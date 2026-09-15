# ⌨️🆓 pi-opencode-cli — `pi` in your terminal, powered by OpenCode's free models

This is the **terminal-native** flavour of the OpenCode backend, the free-model twin of
[`../claude-code/pi-cli`](../claude-code/pi-cli). You type `pi --provider opencode-cli` in any directory and get the pi coding
agent with **its own tools** (`bash`, `read`, `write`, `edit`, `grep`, `find`, `ls`) executing directly in your cwd, while the
model behind it is an **OpenCode free-tier model** (`opencode/mimo-v2.5-free`, `opencode/big-pickle`,
`opencode/nemotron-3-ultra-free`, …) — no API key, no subscription, no per-token cost.

```
 you ──▶ pi (its own tools, your cwd) ──/v1/chat/completions──▶ pure-LLM OpenCode bridge :18386
              ▲                                                    `opencode run` with EVERY tool denied
              └── <tool_call> blocks parsed back into real pi ToolCalls (text emulation)
```

**Text emulation, not native tool calling.** OpenCode's `run` surface is text-only, so the shared provider renders pi's tool
schemas into the system prompt and parses the `<tool_call>` blocks the model writes back into real pi tool calls. pi executes
them. The bridge runs `opencode` with [`../opencode/opencode/pure-llm.json`](../opencode/opencode/pure-llm.json) — every
OpenCode tool denied — so the model on the other side is a plain LLM and can never touch your machine itself. That is the
mirror image of `../claude-code/pi-cli`, which talks to a **native** bridge.

Guardrails are **off by default**, as in `pi-cli` — a `pi` session is your own shell. `PI_CLI_GUARDRAILS=1` turns the shared
Codex-style approval prompts on (see [🛡️](#️-optional-approvals)); with a free model driving your shell, that is worth
considering.

---

## 📦 What's in this folder

| Path | Purpose |
|------|---------|
| `install.sh` | 🧰 One shot: checks/installs pi + OpenCode, registers the bridge as an auto-start service, adds the provider extension and the `opencode-cli/*` models to pi's settings (backup first), smoke-tests. `--default` also makes a bare `pi` use it |
| `run.sh` | ▶️ `upstream` (bridge in the foreground) · `pi [args]` (pi with this provider) · `test` · `models` · `install-service` · `uninstall-service` · `service-status` · `logs` |
| `extensions/opencode-cli/` | 🔌 pi provider `opencode-cli`: the shared text-tools provider pinned to the pure-LLM bridge on `:18386` |
| `.env.example` | ⚙️ Port, default model, guardrails toggle, timeouts |
| [`../common/`](../common) | 🧩 Shared: `extensions/text-tools-provider` (the provider itself), `extensions/guardrails` (optional approvals) |
| [`../opencode/`](../opencode) | 🍎 The **Hermes** flavour of the same backend (`:18484` + `:18385`, approvals on). Independent — run either or both |

---

## ✅ Prerequisites

| Need | Check |
|------|-------|
| Node.js 20+, pi ≥ 0.85 | `node --version`, `pi --version` (`npm install -g @earendil-works/pi-coding-agent`) |
| OpenCode CLI ≥ 1.14, logged in | `opencode --version`; `opencode models opencode` must list `opencode/*-free` |
| Python 3 (the bridge) and `jq` (for `install.sh` to edit pi's settings) | `python3 --version`, `brew install jq` |
| Free port **18386** | `lsof -nP -iTCP:18386 -sTCP:LISTEN` prints nothing |

The bridge runs as you and reuses the `opencode` CLI's own authentication — no extra login, no API key.

---

## 🚀 Quick start

```bash
cd ~/hermes-claude-code-bridge/pi-agents/macos/pi-opencode-cli && ./install.sh
```

Then, from any project:

```bash
pi --provider opencode-cli --model opencode/mimo-v2.5-free    # or just: ./run.sh pi
```

`/model` switches between the free models the bridge advertises (`./run.sh models`).

`install.sh` deliberately does **not** take over pi's default provider — this folder is meant to sit next to
`../claude-code/pi-cli`, and both providers can be registered in the same pi session. If you do want a bare `pi` to start here:

```bash
./install.sh --default
```

Headless, e.g. in a script:

```bash
echo "summarise the TODOs in this repo" | pi -p --no-session --provider opencode-cli
```

---

## 🧪 What `./install.sh` verifies

A headless pi run in a scratch directory where the free model has to **call** pi's `bash` tool (`pwd && echo …`) rather than
describe running it — i.e. the text-emulated tool protocol round-trips. Re-run it any time with `./run.sh test`.

---

## 🛡️ Optional approvals

Off by default. To get the Codex-style *approve once / this session / deny* prompt on risky calls:

```bash
PI_CLI_GUARDRAILS=1 ./run.sh pi
```

The policy is `../common/guardrails.json` (`profile: dangerous-only`, `mode: ask`); point `PI_GUARDRAILS_CONFIG` at
`../opencode/guardrails.json` or your own copy to change it. Decisions are appended to `~/.pi-bridge-audit.jsonl`. Headless
runs cannot prompt — `PI_APPROVAL_NONINTERACTIVE=allow|deny` decides (`run.sh test` sets `allow`).

---

## 💡 Notes

- **Free models are smaller models.** They follow the `<tool_call>` protocol well enough for everyday shell work, but expect
  more re-prompting than on Claude. `opencode/mimo-v2.5-free` has been the most reliable; `/model` to try the others.
- **Two ports, two purposes.** `:18386` is this folder's bridge; `:18385` is the Hermes stack's (`../opencode`). Separate
  launchd labels (`com.hermes.opencode-pi-cli` vs `com.hermes.opencode-pure-llm`), so installing one never disturbs the other.
- **Both terminal providers can coexist.** `opencode-cli` and `claude-code` register side by side in one pi session; switch
  with `--provider` or `/model`. (The shared provider resolves its id/URL per registration for exactly this reason.)
- **Model scope.** pi's `enabledModels` in `~/.pi/agent/settings.json` silently hides models outside it. `install.sh` adds
  every model the bridge advertises as `opencode-cli/<id>`; if you edit the scope by hand, keep those entries.
- No permission prompts, no subscription cost, and the model never executes anything itself — every command is pi's, in your
  cwd, under your user.

## 🩺 Troubleshooting

| Symptom | Fix |
|---------|-----|
| `No models matching "opencode-cli"` | Extension not registered — `./install.sh` (or use `./run.sh pi`, which passes `-e`) |
| `discovery … failed; using fallback list` | Bridge down: `./run.sh service-status`, `./run.sh logs`, or `./run.sh upstream` |
| pi starts on another model than you asked for | pi's model scope excludes ours — re-run `./install.sh`, or add `opencode-cli/opencode/mimo-v2.5-free` to `enabledModels` |
| The model *describes* a command but nothing runs | It didn't emit a `<tool_call>` block — re-prompt ("use your bash tool"), or switch model. If it happens for everything, check you are on `:18386` and not a tool-enabled OpenCode bridge |
| `opencode models opencode` lists nothing | OpenCode isn't logged in / offline — `opencode auth login` |
| Port 18386 busy | `UPSTREAM_PORT=… ` in `.env`, then `./run.sh install-service` again |
| Want the Hermes desktop instead of a terminal | [`../opencode`](../opencode) — same models, approvals in chat, endpoint `:18484` |
