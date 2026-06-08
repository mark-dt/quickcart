# Workshop Exercises

The initial deploy is clean and runs without bugs. Each exercise is triggered by a dedicated Gitea pipeline that introduces a failure mode. Use the matching pipeline (with `action: rollback`) or fix the code manually to recover.

---

## Exercise 1 -- Auto-Remediation (payment-service)

**Trigger pipeline:** `.gitea/workflows/bad-release-payment-service.yaml`
**Manual run input:** `action = deploy-bad-release`, `failure_rate = 1.0`

**What happens:** The pipeline POSTs to `/admin/failure-rate` on the payment-service ingress and flips every payment to 100% failure (HTTP 500 with a 2-8s artificial latency). Davis raises a problem within minutes.

**The auto-remediation hook:** The pipeline emits a `CUSTOM_DEPLOYMENT` event with two properties:
- `remediation.url` -- Gitea dispatches API endpoint for this repo
- `remediation.event_type` -- `auto-remediate-payment`

The Dynatrace workflow `[WORKSHOP] Auto-Remediation: Gitea Pipeline Trigger` (`dynatrace-workflows/workshop-auto-remediation-gitea.workflow.json`) listens for Davis problems on workshop services, runs a DQL query to look up the latest `remediation.url` for the affected service, and `POST`s to it with `{"event_type": "<remediation.event_type>"}`. That re-triggers the same pipeline with `repository_dispatch`, which resolves to `action = rollback` and resets the failure rate to `0`.

**Where to look in Dynatrace:** Services > payment-service > Failure rate. After enabling the workflow, watch the deployment markers -- you should see the bad release followed by an automatic rollback marker.

**Manual recovery:** Re-run the same pipeline with `action = rollback` (no commit needed -- the failure rate is mutated at runtime via the `/admin/failure-rate` endpoint).

---

## Exercise 2 -- Manual Troubleshooting (order-service)

**Trigger pipeline:** `.gitea/workflows/bad-release-order-service.yaml`
**Manual run input:** `action = deploy-bad-release`

**What happens:** The pipeline rewrites `services/order-service/index.js` line 46 from the fixed form to the buggy form, commits and pushes. The `build-and-deploy` pipeline then rebuilds and rolls out the buggy image. The `order-service` randomly selects one of `WIDGET-1`, `WIDGET-2`, `WIDGET-3` per order; only `WIDGET-1` has an entry in `PRODUCT_META`, so the other two trigger `TypeError: Cannot read properties of undefined (reading 'category')`.

**Trigger rate:** ~66% of requests (2 out of 3 items are missing).

**Where to look in Dynatrace:** Services > order-service > Failure rate > pick a failed request > exception stack trace points to `services/order-service/index.js`.

**Buggy line (after pipeline runs):**
```javascript
const category = meta.category;
```

**Fix -- restore line 46 to:**
```javascript
const category = meta ? meta.category : "general";
```

**Recovery options:**
- Edit the file, commit, push -- the `build-and-deploy` pipeline rebuilds with your fix.
- OR re-run the bad-release pipeline with `action = rollback` to revert the line via GitOps mutation.

---

## Exercise 3 -- Fix with Claude + MCP (inventory-service)

**Trigger pipeline:** `.gitea/workflows/bad-release-inventory-service.yaml`
**Manual run input:** `action = deploy-bad-release`

**What happens:** The pipeline rewrites `services/inventory-service/index.js` line 26 from the fixed form to the buggy form, commits and pushes. After rebuild, the service picks a random warehouse for each `/check` request. Warehouse `AP-SOUTH-1` has `total: 0` and `reserved: 0`, so `available = 0`. `Math.ceil(100 / 0)` is `Infinity`, and `new Array(Infinity)` throws `RangeError: Invalid array length`. The error is caught (see commit `a0c4b72`) and logged, so the pod stays up and returns HTTP 500 -- but the request still fails.

**Trigger rate:** ~33% of requests (1 out of 3 warehouses).

**Where to look in Dynatrace:** Services > inventory-service > Failure rate > pick a failed request > exception stack trace points to `services/inventory-service/index.js`. Or query logs for `service:"inventory-service" status:500`.

**Buggy line (after pipeline runs):**
```javascript
const restockUnits = Math.ceil(100 / available);
```

**Fix -- restore line 26 to:**
```javascript
const restockUnits = available > 0 ? Math.ceil(100 / available) : 0;
```

**Recovery options:**
- Edit the file, commit, push -- the `build-and-deploy` pipeline rebuilds with your fix.
- OR re-run the bad-release pipeline with `action = rollback` to revert the line via GitOps mutation.

---

## Pipeline & secrets summary

All three bad-release pipelines live in `.gitea/workflows/`. They share the same trigger model:

- `workflow_dispatch` with `action: deploy-bad-release | rollback` for manual runs
- `repository_dispatch` with a per-service type (`auto-remediate-payment`, `auto-remediate-order`, `auto-remediate-inventory`) for the Dynatrace workflow callback

Required Gitea Actions secrets on the repo:

| Secret | Used by | Purpose |
|---|---|---|
| `DT_ENV_URL` | all three | Dynatrace tenant URL for the deployment event ingest |
| `DT_API_TOKEN` | all three | Token with `events.ingest` scope |
| `K8_CLUSTER` | all three | Kubernetes cluster entity name (used in the `entitySelector` relationship) |
| `WORKSHOP_IP` | payment-service only | IP behind the `workshop.<ip>.nip.io` ingress |
| `GITEA_PAT` | order + inventory only | PAT with repo write (used by source-mutation pipelines to commit back to `main`) |

The Dynatrace workflow requires a Dynatrace app environment variable named `GITEA_PAT` (a Gitea token with repo dispatch permission) to authenticate the callback POST.
