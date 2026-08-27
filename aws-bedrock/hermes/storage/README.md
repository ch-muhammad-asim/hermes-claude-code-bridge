# 💾 Storage

`storageclass.yaml` declares the **gp3** StorageClass the StatefulSet's
`volumeClaimTemplates` asks for.

## ❓ Why this file exists

The Vertex/GKE manifests request `standard-rwo`, a GKE class that does not exist on EKS —
the PVC would sit `Pending` forever with
`storageclass.storage.k8s.io "standard-rwo" not found`. EKS ships `gp2` as its default
instead. Rather than depend on whatever a given cluster happens to default to, the class
is declared explicitly here.

## 🔧 Choices worth knowing

- **gp3 over gp2** — same price per GB, but 3000 IOPS and 125 MiB/s baseline are included.
  A 20Gi *gp2* volume gets only 100 IOPS, because gp2 derives IOPS from size.
- **`volumeBindingMode: WaitForFirstConsumer`** — an EBS volume is single-AZ, so it must be
  created in the AZ the pod actually lands in. `Immediate` provisions first and can strand
  the pod with a `volume node affinity conflict` it can never satisfy.
- **Not marked default** — leaving EKS's `gp2` as the cluster default avoids surprising
  every other workload.
- **`encrypted: true`** — encryption at rest with the account's default EBS KMS key.

## 🐧 On k3s

There is no EBS CSI driver, so `../../overlays/k3s` deletes this StorageClass and patches
the PVC to `local-path` (Rancher's local provisioner, which k3s installs and defaults to).
That is node-local storage — correct for a single-node cluster, and not something to carry
into a multi-node one.

```bash
kubectl get storageclass
```
