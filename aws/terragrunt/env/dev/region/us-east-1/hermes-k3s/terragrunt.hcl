###############################################################################
# Hermes agent - single-node k3s cluster on EC2
#
# Substitute for the eks unit in accounts whose SCP denies eks:CreateCluster - the
# Pluralsight AI Cloud Sandbox does (p-2nwbuy01, an AWS Organizations explicit deny
# that a member account cannot override). Deploy the eks unit instead wherever it is
# permitted; everything layered on top is identical either way.
#
# Consumes the vpc unit's public subnet, and carries the Bedrock invoke permissions
# that hermes-eks-bedrock-iam grants on EKS - on EC2 they ride on the instance profile,
# so the Hermes bridge needs no code change.
###############################################################################

include "root" {
  path   = find_in_parent_folders("root.hcl")
  expose = true
}

terraform {
  source = "${include.root.locals.modules_dir}//hermes-k3s"
}

dependency "vpc" {
  config_path = "../vpc"

  mock_outputs = {
    vpc_id         = "vpc-00000000000000000"
    public_subnets = ["subnet-00000000000000002", "subnet-00000000000000003"]
  }

  mock_outputs_allowed_terraform_commands = ["validate", "plan", "init"]
}

locals {
  operator_cidr = get_env(
    "TG_OPERATOR_CIDR",
    "${trimspace(run_cmd("--terragrunt-quiet", "curl", "-s", "https://checkip.amazonaws.com"))}/32",
  )
}

inputs = {
  vpc_id = dependency.vpc.outputs.vpc_id

  # PUBLIC subnet: the node terminates ingress for hermes.saqlainmushtaq.com and is
  # the kubectl endpoint, so it needs a public IP.
  subnet_id = dependency.vpc.outputs.public_subnets[0]

  cluster_name  = "cloudgeeks-k3s-dev"
  instance_type = "t3.medium"

  # The Kubernetes API is reachable only from the operator's egress /32, DISCOVERED
  # at plan time rather than pinned. A hardcoded /32 goes stale the moment you change
  # network, and the failure is confusing: the apply succeeds and kubectl just hangs.
  #
  # Override for a fixed office/VPN range (and to avoid the lookup):
  #   export TG_OPERATOR_CIDR=203.0.113.0/24
  api_allowed_cidrs = [local.operator_cidr]

  # 80/443 are public by design - that is the point of the ingress.
  ingress_allowed_cidrs = ["0.0.0.0/0"]

  # The node publishes its kubeconfig here (single-object s3:PutObject grant), so
  # reaching the cluster needs no SSH key and no inbound 22.
  # Derived from account.hcl, NOT hardcoded. A hardcoded bucket silently points a
  # new sandbox's node at the previous account's bucket: k3s comes up, then every
  # upload fails with NoSuchBucket and the apply times out with no status object.
  kubeconfig_bucket = include.root.locals.state_bucket
  kubeconfig_key    = "k3s/kubeconfig"

  # Claude Sonnet 4.5 is the intended default, but THIS sandbox account has no
  # AWS Marketplace subscription for it, and SCP p-sdxy6x4w denies
  # bedrock:CreateFoundationModelAgreement - so the subscription cannot be added
  # from inside the account. Haiku 4.5 is subscribed and works. Switch both lines
  # back to claude-sonnet-4-5-20250929 in any account that has the subscription.
  model_id            = "us.anthropic.claude-haiku-4-5-20251001-v1:0"
  foundation_model_id = "anthropic.claude-haiku-4-5-20251001-v1:0"

  ###########################################################################
  # End-to-end bootstrap
  #
  # The node installs k3s, Traefik and Hermes itself and reports COMPLETE, and
  # Terraform waits for that - so `terragrunt apply` returns a working stack,
  # not just an EC2 instance. Set deploy_hermes = false for a bare cluster.
  #
  # hermes_overlay MUST match model_id above: the node role authorizes exactly
  # one model, so a mismatch fails at InvokeModel with AccessDeniedException.
  #   .../k3s            -> Sonnet 4.5 (the designed default)
  #   .../k3s-haiku-4-5  -> Haiku 4.5  (this sandbox: no Sonnet 4.5 subscription)
  ###########################################################################
  deploy_hermes  = true
  hermes_overlay = "aws-bedrock/overlays/k3s-haiku-4-5"

  # Pin to a tag instead of a branch for a byte-reproducible rebuild.
  manifests_ref = "main"

  bootstrap_timeout_minutes = 20
}
