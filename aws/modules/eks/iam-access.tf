###############################################################################
# Cluster access - assumable IAM roles mapped through EKS access entries
#
# The v19 blueprint wired these in through the aws-auth ConfigMap and a stack of
# IAM sub-modules. Access entries replace all of it: no ConfigMap to corrupt, no
# Kubernetes provider needed just to grant access, and AWS-managed access
# policies instead of hand-written RBAC.
###############################################################################

data "aws_iam_policy_document" "account_assume_role" {
  count = var.create_iam_access_roles ? 1 : 0

  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "AWS"
      identifiers = ["arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:root"]
    }
  }
}

data "aws_iam_policy_document" "eks_console_access" {
  count = var.create_iam_access_roles ? 1 : 0

  # Enough to list and open the cluster in the console; the Kubernetes-side
  # permissions come from the access entry, not from IAM.
  statement {
    effect    = "Allow"
    actions   = ["eks:DescribeCluster", "eks:ListClusters", "eks:AccessKubernetesApi"]
    resources = ["*"]
  }
}

resource "aws_iam_role" "eks_admin" {
  count = var.create_iam_access_roles ? 1 : 0

  name               = "eks-admin-${var.cluster_name}"
  description        = "Cluster administrator access to ${var.cluster_name}"
  assume_role_policy = data.aws_iam_policy_document.account_assume_role[0].json
  tags               = local.tags
}

resource "aws_iam_role_policy" "eks_admin" {
  count = var.create_iam_access_roles ? 1 : 0

  name   = "eks-console-access"
  role   = aws_iam_role.eks_admin[0].id
  policy = data.aws_iam_policy_document.eks_console_access[0].json
}

resource "aws_iam_role" "eks_developer" {
  count = var.create_iam_access_roles ? 1 : 0

  name               = "eks-developer-${var.cluster_name}"
  description        = "Read-only access to ${var.cluster_name}"
  assume_role_policy = data.aws_iam_policy_document.account_assume_role[0].json
  tags               = local.tags
}

resource "aws_iam_role_policy" "eks_developer" {
  count = var.create_iam_access_roles ? 1 : 0

  name   = "eks-console-access"
  role   = aws_iam_role.eks_developer[0].id
  policy = data.aws_iam_policy_document.eks_console_access[0].json
}
