# 🐧 pi-agents on Ubuntu — persistent `systemd --user` endpoints

The Ubuntu/Linux port of [`../macos/`](../macos). Same architecture, same ports, same guardrails;
the difference is the **service layer**: hardened `systemd --user` units with `loginctl enable-linger`,
so the endpoints are listening again after a reboot without anyone logging in.

| Folder | Model backend | Endpoint (Hermes) | Upstream | systemd units (`--user`) |
|--------|---------------|-------------------|----------|--------------------------|
| [`claude-code/`](claude-code) | **Claude Code CLI, native tool calling** (MCP shim, one warm `claude` per conversation), built-ins off (WebSearch/WebFetch stay on — pi has none; `PI_CLAUDE_WEB=0` disables) + read-only claude.ai connectors on | `http://127.0.0.1:18485/v1` | `:18186` | `pi-bridge-claude-code`, `pi-upstream-claude-code` |
| [`opencode/`](opencode) | OpenCode **free** models via the pure-LLM OpenCode Bridge | `http://127.0.0.1:18484/v1` | `:18385` | `pi-bridge-opencode`, `pi-upstream-opencode` |
| [`claude-code/pi-cli/`](claude-code/pi-cli) | Terminal-native `pi` on Claude Code — pi's own tools as real function calls, **all** claude.ai connectors, no guardrails | — (terminal) | `:18187` | `pi-cli-claude-code` |
| [`common/`](common) | Ubuntu launcher + apt-aware installer; the OS-agnostic code is symlinked to `../macos/common/` | | | |

Ports match `../macos/`, so a Hermes endpoint configured against either tree needs no change.

## 🔌 Endpoint reference

Five HTTP servers, all bound to **`127.0.0.1` only** (loopback — nothing is reachable from the
network). Point Hermes at the **pi bridge** ports; the upstream ports are the model backends and are
mainly useful for debugging — calling them directly bypasses pi, its tools and the guardrails.

| Port | Service | systemd unit (`--user`) | Role |
|------|---------|--------------------------|------|
| **18485** | pi bridge — claude-code | `pi-bridge-claude-code` | 👉 **Hermes endpoint.** pi + tools + approvals |
| 18186 | native Claude Code bridge | `pi-upstream-claude-code` | model only, via warm `claude` + MCP shim |
| **18484** | pi bridge — opencode | `pi-bridge-opencode` | 👉 **Hermes endpoint.** pi + tools + approvals |
| 18385 | pure-LLM OpenCode bridge | `pi-upstream-opencode` | model only, via `opencode run` |
| 18187 | native Claude Code bridge — **terminal `pi`** | `pi-cli-claude-code` | what a bare `pi` talks to ([pi-cli](claude-code/pi-cli)); all connectors, no guardrails |

### Routes

All five servers speak the same OpenAI-compatible surface, with one exception noted below.

| Method + path | 18485 | 18186 | 18484 | 18385 | 18187 | Returns |
|---|:--:|:--:|:--:|:--:|:--:|---|
| `GET /health` | ✅ | ✅ | ✅ | ✅ | ✅ | liveness + version, model, in-flight count |
| `GET /metrics` | ✅ | ✅ | ✅ | ✅ | ✅ | uptime, requests, errors (18385 adds cost/token totals) |
| `GET /config` | ✅ | ✅ | ✅ | ✅ | ✅ | effective config — binary paths, cwd, model list, approval mode |
| `GET /v1/models` | ✅ | ✅ | ✅ | ✅ | ✅ | OpenAI model list |
| `GET /v1/models/{id}` | ✅ | ✅ | ✅ | ✅ | ✅ | one model object |
| `POST /v1/models/refresh` | ✅ | ❌ | ✅ | ✅ | ❌ | re-discover the catalogue now |
| `POST /v1/chat/completions` | ✅ | ✅ | ✅ | ✅ | ✅ | completion; `"stream": true` → SSE |

`POST /v1/models/refresh` returns `404` on **18186** and **18187** — both are the native Claude bridge,
which has a fixed model list (`CLAUDE_CODE_BRIDGE_MODELS`), so there is nothing to re-discover. Any
other path returns `404 {"error":{"message":"not found"}}`; with `PI_BRIDGE_API_KEY` set, a missing or
wrong `Authorization: Bearer …` returns `401`.

### Every URL, copy-paste

```
# pi bridge — claude-code   (Hermes: http://127.0.0.1:18485/v1)
http://127.0.0.1:18485/health
http://127.0.0.1:18485/metrics
http://127.0.0.1:18485/config
http://127.0.0.1:18485/v1/models
http://127.0.0.1:18485/v1/models/claude-opus-5
http://127.0.0.1:18485/v1/models/refresh          POST
http://127.0.0.1:18485/v1/chat/completions        POST

# native Claude Code bridge (upstream of 18485)
http://127.0.0.1:18186/health
http://127.0.0.1:18186/metrics
http://127.0.0.1:18186/config
http://127.0.0.1:18186/v1/models
http://127.0.0.1:18186/v1/models/claude-opus-5
http://127.0.0.1:18186/v1/chat/completions        POST

# pi bridge — opencode      (Hermes: http://127.0.0.1:18484/v1)
http://127.0.0.1:18484/health
http://127.0.0.1:18484/metrics
http://127.0.0.1:18484/config
http://127.0.0.1:18484/v1/models
http://127.0.0.1:18484/v1/models/opencode/big-pickle
http://127.0.0.1:18484/v1/models/refresh          POST
http://127.0.0.1:18484/v1/chat/completions        POST

# pure-LLM OpenCode bridge (upstream of 18484)
http://127.0.0.1:18385/health
http://127.0.0.1:18385/metrics
http://127.0.0.1:18385/config
http://127.0.0.1:18385/v1/models
http://127.0.0.1:18385/v1/models/opencode/big-pickle
http://127.0.0.1:18385/v1/models/refresh          POST
http://127.0.0.1:18385/v1/chat/completions        POST

# pi-cli bridge — what a bare `pi` in your terminal talks to
http://127.0.0.1:18187/health
http://127.0.0.1:18187/metrics
http://127.0.0.1:18187/config
http://127.0.0.1:18187/v1/models
http://127.0.0.1:18187/v1/models/claude-opus-5
http://127.0.0.1:18187/v1/chat/completions        POST
```

### Smoke-test all five at once

```bash
for p in 18485 18186 18484 18385 18187; do printf '%s %s\n' "$p" "$(curl -fsS -m 5 http://127.0.0.1:$p/health || echo DOWN)"; done
```

List the models each one advertises:

```bash
for p in 18485 18186 18484 18385 18187; do echo "== $p =="; curl -fsS http://127.0.0.1:$p/v1/models | python3 -c 'import json,sys;[print(" ",m["id"]) for m in json.load(sys.stdin)["data"]]'; done
```

A completion through the Hermes endpoint (pi runs the tools, guardrails apply):

```bash
curl -sS http://127.0.0.1:18485/v1/chat/completions -H 'content-type: application/json' -d '{"model":"claude-opus-5","messages":[{"role":"user","content":"Run: uname -sr ; then reply with just that output."}]}'
```

The same prompt against the upstream **bypasses pi, the tools and the guardrails** — model text only:

```bash
curl -sS http://127.0.0.1:18186/v1/chat/completions -H 'content-type: application/json' -d '{"model":"claude-opus-5","messages":[{"role":"user","content":"say pong"}]}'
```

> Sample responses, taken from this machine:
> ```
> :18485/health  {"status":"ok","version":"1.0.0","pi_version":"0.85.1","upstream":"http://127.0.0.1:18186/v1","model":"claude-opus-5","approval":"ask","in_flight":0}
> :18186/health  {"status":"ok","version":"1.0.0","native_tools":true,"model":"claude-opus-5","sessions":1}
> :18484/health  {"status":"ok","version":"1.0.0","pi_version":"0.85.1","upstream":"http://127.0.0.1:18385/v1","model":"opencode/mimo-v2.5-free","approval":"ask","in_flight":0}
> :18385/health  {"status":"ok","version":"1.0.0","opencode_version":"1.14.48","in_flight":0,"model":"opencode/mimo-v2.5-free"}
> :18187/health  {"status":"ok","version":"1.0.0","native_tools":true,"model":"claude-opus-5","sessions":0}
> ```

### Changing a port

Set `BRIDGE_PORT` / `UPSTREAM_PORT` in the backend's `.env`, then re-run
`./run-bridge.sh install-service` — the ports are baked into the generated unit runners, so a plain
restart will not pick them up. Update the Hermes endpoint URL to match.

## ⌨️ Terminal `pi` — fixing "No models available"

A freshly installed `pi` has **no provider configured**, so running it bare fails with:

```
Error: No API key found for the selected model.
Warning: No models available. Use /login to log into a provider via OAuth or API key.
```

Do **not** use pi's `/login`: pi's own Anthropic OAuth is billed by Anthropic as third-party
*"extra usage"*, not against your Claude plan. Install [`claude-code/pi-cli/`](claude-code/pi-cli)
instead — it registers a `claude-code` provider in `~/.pi/agent/settings.json` pointing at a local
Claude Code bridge on `:18187`, so `pi` uses your normal Claude subscription:

```bash
cd pi-agents/ubuntu/claude-code/pi-cli && ./install.sh
```

That does five things: verifies `pi` / `claude` and the Claude login, registers the `:18187` bridge as
an enabled `systemd --user` service with linger, installs `pi-sessions` / `pi-session-rm` into
`~/.local/bin`, writes the provider + defaults into `~/.pi/agent/settings.json` (**backing the file up
first**), and runs a headless smoke test. Afterwards, in any directory:

```bash
pi
```

`/model` switches between `claude-opus-5`, `claude-fable-5-1`, `claude-sonnet-5` and the rest.

Two details worth knowing:

- **The built-in `anthropic` provider is unregistered.** It serves the same model ids, and with both
  present a bare `pi` resolved them to the built-in one — i.e. back to extra-usage billing. Set
  `PI_CLI_KEEP_ANTHROPIC=1` to keep it, then always pass `--provider claude-code`.
- **No guardrails on this path, and every connector is on.** This is your own terminal, so pi's tools
  run directly — unlike the Hermes endpoints (`:18485` / `:18484`), where the guardrails hold `rm -rf`
  and friends for approval and connectors are restricted to a read-only allowlist. Use
  `./install.sh --no-default` and `./run.sh pi` if you would rather not make it pi's global default.

```bash
./run.sh service-status | logs | journal | restart | test | models
./install.sh --uninstall     # removes the service, the tools and the settings entries
```

## 📦 What is actually in `common/`

Only three files in `common/` are Ubuntu-specific (plus each backend's `run-bridge.sh` / `install.sh`). Everything else is a **symlink into `../macos/`**, so the bridge,
the provider extension and the guardrail policy stay single-source — fix a bug once, both OSes get it.

```
common/launcher.sh      real file — systemd-only service layer (see below)
common/install-lib.sh   real file — apt / NodeSource / npm-prefix bootstrap
common/guardrails.json  real file — Linux path roots (no /private/tmp; adds /var/tmp, /srv)
common/pi_bridge.py  →  ../../macos/common/pi_bridge.py
common/extensions    →  ../../macos/common/extensions      (text-tools-provider, guardrails)
common/prompts       →  ../../macos/common/prompts         (sre.md)
claude-code/native   →  ../../macos/claude-code/native     (claude_native_bridge.py, mcp_shim.py)
claude-code/prompts  →  ../../macos/claude-code/prompts    (connectors.md)
opencode/opencode    →  ../../macos/opencode/opencode      (pure-llm.json, plugins)
claude-code/pi-cli/extensions → ../../../macos/claude-code/pi-cli/extensions   (claude-code provider)
claude-code/pi-cli/tools      → ../../../macos/claude-code/pi-cli/tools        (pi-sessions, pi-session-rm)
```

`pi_bridge.py` resolves its extensions with `os.path.abspath(__file__)`, which does **not** follow
symlinks — so it finds `ubuntu/common/extensions`, not the macOS copy. Clone with symlinks intact
(a plain `git clone` does this; a zip export does not).

## ✅ Prerequisites

Ubuntu 20.04+ with systemd, and a **normal user session** (the installer refuses to run as root —
these are per-user services that need your Claude / OpenCode logins). Everything else the installer
puts in place: `python3`, `curl`, `iproute2`, Node.js 20+ (NodeSource if the distro's is too old),
`pi`, and the backend CLI. `sudo` is used only for the apt steps, and only when a package is missing.

If npm's global prefix is not writable it switches you to `~/.npm-global` rather than running npm as
root, and tells you the `PATH` line to add to your shell rc.

## 🚀 Install

```bash
cd pi-agents/ubuntu/claude-code && ./install.sh
```

```bash
cd pi-agents/ubuntu/opencode && ./install.sh
```

Each run installs missing dependencies, verifies the backend login, runs the offline self-checks,
writes both units, enables them, turns on linger, waits for `/health` and then fires a live test —
one everyday call (runs) and one `rm -rf` (held for approval).

Then in Hermes → **Settings → Providers → Custom Endpoints → New endpoint**:

| | claude-code | opencode |
|---|---|---|
| Endpoint URL | `http://127.0.0.1:18485/v1` | `http://127.0.0.1:18484/v1` |
| Default Model | `claude-opus-5` | `opencode/mimo-v2.5-free` |

Discover models ☑ → Test → Save → Use. Both can be registered side by side.

## 🖥️ Operating

```bash
./run-bridge.sh service-status   # both units, enabled-at-boot, linger, live /health
./run-bridge.sh restart          # restart both, then re-check health
./run-bridge.sh logs             # tail ~/.pi-bridge-<backend>.log + ~/.pi-upstream-<backend>.log
./run-bridge.sh journal          # journalctl --user -f for both units
./run-bridge.sh test             # safe call + held call
./run-bridge.sh approve          # replay the held call with "approve"
./run-bridge.sh models           # what the endpoint advertises
./install.sh --uninstall         # remove both units (linger is left alone)
```

Foreground (no services) for debugging — two terminals:

```bash
./run-bridge.sh upstream   # pure-LLM upstream bridge
./run-bridge.sh            # pi bridge
```

## 🔁 Why it survives a reboot

- **`WantedBy=default.target` + `systemctl --user enable`** — both units start with your user manager.
- **`loginctl enable-linger $USER`** — the user manager itself starts at **boot**, not at login, and is
  not torn down when you log out. Without linger the endpoints would only exist while you had a
  graphical session open. `install-service` enables it and prints the `sudo` fallback if it cannot.
- **`Restart=always`, `RestartSec=3`**, with `StartLimitBurst=10 / StartLimitIntervalSec=300` so a
  genuinely broken config fails visibly instead of looping forever.
- **Ordering** — the pi bridge unit carries `Wants=`/`After=` its upstream unit, and both wait on
  `network-online.target`.
- **Baked-in environment** — a unit started at boot has almost no environment and none of your shell's
  `PATH`. `install-service` generates `~/.local/share/pi-bridge-<backend>/run-*.sh` with an absolute
  `PATH` (`~/.local/bin`, the npm global bin, `~/.opencode/bin`) and every `PI_*` value exported
  explicitly. **Re-run `./run-bridge.sh install-service` after changing `.env`** — the runners are a
  snapshot, not a live read.
- **Stray-port cleanup** — `install-service` finds a leftover foreground copy with `ss` (falling back to
  `lsof`) and stops it, so the unit does not crash-loop on "address in use".

Verify without rebooting:

```bash
systemctl --user is-enabled pi-bridge-claude-code.service   # enabled
loginctl show-user "$USER" -p Linger                        # Linger=yes
systemctl --user stop pi-bridge-claude-code pi-upstream-claude-code
systemctl --user start default.target                       # what boot does
curl -fsS http://127.0.0.1:18485/health
```

### Claude Code credentials at boot

The upstream unit starts before you unlock a desktop session, so Claude Code's token must be on disk
at `~/.claude/.credentials.json`. If the token lives in the GNOME keyring instead, the unit cannot
read it until you log in — `install.sh` warns when that file is missing. Check after a reboot with
`systemctl --user status pi-upstream-claude-code.service`.

## 🛡️ Guardrails

Identical engine and profiles to macOS (`../macos/README.md` has the full description). The only
Ubuntu change is `paths.allowed_roots` in each `guardrails.json`: `/private/tmp` (a macOS path) is
dropped, `/var/tmp` and `/srv` are added. Mode stays `ask`, profile stays `dangerous-only`, and the
audit trail is still `~/.pi-bridge-audit.jsonl`.

## 🩺 Troubleshooting

| Symptom | Check |
|---|---|
| Endpoint gone after reboot | `loginctl show-user "$USER" -p Linger` → `Linger=yes`; else `sudo loginctl enable-linger $USER` |
| Unit flapping | `./run-bridge.sh journal`; `systemctl --user status <unit>` |
| `address already in use` | a foreground copy is running — `./run-bridge.sh install-service` clears it |
| `pi: command not found` in the unit | re-run `./run-bridge.sh install-service` (it re-bakes the absolute `PATH`) |
| `.env` change had no effect | re-run `./run-bridge.sh install-service` |
| Edited `run-bridge.sh` / `pi-cli/run.sh` but behaviour is unchanged | that unit is still running the old code — `./run-bridge.sh restart` (or `pi-cli/run.sh restart`). Each backend restarts only **its own** units, so an edit touching both trees needs both restarted |
| Claude answers "authenticate" | `claude login`, then `./run-bridge.sh restart` |
| Broken symlink errors | clone the repo with git (symlinks), not as a zip |
| `pi` says "No models available" | run `claude-code/pi-cli/install.sh` — see [Terminal `pi`](#️-terminal-pi--fixing-no-models-available). Do **not** use pi's `/login` |
| `pi` works but bills as "extra usage" | the built-in `anthropic` provider is back — re-run the pi-cli installer, or unset `PI_CLI_KEEP_ANTHROPIC` |

### Known issue: OpenCode free tier cannot run tool turns

Two separate faults were found here, one fixed and one structural.

**Fixed — silent empty replies.** The `opencode` CLI was on 1.14.48, whose session DB had
`session_message.seq` as `NOT NULL` with no default; every message insert failed with
`SQLiteError: NOT NULL constraint failed`, so runs produced nothing at all. Upgrading the CLI
(now 1.18.31) fixed it: `curl -fsSL https://opencode.ai/install | bash`.

**Structural — the free tier forbids disabling tools.** `opencode/pure-llm.json` used to set every
tool permission to `deny`, so OpenCode ran no tools and pi did them under the guardrails. The free
tier now rejects that outright:

```
FreeTierError: Error from provider (Console): OpenCode's free tier can only be used from within OpenCode
```

Denying **any single** permission triggers it (`{"permission":{"bash":"deny"}}` is enough), and the
separate `tools` key (`{"tools":{"*":false}}`) triggers it too — there is no mechanism left to turn
OpenCode's own tools off on the free tier. `allow` and `ask` are both accepted, and the two
non-model guards `external_directory` / `doom_loop` may stay `deny` because the free tier does not
count them as tools.

`pure-llm.json` is therefore now an **allow** config (bash and websearch included). The consequence:

| Through `:18484` | Result |
|---|---|
| Plain chat | ✅ works |
| Any turn where pi offers its tools | ❌ `[400] tool_calls[0].id must be a non-empty string` |

With OpenCode's agent forced on, pi's tool-emulation prompt makes OpenCode emit a tool call it
serializes with an empty id, which OpenCode Zen rejects. The same prompt sent straight to
`opencode run` works, so this is the two agents colliding, not a model fault.

**Options:** use this backend for plain chat only; use the `claude-code/` backend for tool work (it
is unaffected and verified end to end); or point the backend at a **paid, API-key** OpenCode provider
rather than the free tier, which allows `deny` again and restores the original pure-LLM design.

Despite the name, `pure-llm.json` no longer denies anything — the filename is kept because both
trees' `run-bridge.sh` reference it as `PURE_LLM_CONFIG`.

