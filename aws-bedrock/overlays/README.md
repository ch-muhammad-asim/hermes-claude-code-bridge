# 🧩 Overlays — cluster-flavour patches

The base (`../hermes`) targets **EKS**. An overlay adapts it to a cluster that differs,
without weakening the base — so the base stays correct for the environment it was written
for.

| Overlay | For | Patches |
|---|---|---|
| `k3s/` | Single-node k3s on EC2 (`../../aws/modules/hermes-k3s`) | Deletes the `gp3` StorageClass; repoints the PVC at `local-path` |

```bash
kubectl apply -k k3s
```

## 🤔 Why k3s needs an overlay at all — and why it needs so little

Only **storage** differs. `gp3`'s provisioner (`ebs.csi.aws.com`) is not installed on k3s,
so the StorageClass would apply but never bind and the PVC would sit `Pending`. k3s ships
`local-path` as its default instead.

Notably absent is any credential patch. On EKS, Bedrock access arrives via a Pod Identity
association; on EC2 it arrives via the instance profile through IMDS. **Neither needs a
manifest change** — boto3's default credential chain resolves both — which is why the
bridge is byte-identical on the two platforms. The overlay carries a comment saying so, so
nobody goes hunting for a patch that does not exist.

## ➕ Adding an overlay

Patch the smallest thing that differs, and say *why* in a comment. If an overlay starts
duplicating the base, the difference probably belongs in the base as a variable instead.
