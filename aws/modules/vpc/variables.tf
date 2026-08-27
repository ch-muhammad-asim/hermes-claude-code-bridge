variable "region" {
  description = "AWS region. The Pluralsight sandbox only permits us-east-1 and us-west-2."
  type        = string
  default     = "us-east-1"

  validation {
    condition     = contains(["us-east-1", "us-west-2"], var.region)
    error_message = "The sandbox restricts actions to us-east-1 and us-west-2."
  }
}

variable "cluster_name" {
  description = "Name of the EKS cluster this VPC is built for. Drives subnet discovery tags."
  type        = string
  default     = "cloudgeeks-eks-dev"
}

variable "environment" {
  description = "Environment name applied as a tag."
  type        = string
  default     = "dev"
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC."
  type        = string
  default     = "10.60.0.0/16"
}

variable "az_count" {
  description = "Number of Availability Zones to spread subnets across."
  type        = number
  default     = 3

  validation {
    condition     = var.az_count >= 2 && var.az_count <= 3
    error_message = "EKS requires at least 2 AZs; 3 is the practical maximum for this blueprint."
  }
}

variable "single_nat_gateway" {
  description = "Use one NAT Gateway for all private subnets. True keeps sandbox cost down; set false for production HA."
  type        = bool
  default     = true
}

variable "enable_database_subnets" {
  description = "Create a dedicated database subnet tier and subnet group."
  type        = bool
  default     = false
}

variable "enable_flow_log" {
  description = "Enable VPC flow logs to CloudWatch Logs."
  type        = bool
  default     = false
}

variable "tags" {
  description = "Additional tags applied to every resource."
  type        = map(string)
  default     = {}
}
