output "karpenter_node_iam_role_name" {
  description = "IAM role assumed by Karpenter-provisioned nodes."
  value       = module.karpenter.node_iam_role_name
}

output "karpenter_node_iam_role_arn" {
  description = "ARN of the IAM role assumed by Karpenter-provisioned nodes."
  value       = module.karpenter.node_iam_role_arn
}

output "karpenter_controller_iam_role_arn" {
  description = "ARN of the Karpenter controller role, associated through EKS Pod Identity."
  value       = module.karpenter.iam_role_arn
}

output "karpenter_interruption_queue_name" {
  description = "SQS queue Karpenter watches for interruption and maintenance events."
  value       = try(module.karpenter.queue_name, null)
}

output "karpenter_version" {
  description = "Deployed Karpenter chart version."
  value       = var.karpenter_version
}

output "node_pool_name" {
  description = "Name of the default NodePool."
  value       = kubectl_manifest.node_pool.name
}
