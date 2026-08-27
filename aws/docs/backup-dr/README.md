# 💾 Backup and disaster recovery for EKS

Terraform recreates infrastructure. It does not recreate **state** - the data in
your persistent volumes, the Secrets and ConfigMaps applied outside the repo,
the CRDs an operator wrote at runtime. A blueprint that only covers
`terragrunt apply` has covered the easy half.

This page is the production checklist that the sandbox deployment deliberately
does not implement, and what a senior engineer is expected to have answers for
before a cluster carries anything that matters.

## 🧊 What is actually at risk

| Layer | Recreatable from this repo? | Real risk |
|---|---|---|
| VPC, cluster, node groups, IAM | ✅ yes, `terragrunt apply` | low - it is all code |
| Karpenter NodePool / EC2NodeClass | ✅ yes | low |
| Add-ons | ✅ yes | low |
| **PersistentVolume data** | ❌ no | **total loss** |
| **Secrets applied out-of-band** | ❌ no | **total loss** |
| **CRs written by operators at runtime** | ❌ no | **total loss** |
| Container images | ⚠️ only if the registry survives | ECR is a separate blast radius |

The EKS **control plane itself needs no backup** - AWS runs and replicates etcd.
You cannot snapshot it, and you do not need to. What you are protecting is the
cluster's *contents*.

## 🛡️ AWS Backup for Amazon EKS

AWS Backup supports EKS as a first-class, **native** resource type - the same
way it protects RDS or EBS. A single backup job produces a **composite recovery
point** containing:

- **EKS cluster state** - the Kubernetes manifests defining desired state:
  Secrets, ConfigMaps, StatefulSets, DaemonSets, StorageClasses, PVCs, CRDs,
  Roles and RoleBindings; plus cluster metadata such as add-ons, access entries,
  managed node groups and Pod Identity associations.
- **Persistent storage** - nested recovery points for EBS, EFS and S3 volumes
  attached through PVCs and supported CSI drivers.

Verify the resource type is enabled in your region:

```bash
aws backup describe-region-settings --query "ResourceTypeOptInPreference.EKS"
```

Verified on this account, 2026-08-27: `true`

### ✅ Prerequisite this blueprint already satisfies

AWS Backup needs the cluster's authorization mode set to `API` or
`API_AND_CONFIG_MAP` so it can create its own access entry. This blueprint uses
`API` (see [migration](../migration/)), so no change is required:

```bash
aws eks describe-cluster --name cloudgeeks-eks-dev --query "cluster.accessConfig.authenticationMode"
```

No agent, operator or add-on is installed in the cluster.

### ⚠️ What it does not cover

Straight from the AWS documentation - these are the gaps people discover during
a restore, not during planning:

- **Container images** from ECR or Docker Hub are not backed up.
- **Infrastructure components** - VPCs, subnets, and so on - are not backed up.
  That is Terraform's job, which is why the state bucket matters as much as the
  backup vault.
- **Auto-generated resources** - nodes, pods, events, leases, Jobs - are skipped.
- Volumes provisioned by **in-tree plugins or CSI migration** are not supported,
  only genuine CSI volumes. The `volume.kubernetes.io/storage-provisioner`
  annotation does not prove CSI - the StorageClass decides.
- **FSx via CSI** is unsupported; **EFS with non-root subpath mounts** is
  unsupported; **cross-account EFS** is unsupported.
- The cluster-state recovery point is always a **full** backup; only the volume
  children are incremental.

A job may finish as `Partial` or `Completed with issues` - meaning some nested
resources did not back up. Treat either as a failed backup, because that is what
it will feel like during a restore. Subscribe to notifications rather than
reading job statuses by hand.

### 📅 A minimal production plan

```bash
aws backup start-backup-job --backup-vault-name my-backup-vault --resource-arn arn:aws:eks:us-east-1:111122223333:cluster/my-cluster --iam-role-arn arn:aws:iam::111122223333:role/AWSBackupDefaultServiceRole --lifecycle MoveToColdStorageAfterDays=30,DeleteAfterDays=365
```

In practice you want a scheduled backup plan rather than on-demand jobs, with:

- a **separate vault**, ideally in a **separate account**, with vault lock
  enabled - a backup an attacker can delete is not a backup
- **cross-region copy** if your RTO survives a regional event
- retention matched to a stated RPO, not to a number someone liked

## 🧩 Native, with no agent in the cluster

AWS Backup protects EKS **natively**. There is no agent, operator or Helm chart
to install in the cluster - AWS Backup creates its own access entry and reads
the cluster through the Kubernetes API. From the AWS documentation:

> "AWS Backup does not require any agents or add-ons to be installed on your
> Amazon EKS cluster."

That matters for more than convenience. Any backup controller running inside
the cluster shares the cluster's failure modes and its blast radius: it needs
cluster-admin-level RBAC, it competes for the same nodes, and it can be
unavailable in exactly the scenario where you need it. Keeping the compliance
copy outside the data plane - in a service with its own IAM boundary, audit
trail and vault lock - is the stronger default.

That is an argument for AWS Backup being your *baseline*, not an argument
against in-cluster tooling entirely. Velero solves problems AWS Backup does
not, and the two compose well - see below.

Everything the cluster needs is already in place here: `authenticationMode` is
`API`, so AWS Backup can create its access entry, and the EBS CSI driver is
installed as a managed add-on, so PersistentVolumes are backed by genuine CSI
volumes that AWS Backup supports.

## 🔁 Velero, alongside AWS Backup

**Velero** is the Kubernetes-native backup tool, and it is worth running *in
addition to* AWS Backup rather than instead of it. The two cover different
ground:

| | AWS Backup | Velero |
|---|---|---|
| Native EKS resource support | ✅ first-class, no agent | ⚠️ controller + node agent you operate |
| Managed, audited, IAM-integrated | ✅ | ❌ your responsibility |
| Vault lock / immutability | ✅ | ⚠️ depends on the object store |
| Compliance and retention reporting | ✅ | ❌ |
| Cross-cloud and on-premises | ❌ AWS only | ✅ portable |
| Namespace- or label-scoped restore | ⚠️ limited | ✅ granular |
| Backup hooks (quiesce a database mid-backup) | ❌ | ✅ |
| Cluster-to-cluster migration | ❌ | ✅ |

### How the two divide up in practice

- **AWS Backup** is the compliance and disaster-recovery copy: scheduled,
  immutable, cross-region, cross-account, reportable, and outside the cluster's
  blast radius. This is the one an auditor asks about.
- **Velero** is the operational tool: restore a single namespace a team dropped,
  quiesce a database with a pre-backup hook so the snapshot is consistent, or
  lift a workload into a different cluster during a migration or a version
  upgrade rehearsal.

A useful rule: if the question is *"can we prove we can recover the cluster"*,
that is AWS Backup. If the question is *"can we put this one namespace back the
way it was an hour ago"*, that is Velero.

Velero is not deployed by this blueprint. When you add it, give it its own IAM
role through Pod Identity, its own S3 bucket with versioning and object lock,
and a `VolumeSnapshotClass` wired to the EBS CSI driver already installed here.

## 🧪 The part everyone skips

**A backup you have never restored is a hypothesis.**

Schedule a restore drill on a cadence you can defend - quarterly is common -
and measure the two numbers that actually get asked for during an incident:

- **RPO** - how much data you lose, set by backup frequency
- **RTO** - how long a full restore takes, which you only know by doing it

Restore into a *different* cluster. Restoring over the running one is not a
drill, it is an outage.

## ⬆️ Before a version upgrade

Backups and upgrades are the same conversation, because an upgrade is the most
common planned event that can lose you data.

Before bumping `kubernetes_version`:

1. Take an on-demand backup and confirm it reached `Completed`, not `Partial`.
2. Confirm every upgrade-readiness insight passes:

```bash
aws eks list-insights --cluster-name cloudgeeks-eks-dev --query "insights[?insightStatus.status!='PASSING']"
```

3. Check for API removals in the target version's release notes - deprecated
   APIs are the usual cause of a broken upgrade, and no backup product fixes a
   manifest that the new API server rejects.
4. Upgrade a non-production cluster on the same version first.

Details of the upgrade mechanics are in [auto-upgrade](../auto-upgrade/).

## 📚 Official documentation

| Topic | Link |
|---|---|
| Amazon EKS backups in AWS Backup | https://docs.aws.amazon.com/aws-backup/latest/devguide/eks-backups.html |
| What is AWS Backup | https://docs.aws.amazon.com/aws-backup/latest/devguide/whatisbackup.html |
| Backup feature availability by resource | https://docs.aws.amazon.com/aws-backup/latest/devguide/backup-feature-availability.html |
| AWS Backup Vault Lock | https://docs.aws.amazon.com/aws-backup/latest/devguide/vault-lock.html |
| Backup notifications | https://docs.aws.amazon.com/aws-backup/latest/devguide/backup-notifications.html |
| EKS best practices - protecting the cluster | https://docs.aws.amazon.com/eks/latest/best-practices/protecting-the-cluster.html |
| EKS best practices - cluster upgrades | https://docs.aws.amazon.com/eks/latest/best-practices/cluster-upgrades.html |
| EKS storage and CSI drivers | https://docs.aws.amazon.com/eks/latest/userguide/storage.html |
| Velero documentation | https://velero.io/docs/ |
| Velero AWS plugin | https://github.com/vmware-tanzu/velero-plugin-for-aws |
