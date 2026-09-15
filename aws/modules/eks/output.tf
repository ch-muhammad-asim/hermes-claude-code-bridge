output "cluster_name" {
  description = "Name of the EKS cluster."
  value       = module.eks.cluster_name
}

output "cluster_endpoint" {
  description = "Endpoint of the Kubernetes API server."
  value       = module.eks.cluster_endpoint
}

output "cluster_version" {
  description = "Kubernetes version running on the control plane."
  value       = module.eks.cluster_version
}

output "cluster_certificate_authority_data" {
  description = "Base64 encoded certificate data required to talk to the cluster."
  value       = module.eks.cluster_certificate_authority_data
}

output "cluster_security_group_id" {
  description = "Security group ID attached to the EKS control plane."
  value       = module.eks.cluster_security_group_id
}

output "node_security_group_id" {
  description = "Security group ID shared by the nodes, tagged for Karpenter discovery."
  value       = module.eks.node_security_group_id
}

output "oidc_provider_arn" {
  description = "ARN of the OIDC provider backing IRSA."
  value       = module.eks.oidc_provider_arn
}

output "eks_admin_role_arn" {
  description = "IAM role granting cluster-admin through an EKS access entry."
  value       = try(aws_iam_role.eks_admin[0].arn, null)
}

output "eks_developer_role_arn" {
  description = "IAM role granting read-only access through an EKS access entry."
  value       = try(aws_iam_role.eks_developer[0].arn, null)
}

output "configure_kubectl" {
  description = "Command that writes a kubeconfig entry for this cluster."
  value       = "aws eks update-kubeconfig --region ${var.region} --name ${module.eks.cluster_name}"
}
