locals {
  account_name   = "cloudgeeks"
  aws_account_id = "637423440646"

  # Bootstrapped outside Terraform - state storage should not live in the state
  # it stores. See docs/BOOTSTRAP.md for the exact commands.
  state_bucket  = "cloudgeeks-eks-blueprints-tfstate-637423440646"
  state_kms_key = "alias/terraform-state"
}
