# 🎬 OpenCode DevOps Demo — diagnose *and* fix, on free models

A self-contained **Kustomize overlay** that shows Hermes **diagnose and fix** a broken Kubernetes deployment — running on **OpenCode's free models**, so the whole demo costs **$0 in inference**.

It layers on top of the read-only OpenCode base ([`../opencode/kubernetes`](../opencode/kubernetes)) and, in **one `kubectl apply -k`**, opens all three write gates declaratively: breaks a deployment, grants a scoped RBAC write (Deployments only), extends the kubectl wrapper's verb allowlist, and swaps the agent's skill for a demo variant that authorizes the fix. No runtime `kubectl patch` needed — and RBAC keeps the blast radius to Deployment writes the whole time.

This is the OpenCode counterpart of [`../hermes-agent-devops-demo`](../hermes-agent-devops-demo) (the Claude Code version). Same story, same three-gate structure — **Gate 2 works differently**, for a reason worth showing on camera (see below).

> ⚠️ **Demo/sandbox only.** This deliberately relaxes the read-only guarantee. **Revert it after** (step 4) to restore the secure posture.

## ⚡ Quick start

```bash
cd opencode-demo

# Deploy the overlay — opens all three gates declaratively (Kustomize, so `-k`, NOT `-f`):
kubectl apply -k .

# Roll the agent so it reloads the wrapper allowlist + demo skill and reruns init:
kubectl -n devops-agent rollout restart statefulset/hermes-agent
```

Then ask Hermes *"fix the deployment in `demo`"* — it applies the image fix and confirms the rollout itself. Revert with `kubectl apply -k ../opencode/kubernetes` (step 4).

> 🛑 **`apply -k .`, not `apply -f .`** — this directory is a Kustomize overlay. Pointing `-f` at `kustomization.yaml` fails with *`no matches for kind "Kustomization"`*.

## 🚧 It takes *three* gates to let Hermes write

The read-only posture is defended in depth — opening one gate isn't enough. The overlay opens **all three declaratively**, so `apply -k .` is the only command and there's no ordering trap:

| Gate | What it controls | How the overlay opens it |
|------|------------------|--------------------------|
| **1 · RBAC** | Can the ServiceAccount `patch` Deployments at all? | `02-grant-deploy-write.yaml` — additive ClusterRole (Deployments only) |
| **2 · Harness** | Does the agent's `kubectl` even accept a mutating verb? | `04-grant-harness-write.yaml` — sets `KUBECTL_EXTRA_WRITE_VERBS: "patch set rollout"` |
| **3 · Skill** | Does Hermes's *own disposition* permit a write? | `03-demo-writer.SKILL.md` — skill variant that authorizes the scoped fix |

Gate 3 is the one people miss: even with RBAC and the harness open, the base skill says *"you structurally cannot mutate production"*, so Hermes declines on principle. The demo skill grants a **narrow, temporary** write (Deployment image fix in `demo` only) and nothing else.

### 🔍 Why Gate 2 differs from the Claude Code demo

Worth calling out, because it's a real difference in how the two CLIs enforce policy — established by testing, not assumption:

| | Claude Code demo | This OpenCode demo |
|---|---|---|
| Where writes are gated | `--permission-mode` + `--allowedTools` / `--disallowedTools` | The `kubectl-ro` wrapper's verb allowlist |
| What the overlay changes | Rewrites both tool lists and flips the mode to `default` | Sets one env var: `KUBECTL_EXTRA_WRITE_VERBS` |
| Why | Claude Code enforces per-tool patterns like `Bash(kubectl patch:*)` | OpenCode **can't** express that: a `bash` pattern map whose catch-all is `deny` removes the bash tool **wholesale** — the allow-patterns don't survive (verified on opencode 1.18.5). So the base grants `bash: allow` and enforces the verb allowlist outside the model, in a wrapper |

Two consequences that make this demo *stronger*, not weaker:

- **The gate is enforced by a program, not by the model's cooperation.** The wrapper is a shell script on `PATH`; a prompt-injected model cannot talk it into accepting `delete`.
- **The OpenCode file-mutation policy stays closed throughout.** `edit`, `write` and `patch` remain `deny`, so those tools are *absent from the model's tool list* the entire demo. Hermes fixes the cluster through `kubectl` — it never gains the ability to rewrite a manifest, a skill, or its own config on the PVC.

And **RBAC (Gate 1) is still the hard backstop**: the ServiceAccount can only `patch` Deployments, so Secrets, deletes, and every other resource are refused **cluster-side** regardless of what the wrapper allows. Least privilege is enforced by the API server, not by trusting the model.

## 📦 Files

| File | What it does |
|------|--------------|
| `kustomization.yaml` | The overlay: pulls in `../opencode/kubernetes`, adds 01+02, merge-overrides the skill ConfigMap with 03, applies the Gate-2 patch 04 |
| `01-broken-deployment.yaml` | Creates namespace `demo` + a `demo-nginx` Deployment on `nginx:faulty` → **ImagePullBackOff** |
| `02-grant-deploy-write.yaml` | **Gate 1 (RBAC):** additive ClusterRole+binding giving `hermes-agent` `update/patch` on Deployments (no secrets, no delete) |
| `03-demo-writer.SKILL.md` | **Gate 3 (skill):** demo-writer variant of `lead-devops-sre`; synced to `/opt/data/skills` on the next roll, and loaded by OpenCode via its `instructions` list |
| `04-grant-harness-write.yaml` | **Gate 2 (harness):** one-key merge patch adding `patch`/`set`/`rollout` to the wrapper's allowlist |

> 🧷 The Gate-2 patch touches **one key** and Kustomize merges it, so the other 27 keys of the bridge env ConfigMap survive. That matters: `kubectl apply -f` with a partial ConfigMap **replaces the whole object** and strips every key you left out, which would drop `OPENCODE_PREFIX`/`OPENCODE_NPM_SPEC` and wedge the pod on its next roll. Always `apply -k`.

## ▶️ Run the demo

### 1. Deploy the overlay — opens all three gates, then roll

```bash
cd opencode-demo
kubectl apply -k .                      # broken deploy + all three gates — NOT -f
kubectl -n devops-agent rollout restart statefulset/hermes-agent
kubectl -n demo get pods -w             # demo-nginx → ImagePullBackOff
```

### 2. Confirm the gates opened

```bash
# Gate 1 (RBAC) — ask the API server, from the agent's own identity:
kubectl -n devops-agent exec hermes-agent-0 -c opencode-bridge -- \
  sh -lc '$KUBECTL_REAL auth can-i patch deployments -n demo'        # → yes

# Gate 2 (harness) — the verb the wrapper now accepts:
kubectl -n devops-agent get cm hermes-agent-opencode-bridge-env \
  -o jsonpath='{.data.KUBECTL_EXTRA_WRITE_VERBS}{"\n"}'              # → patch set rollout

# Gate 2, end to end — and proof the rest is still shut:
kubectl -n devops-agent exec hermes-agent-0 -c opencode-bridge -- sh -lc '
  kubectl patch  --help >/dev/null 2>&1 && echo "patch  : allowed"
  kubectl delete --help >/dev/null 2>&1 || echo "delete : still blocked"'

# Gate 3 (skill) — say `hi` in the dashboard; it should greet you in 🧪 Demo mode.
kubectl -n devops-agent exec hermes-agent-0 -c hermes -- \
  grep -l "Demo mode" /opt/data/skills/lead-devops-sre/SKILL.md      # → path printed
```

The roll also reruns the base `init-hermes-config.sh`, which purges the bundled skill catalog and keeps only your SRE skill plus the two self-improvement ones:

```bash
kubectl -n devops-agent exec hermes-agent-0 -c hermes -- ls /opt/data/skills
# → lead-devops-sre  hermes-agent  hermes-agent-skill-authoring   (only these)
```

### 3. Ask Hermes to diagnose, then fix

> 💬 *"The deployment `demo-nginx` in namespace `demo` won't start — diagnose it, then fix it and confirm the rollout is healthy."*

Hermes inspects read-only, finds `nginx:faulty` is a nonexistent tag, then applies a one-line image swap (targeting the container **by index**, so no container-name gotcha):

```bash
kubectl -n demo patch deployment demo-nginx --type=json \
  -p='[{"op":"replace","path":"/spec/template/spec/containers/0/image","value":"nginx:stable"}]'
kubectl -n demo rollout status deployment/demo-nginx        # → successfully rolled out
```

> 💡 **Free-model coaching.** These models are smaller than a frontier model; they occasionally retry a tool call before landing it (you'll see `✗ bash(...)` then `› bash(...)` in the transcript when `OPENCODE_BRIDGE_SHOW_TOOLS=1`). Ask for the diagnosis and the fix in one clear instruction rather than a long open-ended prompt, and if a run wanders, `opencode/big-pickle` or `opencode/nemotron-3-ultra-free` (1M context) are the stronger picks in the model dropdown.

### 4. Revert — restore the read-only, locked-down posture 🔒

```bash
# Closes Gates 2 & 3 (KUBECTL_EXTRA_WRITE_VERBS back to "", read-only skill restored):
kubectl apply -k ../opencode/kubernetes

# Revokes Gate 1 and removes the demo workload:
kubectl delete -f 02-grant-deploy-write.yaml -f 01-broken-deployment.yaml

kubectl -n devops-agent rollout restart statefulset/hermes-agent

# Verify writes are denied again — both layers:
kubectl -n devops-agent exec hermes-agent-0 -c opencode-bridge -- sh -lc '
  $KUBECTL_REAL auth can-i patch deployments -n demo      # → no        (RBAC)
  kubectl patch deployment x -n demo -p "{}"'             # → blocked   (wrapper)
```

## ✅ Verified live on GKE

Run end-to-end on `hermes-cluster` (`devops-agent` + `demo`, us-central1-a):

| Check | Result |
|---|---|
| `apply -k .` + roll | Agent back to **2/2**, `demo-nginx` in **ImagePullBackOff** on `nginx:faulty` |
| Gate 1 · RBAC | `patch deployments -n demo` → **yes**; `delete deployments`, `patch statefulsets`, `get secrets` → **no** |
| Gate 2 · harness | `KUBECTL_EXTRA_WRITE_VERBS=patch set rollout` in the sidecar; wrapper allows `patch`/`set`/`rollout`, still refuses `delete`/`apply`/`exec` |
| Gate 3 · skill | `/opt/data/skills` holds only the 3 expected skills; `lead-devops-sre/SKILL.md` is the demo variant; OpenCode loads it via `instructions` |
| File policy stayed shut | `"write": "deny"` throughout the demo |
| **The fix** | Agent diagnosed `nginx:faulty` from `describe` + `events`, patched by container index, and `rollout status` confirmed — deployment `1/1`, pod Running, verified independently |
| After the fix | Grant did **not** widen: delete/statefulsets/secrets all still **no** |

### 🐞 One bug this live run caught

The first run exposed a flaw worth knowing about, since it shows why you test on a cluster and not just in a renderer. The agent's opening attempt was:

```bash
kubectl --namespace demo patch deployment demo-nginx --type=json -p='…'
```

The wrapper read `$1` as the verb — which here is `--namespace` — so a perfectly valid command was refused. The model noticed (*"the wrapper parses the first non-`kubectl` arg as the verb"*), reordered to `kubectl patch --namespace demo …`, and the demo still succeeded. But `kubectl -n ns get pods` is standard syntax and was being blocked in the **base** read-only deployment too.

Fixed: the wrapper now skips leading global flags — including value-taking ones (`-n`, `--context`, `--kubeconfig`, …) and the attached `--flag=value` form — to find the real verb, and locates `auth can-i` / `config view` sub-verbs the same way instead of reading `$2`. It stays **fail-closed**: unparseable input yields an empty verb and is refused.

Re-verified over 20 command shapes × both gate states (40 assertions), specifically that flags-first cannot sneak a mutating verb past — `kubectl -n demo delete pod x` and `kubectl --namespace=demo delete deployment x` are still blocked in both states. On the cluster, the agent then fixed the deployment **first try**, no reordering.

> The original bug was a false *refusal*, never a false permit — so no run was ever less safe than documented.

## 🎥 The story (for the video)

Read-only Hermes **diagnoses** the outage precisely but **can't touch** anything — and it takes **three independent gates** (RBAC, the kubectl wrapper's allowlist, *and* the agent's own skill disposition) to let it write. You open a **narrow, temporary** grant, it **fixes** the deployment, then you **revoke** — and Secrets, deletes, file edits and every other resource stayed denied the entire time.

The OpenCode angle adds a second punchline: **this ran on a free model, at $0 inference**, and the guardrail that mattered most wasn't a model setting at all — it was a 40-line shell wrapper plus RBAC. Defense-in-depth agentic SRE doesn't require an expensive model; it requires not trusting *any* model.

> 🔗 The permanent read-only posture this demo temporarily relaxes: [`../opencode/kubernetes/rbac`](../opencode/kubernetes/rbac) (layer 3) and the wrapper in [`../opencode/kubernetes/configmaps`](../opencode/kubernetes/configmaps) (layer 2).
> 🤖 The Claude Code version of this demo: [`../hermes-agent-devops-demo`](../hermes-agent-devops-demo).
