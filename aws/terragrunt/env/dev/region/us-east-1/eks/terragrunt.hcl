###############################################################################
# EKS - control plane, add-ons and the system managed node group
#
# ⚠️  NOT USABLE IN A PLURALSIGHT SANDBOX.
#
# Both the regular and the AI Cloud Sandbox deny eks:CreateCluster through an AWS
# Organizations service control policy:
#
#   AccessDeniedException: User: arn:aws:iam::<acct>:user/cloud_user is not
#   authorized to perform: eks:CreateCluster ... with an explicit deny in a
#   service control policy:
#   arn:aws:organizations::674998908974:policy/o-yu55c2titn/service_control_policy/p-2nwbuy01
#
# An SCP deny is evaluated above the account: the IAM user is *allowed* the action
# by its identity policy (aws iam simulate-principal-policy returns "allowed" -
# that call does not evaluate SCPs, so it is a red herring), but nothing inside a
# member account can override it, and member accounts cannot even read the policy.
#
# The deny is unconditional. Verified across Kubernetes 1.30/1.34/1.35/1.36 and the
# API default, authenticationMode API and CONFIG_MAP, tagged and untagged requests,
# EKS Auto Mode, us-east-1 and us-west-2, and multiple cluster names - in two
# separate sandbox accounts (381491923945 and 637423440646).
#
# Use ../hermes-k3s instead, which provisions a conformant single-node Kubernetes
# cluster on EC2 (RunInstances IS permitted). Everything layered above the cluster
# is identical. Deploy THIS unit only in an account whose SCP permits EKS.
###############################################################################

include "root" {
  path   = find_in_parent_folders("root.hcl")
  expose = true
}

terraform {
  source = "${include.root.locals.modules_dir}//eks"
}

dependency "vpc" {
  config_path = "../vpc"

  # Mocks let `terragrunt run --all plan` work before the VPC exists.
  mock_outputs = {
    vpc_id          = "vpc-00000000000000000"
    private_subnets = ["subnet-00000000000000000", "subnet-00000000000000001"]
    public_subnets  = ["subnet-00000000000000002", "subnet-00000000000000003"]
  }

  mock_outputs_allowed_terraform_commands = ["validate", "plan", "init"]
}

inputs = {
  vpc_id     = dependency.vpc.outputs.vpc_id
  subnet_ids = dependency.vpc.outputs.private_subnets

  # The sandbox permits t2/t3/t3a/t4g in micro, small and medium only.
  # t3.medium is the largest allowed and the smallest that comfortably holds
  # the system add-ons alongside the Karpenter controller.
  node_instance_types = ["t3.medium", "t3a.medium"]

  # The sandbox caps the account at nine concurrent EC2 instances. Two here
  # leaves room for the nodes Karpenter provisions.
  node_min_size     = 2
  node_max_size     = 3
  node_desired_size = 2
  node_disk_size    = 50

  # Narrow this to your egress CIDR outside a sandbox.
  endpoint_public_access_cidrs = ["0.0.0.0/0"]

  # Control plane logs cost money per GB ingested; enable the ones you will
  # actually read. ["audit", "authenticator"] is the usual production floor.
  enabled_log_types = []

  create_iam_access_roles = true

  ###########################################################################
  # Version support policy
  #
  # STANDARD  - AWS force-upgrades the cluster when its Kubernetes version
  #             reaches end of standard support. No extended-support charges.
  # EXTENDED  - the AWS default. The cluster stays on its version past end of
  #             standard support and bills a premium per cluster hour.
  #
  # What STANDARD does NOT do: it does not track new releases. It will not move
  # this cluster from 1.36 to 1.37 when 1.37 ships. It fires once, on 1.36's
  # end-of-standard-support date, and lands on whatever is in standard support
  # then. To upgrade before that, bump kubernetes_version in env/dev/env.hcl.
  #
  #   aws eks describe-cluster-versions \
  #     --query "clusterVersions[].{v:clusterVersion,eos:endOfStandardSupportDate}"
  ###########################################################################
  cluster_support_type = "STANDARD"
}
