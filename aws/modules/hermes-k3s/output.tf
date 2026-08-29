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

output "dashboard_url" {
  description = "Hermes dashboard. Point the DNS name at node_public_ip first."
  value       = "https://hermes.saqlainmushtaq.com/"
}

output "credentials_command" {
  description = "Prints the generated dashboard password. Stored as an SSM SecureString by the node, so it never enters Terraform state or a log."
  value       = "aws ssm get-parameter --name ${var.ssm_prefix}/dashboard-password --with-decryption --region ${var.region} --query Parameter.Value --output text"
}

output "bridge_api_key_command" {
  description = "Prints the bridge API key (rarely needed - the pod reads it from its Secret)."
  value       = "aws ssm get-parameter --name ${var.ssm_prefix}/bridge-api-key --with-decryption --region ${var.region} --query Parameter.Value --output text"
}

output "bootstrap_log_command" {
  description = "Reads the node's bootstrap log without SSH, via SSM Session Manager."
  value       = "aws ssm start-session --target ${aws_instance.node.id} --region ${var.region}   # then: sudo tail -100 /var/log/hermes-k3s-bootstrap.log"
}

output "console_log_command" {
  description = "Fallback when the node never came up far enough for SSM to register."
  value       = "aws ec2 get-console-output --instance-id ${aws_instance.node.id} --region ${var.region} --output text | tail -80"
}

output "deployed_overlay" {
  description = "Kustomize overlay the node applied. Must stay aligned with model_id."
  value       = var.deploy_hermes ? var.hermes_overlay : "none (deploy_hermes = false)"
}
