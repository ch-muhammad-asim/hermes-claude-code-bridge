# 🧪 Validation and test results

Recorded against the Pluralsight AWS sandbox, account `898961940126`,
`us-east-1`, on 2026-08-27. Every deployment step ran through Terragrunt.

## 🖥️ Environment

| | |
|---|---|
| Terraform | 1.15.8 |
| Terragrunt | 1.1.3 |
| Kubernetes | v1.36.2-eks-b3f9404 |
| Node AMI | Amazon Linux 2023.12.20260817, kernel 6.18.41 |
| Karpenter | 1.14.1 |
| System node group | 2 x t3.medium, on-demand |

## ✅ Static checks

| Check | Result |
|---|---|
| `terraform fmt` across all modules | ✅ clean |
| `terragrunt validate` - vpc, eks, karpenter, oidc/github | ✅ all "Success! The configuration is valid." |
| `terragrunt run --all plan` after apply | ✅ vpc, eks, karpenter all report "No changes" |

Idempotency is the one worth calling out: a second plan over an applied stack
produces no diff, which is what tells you the code and the live state actually
agree.

## 🚧 Guardrail tests

Each sandbox limit is enforced by a `validation` block. These were tested by
deliberately passing illegal values:

| Input | Result |
|---|---|
| `region = eu-west-1` | ✅ rejected - "The sandbox restricts actions to us-east-1 and us-west-2." |
| `node_disk_size = 150` | ✅ rejected - "The sandbox caps EBS volumes at 100 GiB." |
| `instance_sizes = ["xlarge"]` | ✅ rejected - "The sandbox only permits micro, small and medium..." |

The failures happen at plan time, before any API call.

## 📊 Cluster state after deploy

```
6 add-ons active: vpc-cni, kube-proxy, coredns, eks-pod-identity-agent,
                  metrics-server, aws-ebs-csi-driver
16 pods Running, 0 in any other phase
```

Access entries (no `aws-auth` ConfigMap anywhere):

```
role/eks-admin-cloudgeeks-eks-dev        AmazonEKSClusterAdminPolicy
role/eks-developer-cloudgeeks-eks-dev    AmazonEKSViewPolicy
role/Karpenter-cloudgeeks-eks-dev-...    EC2 node type
role/system-eks-node-group-...           EC2 node type
user/cloud_user                          cluster creator
```

Pod Identity associations:

```
kube-system/karpenter
kube-system/ebs-csi-controller-sa
```

Karpenter resources reconciled and healthy:

```
NodePool/default       Ready=True   ValidationSucceeded=True   NodeClassReady=True
EC2NodeClass/default   Ready=True   SubnetsReady=True   SecurityGroupsReady=True
                                    AMIsReady=True      InstanceProfileReady=True
```

Discovery by tag resolved three private subnets and the shared node security
group, confirming the `karpenter.sh/discovery` tags on the VPC and EKS layers
line up.

## ⬆️ Upgrade readiness

`upgradePolicy.supportType` verified as `STANDARD`, so the cluster auto-upgrades
at end of standard support instead of entering paid extended support. All five
EKS Cluster Insights upgrade-readiness checks report `PASSING`:

```
UPGRADE_READINESS   Kubelet version skew               PASSING
UPGRADE_READINESS   EKS add-on version compatibility   PASSING
UPGRADE_READINESS   kube-proxy version skew            PASSING
UPGRADE_READINESS   Amazon Linux 2 compatibility       PASSING
UPGRADE_READINESS   Cluster health issues              PASSING
```

Auto Mode confirmed off (`computeConfig.enabled: false`), which is correct for a
cluster running its own Karpenter. Details in [auto-upgrade](../auto-upgrade/).

## 📈 Scale-up

`kubectl scale deployment inflate --replicas 6` (6 x 500m CPU request):

| Event | Time |
|---|---|
| 🟢 Scale command issued | 08:18:30 |
| ⚡ NodeClaims created | 08:18:40 (**10s**) |
| ✅ Nodes `Ready`, all 6 pods `Running` | 08:19:19 (**49s total**) |

Karpenter chose **2 x t3a.small** rather than the t3.medium the system group
uses - the pods fit, and t3a.small is cheaper. That instance-type choice is the
behaviour Cluster Autoscaler cannot produce, because it can only scale node
groups that were declared in advance.

## 🔐 Launched-instance posture

Verified against the running instances with `aws ec2 describe-instances`:

| Property | Value |
|---|---|
| Instance lifecycle | on-demand (no spot - the sandbox forbids it) |
| IMDS | `HttpTokens=required` (IMDSv2 only) |
| IMDS hop limit | `1` |
| Detailed monitoring | enabled |
| Tenancy | default |
| Root volume | 50 GiB gp3, `Encrypted=true` |

## 📉 Consolidation

Repacking, `--replicas 6` → `2`:

| Event | Time |
|---|---|
| 🟢 Scale command issued | 08:20:07 |
| ✅ Down to 1 Karpenter node, both pods rescheduled | 08:26:04 (**~6m**) |

The elapsed time is `consolidateAfter: 1m` plus the drain, which respects both
the NodePool disruption budget (1 node at a time) and the workload's
PodDisruptionBudget (`maxUnavailable: 1`).

Full scale-down, `--replicas 2` → `0`:

| Event | Time |
|---|---|
| 🟢 Scale command issued | 08:26:18 |
| ✅ All Karpenter nodes gone, zero NodeClaims | 08:28:18 (**2m**) |

The cluster returned to exactly the 2-node system group. Nothing was orphaned.

## 🔁 Reproducing

```bash
kubectl apply -f modules/karpenter/manifests/inflate.yaml
```

```bash
kubectl scale deployment inflate --replicas 6
```

```bash
kubectl get nodeclaims -w
```

```bash
kubectl scale deployment inflate --replicas 0
```

Watch the controller reason about it:

```bash
kubectl logs -n kube-system -l app.kubernetes.io/name=karpenter -f
```

## 🐛 Issues found and fixed during testing

**`LimitExceeded: Cannot exceed quota for PolicySize: 6144`.** The EKS module
generates a Karpenter controller policy larger than the standard IAM policy
limit. Fixed by setting `enable_inline_policy = true`, exposed as
`use_inline_controller_policy`. Symptom before the fix: the controller
CrashLoopBackOffs with `ec2 api connectivity check failed ...
UnauthorizedOperation` on `DescribeInstanceTypes`, because the role exists with
no policy attached.

**`label domain "karpenter.sh" is restricted`.** The NodePool template carried a
`karpenter.sh/pool` label. That domain is reserved and the API server rejects
the whole NodePool. Removed.
