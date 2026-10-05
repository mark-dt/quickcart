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
in the `dynatrace-config` repo and is applied by that repo's pipeline.
