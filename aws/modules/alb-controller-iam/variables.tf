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
  description = "Name of the EKS cluster the controller runs in."
  type        = string
}

variable "namespace" {
  description = "Namespace the controller is installed into."
  type        = string
  default     = "kube-system"
}

variable "service_account" {
  description = "Service account the controller runs as. Must match the Helm release's serviceAccount.name."
  type        = string
  default     = "aws-load-balancer-controller"
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
