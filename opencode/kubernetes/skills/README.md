# 🎓 skills/

Version-controlled Hermes skills, installed **declaratively**: Git → ConfigMap (`hermes-agent-declarative-skills`) → PVC (`/opt/data/skills/<name>/SKILL.md`) by the `init-hermes-config` init container.

| Skill | Purpose |
|-------|---------|
| `lead-devops-sre/SKILL.md` | The agent's greeting + capability profile — what it can and cannot do, stated accurately for *this* deployment |

## Why it's declarative

`init-hermes-config` writes `/opt/data/.no-bundled-skills`, which makes Hermes' `sync_skills()` a no-op, then installs only:

1. Hermes' own self-improvement skills (so the agent can author and configure skills), and
2. every `*.SKILL.md` from this directory,

purging everything else — including a catalog a previous image may have seeded onto the volume. Fewer skills means a smaller system prompt, which matters more here than on a frontier model: the free models have big context windows but they drift when the prompt is bloated.

The same file is also referenced from `configmaps/configmap-opencode-config.yaml` via OpenCode's `instructions`, so the *bridge-side* agent gets the same operating brief as the Hermes-side one.

## Adding a skill

```bash
mkdir -p my-skill && $EDITOR my-skill/SKILL.md
```

Then register it in `../kustomization.yaml`:

```yaml
  - name: hermes-agent-declarative-skills
    namespace: devops-agent
    files:
      - lead-devops-sre.SKILL.md=skills/lead-devops-sre/SKILL.md
      - my-skill.SKILL.md=skills/my-skill/SKILL.md
```

The `<name>.SKILL.md=` key matters: the init script derives the installed directory name from it (`basename … .SKILL.md`).

```bash
kubectl apply -k .. && kubectl -n devops-agent rollout restart statefulset/hermes-agent
```

## Keep it honest

This deployment's skill claims read-only access with no write/edit tool. That is enforced (see [`../rbac`](../rbac) and the permission policy), so the wording matches reality. If you widen the agent's capabilities, update the skill in the same change — an agent that describes access it doesn't have wastes turns discovering the refusal, and one that under-describes its access surprises its operators.
