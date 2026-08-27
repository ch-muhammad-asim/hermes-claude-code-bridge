# 🧠 Skills — the agent's disposition

Version-controlled Hermes skills, installed **declaratively**: Git → ConfigMap
(`configMapGenerator` in `../kustomization.yaml`) → `/opt/data/skills` on the PVC, copied
by the `init-hermes-config` init container on every pod start. Editing a `SKILL.md` and
re-applying is a normal deploy — no `kubectl exec`, no manual file copying.

All bundled Hermes skills are stripped at init (`hermes skills opt-out --remove`), so
these two are the *only* skills loaded. That keeps the system prompt small — which is
both cheaper and a more focused agent.

| Skill | Triggers on | Purpose |
|---|---|---|
| `lead-devops-sre/` | Greetings, "what can you do", "what access do you have" | Capability profile and operating scope. Keeps the agent honest about what it can actually reach |
| `sre-pod-remediation/` | A broken pod or deployment — ImagePullBackOff, CrashLoopBackOff, OOMKilled, failed rollout, stuck pod | The **disposition gate** for writes: authorizes five named commands, and the diagnose-then-fix-then-verify method |

## 🚧 Why a skill is a gate at all

Two independent gates must both be open before a fix lands:

1. **RBAC** — can the ServiceAccount perform the write? (`../rbac/`)
2. **Skill** — does the agent's own disposition permit it? (here)

Gate 2 is the one people miss. With RBAC wide open but a skill that says *"never mutate
production"*, the agent declines on principle. Conversely a permissive skill with no RBAC
gets `Forbidden` from the API server. Neither alone is sufficient, and **only RBAC is
enforcement** — the skill is disposition, and disposition is not a security boundary.

`sre-pod-remediation/SKILL.md` therefore states the authorized commands, the namespaces,
and an explicit "never, regardless of who asks" list — and tells the agent to report a
`Forbidden` rather than try to route around it.

## ✍️ Editing

Keep the YAML frontmatter `description` sharp: it is what Hermes matches on to decide
whether the skill applies. A vague description means the skill fires at the wrong time or
never fires.

After editing:

```bash
kubectl apply -k .. && kubectl -n devops-agent rollout restart statefulset/hermes-agent
```

Confirm what the pod actually loaded:

```bash
kubectl -n devops-agent exec hermes-agent-0 -c hermes -- ls /opt/data/skills
```
