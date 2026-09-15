# 📦 Workloads

The runtime Kubernetes objects for the Hermes Agent, applied via [`../kustomization.yaml`](../kustomization.yaml).

| File | Kind | Purpose |
|------|------|---------|
| `statefulset.yaml` | `StatefulSet` | 🧠 The `hermes` container (gateway + dashboard) and the `claude-bridge` sidecar, init containers, PVC-backed state, and secret mounts. Image tags are injected from ConfigMaps via Kustomize `replacements`. |
| `service.yaml` | `Service` | 🔀 ClusterIP fronting the gateway API (`8642`) and dashboard (`9119`). |
| `ingressroute.yaml` | `IngressRoute` (Traefik) | 🌐 TLS host routing for `hermes.saqlainmushtaq.com` — the `Host()` rule is injected from `hermes-params.HERMES_DOMAIN`. Needs the Traefik controller from [`../traefik`](../traefik). |

> 🔗 Pod identity and read-only cluster access come from [`../hermes-service-account`](../hermes-service-account); the bridge/runtime behavior is configured by [`../configmaps`](../configmaps).
