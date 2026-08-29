###############################################################################
# VPC - three-AZ network with private subnets tagged for Karpenter discovery
###############################################################################

include "root" {
  path   = find_in_parent_folders("root.hcl")
  expose = true
}

terraform {
  source = "${include.root.locals.modules_dir}//vpc"
}

inputs = {
  vpc_cidr = "10.60.0.0/16"
  az_count = 3

  # One NAT Gateway instead of one per AZ. Sandbox-appropriate; flip to false
  # for production, where a single-AZ NAT outage takes out all egress.
  single_nat_gateway = true

  enable_database_subnets = false
  enable_flow_log         = false
}
