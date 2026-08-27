# 🧪 Pluralsight AWS cloud sandbox - limits that shape this blueprint

Source: [AWS cloud sandbox](https://help.pluralsight.com/hc/en-us/articles/24425443133076-AWS-cloud-sandbox)

The sandbox is a real AWS account with guardrails enforced above your IAM user.
The user's own policy looks permissive (`allow_all` minus Lightsail and
SageMaker); the real limits are applied at the organisation level, so you find
them by hitting them. These are the ones that matter for EKS.

## 🚧 Hard limits

| Limit | Value | Where this repo handles it |
|---|---|---|
| Regions | `us-east-1`, `us-west-2` only | `validation` block on `var.region` in every module |
| EC2 instance types | t2, t3, t3a, t4g - **micro, small, medium only** | `node_instance_types`, NodePool `instance-family` / `instance-size` requirements |
| EC2 Spot | ⛔ **Will not support** | `capacity_type = "ON_DEMAND"`, NodePool `capacity_types = ["on-demand"]` |
| Concurrent EC2 instances | 9 (stopped included, terminated excluded) | 2-node system group + NodePool `limits.cpu = 12` (6 x t3.medium) |
| EBS volume size | 100 GiB max | `node_disk_size` defaults to 50, with a `validation` block at 100 |
| EKS versions | ⚠️ Standard support only - extended support blocked | `kubernetes_version = "1.36"` in `env.hcl`, plus `cluster_support_type = "STANDARD"` - see [auto-upgrade](../auto-upgrade/) |
| Fargate | 4 running tasks, 2048 CPU / 4096 memory | not used here |
| Billing / Cost Explorer | no access | nothing in this repo reads cost data |

## ⚠️ Consequences worth knowing

**No Spot changes the Karpenter story.** Most Karpenter material leads with
spot-first NodePools and interruption handling. In the sandbox that path simply
fails to provision. The NodePool here is on-demand only, and the guidance for
putting spot back is in [karpenter](../karpenter/).

**The nine-instance ceiling is account-wide**, not per cluster or per node
group. The NodePool's `limits.cpu` is the backstop: at 2 vCPU per t3.medium,
12 vCPU caps Karpenter at six nodes, leaving three slots for the system node
group and anything else running in the account. Raise `node_desired_size` and
you must lower `node_cpu_limit` to match.

**t3.medium is small for a Kubernetes node.** 2 vCPU / 4 GiB, and the VPC CNI,
kube-proxy, CoreDNS and Karpenter controller all want a share. Prefix
delegation is enabled on the CNI so pod IP allocation is not the binding
constraint, but expect roughly 8-12 usable application pods per node.

**Extended-support versions are blocked on cost**, so a cluster left running
past a version's standard-support window cannot simply sit there. Note that AWS
defaults every cluster to `upgradePolicy.supportType = EXTENDED`, which would
drift straight into the forbidden state - this blueprint sets `STANDARD`
explicitly, see [auto-upgrade](../auto-upgrade/). Check what is
current before pinning:

```bash
aws eks describe-cluster-versions --query 'clusterVersions[?status==`STANDARD_SUPPORT`].clusterVersion'
```

## 🧹 Sandbox hygiene

Sandbox sessions are time-boxed and reaped. Destroy in reverse dependency order
before the session expires, or the reaper leaves orphaned ENIs and security
groups that block the next VPC create.
