# 🚦 Traefik values for the k3s cluster

`k3s-values.yaml` is derived from
[`../../aws/kubernetes/traefik/eks-values.yaml`](../../aws/kubernetes/traefik/eks-values.yaml)
— same chart version, same entrypoints, same `traefik-external` IngressClass, same
access-log and metrics posture. Only the Service and scheduling differ.

| | EKS values | k3s values |
| --- | --- | --- |
| Service | `LoadBalancer` + AWS LB Controller annotations (NLB, `target-type: ip`, `/ping` health check) | plain `LoadBalancer` — k3s servicelb (klipper) binds host 80/443 |
| Replicas | 2 | 1 (single node) |
| `nodeSelector` | `workload-type: system` (keeps ingress off Karpenter capacity) | none — one node, and the label does not exist |
| PodDisruptionBudget | enabled, `maxUnavailable: 1` | disabled — a PDB on a single replica only blocks eviction of the only pod |

## 📌 Install

One `CHART_VERSION` drives both the CRDs and the chart, so they cannot drift:

```bash
export CHART_VERSION=41.3.0
```

```bash
helm repo add traefik https://traefik.github.io/charts && helm repo update
```

CRDs **before** the chart — otherwise the `IngressRoute` kind does not exist yet:

```bash
helm show crds traefik/traefik --version "$CHART_VERSION" | kubectl apply --server-side --force-conflicts -f -
```

```bash
helm -n traefik upgrade --install traefik traefik/traefik --version "$CHART_VERSION" --create-namespace --values k3s-values.yaml --wait --timeout 6m
```

## 🔍 Verify

```bash
kubectl -n traefik get pods,svc
```

The IngressClass the IngressRoute names must exist, or the route is silently never
picked up:

```bash
kubectl get ingressclass
```

A 404 from the node's IP is the **correct** answer before any route matches — it proves
Traefik is terminating the connection:

```bash
curl -sk -o /dev/null -w '%{http_code}\n' https://<NODE_IP>/
```

## 🧷 Why k3s's packaged Traefik is disabled

`modules/hermes-k3s` installs k3s with `--disable traefik`. k3s ships Traefik **v2** as
a packaged HelmChart; leaving it enabled means two controllers watching the same
IngressClass and competing for the same host ports. `servicelb` is deliberately left
**enabled** — it is what gives a `type: LoadBalancer` Service an address on a cluster
with no cloud controller.
