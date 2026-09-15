# 🥧 pi-agents — pi CLI executing tools on OpenCode's free models, with Codex-style approvals

Run the [pi](https://github.com/earendil-works/pi-mono) coding agent in your terminal, in any directory, on OpenCode's **free**
models (`mimo-v2.5-free`, `big-pickle`, `nemotron-3-ultra-free`, …) — with **pi executing the tools** and a three-option
approval prompt before anything risky runs, the way Codex CLI does it.

```
 pi (your terminal, your cwd)                          OpenCode Bridge — PURE LLM instance (:18385)
 ┌──────────────────────────────────────┐   chat      ┌──────────────────────────────────────────┐
 │ text-tools-provider (../common)      │ ──────────▶ │ opencode_bridge.py                       │
 │   tool schemas → system prompt       │             │   OPENCODE_CONFIG=opencode/pure-llm.json  │
 │   "<tool_call>{…}</tool_call>" text  │ ◀────────── │   (every OpenCode tool denied)            │
 │   → real pi ToolCall                 │   text      │   → opencode run → mimo-v2.5-free         │
 │ guardrails: classify → approve/deny  │             └──────────────────────────────────────────┘
 │ pi runs bash/read/write/edit/…       │
 └──────────────────────────────────────┘
```

Why the extra bridge instance: OpenCode's free tier only works *inside* OpenCode, and `opencode run` is a text-only surface
that drops OpenAI `tools`. So pi's provider **emulates function calling over text** (the models already emit
`<tool_call>` blocks natively when they have no tools), and the bridge it talks to must have OpenCode's own tools switched
off — otherwise OpenCode *and* pi would both act on the same request. Your existing `:18383` bridge for Hermes is untouched.

---

## 📦 What's in this folder

| Path | Purpose |
|------|---------|
| `install.sh` | 🧰 One-shot bootstrap: installs Python/Node/pi/OpenCode if missing, runs the self-checks, registers **both bridges as auto-start user services** (idempotent; `--uninstall` removes them) |
| `run-bridge.sh` | ▶️ Launcher: `run` · `upstream` · `test` · `approve` · `models` · `selfcheck` · `install-service` · `logs` (sources `../common/launcher.sh`) |
| `guardrails.json` | ⚙️ Policy: `profile` (dangerous-only / read-only), `mode` (ask / audit / enforce), dangerous programs & patterns, protected paths, call budget |
| `opencode/pure-llm.json` | 🧠 OpenCode config with every tool denied → the bridge becomes a plain LLM |
| `opencode/opencode.json` + `opencode/plugins/guardrails.ts` | 🛡️ Same policy for a *tool-enabled* bridge (the classic `:18383` Hermes path), audit or enforce |
| `.env.example` | ⚙️ Every environment variable |
| [`../pi-opencode-cli/`](../pi-opencode-cli) | ⌨️ The **terminal** flavour of this backend: `pi --provider opencode-cli` on the same free models, its own bridge on `:18386`, no Hermes, guardrails opt-in |
| [`../common/`](../common) | 🧩 Shared with every backend: `pi_bridge.py` (Hermes endpoint), `extensions/text-tools-provider` (pi provider, tool-call emulation), `extensions/guardrails` (policy + approvals + tests), `prompts/sre.md` |

---

## ✅ Prerequisites

Everything runs on your machine as your own user — no Docker, no sudo, no paid API key. Verified on macOS 15 (Apple Silicon); the
launcher also handles Linux with `systemd --user`.

| # | Need | Why | Check |
|---|------|-----|-------|
| 1 | **This repo**, cloned | the bridges, extensions and configs live here | `git clone https://github.com/ch-muhammad-asim/hermes-claude-code-bridge.git ~/hermes-claude-code-bridge` |
| 2 | **Python 3.10+** | both bridges are stdlib-only Python | `python3 --version` |
| 3 | **Node.js 20+ and npm** | installs/runs pi; runs the offline policy tests | `node --version` |
| 4 | **pi ≥ 0.85** ([pi-mono](https://github.com/earendil-works/pi-mono)) | the agent that plans and executes tools | `npm install -g @earendil-works/pi-coding-agent && pi --version` |
| 5 | **OpenCode CLI ≥ 1.14** ([opencode.ai](https://opencode.ai)) | the only way to reach OpenCode's free models | `brew install sst/tap/opencode` (or `curl -fsSL https://opencode.ai/install \| bash`), then `opencode models opencode` must list `opencode/*-free` |
| 6 | **Hermes desktop** with a *Custom Endpoints* page | the chat UI | Settings → Providers → Custom Endpoints |
| 7 | **`curl`**, optional **`jq`** | tests and model listing | `curl --version`, `brew install jq` |
| 8 | Free loopback ports **18385** (pure-LLM OpenCode bridge) and **18484** (pi bridge) | override with `UPSTREAM_PORT` / `BRIDGE_PORT` in `.env` | `lsof -nP -iTCP:18385 -iTCP:18484 -sTCP:LISTEN` should print nothing |

No accounts or keys are required: OpenCode's free tier is anonymous, pi needs no login for the `opencode-bridge` provider, and the
bridges are unauthenticated on loopback (set `PI_BRIDGE_API_KEY` if you expose one).

Quick pre-flight, all in one go:

```bash
python3 --version && node --version && pi --version && opencode --version && opencode models opencode | head -3
```

Then run the offline checks from this folder before starting anything:

```bash
cd ~/hermes-claude-code-bridge/pi-agents/macos/opencode && ./run-bridge.sh selfcheck
```

---

## 🚀 Quick start

### ♻️ Persistent setup (recommended) — one command

```bash
cd ~/hermes-claude-code-bridge/pi-agents/macos/opencode && ./install.sh
```

It installs anything missing (Python, Node, pi, OpenCode), runs the offline checks, and registers two **user services** that start at
login and restart on crash: `com.hermes.opencode-pure-llm` on `:18385` and `com.hermes.pi-bridge` on `:18484` (launchd on macOS,
`systemd --user` on Linux). Re-run it any time after `git pull` or after changing `.env` / `guardrails.json`. Then connect Hermes
(see 🖥️ below) — done. `./install.sh --uninstall` removes the services; `./run-bridge.sh service-status` and `./run-bridge.sh logs`
show what they are doing.

### 🧪 Manual / terminal use

Set the repo path once per shell:

```bash
export PI_AGENTS="$HOME/hermes-claude-code-bridge/pi-agents/macos/opencode"
```

```bash
export PI_COMMON="$PI_AGENTS/../common"
```

**1. Start the pure-LLM bridge** (foreground, its own port; leave it running in a spare terminal):

```bash
cd "$PI_AGENTS/../../../opencode/hermes-desktop" && BRIDGE_PORT=18385 OPENCODE_CONFIG="$PI_AGENTS/opencode/pure-llm.json" ./run-bridge.sh
```

Check it and see the free models it offers:

```bash
curl -s http://127.0.0.1:18385/v1/models | jq -r '.data[].id'
```

**2. Run pi in any directory on any free model:**

```bash
cd ~/projects/my-project && pi -e "$PI_COMMON/extensions/text-tools-provider" -e "$PI_COMMON/extensions/guardrails" --provider opencode-bridge --model opencode/mimo-v2.5-free
```

Ask it `list the contents of pwd` — it runs `ls` itself, in *that* directory. Ask it `create a directory test-1` — it just does it.
Ask it `delete the build directory` — you get the prompt:

```
Approve bash?  rm -rf build   — destructive or irreversible operation (`rm -rf`)
  › Yes, run it once
    Yes, and don't ask again this session
    No, and tell pi what to do differently
```

Swap models with `--model` (or `/model` inside the session):

```bash
pi -e "$PI_COMMON/extensions/text-tools-provider" -e "$PI_COMMON/extensions/guardrails" --provider opencode-bridge --model opencode/nemotron-3-ultra-free
```

```bash
pi -e "$PI_COMMON/extensions/text-tools-provider" -e "$PI_COMMON/extensions/guardrails" --provider opencode-bridge --model opencode/big-pickle
```

List what the provider registered:

```bash
pi -e "$PI_COMMON/extensions/text-tools-provider" --list-models opencode-bridge
```

Scope `Ctrl+P` cycling to the free models:

```bash
pi -e "$PI_COMMON/extensions/text-tools-provider" -e "$PI_COMMON/extensions/guardrails" --provider opencode-bridge --model opencode/mimo-v2.5-free --models 'opencode/*'
```

Add the SRE persona:

```bash
pi -e "$PI_COMMON/extensions/text-tools-provider" -e "$PI_COMMON/extensions/guardrails" --provider opencode-bridge --model opencode/mimo-v2.5-free --append-system-prompt "$PI_COMMON/prompts/sre.md"
```

### Make it the default (plain `pi`, no flags)

```bash
jq --arg d "$PI_COMMON" '.extensions = [($d + "/extensions/text-tools-provider"), ($d + "/extensions/guardrails")] | .defaultProvider = "opencode-bridge" | .defaultModel = "opencode/mimo-v2.5-free"' ~/.pi/agent/settings.json > ~/.pi/agent/settings.json.tmp && mv ~/.pi/agent/settings.json.tmp ~/.pi/agent/settings.json
```

Then, from any project:

```bash
pi
```

### Headless / scripted

There is no terminal to answer the prompt in `-p` mode, so say what should happen to risky calls (`deny` is the default):

```bash
echo "Summarise the failing pods in namespace prod" | PI_APPROVAL_NONINTERACTIVE=allow pi -p --no-session -e "$PI_COMMON/extensions/text-tools-provider" -e "$PI_COMMON/extensions/guardrails" --provider opencode-bridge --model opencode/mimo-v2.5-free
```

Bridge on another host or port:

```bash
PI_UPSTREAM_BASE_URL=http://10.0.0.5:18385/v1 pi -e "$PI_COMMON/extensions/text-tools-provider" -e "$PI_COMMON/extensions/guardrails" --provider opencode-bridge --model opencode/mimo-v2.5-free
```

---

## 🛡️ Approvals — how the prompt decides

Every tool call is classified by `../common/extensions/guardrails/policy.mjs` before it runs. The **profile** in
[`guardrails.json`](guardrails.json) decides what "risky" means:

| `profile` | runs without asking | held for approval |
|-----------|--------------------|-------------------|
| `dangerous-only` *(default)* | everyday work: `mkdir`, `cp`, `mv`, `rm file`, `touch`, `chmod +x`, edits/writes inside the project, `git commit/checkout/merge/rebase/stash`, `npm`/`pip`/`brew install`, `python`/`node`/`make`, `kubectl get/describe/logs/port-forward`, `helm list/template`, `terraform plan`, `docker build/run/exec/stop`, `curl` GET/POST, `ssh`, `kill <pid>` | destructive / irreversible / privileged / secret-exposing: `rm -rf`, `rm` on `/` or `~`, `sudo`, `dd`, `mkfs`, `diskutil`, `shutdown`, `launchctl`/`systemctl`/`crontab`, `chmod -R`/`777`, writes to `/etc /usr /Library ~/.ssh ~/.zshrc …`, `curl … \| sh`, `kubectl apply/delete/scale/rollout restart/exec/drain`, `kubectl get secret -o yaml`, `helm install/upgrade/uninstall`, `terraform/terragrunt apply/destroy`, `gcloud`/`aws`/`az` create/delete/update/terminate + secret/token retrieval, `git push`, `git reset --hard`, `git clean -f`, `git checkout -- .`, `git branch -D`, `gh pr merge`, `gh repo delete`, `gh release create`, `docker rm/rmi/prune/push`, `docker run --privileged`, `npm publish`, `kill -9`, `pkill`, `env`/`printenv`, Jira/Slack writes via `acli`/`jira`/`slack` (`create`, `transition`, `delete`, `assign`, `comment`), nested AI CLIs (`claude`, `opencode`, `codex`, `pi`) |
| `read-only` | allowlisted read-only programs only (`kubectl get`, `gcloud … list`, `git log`, `cat`, `grep`, …), no redirection, no `$(…)`, paths inside allowed roots | everything else, including `mkdir`, `edit`/`write` |

When a call is held you get the card:

```
> 🔧 bash  rm -rf build · ⏸ held

⏸ Approval required — destructive or irreversible operation (`rm -rf`)
    rm -rf build
Reply approve to run it, or tell me what to do differently.
```

- **Yes, run it once** / **Yes, and don't ask again this session** / **No, and tell pi what to do differently** — in the terminal.
- In Hermes: reply **approve** (or `yes`, `go ahead`, `run it`) and the held call runs in the next turn.
- **Budget:** after 40 tool calls in one run the agent is stopped (`max_tool_calls_per_run`).

Three modes in [`guardrails.json`](guardrails.json) → `"mode"`:

| mode | safe calls | risky calls |
|------|-----------|-------------|
| `ask` *(default)* | run | prompt (headless: `PI_APPROVAL_NONINTERACTIVE`) |
| `audit` | run | run, logged as `would_block` |
| `enforce` | run | blocked (read-only agent) |

Every decision is a JSON line in `~/.pi-bridge-audit.jsonl` (`PI_GUARDRAILS_AUDIT` to move it):

```bash
tail -f ~/.pi-bridge-audit.jsonl | jq -c '{ts,enforcer,event,tool,arg,reason}'
```

Tune it in `guardrails.json`: `profile`, `mode`, and the `dangerous.programs` / `dangerous.patterns` / `dangerous.protected_write_globs` lists (deep-merged onto the defaults in `policy.mjs`; arrays *replace*, so copy a default list before adding to it). Validate offline:

```bash
node "$PI_COMMON/extensions/guardrails/selfcheck.mjs"
```

```bash
PI_GUARDRAILS_CONFIG="$PI_AGENTS/guardrails.json" node "$PI_COMMON/extensions/guardrails/selfcheck.mjs"
```

---

## 🖥️ Hermes → pi (every tool call through pi, approvals in chat)

`pi_bridge.py` is an OpenAI-compatible endpoint for Hermes that runs **pi headless** per request. pi executes all tools in
`PI_BRIDGE_CWD` (default `$HOME`) under the same guardrails. A chat window has no terminal prompt, so the Codex-style approval
becomes a two-turn handshake:

```
 you:  delete the build directory
 pi:   > 🔧 bash  rm -rf build · ⏸ held
       ⏸ Approval required — destructive or irreversible operation (`rm -rf`)
       ```bash
       rm -rf build
       ```
       Reply approve to run it, or tell me what to do differently.
 you:  approve
 pi:   > 🔧 bash  rm -rf build · ✅ no output (0.0s)   …done
```

Start both bridges (pure-LLM upstream on `:18385`, pi bridge on `:18484`) as auto-start user services:

```bash
cd "$PI_AGENTS" && ./run-bridge.sh install-service
```

Or in two terminals, foreground:

```bash
cd "$PI_AGENTS" && ./run-bridge.sh upstream
```

```bash
cd "$PI_AGENTS" && ./run-bridge.sh
```

Exercise it without Hermes (`mkdir` + `ls` run, `rm -rf` held, then the approval):

```bash
cd "$PI_AGENTS" && ./run-bridge.sh test && ./run-bridge.sh approve
```

**Connect Hermes:** Settings → Providers → Custom Endpoints → **New endpoint** (don't edit the OpenCode one):

| Field | Value |
|-------|-------|
| Name / Provider ID | `pi-agent` |
| Endpoint URL | `http://127.0.0.1:18484/v1` |
| Default Model | `opencode/mimo-v2.5-free` |
| API Key | blank unless you set `PI_BRIDGE_API_KEY` |
| ☑️ Discover models | on — then **Test**, then **Save** |

Approval behaviour for Hermes is `PI_BRIDGE_APPROVAL` (`.env` or env): `ask` (default, handshake above), `allow` (run everything,
still logged and shown with `›` notes — POC mode), `deny` (read-only). What counts as "safe" is the same `guardrails.json` pi uses
in the terminal.

**Where the tools run:** the project you select in Hermes' sidebar. Hermes writes `Current working directory: <path>` into its
system prompt and the bridge runs pi there (`PI_BRIDGE_CWD_FROM_PROMPT=0` to disable). With no project selected, or when the path
does not exist on the bridge host, it falls back to `PI_BRIDGE_CWD` (default `$HOME`).

### 🧾 What a reply looks like

Every tool call is one line of an activity log (a Markdown blockquote), with its result status appended when it finishes; the
model's answer follows; a one-line footer closes the turn:

```
> 🔧 bash  ls -la · ✅ 8 lines (0.0s)
> 🔧 bash  wc -l < deploy.yaml · ✅ 1 line (0.0s)

Four directories, no loose files — github/ is the most recently touched.

🥧 pi · opencode/mimo-v2.5-free · 2 tool calls · 6.6s
```

A held call ends its line with `⏸ held` and is followed by the approval card (reason, the exact command in a code block, how to
approve). Knobs: `PI_BRIDGE_SHOW_TOOLS=0` hides the activity log and footer; `PI_BRIDGE_SHOW_OUTPUT=N` quotes the first *N*
lines of each tool's output under its line (default 0 = off); `PI_BRIDGE_TOOLS=read,bash,grep,find,ls` restricts pi's tool set;
`PI_BRIDGE_SYSTEM_PROMPT` (default `../common/prompts/sre.md`); `PI_BRIDGE_TIMEOUT` (default 600 s per request). Endpoints:
`/health`, `/config`, `/metrics`, `/v1/models`, `POST /v1/models/refresh`.

### The original `:18383` OpenCode bridge

Untouched. If you keep using it directly from Hermes, the agent there is OpenCode, headless, with no approval prompt. The same policy
is available for it as an OpenCode plugin (`opencode/opencode.json` + `opencode/plugins/guardrails.ts`): `mode: enforce` blocks risky
calls, anything else only logs them. Enable by adding to that bridge's `.env` (on the account running the service) and re-running its `./run-bridge.sh install-service`:

```bash
printf 'OPENCODE_CONFIG=%s/opencode/opencode.json\nOPENCODE_CONFIG_DIR=%s/opencode\n' "$PI_AGENTS" "$PI_AGENTS" >> "$PI_AGENTS/../../../opencode/hermes-desktop/.env"
```

---

## 🔬 How the tool emulation works (for the curious)

1. pi hands the provider its `Context`: system prompt, messages, and the JSON Schemas of the active tools.
2. The provider appends a `# Tool calling` section: *end your message with exactly one* `<tool_call>{"name","arguments"}</tool_call>` *block*.
3. The reply is streamed; text before the tag is streamed to you, the block is parsed (JSON, or the `<function=…><parameter=…>` form MiMo emits natively — arguments coerced by schema type) into a real pi `ToolCall`, and the stream ends with `stopReason: "toolUse"`.
4. pi runs the tool (after the approval gate) and sends the result back; the provider renders it as a `<tool_result tool id>` block in the next request. One tool call per model turn.
5. Assistant history is re-rendered the same way, so multi-step tasks work across turns.

Limits: one call per turn (the model chains them across turns), no parallel tool calls, usage is estimated (the bridge reports none on streamed replies), and reliability depends on the free model following the protocol — `mimo-v2.5-free` does; if a model returns a malformed block the raw text is shown instead of executing anything.

---

## 🩺 Troubleshooting

| Symptom | Fix |
|---------|-----|
| `No models matching "opencode-bridge"` | Provider not loaded: add `-e "$PI_COMMON/extensions/text-tools-provider"` or register it in `settings.json` |
| `discovery … failed; using fallback list` | Bridge not up: `curl http://127.0.0.1:18385/health`; or set `PI_UPSTREAM_BASE_URL` |
| The model *describes* running a command but nothing executes | You pointed pi at the tool-enabled `:18383` bridge — OpenCode ran it over there. Use the pure-LLM instance (`pure-llm.json`, `:18385`) |
| Headless run says `Not approved: headless run …` | Expected in `-p`/`--mode json`: set `PI_APPROVAL_NONINTERACTIVE=allow` or switch `mode` to `audit` |
| A harmless command keeps prompting | Read the `reason` in the audit log; add the program to `bash.allowed_commands` (copy the default list first), re-run the selfcheck |
| `Model scope: gpt-5.6-terra` at startup | Cosmetic: pi's saved default; `--model` wins (check `provider`/`model` in the reply footer or `message_end`) |
| Bridge answers with `<tool_call>` text in Hermes | That bridge was started with `pure-llm.json` — Hermes needs the tool-enabled config; keep the two instances on separate ports |
