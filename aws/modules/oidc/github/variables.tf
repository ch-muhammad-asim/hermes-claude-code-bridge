variable "github_repos" {
  description = "GitHub repositories in org/repo form. Expanded to org/repo:* subjects. Prefer github_subjects for branch- or environment-scoped trust."
  type        = list(string)
  default     = []
}

variable "github_subjects" {
  description = <<-EOT
    OIDC subjects to trust, e.g. "org/repo:ref:refs/heads/main" or
    "org/repo:environment:production". Takes precedence over github_repos.
  EOT
  type        = list(string)
  default     = []
}

variable "create_oidc_provider" {
  description = "Create the GitHub OIDC provider. Set false when the account already has one - AWS permits only a single provider per URL."
  type        = bool
  default     = true
}

variable "iam_role_name" {
  description = "Name of the IAM role GitHub Actions assumes."
  type        = string
  default     = "github-actions-role"
}

variable "max_session_duration" {
  description = "Maximum session duration in seconds for the assumed role."
  type        = number
  default     = 3600
}

variable "ecr_repository_arns" {
  description = "ECR repositories the role may push to. Defaults to every repository in the account; narrow this in production."
  type        = list(string)
  default     = ["*"]
}

variable "tags" {
  description = "Tags applied to the role and provider."
  type        = map(string)
  default     = {}
}
