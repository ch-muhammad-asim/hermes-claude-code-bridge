###############################################################################
# Karpenter - controller, IAM, interruption queue, NodePool and EC2NodeClass
#
# Layered on top of the eks/ stack. Karpenter replaces Cluster Autoscaler
# entirely: no ASGs to size, no node groups per instance shape, and a scheduling
# loop that picks the instance type from the pending pods' actual requests.
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

###############################################################################
# Controller IAM, node IAM role, instance profile and interruption queue
###############################################################################
# https://registry.terraform.io/modules/terraform-aws-modules/eks/aws/latest/submodules/karpenter
module "karpenter" {
  source  = "registry.terraform.io/terraform-aws-modules/eks/aws//modules/karpenter"
  version = "~> 21.25"

  cluster_name = var.cluster_name

  # Pod Identity instead of IRSA: no OIDC trust policy to maintain, and the
  # association is an EKS API object rather than a role annotation.
  create_pod_identity_association = true
  namespace                       = var.karpenter_namespace
  service_account                 = "karpenter"

  # SQS queue + EventBridge rules for interruption handling.
  enable_spot_termination = var.enable_interruption_queue

  # The generated controller policy is larger than the 6,144-character quota for
  # a standard IAM policy, so AWS rejects CreatePolicy with
  # "LimitExceeded: Cannot exceed quota for PolicySize". An inline role policy
  # has a 10,240-character limit and is the module's documented workaround.
  enable_inline_policy = var.use_inline_controller_policy

  # Karpenter creates the access entry for this role itself, so nodes it
  # launches can join without any aws-auth edit.
  create_access_entry = true

  node_iam_role_additional_policies = {
    AmazonSSMManagedInstanceCore = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore"
  }

  tags = local.tags
}

###############################################################################
# Karpenter controller
###############################################################################
resource "helm_release" "karpenter" {
  name       = "karpenter"
  repository = "oci://public.ecr.aws/karpenter"
  chart      = "karpenter"
  version    = var.karpenter_version
  namespace  = var.karpenter_namespace

  # CRDs ship inside the chart from v1.0 onward.
  atomic          = true
  cleanup_on_fail = true
  wait            = true
  timeout         = 600

  values = [
    yamlencode({
      replicas = var.karpenter_replicas

      serviceAccount = {
        name = module.karpenter.service_account
      }

      settings = {
        clusterName       = var.cluster_name
        clusterEndpoint   = var.cluster_endpoint
        interruptionQueue = var.enable_interruption_queue ? module.karpenter.queue_name : ""
      }

      # Karpenter cannot manage the capacity it runs on, so keep it on the
      # system node group. The chart's default affinity already refuses
      # Karpenter-owned nodes; this pins it to the system label as well.
      nodeSelector = {
        "workload-type" = "system"
      }

      tolerations = [
        {
          key      = "CriticalAddonsOnly"
          operator = "Exists"
        },
      ]

      # Spread replicas so a single node loss cannot take out both.
      topologySpreadConstraints = [
        {
          maxSkew           = 1
          topologyKey       = "kubernetes.io/hostname"
          whenUnsatisfiable = "DoNotSchedule"
          labelSelector = {
            matchLabels = {
              "app.kubernetes.io/instance" = "karpenter"
            }
          }
        },
      ]

      controller = {
        resources = {
          requests = {
            cpu    = "200m"
            memory = "512Mi"
          }
          # CPU is deliberately left unlimited: throttling the scheduling loop
          # slows every scale-up. Memory is capped to bound the blast radius.
          limits = {
            memory = "512Mi"
          }
        }
      }

      logLevel = "info"

      podDisruptionBudget = {
        name           = "karpenter"
        maxUnavailable = 1
      }
    }),
  ]
}
