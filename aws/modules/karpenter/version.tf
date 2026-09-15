terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 3.0"
    }
    kubectl = {
      # Maintained fork of gavinbunney/kubectl. Applies raw CRs (NodePool,
      # EC2NodeClass) without the plan-time cluster reachability requirement
      # that makes kubernetes_manifest painful in a layered stack.
      source  = "alekc/kubectl"
      version = "~> 2.1"
    }
  }
}
