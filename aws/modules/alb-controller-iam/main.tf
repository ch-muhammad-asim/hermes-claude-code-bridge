###############################################################################
# AWS Load Balancer Controller - IAM only
#
# The controller's AWS permissions belong to infrastructure, so they are managed
# here through Terragrunt. The chart itself is installed with Helm - see
# kubernetes/aws-load-balancer-controller/README.md - which keeps the version
# pinning and the CRD handling in one obvious place.
#
# Permissions come from EKS Pod Identity rather than IRSA: no OIDC trust policy
# to hand-maintain, and the association is a plain EKS API object.
###############################################################################

data "aws_partition" "current" {}

locals {
  tags = merge(
    {
      Environment = var.environment
      Terraform   = "true"
      Blueprint   = var.cluster_name
    },
    var.tags,
  )
}

# Vendored from the controller release rather than fetched at apply time, so the
# permissions cannot change underneath a plan:
# https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v3.5.0/docs/install/iam_policy.json
resource "aws_iam_policy" "this" {
  name        = "AWSLoadBalancerControllerIAMPolicy-${var.cluster_name}"
  description = "AWS Load Balancer Controller v3.5.0 permissions for ${var.cluster_name}"
  policy      = file("${path.module}/iam_policy.json")
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
  name               = "${var.cluster_name}-aws-load-balancer-controller"
  description        = "AWS Load Balancer Controller role assumed through EKS Pod Identity"
  assume_role_policy = data.aws_iam_policy_document.pod_identity_trust.json
  tags               = local.tags
}

resource "aws_iam_role_policy_attachment" "this" {
  role       = aws_iam_role.this.name
  policy_arn = aws_iam_policy.this.arn
}

# Binds the role to the controller's service account. The service account does
# not need to exist yet - Helm creates it, and the association applies from the
# next pod start.
resource "aws_eks_pod_identity_association" "this" {
  cluster_name    = var.cluster_name
  namespace       = var.namespace
  service_account = var.service_account
  role_arn        = aws_iam_role.this.arn
  tags            = local.tags
}
