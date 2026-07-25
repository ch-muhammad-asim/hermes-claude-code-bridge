# 🎬 Hermes Agent DevOps Demo

A self-contained **Kustomize overlay** that shows Hermes **diagnose *and* fix** a broken Kubernetes
deployment — great for showcasing agentic SRE. It layers on top of the read-only base
([`../kubernetes`](../kubernetes)) and, in **one `kubectl apply -k`**, opens all three write gates
declaratively: breaks a deployment, grants a scoped RBAC write (Deployments only), opens the harness
policy, and swaps Hermes's skill for a demo variant that authorizes the fix. No runtime `kubectl patch`
needed — and RBAC keeps the blast radius to Deployment writes the whole time.

> ⚠️ **Demo/sandbox only.** This deliberately relaxes the read-only guarantee. **Revert it after**
> (step 4) to restore the secure posture.

## ⚡ Quick start

```bash
cd hermes-agent-devops-demo

# Deploy the overlay — opens all three gates declaratively (Kustomize, so `-k`, NOT `-f`):
kubectl apply -k .

# Roll the agent so it reloads the harness policy + demo skill and reruns init:
kubectl -n devops-agent rollout restart statefulset/hermes-agent
```

Then ask Hermes *"fix the deployment in `demo`"* — it applies the image fix and confirms the rollout
itself. Revert with `kubectl apply -k ../kubernetes` (step 4).

> 🛑 **`apply -k .`, not `apply -f .`** — this directory is a Kustomize overlay. Pointing `-f` at
> `kustomization.yaml` fails with *`no matches for kind "Kustomization"`*. Step-by-step walkthrough below.

### 🚧 It takes *three* gates to let Hermes write

The read-only posture is defended in depth — opening one gate isn't enough. The overlay opens **all
three declaratively**, so `apply -k .` is the only command and there's no ordering trap:

| Gate | What it controls | How the overlay opens it |
|------|------------------|--------------------------|
| **1 · RBAC** | Can the SA `patch` Deployments at all? | `02-grant-deploy-write.yaml` — additive ClusterRole (Deployments only) |
| **2 · Harness** | Does the Claude Code bridge allow the mutating tool? | `04-grant-harness-write.yaml` — `default` mode + allow-list `kubectl patch`/`set`/`rollout`; delete/exec/secrets still denied |
| **3 · Skill** | Does Hermes's *own disposition* permit a write? | `03-demo-writer.SKILL.md` — skill variant that authorizes the scoped fix |

> Gate 3 is the one people miss: even with RBAC + harness open, the base skill says *"never mutate
> production directly,"* so Hermes declines on principle. The demo skill grants a **narrow, temporary**
> write (Deployment image fix in `demo` only) and nothing else.
>
> Gate 2 switches the session from the base's read-only `dontAsk` mode to the standard **`default`**
> mode and allow-lists exactly `kubectl patch`/`set`/`rollout`. In non-interactive `-p`, Claude runs
> allow-listed tools without a prompt — so the fix goes through — while `delete`/`create`/`exec`/secret
> reads stay on the disallow list. (`bypassPermissions` is deliberately *not* used: the bridge runs as
> root and Claude Code refuses `--dangerously-skip-permissions` under root.) And **RBAC (Gate 1)** is
> the hard backstop — the ServiceAccount can only `patch` Deployments, so Secrets/delete/other resources
> are refused **cluster-side** regardless of the harness. Least privilege is enforced by RBAC, not by
> trusting the model.

## 📦 Files

| File | What it does |
|------|--------------|
| `kustomization.yaml` | The overlay: pulls in `../kubernetes`, adds 01+02, merge-overrides the skill ConfigMap with 03, and applies the Gate-2 policy override 04 |
| `01-broken-deployment.yaml` | Creates namespace `demo` + a `demo-nginx` Deployment on `nginx:faulty` → **ImagePullBackOff** |
| `02-grant-deploy-write.yaml` | **Gate 1 (RBAC):** additive ClusterRole+binding giving `hermes-agent` `update/patch` on Deployments (narrow; no secrets/delete) |
| `03-demo-writer.SKILL.md` | **Gate 3 (skill):** demo-writer variant of `lead-devops-sre` that authorizes the scoped `demo` image fix; auto-synced to `/opt/data/skills` on the next roll |
| `04-grant-harness-write.yaml` | **Gate 2 (harness):** declarative override — `default` mode + allow-lists `kubectl patch`/`set`/`rollout` (delete/exec/secrets stay denied; RBAC still limits the SA to Deployment writes) |

> 🧷 **Deploy with `kubectl apply -k .` — never `-f`.** This is a Kustomize overlay; `apply -f .` would
> choke on `kustomization.yaml` and the `.SKILL.md` file. All three gates are opened declaratively by
> the overlay, so there's no runtime `kubectl patch` step and no risk of a later `apply -k` reverting it.

## 🍎 Tool paths (macOS)

These commands use bare `kubectl` (on `PATH`). On macOS the absolute paths are Homebrew's
`/opt/homebrew/bin` for `kubectl`/`helm`/`gcloud`, and `/usr/local/bin/docker` for **Docker/OrbStack**.
Confirm and grab the exact paths (use them if your agent runs in a minimal-`PATH` shell):

```bash
command -v kubectl docker        # e.g. /opt/homebrew/bin/kubectl  and  /usr/local/bin/docker
```

## ▶️ Run the demo

### 1. Deploy the overlay — opens all three gates, then roll

`apply -k .` breaks the deployment and opens Gates 1 (RBAC), 2 (harness policy) and 3 (skill) in one
shot. The `rollout restart` reloads the harness policy and reruns init (which re-syncs the demo skill
and prunes the bundled skills):

```bash
cd hermes-agent-devops-demo
kubectl apply -k .                      # broken deploy + all three gates — NOT -f
kubectl -n devops-agent rollout restart statefulset/hermes-agent
kubectl -n demo get pods -w             # demo-nginx → ImagePullBackOff
```

### 2. Confirm the gates opened

```bash
# Gate 1 (RBAC):
kubectl -n devops-agent exec hermes-agent-0 -c hermes -- kubectl auth can-i patch deployments -n demo   # → yes
# Gate 2 (harness): mode=default and patch/set/rollout allow-listed:
kubectl -n devops-agent get cm hermes-agent-claude-bridge-env \
  -o jsonpath='{.data.CLAUDE_CODE_PERMISSION_MODE}{"\n"}'   # → default
```

> 💡 Say `hi` to Hermes after the roll — it should now greet you in **🧪 Demo mode** with the scoped
> write grant, confirming Gate 3 loaded.

The roll also runs the base `init-hermes-config.sh`, which purges Hermes's ~69 bundled skills and keeps
only your SRE skill + the two self-improvement skills. The **Skills** page should show a short list, not 69:

```bash
kubectl -n devops-agent exec hermes-agent-0 -c hermes -- ls /opt/data/skills
# → lead-devops-sre  hermes-agent  hermes-agent-skill-authoring   (only these)
```

### 3. Ask Hermes to diagnose, then fix

> 💬 *"The deployment `demo-nginx` in namespace `demo` won't start — diagnose it, then fix it and confirm the rollout is healthy."*

Hermes inspects read-only, finds `nginx:faulty` is a nonexistent tag, then applies a one-line image
swap (targeting the container **by index**, so no container-name gotcha):

```bash
kubectl -n demo patch deployment demo-nginx --type=json \
  -p='[{"op":"replace","path":"/spec/template/spec/containers/0/image","value":"nginx:stable"}]'
kubectl -n demo rollout status deployment/demo-nginx        # → successfully rolled out
```

*(Prefer to run it yourself? Gate 1 alone is enough for the patch above — no harness change needed.)*

### 4. Revert — restore the read-only, locked-down posture 🔒

```bash
kubectl apply -k ../kubernetes                              # restores read-only ConfigMaps, policy AND the read-only skill (Gates 2 & 3)
kubectl delete -f 02-grant-deploy-write.yaml -f 01-broken-deployment.yaml   # revokes RBAC (Gate 1) + removes the demo namespace
kubectl -n devops-agent rollout restart statefulset/hermes-agent
# verify writes are denied again:
kubectl -n devops-agent exec hermes-agent-0 -c hermes -- kubectl auth can-i patch deployments -n demo   # → no
```

Applying the base overlay merge-overrides the demo skill back to the read-only `lead-devops-sre`
skill, so after the roll `hi` greets you in the locked-down profile again — all three gates closed.

## 🩹 Recovering from a clobbered ConfigMap

If you (or an earlier version of this demo that shipped ConfigMap **patch files**) ran
`kubectl apply -f` against a *partial* ConfigMap, `apply` replaces the **whole object** and strips
every key you didn't include. On `hermes-agent-claude-bridge-env` that drops `CLAUDE_CODE_PREFIX`,
`CLAUDE_CODE_NPM_SPEC`, and the tool-policy keys — which breaks the agent on next roll.

**Symptom:** `hermes-agent-0` stuck `Pending`/`Init`, with init container **`init-claude-code`**
in `CrashLoopBackOff` (exit 2). The log shows:

```
kubectl -n devops-agent logs hermes-agent-0 -c init-claude-code
# init-claude-code.sh: 3: CLAUDE_CODE_PREFIX: parameter not set
```

**Fix** — restore the complete ConfigMaps from the base, then recreate the pod so init reruns:

```bash
kubectl apply -k ../kubernetes                              # restores all 39 keys (CLAUDE_CODE_PREFIX, NPM_SPEC, policy…)
kubectl -n devops-agent delete pod hermes-agent-0          # StatefulSet recreates it; init-claude-code now passes → 2/2 Running
```

> A `rollout restart` also works, but deleting the pod is the fastest way to clear a wedged
> init-container back-off.

Going forward, only ever open Gate 2 with the **`--type merge`** patch in step 2 — never
`apply -f` these shared ConfigMaps.

## 🎥 The story (for the video)

Read-only Hermes **diagnoses** the outage precisely but **can't touch** anything — and it takes
**three independent gates** (RBAC, the harness tool policy, *and* the agent's own skill disposition)
to let it write. You open a **narrow, temporary** grant, it **fixes** the deployment, then you
**revoke** — and Secrets, deletes, and every other resource stayed denied the entire time. That's
defense-in-depth agentic SRE: no single misconfiguration hands the agent write access.

> 🔗 The permanent read-only RBAC model this demo temporarily relaxes: [`../kubernetes/hermes-service-account`](../kubernetes/hermes-service-account).
