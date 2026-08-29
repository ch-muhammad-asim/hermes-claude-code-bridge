###############################################################################
# Hermes agent - single-node k3s cluster on EC2
#
# Substitute for the eks unit in accounts whose SCP denies eks:CreateCluster - the
# Pluralsight AI Cloud Sandbox does (p-2nwbuy01, an AWS Organizations explicit deny
# that a member account cannot override). Deploy the eks unit instead wherever it is
# permitted; everything layered on top is identical either way.
#
# Consumes the vpc unit's public subnet, and carries the Bedrock invoke permissions
# that hermes-bedrock-iam grants on EKS - on EC2 they ride on the instance profile,
# so the Hermes bridge needs no code change.
###############################################################################

include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "${get_parent_terragrunt_dir()}/../modules//hermes-k3s"
}

dependency "vpc" {
  config_path = "../vpc"

  mock_outputs = {
    vpc_id         = "vpc-00000000000000000"
    public_subnets = ["subnet-00000000000000002", "subnet-00000000000000003"]
  }

  mock_outputs_allowed_terraform_commands = ["validate", "plan", "init"]
}

inputs = {
  vpc_id = dependency.vpc.outputs.vpc_id

  # PUBLIC subnet: the node terminates ingress for hermes.saqlainmushtaq.com and is
  # the kubectl endpoint, so it needs a public IP.
  subnet_id = dependency.vpc.outputs.public_subnets[0]

  cluster_name  = "cloudgeeks-k3s-dev"
  instance_type = "t3.medium"

  # The Kubernetes API is reachable only from the operator's egress /32. Empty would
  # fail closed (no rule, no kubectl) rather than exposing 6443 to the internet.
  api_allowed_cidrs = ["182.189.178.172/32"]

  # 80/443 are public by design - that is the point of the ingress.
  ingress_allowed_cidrs = ["0.0.0.0/0"]

  # The node publishes its kubeconfig here (single-object s3:PutObject grant), so
  # reaching the cluster needs no SSH key and no inbound 22.
  kubeconfig_bucket = "cloudgeeks-eks-blueprints-tfstate-637423440646"
  kubeconfig_key    = "k3s/kubeconfig"

  # Claude Sonnet 4.5 is the intended default, but THIS sandbox account has no
  # AWS Marketplace subscription for it, and SCP p-sdxy6x4w denies
  # bedrock:CreateFoundationModelAgreement - so the subscription cannot be added
  # from inside the account. Haiku 4.5 is subscribed and works. Switch both lines
  # back to claude-sonnet-4-5-20250929 in any account that has the subscription.
  model_id            = "us.anthropic.claude-haiku-4-5-20251001-v1:0"
  foundation_model_id = "anthropic.claude-haiku-4-5-20251001-v1:0"
}
