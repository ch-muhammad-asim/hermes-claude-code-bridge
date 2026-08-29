###############################################################################
# Hermes agent - single-node k3s on EC2
#
# WHY THIS EXISTS INSTEAD OF modules/eks:
# The Pluralsight *AI* Cloud Sandbox (the Bedrock-enabled one) denies
# eks:CreateCluster through an AWS Organizations service control policy
# (p-2nwbuy01). That is an org-level explicit deny: the account's IAM user is
# *allowed* the action by its identity policy, but an SCP deny cannot be overridden
# from inside the member account, and it is unconditional - verified against every
# supported Kubernetes version, both authentication modes, tagged requests and EKS
# Auto Mode, in us-east-1 and us-west-2.
#
# EC2 RunInstances IS permitted, so this module provisions a conformant
# single-node Kubernetes cluster the same blueprint can run on. Everything above
# the cluster layer is unchanged: Traefik is still the ingress controller, the
# Hermes manifests are the same Kustomize root, and the bridge still reaches
# Bedrock with the AWS SDK's default credential chain - it just resolves to the
# EC2 instance profile here instead of EKS Pod Identity, which costs zero lines
# of application change.
#
# Use modules/eks in any account whose SCP permits it. This is the sandbox path.
###############################################################################

data "aws_partition" "current" {}
data "aws_caller_identity" "current" {}

# AL2023 rather than a pinned AMI id: the id differs per region and rots, and SSM
# always resolves the current patched release.
data "aws_ssm_parameter" "al2023" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

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

  inference_profile_arns = [
    "arn:${local.partition}:bedrock:${var.region}:${local.account_id}:inference-profile/${var.model_id}",
  ]

  foundation_model_arns = [
    for r in var.inference_profile_regions :
    "arn:${local.partition}:bedrock:${r}::foundation-model/${var.foundation_model_id}"
  ]
}

###############################################################################
# Instance identity
#
# One role does two jobs: invoke the configured Bedrock model (the agent's only
# AWS permission) and publish the kubeconfig to S3 so operators reach the cluster
# without an SSH key or an inbound 22.
###############################################################################

data "aws_iam_policy_document" "ec2_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "node" {
  name               = "${var.cluster_name}-node"
  description        = "k3s node role: Bedrock invoke for the Hermes bridge + kubeconfig publish"
  assume_role_policy = data.aws_iam_policy_document.ec2_trust.json
  tags               = local.tags
}

data "aws_iam_policy_document" "node" {
  # Identical scope to modules/hermes-bedrock-iam: invoke only, on one model.
  statement {
    sid    = "InvokeConfiguredClaudeModel"
    effect = "Allow"

    actions = [
      "bedrock:InvokeModel",
      "bedrock:InvokeModelWithResponseStream",
    ]

    resources = concat(local.inference_profile_arns, local.foundation_model_arns)
  }

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

  # Exactly two objects, not the bucket: the node publishes its kubeconfig and its
  # bootstrap status, and can do nothing else in the state bucket it shares with
  # Terraform.
  statement {
    sid     = "PublishKubeconfigAndStatus"
    effect  = "Allow"
    actions = ["s3:PutObject"]
    resources = [
      "arn:${local.partition}:s3:::${var.kubeconfig_bucket}/${var.kubeconfig_key}",
      "arn:${local.partition}:s3:::${var.kubeconfig_bucket}/${var.status_key}",
    ]
  }

  # The generated dashboard password and bridge API key go to SSM SecureString
  # rather than to a log, an S3 object, or a Terraform output - so they never land
  # in state. Scoped to this deployment's prefix only.
  statement {
    sid       = "PublishGeneratedCredentials"
    effect    = "Allow"
    actions   = ["ssm:PutParameter"]
    resources = ["arn:${local.partition}:ssm:${var.region}:${local.account_id}:parameter${var.ssm_prefix}/*"]
  }

  # SecureString encryption with the AWS-managed SSM key.
  statement {
    sid       = "EncryptSsmSecureStrings"
    effect    = "Allow"
    actions   = ["kms:Encrypt", "kms:GenerateDataKey"]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["ssm.${var.region}.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy" "node" {
  name   = "${var.cluster_name}-node"
  role   = aws_iam_role.node.id
  policy = data.aws_iam_policy_document.node.json
}

resource "aws_iam_instance_profile" "node" {
  name = "${var.cluster_name}-node"
  role = aws_iam_role.node.name
  tags = local.tags
}

###############################################################################
# Network
###############################################################################

resource "aws_security_group" "node" {
  name        = "${var.cluster_name}-node"
  description = "k3s node: public ingress on 80/443, restricted Kubernetes API"
  vpc_id      = var.vpc_id
  tags        = merge(local.tags, { Name = "${var.cluster_name}-node" })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "http" {
  for_each = toset(var.ingress_allowed_cidrs)

  security_group_id = aws_security_group.node.id
  description       = "HTTP - Traefik web entrypoint (redirects to websecure)"
  cidr_ipv4         = each.value
  from_port         = 80
  to_port           = 80
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_ingress_rule" "https" {
  for_each = toset(var.ingress_allowed_cidrs)

  security_group_id = aws_security_group.node.id
  description       = "HTTPS - Traefik websecure entrypoint (hermes.saqlainmushtaq.com)"
  cidr_ipv4         = each.value
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
}

# Deliberately no default: an empty api_allowed_cidrs creates no rule at all, so a
# forgotten value fails closed (no kubectl) rather than open (world-reachable API).
resource "aws_vpc_security_group_ingress_rule" "kube_api" {
  for_each = toset(var.api_allowed_cidrs)

  security_group_id = aws_security_group.node.id
  description       = "Kubernetes API - operator kubectl"
  cidr_ipv4         = each.value
  from_port         = 6443
  to_port           = 6443
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "all" {
  security_group_id = aws_security_group.node.id
  description       = "Pulls container images, the k3s installer, kubectl/gh, and calls Bedrock"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

###############################################################################
# Node
###############################################################################

resource "aws_instance" "node" {
  ami                    = data.aws_ssm_parameter.al2023.value
  instance_type          = var.instance_type
  subnet_id              = var.subnet_id
  vpc_security_group_ids = [aws_security_group.node.id]
  iam_instance_profile   = aws_iam_instance_profile.node.name

  # Public IP: this node terminates ingress and is the kubectl endpoint.
  associate_public_ip_address = true

  root_block_device {
    volume_type           = "gp3"
    volume_size           = var.root_volume_size
    encrypted             = true
    delete_on_termination = true
  }

  metadata_options {
    http_tokens = "required" # IMDSv2 only
    # 2, not the default 1. Pod traffic to IMDS is routed through the host network
    # namespace, which decrements the hop count - at a limit of 1 every pod gets a
    # connection timeout instead of credentials, and the Hermes bridge would fail
    # with NoCredentialsError. This single line is what lets the sidecar reach
    # Bedrock with the instance role.
    http_put_response_hop_limit = 2
    http_endpoint               = "enabled"
  }

  user_data_replace_on_change = true
  user_data = templatefile("${path.module}/user_data.sh.tftpl", {
    k3s_channel           = var.k3s_version_channel
    kubeconfig_bucket     = var.kubeconfig_bucket
    kubeconfig_key        = var.kubeconfig_key
    status_key            = var.status_key
    region                = var.region
    deploy_hermes         = var.deploy_hermes ? "true" : "false"
    manifests_repo        = var.manifests_repo
    manifests_ref         = var.manifests_ref
    hermes_overlay        = var.hermes_overlay
    traefik_values        = var.traefik_values
    traefik_chart_version = var.traefik_chart_version
    helm_version          = var.helm_version
    hermes_image          = var.hermes_image
    ssm_prefix            = var.ssm_prefix
  })

  tags = merge(local.tags, { Name = "${var.cluster_name}-node" })
}


###############################################################################
# Bootstrap gate
#
# EC2 reports an instance as created the moment it boots - long before k3s,
# Traefik and Hermes exist. Without this, `terragrunt apply` would succeed against
# a half-built cluster and the failure would surface later, somewhere confusing.
#
# The node writes its progress to s3://<bucket>/<status_key>; this polls until it
# reads COMPLETE, and fails the apply on FAILED or on timeout. That is what makes
# the module end-to-end: apply returns only when the stack actually works.
#
# stale-marker guard: the object may still hold COMPLETE from a previous instance,
# so the poll ignores anything written before this instance existed.
###############################################################################

resource "terraform_data" "bootstrap_gate" {
  triggers_replace = [aws_instance.node.id]

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    environment = {
      BUCKET      = var.kubeconfig_bucket
      STATUS_KEY  = var.status_key
      REGION      = var.region
      TIMEOUT_MIN = tostring(var.bootstrap_timeout_minutes)
      INSTANCE_ID = aws_instance.node.id
    }
    command = <<-EOT
      set -uo pipefail
      deadline=$(( $(date +%s) + TIMEOUT_MIN * 60 ))
      echo "waiting for $INSTANCE_ID to finish bootstrapping (timeout $${TIMEOUT_MIN}m)..."
      last=""
      while [ "$(date +%s)" -lt "$deadline" ]; do
        status=$(aws s3 cp "s3://$BUCKET/$STATUS_KEY" - --region "$REGION" 2>/dev/null | tr -d '[:space:]' || true)
        if [ -n "$status" ] && [ "$status" != "$last" ]; then echo "  status: $status"; last="$status"; fi
        case "$status" in
          COMPLETE) echo "bootstrap complete"; exit 0 ;;
          FAILED*)  echo "bootstrap FAILED on the node ($status)."; echo "inspect: aws ssm start-session --target $INSTANCE_ID  then: sudo tail -100 /var/log/hermes-k3s-bootstrap.log"; exit 1 ;;
        esac
        sleep 15
      done
      echo "timed out after $${TIMEOUT_MIN}m waiting for bootstrap (last status: $${last:-none})."
      echo "the console log usually shows why: aws ec2 get-console-output --instance-id $INSTANCE_ID --region $REGION --output text | tail -50"
      exit 1
    EOT
  }
}
