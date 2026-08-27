###############################################################################
# Terragrunt root configuration
#
# Every unit includes this file. It owns the three things that must never be
# copy-pasted per unit: remote state, provider configuration and common inputs.
#
#   include "root" {
#     path = find_in_parent_folders("root.hcl")
#   }
###############################################################################

locals {
  account_vars = read_terragrunt_config(find_in_parent_folders("account.hcl"))
  env_vars     = read_terragrunt_config(find_in_parent_folders("env.hcl"))
  region_vars  = read_terragrunt_config(find_in_parent_folders("region.hcl"))

  account_name   = local.account_vars.locals.account_name
  aws_account_id = local.account_vars.locals.aws_account_id
  state_bucket   = local.account_vars.locals.state_bucket
  state_kms_key  = local.account_vars.locals.state_kms_key

  environment = local.env_vars.locals.environment
  aws_region  = local.region_vars.locals.aws_region

  cluster_name = local.env_vars.locals.cluster_name

  common_tags = {
    Environment = local.environment
    Terraform   = "true"
    ManagedBy   = "terragrunt"
    Blueprint   = local.cluster_name
  }
}

###############################################################################
# Remote state
#
# S3 native locking (use_lockfile) replaces the DynamoDB lock table: one less
# resource to bootstrap, one less thing to pay for, and no lock table drift.
###############################################################################
remote_state {
  backend = "s3"

  config = {
    bucket       = local.state_bucket
    key          = "${path_relative_to_include()}/terraform.tfstate"
    region       = local.aws_region
    encrypt      = true
    use_lockfile = true

    kms_key_id = local.state_kms_key
  }

  generate = {
    path      = "backend.tf"
    if_exists = "overwrite_terragrunt"
  }
}

###############################################################################
# Providers
#
# Generated rather than committed, so the modules stay provider-agnostic and can
# be consumed from any region or account without editing them.
###############################################################################
generate "provider" {
  path      = "provider.tf"
  if_exists = "overwrite_terragrunt"

  contents = <<-EOF
    provider "aws" {
      region = "${local.aws_region}"

      default_tags {
        tags = {
          Environment = "${local.environment}"
          Terraform   = "true"
          ManagedBy   = "terragrunt"
          Blueprint   = "${local.cluster_name}"
        }
      }
    }
  EOF
}

# Fail fast if someone points this at an account that is not the sandbox.
generate "account_guard" {
  path      = "account_guard.tf"
  if_exists = "overwrite_terragrunt"

  contents = <<-EOF
    data "aws_caller_identity" "guard" {}

    resource "terraform_data" "account_guard" {
      lifecycle {
        precondition {
          condition     = data.aws_caller_identity.guard.account_id == "${local.aws_account_id}"
          error_message = "Wrong AWS account: expected ${local.aws_account_id}."
        }
      }
    }
  EOF
}

# Retry the handful of AWS failures that are genuinely transient.
errors {
  retry "transient_aws" {
    retryable_errors = [
      "(?s).*RequestError.*",
      "(?s).*Throttling.*",
      "(?s).*timeout while waiting for state.*",
    ]
    max_attempts       = 3
    sleep_interval_sec = 20
  }
}

inputs = merge(
  local.account_vars.locals,
  local.region_vars.locals,
  local.env_vars.locals,
  {
    tags = local.common_tags
  },
)
