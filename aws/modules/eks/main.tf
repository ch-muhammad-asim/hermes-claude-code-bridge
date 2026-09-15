###############################################################################
# EKS control plane, system node group and cluster access
#
# Sandbox guardrails baked in (see docs/SANDBOX.md):
#   - Kubernetes version must be in EKS standard support
#   - t2/t3/t3a/t4g micro|small|medium instances only
#   - no EC2 Spot capacity
#   - nine concurrent EC2 instances account-wide
###############################################################################

data "aws_caller_identity" "current" {}
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

#############
# EKS cluster
#############
# https://registry.terraform.io/modules/terraform-aws-modules/eks/aws/latest
module "eks" {
  source  = "registry.terraform.io/terraform-aws-modules/eks/aws"
  version = "~> 21.25"

  name               = var.cluster_name
  kubernetes_version = var.kubernetes_version

  vpc_id     = var.vpc_id
  subnet_ids = var.subnet_ids

  # API is the modern replacement for the aws-auth ConfigMap, which the module
  # dropped in v20. Access entries are plain AWS API objects, so cluster access
  # no longer depends on being able to reach the Kubernetes API to fix itself.
  authentication_mode                      = "API"
  enable_cluster_creator_admin_permissions = true

  endpoint_private_access      = true
  endpoint_public_access       = true
  endpoint_public_access_cidrs = var.endpoint_public_access_cidrs

  enabled_log_types = var.enabled_log_types

  # AWS defaults this to EXTENDED, which parks the cluster on an end-of-life
  # version at premium pricing instead of moving it forward. STANDARD makes AWS
  # auto-upgrade the control plane when the version leaves standard support -
  # and it is the only setting the sandbox permits.
  upgrade_policy = {
    support_type = var.cluster_support_type
  }

  access_entries = var.create_iam_access_roles ? {
    admin = {
      principal_arn = aws_iam_role.eks_admin[0].arn

      policy_associations = {
        cluster_admin = {
          policy_arn = "arn:${data.aws_partition.current.partition}:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
          access_scope = {
            type = "cluster"
          }
        }
      }
    }

    developer = {
      principal_arn = aws_iam_role.eks_developer[0].arn

      policy_associations = {
        view = {
          policy_arn = "arn:${data.aws_partition.current.partition}:eks::aws:cluster-access-policy/AmazonEKSViewPolicy"
          access_scope = {
            type = "cluster"
          }
        }
      }
    }
  } : {}

  # IRSA stays on: Karpenter uses Pod Identity, but plenty of charts still
  # expect an OIDC provider.
  enable_irsa = true

  addons = {
    # vpc-cni and kube-proxy must exist before the nodes join, otherwise the
    # first nodes come up without networking and the node group times out.
    vpc-cni = {
      before_compute = true
      configuration_values = jsonencode({
        env = {
          ENABLE_PREFIX_DELEGATION = "true"
          WARM_PREFIX_TARGET       = "1"
        }
      })
    }
    kube-proxy = {
      before_compute = true
    }
    coredns = {
      configuration_values = jsonencode({
        replicaCount = 2
        tolerations = [
          {
            key      = "CriticalAddonsOnly"
            operator = "Exists"
          },
        ]
      })
    }
    eks-pod-identity-agent = {
      before_compute = true
    }
    metrics-server = {}
    aws-ebs-csi-driver = {
      pod_identity_association = [
        {
          role_arn        = aws_iam_role.ebs_csi.arn
          service_account = "ebs-csi-controller-sa"
        },
      ]
    }
  }

  # Recommended rules cover node-to-node and control-plane-to-node traffic,
  # including the webhook ports Karpenter needs. The hand-rolled allow-all
  # rules this blueprint used to carry are no longer required.
  node_security_group_enable_recommended_rules = true

  node_security_group_tags = {
    # Karpenter v1 discovers security groups on this tag.
    "karpenter.sh/discovery" = var.cluster_name
  }

  timeouts = {
    create = "60m"
    update = "60m"
    delete = "30m"
  }

  ###########################################################################
  # System node group
  #
  # Karpenter itself cannot run on Karpenter-managed capacity, so this group
  # exists to host the controller, CoreDNS and the other system add-ons.
  # Everything else should land on Karpenter nodes.
  ###########################################################################
  eks_managed_node_groups = {
    system = {
      # ON_DEMAND only - the sandbox does not support EC2 Spot at all.
      capacity_type  = "ON_DEMAND"
      instance_types = var.node_instance_types
      ami_type       = "AL2023_x86_64_STANDARD"

      min_size     = var.node_min_size
      max_size     = var.node_max_size
      desired_size = var.node_desired_size

      subnet_ids = var.subnet_ids

      ebs_optimized     = true
      enable_monitoring = true

      # Roll the node group onto the newest EKS-optimised AMI for its Kubernetes
      # version on every apply. This is how kernel and CVE patches reach the
      # system nodes - a managed node group does NOT patch itself. Karpenter
      # nodes handle this on their own through drift detection.
      use_latest_ami_release_version = var.node_use_latest_ami

      block_device_mappings = {
        xvda = {
          device_name = "/dev/xvda"
          ebs = {
            volume_size           = var.node_disk_size
            volume_type           = "gp3"
            iops                  = 3000
            throughput            = 125
            encrypted             = true
            delete_on_termination = true
          }
        }
      }

      # IMDSv2 required, single hop: blocks the classic container-breakout path
      # to the node instance role.
      metadata_options = {
        http_endpoint               = "enabled"
        http_tokens                 = "required"
        http_put_response_hop_limit = 1
        instance_metadata_tags      = "disabled"
      }

      # Let EKS replace nodes that fail health checks on its own.
      node_repair_config = {
        enabled = true
      }

      update_config = {
        max_unavailable_percentage = 33
      }

      iam_role_additional_policies = {
        AmazonSSMManagedInstanceCore = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore"
      }

      labels = {
        "node.kubernetes.io/lifecycle" = "on-demand"
        "workload-type"                = "system"
      }

      tags = local.tags
    }
  }

  tags = local.tags
}

##############################################
# EBS CSI driver - EKS Pod Identity, not IRSA
##############################################
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

resource "aws_iam_role" "ebs_csi" {
  name               = "${var.cluster_name}-ebs-csi-driver"
  description        = "EBS CSI driver role assumed through EKS Pod Identity"
  assume_role_policy = data.aws_iam_policy_document.pod_identity_trust.json
  tags               = local.tags
}

resource "aws_iam_role_policy_attachment" "ebs_csi" {
  role       = aws_iam_role.ebs_csi.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}
