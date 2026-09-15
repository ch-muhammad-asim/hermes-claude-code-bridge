###############################################################################
# EC2NodeClass and NodePool (Karpenter v1 APIs)
#
# EC2NodeClass answers "what does an instance look like" - AMI, subnets,
# security groups, disk, metadata. NodePool answers "what may be provisioned
# and when is it torn down" - instance shapes, limits, disruption behaviour.
###############################################################################

resource "kubectl_manifest" "ec2_node_class" {
  yaml_body = yamlencode({
    apiVersion = "karpenter.k8s.aws/v1"
    kind       = "EC2NodeClass"

    metadata = {
      name = "default"
    }

    spec = {
      # Karpenter creates and manages the instance profile for this role.
      role = module.karpenter.node_iam_role_name

      # al2023@latest tracks the newest AL2023 EKS AMI. Pin to a dated alias in
      # production so an upstream AMI release cannot roll your fleet unplanned.
      amiSelectorTerms = [
        {
          alias = var.ami_alias
        },
      ]

      subnetSelectorTerms = [
        {
          tags = {
            "karpenter.sh/discovery" = var.cluster_name
          }
        },
      ]

      securityGroupSelectorTerms = [
        {
          tags = {
            "karpenter.sh/discovery" = var.cluster_name
          }
        },
      ]

      # IMDSv2 required with a single hop: a container cannot reach instance
      # metadata and borrow the node role.
      metadataOptions = {
        httpEndpoint            = "enabled"
        httpProtocolIPv6        = "disabled"
        httpPutResponseHopLimit = 1
        httpTokens              = "required"
      }

      blockDeviceMappings = [
        {
          deviceName = "/dev/xvda"
          ebs = {
            volumeSize          = var.node_disk_size
            volumeType          = "gp3"
            encrypted           = true
            deleteOnTermination = true
          }
        },
      ]

      detailedMonitoring = true

      tags = merge(local.tags, {
        Name                     = "${var.cluster_name}-karpenter"
        "karpenter.sh/discovery" = var.cluster_name
        ManagedBy                = "karpenter"
      })
    }
  })

  server_side_apply = true
  wait              = true

  depends_on = [helm_release.karpenter]
}

resource "kubectl_manifest" "node_pool" {
  yaml_body = yamlencode({
    apiVersion = "karpenter.sh/v1"
    kind       = "NodePool"

    metadata = {
      name = "default"
    }

    spec = {
      template = {
        metadata = {
          # The karpenter.sh/ label domain is reserved - the API server rejects
          # any NodePool that sets labels under it.
          labels = {
            "workload-type"  = "general"
            "provisioned-by" = "karpenter"
          }
        }

        spec = {
          nodeClassRef = {
            group = "karpenter.k8s.aws"
            kind  = "EC2NodeClass"
            name  = kubectl_manifest.ec2_node_class.name
          }

          # Requirements are a filter, not a preference list. The wider they
          # are, the better Karpenter bin-packs and the cheaper the result -
          # these are narrow only because the sandbox demands it.
          requirements = concat(
            [
              {
                key      = "kubernetes.io/arch"
                operator = "In"
                values   = ["amd64"]
              },
              {
                key      = "kubernetes.io/os"
                operator = "In"
                values   = ["linux"]
              },
              {
                key      = "karpenter.sh/capacity-type"
                operator = "In"
                values   = var.capacity_types
              },
              {
                key      = "karpenter.k8s.aws/instance-family"
                operator = "In"
                values   = var.instance_families
              },
              {
                key      = "karpenter.k8s.aws/instance-size"
                operator = "In"
                values   = var.instance_sizes
              },
            ],
          )

          # Rotate nodes on a schedule so AMI and kernel patches actually land.
          expireAfter = var.node_expire_after

          # Cap how long a drain may hang before Karpenter forces termination.
          terminationGracePeriod = "24h"
        }
      }

      # WhenEmptyOrUnderutilized also removes nodes whose pods fit elsewhere,
      # not just empty ones - this is where most of the savings come from.
      disruption = {
        consolidationPolicy = "WhenEmptyOrUnderutilized"
        consolidateAfter    = var.consolidate_after

        budgets = [
          {
            nodes = var.disruption_budget_nodes
          },
        ]
      }

      # A hard ceiling on the fleet. Without limits a runaway ReplicaSet will
      # happily provision until it hits an AWS quota.
      limits = {
        cpu    = tostring(var.node_cpu_limit)
        memory = var.node_memory_limit
      }

      weight = 10
    }
  })

  server_side_apply = true
  wait              = true

  depends_on = [kubectl_manifest.ec2_node_class]
}
