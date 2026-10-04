# Who owns what — one entry per team
teams = {
  payments = { name = "Payments", email = "payments@quickcart.example" }
}

# Every service listed here gets, without touching the Dynatrace UI:
#   ownership, segment, availability SLO, staging quality gate (SRG),
#   production anomaly detection and the auto-remediation hook.
services = {
  "payment-service" = {
    team                    = "payments"
    slo_target              = 99.0 # % availability in production
    slo_warning             = 99.5
    gate_failure_rate_max   = 2   # % — staging quality gate
    gate_p90_ms_max         = 500 # ms — staging quality gate
    prod_failure_rate_alert = 5   # % — production problem threshold
  }
}
