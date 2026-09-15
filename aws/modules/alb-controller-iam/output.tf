output "iam_role_arn" {
  description = "ARN of the controller's IAM role."
  value       = aws_iam_role.this.arn
}

output "iam_role_name" {
  description = "Name of the controller's IAM role."
  value       = aws_iam_role.this.name
}

output "iam_policy_arn" {
  description = "ARN of the controller's IAM policy."
  value       = aws_iam_policy.this.arn
}

output "service_account" {
  description = "Service account the Helm release must use for Pod Identity to apply."
  value       = var.service_account
}
