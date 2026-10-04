provider "dynatrace" {
  # Classic / Settings 2.0 APIs (ownership teams, anomaly detectors, guardians)
  dt_env_url   = var.dt_env_url
  dt_api_token = var.dt_api_token

  # Platform APIs (segments, platform SLOs) — OAuth client credentials
  client_id     = var.dt_client_id
  client_secret = var.dt_client_secret
  account_id    = var.dt_account_id

  # Workflows (AutomationEngine) — same OAuth client
  automation_client_id     = var.dt_client_id
  automation_client_secret = var.dt_client_secret
  automation_env_url       = var.dt_apps_url
  automation_token_url     = var.dt_sso_url
}
