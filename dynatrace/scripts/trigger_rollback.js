// trigger_rollback — start the GitLab rollback pipeline for the deployment found by find_deployment.
// Rendered by Terraform (remediation.tf); CFG is injected as JSON.
import { execution } from '@dynatrace-sdk/automation-utils';

const CFG = ${cfg};

export default async function ({ execution_id }) {
  const exec = await execution(execution_id);
  const dep = await exec.result('find_deployment');

  const url = CFG.gitlabUrl + '/api/v4/projects/' + CFG.projectId + '/pipeline';
  const response = await fetch(url, {
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
        { key: 'ROLLBACK_SERVICE', value: dep.service },
        // Idempotency: only roll back if production still runs this version.
        { key: 'ROLLBACK_FROM_VERSION', value: dep.version },
        { key: 'DT_PROBLEM_ID', value: dep.displayId },
        { key: 'DT_PROBLEM_URL', value: dep.problemUrl },
      ],
    }),
  });

  const text = await response.text();
  console.log('GitLab create pipeline ' + response.status + ': ' + text);
  if (response.status !== 201) {
    throw new Error('Rollback pipeline was not created (HTTP ' + response.status + ')');
  }

  const body = JSON.parse(text);
  return { status: response.status, pipelineId: body.id, pipelineUrl: body.web_url };
}
