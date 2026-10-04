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

  name        = "${var.name_prefix} ${each.key} quality gate"
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
        key   = "query"
        value = <<-DQL
          fetch spans
          | filter ${local.span_filter[each.key].production}
          | makeTimeseries {total = count(), failed = countIf(request.is_failed == true)}, by: {dt.entity.service}, interval: 1m
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
  description = "Validates the ${each.key} guardian over the last staging window. Started by the GitLab pipeline; the result decides promotion to production."

  tasks {
    task {
      name        = "validate"
      description = "Run the ${each.key} quality gate (Site Reliability Guardian) on staging"
      action      = "dynatrace.site.reliability.guardian:validate-guardian-action"
      active      = true
      input = jsonencode({
        guardianId         = dynatrace_site_reliability_guardian.gate[each.key].id
        timeframeInputType = "timeframeSelector"
        timeframeSelector = {
          timeframeFrom = var.gate_window
          timeframeTo   = "now"
        }
      })
      position {
        x = 0
        y = 1
      }
    }
  }
}
