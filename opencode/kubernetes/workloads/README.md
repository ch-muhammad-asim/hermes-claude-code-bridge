# 📦 workloads/

| File | Resource | Notes |
|------|----------|-------|
| `statefulset.yaml` | `StatefulSet/hermes-agent` | 4 init containers, 2 runtime containers, one 20Gi PVC |
| `service.yaml` | `Service/hermes-agent` | ClusterIP for the gateway (`8642`) and dashboard (`9119`) |
| `ingressroute.yaml` | `IngressRoute/hermes-agent-dashboard` | Traefik v3 routes; needs Traefik's CRDs installed |

## Why a StatefulSet with one replica

The agent is stateful: OpenCode releases, kubectl, Hermes' `config.yaml`, skills, and the workspace all live on the PVC (`ReadWriteOnce`). A second replica would contend on the same volume, and Hermes' gateway is not designed to be sharded. Scale the *models* (bigger context, different free model), not the pods.

## Ports

`hermes` exposes `8642` (API) and `9119` (dashboard), both fronted by the Service and the IngressRoute.

The bridge's `18282` is listed on the container for readability only — the bridge binds `127.0.0.1`, so it is reachable from `hermes` (same pod network namespace) and from nowhere else. It is deliberately **not** in the Service: nothing outside the pod should be able to drive the OpenCode CLI, even from inside the cluster.

## Editing

- **Images and the bridge port come from the ConfigMaps** via Kustomize replacements — edit `configmaps/`, not the pod spec. Verify a change landed with `kubectl kustomize ..`.
- **The domain** is set once in `../kustomization.yaml` (`hermes-params.HERMES_DOMAIN`) and fanned out to all three `Host()` routes. The literal in `ingressroute.yaml` is a placeholder.
- **`ingressClassName: traefik-external`** must match your Traefik install. An `ingress.class` *annotation* naming a class no Traefik instance watches is silently ignored — the repo's [`../../../kubernetes/traefik`](../../../kubernetes/traefik) chart values are the reference install.

## Probes

`hermes` uses HTTP `/health` on the API port. The bridge uses an exec probe that curls its own `/health` with the bearer token, with `failureThreshold: 6` and a 20s delay — first boot has to npm-install OpenCode and resolve the model catalogue, so a tight probe would restart the container mid-install.

## Render locally

```bash
kubectl kustomize ..                       # full stack, no cluster needed
kubectl apply --dry-run=client -k ..       # schema-validates built-ins; IngressRoute needs the CRDs
```
