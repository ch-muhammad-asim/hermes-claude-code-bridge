<div align="center">

# 🌉 Hermes × Claude Code Bridge

**Run [Claude Code](https://claude.com/claude-code) as an OpenAI-compatible backend — anywhere.**
From a single Windows laptop to a production GKE cluster, with a **security-first, read-only** operations posture. 🔒

[![Deploy: macOS](https://img.shields.io/badge/deploy-macOS-000000?logo=apple&logoColor=white)](./mac)
[![Deploy: Windows](https://img.shields.io/badge/deploy-Windows-0078D6?logo=windows&logoColor=white)](./windows)
[![Deploy: Ubuntu](https://img.shields.io/badge/deploy-Ubuntu%20Desktop-E95420?logo=ubuntu&logoColor=white)](./ubuntu-desktop)
[![Deploy: Docker](https://img.shields.io/badge/deploy-Docker-2496ED?logo=docker&logoColor=white)](./docker)
[![Deploy: Kubernetes](https://img.shields.io/badge/deploy-Kubernetes-326CE5?logo=kubernetes&logoColor=white)](./kubernetes)

<br/>

[![▶️ Watch the demo on YouTube](https://img.shields.io/badge/▶️%20Watch%20the%20Demo-YouTube-FF0000?style=for-the-badge&logo=youtube&logoColor=white)](https://www.youtube.com/watch?v=m8k2GGRldiU)

</div>

---

> ### 🎥 Watch it in action
> **[I Turned Claude Code Into an OpenAI-Compatible SRE Agent on GKE 🤖☸️](https://www.youtube.com/watch?v=m8k2GGRldiU)**
> A full walkthrough — deploying the read-only agent on GKE, and watching Hermes **diagnose and fix** a broken Kubernetes deployment through the three-gate security model, then revoke access.
> 📺 More cloud/DevOps/SRE deep-dives on [**@devopsgang**](https://www.youtube.com/@devopsgang).

---

## 🧭 What is this?

A small, dependency-light **HTTP bridge** that turns your authenticated **Claude Code CLI** into an **OpenAI-compatible `/v1/chat/completions` endpoint**. Any tool, SDK, or agent gateway that speaks the OpenAI API can now use Claude Code as its model backend — with streaming, real token accounting, concurrency control, and tool-permission enforcement.

It ships with five production-tested ways to run it, and pairs with the **Hermes agent gateway** to deliver a read-only **Lead DevOps/SRE investigation assistant** ("Hermes SRE") that reasons across Kubernetes, GitHub, and Google Cloud observability — **without any write access**.

```
                ┌──────────────────────────────┐
   OpenAI-      │        Claude Code Bridge      │        ┌────────────────────┐
   compatible ─▶│  /v1/chat/completions (SSE)    │──────▶ │   claude CLI        │
   clients      │  concurrency · streaming · auth │        │ (your auth login)   │
                └──────────────────────────────┘        └─────────┬──────────┘
                                                                   │ read-only MCP
                                    ┌──────────────────────────────┼──────────────┐
                                    ▼                ▼                ▼
                              GCP Logging/      GitHub (SRE       kubectl
                              Monitoring/Trace  read-only)        (get/describe/logs)
```

---

## 🤖 One-shot deploy (agent-driven)

Want the whole production stack stood up for you? Point a coding agent (Claude Code / Hermes) at
[`ai-deploy/`](./ai-deploy) and say **_"deploy hermes agent."_** That runbook checks prerequisites
and orchestrates **GCP VPC → GKE → Traefik → Hermes** end-to-end, then hands you working dashboard
credentials and the DNS record to set. Prefer to do it by hand? Pick a target below.

---

## 🚀 Pick your deployment

| | Environment | Best for | Guide |
|---|-------------|----------|-------|
| 🍎 | **macOS** | Local dev on a Mac (no Docker); powers the Hermes desktop app | [`mac/`](./mac) |
| 🪟 | **Windows 10/11** | Local dev on a Windows laptop (no Docker/WSL) | [`windows/`](./windows) |
| 🐧 | **Ubuntu Desktop** | Local dev / a dedicated Linux box | [`ubuntu-desktop/`](./ubuntu-desktop) |
| 🐳 | **Docker (Compose)** | Two-service Compose stack — bridge + Hermes, **Opus 5** default with **Fable 5** optional; runs anywhere Docker does | [`docker-bridge/`](./docker-bridge) |
| 🐳 | **Docker (script)** | Scripted runtime with host-mode proxy and lifecycle subcommands (needs `flock`) | [`docker/`](./docker) |
| ☸️ | **Kubernetes (GKE)** | Production: Hermes gateway + bridge sidecar, TLS, autoscaling | [`kubernetes/`](./kubernetes) |
| 🧩 | **The bridge itself** | Cross-platform launcher + the Python bridge | [`claude-bridge-with-hermes/`](./claude-bridge-with-hermes) |

Every deployment exposes the same endpoint: **`http://<host>:18181/v1`**. Default model is
`claude-opus-4-8`, except [`docker-bridge/`](./docker-bridge) which defaults to **`claude-opus-5`** and
also advertises **`claude-fable-5`** as an optional pick.

**Native cloud-provider models (no Claude Code CLI, no Claude subscription):**

Hermes talks to a pod-local bridge sidecar that translates chat-completions into the
cloud provider's own Anthropic Messages API, authenticating with keyless workload
credentials. The bridge listens on **`http://127.0.0.1:18182/v1`** — pod-local, never
public. One directory per cloud:

| | Cloud | Model | Identity | Ingress | Guide |
|---|---|---|---|---|---|
| ☁️ | **Google Cloud** — Vertex AI on GKE | `claude-opus-4-8`, or `gemini-3.5-flash` (deployed default) | GKE Workload Identity → GSA | Traefik `IngressRoute` | [`vertex-ai/`](./vertex-ai) |
| 🟧 | **AWS** — Bedrock on EKS or k3s | **Claude Sonnet 4.5** (`us.anthropic.claude-sonnet-4-5`, inference-profile only) | EKS Pod Identity, or EC2 instance profile | Traefik `IngressRoute` | [`hermes-agent/aws-bedrock/`](./hermes-agent/aws-bedrock) |

The AWS deployment is a port of the Google one — same Hermes runtime config, same
hardening posture, same chat-completions ⇄ Anthropic Messages translation. It adds one
capability the Google path does not have: **scoped Kubernetes write access, so the agent
repairs a broken workload instead of only reporting it.** Read-only everywhere else,
enforced by RBAC rather than by trusting the model.

Why either of these instead of the CLI path: native Kubernetes ServiceAccount RBAC,
cloud-native IAM and billing, and no dependency on `claude -p`. The tradeoff is that you
own the translation bridge — so prompt caching, retries and cost telemetry are
implemented in it.

**Same protocol, different agent CLI:**

| | Environment | Best for | Guide |
|---|-------------|----------|-------|
| 🆓 | **OpenCode — desktop** | Zero-cost local chats in Hermes via the OpenCode CLI — runs alongside the Claude bridge on `:18282` | [`opencode/hermes-desktop/`](./opencode/hermes-desktop) |
| 🆓 | **OpenCode — Kubernetes** | Zero-cost production SRE agent on GKE: bridge sidecar, four-layer read-only posture, Traefik dashboard | [`opencode/kubernetes/`](./opencode/kubernetes) |

**Many providers behind one endpoint:**

| | Environment | Best for | Guide |
|---|-------------|----------|-------|
| 🧭 | **OmniRoute — Docker** | Self-hosted gateway fanning one OpenAI-compatible endpoint out to many providers, on a laptop via Compose | [`omniroute/docker/`](./omniroute/docker) |
| 🧭 | **OmniRoute — Kubernetes** | The same gateway in a cluster: StatefulSet + PVC (SQLite/WAL), non-root, API-key enforced, Traefik TLS | [`omniroute/kubernetes/`](./omniroute/kubernetes) |
| 🔀 | **9Router — Docker** | 9Router + Hermes as one Compose stack: health-gated startup, generated secrets, ~690 models incl. free `oc/*` tiers | [`9router/docker-compose/`](./9router/docker-compose) |
| 🔀 | **9Router — Kubernetes** | The same pair as StatefulSets with PVCs, two Secrets and a one-command installer | [`9router/kubernetes/`](./9router/kubernetes) |
| 🔀 | **9Router — plain Docker** | Single container, named volumes, host-port mapping — the minimal path | [`9router/`](./9router) |
| 🧰 | **Codex CLI + Desktop via 9Router** | OpenAI Codex against a free model, with **working local shell execution** — ships the translator patch that makes it possible | [`9router/codex/`](./9router/codex) |

> Both 9Router stacks install **and self-repair** with one command — `./generate.sh --up` — which generates
> every secret, starts the stack, mints and *validates* the API key, then warms the model catalog.

**Supporting infra for the Kubernetes path:**

| | Component | Purpose | Guide |
|---|---|---|---|
| ☁️ | **GCP / GKE** | Provision a cost-optimized VPC + GKE cluster (Workload Identity, on-demand 3-node) — one command via [`gcp-infra.sh`](./gcp/gcp-infra.sh) | [`gcp/`](./gcp) |
| 🟧 | **AWS / EKS** | Terragrunt-driven EKS blueprint: VPC, EKS (access entries, add-ons), Karpenter, ALB controller IAM — plus the Bedrock IAM and k3s units the agent uses | [`aws/`](./aws) |
| 🚦 | **Traefik v3** | TLS ingress controller for the dashboard/API `IngressRoute`, chart-pinned CRDs. Per-platform values: GKE, EKS (NLB via the AWS LB Controller), k3s (klipper) | [`kubernetes/traefik/`](./kubernetes/traefik) · [`aws/kubernetes/traefik/`](./aws/kubernetes/traefik) · [`hermes-agent/aws-bedrock/traefik/`](./hermes-agent/aws-bedrock/traefik) |
| 🎬 | **DevOps demo** | Break a deployment, watch Hermes diagnose & fix it, then revoke — a read-only → scoped-grant → revoke showcase | [`hermes-agent-devops-demo/`](./hermes-agent-devops-demo) |
| 🎬 | **DevOps demo (OpenCode)** | The same three-gate diagnose-and-fix story on **free** models, at $0 inference | [`opencode-demo/`](./opencode-demo) |
| 🎬 | **SRE demo (Bedrock)** | The same diagnose-and-fix story on Bedrock — **two** gates, not three, because the native path has no Claude Code harness policy to open; RBAC is bound per namespace | [`hermes-agent/aws-bedrock/sre-demo/`](./hermes-agent/aws-bedrock/sre-demo) |

---

## 🔒 Security-first by design

This is built the way production infrastructure should be — **least privilege, everywhere**:

- 🧱 **Read-only operations.** The SRE assistant can `get`/`describe`/`logs`/`top` in Kubernetes and query GCP Logging, Monitoring, and Trace — but **every** mutating verb (`apply`, `delete`, `patch`, `exec`, `port-forward`, secret reads…) is explicitly denied.
- 🛡️ **RBAC as the hard backstop.** A cluster-wide read-only `ClusterRole` means the agent cannot write or read secrets *even if* the tool allowlist were widened.
- 🔑 **No long-lived cloud keys on nodes.** Workload Identity + a loopback OAuth token bridge mint short-lived, read-only access tokens on demand.
- 🌐 **TLS + host routing** via Traefik `IngressRoute` at `hermes.saqlainmushtaq.com`.

---

## ⚡ 60-second local try (Docker)

```bash
# OpenAI-compatible bridge as a Compose stack (macOS, Linux, Windows)
cd docker-bridge
./generate-secrets.sh --all-tools --allow-anonymous && docker compose up -d --build
# → OpenAI-compatible endpoint on http://127.0.0.1:18181/v1
```

No login step: the container bind-mounts your existing `$HOME/.claude`, so it shares your host
session. Drop the flags for the secure default (bearer token required, read-only tools).

> claude.ai connectors (Slack, Drive, Atlassian) are **not** usable through the bridge: `claude -p`
> loads no MCP tools, on any host. See [docker-bridge/README.md](docker-bridge/README.md#claudeai-connectors--visible-but-not-usable-through-the-bridge).

Then (default model is Opus 5; omit `"model"` to use it):

```bash
source docker-bridge/.env
curl -s http://127.0.0.1:18181/v1/chat/completions \
  -H "Authorization: Bearer $CLAUDE_CODE_PROXY_API_KEY" \
  -H 'content-type: application/json' \
  -d '{"messages":[{"role":"user","content":"hello"}]}'

# …or opt into Fable 5 for one request
curl -s http://127.0.0.1:18181/v1/chat/completions \
  -H "Authorization: Bearer $CLAUDE_CODE_PROXY_API_KEY" \
  -H 'content-type: application/json' \
  -d '{"model":"claude-fable-5","messages":[{"role":"user","content":"hello"}]}'
```

> The `../docker/` script needs `flock(1)`, so it's Linux-only in practice — use `docker-bridge/`
> on macOS.

---

## 🩺 Hermes desktop troubleshooting

### "UPDATE DIDN'T FINISH — Hermes is still running"

The message is misleading: it appears with **no Hermes window open and, often, no update process at
all**. The updater writes a sentinel at `$HOME/.hermes/.hermes-update-in-progress` holding the PID
that claimed the update, and **it does not verify that the PID is still alive**. Any update that
dies, is killed, or wedges therefore blocks every later attempt permanently:

```
✗ Another Hermes update is already running (PID 38134, started 29s ago).
```

Clicking **Retry update** cannot help — Retry is the thing being blocked.

**1. Confirm the sentinel is stale.** If the PID it names has no process, the lock is a leftover:

```bash
cat "$HOME/.hermes/.hermes-update-in-progress"          # first line is the PID
ps ax -o pid,stat,etime,%cpu,command | grep -iE 'hermes-setup|Hermes\.app' | grep -v grep
```

A *wedged* (rather than dead) updater shows `0.0` CPU with no children — also safe to clear.

**2. Clear it.**

```bash
pkill -f 'hermes-setup --update'
rm -f "$HOME/.hermes/.hermes-update-in-progress"
```

**3. Run the update.** Either click **Retry update**, or drive it directly — on Apple Silicon:

```bash
"$HOME/.hermes/hermes-setup" --update --branch main \
  --target-app "$HOME/.hermes/hermes-agent/apps/desktop/release/mac-arm64/Hermes.app"
```

Substitute `mac-x64` on Intel, or point `--target-app` at wherever `Hermes.app` lives.

**4. Confirm it finished.** It takes ~3-4 minutes (npm install plus a Vite build) and is silent on
stdout — all progress goes to the log. All three stages must report `Succeeded`:

```bash
grep -E 'state=Succeeded|state=Failed' "$HOME/.hermes/logs/bootstrap-installer.log" | tail -4
```

```
update  stage=update  state=Succeeded  duration_ms=Some(204963)
update  stage=rebuild state=Succeeded  duration_ms=Some(1843)
update  stage=install state=Succeeded  duration_ms=Some(2)
```

To watch it while it runs:

```bash
tail -f "$HOME/.hermes/logs/bootstrap-installer.log"
```

> Do not match on the bare string `hermes` when hunting for processes. Any path containing it —
> including this repository's own bridges, e.g. `hermes-claude-code-bridge/opencode/…` — will match
> and send you after the wrong process. Match `Hermes.app` or `hermes-setup`.

### Hermes relaunches a helper you thought you stopped

On macOS these are `launchd` jobs with `KeepAlive = true`, so `kill` is undone within seconds. Unload
the job rather than killing the process:

```bash
launchctl list | grep -i hermes
launchctl bootout  "gui/$(id -u)/<label>"
launchctl disable  "gui/$(id -u)/<label>"
mkdir -p "$HOME/Library/LaunchAgents/disabled"
mv "$HOME/Library/LaunchAgents/<label>.plist" "$HOME/Library/LaunchAgents/disabled/"
```

To restore it later:

```bash
mv "$HOME/Library/LaunchAgents/disabled/<label>.plist" "$HOME/Library/LaunchAgents/"
launchctl enable    "gui/$(id -u)/<label>"
launchctl bootstrap "gui/$(id -u)" "$HOME/Library/LaunchAgents/<label>.plist"
```

### Hermes shows `HTTP 502: Not logged in · Please run /login`

That is the **bridge**, not Hermes — the container's Claude Code session is unauthenticated. On
macOS the usual cause is a stale `$HOME/.claude/.credentials.json`; re-running
`./generate-secrets.sh` rewrites it from the keychain. Then `docker compose up -d`. See
[`docker-bridge/README.md`](docker-bridge/README.md#reusing-your-host-login).

---

## 🧠 Why I built this

Agent gateways and OpenAI-native tooling are everywhere, but **Claude Code** is the strongest coding/ops model interface I use daily. This bridge lets me drop Claude Code in behind any OpenAI-compatible surface — and then run it as a **safe, read-only production SRE copilot** that investigates incidents across my clusters and cloud **without the risk of it changing anything**.

It's the pattern I reach for as a Lead SRE: *give the agent deep read access and zero write access, and let RBAC — not prompts — be the guarantee.*

---

## 👤 About the author

**Muhammad Asim** — Lead Site Reliability Engineer · DevOps / DevSecOps
*10+ years architecting secure, scalable cloud infrastructure across AWS, GCP & Azure.* ☁️

🔧 Kubernetes · Terraform · GitOps (ArgoCD/FluxCD) · Istio · Prometheus/Grafana · Zero-trust
📜 AWS Solutions Architect Professional · CKA

<div align="center">

[![LinkedIn](https://img.shields.io/badge/LinkedIn-Follow-0A66C2?logo=linkedin&logoColor=white)](https://www.linkedin.com/in/muhammad-asim1982)
[![YouTube](https://img.shields.io/badge/YouTube-@devopsgang-FF0000?logo=youtube&logoColor=white)](https://www.youtube.com/@devopsgang)
[![GitHub](https://img.shields.io/badge/GitHub-ch--muhammad--asim-181717?logo=github&logoColor=white)](https://github.com/ch-muhammad-asim)
[![Portfolio](https://img.shields.io/badge/Portfolio-Website-4285F4?logo=googlechrome&logoColor=white)](https://ch-muhammad-asim.github.io/)

</div>

> 💬 Found this useful? A ⭐ helps — and I share cloud/DevOps/SRE deep-dives on [YouTube](https://www.youtube.com/@devopsgang) and [LinkedIn](https://www.linkedin.com/in/muhammad-asim1982).
