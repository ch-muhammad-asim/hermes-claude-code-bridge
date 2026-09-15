# ⌨️ pi-cli — `pi` in your terminal, powered by Claude Code, all connectors, no guardrails

This is the **terminal-native** flavour of the Claude Code backend. You type `pi` in any directory and get the pi coding agent
with **its own tools** (`bash`, `read`, `write`, `edit`, `grep`, `find`, `ls`) executing directly — no approval prompts, no
policy — while the model behind it is the **Claude Code CLI** on your subscription (`claude-opus-5`, `claude-fable-5-1`,
`claude-sonnet-5`, …) with **every claude.ai connector** you have (Atlassian/Jira, Confluence, Slack, Gmail, Google Drive,
Calendar, …) available natively.

```
 you ──▶ pi (its own tools, no guardrails, your cwd) ──/v1/chat/completions + tools──▶ Claude Code NATIVE bridge :18187
                                                                                          one warm `claude` per conversation
                                                                                          pi's tools = real functions (MCP shim)
                                                                                          built-in tools OFF · ALL connectors ON
```

**Native means native:** pi's `bash`/`read`/`write`/`edit`/… are handed to Claude as real function definitions (through a tiny MCP
server the bridge gives to `claude`), Claude's calls come back as standard `tool_calls`, pi executes them, and the *same* `claude`
process continues — no text protocol, no per-turn process spawn.

Local work is pi's; SaaS look-ups and actions are Claude's connectors. Nothing is held for approval on this path — that is the
point of pi-cli. Want approvals and read-only connectors instead? Use the parent folder ([`../`](..)), which is the Hermes setup.

---

## 📦 What's in this folder

| Path | Purpose |
|------|---------|
| `install.sh` | 🧰 One shot: checks pi/claude, registers the bridge as an auto-start service, makes `claude-code`/`claude-opus-5` pi's default and puts the `claude-code/*` models into pi's `enabledModels` scope (settings backup first), smoke-tests |
| `run.sh` | ▶️ `upstream` (bridge in the foreground) · `pi [args]` (pi with this provider) · `test` · `models` · `install-service` · `uninstall-service` · `service-status` · `logs` |
| `tools/pi-sessions` · `tools/pi-session-rm` | 💾 List and delete pi sessions by id or name — pi ships neither. See [Sessions](#-sessions--name-resume-list-clean-up) |
| `extensions/claude-code/` | 🔌 pi provider `claude-code`: pi's stock OpenAI adapter pointed at the native bridge on `:18187` (via the shared provider in native mode) |
| `.env.example` | ⚙️ Port, default model, effort, per-turn budget |

---

## ✅ Prerequisites

`install.sh` **checks** every prerequisite before touching anything and stops with the exact message below if one is
missing. It installs only `pi`; everything else you provide. Nothing is half-configured on a failed run.

| Need | Check | If missing, `install.sh` … |
|------|-------|----------------------------|
| Python 3 (runs the bridge) | `python3 --version` | ✋ `python3 not found` |
| Node.js **20+** | `node --version` | ✋ `Node.js 20+ required` |
| pi ≥ 0.85 | `pi --version` | 🛠️ **installs it** (`npm install -g @earendil-works/pi-coding-agent`) |
| Claude Code CLI ≥ 2.1 | `claude --version` | ✋ `Claude Code CLI not found — install it and log in first` |
| A **working** `claude` login | see the probe below | ✋ `Claude Code login not working — run: claude login` |
| `jq` (only to edit pi's settings) | `jq --version` · `brew install jq` | ✋ `jq is required … or re-run with --no-default` |
| Free port **18187** | `lsof -nP -iTCP:18187 -sTCP:LISTEN` prints nothing | service fails to bind |
| claude.ai connectors (optional) | `claude mcp list` shows `✔ Connected` | connector answers are unavailable, local tools still work |

The login check is a real tool-less call, so an **expired** session fails the install rather than leaving you with a bridge
that 401s on first use. Run it yourself to confirm — it must print `pong`:

```bash
claude -p --tools "" --no-session-persistence --model haiku "Reply with exactly: pong"
```

No extra login: the bridge runs as you and reuses the `claude` CLI's authentication and connectors. There is no API key
anywhere in this setup — pi's built-in `anthropic` provider is deliberately disabled so requests go through Claude Code
(plan limits) instead of the third-party OAuth path (extra usage).

**Re-running is safe and is the normal repair path.** The settings edit is idempotent and a fresh backup of
`~/.pi/agent/settings.json` is written every time, so re-run after `claude login`, a pi upgrade, or a reboot that left the
service unhealthy.

On a clean Mac the whole sequence is:

```bash
brew install node jq                          # Node 20+ and jq
curl -fsSL https://claude.ai/install.sh | bash   # Claude Code (or: npm i -g @anthropic-ai/claude-code)
claude login
cd pi-agents/macos/claude-code/pi-cli && ./install.sh
```

---

## 🚀 Quick start

```bash
cd ~/hermes-claude-code-bridge/pi-agents/macos/claude-code/pi-cli && ./install.sh
```

Then, from any project:

```bash
pi
```

`/model` switches between `claude-opus-5`, `claude-fable-5-1`, `claude-fable-5`, `claude-opus-4-8`, `claude-sonnet-5`,
`claude-sonnet-4-6`, `claude-haiku-4-5`. Thinking depth is pi's `--thinking off|minimal|low|medium|high|xhigh|max` (forwarded to
`claude --effort`; default medium):

```bash
pi --thinking low
```

Prefer not to change pi's defaults? `./install.sh --no-default`, then start it explicitly (extra pi flags pass through):

```bash
cd ~/any/project && ~/hermes-claude-code-bridge/pi-agents/macos/claude-code/pi-cli/run.sh pi
```

Headless, e.g. in a script:

```bash
echo "summarise the failing pods in namespace prod" | pi -p --no-session
```

---

## 🧪 What `./install.sh` verifies

- pi runs a shell command itself (`pwd`) — native pi tool, no prompt.
- Claude answers a connector question (the Atlassian site it can access) inside the same reply.

Re-run the smoke test any time with `./run.sh test`; the models the bridge advertises with `./run.sh models`.

---

## 🔀 Running on a non-default port

Port `18187` is the default. You need a different one if something else already holds it — most often
**another user account on the same Mac** running this bridge, which `lsof` will *not* show you (it only lists sockets your
own user owns). Check with a bind test instead:

```bash
python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",18187));print("free")'
```

`Address already in use` means it is taken. `./run.sh logs` will show your service crash-looping on `OSError: [Errno 48]`.

Two variables must move **together** — they configure the two halves of the setup:

| Variable | Read by | Sets |
|----------|---------|------|
| `UPSTREAM_PORT` | `install.sh` / `run.sh` | the port the **bridge service** listens on |
| `PI_CLI_UPSTREAM` | the pi **extension** (`extensions/claude-code/index.ts`) | the full URL **pi connects to** |

Changing only `UPSTREAM_PORT` is the trap: the installer happily reports `(:18188)` and its health check passes, while pi keeps
registering models from `18187`. If another bridge is listening there you get **no error at all** — pi just silently uses the
wrong one. The startup banner is the tell:

```
[text-tools-provider] claude-code: registered 7 model(s) from http://127.0.0.1:18187/v1   ← still the old port
```

To move to `18188`, set both — the first for the service, the second permanently for every shell:

```bash
echo UPSTREAM_PORT=18188 > .env          # in this folder; install.sh sources it
echo 'export PI_CLI_UPSTREAM=http://127.0.0.1:18188/v1' >> ~/.zshrc
./install.sh                              # re-register the service on the new port
```

Open a new shell, then verify **both** halves:

```bash
curl -s http://127.0.0.1:18188/v1/models | python3 -m json.tool | head   # your bridge answers
pi                                                                       # banner must say :18188
```

---

## 💾 Sessions — name, resume, list, clean up

Every `pi` run is recorded as a JSONL transcript under `~/.pi/agent/sessions/<cwd-slug>/`. The directory name is derived from
the **working directory**, so sessions are per-project: resume from the same folder you started in.

**These are CLI flags, not slash commands.** `/session foo` at pi's prompt returns *"isn't available in this environment"* —
it is `pi --session foo` from your shell. Same for the rest:

| Flag | Does |
|------|------|
| `-n`, `--name <name>` | name the session (stored as a `session_info` line in the transcript) |
| `-c`, `--continue` | continue the most recent session in this directory |
| `-r`, `--resume` | interactive picker of this directory's sessions |
| `--session <path\|id>` | resume a specific session; a **partial UUID prefix is enough** |
| `--fork <id>` | branch a copy, leaving the original untouched |
| `--no-session` | ephemeral, nothing written |

```bash
pi -n pi-devops                 # start a named session
pi --session 01a0a326           # resume it later, partial id is fine
```

### Listing and deleting — `tools/`

pi has no non-interactive list and no delete command at all (`pi --resume` is a picker, `pi list` is for *extensions*), so this
folder ships two small helpers. **`./install.sh` puts both in `~/.local/bin`** (override with `PI_CLI_BIN_DIR`; a copy of your own
already on `PATH` is left untouched), so on an installed machine they just work. If you skipped the installer, or that directory is
not on your `PATH`:

```bash
cp tools/pi-sessions tools/pi-session-rm ~/.local/bin/ && chmod +x ~/.local/bin/pi-session*
```

`command not found` right after installing them means your shell cached the earlier lookup — `hash -r`, or open a new tab.

**`pi-sessions`** — every session with its id, name, size and project, newest first:

```console
$ pi-sessions
SESSION ID                             NAME         LINES   SIZE  MODIFIED     PROJECT
0199aaaa-1111-7000-8000-aaaaaaaaaaaa   infra-work     227   445K  15 Sep 10:26 …/projects/infra
0199bbbb-2222-7000-8000-bbbbbbbbbbbb   scratch         46   142K  14 Sep 08:39 …/projects/scratch
```

| | |
|---|---|
| `pi-sessions` | all sessions |
| `pi-sessions --named` | only named ones |
| `pi-sessions --here` | only the current directory's |
| `pi-sessions <filter>` | match on name, id or project |

The summary line goes to stderr, so `pi-sessions \| grep …` stays pipeable.

**`pi-session-rm`** — delete by id or name, with the guard rails a `rm` glob does not give you:

```console
$ pi-session-rm test-box --dry-run
Would delete 1 session(s):
  01a09dec-bb57-702b-9af3-1ce8b03ea158  test-box          46 lines  142K

$ pi-session-rm 01a0 --dry-run
'01a0' matches 2 sessions — be more specific:      ← ambiguous prefixes are refused, never guessed
```

| | |
|---|---|
| `pi-session-rm <id\|name>` | delete one, prompts for `yes` first |
| `pi-session-rm <id\|name> -f` | skip the prompt |
| `pi-session-rm --unnamed` | delete every session with no name |
| `pi-session-rm … --dry-run` | show what would go, delete nothing |

It prunes the project directories it empties. Deletion is permanent — there is no trash. Quit any pi still attached to a session
before removing its file.

Prefer `--unnamed` over filtering by file size: size correlates with importance only by accident, and a short named session is
exactly the one you do not want to lose.

### Doing it by hand

If you would rather not install the helpers, the same listing inline:

```bash
python3 -c "
import json,glob,os
for f in sorted(glob.glob(os.path.expanduser('~/.pi/agent/sessions/*/*.jsonl')), key=os.path.getmtime, reverse=True):
    sid=name=None; n=0
    for ln in open(f):
        n+=1
        try: e=json.loads(ln)
        except: continue
        if e.get('type')=='session': sid=e.get('id')
        if e.get('type')=='session_info' and e.get('name'): name=e['name']
    print(f\"{sid or '?':38} {(name or '—'):12} {n:5} lines {os.path.getsize(f)//1024:5}K\")"
```

> A pi session asked *'what sessions exist?'* will answer from its **own** `PI_SESSION_ID` env var and report that no other
> session is named anything — it does not read the other transcripts. Check the files, not the agent.

### Deleting

There is no delete command; sessions are plain files. Select by **name**, not by size — size only correlates with importance
by accident, and a short named session is exactly the one you do not want to lose:

```bash
python3 -c "
import json,glob,os
for f in glob.glob(os.path.expanduser('~/.pi/agent/sessions/*/*.jsonl')):
    named=any(json.loads(l).get('name') for l in open(f) if '\"session_info\"' in l)
    print(('KEEP  ' if named else 'DELETE'), os.path.basename(f))"
```

Swap the `print` for `os.remove(f)` in the unnamed branch once the dry run looks right, then prune the directories it empties:

```bash
find ~/.pi/agent/sessions -type d -empty -delete
```

Deletion is permanent — no trash. Quit any pi that is still attached to a session before removing its file.

---

## 💡 Notes

- **The status bar must read `(claude-code) claude-opus-5`.** The extension disables pi's built-in `anthropic` provider, because it
  serves the same model ids through pi's own OAuth, which Anthropic bills as third-party *extra usage* and refuses when none is
  available (`Third-party apps now draw from extra usage, not plan limits`). `PI_CLI_KEEP_ANTHROPIC=1` keeps it.
- pi's `enabledModels` (the model scope you see as "Model scope: …" at startup) silently hides models outside it — a bare `pi`
  then falls back to another enabled model. `install.sh` adds every `claude-code/*` model to that list and removes the `anthropic/`
  entries; if you edit the scope by hand keep `claude-code/…` in it.

- **Every claude.ai connector is enabled** with `bypassPermissions` on this bridge, including connectors that can write (create a Jira
  issue, send a Slack message, …). That is intentional for a personal terminal agent; it is *not* what the Hermes path does.
- pi has no permission prompts by design; combined with the above, treat a `pi` session like your own shell.
- One `claude` process per pi session: the first turn pays the start-up + connector handshake (~5 s), later turns ~1 s overhead.
  Idle sessions are reaped after 30 min (`CLAUDE_NATIVE_SESSION_IDLE`). `pi --thinking low` and `/model claude-sonnet-5` make
  individual answers snappier.
- Uses your Claude subscription (first-party CLI), not "extra usage"; `CLAUDE_CODE_MAX_BUDGET_USD` caps spend per claude call.
- The bridge service and the parent folder's Hermes services are independent — run either or both.

## 🩺 Troubleshooting

| Symptom | Fix |
|---------|-----|
| `No models matching "claude-code"` | Extension not registered — `./install.sh` (or `./run.sh pi`) |
| Status bar shows `(anthropic)` or `(openai-codex)` instead of `(claude-code)` | pi's model scope excludes our models — re-run `./install.sh`, or add `claude-code/claude-opus-5` to `enabledModels` in `~/.pi/agent/settings.json` |
| `discovery … failed; using fallback list` | Bridge down: `./run.sh service-status`, `./run.sh logs`, or `./run.sh upstream` |
| `Failed to authenticate` in `./run.sh logs` | `claude login`, then it recovers by itself |
| `OSError: [Errno 48] Address already in use` in `./run.sh logs`, service `spawn scheduled` / `last exit code = 1` | Another process — often **another user account** — holds the port. `lsof` won't show it; bind-test instead. See [Running on a non-default port](#-running-on-a-non-default-port) |
| Banner shows a different port than the one you installed on | `UPSTREAM_PORT` was changed without `PI_CLI_UPSTREAM` — pi is talking to another bridge. Set both, see [Running on a non-default port](#-running-on-a-non-default-port) |
| pi auto-compacts far too early (status bar `?/200k` on a 1M model) | The bridge must advertise `context_length` on `/v1/models`; check with `curl -s http://127.0.0.1:$PORT/v1/models`. `null` means the bridge serving that port is running pre-`MODEL_CONTEXT_WINDOWS` code — almost always a **service still running the old file** (next row), sometimes someone else's bridge (row above). After the port reports `1000000`, restart pi too: the provider extension registers `contextWindow` once, at startup, and falls back to `200_000` when `context_length` is absent |
| Edited `native/claude_native_bridge.py` (or pulled a newer one) and nothing changed | The launchd/systemd service loaded the module when it started and keeps serving the old code — an edit on disk is not picked up. Restart it: `launchctl kickstart -k "gui/$(id -u)/com.hermes.claude-code-pi-cli"` (Linux: `systemctl --user restart com.hermes.claude-code-pi-cli`), then confirm with `curl -s http://127.0.0.1:$PORT/v1/models` (`./run.sh models` prints ids only, so it looks healthy either way). `ps -o lstart= -p "$(lsof -tnP -iTCP:$PORT -sTCP:LISTEN)"` against the file's mtime tells you whether the process predates the change |
| `Third-party apps now draw from extra usage` | The bridge was started from inside a Claude Code / Agent SDK session — its env leaked in. `run.sh upstream` scrubs it now; `install-service` always runs clean |
| Connector "not available" | `claude mcp list` — the connector must be `✔ Connected` in the CLI; connect it at claude.ai → Settings → Connectors |
| Want approvals back | Use the parent folder's Hermes setup, or run pi with `-e ../../common/extensions/guardrails` |
| `/session <name> isn't available in this environment` | Sessions are CLI flags, not slash commands — `pi --session <id>` / `pi -n <name>`. See [Sessions](#-sessions--name-resume-list-clean-up) |
| A named session "doesn't exist" according to pi | pi reports on its *own* `PI_SESSION_ID`, not the other transcripts on disk — list the files instead. See [Sessions](#-sessions--name-resume-list-clean-up) |
