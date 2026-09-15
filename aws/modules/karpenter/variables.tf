variable "region" {
  description = "AWS region. The Pluralsight sandbox only permits us-east-1 and us-west-2."
  type        = string
  default     = "us-east-1"

  validation {
    condition     = contains(["us-east-1", "us-west-2"], var.region)
    error_message = "The sandbox restricts actions to us-east-1 and us-west-2."
  }
}

variable "environment" {
  description = "Environment name applied as a tag."
  type        = string
  default     = "dev"
}

variable "cluster_name" {
  description = "Name of the EKS cluster Karpenter provisions capacity for."
  type        = string
}

variable "cluster_endpoint" {
  description = "Endpoint of the Kubernetes API server."
  type        = string
}

variable "cluster_certificate_authority_data" {
  description = "Base64 encoded cluster CA certificate."
  type        = string
}

variable "karpenter_version" {
  description = "Karpenter Helm chart / controller version. Must satisfy the Karpenter-to-Kubernetes compatibility matrix: https://karpenter.sh/docs/upgrading/compatibility/"
  type        = string
  default     = "1.14.1"
}

variable "use_inline_controller_policy" {
  description = <<-EOT
    Attach the Karpenter controller permissions as an inline role policy rather
    than a standalone managed policy. Standard IAM policies cap at 6,144
    characters and the generated controller policy exceeds that, so
    CreatePolicy fails with "LimitExceeded: Cannot exceed quota for
    PolicySize". Inline policies allow 10,240 characters.
  EOT
  type        = bool
  default     = true
}

variable "karpenter_namespace" {
  description = "Namespace the Karpenter controller runs in."
  type        = string
  default     = "kube-system"
}

variable "karpenter_replicas" {
  description = "Karpenter controller replicas. Two gives leader-election failover; the chart spreads them across nodes."
  type        = number
  default     = 2
}

variable "enable_interruption_queue" {
  description = <<-EOT
    Create the SQS interruption queue and EventBridge rules. Karpenter uses them
    to drain nodes ahead of spot interruptions, rebalance recommendations,
    instance state changes and AWS scheduled maintenance events. Worth keeping
    on even without spot, for the scheduled-change and state-change paths.
  EOT
  type        = bool
  default     = true
}

###############################################################################
# NodePool shape
#
# Defaults are pinned to what the Pluralsight sandbox actually allows:
#   - t2/t3/t3a/t4g in micro, small and medium only
#   - no EC2 Spot
#   - nine concurrent EC2 instances account-wide (system node group included)
#   - EBS volumes no larger than 100 GiB
###############################################################################

variable "instance_families" {
  description = "Instance families Karpenter may provision. Keep to families the sandbox allows."
  type        = list(string)
  default     = ["t3", "t3a"]
}

variable "instance_sizes" {
  description = "Instance sizes Karpenter may provision. The sandbox permits micro, small and medium only."
  type        = list(string)
  default     = ["small", "medium"]

  validation {
    condition     = alltrue([for s in var.instance_sizes : contains(["nano", "micro", "small", "medium"], s)])
    error_message = "The sandbox only permits micro, small and medium (nano where the family offers it)."
  }
}

variable "capacity_types" {
  description = <<-EOT
    Capacity types Karpenter may request. The sandbox will not support EC2 Spot,
    so this stays on-demand there. Outside the sandbox, put "spot" first and let
    Karpenter fall back to on-demand.
  EOT
  type        = list(string)
  default     = ["on-demand"]
}

variable "node_cpu_limit" {
  description = <<-EOT
    Ceiling on total vCPU Karpenter may provision.

    Size this against instance COUNT, not vCPU. Karpenter picks the cheapest
    shape that fits, which in this NodePool is t3a.small at 2 vCPU - so every
    2 vCPU of limit is another EC2 instance. 8 vCPU is four nodes, which with
    the two-node system group leaves three instances of headroom under the
    sandbox's nine-instance cap.
  EOT
  type        = number
  default     = 8
}

variable "node_memory_limit" {
  description = "Ceiling on total memory Karpenter may provision."
  type        = string
  default     = "32Gi"
}

variable "node_disk_size" {
  description = "Root volume size for Karpenter nodes. The sandbox caps volumes at 100 GiB."
  type        = string
  default     = "50Gi"
}

variable "node_expire_after" {
  description = "Maximum node lifetime before Karpenter rotates it. Forced rotation keeps AMIs and kernels current."
  type        = string
  default     = "168h"
}

variable "consolidate_after" {
  description = "How long a node must sit empty or underutilised before Karpenter consolidates it."
  type        = string
  default     = "1m"
}

variable "ami_alias" {
  description = "EC2NodeClass AMI alias. Pin to a specific version (al2023@v20260801) for production instead of @latest."
  type        = string
  default     = "al2023@latest"
}

variable "tags" {
  description = "Additional tags applied to every resource."
  type        = map(string)
  default     = {}
}

variable "disruption_budget_nodes" {
  description = <<-EOT
    How many nodes Karpenter may disrupt at once. Percentage budgets round down,
    so on a small cluster "10%" evaluates to zero and silently blocks all
    consolidation - an explicit node count is safer here.
  EOT
  type        = string
  default     = "1"
}
