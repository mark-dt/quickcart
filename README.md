# QuickCart

Five small Node.js microservices (frontend, order, payment, inventory,
notification) and the pipeline that ships them.

```
services/<svc>/        source + Dockerfile per service
deploy/base/           Kubernetes manifests (shared)
deploy/overlays/       staging / production — the version (image tag) per stage; ArgoCD syncs these
.gitlab-ci.yml, ci/    pipeline: build → deploy staging → quality gate → promote production (+ rollback)
```

## Pipeline

On every merge to `main`:

1. **build** — one image per service, tagged with the short commit SHA
2. **deploy-staging** — writes the version into `deploy/overlays/staging`, ArgoCD syncs, a
   Dynatrace deployment event is sent
3. **quality-gate** — Dynatrace validates staging (Site Reliability Guardian, triggered by the
   deployment event); the job waits for the verdict and comments it on the merge request
4. **promote-production** — only on PASS
5. **rollback** — started by Dynatrace on FAIL (`ROLLBACK=true`): staging goes back to the
   previous version

The Dynatrace configuration (guardian, quality-gate workflow) is not in this repo — it lives
in [quickcart-dt-config](https://github.com/mark-dt/quickcart-dt-config) and is applied by
that repo's pipeline.

## Contract with quickcart-dt-config

The quality gate only works if both repos agree on these names. Change them together.

| What | Value | Here | There |
|---|---|---|---|
| Deployment event | `CUSTOM_DEPLOYMENT` per service, `dt.event.deployment.name = "<service> deploy"`, `release_stage = staging/production`, `release_product = quickcart-demo` (`RELEASE_PRODUCT`), `k8s.cluster.name = $K8_CLUSTER` — stored in Grail as `deployment.<x>` | `ci/dt.py event` | workflow trigger |
| Workflow title | `workshop-aiops-lab $K8_CLUSTER $GATE_SERVICE quality gate` | `quality-gate` job | `terraform/workflow.tf` |
| Verdict | task `validate`, result `validation_status`, `validation_details[]` | `ci/dt.py gate` | Site Reliability Guardian |
| Rollback | pipeline variables `ROLLBACK=true`, `ROLLBACK_STAGE`, `ROLLBACK_FROM_VERSION`, `ROLLBACK_REASON`, `DT_VALIDATION_URL` | `rollback` job | GitLab connector task `rollback_staging` in `terraform/workflow.tf` |

CI/CD variables this pipeline expects: `DT_ENV_URL`, `DT_API_TOKEN` (events.ingest),
`DT_APPS_URL`, `DT_SSO_URL`, `DT_TENANT_ID`, `DT_CLIENT_ID`, `DT_CLIENT_SECRET`
(automation:workflows:read), `K8_CLUSTER`, `REPO_PAT`, `WORKSHOP_IP`.
