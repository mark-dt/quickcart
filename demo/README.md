# Quality-gate exercise — prepared merge requests

Open them on the VM with `quickcart-demo mr <nn>`, then merge in GitLab.
Each scenario is a set of complete files copied over `main` on a new branch,
plus the MR text (`mr.md`).

| Scenario | What happens |
|---|---|
| `01-loyalty-points` | healthy feature → staging → Site Reliability Guardian **PASS** → production |
| `02-loyalty-customer-tiers` | slow, flaky tier lookup → guardian **FAIL** → Dynatrace rolls staging back, production untouched |

`quickcart-demo reset` puts the code and both environments back to the initial
snapshot so the exercise can be run again.
