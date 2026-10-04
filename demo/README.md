# atruvia demo — prepared merge requests

The presenter opens these on the demo VM with `quickcart-demo mr <nn>`. Each
scenario is a set of complete files copied over `main` on a new branch, plus
the MR text (`mr.md`). The full run script is in the aiops-lab repo:
`doc/04-atruvia-demo.md`.

| Scenario | Step | Outcome |
|---|---|---|
| `01-new-service-observability` | 1 — service ready by default | `dynatrace-plan` comments what inventory-service gets; merge applies it |
| `02-loyalty-points` | 2 — feature + deploy | staging deploy + deployment events; gate passes → production |
| `03-loyalty-customer-tiers` | 3 — quality gate | slow, flaky tier lookup → gate fails, MR comment, production untouched |
| `04-loyalty-tier-cache` | 4 — auto-remediation | passes the gate, breaks 5 min after rollout → Davis → rollback + GitLab issue |
