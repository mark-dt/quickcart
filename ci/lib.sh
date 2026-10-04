#!/usr/bin/env bash
# Shared helpers for the demo pipeline (.gitlab-ci.yml). Sourced by every job
# on the shell runner (root on the VM: docker, k3s ctr, k3s kubectl available).
#
# CI/CD variables (set by aiops-lab 58-gitlab): DT_ENV_URL, DT_APPS_URL,
# DT_SSO_URL, DT_TENANT_ID, DT_ACCOUNT_ID, DT_API_TOKEN, DT_CLIENT_ID,
# DT_CLIENT_SECRET, K8_CLUSTER, REPO_PAT, WORKSHOP_IP.

# GitLab's shell executor already runs with errexit + pipefail; no `set -u`
# here — it would also apply to the runner's own step code.

SERVICES="frontend order-service payment-service inventory-service notification-service"
CI_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log() { printf '\033[1;36m==> %s\033[0m\n' "$*"; }

kc() { k3s kubectl "$@"; }

namespace_for() { # namespace_for <staging|production>
  case "$1" in
    staging)    echo "${STAGING_NAMESPACE}" ;;
    production) echo "${PRODUCTION_NAMESPACE}" ;;
    *) echo "unknown stage $1" >&2; return 1 ;;
  esac
}

# ---------------------------------------------------------------- GitLab API
gitlab_api() { # gitlab_api <METHOD> <path> [json-body]
  local method="$1" path="$2" body="${3:-}"
  if [ -n "${body}" ]; then
    curl -sS -X "${method}" -H "PRIVATE-TOKEN: ${REPO_PAT}" -H "Content-Type: application/json" \
      --data-binary "${body}" "${CI_API_V4_URL}${path}"
  else
    curl -sS -X "${method}" -H "PRIVATE-TOKEN: ${REPO_PAT}" "${CI_API_V4_URL}${path}"
  fi
}

# Merge request that produced a commit on main (merge commit) — prints
# "<iid> <web_url> <author_username>", or nothing for a direct push.
mr_for_commit() {
  gitlab_api GET "/projects/${CI_PROJECT_ID}/repository/commits/$1/merge_requests" | python3 -c '
import json, sys
try:
    mrs = json.load(sys.stdin)
except Exception:
    sys.exit(0)
mrs = [m for m in mrs if isinstance(m, dict) and m.get("target_branch") == "main"]
if mrs:
    m = sorted(mrs, key=lambda m: m.get("merged_at") or "", reverse=True)[0]
    print(m["iid"], m["web_url"], m["author"]["username"])'
}

mr_note() { # mr_note <iid> <markdown-file>
  local body
  body="$(python3 -c 'import json,sys; print(json.dumps({"body": open(sys.argv[1]).read()}))' "$2")"
  gitlab_api POST "/projects/${CI_PROJECT_ID}/merge_requests/$1/notes" "${body}" >/dev/null
}

# Export MR_IID / MR_URL / MR_AUTHOR for the commit being released.
load_mr_context() {
  local sha="${1:-${CI_COMMIT_SHA}}" ctx
  ctx="$(mr_for_commit "${sha}" || true)"
  MR_IID="$(echo "${ctx}" | awk '{print $1}')"
  MR_URL="$(echo "${ctx}" | awk '{print $2}')"
  MR_AUTHOR="$(echo "${ctx}" | awk '{print $3}')"
  MR_AUTHOR="${MR_AUTHOR:-${GITLAB_USER_LOGIN:-}}"
  export MR_IID MR_URL MR_AUTHOR
}

# ------------------------------------------------------------------- GitOps
# overlay_version <stage> [ref] — VERSION currently declared in an overlay
overlay_version() {
  local ref="${2:-HEAD}"
  git show "${ref}:deploy/overlays/$1/kustomization.yaml" 2>/dev/null \
    | sed -n 's/^ *- VERSION=//p' | head -n1
}

# gitops_release <stage> <version> <commit message>
# Rewrites the overlay (VERSION + every image newTag) on the tip of main,
# pushes with [skip ci] and prints the pushed commit SHA on stdout.
gitops_release() {
  local stage="$1" version="$2" msg="$3"
  local file="deploy/overlays/${stage}/kustomization.yaml"
  local push_url="https://oauth2:${REPO_PAT}@${CI_SERVER_HOST}/${CI_PROJECT_PATH}.git"
  git config user.name  "gitlab-ci[bot]"
  git config user.email "gitlab-ci[bot]@users.noreply.local"
  for attempt in 1 2 3 4 5; do
    git fetch -q origin "${CI_DEFAULT_BRANCH}" >&2
    git checkout -q -B "${CI_DEFAULT_BRANCH}" "origin/${CI_DEFAULT_BRANCH}" >&2
    sed -i -e "s/^\( *- VERSION=\).*/\1${version}/" -e "s/^\( *newTag:\).*/\1 ${version}/" "${file}"
    if git diff --quiet; then
      log "${stage} already at ${version}" >&2
      git rev-parse HEAD
      return 0
    fi
    git add "${file}"
    git commit -q -m "${msg} [skip ci]" >&2
    if git push -q "${push_url}" "HEAD:${CI_DEFAULT_BRANCH}" >&2; then
      git rev-parse HEAD
      return 0
    fi
    log "push rejected (main moved) — retrying (${attempt}/5)" >&2
    sleep 2
  done
  echo "could not push ${file}" >&2
  return 1
}

# argocd_sync_wait <stage> <git-sha> — refresh the ArgoCD app, wait until it
# runs that revision Synced + Healthy, then wait for the rollouts.
argocd_sync_wait() {
  local stage="$1" sha="$2" app="quickcart-$1" ns rev sync health
  ns="$(namespace_for "${stage}")"
  log "ArgoCD: syncing ${app} to ${sha:0:8}"
  kc -n argocd annotate application "${app}" argocd.argoproj.io/refresh=normal --overwrite >/dev/null
  for i in $(seq 1 90); do
    rev="$(kc -n argocd get application "${app}" -o jsonpath='{.status.sync.revision}' 2>/dev/null || true)"
    sync="$(kc -n argocd get application "${app}" -o jsonpath='{.status.sync.status}' 2>/dev/null || true)"
    health="$(kc -n argocd get application "${app}" -o jsonpath='{.status.health.status}' 2>/dev/null || true)"
    if [ "${rev}" = "${sha}" ] && [ "${sync}" = "Synced" ] && [ "${health}" = "Healthy" ]; then
      break
    fi
    [ $((i % 6)) -eq 0 ] && echo "   ${app}: revision=${rev:0:8} sync=${sync} health=${health}"
    sleep 5
  done
  for svc in ${SERVICES}; do
    kc -n "${ns}" rollout status "deploy/${svc}" --timeout=180s
  done
  log "ArgoCD: ${app} is Synced + Healthy at ${sha:0:8}"
}

# ---------------------------------------------------------------- Dynatrace
# dt_deployment_events <stage> <version> <name> [extra-json-properties]
dt_deployment_events() {
  local extra="${4:-}"
  [ -n "${extra}" ] || extra='{}'
  python3 -u "${CI_DIR}/dt.py" event --stage "$1" --version "$2" --name "$3" \
    --namespace "$(namespace_for "$1")" --extra "${extra}" ${SERVICES}
}
