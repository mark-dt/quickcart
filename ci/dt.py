#!/usr/bin/env python3
"""Dynatrace calls of the pipeline.

  event  — send a CUSTOM_DEPLOYMENT event per service
  gate   — wait for the quality-gate verdict, write the MR report (exit 1 = fail)
"""
import argparse
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

env = os.environ.get


def http(method, url, headers=None, body=None, form=None, timeout=60):
    data = None
    headers = dict(headers.items()) if headers is not None else {}
    if form is not None:
        data = urllib.parse.urlencode(form).encode()
        headers["Content-Type"] = "application/x-www-form-urlencoded"
    elif body is not None:
        data = json.dumps(body).encode()
        headers["Content-Type"] = "application/json"
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            raw = resp.read().decode() or "{}"
            return resp.status, json.loads(raw)
    except urllib.error.HTTPError as e:
        raw = e.read().decode()
        try:
            return e.code, json.loads(raw)
        except ValueError:
            return e.code, {"raw": raw}


# --------------------------------------------------------------- events
def single_entity_selector(selector):
    """Selector for the most recently seen matching entity (one event, one workflow run)."""
    status, resp = http(
        "GET",
        f"{env('DT_ENV_URL')}/api/v2/entities?" + urllib.parse.urlencode(
            {"entitySelector": selector, "fields": "lastSeenTms", "from": "now-2h", "pageSize": 50}),
        headers={"Authorization": f"Api-Token {env('DT_API_TOKEN')}"},
    )
    entities = resp.get("entities") or [] if status == 200 else []
    if not entities:
        return selector, 0
    latest = max(entities, key=lambda e: e.get("lastSeenTms") or 0)
    return f'entityId("{latest["entityId"]}")', len(entities)



# dt.event.deployment.<x> properties are stored in Grail as deployment.<x>
def cmd_event(a):
    extra = json.loads(a.extra or "{}")
    commit_url = f"{env('CI_PROJECT_URL')}/-/commit/{env('CI_COMMIT_SHA')}"
    ok = True
    for svc in a.services:
        title = f"{svc} {a.name} {a.version}"
        props = {
            "event.title": title,
            "event.description": f"{a.name} of {svc} {a.version} to {a.stage} ({a.namespace})",
            "dt.event.deployment.name": f"{svc} {a.name}",
            "dt.event.deployment.version": a.version,
            "dt.event.deployment.release_stage": a.stage,
            "dt.event.deployment.release_product": env("RELEASE_PRODUCT", "quickcart-demo"),
            "dt.event.deployment.ci_back_link": env("CI_PIPELINE_URL", ""),
            "dt.event.deployment.release_build_version": env("CI_PIPELINE_IID", ""),
            "service.name": svc,
            "k8s.cluster.name": env("K8_CLUSTER", ""),
            "k8s.namespace.name": a.namespace,
            "git.commit.sha": env("CI_COMMIT_SHA", ""),
            "git.commit.url": commit_url,
            "git.repository": env("CI_PROJECT_PATH", ""),
            "gitlab.pipeline.url": env("CI_PIPELINE_URL", ""),
            "gitlab.merge_request.url": env("MR_URL", ""),
            "gitlab.merge_request.iid": env("MR_IID", ""),
            "gitlab.merge_request.author": env("MR_AUTHOR", ""),
        }
        props.update(extra)
        props = {k: str(v) for k, v in props.items() if v not in (None, "")}
        selector = (
            f'type(SERVICE),entityName.startsWith("{svc}"),'
            f'toRelationships.isNamespaceOfService(type(CLOUD_APPLICATION_NAMESPACE),entityName.equals("{a.namespace}")),'
            f'toRelationships.isClusterOfService(type(KUBERNETES_CLUSTER),entityName.equals("{env("K8_CLUSTER")}"))'
        )
        selector, candidates = single_entity_selector(selector)
        status, resp = http(
            "POST", f"{env('DT_ENV_URL')}/api/v2/events/ingest",
            headers={"Authorization": f"Api-Token {env('DT_API_TOKEN')}"},
            body={"eventType": "CUSTOM_DEPLOYMENT", "title": title,
                  "entitySelector": selector, "properties": props},
        )
        matched = sum(1 for r in resp.get("eventIngestResults", []) if r.get("status") == "OK")
        print(f"   deployment event {svc} ({a.stage} {a.version}): HTTP {status}, {matched} entity "
              f"(latest of {candidates} candidate(s))")
        if status >= 300:
            print(f"   {json.dumps(resp)[:400]}")
            ok = False
    return 0 if ok else 1


# ----------------------------------------------------------- quality gate
_TOKEN = {"value": None, "expires": 0.0, "scopes": None}


def platform_token(scopes):
    """OAuth platform token, cached and refreshed before it expires."""
    if _TOKEN["value"] and _TOKEN["scopes"] == scopes and time.time() < _TOKEN["expires"] - 60:
        return _TOKEN["value"]
    status, resp = http("POST", env("DT_SSO_URL"), form={
        "grant_type": "client_credentials",
        "client_id": env("DT_CLIENT_ID"),
        "client_secret": env("DT_CLIENT_SECRET"),
        "scope": scopes,
        "resource": f"urn:dtenvironment:{env('DT_TENANT_ID')}",
    })
    if status != 200 or "access_token" not in resp:
        sys.exit(f"OAuth token request failed: HTTP {status} {json.dumps(resp)[:300]}")
    _TOKEN.update(value=resp["access_token"], scopes=scopes,
                  expires=time.time() + float(resp.get("expires_in", 300)))
    return _TOKEN["value"]


GATE_SCOPES = "automation:workflows:read automation:workflows:run"


class Auth(dict):
    """Headers mapping that always carries a fresh bearer token."""
    def items(self):
        return {"Authorization": f"Bearer {platform_token(GATE_SCOPES)}"}.items()


def first(d, *keys, default=None):
    for k in keys:
        if isinstance(d, dict) and d.get(k) not in (None, ""):
            return d[k]
    return default


def find_triggered_execution(base, auth, workflow_id, version, not_before, wait_s):
    """Execution of the gate workflow triggered by this version's staging deployment."""
    deadline = time.time() + wait_s
    seen = set()
    while time.time() < deadline:
        _, lst = http("GET", f"{base}/executions?workflow={workflow_id}&limit=20", headers=auth)
        for ex in (lst.get("results") or []) if isinstance(lst, dict) else []:
            if ex.get("workflow") not in (None, workflow_id) or ex["id"] in seen:
                continue
            _, det = http("GET", f"{base}/executions/{ex['id']}", headers=auth)
            ev = (det.get("params") or {}).get("event") or {}
            if ev.get("deployment.version") == version:
                return ex["id"]
            started = det.get("startedAt") or ""
            if started and started < not_before:
                seen.add(ex["id"])
        time.sleep(10)
    return None


def cmd_gate(a):
    auth = Auth()
    base = f"{env('DT_APPS_URL')}/platform/automation/v1"

    # The workflow is created per VM by the aiops-lab Terraform; find it by title.
    _, lst = http("GET", f"{base}/workflows?search={urllib.parse.quote(a.workflow_title)}&limit=50", headers=auth)
    ids = [w["id"] for w in (lst.get("results") or []) if w.get("title") == a.workflow_title]
    if not ids:
        sys.exit(f"quality-gate workflow '{a.workflow_title}' not found in Dynatrace")
    a.workflow_id = ids[0]
    not_before = time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime(a.deployed_at - 60))

    # Dynatrace starts the validation itself from the staging deployment event.
    exec_id = find_triggered_execution(base, auth, a.workflow_id, a.version, not_before, a.trigger_wait)
    triggered = exec_id is not None
    if not triggered:
        print(f"   !! no execution of the quality-gate workflow was triggered by the deployment event "
              f"within {a.trigger_wait}s — check the workflow's event trigger. Starting it directly.")
        status, run = http("POST", f"{base}/workflows/{a.workflow_id}/run", headers=auth, body={})
        if status >= 300 or "id" not in run:
            sys.exit(f"could not start quality-gate workflow {a.workflow_id}: HTTP {status} {json.dumps(run)[:300]}")
        exec_id = run["id"]
    exec_url = f"{env('DT_APPS_URL')}/ui/apps/dynatrace.automations/executions/{exec_id}"
    print(f"   quality gate for {a.service} {a.version}: {exec_url} "
          f"({'triggered by the deployment event' if triggered else 'started by the pipeline'})")

    state = "RUNNING"
    for i in range(240):
        _, ex = http("GET", f"{base}/executions/{exec_id}", headers=auth)
        state = ex.get("state", state)
        if state not in ("RUNNING", "WAITING", "IDLE"):
            break
        if i % 6 == 0:
            print(f"   waiting for the guardian ({state})...")
        time.sleep(10)
    _, result = http("GET", f"{base}/executions/{exec_id}/tasks/validate/result", headers=auth)
    if not isinstance(result, dict):
        result = {}
    _, rollback = http("GET", f"{base}/executions/{exec_id}/tasks/rollback_staging/result", headers=auth)
    if not isinstance(rollback, dict):
        rollback = {}

    # Guardian result (field names vary between SRG versions)
    verdict = str(first(result, "validation_status", "status", default="error")).lower()
    objectives = first(result, "validation_details", "objective_results", "objectives", default=[]) or []
    rows = []
    for o in objectives:
        rows.append({
            "name": first(o, "name", "objective_name", default="?"),
            "status": str(first(o, "status", default="?")).lower(),
            "value": (round(o["value"], 2) if isinstance(o.get("value"), (int, float))
                      else first(o, "display_value", default="—")),
            "target": first(o, "target", default="—"),
            "warning": first(o, "warning", default="—"),
        })
    srg_url = first(result, "validation_url", "url", default=exec_url)

    icon = {"pass": "✅", "warning": "⚠️", "fail": "❌"}.get(verdict, "⛔")
    lines = [
        f"### {icon} Dynatrace quality gate: **{verdict.upper()}** — `{a.service}` {env('CI_COMMIT_SHORT_SHA', '')}",
        "",
        f"Site Reliability Guardian validated the new version in **staging** "
        f"(pipeline [#{env('CI_PIPELINE_IID', '')}]({env('CI_PIPELINE_URL', '')})).",
        "",
    ]
    if rows:
        lines += ["| Objective | Result | Value | Target | Warning |", "|---|---|---|---|---|"]
        for r in rows:
            ri = {"pass": "✅", "warning": "⚠️", "fail": "❌"}.get(r["status"], "⛔")
            lines.append(f"| {r['name']} | {ri} {r['status']} | {r['value']} | {r['target']} | {r['warning']} |")
        lines.append("")
    if verdict not in ("pass", "warning"):
        # rollback_staging = GitLab connector "Trigger a new pipeline" (GitLab pipeline object)
        rollback_url = (rollback.get("pipeline") or {}).get("web_url")
        if rollback_url:
            lines.append(f"↩️ **Dynatrace rolled staging back** to the previous version "
                         f"([rollback pipeline]({rollback_url})).")
            lines.append("")
    if verdict not in ("pass", "warning", "fail"):
        lines.append(f"The validation did not produce a verdict (workflow state `{state}`) — treating it as failed.")
    lines += ["", f"[Validation details in Dynatrace]({srg_url}) · [Workflow execution]({exec_url})"]

    with open(a.report, "w") as f:
        f.write("\n".join(lines) + "\n")
    print("\n".join(lines))
    if not rows and result:
        print(f"   raw SRG result: {json.dumps(result)[:1500]}")
    return 0 if verdict in ("pass", "warning") else 1


def main():
    p = argparse.ArgumentParser()
    sub = p.add_subparsers(dest="cmd", required=True)
    e = sub.add_parser("event")
    e.add_argument("--stage", required=True)
    e.add_argument("--version", required=True)
    e.add_argument("--name", required=True)
    e.add_argument("--namespace", required=True)
    e.add_argument("--extra", default="{}")
    e.add_argument("services", nargs="+")
    g = sub.add_parser("gate")
    g.add_argument("--workflow-title", required=True)
    g.add_argument("--version", required=True)
    g.add_argument("--deployed-at", type=int, required=True, help="unix time of the staging deployment")
    g.add_argument("--trigger-wait", type=int, default=180, help="seconds to wait for the event-triggered execution")
    g.add_argument("--service", required=True)
    g.add_argument("--report", required=True)
    a = p.parse_args()
    sys.exit(cmd_event(a) if a.cmd == "event" else cmd_gate(a))


if __name__ == "__main__":
    main()
