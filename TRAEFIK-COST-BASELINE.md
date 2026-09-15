# Traefik cost/runtime baseline

This repository contains multiple Traefik controller deployments. Keep each deployment pinned to its existing chart version and apply the resource/runtime baseline through that chart's supported values schema.

## Baseline

```yaml
resources:
  requests:
    cpu: 100m
    memory: 128Mi
  limits:
    cpu: null
    memory: 512Mi

env:
  - name: GOMAXPROCS
    value: "2"
```

The existing memory request is preserved. Kubernetes schedules primarily from resource requests, so the `100m` CPU request can improve bin packing and cluster-autoscaler consolidation compared with larger requests. The CPU limit is intentionally unset so Traefik can burst when spare node CPU exists. `GOMAXPROCS=2` controls Go execution parallelism; it does not request or reserve two CPUs.

The `512Mi` memory limit is a hard ceiling. Validate it against representative peak traffic because exceeding it can cause an OOM termination.

## Deployments in this repository

| Path | Platform | Helm chart | Notes |
|---|---|---:|---|
| `kubernetes/traefik/gke-values.yaml` | GKE | `41.0.2` | Single replica, external GKE LoadBalancer |
| `omniroute/kubernetes/traefik/gke-values.yaml` | GKE | `41.0.2` | Same controller contract for the OmniRoute/Hermes stack |
| `aws/kubernetes/traefik/eks-values.yaml` | EKS | `41.3.0` | Two replicas, system-node selector, PDB preserved |
| `aws-bedrock/traefik/k3s-values.yaml` | K3s | `41.3.0` | Single replica, K3s ServiceLB, PDB disabled |

Traefik chart `41.0.2` and `41.3.0` both default `deployment.goMemLimitPercentage` to `0.9`. Because these values set a memory limit, the chart derives `GOMEMLIMIT` automatically. Do not add a separate `GOMEMLIMIT` unless intentionally overriding the chart-native behavior.

## Render checks

GKE 41.0.2:

```bash
helm template traefik traefik/traefik \
  --namespace traefik \
  --version 41.0.2 \
  --values kubernetes/traefik/gke-values.yaml > /tmp/traefik-gke.yaml
```

EKS 41.3.0:

```bash
helm template traefik traefik/traefik \
  --namespace traefik \
  --version 41.3.0 \
  --values aws/kubernetes/traefik/eks-values.yaml > /tmp/traefik-eks.yaml
```

K3s 41.3.0:

```bash
helm template traefik traefik/traefik \
  --namespace traefik \
  --version 41.3.0 \
  --values aws-bedrock/traefik/k3s-values.yaml > /tmp/traefik-k3s.yaml
```

Before rollout, inspect the rendered Traefik container and verify:

- CPU request: `100m`
- memory request: the existing value (`128Mi` in these files)
- no CPU limit
- memory limit: `512Mi`
- `GOMAXPROCS="2"`
- chart-generated `GOMEMLIMIT` remains present for chart 41

After rollout, monitor memory working set, OOM kills, restarts, p95/p99 latency, CPU throttling, HPA behavior if enabled, and cluster-autoscaler/Karpenter consolidation events.
