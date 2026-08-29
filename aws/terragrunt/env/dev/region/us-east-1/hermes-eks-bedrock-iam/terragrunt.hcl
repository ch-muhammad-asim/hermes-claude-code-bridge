###############################################################################
# Hermes agent - Bedrock IAM role, invoke-only policy and Pod Identity association
#
# Consumed by the Hermes deployment in
# hermes-agent/aws-bedrock/kubernetes (applied with Kustomize).
#
# The Kubernetes side carries no credentials: the bridge sidecar picks the role up
# through EKS Pod Identity, so this unit is the only place Bedrock permissions are
# declared.
###############################################################################

include "root" {
  path   = find_in_parent_folders("root.hcl")
  expose = true
}

terraform {
  source = "${include.root.locals.modules_dir}//hermes-eks-bedrock-iam"
}

dependency "eks" {
  config_path = "../eks"

  mock_outputs = {
    cluster_name = "mock-cluster"
  }

  mock_outputs_allowed_terraform_commands = ["validate", "plan", "init"]
}

inputs = {
  cluster_name = dependency.eks.outputs.cluster_name

  # Must match rbac/serviceaccount.yaml in the Kustomize root, or Pod Identity does
  # not bind and the bridge fails with AccessDeniedException on InvokeModel.
  namespace       = "devops-agent"
  service_account = "hermes-agent"

  # Claude Sonnet 4.5 is INFERENCE_PROFILE-only on Bedrock - a bare
  # anthropic.claude-sonnet-4-5-* modelId is rejected with a ValidationException
  # telling you to use an inference profile. Keep this aligned with ANTHROPIC_MODEL
  # on the bedrock-claude-bridge sidecar.
  model_id            = "us.anthropic.claude-sonnet-4-5-20250929-v1:0"
  foundation_model_id = "anthropic.claude-sonnet-4-5-20250929-v1:0"
}
