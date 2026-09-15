# 🪪 Identity — `SOUL.md`

`SOUL.md` is the agent's always-loaded identity: who it is, what it may touch, and how it
behaves. The `init-hermes-config` init container copies it to `/opt/data/SOUL.md` on every
pod start, so it is version-controlled rather than typed into a running pod.

It is loaded on **every** request, ahead of any skill. That makes it the right place for
facts that must never be forgotten (scope, guardrails, the greeting contract) and the
wrong place for anything long — it is charged to every single call, and
`context_file_max_chars: 20000` caps it.

## 📋 What it declares

- **Scope** — AWS account, region, cluster, and that remediation is `demo`-only.
- **The one write exception**, stated plainly so the agent neither over-claims read-only
  nor assumes it can write anywhere.
- **A greeting contract** — the exact capability table to print on "hi", so the agent
  never invents access it does not have.
- **Behaviour rules** — investigate before acting; never ask for secrets; never widen its
  own access; never `kubectl exec`.
- **Cost discipline** — the sandbox's hard token allowance, because an agent that dumps
  whole namespaces ends the lab.

## ⚖️ SOUL.md vs a skill

| | `SOUL.md` | `../skills/*/SKILL.md` |
|---|---|---|
| Loaded | Always, every request | Only when its `description` matches |
| Cost | Charged on every call | Charged when it fires |
| Use for | Identity, scope, hard guardrails | Task procedure and method |

Keep SOUL.md short and absolute. Put the how-to in a skill.

## 🔁 After editing

```bash
kubectl apply -k .. && kubectl -n devops-agent rollout restart statefulset/hermes-agent
```

```bash
kubectl -n devops-agent exec hermes-agent-0 -c hermes -- head -20 /opt/data/SOUL.md
```
