output "quality_gate_workflow_ids" {
  description = "Service -> quality-gate workflow id (the pipeline runs these via the Automation API)"
  value       = { for svc, wf in dynatrace_automation_workflow.quality_gate : svc => wf.id }
}

output "guardian_ids" {
  description = "Service -> Site Reliability Guardian id"
  value       = { for svc, g in dynatrace_site_reliability_guardian.gate : svc => g.id }
}

output "remediation_workflow_id" {
  value = dynatrace_automation_workflow.remediation.id
}
