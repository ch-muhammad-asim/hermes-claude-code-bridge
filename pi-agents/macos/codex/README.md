# 🧠 codex — run `pi` on the OpenAI Codex CLI

Terminal `pi`, with **pi's own tools in your own working directory**, driven by the `codex` CLI
as a plain language model.

```
pi (own tools, your cwd) ──▶ pure-LLM codex bridge :18288 ──▶ `codex exec --json` ──▶ gpt-5.6-sol
                             tool calls emulated over text by common/extensions/text-tools-provider
```

Sibling backends: [`../claude-code/pi-cli`](../claude-code/pi-cli) (NATIVE tool calling over MCP)
and [`../pi-opencode-cli`](../pi-opencode-cli) (same text-emulated shape as this one).

## Why a bridge at all

`codex` is an agent in its own right — it has its own shell and patch tools and its own sandbox.
That is exactly what we *don't* want here: pi must own the tool loop so that commands run in
**your** directory, under **pi's** approvals, with pi's session history. So the bridge runs codex
as a pure LLM:

- `--sandbox read-only` — codex cannot modify anything even if it tries
- a preamble telling codex that the *caller* executes tools, while still requiring it to emit the
  caller's `<tool_call>` format (see `PURE_LLM_PREAMBLE` in `codex_bridge.py`)
- `--ephemeral` — no codex session files accumulate; pi keeps the history

## Sandbox, approval and hook trust

Three independent axes. Conflating them is the usual source of confusion, because the desktop app
presents a single "how should actions be approved?" selector that spans two of them.

| Axis | Values (codex 0.155.x) | Flag / config key |
|---|---|---|
| **Sandbox** | `read-only`, `workspace-write`, `danger-full-access` | `-s/--sandbox`, `sandbox_mode` |
| **Approval** | `on-request`, `never` (`untrusted` is retired) | `-a/--ask-for-approval`, `approval_policy` |
| **Hook trust** | enforced / bypassed | `--dangerously-bypass-hook-trust` |

Presets combining the first two: `--approve-for-me` (workspace-write + automatic review) and
`--dangerously-bypass-approvals-and-sandbox` (no sandbox, no prompts). Precedence is CLI flag >
profile > config file. Desktop selector mapping: *Ask for approval* → `on-request`,
*Approve for me* → `--approve-for-me`, *Full access* → the bypass flag.

**What this bridge uses, and why:**

| Setting | Value | Rationale |
|---|---|---|
| sandbox | `read-only` | pi owns the tool loop; write access lands in a sandbox pi cannot see or use |
| approval | effectively `never` | `codex exec` is non-interactive — there is no human to prompt |
| hook trust | bypassed | otherwise every app/connector silently disappears (see below) |
| `--cd` | an **empty** directory | least privilege — see next paragraph |

**Point `CODEX_BRIDGE_CWD` at an empty directory.** It defaults to `$HOME`, which roots the
read-only sandbox at your home directory: codex can then *read* SSH keys, `.env` files and its own
`auth.json`, despite having no reason to read anything at all — pi does the file reading. Connectors
are network calls and do not touch the filesystem, so narrowing this costs nothing:

```bash
# in .env next to run.sh, then restart the service
CODEX_BRIDGE_CWD=$HOME/.local/share/pi-cli-codex/sandbox-root
```

Do not raise the sandbox to `workspace-write` or `danger-full-access` hoping to gain capability.
It grants nothing pi can use and widens blast radius; connectors work fine on `read-only`.

## Codex apps and MCP servers

Whatever codex is already connected to — Atlassian Rovo, Slack, documents, any `[mcp_servers.*]`
you add — is exposed to pi automatically. No per-server setup, no second sign-in: the bridge
inherits your existing `codex login`.

**This works only because the bridge passes `--dangerously-bypass-hook-trust`.** Codex apps and
plugins sit behind *persisted hook trust*, normally granted by an interactive prompt in the TUI.
`codex exec` has no prompt, so without the flag the whole apps layer silently disappears and the
model reports every connector as unavailable — which looks exactly like a bridge bug. The flag
skips the trust prompt only for hooks you already enabled in `~/.codex/config.toml`; the read-only
sandbox still constrains codex itself. Set `CODEX_BRIDGE_BYPASS_HOOK_TRUST=0` and the connectors
vanish again.

Two traps when checking what is reachable:

- **Asking the model to *list* its tools is unreliable.** With any system preamble in the prompt it
  tends to answer `NONE` while still calling those same tools happily. Test with a real call and
  its result, never an inventory question.
- **Exposed is not the same as linked.** A call can return `"error_code": "USER_NOT_LOGGED_IN"`,
  `"auth_reason": "missing_link"` — an account-level connector link that the bridge cannot fix.
  Link the app on the codex side, then retry.

## Prerequisites

| Needs | Checked by `install.sh` | Installed by `install.sh` |
|---|---|---|
| `python3` | ✅ | ❌ (stdlib only, any 3.9+) |
| Node.js 20+ | ✅ | ❌ |
| `pi` | ✅ | ✅ via npm |
| `codex` | ✅ | ❌ — `npm i -g @openai/codex` |
| `codex login` | ✅ warns if `~/.codex/auth.json` is missing | ❌ — interactive, do it yourself |
| `jq` | ✅ | ❌ — `brew install jq` |

## Install

```bash
cp .env.example .env          # optional: change the port or model
./install.sh                  # bridge as a service + register the provider with pi
./install.sh --default        # …and make a bare `pi` start on codex
./install.sh --no-service     # register only; you run ./run.sh upstream yourself
./install.sh --uninstall
```

Then, in any directory:

```bash
pi --provider codex-cli --model gpt-5.6-sol
```

## ⚠️ Do not install the service from a path under `~/Desktop`

launchd cannot execute scripts inside the TCC-protected `~/Desktop` tree: the service starts, dies
with `Operation not permitted` (exit 126) and then crash-loops under `KeepAlive`. An interactive
shell *can* run the same script, because it inherits the terminal's grant — which makes this look
like a file-permission bug when it is not.

If this clone lives under `~/Desktop`, either run the bridge in the foreground
(`./run.sh upstream`) or move the clone somewhere else (e.g. `~/hermes-claude-code-bridge`) and
re-run `./install.sh`, which also rewrites the extension path in `~/.pi/agent/settings.json`.

## Commands

```bash
./run.sh upstream          # foreground bridge on :18288
./run.sh pi [args…]        # pi on this provider, in the current directory
./run.sh test              # headless run: the model must CALL pi's bash tool
./run.sh models            # what /v1/models advertises
./run.sh install-service   # launchd (macOS) / systemd --user (Linux)
./run.sh uninstall-service | service-status | logs
```

## Configuration

Everything is env or `.env` next to `run.sh` — see [`.env.example`](.env.example). The ones that
matter most:

| Variable | Default | Notes |
|---|---|---|
| `UPSTREAM_PORT` | `18288` | **Re-run `install.sh` after changing** — the port is baked into the generated launchd runner |
| `PI_CLI_MODEL` | `gpt-5.6-sol` | passed to `codex exec --model` |
| `PI_CODEX_CLI_UPSTREAM` | `http://127.0.0.1:18288/v1` | read by the *extension*; must move together with `UPSTREAM_PORT` |
| `CODEX_BRIDGE_SANDBOX` | `read-only` | keep it — pi owns the tool loop |
| `CODEX_BRIDGE_TIMEOUT` | `600` | seconds per `codex exec` turn, then 504 |

`UPSTREAM_PORT` and `PI_CODEX_CLI_UPSTREAM` are **two different things** and must agree. Changing
only the first produces no error: the bridge moves, the health check passes, and pi keeps talking
to the old port. The startup banner names the port pi actually used — trust that, not the
installer's output.

## HTTP surface

| Route | Purpose |
|---|---|
| `GET /health` | `{status, version, model, in_flight, uptime_s}` |
| `GET /config` | effective configuration (`api_key` redacted to `"set"`) |
| `GET /v1/models` | advertised models |
| `POST /v1/chat/completions` | streaming (SSE) and non-streaming |

## Troubleshooting

### The model *describes* a command (```sh fence) instead of calling it — FIXED

Symptom: you ask pi to list a directory and the reply is a fenced `pwd && ls -la` suggestion; no
tool ever runs. **Not specific to this backend** — it hit every text-emulated provider,
`opencode-cli` included.

Cause: pi 0.86 changed the provider contract. Up to 0.85 a request carried `systemPrompt` and
`tools` as fields on `Context`; from 0.86 `normalizeContext()` folds both into the transcript's
**system messages** (`sections`, `toolsAdded`, `toolsRemoved`) and the provider receives a
`TranscriptContext` holding only `messages`. `text-tools-provider` still read `context.tools`,
got `undefined`, and injected no tool protocol — so the model was never told the format existed.

Fixed by `resolveContext()` in `../common/extensions/text-tools-provider/index.ts`, which reads
both shapes. **Extensions load at pi startup, so restart pi after pulling this.**

Confirming it works: watch the prompt size grow across turns in `./run.sh logs`. A working tool
loop looks like `chars=1677 → 3527 → 8003` — pi calls the tool, feeds the result back, the model
continues. A stuck one repeats the same size every turn.

Diagnosing a recurrence — `CODEX_BRIDGE_DUMP=<prefix>` writes one `<prefix>.N.json` per turn, the
exact request the client sent. If `tools` is absent there, the extension is at fault, not the
bridge. Leave it unset in normal use.

To check the model's side of the protocol independently of pi:

```bash
curl -s localhost:18288/v1/chat/completions -H 'content-type: application/json' -d '{
  "model":"gpt-5.6-sol",
  "messages":[{"role":"system","content":"When you need to run a command reply with ONLY:\n<tool_call>\n{\"name\":\"bash\",\"arguments\":{\"command\":\"<cmd>\"}}\n</tool_call>"},
              {"role":"user","content":"Run: echo TAGTEST"}]}' \
| python3 -c 'import sys,json;print(json.load(sys.stdin)["choices"][0]["message"]["content"])'
```

Expected — and confirmed on codex-cli 0.155.1 / gpt-5.6-sol:

```
<tool_call>
{"name": "bash", "arguments": {"command": "echo TAGTEST"}}
</tool_call>
```

Each turn is a full `codex exec` process, so this backend is markedly slower than `claude-code` —
expect tens of seconds per tool call, not the sub-second round trip of a native bridge.

### Other symptoms

| Symptom | Cause |
|---|---|
| `codex returned no agent message` | not logged in — run `codex login`; or the model name is not available to your plan |
| Model answers *"I can't run that, you told me not to use tools"* | the pure-LLM preamble is too strict for that model — loosen `PURE_LLM_PREAMBLE`, or run with `--no-pure-llm` |
| `bridge busy: N codex runs already active` | concurrency cap — raise `CODEX_BRIDGE_MAX_CONCURRENCY` |
| Service crash-loops with exit 126 | the `~/Desktop` / TCC trap above |
| Service crash-loops with `Errno 48` | another account or a leftover foreground bridge holds the port |
| pi registers the wrong port | `PI_CODEX_CLI_UPSTREAM` not exported in that shell — open a new terminal |
