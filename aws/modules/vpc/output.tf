output "vpc_id" {
  description = "ID of the VPC."
  value       = module.vpc.vpc_id
}

output "vpc_cidr_block" {
  description = "CIDR block of the VPC."
  value       = module.vpc.vpc_cidr_block
}

output "private_subnets" {
  description = "Private subnet IDs used by the EKS nodes and Karpenter."
  value       = module.vpc.private_subnets
}

output "public_subnets" {
  description = "Public subnet IDs used by internet-facing load balancers."
  value       = module.vpc.public_subnets
}

output "database_subnets" {
  description = "Database subnet IDs (empty unless enable_database_subnets is true)."
  value       = module.vpc.database_subnets
}

output "azs" {
  description = "Availability Zones the subnets are spread across."
  value       = module.vpc.azs
}

output "nat_public_ips" {
  description = "Public IPs of the NAT Gateways."
  value       = module.vpc.nat_public_ips
}
