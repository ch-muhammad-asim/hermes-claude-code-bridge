# 📦 Workloads — StatefulSet, Service, IngressRoute

| File | Kind | Notes |
|---|---|---|
| `statefulset.yaml` | StatefulSet | Two containers + two init containers + the state PVC |
| `service.yaml` | Service (ClusterIP) | `8642` API · `9119` dashboard · `18182` bridge (in-cluster debugging only — the IngressRoute never routes to it) |
| `ingressroute.yaml` | Traefik IngressRoute | `hermes.saqlainmushtaq.com` on the `websecure` entrypoint |

## 🧱 Why a StatefulSet and not a Deployment

The agent has durable state on a `ReadWriteOnce` PVC — pairing memory, approved Slack
users, skills, the image cache, `config.yaml`. A StatefulSet gives a stable pod identity
(`hermes-agent-0`) and a stable volume binding; a Deployment rolling a second replica
would deadlock on the RWO volume.

## 🔄 Container roles

| Container | Job |
|---|---|
| `init-runtime-tools` (init) | Installs `kubectl` (pinned to the cluster's stable release) and `gh` (latest release, **checksum-verified** against GitHub's published `checksums.txt`) onto the PVC |
| `init-hermes-config` (init) | Renders `config.yaml`: model + provider, MCP servers, compaction, I/O limits, hardening, the block-installs hook. Installs `SOUL.md` and the skills. Idempotent across restarts |
| `hermes` | Gateway, dashboard, MCP client, skills, `kubectl`, `gh` |
| `bedrock-claude-bridge` | chat-completions ⇄ Anthropic Messages against Bedrock |

## ⚠️ Details that cost hours if changed carelessly

- **`AWS_REGION` on the bridge is required.** Pod Identity (and IMDS) supply credentials
  but no default region; unset, boto3 fails at startup with `NoRegionError`.
- **`ANTHROPIC_MODEL` must stay an inference profile** (`us.anthropic.claude-sonnet-4-5-…`).
  Claude Sonnet 4.5 is `INFERENCE_PROFILE`-only on Bedrock; a bare foundation-model id
  returns `ValidationException`. It must also match the IAM policy in
  `../../../aws/modules/hermes-bedrock-iam`.
- **`context_length: 200000`** is pinned because Hermes cannot probe a custom bridge and
  would default to 256k — *overstating* Sonnet 4.5's window and getting requests rejected
  mid-thread. The 1M window is a separate opt-in, not the default.
- **`storageClassName: gp3`** is EKS-specific. On k3s, `../../overlays/k3s` patches it to
  `local-path`; the `gp3` provisioner does not exist there and the PVC would sit `Pending`.
- **Bridge readiness is 30s**, not 15s — the container `pip install`s boto3 before binding.
- **The GitHub App Secret is `optional: true`** on both the volume and the env vars, so
  the pod starts with no GitHub App configured. Drop that and a fresh cluster hangs in
  `ContainerCreating`.
- **`/health` on the bridge never invokes the model.** The probe runs every 10s; a
  token-spending probe would drain a metered allowance before anyone asked a question.

## 🌐 IngressRoute ordering

Routes are declared most-specific-first — `/v1` and `/health` to the API port (8642),
then `/` to the dashboard (9119). Traefik sorts by rule length anyway, but explicit
ordering means the catch-all cannot silently swallow the API.

`ingressClassName: traefik-external` must match your Traefik install. A class no
controller watches is **silently never picked up** — no error, no route:

```bash
kubectl get ingressclass
```
