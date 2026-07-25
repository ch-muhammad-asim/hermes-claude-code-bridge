# ☸️ Giving Hermes Safe Read-Only Access to Kubernetes (RBAC)

How to let the Hermes agent **observe the cluster** — pods, logs, events, workloads, networking, RBAC and storage guardrails — while being **physically forbidden** from reading **Secrets** or making **any change** (no create/patch/update/delete, anywhere). This is the read-only profile lead DevOps/SRE engineers hand to an AI agent in 2026. ✅ **Built, applied, and POC-tested on a live GKE cluster** (results below).

---

## 🎯 The problem

You want Hermes to do real SRE triage:
- ✅ "Show me the pods" / "tail the logs" / "what's CrashLooping?"
- ✅ "Which RBAC/NetworkPolicy/ingress is blocking this?" / "how many nodes?"
- ⛔ **Never** read or exfiltrate **Secrets**
- ⛔ **Never** mutate anything — no restart, scale, edit, create, or delete

An LLM can be **prompt-injected**, so "just tell it not to" is not a control. The restriction must be enforced **below** the model, at the API server.

---

## 🔬 What the industry does (research)

| Source | Takeaway |
|---|---|
| [InfoQ — Securing Autonomous AI Agents on K8s](https://www.infoq.com/articles/securing-autonomous-ai-agents-kubernetes/) | *"The difference between safe review and dangerous action is usually one verb."* `get/list/watch` = observe; `create/update/patch/delete` = change. Use **dedicated identity + read-only RBAC + no Secret access**. |
| [DEV — Your AI Agent Should Not Have Direct kubectl Access](https://dev.to/mike_anderson_d01f52129fb/your-ai-agent-should-not-have-direct-kubectl-access-b1o) | Raw kubectl + broad token = control-plane risk. Wrap access; scope the token. |
| [Kubernetes RBAC Good Practices](https://kubernetes.io/docs/concepts/security/rbac-good-practices) | One SA per workload, never the default SA, least privilege per verb. |
| [containers/kubernetes-mcp-server](https://github.com/containers/kubernetes-mcp-server) | MCP server with `read_only: true` + `denied_resources` (deny Secrets). |
| [kubectl-ro](https://dev.to/veysi/kubectl-ro-read-only-kubernetes-access-for-ai-agents-and-humans-1okg) | Read-only kubectl wrapper; secret values auto-`[REDACTED]`. |

**Consensus:** layer **(1) Kubernetes RBAC** (the hard wall, read-only here) + **(2) a closed Claude tool surface** (write-capable tools denied by default). Any future tool access must go through **(3) human approval**.

---

## 🏗️ The architecture (what we built)

```
┌──────────────────────────────────────────────────────────────┐
│ Hermes pod   (ServiceAccount: hermes-agent)                    │
│                                                                │
│   terminal_tool ── kubectl ──┐                                 │
│                              │ in-cluster SA token             │
│                              │ (auto-mounted, auto-scoped)     │
└──────────────────────────────┼─────────────────────────────────┘
                               ▼
                  ┌──────────────────────────────┐
                  │ Kubernetes API server         │
                  │ enforces RBAC (deny-by-default)│
                  │   ClusterRole readonly:        │
                  │     ✅ get/list/watch cluster   │
                  │     ⛔ secrets                  │
                  │     ⛔ create/patch/update/del  │
                  │   Role (ns) readonly:          │
                  │     ✅ get/list/watch + cfgmaps │
                  │     ⛔ secrets / writes          │
                  └──────────────────────────────┘
```

**Why this is the right call:**
- 🔒 **RBAC is the enforcement** — not the prompt, not the tool. Secrets are *omitted* and **no write verb is granted anywhere**; RBAC is deny-by-default, so every secret call and every mutation is rejected at the API server even if the model is compromised.
- 🪪 **In-cluster SA token** — the pod already runs as `hermes-agent`; kubectl inside the pod uses `/var/run/secrets/kubernetes.io/serviceaccount/token` automatically. No kubeconfig, no long-lived cloud creds to leak.
- 🎯 **ClusterRole for cluster-wide reads, a slim namespaced Role for the few namespace-local reads the cluster-wide role withholds** (notably configmaps in `devops-agent`).

---

## 📂 Manifests

| File | What |
|---|---|
| `01-serviceaccount.yaml` | The `hermes-agent` SA (the pod already runs as it) |
| `02-role.yaml` | **Namespaced read-only Role** — `get/list/watch` in `devops-agent`, including configmaps; **no secrets, no writes** |
| `03-rolebinding.yaml` | Binds the namespaced Role to the SA |
| `04-clusterrole-readonly.yaml` | Cluster-wide **read-only** view + its binding; excludes Secrets and cluster-wide configmaps |
| `kustomization.yaml` | Applies all of the above |

> 🧠 **Why a namespaced Role at all if it's read-only?** The cluster-wide ClusterRole deliberately **omits configmaps** (teams sometimes stash sensitive values there). The namespaced Role re-grants configmap reads **only inside `devops-agent`**, so Hermes can read its own config without gaining cluster-wide configmap access. If you don't need that, you can drop `02-role.yaml` + `03-rolebinding.yaml` and keep only the ClusterRole.

---

## 🧭 Role vs ClusterRole — why both?

Kubernetes RBAC has **two scopes**, and this profile uses one of each on purpose.

| | **Role** (+ RoleBinding) | **ClusterRole** (+ ClusterRoleBinding) |
|---|---|---|
| Scope | A **single namespace** | The **whole cluster** — every namespace **and** cluster-scoped resources |
| Can grant | Namespaced resources only (pods, configmaps, deployments…) in its namespace | Namespaced resources across **all** namespaces, **plus** cluster-scoped ones (nodes, PVs, namespaces, storageclasses, ClusterRoles…) |
| Here | `hermes-namespace-readonly` in `devops-agent` | `hermes-cluster-readonly`, bound cluster-wide |

**Why the ClusterRole is required.** An SRE agent has to see the *whole* cluster — "how many nodes?", "which pods are CrashLooping in **any** namespace?", "what NetworkPolicy/IngressRoute/RBAC is blocking this?". Two things are **only** expressible with a ClusterRole:

1. **Cluster-scoped resources** (`nodes`, `persistentvolumes`, `namespaces`, `storageclasses`, RBAC objects, webhook configs) have no namespace — a Role literally cannot grant them.
2. **Cross-namespace reads** — one ClusterRole + ClusterRoleBinding grants `get/list/watch` in every namespace, instead of copying a Role into each one.

**Why we *still* add a namespaced Role.** The ClusterRole deliberately **omits `configmaps`** cluster-wide, because teams sometimes stash sensitive values in ConfigMaps in other namespaces. But Hermes needs to read **its own** config (ConfigMaps in `devops-agent`). The namespaced Role re-grants **only** `configmaps` reads **only** inside `devops-agent` — least privilege: the broad cluster read stays safe, the one sensitive-ish resource is scoped to a single namespace.

> 🧩 **Binding matters as much as the role.** A `RoleBinding` grants a role's rules **in one namespace**; a `ClusterRoleBinding` grants them **cluster-wide**. (You *can* also reference a ClusterRole from a RoleBinding to reuse its rules in just one namespace — not done here, since we genuinely want cluster-wide observation.) Either way, RBAC is **additive and deny-by-default**: the agent's effective access is the *union* of both, and anything not listed — every write verb, all secrets — is refused at the API server.

Prefer a single-namespace agent? Drop `02-role.yaml` + `03-rolebinding.yaml` and keep only the ClusterRole (Hermes just loses in-namespace ConfigMap reads).

---

## 🔎 What Hermes can inspect (cluster-wide, read-only)

`get` / `list` / `watch` only, across all namespaces:

- Nodes and namespaces
- Pods, pod logs, pod status, services, endpoints, events
- Deployments, ReplicaSets, StatefulSets, DaemonSets (+ status)
- Jobs, CronJobs, HorizontalPodAutoscalers
- PVCs/PVs, storage classes, volume attachments, CSI nodes/drivers
- NetworkPolicies, Ingresses, IngressClasses
- Traefik CRDs: IngressRoutes, middlewares, TLS options/stores, TraefikServices, ServersTransports
- Metrics API for nodes/pods (when metrics-server is installed)
- RBAC objects read-only: Roles, RoleBindings, ClusterRoles, ClusterRoleBindings
- Admission guardrails read-only: Validating/Mutating WebhookConfigurations
- PodDisruptionBudgets, ResourceQuotas, LimitRanges

Plus, **inside `devops-agent` only**: configmaps (read-only).

Typical questions this answers:

```bash
NAMESPACE=devops-agent
POD=hermes-agent-0

kubectl get nodes
kubectl get pods -A -o wide
kubectl get events -A --field-selector type=Warning --sort-by=.lastTimestamp
kubectl describe pod -n "$NAMESPACE" "$POD"
kubectl logs -n "$NAMESPACE" "$POD" --all-containers --tail=200
kubectl get rolebindings,roles -A
kubectl get networkpolicies -A
kubectl get ingressroute -A
```

## ⛔ What remains blocked (deny-by-default)

- **Secrets** — no `get`/`list`/`watch`/mutation in any namespace
- **Cluster-wide configmaps** — denied (sensitive values risk); readable only in `devops-agent`
- **Every write verb everywhere** — no `create`/`patch`/`update`/`delete` on any resource, so no restart, scale, edit, create, or delete
- Node mutation, namespace mutation, RBAC mutation, webhook/CRD mutation
- `serviceaccounts/token`, `tokenreviews`, `subjectaccessreviews`

---

## 🚀 Apply

```bash
kubectl apply -k .
```

```
serviceaccount/hermes-agent configured
role.rbac.authorization.k8s.io/hermes-namespace-readonly created
clusterrole.rbac.authorization.k8s.io/hermes-cluster-readonly created
rolebinding.rbac.authorization.k8s.io/hermes-namespace-readonly created
clusterrolebinding.rbac.authorization.k8s.io/hermes-cluster-readonly created
```

### 🧰 kubectl install — init container onto the PVC (the multi-container gotcha)

The Hermes pod has **two app containers**, and this is the #1 thing that trips people up:

| Container | Runs | Has the SA token? |
|---|---|---|
| `hermes` | the gateway + dashboard (Python) | yes |
| **`claude-bridge`** | the `claude` CLI — **this is where Hermes' `Bash`/exec tool actually runs** | yes |

If kubectl is only in one container, Hermes reports *"there's no kubectl in this environment"* — because the `claude` CLI's shell lives in the bridge. (Hermes will silently fall back to hitting the K8s REST API with curl + the SA token — which works, but isn't kubectl.)

✅ **The fix (what's deployed): an `init-kubectl` init container installs kubectl onto the shared PVC, and both app containers pick it up via PATH + a symlink.** This installs it **once, before the app containers start**, and it **survives pod restarts/recreation** because it lives on the PVC.

**1. Init container** (`../workloads/statefulset.yaml`, `initContainers: init-kubectl`) — resolves the current stable kubectl release at startup, installs atomically, and verifies it before swap-in:

```sh
KUBECTL_VERSION="$(curl -fsSL --retry 3 --retry-delay 2 https://dl.k8s.io/release/stable.txt)"
case "$KUBECTL_VERSION" in
  v*) ;;
  *) echo "Unexpected kubectl stable version: $KUBECTL_VERSION" >&2; exit 1 ;;
esac
DEST=/opt/data/bin/kubectl          # /opt/data is the shared PVC (agent-state)
mkdir -p /opt/data/bin
TMP="${DEST}.tmp.$$"
curl -fsSL --retry 3 --retry-delay 2 -o "$TMP" \
  "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl"
chmod +x "$TMP"
"$TMP" version --client=true | head -1   # verify it runs before swapping in
mv -f "$TMP" "$DEST"                       # atomic: a partial download can't break it
```

**2. Both app containers find it** because `/opt/data` (the PVC) is mounted in each:

- **`PATH`** env in both `hermes` and `claude-bridge` starts with `/opt/data/bin`, so plain `kubectl` resolves.
- A **symlink** to `/usr/local/bin/kubectl` is created in each container (the `hermes` container does it in `lifecycle.postStart`; the `claude-bridge` container does it in its startup args) so tools that reset/ignore PATH still find it.

| Where | Path | Survives restart? |
|---|---|---|
| Canonical install (PVC) | `/opt/data/bin/kubectl` | ✅ yes (PVC-backed) |
| PATH (both containers) | `/opt/data/bin:` prepended | ✅ |
| Compatibility symlink | `/usr/local/bin/kubectl` | ✅ recreated each start |

- ✅ **Current stable kubectl** is resolved from `https://dl.k8s.io/release/stable.txt` at pod startup. ✅ Installed once by the init container (not on every bridge start).
- Both containers have the **in-cluster SA token** mounted, so kubectl auto-authenticates as `hermes-agent`, scoped by the read-only RBAC above.
- The `claude-bridge` agent path may run **read-only `kubectl`** (get/describe/logs/top/events/explain/api-resources/version) for debugging across namespaces. Mutation, `exec`/`port-forward`, and Secret reads are denied by the bridge tool policy **and** by this RBAC, so the cluster is the hard backstop.

> Alternative for production: bake kubectl into a **custom image** (no per-start download at all).

---

## 🔑 How authentication works (the GKE question answered)

There are **two distinct auth layers** — don't conflate them:

| Goal | Mechanism | Needed for THIS setup? |
|---|---|---|
| Talk to **the cluster Hermes runs in** | **In-cluster ServiceAccount token** — auto-mounted at `/var/run/secrets/kubernetes.io/serviceaccount/token`; kubectl uses it automatically. **No kubeconfig, no gcloud, no keys.** | ✅ **Yes — this is it** |
| Talk to **GCP APIs** or a **different/remote** GKE cluster | Out of scope for this ServiceAccount. Do not add cloud-provider identity annotations or bind this KSA to a Google service account. | ❌ **No — this identity is Kubernetes-native only** |

**Proof the in-cluster token is all you need (tested):**

```bash
$ kubectl exec hermes-agent-0 -c hermes -- sh -c 'echo $KUBECONFIG; kubectl auth whoami'
KUBECONFIG:               # ← unset
~/.kube/config:  no       # ← none
Username   system:serviceaccount:devops-agent:hermes-agent   # ← authenticated anyway
Groups     [system:serviceaccounts system:serviceaccounts:devops-agent system:authenticated]
```

No credentials on disk; the pod's identity *is* the auth — more secure than a kubeconfig (token is short-lived, pod-bound, and scoped by the read-only RBAC above).

> 🌐 **If Hermes must manage a remote cluster or call GCP APIs:** design a separate approved access path. Do not retrofit this read-only Kubernetes ServiceAccount with cloud-provider identity bindings.

---

## ✅ POC — tested live (real results)

Run **from inside the pod** (uses the SA token — exactly how Hermes' `terminal_tool` runs it). `kubectl auth can-i --as=…` does **not** work on managed clusters that block user impersonation (e.g. GKE), so test in-pod:

```bash
kubectl exec hermes-agent-0 -n devops-agent -c hermes -- sh -lc 'kubectl auth can-i <verb> <resource> -n <namespace>'
```

| Action | Command | Result |
|---|---|---|
| 👀 get pods | `kubectl get pods` | ✅ `hermes-agent-0  2/2  Running` |
| 👀 get deployments (other ns) | `kubectl get deploy -n traefik` | ✅ `traefik  1/1` |
| 👀 get nodes (clusterrole) | `kubectl get nodes` | ✅ nodes listed |
| 👀 read RBAC guardrails | `kubectl get rolebindings,roles -A` | ✅ listed |
| 🔒 **get secret** | `kubectl get secret hermes-agent-secrets` | ⛔ `forbidden … cannot get resource "secrets"` |
| 🔒 list secrets | `auth can-i list secrets` | ⛔ `no` |
| 💥 **patch/restart** | `auth can-i patch statefulsets.apps` | ⛔ `no` |
| 💥 delete pod | `auth can-i delete pods` | ⛔ `no` |
| 💥 delete deployment | `kubectl delete deployment traefik -n traefik` | ⛔ `forbidden … cannot delete` |
| 💥 delete namespace | `auth can-i delete namespaces` | ⛔ `no` |

> ✅ **Every read worked, every write/secret call was denied at the API server.** Secrets and all mutations are physically impossible for this identity.

### Quick verification (run from outside the cluster)

```bash
kubectl -n devops-agent exec hermes-agent-0 -c hermes -- kubectl auth can-i list nodes                    # yes
kubectl -n devops-agent exec hermes-agent-0 -c hermes -- kubectl auth can-i list pods --all-namespaces     # yes
kubectl -n devops-agent exec hermes-agent-0 -c hermes -- kubectl auth can-i list secrets --all-namespaces  # no
kubectl -n devops-agent exec hermes-agent-0 -c hermes -- kubectl auth can-i patch statefulsets             # no
kubectl -n devops-agent exec hermes-agent-0 -c hermes -- kubectl auth can-i delete pods                    # no
```

---

## 🧰 Layer 2 — constrain the tool surface (defense in depth)

RBAC is the wall; add a second layer so a confused/injected LLM can't even *form* a dangerous call:

1. **Closed tool surface on the bridge** — deny `Bash` write-capable tools by default. In `../workloads/statefulset.yaml` the bridge's `--disallowed-tools` gates those tools before the model can call them.
2. **Read-only MCP server** — instead of raw kubectl, front the cluster with [`containers/kubernetes-mcp-server`](https://github.com/containers/kubernetes-mcp-server) (`read_only: true`, `denied_resources: [secrets]`).

> If you later need write actions (restart/scale), don't loosen this Role — add a **separate, narrowly-scoped Role behind a human-approval gate** (`approvals.mode: manual` + the bridge `--permission-mode`). Keep the read-only identity as the default.

---

## 🔒 Hardening checklist (production)

- [ ] `automountServiceAccountToken` only where needed; consider projected tokens with short TTL
- [ ] Keep real secrets in **Secrets** (never ConfigMaps — namespaced configmaps are readable here)
- [ ] Source app secrets from **External Secrets / Sealed Secrets / Secret Manager**, not flat files
- [ ] Add **audit logging** on the API server; alert on any unexpected verb by `hermes-agent`
- [ ] Require **human approval** before introducing any mutating Role
- [ ] Periodically run the POC table above as a **regression test** (CI: `kubectl auth can-i` from a pod)

---

## 🔗 Related

- `../README.md` — full Hermes Kubernetes deployment guide and reference

🎯 **Bottom line:** kubectl **+** a tight **read-only** RBAC profile on the pod's own ServiceAccount is the correct, tested foundation. By *omitting* secrets and *every* write verb, "observe everything, change nothing, never touch secrets" is a hard guarantee — not a hope.
