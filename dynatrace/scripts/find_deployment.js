// find_deployment — which production deployment does this Davis problem belong to?
// Rendered by Terraform (remediation.tf); CFG is injected as JSON.
import { queryExecutionClient } from '@dynatrace-sdk/client-query';

const CFG = ${cfg};

function dqlString(s) {
  return '"' + String(s).replace(/\\/g, '\\\\').replace(/"/g, '\\"') + '"';
}

async function runDql(query) {
  const started = await queryExecutionClient.queryExecute({
    body: { query: query, requestTimeoutMilliseconds: 30000 },
  });
  if (started.result) return started.result.records || [];
  for (let i = 0; i < 60; i++) {
    const polled = await queryExecutionClient.queryPoll({
      requestToken: started.requestToken,
      requestTimeoutMilliseconds: 5000,
    });
    if (polled.state === 'SUCCEEDED') return (polled.result && polled.result.records) || [];
    if (polled.state === 'FAILED' || polled.state === 'CANCELLED') {
      throw new Error('DQL query ' + polled.state);
    }
  }
  throw new Error('DQL query timed out');
}

export default async function ({ execution_id }) {
  const ex = await fetch('/platform/automation/v1/executions/' + execution_id);
  const data = await ex.json();
  const event = (data.params && data.params.event) || {};

  const problemId = event['event.id'] || '';
  const displayId = event['display_id'] || event['event.display_id'] || problemId;
  const problemTitle = event['event.name'] || 'Unknown problem';
  const problemUrl = CFG.appsUrl + '/ui/apps/dynatrace.davis.problems/problem/' + problemId;
  const rootCause = event['root_cause_entity_name'] || event['root_cause_entity_id'] || '';

  const entityIds = []
    .concat(event['affected_entity_ids'] || [])
    .concat(event['root_cause_entity_id'] ? [event['root_cause_entity_id']] : [])
    .filter(function (v, i, a) { return v && a.indexOf(v) === i; });

  const notFound = { found: false, problemId: problemId, displayId: displayId, problemTitle: problemTitle };
  if (entityIds.length === 0) {
    console.log('Problem ' + displayId + ' has no affected entities — not ours, skipping.');
    return notFound;
  }

  const query = [
    'fetch events, from: now()-6h',
    '| filter event.type == "CUSTOM_DEPLOYMENT"',
    '| filter deployment.release_product == ' + dqlString(CFG.releaseProduct),
    '| filter deployment.release_stage == "production"',
    '| filter k8s.cluster.name == ' + dqlString(CFG.cluster),
    '| filter in(toString(dt.source_entity), array(' + entityIds.map(dqlString).join(', ') + '))',
    '| sort timestamp desc',
    '| limit 1',
    '| fields timestamp, service.name, deployment.name, deployment.version, git.commit.sha, git.commit.url,',
    '         gitlab.merge_request.url, gitlab.merge_request.iid, gitlab.merge_request.author, gitlab.pipeline.url',
  ].join('\n');

  const records = await runDql(query);
  if (records.length === 0) {
    console.log('No ' + CFG.releaseProduct + ' production deployment on ' + CFG.cluster +
      ' matches problem ' + displayId + ' — not ours, skipping.');
    return notFound;
  }

  const d = records[0];
  // The latest production change is already a rollback: this problem is the
  // tail of the incident we just remediated — never roll back twice.
  if (String(d['deployment.name'] || '').endsWith(' rollback')) {
    console.log('Latest production change for problem ' + displayId + ' is already a rollback (' +
      d['deployment.version'] + ') — skipping.');
    return notFound;
  }
  const result = {
    found: true,
    service: d['service.name'],
    version: d['deployment.version'],
    commit: d['git.commit.sha'],
    commitUrl: d['git.commit.url'],
    mergeRequestUrl: d['gitlab.merge_request.url'],
    mergeRequestIid: d['gitlab.merge_request.iid'],
    mergeRequestAuthor: d['gitlab.merge_request.author'],
    pipelineUrl: d['gitlab.pipeline.url'],
    deployedAt: d['timestamp'],
    problemId: problemId,
    displayId: displayId,
    problemTitle: problemTitle,
    problemUrl: problemUrl,
    rootCause: rootCause,
  };
  console.log('Problem ' + displayId + ' -> ' + result.service + ' ' + result.version + ' (commit ' + result.commit + ')');
  return result;
}
