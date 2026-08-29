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

###############################################################################
# End-to-end bootstrap
#
# With deploy_hermes = true (the default) `terragrunt apply` returns a WORKING
# stack: k3s + Traefik + Hermes, not just an EC2 instance. Terraform waits for the
# node to report COMPLETE and fails the apply otherwise.
###############################################################################

variable "deploy_hermes" {
  description = "Install Traefik and the Hermes agent during bootstrap. false provisions a bare k3s cluster and stops after publishing the kubeconfig."
  type        = bool
  default     = true
}

variable "manifests_repo" {
  description = "Public Git repository the node clones the Kustomize manifests and Traefik values from."
  type        = string
  default     = "https://github.com/ch-muhammad-asim/hermes-claude-code-bridge.git"
}

variable "manifests_ref" {
  description = "Branch or tag to clone. Pin to a tag for a reproducible rebuild."
  type        = string
  default     = "main"
}

variable "hermes_overlay" {
  description = <<-EOT
    Kustomize overlay applied on the node, relative to the repo root.
      aws-bedrock/overlays/k3s            - Claude Sonnet 4.5 (the designed default)
      aws-bedrock/overlays/k3s-haiku-4-5  - Claude Haiku 4.5, for accounts with no
                                            Sonnet 4.5 Marketplace subscription
    Keep this aligned with var.model_id, or InvokeModel returns AccessDeniedException:
    the node role authorizes one specific model.
  EOT
  type        = string
  default     = "aws-bedrock/overlays/k3s"
}

variable "traefik_values" {
  description = "Traefik Helm values file, relative to the repo root."
  type        = string
  default     = "aws-bedrock/traefik/k3s-values.yaml"
}

variable "traefik_chart_version" {
  description = "traefik/traefik chart version. CRDs are installed from the same version so the two cannot drift."
  type        = string
  default     = "41.3.0"
}

variable "helm_version" {
  description = "Helm release installed on the node. Downloaded with its published sha256sum and verified."
  type        = string
  default     = "v3.16.0"
}

variable "hermes_image" {
  description = "Hermes image used to generate the dashboard password hash. MUST equal the image in the StatefulSet, or the hash is produced by a different build than the one verifying it."
  type        = string
  default     = "nousresearch/hermes-agent:v2026.8.3"
}

variable "ssm_prefix" {
  description = "SSM Parameter Store prefix for the generated dashboard password and bridge API key (SecureString)."
  type        = string
  default     = "/hermes/k3s"
}

variable "status_key" {
  description = "S3 key the node writes its bootstrap status to. Terraform polls it and fails the apply if it never reaches COMPLETE."
  type        = string
  default     = "k3s/bootstrap-status"
}

variable "bootstrap_timeout_minutes" {
  description = "How long to wait for the node to report COMPLETE. A full bootstrap (k3s + Traefik + image pulls + rollout) typically takes 5-8 minutes."
  type        = number
  default     = 20
}
