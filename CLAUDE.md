# QuickCart

## Project Overview
Workshop demo environment for Dynatrace HOT (Hands-On Training) sessions.
- **Workshop app**: Custom Node.js microservices (frontend, order-service, payment-service, inventory-service, notification-service) running on k3s

## Architecture

### Workshop App (k8s/k3s)
- Services run in `workshop` namespace on a GCP VM with k3s
- Frontend proxies `/admin/failure-rate` to all payment-service pods via headless service DNS (`payment-service-headless`)
- Ingress: `workshop.PLACEHOLDER_IP.nip.io` → frontend (IP patched at startup via GCP metadata)
- Payment-service has a runtime-mutable failure rate (`POST /admin/failure-rate` with `{"rate": 0.7}`)
- No pod restarts needed for failure rate changes — all replicas updated via API fan-out

### Dynatrace Version Detection
All service manifests include labels and env vars for Dynatrace release tracking:
- Pod labels: `app.kubernetes.io/version` → `DT_RELEASE_VERSION`, `app.kubernetes.io/part-of` → `DT_RELEASE_PRODUCT`
- Env vars: `DT_RELEASE_VERSION`, `DT_RELEASE_PRODUCT`, `DT_RELEASE_STAGE`
- Baseline version is `1.0.0`; the `workshop-release` workflow bumps payment-service to `bad-release-<N>` / `rollback-<N>`

## GitHub Workflows
All in `.github/workflows/`:
- `workshop-deploy-bad-release.yaml` — Set/rollback payment-service failure rate via HTTP API. Supports `workflow_dispatch` and `repository_dispatch` (event: `auto-remediate`)
- `workshop-release.yaml` — GitOps release: commits version label + failure rate changes to `k8s/payment-service.yaml` for ArgoCD sync. Supports `workflow_dispatch` and `repository_dispatch` (event: `auto-remediate-release`). Uses `yq` to update manifest.
- `workshop-build-and-push.yaml` — Build and push Docker images

### Workflow Patterns
- "Resolve action" step handles both `workflow_dispatch` and `repository_dispatch` triggers
- Dynatrace deployment events use `K8_CLUSTER` secret, `entitySelector` with `entityName.startsWith()` and environment tag
- Heredocs must be unquoted (`<<EOF` not `<<'EOF'`) so `${K8_CLUSTER}` shell variable expands

## Dynatrace Workflows
Exported workflow JSONs in `dynatrace-workflows/` folder:
- Sensitive fields (`id`, `actor`, `owner`, `ownerType`) removed before committing
- GitHub PAT referenced as `{{ env.GITHUB_PAT }}` — never hardcode tokens

## Secrets (GitHub Actions)
`DT_ENV_URL`, `DT_API_TOKEN`, `WORKSHOP_IP`, `K8_CLUSTER`, `GCP_SA_KEY`, `VM_NAME`, `VM_ZONE`, `GCP_PROJECT`

## Dev Notes
- VM startup script: `startup.sh` — clones repo, builds images, imports to k3s containerd, applies k8s manifests
- Images built locally on VM (no registry) — `docker build` → `docker save` → `k3s ctr images import`
- After code changes: must rebuild image + restart deployment on VM
