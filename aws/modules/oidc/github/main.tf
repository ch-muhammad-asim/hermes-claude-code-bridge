###############################################################################
# GitHub Actions OIDC federation
#
# Lets a workflow assume an AWS role with a short-lived token minted by GitHub,
# so there are no long-lived access keys in repository secrets.
###############################################################################

locals {
  # v3 of the upstream module takes OIDC *subjects*, not repository names, which
  # is what lets you scope a role to a branch or environment rather than to the
  # whole repository. "org/repo:*" reproduces the old repository-wide behaviour.
  github_subjects = length(var.github_subjects) > 0 ? var.github_subjects : [for repo in var.github_repos : "${repo}:*"]
}

module "github_oidc" {
  source  = "unfunco/oidc-github/aws"
  version = "~> 3.0"

  github_subjects = local.github_subjects

  create_oidc_provider = var.create_oidc_provider

  iam_role_name                 = var.iam_role_name
  iam_role_max_session_duration = var.max_session_duration

  # Least privilege: push to ECR and nothing else. Add to this deliberately.
  iam_role_inline_policies = {
    github_ecr_push_permissions = jsonencode({
      Version = "2012-10-17"
      Statement = [
        {
          Effect = "Allow"
          Action = [
            "ecr:GetAuthorizationToken",
          ]
          Resource = "*"
        },
        {
          Effect = "Allow"
          Action = [
            "ecr:BatchCheckLayerAvailability",
            "ecr:InitiateLayerUpload",
            "ecr:UploadLayerPart",
            "ecr:CompleteLayerUpload",
            "ecr:PutImage",
          ]
          Resource = var.ecr_repository_arns
        },
      ]
    })
  }

  tags = var.tags
}
