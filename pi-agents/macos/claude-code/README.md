# 🤖 pi-agents · Claude Code backend — pi executes the tools, Claude Code is the brain (native tool calling)

Same concept as the [OpenCode backend](../opencode): Hermes (or your terminal) talks to **pi**, pi plans and executes every tool call
under **Codex-style approvals**, and the model behind pi is the **Claude Code CLI** — `claude-opus-5`, `claude-fable-5-1`,
`claude-fable-5`, `claude-sonnet-5`, … — on your normal Claude subscription. Here the tool calls are **native**: pi's tools reach
Claude as real functions, and one warm `claude` process serves a whole conversation.

```
 Hermes ──▶ pi_bridge.py :18485 ──▶ pi (tools + guardrails) ──/v1/chat/completions + tools──▶ Claude Code NATIVE bridge :18186
                                                                                                │  one warm `claude -p --input-format stream-json`
                                                                                                │  per conversation · built-in tools OFF
                                                                                                ├─ MCP shim: pi's tools = mcp__host__bash/read/write/…
                                                                                                └─ claude.ai connectors ON (read-only allowlist)
```

How a tool call flows: Claude calls `mcp__host__bash` → the shim forwards it to the bridge → the bridge answers pi's request with a
standard `tool_calls` → pi runs the tool (guardrails apply) and sends the `tool` result → the bridge hands it back to the *same*
`claude` process, which continues. No text protocol, no per-turn process spawn: a follow-up turn costs about a second of overhead.

Why not pi's built-in Anthropic login? Anthropic bills third-party OAuth clients like pi from **extra usage**, not the plan
(`"Third-party apps now draw from extra usage, not plan limits"`). The Claude Code CLI is first-party, so routing pi through
the bridge keeps you on plan limits. Claude's **built-in** tools (Bash, Edit, Write, Read, …) are disallowed so **only pi touches
your machine**, with approvals — while Claude's **claude.ai connectors** stay usable natively, limited to a read-only allowlist
(Jira/Confluence get/search/fetch). Anything that creates, edits, transitions or comments is refused by Claude's permission layer;
widen it with `CLAUDE_CODE_MCP_ALLOW` in `.env` (`*` = every connector tool). `PI_CLAUDE_NATIVE=0` falls back to the older
text-emulation path on the plain Claude bridge; `PI_CLAUDE_CONNECTORS=0` additionally strips connectors (`claude --tools ""`).

---

## 📦 What's in this folder

| Path | Purpose |
|------|---------|
| `install.sh` | 🧰 One-shot bootstrap: Python / Node / pi / Claude Code if missing, login probe, self-checks, **both bridges as auto-start user services** (`--uninstall` removes) |
| `run-bridge.sh` | ▶️ Launcher: `run` · `upstream` · `test` · `approve` · `models` · `selfcheck` · `install-service` · `logs` |
| `guardrails.json` | ⚙️ Approval policy (`profile`: dangerous-only / read-only, `mode`: ask / audit / enforce) — same engine as every other backend |
| `.env.example` | ⚙️ Every setting (ports, model, effort, budget, approval mode, cwd) |
| [`pi-cli/`](pi-cli) | ⌨️ **Terminal flavour**: plain `pi` on Claude Code with native pi tools, **all** connectors, no guardrails (own bridge on `:18187`) |
| [`../common/`](../common) | 🧩 Shared: `pi_bridge.py`, `extensions/text-tools-provider`, `extensions/guardrails`, `prompts/sre.md`, launcher & installer libraries |
| `native/claude_native_bridge.py` + `native/mcp_shim.py` | 🧠 The **native** Claude Code bridge this backend runs on `:18186`: OpenAI `tools` → real Claude function calls through the MCP shim, one warm `claude` process per conversation, streaming, read-only connector allowlist |
| [`../../../mac/`](../../../mac) | 🌉 The classic text-only Claude Code Bridge — only used with `PI_CLAUDE_NATIVE=0` |

---

## ✅ Prerequisites

| # | Need | Check |
|---|------|-------|
| 1 | This repo cloned | `git clone https://github.com/ch-muhammad-asim/hermes-claude-code-bridge.git ~/hermes-claude-code-bridge` |
| 2 | Python 3.10+ | `python3 --version` |
| 3 | Node.js 20+ / npm | `node --version` |
| 4 | pi ≥ 0.85 | `npm install -g @earendil-works/pi-coding-agent && pi --version` |
| 5 | **Claude Code CLI ≥ 2.1**, already authenticated (the login you use interactively) | `claude --version`; the installer probes the login and says if it has expired |
| 6 | Hermes desktop with *Custom Endpoints* | Settings → Providers → Custom Endpoints |
| 7 | Free ports **18186** (native Claude bridge) and **18485** (pi bridge) | `lsof -nP -iTCP:18186 -iTCP:18485 -sTCP:LISTEN` prints nothing |

Login sanity check (a plain tool-less `claude` call) — must answer `pong`, not `Failed to authenticate`:

```bash
claude -p --tools "" --no-session-persistence --model haiku "Reply with exactly: pong"
```

If it fails: `claude login` and try again. The services run as your user and reuse that login **and your claude.ai connectors**
(`claude mcp list` shows which are connected — Atlassian must say `✔ Connected` for Jira questions to work).

---

## 🚀 Quick start

### ♻️ Persistent (recommended)

```bash
cd ~/hermes-claude-code-bridge/pi-agents/macos/claude-code && ./install.sh
```

Registers `com.hermes.claude-code-pure-llm` (`:18186`) and `com.hermes.pi-bridge-claude-code` (`:18485`) as launchd user services
(systemd `--user` on Linux) and runs the live test: `mkdir` + `ls` execute without asking, an `rm -rf` is held for approval.

### 🧪 Foreground (two terminals)

```bash
cd ~/hermes-claude-code-bridge/pi-agents/macos/claude-code && ./run-bridge.sh upstream
```

```bash
cd ~/hermes-claude-code-bridge/pi-agents/macos/claude-code && ./run-bridge.sh
```

### 🔎 Exercise it without Hermes

```bash
cd ~/hermes-claude-code-bridge/pi-agents/macos/claude-code && ./run-bridge.sh test && ./run-bridge.sh approve
```

---

## 🖥️ Connect Hermes

Settings → Providers → Custom Endpoints → **New endpoint** (keep your OpenCode endpoint; switch with **Use**):

| Field | Value |
|-------|-------|
| Name / Provider ID | `pi-claude` |
| Endpoint URL | `http://127.0.0.1:18485/v1` |
| Default Model | `claude-opus-5` (or `claude-fable-5-1`) |
| API Key | blank unless `PI_BRIDGE_API_KEY` is set |
| ☑️ Discover models | on → **Test** (7 models) → **Save** → **Use** |

Then in any project: `list the contents of pwd` and `make a directory test-1` run immediately; `delete test-1` shows the approval card; reply `approve`.

### 🔌 Connectors (Jira, Confluence, …)

Claude keeps its claude.ai connectors on this path, limited to a **read-only allowlist** — Atlassian by default:
`getAccessibleAtlassianResources`, `getJiraIssue`, `searchJiraIssuesUsingJql`, `getVisibleJiraProjects`, `getTransitionsForJiraIssue`,
`lookupJiraAccountId`, `getConfluencePage`, `searchConfluenceUsingCql`, `getConfluenceSpaces`, `search`, `fetch`, … (full list in
`run-bridge.sh`). Claude calls them natively inside its own turn; pi never sees them, so they show up in the reply as plain text rather
than `🔧` lines. Anything not on the list — every create/edit/transition/comment — is refused by Claude Code's permission system
(`--permission-mode default`), so connector **writes cannot happen** on this path. Extend the allowlist with `CLAUDE_CODE_MCP_ALLOW`
(comma-separated `mcp__claude_ai_<Connector>__<tool>` names) in `.env`, or disable connectors entirely with `PI_CLAUDE_CONNECTORS=0`
(strict `claude --tools ""`).

Try in Hermes: `which Jira projects can I see, then list the files in pwd` — the project keys come from the connector, the listing from pi.

### 🎛️ Models

`/v1/models` advertises what the Claude bridge does: `claude-opus-5`, `claude-fable-5-1`, `claude-fable-5`, `claude-opus-4-8`,
`claude-sonnet-5`, `claude-sonnet-4-6`, `claude-haiku-4-5`. Override with `CLAUDE_CODE_BRIDGE_MODELS` in `.env`; the model is
forwarded to `claude --model`, so any id your subscription can run works. Reasoning depth: `CLAUDE_CODE_EFFORT=low|medium|high|xhigh|max` is the default; Hermes' **Min/Low/Med/High selector overrides it per message** (sent as `reasoning_effort`, mapped to `pi --thinking` and `claude --effort`).
Spend guard per turn: `CLAUDE_CODE_MAX_BUDGET_USD`.

---

## 🛡️ Approvals

Identical to the OpenCode backend — see [its 🛡️ section](../opencode/README.md#%EF%B8%8F-approvals--how-the-prompt-decides).
Default `profile: "dangerous-only"`: everyday work runs; only destructive / irreversible / privileged / secret-exposing calls are held
(`rm -rf`, `sudo`, `kubectl apply/delete`, `terraform apply`, `git push`, `gh pr merge`, `docker prune`, `curl | sh`, secret access, …):

```
 > 🔧 bash  git push origin main · ⏸ held

 ⏸ Approval required — destructive or irreversible operation (`git push`)
     git push origin main
 Reply approve to run it, or tell me what to do differently.
```

`PI_BRIDGE_APPROVAL=ask|allow|deny` for Hermes; `mode` in `guardrails.json` for the policy; every decision in `~/.pi-bridge-audit.jsonl`.

Terminal use with the real 3-option prompt:

```bash
export PI_COMMON="$HOME/hermes-claude-code-bridge/pi-agents/macos/common"
```

```bash
cd ~/any/project && PI_UPSTREAM_BASE_URL=http://127.0.0.1:18186/v1 PI_UPSTREAM_PROVIDER_ID=claude-code-bridge pi -e "$PI_COMMON/extensions/text-tools-provider" -e "$PI_COMMON/extensions/guardrails" --provider claude-code-bridge --model claude-opus-5
```

---

## 💡 Notes & limits

- Tool calls are native function calls (MCP shim), so Claude can batch several in one turn and pi runs them in parallel.
- Each Hermes message is one headless pi run; the **native bridge keeps one `claude` process per conversation**, so a model turn
  costs ~1 s of overhead instead of a ~4 s spawn + connector handshake (only the first turn of a conversation pays that).
  A one-tool answer lands in ~10 s, a connector look-up in ~15 s. Keep turns few: pi lets the model batch independent calls in one
  turn, the guardrails refuse the 3rd identical call in a run (`PI_GUARDRAILS_REPEAT_LIMIT`), and the prompts tell the model to answer
  from connector data instead of re-piping it through `jq`. A Jira look-up is ~20 s inside Claude (tool discovery + connector handshake
  + query) plus one ~4 s pi turn when Claude Code parks the large result in a file and the model reads it back with `jq`. Pick **Low**
  or **Min** in Hermes for quick questions; `PI_BRIDGE_MODEL=claude-sonnet-5` is the other lever.
- Token usage in replies is estimated (the Claude bridge reports usage only on non-streamed calls).
- Connector calls (Jira, Confluence, …) run **inside Claude**, natively, and are limited to the read-only allowlist in `run-bridge.sh`;
  local execution (bash, files) is always pi's, under the guardrails. `PI_CLAUDE_CONNECTORS=0` switches to strict pure-LLM mode.

## 🩺 Troubleshooting

| Symptom | Fix |
|---------|-----|
| `Third-party apps now draw from extra usage` right after starting `./run-bridge.sh upstream` by hand | You started it from inside a Claude Code / Agent SDK session whose env (`ANTHROPIC_BASE_URL`, `CLAUDE_CODE_*`) leaked in — the launcher now scrubs those; otherwise use `install-service` (clean env) |
| `Failed to authenticate: OAuth session expired` in `./run-bridge.sh logs` | `claude login`, then `./run-bridge.sh install-service` (or just retry — the services reuse the login) |
| Reply is a raw `<tool_call>` block in Hermes | You pointed Hermes at `:18186` (pure LLM). Use the pi bridge `:18485` |
| Hermes says the model is not available | `./run-bridge.sh models`; add ids via `CLAUDE_CODE_BRIDGE_MODELS` in `.env` and re-run `install-service` |
| Slow first token | Effort `medium` on Opus/Fable thinks first; try `CLAUDE_CODE_EFFORT=low` or `PI_BRIDGE_MODEL=claude-sonnet-5` |
| Port in use | A foreground copy is running — `./run-bridge.sh install-service` stops strays automatically |
| Hermes/pi compacts at 200k on a 1M model | The bridge advertises the window as `context_length` on `/v1/models` — `curl -s http://127.0.0.1:18186/v1/models` (pure LLM) and `:18485` (pi bridge, which copies the field through from its upstream). `null` on either means that service is still running pre-`MODEL_CONTEXT_WINDOWS` code |
| Bridge code edited but the behaviour is unchanged | Both services load their Python at start-up, so restart them after any edit or pull — `launchctl kickstart -k "gui/$(id -u)/com.hermes.claude-code-pure-llm"` and the same for `com.hermes.pi-bridge-claude-code` (the opencode chain is `com.hermes.opencode-pure-llm` / `com.hermes.pi-bridge`). Linux: `systemctl --user restart <label>`. Then restart the client — pi reads model metadata once per session |
