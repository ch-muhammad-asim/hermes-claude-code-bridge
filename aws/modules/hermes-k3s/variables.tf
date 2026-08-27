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
  description = "Name for the k3s cluster and its resources."
  type        = string
  default     = "cloudgeeks-k3s-dev"
}

variable "vpc_id" {
  description = "VPC to launch the node into."
  type        = string
}

variable "subnet_id" {
  description = "PUBLIC subnet. The node needs a public IP: it terminates ingress for hermes.saqlainmushtaq.com and is the kubectl endpoint."
  type        = string
}

variable "instance_type" {
  description = "The sandbox permits t2/t3/t3a/t4g in micro, small and medium only. t3.medium is the largest allowed and the smallest that holds k3s + Traefik + the Hermes pod."
  type        = string
  default     = "t3.medium"

  validation {
    condition     = can(regex("^t[234]a?g?\\.(micro|small|medium)$", var.instance_type))
    error_message = "The sandbox caps instances at t2/t3/t3a/t4g micro|small|medium."
  }
}

variable "root_volume_size" {
  description = "Root EBS size in GiB. Holds container images plus the Hermes state volume (local-path PVC)."
  type        = number
  default     = 50
}

variable "api_allowed_cidrs" {
  description = "CIDRs allowed to reach the k3s API on 6443. Defaults to nothing - set it to your egress /32 so the API is not world-readable."
  type        = list(string)
  default     = []
}

variable "ingress_allowed_cidrs" {
  description = "CIDRs allowed to reach 80/443. Public by design: this is what serves hermes.saqlainmushtaq.com."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "kubeconfig_bucket" {
  description = "Bucket the node writes its kubeconfig to, so no SSH key is needed to reach the cluster."
  type        = string
}

variable "kubeconfig_key" {
  description = "Object key for the kubeconfig."
  type        = string
  default     = "k3s/kubeconfig"
}

variable "model_id" {
  description = "Bedrock inference profile the Hermes bridge invokes. Claude Sonnet 4.5 is INFERENCE_PROFILE-only."
  type        = string
  default     = "us.anthropic.claude-sonnet-4-5-20250929-v1:0"
}

variable "foundation_model_id" {
  description = "Foundation model behind var.model_id. A cross-region profile authorizes against BOTH the profile and the foundation model in every region it routes to."
  type        = string
  default     = "anthropic.claude-sonnet-4-5-20250929-v1:0"
}

variable "inference_profile_regions" {
  description = "Regions a `us.` profile may route to. Each needs a foundation-model ARN or failover returns AccessDeniedException."
  type        = list(string)
  default     = ["us-east-1", "us-east-2", "us-west-2"]
}

variable "k3s_version_channel" {
  description = "k3s install channel. `stable` tracks the current stable minor."
  type        = string
  default     = "stable"
}

variable "environment" {
  description = "Environment name applied as a tag."
  type        = string
  default     = "dev"
}

variable "tags" {
  description = "Additional tags applied to every resource."
  type        = map(string)
  default     = {}
}
