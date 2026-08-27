# ⚡ Karpenter layer

Karpenter replaces Cluster Autoscaler. Instead of resizing pre-declared node
groups, it reads pending pods, computes the cheapest instance that fits them,
and launches it directly through the EC2 fleet API. Node groups stop being a
capacity-planning exercise.

## 📦 What the layer creates

| Resource | Purpose |
|---|---|
| Controller IAM role + **EKS Pod Identity** association | Karpenter's AWS permissions, with no OIDC trust policy to maintain |
| Node IAM role + instance profile | Identity the provisioned nodes assume |
| EKS access entry for the node role | Lets Karpenter nodes join without touching `aws-auth` |
| SQS queue + EventBridge rules | Interruption, rebalance, instance-state and scheduled-maintenance events |
| Helm release (`kube-system`) | The controller itself, 2 replicas, spread across hosts |
| `EC2NodeClass/default` | What an instance looks like - AMI, subnets, SGs, disk, metadata |
| `NodePool/default` | What may be provisioned, and when it is torn down |

## 🎛️ Settings and why they are set that way

**Pod Identity over IRSA.** IRSA needs an OIDC provider and a role trust policy
keyed to a service account name. Pod Identity is an EKS API association, which
means it survives cluster recreation cleanly and shows up in `aws eks
list-pod-identity-associations` rather than buried in a trust policy.

**Controller on the system node group.** Karpenter cannot manage the capacity
it runs on - if it drained its own node it would have nothing left to schedule
itself onto. The chart's default affinity already refuses Karpenter-owned
nodes; the `workload-type: system` node selector pins it explicitly.

**Two replicas with a topology spread.** Karpenter is leader-elected. The
second replica is standby, and spreading them across hosts means one node loss
does not stall provisioning.

**Memory limit but no CPU limit.** Throttling the scheduling loop directly
slows every scale-up, so CPU is left unbounded. Memory is capped to bound the
blast radius of a leak.

**`consolidationPolicy: WhenEmptyOrUnderutilized`.** The `WhenEmpty` policy
only reclaims nodes with nothing on them. `WhenEmptyOrUnderutilized` also
repacks nodes whose pods would fit elsewhere, which is where the savings
actually come from. `consolidateAfter: 1m` keeps it from thrashing on churn.

**Disruption budget as a node count, not a percentage.** Percentage budgets
round down, so on a small cluster `10%` evaluates to zero nodes and silently
blocks all consolidation. `nodes: "1"` is unambiguous.

**`expireAfter: 168h`.** Forced weekly rotation is how AMI and kernel patches
land. Without it, nodes live until something else disrupts them, and drift
accumulates.

Together with `amiSelectorTerms: alias al2023@latest`, this is what gives the
data plane GKE-style node auto-upgrade at no extra cost: a new AL2023 release
marks nodes `Drifted` and Karpenter replaces them, respecting PodDisruptionBudgets
and the NodePool disruption budget. The control-plane side of that story is in
[auto-upgrade](../auto-upgrade/).

**`terminationGracePeriod: 24h`.** A ceiling on how long a drain may hang. A
pod with a broken `preStop` hook or a PDB that can never be satisfied will
otherwise block node deletion indefinitely.

**IMDSv2 required, hop limit 1.** A hop limit of 1 stops a container from
reaching instance metadata and borrowing the node role - the classic path from
"pod compromise" to "node credentials".

**`limits.cpu`.** A hard ceiling on the fleet. Without limits, a runaway
ReplicaSet provisions until it hits an AWS quota, which is a far more expensive
way to discover the problem.

**Discovery by tag.** Subnets and security groups are selected on
`karpenter.sh/discovery = <cluster name>`, set by the VPC and EKS layers. Note
this is the v1 tag key: v1alpha5 used `karpenter.sh/discovery/<cluster>`, and
carrying the old key forward is a common upgrade failure.

## 🎯 Tuning for production

The defaults here are shaped by the sandbox. Outside it, change these:

**Put spot back.** Spot is where Karpenter earns its keep:

```hcl
capacity_types = ["spot", "on-demand"]
```

Karpenter's price-capacity-optimised allocation picks from the spot pools least
likely to be interrupted, and falls back to on-demand when none are available.
Keep `enable_interruption_queue = true` so nodes drain on the two-minute
warning instead of disappearing.

**Widen the instance requirements.** Narrow requirements defeat the whole
mechanism - Karpenter bin-packs better and prices better the more shapes it can
choose from. Prefer excluding what you cannot use over enumerating what you
can:

```hcl
instance_families = ["c", "m", "r"]
instance_sizes    = ["large", "xlarge", "2xlarge"]
```

**Pin the AMI alias.** `al2023@latest` means an upstream AMI release rolls your
fleet on the next drift evaluation. Pin a dated alias (`al2023@v20260801`) and
bump it deliberately.

**Add disruption blackout windows** for change-freeze periods:

```hcl
budgets = [
  { nodes = "10%" },
  { nodes = "0", schedule = "0 9 * * mon-fri", duration = "8h" },
]
```

**Give every workload a PDB.** Consolidation is only as safe as the disruption
budgets you give it.

## 🛠️ Operating notes

Watch what the controller decides:

```bash
kubectl logs -n kube-system -l app.kubernetes.io/name=karpenter -f
```

Inspect claims in flight:

```bash
kubectl get nodeclaims -o wide
```

Explain why a node is or is not being removed:

```bash
kubectl get nodeclaim -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.conditions[?(@.type=="Drifted")].status}{"\n"}{end}'
```

A NodePool that provisions nothing is almost always one of: requirements that
no allowed instance type satisfies, a `limits` ceiling already reached, or
subnet/security-group tags that do not match the selector.
