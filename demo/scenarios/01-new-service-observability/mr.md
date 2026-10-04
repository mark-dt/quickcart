# Onboard inventory-service to Dynatrace

inventory-service gets the same production readiness as payment-service — by
adding one entry to `dynatrace/services.auto.tfvars`. No clicks in the
Dynatrace UI.

The pipeline's `dynatrace-plan` job shows (and comments here) what gets created:

- owner team **Fulfillment** (and the `dt.owner` label on the workload)
- availability **SLO** for production
- **Site Reliability Guardian** quality gate for staging (failure rate, p90)
- **anomaly detector** for the production failure rate
- quality-gate **workflow** the pipeline calls after every staging deploy

Merging applies it.
