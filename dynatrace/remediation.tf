# Auto-remediation: Davis problem -> find the production deployment behind it
# -> GitLab rollback pipeline (ArgoCD syncs the previous version) -> GitLab issue
# for the developer. Problems that don't belong to a QuickCart production
# deployment on this cluster are skipped in find_deployment.

locals {
  remediation_cfg = jsonencode({
    appsUrl        = var.dt_apps_url
    gitlabUrl      = var.gitlab_url
    projectId      = var.gitlab_project_id
    gitlabPat      = var.gitlab_pat
    cluster        = var.k8s_cluster
    releaseProduct = var.release_product
  })
}

resource "dynatrace_automation_workflow" "remediation" {
  title                  = "${var.name_prefix} auto-remediation"
  description            = "Rolls back the QuickCart production deployment that caused a Davis problem and opens a GitLab issue for its author."
  hourly_execution_limit = 1000

  trigger {
    event {
      active = true
      config {
        davis_problem {
          trigger_on = "open"
          categories {
            error    = true
            slowdown = true
          }
        }
      }
    }
  }

  tasks {
    task {
      name        = "find_deployment"
      description = "Find the QuickCart production deployment behind this problem"
      action      = "dynatrace.automations:run-javascript"
      active      = true
      input = jsonencode({
        script = templatefile("${path.module}/scripts/find_deployment.js", { cfg = local.remediation_cfg })
      })
      position {
        x = 0
        y = 1
      }
    }

    task {
      name        = "trigger_rollback"
      description = "Start the GitLab rollback pipeline (ArgoCD syncs the previous version)"
      action      = "dynatrace.automations:run-javascript"
      active      = true
      input = jsonencode({
        script = templatefile("${path.module}/scripts/trigger_rollback.js", { cfg = local.remediation_cfg })
      })
      conditions {
        states = { find_deployment = "OK" }
        custom = "{{ result(\"find_deployment\").found }}"
      }
      position {
        x = 0
        y = 2
      }
    }

    task {
      name        = "create_gitlab_issue"
      description = "Open a GitLab issue for the author of the merge request"
      action      = "dynatrace.automations:run-javascript"
      active      = true
      input = jsonencode({
        script = templatefile("${path.module}/scripts/create_gitlab_issue.js", { cfg = local.remediation_cfg })
      })
      conditions {
        states = { trigger_rollback = "OK" }
      }
      position {
        x = 0
        y = 3
      }
    }
  }
}
