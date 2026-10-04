# Ownership teams. Workloads point at a team with the Kubernetes label
#   dt.owner: <identifier>     e.g. dt.owner: workshop-aiops-lab-demo-payments
resource "dynatrace_ownership_teams" "team" {
  for_each = var.teams

  name        = "${var.name_prefix} ${each.value.name}"
  identifier  = "${var.name_prefix}-${each.key}"
  description = "Owns ${join(", ", [for svc, s in var.services : svc if s.team == each.key])} (managed by Terraform in the quickcart repo)"

  responsibilities {
    development      = true
    operations       = true
    infrastructure   = false
    line_of_business = false
    security         = false
  }

  contact_details {
    contact_detail {
      integration_type = "EMAIL"
      email            = each.value.email
    }
  }

  links {
    link {
      link_type = "REPOSITORY"
      url       = "${var.gitlab_url}/${var.gitlab_project_path}"
    }
  }
}
