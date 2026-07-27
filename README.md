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
| 🐳 | **Docker** | Reproducible container on any host | [`docker/`](./docker) |
| ☸️ | **Kubernetes (GKE)** | Production: Hermes gateway + bridge sidecar, TLS, autoscaling | [`kubernetes/`](./kubernetes) |
| 🧩 | **The bridge itself** | Cross-platform launcher + the Python bridge | [`claude-bridge-with-hermes/`](./claude-bridge-with-hermes) |

Every deployment exposes the same endpoint: **`http://<host>:18181/v1`** (model `claude-opus-4-8`).

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

**Supporting infra for the Kubernetes path:**

| | Component | Purpose | Guide |
|---|---|---|---|
| ☁️ | **GCP / GKE** | Provision a cost-optimized VPC + GKE cluster (Workload Identity, on-demand 3-node) — one command via [`gcp-infra.sh`](./gcp/gcp-infra.sh) | [`gcp/`](./gcp) |
| 🚦 | **Traefik v3** | TLS ingress controller for the dashboard/API `IngressRoute` (chart-pinned CRDs) | [`kubernetes/traefik/`](./kubernetes/traefik) |
| 🎬 | **DevOps demo** | Break a deployment, watch Hermes diagnose & fix it, then revoke — a read-only → scoped-grant → revoke showcase | [`hermes-agent-devops-demo/`](./hermes-agent-devops-demo) |
| 🎬 | **DevOps demo (OpenCode)** | The same three-gate diagnose-and-fix story on **free** models, at $0 inference | [`opencode-demo/`](./opencode-demo) |

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
# Runs the stdlib-only bridge against your authenticated `claude`
cd docker
./docker-hermes-claude-bridge.sh
# → OpenAI-compatible endpoint on http://127.0.0.1:18181/v1
```

Then:

```bash
curl -s http://127.0.0.1:18181/v1/chat/completions \
  -H 'content-type: application/json' \
  -d '{"model":"claude-opus-4-8","messages":[{"role":"user","content":"hello"}]}'
```

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
