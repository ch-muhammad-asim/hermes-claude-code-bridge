###############################################################################
# Karpenter - controller, interruption queue, EC2NodeClass and NodePool
###############################################################################

include "root" {
  path   = find_in_parent_folders("root.hcl")
  expose = true
}

terraform {
  source = "${include.root.locals.modules_dir}//karpenter"
}

dependency "eks" {
  config_path = "../eks"

  mock_outputs = {
    cluster_name                       = "mock-cluster"
    cluster_endpoint                   = "https://mock.eks.amazonaws.com"
    cluster_certificate_authority_data = "bW9jaw=="
  }

  mock_outputs_allowed_terraform_commands = ["validate", "plan", "init"]
}

inputs = {
  cluster_name                       = dependency.eks.outputs.cluster_name
  cluster_endpoint                   = dependency.eks.outputs.cluster_endpoint
  cluster_certificate_authority_data = dependency.eks.outputs.cluster_certificate_authority_data

  # Must satisfy the Karpenter/Kubernetes compatibility matrix:
  # https://karpenter.sh/docs/upgrading/compatibility/
  karpenter_version = "1.14.1"

  ###########################################################################
  # NodePool shape - pinned to what the sandbox allows
  ###########################################################################
  instance_families = ["t3", "t3a"]
  instance_sizes    = ["small", "medium"]

  # The sandbox will not support EC2 Spot. Outside it, put "spot" first and let
  # Karpenter fall back to on-demand when spot capacity is unavailable.
  capacity_types = ["on-demand"]

  # The binding sandbox limit is instance COUNT (nine account-wide), not vCPU.
  # Karpenter bin-packs onto the cheapest shape that fits, which is usually
  # t3a.small at 2 vCPU - so a 12 vCPU ceiling permits SIX nodes, and with the
  # two-node system group that reaches eight. Too close to the cap.
  #
  # 8 vCPU caps Karpenter at four t3a.small, for six instances in total.
  node_cpu_limit    = 8
  node_memory_limit = "32Gi"
  node_disk_size    = "50Gi"

  node_expire_after = "168h"
  consolidate_after = "1m"

  enable_interruption_queue = true
}
