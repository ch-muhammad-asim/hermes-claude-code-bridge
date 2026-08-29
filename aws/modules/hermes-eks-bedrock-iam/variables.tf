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
  description = "Name of the EKS cluster the Hermes agent runs in."
  type        = string
}

variable "namespace" {
  description = "Namespace the Hermes agent runs in."
  type        = string
  default     = "devops-agent"
}

variable "service_account" {
  description = "ServiceAccount the Hermes pod runs as. Must match rbac/serviceaccount.yaml, or Pod Identity will not bind and the bridge fails with AccessDeniedException."
  type        = string
  default     = "hermes-agent"
}

variable "model_id" {
  description = <<-EOT
    Bedrock model id the bridge invokes. Claude Sonnet 4.5 is INFERENCE_PROFILE-only,
    so this is a cross-region inference profile id, not a bare foundation-model id:
      aws bedrock list-foundation-models --query "modelSummaries[?contains(modelId,'sonnet-4-5')].inferenceTypesSupported"
  EOT
  type        = string
  default     = "us.anthropic.claude-sonnet-4-5-20250929-v1:0"
}

variable "foundation_model_id" {
  description = "The foundation model behind var.model_id. Invoking through a profile authorizes against BOTH the profile ARN and the underlying foundation model in every region the profile routes to."
  type        = string
  default     = "anthropic.claude-sonnet-4-5-20250929-v1:0"
}

variable "inference_profile_regions" {
  description = "Regions a `us.` cross-region profile may route inference to. Each needs a foundation-model ARN in the policy or Bedrock returns AccessDeniedException when it fails over."
  type        = list(string)
  default     = ["us-east-1", "us-east-2", "us-west-2"]
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
