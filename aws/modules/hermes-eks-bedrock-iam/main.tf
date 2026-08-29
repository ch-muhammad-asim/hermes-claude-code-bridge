###############################################################################
# Hermes agent - Bedrock invoke permissions
#
# The Hermes pod's bedrock-claude-bridge sidecar calls Bedrock with the AWS SDK's
# default credential chain. In-cluster that chain resolves to EKS Pod Identity, so
# the credentials are keyless and short-lived and there is no access key anywhere
# in Git or in a Kubernetes Secret.
#
# Pod Identity rather than IRSA, matching the rest of this blueprint (ebs-csi,
# karpenter, alb-controller): no OIDC trust policy to hand-maintain, and the
# association is a plain EKS API object.
#
# Least privilege: invoke only, only on the one model the agent is configured to
# use. No model-access management, no Bedrock Agents, no Knowledge Bases, no
# training or fine-tuning - none of which the sandbox permits anyway.
###############################################################################

data "aws_partition" "current" {}
data "aws_caller_identity" "current" {}

locals {
  tags = merge(
    {
      Environment = var.environment
      Terraform   = "true"
      Blueprint   = var.cluster_name
    },
    var.tags,
  )

  partition  = data.aws_partition.current.partition
  account_id = data.aws_caller_identity.current.account_id

  # A cross-region ("us.") inference profile is authorized against the profile ARN
  # in the calling region AND the foundation-model ARN in every region it may route
  # to. Listing only the profile yields AccessDeniedException the moment Bedrock
  # fails inference over to a sibling region.
  inference_profile_arns = [
    "arn:${local.partition}:bedrock:${var.region}:${local.account_id}:inference-profile/${var.model_id}",
  ]

  foundation_model_arns = [
    for r in var.inference_profile_regions :
    "arn:${local.partition}:bedrock:${r}::foundation-model/${var.foundation_model_id}"
  ]
}

data "aws_iam_policy_document" "invoke" {
  # The only mutating-shaped call the agent makes: model inference.
  statement {
    sid    = "InvokeConfiguredClaudeModel"
    effect = "Allow"

    actions = [
      "bedrock:InvokeModel",
      "bedrock:InvokeModelWithResponseStream",
    ]

    resources = concat(local.inference_profile_arns, local.foundation_model_arns)
  }

  # Read-only discovery, so the bridge's /health check and an operator's
  # troubleshooting can confirm the model resolves without invoking it (and
  # therefore without spending any of the sandbox's token allowance).
  statement {
    sid    = "DescribeModelsForHealthChecks"
    effect = "Allow"

    actions = [
      "bedrock:ListFoundationModels",
      "bedrock:GetFoundationModel",
      "bedrock:ListInferenceProfiles",
      "bedrock:GetInferenceProfile",
    ]

    resources = ["*"]
  }
}

resource "aws_iam_policy" "this" {
  name        = "${var.cluster_name}-hermes-bedrock-invoke"
  description = "Invoke-only Bedrock access for the Hermes agent (${var.model_id})"
  policy      = data.aws_iam_policy_document.invoke.json
  tags        = local.tags
}

data "aws_iam_policy_document" "pod_identity_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole", "sts:TagSession"]

    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "this" {
  name               = "${var.cluster_name}-hermes-agent-bedrock"
  description        = "Hermes agent Bedrock role assumed through EKS Pod Identity"
  assume_role_policy = data.aws_iam_policy_document.pod_identity_trust.json
  tags               = local.tags
}

resource "aws_iam_role_policy_attachment" "this" {
  role       = aws_iam_role.this.name
  policy_arn = aws_iam_policy.this.arn
}

# Binds the role to the Hermes ServiceAccount. The ServiceAccount does not need to
# exist yet - Kustomize creates it, and the association applies from the next pod
# start. Both containers in the pod share the credentials.
resource "aws_eks_pod_identity_association" "this" {
  cluster_name    = var.cluster_name
  namespace       = var.namespace
  service_account = var.service_account
  role_arn        = aws_iam_role.this.arn
  tags            = local.tags
}
