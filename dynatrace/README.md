# Dynatrace configuration for QuickCart

The Dynatrace setup of every QuickCart service lives here, next to the code,
and is applied by the GitLab pipeline. Nobody configures these objects in the
Dynatrace UI.

## Adding a service

Add one entry to `services.auto.tfvars` (and, if the service has a new owner,
one entry under `teams`) and open a merge request:

- the merge request pipeline runs `terraform plan` and posts the plan summary
  on the merge request
- merging to `main` runs `terraform apply`

## What each service gets

| Object | File | Purpose |
|---|---|---|
| Ownership team | `teams.tf` | Who owns the service. Workloads point at it with the k8s label `dt.owner: workshop-aiops-lab-demo-<team>` |
| Segment | `segment.tf` | One segment that scopes all data to QuickCart staging + production on this cluster |
| Availability SLO | `service.tf` | Production success rate over 7 days (`slo_target` / `slo_warning`) |
| Quality gate | `service.tf` | Site Reliability Guardian on **staging**: failure rate and p90 response time |
| Quality-gate workflow | `service.tf` | Runs the guardian over the last few minutes; the pipeline starts it after every staging deployment |
| Anomaly detector | `service.tf` | Opens a Davis problem when the **production** failure rate goes above `prod_failure_rate_alert` |
| Auto-remediation workflow | `remediation.tf` | Davis problem → finds the production deployment behind it → starts the GitLab rollback pipeline → opens a GitLab issue for the merge request author |

Every object name starts with `workshop-aiops-lab-demo` (shared tenant).

## Inputs

The pipeline sets these as `TF_VAR_*`: `dt_env_url`, `dt_apps_url`,
`dt_sso_url`, `dt_api_token`, `dt_client_id`, `dt_client_secret`,
`dt_account_id`, `gitlab_url`, `gitlab_project_id`, `gitlab_project_path`,
`gitlab_pat`, `k8s_cluster`. State is kept in GitLab's Terraform state
backend (`backend "http"`).
