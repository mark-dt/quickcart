# Everything a service gets by being listed in services.auto.tfvars.

locals {
  # DQL span filter for one service in one namespace (server-side requests only)
  span_filter = {
    for svc, _ in var.services : svc => {
      staging    = "k8s.cluster.name == \"${var.k8s_cluster}\" and k8s.namespace.name == \"${var.staging_namespace}\" and k8s.workload.name == \"${svc}\" and span.kind == \"server\""
      production = "k8s.cluster.name == \"${var.k8s_cluster}\" and k8s.namespace.name == \"${var.production_namespace}\" and k8s.workload.name == \"${svc}\" and span.kind == \"server\""
    }
  }
}

# --- Availability SLO (production) ---
resource "dynatrace_platform_slo" "availability" {
  for_each = var.services

  name        = "${var.name_prefix} ${each.key} availability"
  description = "Share of successful server requests of ${each.key} in production (owner: ${var.teams[each.value.team].name})"
  tags        = ["service:${each.key}", "stage:production", "owner:${var.name_prefix}-${each.value.team}"]

  criteria {
    criteria_detail {
      target         = each.value.slo_target
      warning        = each.value.slo_warning
      timeframe_from = "now-7d"
      timeframe_to   = "now"
    }
  }

  custom_sli {
    indicator = <<-DQL
      fetch spans
      | filter ${local.span_filter[each.key].production}
      | makeTimeseries {total = count(), failed = countIf(request.is_failed == true)}
      | fieldsAdd sli = 100 * (total[] - failed[]) / total[]
      | fieldsRemove total, failed
    DQL
  }
}

# --- Quality gate (Site Reliability Guardian, evaluated on staging) ---
resource "dynatrace_site_reliability_guardian" "gate" {
  for_each = var.services

  name        = "${each.key} quality gate"
  description = "Staging release check for ${each.key}. Run by the GitLab pipeline after every staging deployment; production is only touched if this passes."
  tags        = ["service:${each.key}", "stage:staging"]

  objectives {
    objective {
      name                = "Failure rate"
      description         = "Share of failed server requests in staging, %"
      objective_type      = "DQL"
      comparison_operator = "LESS_THAN_OR_EQUAL"
      target              = each.value.gate_failure_rate_max
      dql_query           = <<-DQL
        fetch spans
        | filter ${local.span_filter[each.key].staging}
        | summarize failure_rate = 100.0 * countIf(request.is_failed == true) / count()
      DQL
    }

    objective {
      name                = "Response time p90 (ms)"
      description         = "90th percentile of server request duration in staging, ms"
      objective_type      = "DQL"
      comparison_operator = "LESS_THAN_OR_EQUAL"
      target              = each.value.gate_p90_ms_max
      dql_query           = <<-DQL
        fetch spans
        | filter ${local.span_filter[each.key].staging}
        | summarize p90_ms = toDouble(percentile(duration, 90)) / 1000000.0
      DQL
    }
  }
}

# --- Production anomaly detection (opens a Davis problem) ---
resource "dynatrace_davis_anomaly_detectors" "prod_failure_rate" {
  for_each = var.services

  title       = "${var.name_prefix} ${each.key} production failure rate"
  description = "Failure rate of ${each.key} in production above ${each.value.prod_failure_rate_alert}% for 3 of 5 minutes"
  enabled     = true
  source      = var.name_prefix

  analyzer {
    name = "dt.statistics.ui.anomaly_detection.StaticThresholdAnomalyDetectionAnalyzer"
    input {
      analyzer_input_field {
        key = "query"
        # Metric timeseries (not spans/makeTimeseries): anomaly detectors only
        # accept a plain timeseries query with interval:1m and no timeframe.
        value = <<-DQL
          timeseries {total = sum(dt.service.request.count), failed = sum(dt.service.request.failure_count)},
            by: {dt.entity.service, k8s.namespace.name, k8s.cluster.name, k8s.workload.name},
            filter: k8s.cluster.name == "${var.k8s_cluster}" and k8s.namespace.name == "${var.production_namespace}" and k8s.workload.name == "${each.key}",
            interval: 1m
          | fieldsAdd failure_rate = 100 * failed[] / total[]
          | fieldsRemove total, failed
        DQL
      }
      analyzer_input_field {
        key   = "threshold"
        value = tostring(each.value.prod_failure_rate_alert)
      }
      analyzer_input_field {
        key   = "alertCondition"
        value = "ABOVE"
      }
      analyzer_input_field {
        key   = "alertOnMissingData"
        value = "false"
      }
      analyzer_input_field {
        key   = "violatingSamples"
        value = "3"
      }
      analyzer_input_field {
        key   = "slidingWindow"
        value = "5"
      }
      analyzer_input_field {
        key   = "dealertingSamples"
        value = "5"
      }
    }
  }

  event_template {
    properties {
      property {
        key   = "event.type"
        value = "ERROR_EVENT"
      }
      property {
        key   = "event.name"
        value = "${each.key} failure rate above ${each.value.prod_failure_rate_alert}% in production"
      }
      property {
        key   = "event.description"
        value = "The ${var.name_prefix} anomaly detector for ${each.key} saw the production failure rate above ${each.value.prod_failure_rate_alert}% for 3 of the last 5 minutes."
      }
      property {
        key   = "dt.source_entity"
        value = "{dims:dt.entity.service}"
      }
      property {
        key   = "k8s.namespace.name"
        value = var.production_namespace
      }
      property {
        key   = "k8s.cluster.name"
        value = var.k8s_cluster
      }
    }
  }

  execution_settings {}
}

# --- Quality-gate workflow (started on demand by the pipeline via the Automation API) ---
resource "dynatrace_automation_workflow" "quality_gate" {
  for_each = var.services

  title       = "${var.name_prefix} ${each.key} quality gate"
  description = "Triggered by every ${each.key} deployment to staging: validates the guardian after a traffic soak and, on FAIL, starts the GitLab rollback pipeline for staging. The release pipeline reads the verdict to decide promotion."

  # The staging deployment event sent by the pipeline (deploy-staging) starts
  # the validation. Rollback events ("<svc> rollback") deliberately don't match.
  trigger {
    event {
      active = true
      config {
        event {
          event_type = "events"
          query      = "event.type == \"CUSTOM_DEPLOYMENT\" AND deployment.release_product == \"${var.release_product}\" AND deployment.release_stage == \"staging\" AND deployment.name == \"${each.key} deploy\" AND k8s.cluster.name == \"${var.k8s_cluster}\""
        }
      }
    }
  }

  tasks {
    task {
      name        = "validate"
      description = "Run the ${each.key} quality gate (Site Reliability Guardian) on staging after the traffic soak"
      action      = "dynatrace.site.reliability.guardian:validate-guardian-action"
      active      = true
      # Let the new version take traffic for the whole guardian window first.
      wait_before = var.gate_soak_seconds
      # Input shape of the SRG "validate guardian" action (objectId = the
      # guardian's settings object id; timeframe in DQL time syntax).
      input = jsonencode({
        objectId           = dynatrace_site_reliability_guardian.gate[each.key].id
        executionId        = "{{ execution().id }}"
        timeframeInputType = "timeframeSelector"
        timeframeSelector = {
          from = var.gate_window
          to   = "now()"
        }
        expressionFrom = ""
        expressionTo   = ""
      })
      position {
        x = 0
        y = 1
      }
    }
    task {
      name        = "rollback_staging"
      description = "On FAIL: start the GitLab rollback pipeline for staging (ArgoCD syncs the previous version)"
      action      = "dynatrace.automations:run-javascript"
      active      = true
      input = jsonencode({
        script = templatefile("${path.module}/scripts/rollback_staging.js", {
          cfg = jsonencode({
            appsUrl   = var.dt_apps_url
            gitlabUrl = var.gitlab_url
            projectId = var.gitlab_project_id
            gitlabPat = var.gitlab_pat
            service   = each.key
          })
        })
      })
      conditions {
        states = { validate = "OK" }
      }
      position {
        x = 0
        y = 2
      }
    }
  }
}
