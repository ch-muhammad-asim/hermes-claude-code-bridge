output "node_public_ip" {
  description = "Public IP of the k3s node. Point hermes.saqlainmushtaq.com at this."
  value       = aws_instance.node.public_ip
}

output "node_private_ip" {
  description = "Private IP of the k3s node."
  value       = aws_instance.node.private_ip
}

output "instance_id" {
  description = "EC2 instance id of the k3s node."
  value       = aws_instance.node.id
}

output "cluster_name" {
  description = "Name of the k3s cluster."
  value       = var.cluster_name
}

output "kubeconfig_s3_uri" {
  description = "Where the node publishes its kubeconfig. Fetch with: aws s3 cp <uri> ~/.kube/hermes-k3s"
  value       = "s3://${var.kubeconfig_bucket}/${var.kubeconfig_key}"
}

output "kubeconfig_fetch_command" {
  description = "Ready-to-run command that installs the kubeconfig locally."
  value       = "aws s3 cp s3://${var.kubeconfig_bucket}/${var.kubeconfig_key} $HOME/.kube/hermes-k3s --region ${var.region} && export KUBECONFIG=$HOME/.kube/hermes-k3s"
}

output "iam_role_arn" {
  description = "ARN of the node role carrying invoke-only Bedrock access."
  value       = aws_iam_role.node.arn
}

output "model_id" {
  description = "Bedrock model id the node role authorizes."
  value       = var.model_id
}

output "security_group_id" {
  description = "Security group protecting the node."
  value       = aws_security_group.node.id
}
