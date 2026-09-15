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

  ###########################################################################
  # Module root, resolved once
  #
  # root.hcl lives at <blueprint>/terragrunt/root.hcl, so two dirname() hops
  # land on the blueprint directory that also holds modules/. Units then say:
  #
  #   include "root" {
  #     path   = find_in_parent_folders("root.hcl")
  #     expose = true
  #   }
  #   terraform { source = "${include.root.locals.modules_dir}//vpc" }
  #
  # rather than counting ../ hops from wherever they happen to sit. That
  # relative counting is what broke when aws/ was vendored into a larger repo:
  # get_repo_root() started resolving to the OUTER repo, and every unit failed
  # to init. Defining the path once, relative to this file, survives both
  # vendoring and any change to the env/region directory depth.
  ###########################################################################
  blueprint_dir = dirname(dirname(find_in_parent_folders("root.hcl")))
  modules_dir   = "${local.blueprint_dir}/modules"

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

  # kms_key_id is merged in only when a CMK is configured. Sending an empty or
  # nonexistent alias makes every state write fail with NotFoundException.
  config = merge(
    {
      bucket       = local.state_bucket
      key          = "${path_relative_to_include()}/terraform.tfstate"
      region       = local.aws_region
      encrypt      = true
      use_lockfile = true

      s3_bucket_tags = {
        Name        = "terraform-state"
        Environment = local.environment
        ManagedBy   = "terragrunt"
        Blueprint   = local.cluster_name
      }
    },
    local.state_kms_key != "" ? { kms_key_id = local.state_kms_key } : {},
  )

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

###############################################################################
# Backend bootstrap
#
# Terragrunt 1.x no longer creates the state bucket implicitly - it wants
# --backend-bootstrap (or TG_BACKEND_BOOTSTRAP=true) on every command. Relying on
# an env var means a fresh clone or a reissued sandbox fails on the first init
# with "NoSuchBucket", which is exactly the toil this blueprint removes elsewhere.
#
# This hook runs `terragrunt backend bootstrap` for the current unit immediately
# before `terraform init`, so the bucket is created (versioned, SSE-KMS,
# public-access-blocked, TLS-only) by Terragrunt itself on first use, and is a
# no-op every time after. `backend bootstrap` does not invoke `init`, so there is
# no recursion.
#
# Best-effort (`|| true`) on purpose. `backend bootstrap` re-parses the unit
# WITHOUT dependency resolution, so on a unit carrying a `dependency` block it
# aborts with `There is no variable named "dependency"`. There is no flag to
# disable that parsing. Letting the hook fail softly there is correct rather than
# merely convenient: every such unit depends on `vpc`, `vpc` has no dependencies
# and therefore always bootstraps successfully, and it is always applied first -
# so by the time a dependent unit initialises, the bucket already exists.
#
# The one gap: running a dependent unit standalone in a brand-new account before
# `vpc`. That still fails, but with the plain, accurate `NoSuchBucket` error and
# Terragrunt's own hint, not a misleading parse error.
###############################################################################
terraform {
  before_hook "bootstrap_backend" {
    commands = ["init"]
    execute = ["bash", "-c",
      "terragrunt backend bootstrap --non-interactive --working-dir '${get_terragrunt_dir()}' >/dev/null 2>&1 || true",
    ]
  }
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
