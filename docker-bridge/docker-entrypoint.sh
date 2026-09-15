#!/usr/bin/env bash
# Entrypoint for the Claude Code bridge container.
# Builds the bridge command from environment variables (sane defaults baked in),
# or runs an arbitrary command if one is passed (e.g. `bash`, `claude`).
set -euo pipefail

: "${PROXY_HOST:=0.0.0.0}"
: "${PROXY_PORT:=18181}"
: "${CLAUDE_BIN:=/usr/local/bin/claude}"
: "${CLAUDE_CODE_PROXY_CWD:=/workspace}"
# Default model = Opus 5. Fable 5 is advertised as an optional alternative via
# CLAUDE_CODE_MODELS; clients pick it per request with "model": "claude-fable-5".
: "${CLAUDE_CODE_PROXY_MODEL:=claude-opus-5}"
: "${CLAUDE_CODE_MODELS:=claude-opus-5,claude-fable-5,claude-opus-4-8,claude-opus-4-7,claude-opus-4-6,claude-sonnet-5,claude-sonnet-4-6,claude-haiku-4-5,claude-haiku-4-5-20251001}"
# Honour whatever model the client asks for instead of forcing every request to
# CLAUDE_CODE_PROXY_MODEL — this is what makes Fable 5 selectable at runtime.
: "${CLAUDE_CODE_PASS_MODEL:=true}"
: "${CLAUDE_CODE_EFFORT:=high}"
: "${CLAUDE_CODE_PERMISSION_MODE:=dontAsk}"
: "${CLAUDE_CODE_MAX_BUDGET_USD:=5.00}"
# `=` not `:=` — an EXPLICITLY EMPTY value means "deny nothing" (all tools) and must
# survive. With `:=` the default would silently reinstate the deny list, so
# generate-secrets.sh --all-tools would appear to do nothing.
: "${CLAUDE_CODE_DISALLOWED_TOOLS=Bash,Edit,Write,NotebookEdit}"
: "${CLAUDE_CODE_ALLOWED_TOOLS:=}"
# Read roots beyond the working directory (image caches, shared skills).
: "${CLAUDE_CODE_ADDITIONAL_DIRS:=}"
: "${CLAUDE_CODE_PROXY_API_KEY:=}"
# Opt-in anonymous access. Kept separate from an empty API key so that a key that
# is missing BY ACCIDENT still fails fast, instead of quietly serving an
# unauthenticated bridge onto whatever PROXY_BIND points at.
: "${PROXY_ALLOW_ANONYMOUS:=false}"
# Long-lived token from `claude setup-token`. When present it is the CLI's sole
# credential — independent of the claude-home volume, so recreating the volume
# (or running on CI) cannot break authentication.
: "${CLAUDE_CODE_OAUTH_TOKEN:=}"
# Derive HOME from the running uid rather than hardcoding it: the image's user
# can be overridden (`user:` in compose, `--user`, rootless remaps), and Claude
# Code writes its credentials under $HOME. Falls back to /home/node only if the
# uid has no passwd entry.
: "${HOME:=$(getent passwd "$(id -u)" 2>/dev/null | cut -d: -f6)}"
: "${HOME:=/home/node}"

export CLAUDE_CODE_MODELS
[ -n "$CLAUDE_CODE_OAUTH_TOKEN" ] && export CLAUDE_CODE_OAUTH_TOKEN

# Report the credential source up front: "which auth am I using" is the first
# question when completions fail, and it should not require reading two logs.
if [ -n "$CLAUDE_CODE_OAUTH_TOKEN" ]; then
  claude_auth="oauth-token (CLAUDE_CODE_OAUTH_TOKEN)"
elif [ -f "$HOME/.claude/.credentials.json" ]; then
  claude_auth="credentials file"
else
  claude_auth="NONE - completions will fail"
fi

if [ -z "$CLAUDE_CODE_PROXY_API_KEY" ] && [ "$PROXY_ALLOW_ANONYMOUS" != "true" ]; then
  echo "[entrypoint] FATAL: CLAUDE_CODE_PROXY_API_KEY is empty." >&2
  echo "[entrypoint]   Run ./generate-secrets.sh, or set PROXY_ALLOW_ANONYMOUS=true to" >&2
  echo "[entrypoint]   deliberately serve without authentication." >&2
  exit 1
fi

if [ -n "$CLAUDE_CODE_PROXY_API_KEY" ] && [ "$PROXY_ALLOW_ANONYMOUS" = "true" ]; then
  echo "[entrypoint] WARNING: contradictory settings — an API key is set AND" >&2
  echo "[entrypoint]   PROXY_ALLOW_ANONYMOUS=true. The key WINS (fail-secure), so clients" >&2
  echo "[entrypoint]   must send a bearer token and anonymous requests get 401." >&2
  echo "[entrypoint]   For genuinely anonymous access: ./generate-secrets.sh --allow-anonymous" >&2
fi

if [ -z "$CLAUDE_CODE_PROXY_API_KEY" ]; then
  echo "[entrypoint] WARNING: anonymous access enabled (PROXY_ALLOW_ANONYMOUS=true)." >&2
  echo "[entrypoint]   Any process that can reach ${PROXY_HOST}:${PROXY_PORT} can drive this" >&2
  echo "[entrypoint]   Claude Code session and spend against the account. Keep PROXY_BIND" >&2
  echo "[entrypoint]   on 127.0.0.1." >&2
fi

# The bridge appends a guardrail system prompt. Its built-in default says "use only
# explicitly allowed tools", which is actively wrong when the deny list is empty and
# the allow list is empty (= everything permitted): the model reads "explicitly
# allowed" as "none" and refuses to act, even though the tools work. Derive the
# wording from the real posture instead.
if [ -z "${CLAUDE_CODE_APPEND_SYSTEM_PROMPT:-}" ]; then
  if [ -z "$CLAUDE_CODE_DISALLOWED_TOOLS" ] && [ -z "$CLAUDE_CODE_ALLOWED_TOOLS" ]; then
    CLAUDE_CODE_APPEND_SYSTEM_PROMPT="You are being called through a local OpenAI-compatible proxy. All tools are available to you, including Read for files the user references by path. Use them as needed to answer the request."
  elif [ -n "$CLAUDE_CODE_ALLOWED_TOOLS" ]; then
    CLAUDE_CODE_APPEND_SYSTEM_PROMPT="You are being called through a local OpenAI-compatible proxy. Only these tools are available: ${CLAUDE_CODE_ALLOWED_TOOLS}. Do not attempt others."
  else
    CLAUDE_CODE_APPEND_SYSTEM_PROMPT="You are being called through a local OpenAI-compatible proxy. Every tool is available EXCEPT: ${CLAUDE_CODE_DISALLOWED_TOOLS}. Use the rest freely; do not attempt the excluded ones."
  fi
fi
export CLAUDE_CODE_APPEND_SYSTEM_PROMPT

mkdir -p "$HOME" "$CLAUDE_CODE_PROXY_CWD/.claude"

# Write the Claude Code permission file from the CURRENT env on every start.
# It is derived config, not user data, so it must be rewritten rather than seeded
# once: the workspace volume outlives the container, so a file left from an earlier
# configuration would keep denying tools that the env now permits.
# Belt-and-suspenders anyway — the bridge also passes the allow/deny lists on every
# request, which is the live enforcement point.
settings="$CLAUDE_CODE_PROXY_CWD/.claude/settings.local.json"
python3 - "$settings" "$CLAUDE_CODE_ALLOWED_TOOLS" "$CLAUDE_CODE_DISALLOWED_TOOLS" <<'PY'
import json, sys
path, allowed, denied = sys.argv[1], sys.argv[2], sys.argv[3]
split = lambda v: [x.strip() for x in v.split(",") if x.strip()]
with open(path, "w") as fh:
    json.dump({"permissions": {"allow": split(allowed), "deny": split(denied)}}, fh, indent=2)
    fh.write("\n")
PY

# If a command was provided (docker compose run … <cmd>), exec it instead.
if [ "$#" -gt 0 ]; then
  exec "$@"
fi

set -- python3 /app/claude_code_bridge.py \
  --host "$PROXY_HOST" \
  --port "$PROXY_PORT" \
  --claude-bin "$CLAUDE_BIN" \
  --cwd "$CLAUDE_CODE_PROXY_CWD" \
  --model "$CLAUDE_CODE_PROXY_MODEL" \
  --effort "$CLAUDE_CODE_EFFORT" \
  --permission-mode "$CLAUDE_CODE_PERMISSION_MODE"

# Omit the flag entirely when empty, rather than passing an empty deny list.
[ -n "$CLAUDE_CODE_DISALLOWED_TOOLS" ] && set -- "$@" --disallowed-tools "$CLAUDE_CODE_DISALLOWED_TOOLS"

[ "${CLAUDE_CODE_PASS_MODEL:-true}" = "true" ] && set -- "$@" --pass-model
[ -n "$CLAUDE_CODE_ALLOWED_TOOLS" ]  && set -- "$@" --allowed-tools  "$CLAUDE_CODE_ALLOWED_TOOLS"
[ -n "$CLAUDE_CODE_ADDITIONAL_DIRS" ] && set -- "$@" --additional-dirs "$CLAUDE_CODE_ADDITIONAL_DIRS"
[ -n "$CLAUDE_CODE_MAX_BUDGET_USD" ] && set -- "$@" --max-budget-usd "$CLAUDE_CODE_MAX_BUDGET_USD"
[ -n "$CLAUDE_CODE_PROXY_API_KEY" ]  && set -- "$@" --api-key        "$CLAUDE_CODE_PROXY_API_KEY"

echo "[entrypoint] claude-code bridge -> ${PROXY_HOST}:${PROXY_PORT}" \
     "default_model=${CLAUDE_CODE_PROXY_MODEL} effort=${CLAUDE_CODE_EFFORT}" \
     "advertised=${CLAUDE_CODE_MODELS}" \
     "pass_model=${CLAUDE_CODE_PASS_MODEL}" \
     "permission_mode=${CLAUDE_CODE_PERMISSION_MODE}" \
     "api_key_required=$([ -n "$CLAUDE_CODE_PROXY_API_KEY" ] && echo yes || echo no)" \
     "claude_auth=${claude_auth}"
exec "$@"
