# docker-bridge

An OpenAI-compatible HTTP facade over the **Claude Code CLI**, packaged as a single container.
Exposes `POST /v1/chat/completions` and `GET /v1/models` on `127.0.0.1:18181`, allowing any
OpenAI-API client to use Claude Code as its inference backend.

**Default model:** `claude-opus-5`. **`claude-fable-5` is available as an opt-in alternative**,
selectable per request; it is never the default.

Validated against Docker 29.4.0 (OrbStack) with Claude Code 2.1.220 on macOS 25.5.0.

---

## Contents

| Path | Role |
|------|------|
| `docker-compose.yml` | Service definitions: a one-shot credential seed plus the long-running bridge |
| `Dockerfile` | `node:22-bookworm-slim`, Claude Code CLI, Python bridge; non-root runtime |
| `docker-entrypoint.sh` | Derives the bridge invocation from environment; applies defaults |
| `healthcheck.sh` | Bearer-aware `/health` probe used by `HEALTHCHECK` |
| `claude_code_bridge.py` | The bridge implementation |
| `env.example` | Documented environment contract; source for `.env` |
| `generate-secrets.sh` | Creates `.env` and edits settings in place; see [Configuring](#configuring-with-generate-secretssh) |

---

## Architecture

```
OpenAI-API client            tools, if any, are executed BY THE CLIENT
      │  Bearer CLAUDE_CODE_PROXY_API_KEY (optional)          (see Tool calling)
      ▼
127.0.0.1:18181 ──► claude-code-bridge   (runs as your HOST uid)
                         │  subprocess: claude -p --output-format stream-json
                         ▼
                    Claude Code CLI ──► Anthropic API
                         │            + ~30 built-in tools (Read, Bash, …) in-container
                         ▼            NO MCP / claude.ai connectors — print mode loads none
                    $HOME/.claude   ── bind-mounted read-write ──► host
```

One service. The container **bind-mounts your real `$HOME/.claude`** rather than copying into a
named volume, so it is the same Claude Code installation your host uses: same credentials, same
settings, same skills. There is no separate container-side session to seed, expire, or lose.

Note what the bind mount does **not** buy you: claude.ai connectors. `claude -p` activates no MCP
servers at all, so none of them are reachable through the bridge — see
[Tool calling](#tool-calling-what-this-bridge-does-and-does-not-do).

Two consequences worth understanding before you deploy:

- **It runs as your host uid** (`HOST_UID`/`HOST_GID`, filled in by `generate-secrets.sh`). The CLI
  must *write* to `~/.claude` to refresh its own token; a uid mismatch makes that fail.
- **`docker compose down -v` no longer destroys your login.** Only the `workspace` volume is named;
  credentials live on the host.

### Why not `CLAUDE_CODE_OAUTH_TOKEN`

A `claude setup-token` credential authenticates completions but **exposes no claude.ai connectors** —
`claude mcp list` inside the container returns `No MCP servers configured`. Connectors are attached
to the account session and require a full `.credentials.json`, which is precisely what the bind
mount provides:

```
claude.ai Slack: https://mcp.slack.com/mcp - ✔ Connected
claude.ai Google Drive: https://drivemcp.googleapis.com/mcp/v1 - ✔ Connected
```

Use the token only where there is no host login to share — CI, a headless VM.

---

## Prerequisites

- Docker Engine with Compose v2 and BuildKit enabled (`DOCKER_BUILDKIT=1`).
- **Claude Code logged in on this host.** The container bind-mounts `$HOME/.claude` and shares that
  session; `generate-secrets.sh` keeps the credential file current. Without a host login, see
  [CI and headless hosts](#ci-and-headless-hosts).
- TCP `18181` free on the loopback interface. Verify before deploying — a pre-existing listener
  will silently shadow the container's port mapping, and Docker reports the mapping anyway. See
  [Port already bound](#symptom-responses-do-not-match-this-container).

---

## Deployment

```bash
cd docker-bridge

./generate-secrets.sh                 # writes .env; adopts an active host login if it finds one
docker compose up -d --build          # initial build ~2-4 min (npm install)
docker compose ps                     # await claude-code-bridge -> healthy
```

That is the secure default: a **bearer token is required**, and only read-only tools are available.

For a **live demo** — callable from a browser, every tool enabled:

```bash
./generate-secrets.sh --all-tools --allow-anonymous && docker compose up -d
```

Re-run that any time to return to a known-good demo state; it is safe on an existing stack.

### Pick the setup that matches how you will use it

| Situation | Command |
|-----------|---------|
| Secure default | `./generate-secrets.sh` |
| **Live demo** — browser-callable, every built-in tool enabled | `./generate-secrets.sh --all-tools --allow-anonymous` |
| Agent must run commands and edit files | `./generate-secrets.sh --all-tools` |
| Undo any relaxation | `./generate-secrets.sh --secure` |
| No host login (CI, headless VM) | `./generate-secrets.sh --setup-token` |

Every row survives `docker compose down -v`: credentials live in your bind-mounted `$HOME/.claude`,
not in a Docker volume.

Full reference: [Configuring with `generate-secrets.sh`](#configuring-with-generate-secretssh).

Two defaults commonly surprise people, and they are independent:

- **A browser cannot call the bridge.** It cannot send an `Authorization` header, so
  `http://localhost:18181/v1/models` returns `{"error": {"message": "unauthorized"}}`. That is
  correct. Use `curl -H "Authorization: Bearer …"`, or `--allow-anonymous`.
- **`/v1/models` working does not mean completions work.** It is served by the bridge process and
  answers regardless of whether Claude Code is authenticated. Only a completion proves the session.

### Verify the credential before calling it done

```bash
docker compose logs claude-code-bridge | grep -o 'claude_auth=.*'
```

```
claude_auth=oauth-token (CLAUDE_CODE_OAUTH_TOKEN)     # durable; survives docker compose down -v
claude_auth=credentials file                          # bind-mounted host login
claude_auth=NONE - completions will fail              # nothing usable
```

Then exercise the session itself:

```bash
source .env
curl -sS http://127.0.0.1:18181/v1/chat/completions \
  ${CLAUDE_CODE_PROXY_API_KEY:+-H "Authorization: Bearer $CLAUDE_CODE_PROXY_API_KEY"} \
  -H 'content-type: application/json' \
  -d '{"messages":[{"role":"user","content":"Reply with exactly: bridge ok"}],"stream":false}'
```

### Startup refuses to run unauthenticated by accident

An empty `CLAUDE_CODE_PROXY_API_KEY` is a hard failure unless you opted in explicitly, so a key lost
to a bad edit or an unset CI variable can never silently open the bridge:

```
[entrypoint] FATAL: CLAUDE_CODE_PROXY_API_KEY is empty.
[entrypoint]   Run ./generate-secrets.sh, or set PROXY_ALLOW_ANONYMOUS=true to
[entrypoint]   deliberately serve without authentication.
```

### Exposure

The published port is bound to `127.0.0.1` by design. This endpoint drives an authenticated Claude
Code session; any client that can reach it inherits that session and its billing. Override
`PROXY_BIND` only behind an authenticating reverse proxy or a deliberate network policy.

---

## Configuring with `generate-secrets.sh`

Every setting lives in `.env`, and `generate-secrets.sh` edits it **in place** — it rewrites the
first occurrence of a key and drops later duplicates, so a stale line can never shadow the real
value. Safe to re-run.

| Flag | Effect |
|------|--------|
| *(none)* | Create `.env` from `env.example` and fill `CLAUDE_CODE_PROXY_API_KEY` if empty |
| `--print` | Print generated values to stdout only; change nothing |
| `--force` | Regenerate values that are already set |
| `--all-tools` | Clear the tool deny list — `Bash`, `Edit`, `Write`, `NotebookEdit` become usable |
| `--allow-anonymous` | Serve with **no** bearer token; empties the key and sets `PROXY_ALLOW_ANONYMOUS=true` |
| `--require-api-key` | **Require** a bearer token again — generates one if absent, sets `PROXY_ALLOW_ANONYMOUS=false`, and leaves the tool lists untouched (alias: `--api-key`) |
| `--secure` | Restore **both** defaults: deny list on *and* bearer token required |
| `--show-secrets` | Also print secret **values** to the shell, with a ready-to-paste `curl` |
| `-f PATH`, `--file PATH` | Operate on a different env file (useful for a dry run) |
| `-h`, `--help` | Usage summary |

`--require-api-key` is the narrow counterpart to `--secure`: it changes authentication only, so
enabling a token does not silently re-lock the tools you opened.

Conflicting combinations exit `64` rather than picking a winner:

- `--secure` with `--all-tools` or `--allow-anonymous`
- `--require-api-key` with `--allow-anonymous`

Every run prints the full effective state to the shell, so there is no need to re-read the file:

```
Effective settings:
  CLAUDE_CODE_PROXY_MODEL=claude-opus-5
  CLAUDE_CODE_DISALLOWED_TOOLS=
  CLAUDE_CODE_ALLOWED_TOOLS=
  CLAUDE_CODE_PERMISSION_MODE=dontAsk
  PROXY_ALLOW_ANONYMOUS=false
  PROXY_BIND=127.0.0.1
  PROXY_PORT=18181
  all tools available=yes
  api key required=yes
```

Secret values are withheld unless asked for, so the summary is safe to paste into an issue or share
a screenshot of. With `--show-secrets` the token is printed for you to save:

```
SECRETS — save these now:
  CLAUDE_CODE_PROXY_API_KEY=<token>

Use it:
  curl -sS http://127.0.0.1:18181/v1/models \
    -H "Authorization: Bearer <token>"
```

Without it, you get a pointer instead:

```
Secret values hidden. Print them with --show-secrets, or read them directly:
  grep -m1 '^CLAUDE_CODE_PROXY_API_KEY=' .env
```

All messages — including the `ALL TOOLS ENABLED` / `ANONYMOUS ACCESS ENABLED` warnings — go to
stdout, so a single redirect captures the whole run:

```bash
./generate-secrets.sh --all-tools --show-secrets | tee setup.log
```

### Choosing a posture

Two **independent** axes. Picking a row from only one of them leaves the other at its default, which
is the usual cause of a bridge that answers `/v1/models` but fails every completion.

**Axis 1 — who may call the bridge**

| Your need | Flag | Result |
|-----------|------|--------|
| Default, safest | *(none)* | Bearer token required |
| A client that cannot send headers (browser, bare `curl`) | `--allow-anonymous` | No token required |
| Turn the token back on | `--require-api-key` | Bearer token required; tools untouched |

**Axis 2 — how the container authenticates to Claude**

| Your situation | Flag | Result |
|----------------|------|--------|
| Any host with a Claude Code login | *(none)* | Bind-mounted host credentials |
| No host login — CI, headless VM | `--setup-token` | Token in `.env` |
| You already hold a token | `--oauth-token <tok>` | Same, without the browser step |

All of them survive `docker compose down -v`: with the bind mount, credentials never live in a
Docker volume.

**Axis 3 — what the agent may do**

| Your need | Flag | Result |
|-----------|------|--------|
| Default, read-only | *(none)* | `Bash`, `Edit`, `Write`, `NotebookEdit` denied |
| Agent must run commands and edit files | `--all-tools` | Every tool available |

#### Complete recipes

| Scenario | Command |
|----------|---------|
| Secure default | `./generate-secrets.sh && docker compose up -d` |
| **Live demo — browser-callable, every built-in tool** | `./generate-secrets.sh --all-tools --allow-anonymous && docker compose up -d` |
| Agent must run commands and edit files | `./generate-secrets.sh --all-tools && docker compose up -d` |
| No host login (CI, headless) | `./generate-secrets.sh --setup-token && docker compose up -d` |
| Undo the relaxations | `./generate-secrets.sh --secure && docker compose up -d` |

> **`docker compose up -d` is required after every change.** Docker reads `.env` only when it
> *creates* the container, so editing `.env` on a running stack changes nothing — the bridge keeps
> serving the settings it launched with, which looks exactly like the flag not working. That is why
> each recipe above is chained with `&& docker compose up -d`.

### Try it without touching your `.env`

```bash
cp env.example /tmp/try.env
./generate-secrets.sh -f /tmp/try.env --all-tools --allow-anonymous
```

### Two behaviours worth knowing

**An empty API key plus `PROXY_ALLOW_ANONYMOUS=true` is a deliberate state, not a missing secret.**
Later runs leave it alone rather than silently re-enabling authentication:

```
CLAUDE_CODE_PROXY_API_KEY left empty — PROXY_ALLOW_ANONYMOUS=true (use --secure or --force to require a token)
```

**If both a key and the anonymous flag are set, the key wins.** That combination is contradictory, so
the entrypoint warns rather than resolving it quietly, and resolves it fail-secure — a stray flag can
never switch authentication off:

```
[entrypoint] WARNING: contradictory settings — an API key is set AND
[entrypoint]   PROXY_ALLOW_ANONYMOUS=true. The key WINS (fail-secure), so clients
[entrypoint]   must send a bearer token and anonymous requests get 401.
```

---
## Reusing your host login

There is no second login and no copy. The container **bind-mounts `$HOME/.claude` read-write** and
runs as your host uid, so it *is* your host's Claude Code installation: same credentials, same
settings, same skills. Nothing is imported, so nothing can drift or go stale, and no Docker command
can destroy it.

This shares the **login**, not the tooling: claude.ai connectors remain unavailable either way,
because `claude -p` activates no MCP servers. See
[Tool calling](#tool-calling-what-this-bridge-does-and-does-not-do).

| Host OS | Authoritative token store | Bind mount |
|---------|---------------------------|------------|
| Linux | `$HOME/.claude/.credentials.json` | works as-is |
| macOS | Keychain `Claude Code-credentials` | `generate-secrets.sh` refreshes the file from the keychain |
| Windows | Credential Manager | set `HOST_CLAUDE_DIR` to a directory holding a valid file |
| CI / headless | *(none)* | use `--setup-token` instead |

The startup log names the credential in use, so this is never ambiguous:

```
[entrypoint] … claude_auth=credentials file            # bind-mounted host login
[entrypoint] … claude_auth=oauth-token (CLAUDE_CODE_OAUTH_TOKEN)
[entrypoint] … claude_auth=NONE - completions will fail
```

### CI and headless hosts

Where there is no host login to share, `claude setup-token` mints a credential that lives in `.env`
instead:

```bash
./generate-secrets.sh --setup-token          # opens a browser once
./generate-secrets.sh --oauth-token sk-ant-oat01-…   # or store one you already have
```

It authenticates completions on any host. **It exposes no claude.ai connectors** — with it set,
`claude mcp list` reports `No MCP servers configured` even with `~/.claude` mounted. Prefer the bind
mount wherever a host login exists.

`.env` is gitignored; that token is a live credential and belongs nowhere else.

### macOS: how the keychain is handled

On macOS the CLI authenticates from the **Keychain**, and `$HOME/.claude/.credentials.json` is a
stale leftover — on this machine it sat 4.6 days expired while the host CLI worked normally. A Linux
container cannot read the Keychain, and the bind mount exposes the *file*, so the file has to be
current.

`generate-secrets.sh` handles this on every run: it reads the keychain item, verifies the token is
unexpired, and rewrites `$HOME/.claude/.credentials.json` from it.

```
refreshed /Users/you/.claude/.credentials.json from the keychain (valid ~6.7h)
  the container bind-mounts this directory, so it now shares your host
  session; the CLI refreshes the credential in place
```

Nothing about your host login changes — it is the same session, written to the file the host CLI
already owned. From then on the containerised CLI refreshes that file in place, so the ~7h lifetime
of the initial token is not a ceiling.

Skip it with `--no-host-token` if you would rather manage the file yourself.

### Verifying the session, not just the container

`GET /v1/models` is served by the bridge process and succeeds regardless of login state. **Model
discovery passing does not prove the backend can serve completions** — a client's "Test connection"
can report success while every chat fails. Only a completion exercises the session:

```bash
source .env
curl -sS http://127.0.0.1:18181/v1/chat/completions \
  -H "Authorization: Bearer $CLAUDE_CODE_PROXY_API_KEY" \
  -H 'content-type: application/json' \
  -d '{"messages":[{"role":"user","content":"Reply with exactly: bridge ok"}],"stream":false}'
```

### Fallback: authenticate inside the container

Only needed on a host with no Claude Code login at all (a CI runner, a fresh VM):

```bash
docker compose run --rm claude-code-bridge claude /login
docker compose restart claude-code-bridge
```

### Design constraints

- **Copy rather than bind-mount the credential.** The host uid (502 on macOS) does not match the
  container's 1000, and the CLI must *write* the token when refreshing it. A read-only bind mount
  breaks refresh; a writable one lets the container modify live host credentials. A copy in the
  volume is writable and disposable.
- **Credentials and config only; never session state.** `sessions/`, `projects/` and
  `history.jsonl` are excluded. Importing them makes the first request fail with
  `Session ID <uuid> is already in use`.

Override the import source with `HOST_CLAUDE_DIR` and `HOST_CLAUDE_JSON` in `.env`.

---
## Tool calling: what this bridge does and does not do

The bridge is **text in, text out**. It reads only `model`, `messages` and `stream` from a request —
`tools`, `tool_choice` and `tool_calls` are **not implemented**. A `tools` array is silently ignored,
and no response ever contains `tool_calls`.

| Layer | Responsibility |
|-------|----------------|
| Client (e.g. Hermes) | Owns its tool registry and credentials, and **executes** tool calls itself |
| This bridge | Relays prompt text to the CLI and returns the reply |
| `claude -p` | Runs the model plus its ~30 built-in tools (Read, Bash, …) **inside the container** |

Two consequences:

- **Clients using native OpenAI function calling will not get tool calls back.** Clients that
  describe their tools *in the prompt* and parse the reply work fine — that is how Hermes drives
  Slack, using its own OAuth, with Claude Code uninvolved.
- **A client's connector state is its own.** Authorising a connector on claude.ai, or seeing it
  `✔ Connected` in `claude mcp list`, has no effect on what the client can execute. Those are
  separate tool systems that happen to share a vendor name.

The built-in tools *are* available to the model inside the container, which is why `--all-tools`
lets it read files, run commands, and open images the client references by path.

---

## claude.ai connectors — visible, but NOT usable through the bridge

Short version: **claude.ai connectors (Slack, Drive, Gmail, Atlassian) do not work through this
bridge.** Not because of the container — because of how the CLI's non-interactive mode works.

The bridge runs `claude -p`, and **print mode loads no MCP tools at all**:

```bash
claude -p "List any MCP tools available to you. If none, reply exactly: NONE"
# NONE   ← on the host
# NONE   ← inside the container
```

Identical on both, so this is a Claude Code print-mode behaviour, not something the bind mount or
this deployment introduces.

`claude mcp list` is misleading here. It reports the connectors as reachable and authorised:

```
claude.ai Slack:     https://mcp.slack.com/mcp        - ✔ Connected
claude.ai Atlassian: https://mcp.atlassian.com/v1/mcp - ✔ Connected
```

That is a health check of your account's connector configuration. It says nothing about whether a
`-p` session can call them — and it cannot. A completion routed through the bridge will answer that
it has no such access, which is accurate.

`claude mcp get "claude.ai Slack"` shows `Scope: claude.ai config`: these are delivered by your
account for interactive surfaces (claude.ai, the Claude Code TUI), not materialised as local servers
a headless session can load.

### What does work

MCP servers defined **locally**, which print mode can load explicitly:

```bash
docker compose run --rm --entrypoint /usr/local/bin/claude claude-code-bridge \
  mcp add --scope user <name> <command…>
```

or a JSON config passed to the CLI via `--mcp-config`. Each needs its own credentials — a Slack bot
token, an Atlassian API token — rather than inheriting your claude.ai authorisation. This is the
approach [`kubernetes/`](../kubernetes) takes: it wires up a GCP MCP auth bridge and an OAuth Secret
explicitly instead of inheriting anything.

Because `$HOME/.claude` is bind-mounted, a server added that way is shared with your host CLI — one
configuration, not a copy.

> Not verified in this repository: whether a locally-added MCP server is picked up by `claude -p`.
> The two claims above that *are* verified: claude.ai connectors are absent from print mode on both
> host and container, and `--mcp-config` is the documented way to supply servers to it.

---

## Images (screenshots from Hermes and similar clients)

Clients that attach screenshots — Hermes among them — put a **host filesystem path** in the prompt
and expect the agent to `Read` it. Three things must all hold, and by default two of them did not:

| Requirement | How it is met |
|-------------|---------------|
| The file exists inside the container | the image cache is bind-mounted |
| At the **same absolute path** as on the host | mounted source and target are identical |
| `Read` is permitted, and the path is an allowed root | `--all-tools` plus `--add-dir` |

The identical-path detail is the subtle one. The client sends something like
`/Users/you/.hermes/image_cache/abc.png`; if that were mounted at `/images` inside the container,
the path in the prompt would simply not exist.

Two roots are mounted by default, both overridable in `.env`:

```bash
HOST_COMPOSER_IMAGES="$HOME/Library/Application Support/Hermes/composer-images"  # Hermes desktop
HOST_IMAGE_CACHE="$HOME/.hermes/image_cache"                                     # Hermes agent
CLAUDE_CODE_ADDITIONAL_DIRS="…/image_cache,…/composer-images"                    # → --add-dir
```

**Hermes desktop pastes screenshots into `~/Library/Application Support/Hermes/composer-images/`**,
not into `~/.hermes/`. That path contains spaces, so the mount uses Compose's long syntax — the
short `source:target:ro` form cannot express it reliably.

### A refusal is not always a permission problem

The bridge appends a guardrail system prompt to each session. Its upstream default reads *"use only
explicitly allowed tools"*, which is wrong when `CLAUDE_CODE_ALLOWED_TOOLS` is empty and the deny
list is empty — that combination means *everything* is permitted, but the model reads "explicitly
allowed" as *nothing* and declines without trying. It reports this as a permission denial, which
sends you looking in the wrong place.

The prompt is now derived from the real posture (all tools / allow-list / deny-list), so the model
is told what it can actually do. Override with `CLAUDE_CODE_APPEND_SYSTEM_PROMPT`.

Confirm what the model was told:

```bash
docker compose exec claude-code-bridge sh -lc 'echo "$CLAUDE_CODE_APPEND_SYSTEM_PROMPT"'
```

Verify with a plain file rather than an image:

```bash
echo probe > "$HOME/.hermes/image_cache/probe.txt"
curl -sS http://127.0.0.1:18181/v1/chat/completions -H 'content-type: application/json' \
  -d "{\\"messages\\":[{\\"role\\":\\"user\\",\\"content\\":\\"Read $HOME/.hermes/image_cache/probe.txt and reply with only its contents.\\"}],\\"stream\\":false}"
```

Add more roots as a comma-separated list — a second client's cache, a shared skills directory — and
mount each at its host path.

> **Inline base64 images are still dropped.** A request carrying
> `{"type": "image_url", "image_url": {"url": "data:image/png;base64,…"}}` loses that part: the
> bridge flattens message content to text and keeps only `type: "text"` items. Path-based images
> work; embedded ones do not. Point such a client at a file path instead.

---

## Model configuration

| Variable | Default | Behaviour |
|----------|---------|-----------|
| `CLAUDE_CODE_PROXY_MODEL` | `claude-opus-5` | Applied when a request omits `model` |
| `CLAUDE_CODE_MODELS` | `claude-opus-5,claude-fable-5,claude-opus-4-8,claude-opus-4-7,claude-opus-4-6,claude-sonnet-5,claude-sonnet-4-6,claude-haiku-4-5,claude-haiku-4-5-20251001` | Advertised by `GET /v1/models` |
| `CLAUDE_CODE_PASS_MODEL` | `true` | Forward the client's requested model instead of forcing the default |

`claude-opus-5` is listed first so clients that select the head of the list default correctly.

```bash
source .env

# Default path — no "model" key
curl -sS http://127.0.0.1:18181/v1/chat/completions \
  -H "Authorization: Bearer $CLAUDE_CODE_PROXY_API_KEY" \
  -H 'content-type: application/json' \
  -d '{"messages":[{"role":"user","content":"identify your model"}],"stream":false}'

# Opt into Fable 5 for one request
curl -sS http://127.0.0.1:18181/v1/chat/completions \
  -H "Authorization: Bearer $CLAUDE_CODE_PROXY_API_KEY" \
  -H 'content-type: application/json' \
  -d '{"model":"claude-fable-5","messages":[{"role":"user","content":"hello"}],"stream":false}'

# Advertised catalogue
curl -sS http://127.0.0.1:18181/v1/models \
  -H "Authorization: Bearer $CLAUDE_CODE_PROXY_API_KEY" | python3 -m json.tool
```

`CLAUDE_CODE_MODELS` is an advertisement, **not an allowlist**. With `CLAUDE_CODE_PASS_MODEL=true`
the bridge forwards any valid Claude model identifier a client supplies. Set it `false` to pin all
traffic to `CLAUDE_CODE_PROXY_MODEL`.

### Client configuration

| Field | Value |
|-------|-------|
| Endpoint URL | `http://localhost:18181/v1` |
| Default model | `claude-opus-5` |
| API key | Required — value of `CLAUDE_CODE_PROXY_API_KEY` |

```bash
grep -m1 '^CLAUDE_CODE_PROXY_API_KEY=' .env
```

---

## Verification

```bash
source .env

docker compose ps
#   NAME                 STATUS
#   claude-code-bridge   Up ... (healthy)   127.0.0.1:18181->18181/tcp

# Liveness
curl -fsS http://127.0.0.1:18181/health -H "Authorization: Bearer $CLAUDE_CODE_PROXY_API_KEY"
#   {"status": "ok"}

# Authentication enforced
curl -sS -o /dev/null -w '%{http_code}\n' http://127.0.0.1:18181/v1/models                     # 401
curl -sS -o /dev/null -w '%{http_code}\n' -H 'Authorization: Bearer invalid' \
  http://127.0.0.1:18181/v1/models                                                             # 401

# Advertised catalogue, opus-5 first
curl -sS http://127.0.0.1:18181/v1/models -H "Authorization: Bearer $CLAUDE_CODE_PROXY_API_KEY" \
  | python3 -c 'import sys,json; print([m["id"] for m in json.load(sys.stdin)["data"]])'
#   ['claude-opus-5', 'claude-fable-5', 'claude-sonnet-5', 'claude-haiku-4-5-20251001']

# Effective configuration
docker compose logs claude-code-bridge | grep entrypoint
```

To verify against **this container** specifically, bypassing host port ambiguity entirely:

```bash
docker compose exec claude-code-bridge sh -lc \
  'curl -sS -H "Authorization: Bearer $CLAUDE_CODE_PROXY_API_KEY" localhost:18181/v1/models'
```

Completions are the only check that exercises the Claude Code session. Treat a successful
completion — not a healthy container — as the acceptance criterion.

---

## Security model

Allow/deny lists are transmitted on **every request**, so they are enforced at call time rather
than depending on a settings file that could drift.

| Variable | Default | Effect |
|----------|---------|--------|
| `CLAUDE_CODE_DISALLOWED_TOOLS` | `Bash,Edit,Write,NotebookEdit` | Denied unconditionally — read-only posture |
| `CLAUDE_CODE_ALLOWED_TOOLS` | *(empty)* | Empty means *no explicit allowlist*, not *allow everything* |
| `CLAUDE_CODE_PERMISSION_MODE` | `dontAsk` | Non-interactive; no approval prompts |
| `CLAUDE_CODE_EFFORT` | `high` | Reasoning effort: `low` … `max` |
| `CLAUDE_CODE_MAX_BUDGET_USD` | `5.00` | Per-invocation spend ceiling |

Container posture: non-root (`uid 1000`), `cap_drop: ALL`, `no-new-privileges:true`,
`pids_limit: 256`, memory and CPU ceilings, `tmpfs /tmp`, JSON log rotation at 10 MB × 3.

Do **not** set `CLAUDE_CODE_PERMISSION_MODE=bypassPermissions`. It makes the CLI pass
`--dangerously-skip-permissions`, which is refused outright when running as root and which
discards every guardrail above. `dontAsk` is the correct non-interactive mode.

`.env` holds a bearer token and is covered by the repository `.gitignore` (`.env`, `.env.*`,
`*credentials*.json`). Confirm before committing:

```bash
git check-ignore -v docker-bridge/.env
```

### Enabling every tool

The deny list is what restricts tools; the allow list only narrows further. So an empty
`CLAUDE_CODE_ALLOWED_TOOLS` does **not** grant everything — `CLAUDE_CODE_DISALLOWED_TOOLS` still
wins. To use all tools, clear the *deny* list — `./generate-secrets.sh --all-tools`, then
`docker compose up -d --build`. See
[Choosing a posture](#choosing-a-posture) for the full matrix.

| Deny list | Allow list | Result |
|-----------|------------|--------|
| `Bash,Edit,Write,NotebookEdit` | *(empty)* | Default — read-only tools only |
| `Bash,Edit,Write,NotebookEdit` | `Read,Grep` | Only `Read` and `Grep`; the four stay denied |
| *(empty)* | *(empty)* | **Every tool available** |

This grants command execution and file modification **inside the container** — the `workspace`
volume and the container's own `$HOME`, not your host filesystem, since nothing from the host is
bind-mounted read-write. It does mean any client of the bridge can run arbitrary commands in that
container, which shares your Claude Code credentials. Keep `PROXY_BIND` on `127.0.0.1`.

Reverse it with `./generate-secrets.sh --secure`, which also restores the bearer token.

### Serving without authentication

A browser cannot attach an `Authorization` header to an address-bar request, so
`http://localhost:18181/v1/models` always returns `{"error": {"message": "unauthorized"}}`. That is
correct behaviour. If you need browser-viewable output, authentication can be disabled explicitly:

```bash
./generate-secrets.sh --allow-anonymous   # empties the key, sets PROXY_ALLOW_ANONYMOUS=true
docker compose up -d --force-recreate
```

Emptying the API key alone is deliberately **not** sufficient — the entrypoint exits non-zero:

```
[entrypoint] FATAL: CLAUDE_CODE_PROXY_API_KEY is empty.
[entrypoint]   Run ./generate-secrets.sh, or set PROXY_ALLOW_ANONYMOUS=true to
[entrypoint]   deliberately serve without authentication.
```

The two-key requirement keeps an accidentally missing token a hard failure rather than a silently
open bridge. When anonymous access is on, the startup log says so and `api_key_required=no`:

```
[entrypoint] WARNING: anonymous access enabled (PROXY_ALLOW_ANONYMOUS=true).
```

Understand what this gives away: any process or web page on the host can then drive your Claude Code
session and bill your account, with no audit trail distinguishing callers. Keep `PROXY_BIND` on
`127.0.0.1`, and prefer `curl -H "Authorization: Bearer ..."` for one-off inspection instead.

---

## Operations

### Persistent state

| Volume | Mount | Contents |
|--------|-------|----------|
| *(bind mount)* | `/hosthome/.claude` | Your real host Claude Code directory — credentials, settings, connectors |
| `workspace` | `/workspace` | Working directory, `.claude/settings.local.json` |

```bash
docker compose down          # stop
docker compose down -v       # also drop the workspace volume — your Claude login is
                             # unaffected: it lives on the host, not in a volume
```

### Routine tasks

```bash
docker compose logs -f claude-code-bridge                  # follow logs
docker compose restart claude-code-bridge                  # restart, volumes retained
docker compose up -d --build                               # rebuild after a CLI version bump
docker compose run --rm claude-code-bridge bash            # interactive shell
docker compose run --rm claude-code-bridge claude /login    # (re-)authenticate
```

### Pinning the CLI version

`CLAUDE_CODE_VERSION` defaults to `latest`, so rebuilds track upstream releases. Pin it in `.env`
for reproducible images:

```bash
CLAUDE_CODE_VERSION=2.1.220
```

### Changing the published port

```bash
sed -i '' 's/^PROXY_PORT=.*/PROXY_PORT=18182/' .env    # GNU sed: drop the ''
docker compose up -d --force-recreate
```

### Rollback

```bash
docker compose down                                        # non-destructive
docker compose down -v && docker compose up -d --build     # full rebuild from clean state
```

---

## Comparison with `../docker/`

| | `docker-bridge/` (this directory) | [`../docker/`](../docker) |
|---|---|---|
| Interface | `docker compose` | `./docker-hermes-claude-bridge.sh up` |
| Definition | Checked-in Dockerfile and Compose file | Generated at runtime by the script |
| Scope | Bridge only | Bridge plus an agent stack |
| Default model | `claude-opus-5` (`claude-fable-5` opt-in) | `claude-opus-4-8` |
| Host dependencies | Docker only | Also requires `flock(1)` — effectively Linux-only |

Use this directory for a declarative, portable Compose deployment, including on macOS where the
script's `flock` dependency is unavailable.

---

## Troubleshooting

### Symptom: `up` aborts with `set CLAUDE_CODE_PROXY_API_KEY in .env`

Expected behaviour, not a defect. Run `./generate-secrets.sh`. Compose refuses to start a bridge
that would accept unauthenticated requests.

### Symptom: responses do not match this container

Model list differs from `CLAUDE_CODE_MODELS`, or requests succeed without a bearer token.

**Diagnosis.** Another process holds the port. Docker reports the mapping
(`127.0.0.1:18181->18181/tcp`) even when it lost the bind, and logs nothing. Common sources are a
host-mode bridge from `../docker/` (`PROXY_RUNTIME` defaults to `host`), or `../mac/` / `../windows/`.

```bash
ps aux | grep '[c]laude_code_bridge'      # authoritative
launchctl list | grep -i bridge           # macOS: is it supervised?
```

`lsof -iTCP:18181` reports nothing under OrbStack even when the port is published — absence there
is not evidence.

**Remediation.** Stop the competing listener, or relocate this container via `PROXY_PORT`. On macOS
a `launchd` agent with `KeepAlive = true` will respawn within seconds of a `kill`; unload it first:

```bash
launchctl bootout "gui/$(id -u)/<label>"
launchctl disable "gui/$(id -u)/<label>"
mkdir -p "$HOME/Library/LaunchAgents/disabled"
mv "$HOME/Library/LaunchAgents/<label>.plist" "$HOME/Library/LaunchAgents/disabled/"
```

To restore it later:

```bash
mv "$HOME/Library/LaunchAgents/disabled/<label>.plist" "$HOME/Library/LaunchAgents/"
launchctl enable "gui/$(id -u)/<label>"
launchctl bootstrap "gui/$(id -u)" "$HOME/Library/LaunchAgents/<label>.plist"
```

If `kill` returns `operation not permitted`, the process belongs to another local user; compare
`ps -o pid,user -p <pid>` against `id -un`. It requires `sudo` or that user's session.

### Symptom: `--all-tools` seems to have no effect

Check what the container actually resolved, not what `.env` says:

```bash
docker compose logs claude-code-bridge | grep -oE "disallowed_tools=\[[^]]*\]"
docker compose exec claude-code-bridge cat /workspace/.claude/settings.local.json
```

All tools are enabled when `disallowed_tools` is absent from the startup line and the settings file
reports `"deny": []`.

Two things could previously reinstate the deny list behind your back, both fixed — if you are running
an older copy of this directory, they are what to look for:

- **`${VAR:-default}` / `${VAR:=default}` substitute on an EMPTY value, not just an unset one.** An
  intentionally empty deny list was therefore replaced by the default in both `docker-compose.yml`
  and `docker-entrypoint.sh`. The fix is the colonless form, `${VAR-default}` / `${VAR=default}`,
  which distinguishes "unset" from "deliberately empty".
- **`settings.local.json` lived on the `workspace` volume and was only written when absent.** The
  volume outlives the container, so a file from an earlier configuration kept denying tools the
  environment now permitted. It is now rewritten from the current environment on every start.

A config change needs a restart to take effect:

```bash
docker compose up -d --build
```

### Symptom: `Not logged in · Please run /login`, or a `502` with zero output tokens

The bind-mounted credential is expired or absent. Confirm which:

```bash
docker compose logs claude-code-bridge | grep -o 'claude_auth=.*'
docker compose run --rm --entrypoint /usr/local/bin/claude claude-code-bridge mcp list
```

On macOS the usual cause is that `$HOME/.claude/.credentials.json` has gone stale against the
Keychain. Re-run `./generate-secrets.sh` — it rewrites the file from the Keychain — then
`docker compose up -d`. See
[macOS: how the keychain is handled](#macos-how-the-keychain-is-handled). It is not a re-login.

### Symptom: `502 … claude api error 429: You've hit your monthly spend limit.`

An account-level limit, not a deployment fault — the request reached Anthropic and was refused.
It is per-account, so it can affect one model while another still answers. Either switch model
(`CLAUDE_CODE_PROXY_MODEL`, or `model` per request) or raise the limit on the account.

`CLAUDE_CODE_MAX_BUDGET_USD` is unrelated: that ceiling is enforced locally per invocation and
surfaces as a different message.

### Symptom: `502 … Session ID <uuid> is already in use`

Session state was imported from the host, or a retry reused a registered id. Both are mitigated
here — session state is excluded from the seed, and the retry path regenerates the identifier. If
it still occurs, reset the volume:

```bash
docker compose down -v && docker compose up -d
```

### Symptom: `The "f" variable is not set` during `docker compose config`

Compose interpolates `$VAR` inside inline shell in the Compose file before the shell sees it,
silently emptying loop variables. Escape as `$$VAR`. Treat any interpolation warning from
`docker compose config` as a defect, not noise.

### Symptom: `s6-overlay-suexec: fatal: can only run as pid 1`

`init: true` was added to an s6-overlay-based service. Compose's init claims PID 1, which s6
requires. Remove it. This image uses `tini` from its own `ENTRYPOINT` and must not have `init: true`
layered on top.

### Symptom: `claude: command not found` inside the container

The image was built from a layer where the npm install had not completed.

```bash
docker compose build --no-cache claude-code-bridge
```

### Symptom: builds are slow on every invocation

BuildKit is disabled, so the apt and npm cache mounts are inactive. Export `DOCKER_BUILDKIT=1`.
