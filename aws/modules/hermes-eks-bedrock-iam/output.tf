output "iam_role_arn" {
  description = "ARN of the Hermes agent's Bedrock role."
  value       = aws_iam_role.this.arn
}

output "iam_role_name" {
  description = "Name of the Hermes agent's Bedrock role."
  value       = aws_iam_role.this.name
}

output "iam_policy_arn" {
  description = "ARN of the invoke-only Bedrock policy."
  value       = aws_iam_policy.this.arn
}

output "model_id" {
  description = "Bedrock model id the policy authorizes. Must match ANTHROPIC_MODEL on the bridge sidecar."
  value       = var.model_id
}

output "service_account" {
  description = "ServiceAccount the Kustomize manifests must use for Pod Identity to apply."
  value       = "${var.namespace}/${var.service_account}"
}
