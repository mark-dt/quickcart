// create_gitlab_issue — tell the developer what happened, in GitLab.
// Rendered by Terraform (remediation.tf); CFG is injected as JSON.
import { execution } from '@dynatrace-sdk/automation-utils';

const CFG = ${cfg};

function gitlab(path, options) {
  const opts = options || {};
  opts.headers = Object.assign({
    'Accept': 'application/json',
    'Content-Type': 'application/json',
    'PRIVATE-TOKEN': CFG.gitlabPat,
  }, opts.headers || {});
  return fetch(CFG.gitlabUrl + '/api/v4' + path, opts);
}

function link(label, url) {
  return url ? '[' + label + '](' + url + ')' : label;
}

export default async function ({ execution_id }) {
  const exec = await execution(execution_id);
  const dep = await exec.result('find_deployment');
  const rb = await exec.result('trigger_rollback');

  // Assign the issue to the author of the merge request that shipped the change
  let assigneeIds = [];
  if (dep.mergeRequestAuthor) {
    const res = await gitlab('/users?username=' + encodeURIComponent(dep.mergeRequestAuthor));
    const users = res.ok ? await res.json() : [];
    if (users.length > 0) assigneeIds = [users[0].id];
  }

  const shortSha = dep.commit ? String(dep.commit).substring(0, 8) : 'unknown';
  const mr = dep.mergeRequestIid ? '!' + dep.mergeRequestIid : 'merge request';
  const description = [
    '## What Dynatrace detected',
    '',
    'Davis opened problem ' + link('**' + dep.displayId + ' — ' + dep.problemTitle + '**', dep.problemUrl) +
      ' on `' + dep.service + '` in production.',
    dep.rootCause ? 'Root cause entity: `' + dep.rootCause + '`.' : '',
    '',
    '## The deployment it points to',
    '',
    '| | |',
    '|---|---|',
    '| Service | `' + dep.service + '` |',
    '| Version | `' + dep.version + '` |',
    '| Commit | ' + link('`' + shortSha + '`', dep.commitUrl) + ' |',
    '| Merge request | ' + link(mr, dep.mergeRequestUrl) + ' |',
    '| Deploy pipeline | ' + link('pipeline', dep.pipelineUrl) + ' |',
    '| Deployed at | ' + (dep.deployedAt || 'unknown') + ' |',
    '',
    '## What was done automatically',
    '',
    '1. The Dynatrace workflow started the ' + link('rollback pipeline', rb.pipelineUrl) + '.',
    '2. The pipeline set production back to the previous version in `deploy/overlays/production`; ArgoCD synced it.',
    '3. Davis closes the problem on its own once the failure rate is back to normal.',
    '',
    '## Next steps',
    '',
    '- Look at the failing requests for `' + dep.service + '` in the ' + link('problem', dep.problemUrl) + ' (traces, logs, exceptions).',
    '- Fix the change from ' + link(mr, dep.mergeRequestUrl) + ' and open a new merge request — it goes through staging and the quality gate again.',
    '- If the quality gate should have caught this, tighten the objectives in `dynatrace/services.auto.tfvars`.',
    '',
    '_Opened by the Dynatrace auto-remediation workflow._',
  ].filter(function (l) { return l !== null; }).join('\n');

  const res = await gitlab('/projects/' + CFG.projectId + '/issues', {
    method: 'POST',
    body: JSON.stringify({
      title: 'Auto-remediation: ' + dep.service + ' ' + dep.version + ' rolled back in production (' + dep.displayId + ')',
      description: description,
      labels: 'dynatrace,auto-remediation',
      assignee_ids: assigneeIds,
    }),
  });
  const text = await res.text();
  console.log('GitLab create issue ' + res.status + ': ' + text);
  if (res.status !== 201) {
    throw new Error('Issue was not created (HTTP ' + res.status + ')');
  }
  const issue = JSON.parse(text);
  return { status: res.status, issueUrl: issue.web_url, issueIid: issue.iid };
}
