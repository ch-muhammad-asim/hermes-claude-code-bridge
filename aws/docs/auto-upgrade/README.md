# ⬆️ EKS auto upgrade - what is actually automatic

Short version: **EKS has no equivalent of GKE release channels.** Nothing in
EKS proactively moves a cluster from 1.36 to 1.37 the way GKE's regular channel
does. What EKS gives you is a *safety net* at end of support, plus data-plane
automation you have to assemble yourself.

This page is explicit about the difference, because assuming GKE behaviour and
getting EKS behaviour is how clusters end up two versions behind.

## 🆚 EKS versus GKE

| | GKE | EKS |
|---|---|---|
| Release channels (rapid/regular/stable) | ✅ yes | ❌ none |
| Proactive minor-version upgrades | ✅ continuous, on the channel's schedule | ❌ never - you initiate it |
| Forced upgrade at end of life | ✅ yes | ✅ yes, if `supportType = STANDARD` |
| Maintenance windows / exclusions | ✅ yes | ❌ not for the automatic EOL upgrade |
| Node auto-upgrade | ✅ built in | ⚠️ Karpenter drift, or Auto Mode, or you script it |
| Node auto-repair | ✅ built in | ✅ managed node group `nodeRepairConfig` |
| Extra cost for any of it | free | free, except Auto Mode |

## ❌ What `STANDARD` will not do

It will **not** move this cluster from 1.36 to 1.37 when 1.37 ships.

`STANDARD` is a single, deadline-driven event, not a subscription to new
releases. It fires once - on the running version's end-of-standard-support date
- and lands on whatever is in standard support at that moment.

Concretely, as of 2026-08-27:

| Version | Status | End of standard support |
|---|---|---|
| **1.36** | standard (default) | **2027-08-02** |
| 1.35 | standard | 2027-03-27 |
| 1.34 | standard | 2026-12-02 |
| 1.33 | extended | 2026-07-29 (passed) |

1.37 does not exist in EKS yet. This cluster runs 1.36, so `STANDARD` does
nothing at all until **2027-08-02** - roughly eleven months away. If 1.37 and
1.38 ship in the meantime, the cluster stays on 1.36 regardless.

Check the current picture yourself:

```bash
aws eks describe-cluster-versions --query "clusterVersions[].{v:clusterVersion,status:status,eos:endOfStandardSupportDate}" --output table
```

**To actually move 1.36 → 1.37**, bump the version and apply - this is the only
knob that upgrades a cluster on your schedule:

```hcl
# terragrunt/env/dev/env.hcl
locals {
  kubernetes_version = "1.37"
}
```

```bash
terragrunt apply --working-dir terragrunt/env/dev/region/us-east-1/eks
```

EKS upgrades one minor version at a time, so 1.36 → 1.38 must be done as two
applies.

### ⚠️ Is that bump safe? Caveats before you run it

Changing one line in `env.hcl` is a **one-way, cluster-wide** operation. Read
this before you type it in production.

**It cannot be undone.** EKS does not downgrade a control plane. If a workload
breaks on 1.37, the only path is forward - fix the workload. There is no
`kubernetes_version = "1.36"` rollback.

**Deprecated and removed APIs are the usual failure.** The API server stops
serving removed versions the moment the control plane upgrades, and every
manifest, Helm chart and operator still using them breaks at once. No backup
product fixes this; the manifest is simply invalid on the new version. Check the
target version's release notes and run the readiness insights:

```bash
aws eks list-insights --cluster-name cloudgeeks-eks-dev --query "insights[?insightStatus.status!='PASSING']"
```

An empty result is the only acceptable answer.

**The version skew rule binds the order.** The control plane upgrades first,
then nodes. Nodes may trail the control plane, never lead it. Terraform handles
the ordering, but it means a cluster spends the upgrade window running mixed
kubelet versions - a workload that cannot tolerate that needs a maintenance
window.

**Node rotation is a real disruption.** After the control plane moves, the
managed node group rolls and Karpenter marks its nodes `Drifted` and replaces
them. Every pod in the cluster gets rescheduled. That is only safe if
PodDisruptionBudgets are correct - and a PDB that can never be satisfied will
stall the rollout instead, which is its own incident.

**Add-ons have their own compatibility matrix.** vpc-cni, CoreDNS, kube-proxy
and the EBS CSI driver each support a range of Kubernetes versions.
`most_recent = true` handles this on apply, but an add-on pinned to a fixed
version will block or break the upgrade.

**Stateful workloads deserve a backup first.** See
[backup-dr](../backup-dr/) - take an on-demand AWS Backup job and
confirm it completed, not `Partial`, before starting.

### ✅ The production sequence

1. Read the target version's release notes for removed APIs and behaviour
   changes.
2. Confirm all upgrade-readiness insights pass.
3. Take and verify a backup of cluster state and persistent volumes.
4. Upgrade a non-production cluster on the same version, and let it soak.
5. Confirm PodDisruptionBudgets are satisfiable - a stuck drain is the most
   common upgrade stall.
6. Bump `kubernetes_version`, `terragrunt plan`, review, apply.
7. Watch nodes roll: `kubectl get nodes -w` and `kubectl get nodeclaims -w`.
8. Re-run the insights afterwards, and upgrade add-ons if any lagged.

In a sandbox, steps 3 and 4 are skippable and the whole thing is a five-minute
exercise. In production they are the job.

## ✅ What this blueprint automates, at no extra cost

| Layer | Mechanism | Behaviour |
|---|---|---|
| Control plane | `upgradePolicy.supportType = STANDARD` | AWS force-upgrades **once**, on the end-of-standard-support date, no extended-support charges. Not a release channel |
| Karpenter nodes | `amiSelectorTerms: alias al2023@latest` + drift detection | a new AL2023 AMI marks nodes `Drifted`; Karpenter replaces them respecting PDBs |
| Karpenter nodes | `expireAfter: 168h` | nodes rotate weekly regardless, so nothing accumulates drift |
| System node group | `use_latest_ami_release_version = true` | each apply moves the group onto the newest AMI for its version |
| System node group | `nodeRepairConfig.enabled = true` | EKS replaces nodes that fail health checks |
| Add-ons | `most_recent = true` | each apply pulls the newest compatible add-on build |

The **control-plane minor version is the one thing left manual**: bump
`kubernetes_version` in `terragrunt/env/dev/env.hcl` and apply. Everything else
follows automatically - the node groups and Karpenter nodes converge on the new
version without further intervention.

## 💰 Cost

| Setting | Cost |
|---|---|
| `supportType = STANDARD` | **no additional cost** - this is the setting that *avoids* charges |
| `supportType = EXTENDED` | extended-support premium per cluster hour once the version ages out |
| Karpenter drift + expiry | free (you pay only for the EC2 instances either way) |
| EKS Auto Mode | **additional management fee per instance**, on top of EC2 |

So the answer to "auto upgrade with no additional cost" is yes - `STANDARD` is
strictly cheaper than the `EXTENDED` default. The only paid option is Auto Mode.

## ⚠️ Is it safe?

Automatic *is not* the same as safe. Two things to be clear about:

- **Upgrades are one-way.** EKS cannot downgrade a control plane. If a workload
  breaks on the new version, you roll the workload forward, not the cluster
  back.
- **The EOL upgrade is not schedulable.** Unlike a GKE maintenance window, you
  do not choose when the forced upgrade lands. Treat it as a deadline, not a
  plan.

What makes it safe in practice is checking readiness *before* the deadline. EKS
ships Cluster Insights for exactly this - it flags deprecated API usage, version
skew and add-on incompatibility:

```bash
aws eks list-insights --cluster-name cloudgeeks-eks-dev --query "insights[].{name:name,category:category,status:insightStatus.status}" --output table
```

Verified on this cluster, 2026-08-27:

```
|      category      |               name                 | status   |
|  UPGRADE_READINESS |  Kubelet version skew              |  PASSING |
|  UPGRADE_READINESS |  EKS add-on version compatibility  |  PASSING |
|  UPGRADE_READINESS |  kube-proxy version skew           |  PASSING |
|  UPGRADE_READINESS |  Amazon Linux 2 compatibility      |  PASSING |
|  UPGRADE_READINESS |  Cluster health issues             |  PASSING |
```

All five checks passing means this cluster can take a version bump without a
known blocker. Anything `ERROR` here should be fixed before the upgrade, not
after.

The other half of safety is disruption control, which the blueprint already
sets: PodDisruptionBudgets on workloads, a NodePool disruption budget of one
node at a time, and `terminationGracePeriod` so a stuck drain cannot hang a
rotation forever. See [karpenter](../karpenter/).

## 🎯 Getting closest to GKE behaviour

If you want continuous upgrades rather than a 14-month safety net, the pattern
is a scheduled pipeline, because AWS provides no channel to subscribe to:

1. Query what standard support currently covers:

```bash
aws eks describe-cluster-versions --query "clusterVersions[?status=='STANDARD_SUPPORT'].clusterVersion"
```

2. Gate on readiness - fail the pipeline if any insight is not `PASSING`:

```bash
aws eks list-insights --cluster-name cloudgeeks-eks-dev --query "insights[?insightStatus.status!='PASSING']"
```

3. Bump `kubernetes_version` in `terragrunt/env/dev/env.hcl` and apply:

```bash
terragrunt apply --working-dir terragrunt/env/dev/region/us-east-1/eks
```

Nodes follow on their own: the managed node group updates with the cluster, and
Karpenter marks its nodes drifted and rotates them.

The alternative is **EKS Auto Mode**, which is the genuine GKE-Autopilot
analogue - AWS manages nodes and replaces the CNI, CoreDNS, kube-proxy, the EBS
CSI driver, the Load Balancer Controller and Karpenter with service
functionality. It carries a per-instance management fee, and it makes the
`karpenter` unit in this repo redundant. It is off here:

```bash
aws eks describe-cluster --name cloudgeeks-eks-dev --query "cluster.computeConfig"
```

```
{ "enabled": false, "nodePools": [] }
```

## 🛠️ How the policy is configured

Set it per environment in the Terragrunt unit
(`terragrunt/env/dev/region/us-east-1/eks/terragrunt.hcl`):

```hcl
inputs = {
  cluster_support_type = "STANDARD"
}
```

The module passes it straight through in `modules/eks/main.tf`:

```hcl
upgrade_policy = {
  support_type = var.cluster_support_type
}
```

`cluster_support_type` defaults to `STANDARD` and is validated to reject
anything other than `STANDARD` or `EXTENDED`. Setting `EXTENDED` is a
deliberate, billable choice - make it in the unit, where it is reviewable.

Two constraints before you rely on switching later:

- Once a cluster **has entered** extended support, you cannot disable it. The
  cluster must be on a standard-support version to change the policy.
- If an automatic upgrade has already been initiated, AWS does not guarantee a
  late switch to `EXTENDED` takes effect.

## ✅ Verification

```bash
aws eks describe-cluster --name cloudgeeks-eks-dev --query "cluster.upgradePolicy.supportType"
```

Verified 2026-08-27: `"STANDARD"`

```bash
aws eks describe-cluster --name cloudgeeks-eks-dev --query "cluster.version"
```

Verified: `"1.36"` - in standard support, so the cluster is compliant and will
auto-upgrade rather than roll into extended support.

Drift is caught by Terraform if anyone changes it out of band:

```bash
terragrunt plan --working-dir terragrunt/env/dev/region/us-east-1/eks
```

## 📚 Official AWS documentation

| Topic | Link |
|---|---|
| Kubernetes versions and the support lifecycle | https://docs.aws.amazon.com/eks/latest/userguide/kubernetes-versions.html |
| View current cluster upgrade policy | https://docs.aws.amazon.com/eks/latest/userguide/view-upgrade-policy.html |
| Edit cluster upgrade policy | https://docs.aws.amazon.com/eks/latest/userguide/edit-upgrade-policy.html |
| Versions on standard support | https://docs.aws.amazon.com/eks/latest/userguide/kubernetes-versions-standard.html |
| Versions on extended support | https://docs.aws.amazon.com/eks/latest/userguide/kubernetes-versions-extended.html |
| Update a cluster to a new Kubernetes version | https://docs.aws.amazon.com/eks/latest/userguide/update-cluster.html |
| Cluster Insights (upgrade readiness) | https://docs.aws.amazon.com/eks/latest/userguide/cluster-insights.html |
| Update a managed node group | https://docs.aws.amazon.com/eks/latest/userguide/update-managed-node-group.html |
| Node health and auto repair | https://docs.aws.amazon.com/eks/latest/userguide/node-health.html |
| Cluster upgrade best practices | https://docs.aws.amazon.com/eks/latest/best-practices/cluster-upgrades.html |
| EKS Auto Mode | https://docs.aws.amazon.com/eks/latest/userguide/automode.html |
| Karpenter drift | https://karpenter.sh/docs/concepts/disruption/#drift |
