// rollback_staging — act on the Site Reliability Guardian verdict for a staging
// deployment: on FAIL, start the GitLab rollback pipeline for staging (ArgoCD
// syncs the previous version). The release pipeline reads the same verdict and
// does not promote to production.
// Rendered by Terraform (service.tf); CFG is injected as JSON.
import { execution } from '@dynatrace-sdk/automation-utils';

const CFG = ${cfg};

function first(obj, keys) {
  for (const k of keys) {
    if (obj && obj[k] !== undefined && obj[k] !== null && obj[k] !== '') return obj[k];
  }
  return undefined;
}

export default async function ({ execution_id }) {
  const exec = await execution(execution_id);

  // Deployment event that triggered this validation
  const exResp = await fetch('/platform/automation/v1/executions/' + execution_id);
  const exData = await exResp.json();
  const event = (exData.params && exData.params.event) || {};
  const version = event['deployment.version'] || 'unknown';

  let srg = {};
  try {
    srg = (await exec.result('validate')) || {};
  } catch (e) {
    console.log('No validation result available: ' + e);
  }
  const verdict = String(first(srg, ['validation_status', 'status']) || 'error').toLowerCase();
  const executionUrl = CFG.appsUrl + '/ui/apps/dynatrace.automations/executions/' + execution_id;
  console.log('Guardian verdict for ' + CFG.service + ' ' + version + ' in staging: ' + verdict);

  if (verdict === 'pass' || verdict === 'warning') {
    return { rolledBack: false, verdict: verdict, version: version, executionUrl: executionUrl };
  }

  const response = await fetch(CFG.gitlabUrl + '/api/v4/projects/' + CFG.projectId + '/pipeline', {
    method: 'POST',
    headers: {
      'Accept': 'application/json',
      'Content-Type': 'application/json',
      'PRIVATE-TOKEN': CFG.gitlabPat,
    },
    body: JSON.stringify({
      ref: 'main',
      variables: [
        { key: 'ROLLBACK', value: 'true' },
        { key: 'ROLLBACK_STAGE', value: 'staging' },
        { key: 'ROLLBACK_SERVICE', value: CFG.service },
        { key: 'ROLLBACK_REASON', value: 'Site Reliability Guardian: ' + verdict.toUpperCase() + ' for ' + version },
        { key: 'DT_VALIDATION_URL', value: executionUrl },
      ],
    }),
  });
  const text = await response.text();
  let pipelineUrl = null;
  try { pipelineUrl = JSON.parse(text).web_url || null; } catch (e) { /* non-JSON error body */ }
  console.log('GitLab staging rollback pipeline: HTTP ' + response.status + ' ' + (pipelineUrl || text.slice(0, 300)));
  if (response.status !== 201) {
    throw new Error('GitLab rollback pipeline failed: HTTP ' + response.status + ' ' + text.slice(0, 300));
  }
  return { rolledBack: true, verdict: verdict, version: version, executionUrl: executionUrl, pipelineUrl: pipelineUrl };
}
