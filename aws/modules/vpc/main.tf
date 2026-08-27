#########
# EKS VPC
#########
# https://registry.terraform.io/modules/terraform-aws-modules/vpc/aws/latest

data "aws_availability_zones" "available" {
  state = "available"

  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

locals {
  azs = slice(data.aws_availability_zones.available.names, 0, var.az_count)

  # /20 per tier member keeps ~4090 usable IPs per private subnet, which matters
  # because the VPC CNI hands pod IPs out of the subnet itself.
  private_subnets  = [for i in range(var.az_count) : cidrsubnet(var.vpc_cidr, 4, i)]
  public_subnets   = [for i in range(var.az_count) : cidrsubnet(var.vpc_cidr, 8, i + 100)]
  database_subnets = var.enable_database_subnets ? [for i in range(var.az_count) : cidrsubnet(var.vpc_cidr, 8, i + 200)] : []

  tags = merge(
    {
      Environment = var.environment
      Terraform   = "true"
      Blueprint   = var.cluster_name
    },
    var.tags,
  )
}

module "vpc" {
  source  = "registry.terraform.io/terraform-aws-modules/vpc/aws"
  version = "~> 6.7"

  name = var.cluster_name
  cidr = var.vpc_cidr
  azs  = local.azs

  private_subnets  = local.private_subnets
  public_subnets   = local.public_subnets
  database_subnets = local.database_subnets

  create_database_subnet_group       = var.enable_database_subnets
  create_database_subnet_route_table = var.enable_database_subnets
  create_database_nat_gateway_route  = var.enable_database_subnets

  enable_nat_gateway     = true
  single_nat_gateway     = var.single_nat_gateway
  one_nat_gateway_per_az = !var.single_nat_gateway

  enable_dns_hostnames = true
  enable_dns_support   = true

  # Nodes are private-only; public subnets exist for the internet-facing load balancers.
  map_public_ip_on_launch = false

  enable_flow_log                      = var.enable_flow_log
  create_flow_log_cloudwatch_log_group = var.enable_flow_log
  create_flow_log_cloudwatch_iam_role  = var.enable_flow_log
  flow_log_max_aggregation_interval    = 60

  # https://aws.amazon.com/premiumsupport/knowledge-center/eks-vpc-subnet-discovery/
  # karpenter.sh/discovery is the tag key Karpenter v1 selects subnets on.
  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = "1"
    "karpenter.sh/discovery"          = var.cluster_name
  }

  public_subnet_tags = {
    "kubernetes.io/role/elb" = "1"
  }

  tags = local.tags
}
