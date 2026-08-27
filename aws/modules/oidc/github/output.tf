output "iam_role_arn" {
  description = "ARN of the role GitHub Actions assumes."
  value       = module.github_oidc.iam_role_arn
}

output "iam_role_name" {
  description = "Name of the role GitHub Actions assumes."
  value       = module.github_oidc.iam_role_name
}

output "oidc_provider_arn" {
  description = "ARN of the GitHub OIDC provider."
  value       = module.github_oidc.oidc_provider_arn
}
