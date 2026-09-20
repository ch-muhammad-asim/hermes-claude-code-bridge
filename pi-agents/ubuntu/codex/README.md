# 🧠 codex — run `pi` on the OpenAI Codex CLI (Ubuntu)

Terminal `pi`, with **pi's own tools in your own working directory**, driven by the `codex` CLI
as a plain language model.

```
pi (own tools, your cwd) ──▶ pure-LLM codex bridge :18288 ──▶ `codex exec --json` ──▶ gpt-5.6-sol
                             tool calls emulated over text by common/extensions/text-tools-provider
```

Sibling backends: [`../claude-code/pi-cli`](../claude-code/pi-cli) (NATIVE tool calling over MCP)
and [`../opencode`](../opencode). The macOS twin is [`../../macos/codex`](../../macos/codex).

## What is Linux-specific here

The bridge itself is platform-neutral, so this folder **symlinks** it rather than forking it:

```
codex_bridge.py -> ../../macos/codex/codex_bridge.py
extensions      -> ../../macos/codex/extensions
```

Only the operational wrapper differs:

| | macOS | Ubuntu (here) |
|---|---|---|
| Service manager | launchd (`com.hermes.codex-pi-cli`) | **systemd --user** (`pi-cli-codex.service`) |
| Survives logout | n/a | needs **`loginctl enable-linger`** (install does it) |
| Logs | `~/.pi-cli-codex.log` | same, plus `journalctl --user -u pi-cli-codex` |
| Port holder lookup | `lsof` | `ss -ltnp`, falling back to `lsof` |
| Sandbox root default | `$HOME` unless set | `$XDG_DATA_HOME/pi-cli-codex/sandbox-root` |

Both `run.sh` and `install.sh` refuse to run on a non-Linux host, and `install.sh` refuses to run
as root — this is a per-user service that edits your own `~/.pi` settings.

## Why a bridge at all

`codex` is an agent in its own right — it has its own shell and patch tools and its own sandbox.
That is exactly what we *don't* want here: pi must own the tool loop so that commands run in
**your** directory, under **pi's** approvals, with pi's session history. So the bridge runs codex
as a pure LLM: a read-only sandbox rooted at an empty directory, `--ephemeral` so no codex session
files accumulate, and a preamble telling codex that the caller executes shell commands (see
`PURE_LLM_PREAMBLE` in the shared `codex_bridge.py`).

## Sandbox, approval and hook trust

Three independent axes. Conflating them is the usual source of confusion.

| Axis | Values (codex 0.155.x) | Flag / config key |
|---|---|---|
| **Sandbox** | `read-only`, `workspace-write`, `danger-full-access` | `-s/--sandbox`, `sandbox_mode` |
| **Approval** | `on-request`, `never` (`untrusted` is retired) | `-a/--ask-for-approval`, `approval_policy` |
| **Hook trust** | enforced / bypassed | `--dangerously-bypass-hook-trust` |

Presets combining the first two: `--approve-for-me` (workspace-write + automatic review) and
`--dangerously-bypass-approvals-and-sandbox` (no sandbox, no prompts). Precedence is CLI flag >
profile > config file.

What this bridge uses: sandbox `read-only`; approval effectively `never` (exec is non-interactive,
so there is no human to prompt); hook trust bypassed; `--cd` an empty directory.

Do not raise the sandbox hoping to gain capability — it grants nothing pi can use and widens blast
radius. Connectors work fine on `read-only`.

## Codex apps and MCP servers

Whatever codex is already connected to — Atlassian, Slack, documents, any `[mcp_servers.*]` you
add — is exposed to pi automatically. No per-server setup and no second sign-in: the bridge
inherits your existing `codex login`.

**This works only because the bridge passes `--dangerously-bypass-hook-trust`.** Codex apps and
plugins sit behind *persisted hook trust*, normally granted by an interactive prompt in the TUI.
`codex exec` has no prompt, so without the flag the whole apps layer silently disappears and the
model reports every connector as unavailable — which looks exactly like a bridge bug. The flag
skips the trust prompt only for hooks you already enabled in `$CODEX_HOME/config.toml`; the
read-only sandbox still constrains codex itself. `CODEX_BRIDGE_BYPASS_HOOK_TRUST=0` opts out.

Two traps when checking what is reachable:

- **Asking the model to *list* its tools is unreliable.** With any system preamble in the prompt it
  tends to answer `NONE` while still calling those same tools happily. Test with a real call and
  its result, never an inventory question.
- **Exposed is not the same as linked.** A call can return `"error_code": "USER_NOT_LOGGED_IN"`,
  `"auth_reason": "missing_link"` — an account-level connector link the bridge cannot fix. Some
  connectors also ship a deprecated `*_legacy` tool variant that is *not* linked; if a call fails,
  retry with the non-legacy name before assuming the connector is broken.

## Prerequisites

| Needs | Checked by `install.sh` | Installed by `install.sh` |
|---|---|---|
| `python3` | ✅ | ❌ — `sudo apt install -y python3` |
| Node.js 20+ | ✅ | ❌ |
| `jq` | ✅ | ✅ via apt |
| `pi` | ✅ | ✅ via npm |
| `codex` | ✅ | ❌ — `npm i -g @openai/codex` |
| `codex login` | ✅ warns if `auth.json` is missing | ❌ — interactive, do it yourself |
| systemd user session | — | linger enabled automatically (warns if it cannot) |

## Install

```bash
cp .env.example .env          # optional: change the port or model
./install.sh                  # bridge as a systemd --user service + register the provider
./install.sh --default        # …and make a bare `pi` start on codex
./install.sh --no-service     # register only; you run ./run.sh upstream yourself
./install.sh --uninstall
```

Then, in any directory:

```bash
pi --provider codex-cli --model gpt-5.6-sol
```

## Commands

```bash
./run.sh upstream          # foreground bridge on :18288
./run.sh pi [args…]        # pi on this provider, in the current directory
./run.sh test              # headless run (see the caveat below)
./run.sh models            # what /v1/models advertises
./run.sh install-service   # systemd --user unit + enable + linger
./run.sh uninstall-service | service-status | restart | logs | journal
```

## Configuration

Everything is env or `.env` next to `run.sh` — see [`.env.example`](.env.example).

| Variable | Default | Notes |
|---|---|---|
| `UPSTREAM_PORT` | `18288` | **Re-run `install.sh` after changing** — it is baked into the generated runner |
| `PI_CLI_MODEL` | `gpt-5.6-sol` | passed to `codex exec --model` |
| `PI_CODEX_CLI_UPSTREAM` | `http://127.0.0.1:18288/v1` | read by the *extension*; must move together with `UPSTREAM_PORT` |
| `CODEX_BRIDGE_CWD` | `…/pi-cli-codex/sandbox-root` | keep it an empty directory |
| `CODEX_BRIDGE_SANDBOX` | `read-only` | keep it |
| `CODEX_BRIDGE_TIMEOUT` | `600` | seconds per turn, then 504 |

`UPSTREAM_PORT` and `PI_CODEX_CLI_UPSTREAM` are **two different things** and must agree. Changing
only the first produces no error: the bridge moves, the health check passes, and pi keeps talking
to the old port. The pi startup banner names the port actually used — trust that, not the
installer's output.

## Models in pi's picker

The bridge discovers every model codex itself offers from `$CODEX_HOME/models_cache.json`,
filtering on the same `visibility` field codex uses (`list` = offered, `hide` = internal).

If pi's `/model` picker is missing models, check `enabledModels` in `~/.pi/agent/settings.json`.
That field is pi's model **scope**: when present, anything outside it is ignored. Use exact
`provider/id` references rather than globs — a single `*` does not match across a `/`, and some
providers have ids that already contain one, so a pattern like `opencode-cli/*` silently drops
every model.

## HTTP surface

| Route | Purpose |
|---|---|
| `GET /health` | `{status, version, model, in_flight, uptime_s}` |
| `GET /config` | effective configuration (`api_key` redacted to `"set"`) |
| `GET /v1/models` | discovered models, with `context_length` |
| `POST /v1/chat/completions` | streaming (SSE) and non-streaming |

## Troubleshooting

### `./run.sh test` shows the model *describing* a command instead of calling it

Known pi 0.86.x behaviour, **not specific to this backend**. In headless `-p` mode pi hands a
`streamSimple` provider a bare user message: `context.systemPrompt` and `context.tools` are both
empty, so the shared provider has no tool schemas to inject and the model has no `<tool_call>`
protocol to follow. Use the interactive TUI (`./run.sh pi`) to judge tool calling.

`CODEX_BRIDGE_DUMP=<prefix>` writes one `<prefix>.N.json` per turn — the exact request the client
sent. Leave it unset in normal use.

### Other symptoms

| Symptom | Cause |
|---|---|
| `codex returned no agent message` | not logged in — `codex login`; or the model is not available to your plan |
| Service dies when you log out of ssh | linger not enabled — `sudo loginctl enable-linger $USER` |
| Service crash-loops with `Errno 48` | another process holds the port — `ss -ltnp 'sport = :18288'` |
| `bridge busy: N codex runs already active` | concurrency cap — raise `CODEX_BRIDGE_MAX_CONCURRENCY` |
| pi registers the wrong port | `PI_CODEX_CLI_UPSTREAM` not exported in that shell — open a new terminal |
| pi starts on a built-in provider | the extension unregisters `openai-codex`, but scope is what really gates the picker — see "Models in pi's picker" |
