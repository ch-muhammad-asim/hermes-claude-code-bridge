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
  description = "Name of the EKS cluster."
  type        = string
  default     = "cloudgeeks-eks-dev"
}

variable "kubernetes_version" {
  description = <<-EOT
    Kubernetes control plane version. The sandbox only permits versions in EKS
    standard support - extended-support versions are blocked because they bill
    at a premium. Check with: aws eks describe-cluster-versions
  EOT
  type        = string
  default     = "1.36"
}

variable "cluster_support_type" {
  description = <<-EOT
    STANDARD or EXTENDED. STANDARD means AWS automatically upgrades the control
    plane when its Kubernetes version reaches end of standard support, which is
    both the cheaper option and the only one the sandbox allows. EXTENDED (the
    AWS default) keeps the cluster on an unsupported version and bills a premium
    for it.
  EOT
  type        = string
  default     = "STANDARD"

  validation {
    condition     = contains(["STANDARD", "EXTENDED"], var.cluster_support_type)
    error_message = "cluster_support_type must be STANDARD or EXTENDED."
  }
}

variable "environment" {
  description = "Environment name applied as a tag."
  type        = string
  default     = "dev"
}

variable "vpc_id" {
  description = "ID of the VPC the cluster is deployed into."
  type        = string
}

variable "subnet_ids" {
  description = "Private subnet IDs for the control plane ENIs and the node group."
  type        = list(string)

  validation {
    condition     = length(var.subnet_ids) >= 2
    error_message = "EKS requires subnets in at least two Availability Zones."
  }
}

variable "node_instance_types" {
  description = <<-EOT
    Instance types for the system managed node group. The sandbox only permits
    t2/t3/t3a/t4g in micro, small and medium sizes; t3.medium (2 vCPU / 4 GiB)
    is the largest allowed and the only size with enough room for system pods.
  EOT
  type        = list(string)
  default     = ["t3.medium", "t3a.medium"]
}

variable "node_min_size" {
  description = "Minimum size of the system node group."
  type        = number
  default     = 2
}

variable "node_max_size" {
  description = "Maximum size of the system node group."
  type        = number
  default     = 3
}

variable "node_desired_size" {
  description = <<-EOT
    Desired size of the system node group. The sandbox caps the account at nine
    concurrent EC2 instances, so leave headroom for the nodes Karpenter launches.
  EOT
  type        = number
  default     = 2
}

variable "node_use_latest_ami" {
  description = <<-EOT
    Move the system node group to the newest EKS-optimised AMI release on every
    apply. Managed node groups never patch themselves, so without this the
    system nodes keep whatever AMI they were created with until someone
    intervenes. The trade-off is that a new AMI release shows up as a node
    replacement in the next plan - which is the point, but run it through a
    pipeline rather than being surprised by it.
  EOT
  type        = bool
  default     = true
}

variable "node_disk_size" {
  description = "Root volume size in GiB. The sandbox caps volumes at 100 GiB."
  type        = number
  default     = 50

  validation {
    condition     = var.node_disk_size <= 100
    error_message = "The sandbox caps EBS volumes at 100 GiB."
  }
}

variable "endpoint_public_access_cidrs" {
  description = "CIDRs allowed to reach the public API server endpoint. Narrow this to your egress IP for anything beyond a sandbox."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "enabled_log_types" {
  description = "Control plane log types shipped to CloudWatch Logs. Empty keeps sandbox cost at zero."
  type        = list(string)
  default     = []
}

variable "create_iam_access_roles" {
  description = "Create the eks-admin / eks-developer assumable IAM roles and their access entries."
  type        = bool
  default     = true
}

variable "tags" {
  description = "Additional tags applied to every resource."
  type        = map(string)
  default     = {}
}
