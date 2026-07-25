# 🧩 Kubernetes Dashboard Skills

Optional local dashboard skills for the Kubernetes Hermes deployment.

The deployment is read-only by default. Any skill added here must preserve that posture: inspect and summarize only; do not create, update, delete, comment, transition, or send messages unless a separate approved write path is explicitly introduced.

Skills are deployed declaratively. Add `SKILL.md` under `kubernetes/skills/<skill-name>/`, include it in the `hermes-agent-declarative-skills` `configMapGenerator`, then apply the Kustomize directory and roll the StatefulSet. Runtime sync writes the skill to the PVC-backed path `/opt/data/skills/<skill-name>/SKILL.md`.

## 🧹 Only our skills — the bundled catalog is disabled

Hermes ships ~69 bundled skills (Airtable, arXiv, ASCII art, …) that are irrelevant to a locked-down SRE agent and clutter the Skills page. `init-hermes-config.sh` keeps the skill set clean:

- It drops a `.no-bundled-skills` marker in `HERMES_HOME`, which makes the agent's `sync_skills()` a no-op ([`tools/skills_sync.py`](https://github.com/NousResearch/hermes-agent)) — so **none of the bundled catalog is ever seeded**, on fresh volumes included.
- It then purges any catalog a previous image seeded onto the volume, keeping **only**:
  - our declarative skill(s) — `lead-devops-sre`;
  - Hermes's **self-improvement** skills, so the agent can still improve itself — `hermes-agent` (configure/extend Hermes) and `hermes-agent-skill-authoring` (author new `SKILL.md`s).

To retain a different set, edit `SELF_IMPROVE_SKILLS` in `configmaps/configmap-hermes-runtime-scripts.yaml`.
