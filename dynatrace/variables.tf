# --- Dynatrace connection (provided by the pipeline as TF_VAR_*) ---
variable "dt_env_url" {
  type        = string
  description = "Environment URL, e.g. https://ggg43721.sprint.dynatracelabs.com"
}

variable "dt_apps_url" {
  type        = string
  description = "Platform (apps) URL, e.g. https://ggg43721.sprint.apps.dynatracelabs.com"
}

variable "dt_sso_url" {
  type        = string
  description = "SSO token endpoint, e.g. https://sso-sprint.dynatracelabs.com/sso/oauth2/token"
}

variable "dt_api_token" {
  type      = string
  sensitive = true
}

variable "dt_client_id" {
  type = string
}

variable "dt_client_secret" {
  type      = string
  sensitive = true
}

variable "dt_account_id" {
  type        = string
  description = "Dynatrace account UUID"
}

# --- GitLab (used by the auto-remediation workflow) ---
variable "gitlab_url" {
  type        = string
  description = "Public GitLab URL, e.g. https://gitlab.1.2.3.4.nip.io"
}

variable "gitlab_project_id" {
  type = number
}

variable "gitlab_project_path" {
  type        = string
  description = "e.g. user1/quickcart"
}

variable "gitlab_pat" {
  type        = string
  sensitive   = true
  description = "GitLab token (api scope) the remediation workflow uses to start the rollback pipeline and open the issue"
}

# --- Where the service runs ---
variable "k8s_cluster" {
  type        = string
  description = "Kubernetes cluster name as seen by Dynatrace (the DynaKube name), e.g. dynakube-aiops-lab-de-vm-1"
}

variable "staging_namespace" {
  type    = string
  default = "quickcart-staging"
}

variable "production_namespace" {
  type    = string
  default = "quickcart-production"
}

# --- Naming / behaviour ---
variable "name_prefix" {
  type        = string
  default     = "workshop-aiops-lab-demo"
  description = "Every Dynatrace object created here starts with this prefix (shared tenant)."
}

variable "gate_soak_seconds" {
  description = "Seconds the quality-gate workflow waits after the staging deployment event before validating. Must cover gate_window."
  type        = number
  default     = 270
}

variable "gate_window" {
  type        = string
  default     = "now()-4m"
  description = "Start of the quality-gate evaluation window in DQL time syntax (end is always now())"
}

variable "release_product" {
  type        = string
  default     = "quickcart-demo"
  description = "release product on the pipeline's deployment events (sent as dt.event.deployment.release_product, stored in Grail as deployment.release_product)"
}

# --- The part a developer edits (services.auto.tfvars) ---
variable "teams" {
  type = map(object({
    name  = string
    email = string
  }))
}

variable "services" {
  type = map(object({
    team                    = string # key in var.teams
    slo_target              = number # production availability SLO, %
    slo_warning             = number
    gate_failure_rate_max   = number # staging quality gate: max failure rate, %
    gate_p90_ms_max         = number # staging quality gate: max p90 response time, ms
    prod_failure_rate_alert = number # production alert: failure rate above this %, opens a Davis problem
  }))
}
