terraform {
  required_version = ">= 1.5.0"

  required_providers {
    dynatrace = {
      source  = "dynatrace-oss/dynatrace"
      version = "~> 1.96"
    }
  }

  # GitLab-managed Terraform state — address/lock/credentials are passed with
  # -backend-config by the pipeline (see .gitlab-ci.yml).
  backend "http" {}
}
