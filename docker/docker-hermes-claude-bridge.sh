#!/usr/bin/env bash
#
# docker-hermes-claude-bridge.sh
# ----------------------------------------------------------------------------
# Single, self-contained Docker launcher for Hermes + Claude Code.
#
# It builds a small proxy image that bundles:
#   - Python 3 (runs the OpenAI-compatible proxy)
#   - the Claude Code CLI (@anthropic-ai/claude-code)
#   - claude_code_proxy.py  (the embedded proxy)
#
# ...and then runs:
#   - host claude-code proxy process   -> OpenAI-compatible proxy backed by host Claude Code
#   - ${STACK_NAME}-agent              -> Hermes dashboard/API configured to use that proxy
#
# The default proxy runtime is the host, because copied Claude Code auth is not
# reliably portable into a Linux Docker container.
# If `claude` is already authenticated on the host, Hermes can use it without
# asking the developer to log in again inside Docker.
#
# This file is self-sufficient: copy *just this script* to any Docker host and
# run it. The Dockerfile / entrypoint / healthcheck and a fallback copy of the
# proxy are embedded below. If a real claude_code_proxy.py sits next to this
# script (or in the parent directory, or at $CLAUDE_PROXY_SRC) that canonical
# copy is preferred over the embedded fallback.
#
# Two runtime modes: host proxy (default) and an experimental in-container proxy.
#
# Usage:
#   ./docker-hermes-claude-bridge.sh up           # run host proxy + run Hermes
#   ./docker-hermes-claude-bridge.sh test         # verify proxy and Hermes
#   ./docker-hermes-claude-bridge.sh status       # containers + health
#   ./docker-hermes-claude-bridge.sh logs         # follow Hermes logs
#   ./docker-hermes-claude-bridge.sh logs proxy   # follow proxy logs
#   ./docker-hermes-claude-bridge.sh open         # open Hermes dashboard
#   ./docker-hermes-claude-bridge.sh mcp-callback URL      # bridge OAuth callback into container
#   ./docker-hermes-claude-bridge.sh mcp-status            # show MCP config/auth/log status
#   ./docker-hermes-claude-bridge.sh login        # optional: run Claude Code login in proxy
#   ./docker-hermes-claude-bridge.sh build        # build the proxy image only
#   ./docker-hermes-claude-bridge.sh health       # GET /health
#   ./docker-hermes-claude-bridge.sh config       # GET /config
#   PROXY_RUNTIME=docker ./docker-hermes-claude-bridge.sh shell  # shell in experimental proxy container
#   ./docker-hermes-claude-bridge.sh restart      # restart both containers
#   ./docker-hermes-claude-bridge.sh stop         # stop + remove containers (keep data/auth)
#   ./docker-hermes-claude-bridge.sh down         # alias for stop; add --purge to drop Docker volumes
#   ./docker-hermes-claude-bridge.sh extract DIR  # write Dockerfile+entrypoint+proxy into DIR
#   ./docker-hermes-claude-bridge.sh help
#
# Configuration (env vars, or a `.env` file next to this script):
#   STACK_NAME                default: local-hermes       (prefix for container/network/volume names)
#   CONTAINER                 default: ${STACK_NAME}-claude-code-proxy
#   HERMES_CONTAINER          default: ${STACK_NAME}-agent
#   IMAGE                     default: ${STACK_NAME}-claude-code-proxy:local
#   HERMES_IMAGE              default: nousresearch/hermes-agent:v2026.7.20
#   NETWORK                   default: ${STACK_NAME}-net  (so a Hermes container can reach it by name)
#   PROXY_RUNTIME             default: host                (host uses already-authenticated host claude)
#   HOST_CLAUDE_DIR           default: $HOME/.claude       (host Claude Code auth/config)
#   HOST_CLAUDE_JSON          default: $HOME/.claude.json  (host Claude Code login state)
#   PROXY_PORT                default: 18181
#   PROXY_BIND                default: 127.0.0.1           (host interface to publish on; 0.0.0.0 to expose)
#   HOST_PROXY_HOST           default: 0.0.0.0 on Linux, 127.0.0.1 elsewhere
#   PROXY_HOME_VOLUME         default: ${STACK_NAME}-claude-home
#   WORKSPACE_VOLUME          default: ${STACK_NAME}-workspace
#   HERMES_DATA_VOLUME        default: ${STACK_NAME}-data
#   HERMES_DASHBOARD_PORT     default: 9119
#   HERMES_API_PORT           default: 8642
#   HERMES_BIND               default: 127.0.0.1
#   HERMES_API_KEY            default: a random per-run key (override to pin)
#   CLAUDE_CODE_VERSION       default: latest              (npm @anthropic-ai/claude-code version; pin e.g. 2.1.167 to freeze)
#   CLAUDE_CODE_PROXY_MODEL   default: claude-opus-4-8     (default when a request omits "model")
#   CLAUDE_CODE_PASS_MODEL    default: true                (honor any Claude model ID the client requests)
#   CLAUDE_CODE_MODELS        default: claude-opus-4-8,claude-sonnet-5,claude-haiku-4-5,claude-fable-5 (advertised on /v1/models)
#   CLAUDE_CODE_EFFORT        default: max
#   CLAUDE_CODE_PERMISSION_MODE default: dontAsk
#   CLAUDE_CODE_MAX_BUDGET_USD  default: 1.00              (empty string disables the budget flag)
#   CLAUDE_CODE_ALLOWED_TOOLS   default: empty (no allowlist; read-only enforced via denylist + permission mode)
#   CLAUDE_CODE_DISALLOWED_TOOLS default: Bash,Edit,Write,NotebookEdit
#   CLAUDE_CODE_PROXY_API_KEY   default: (empty -> proxy is unauthenticated; set one to require Bearer)
#   MEMORY                    default: 2g
#   CPUS                      default: 1
# ----------------------------------------------------------------------------
set -euo pipefail

# --- error handling ----------------------------------------------------------
# Print the failing line + function on any uncaught error so users don't get a
# bare 'exit 1' from somewhere deep in the script.
_on_err() {
  local code=$? line=${1:-?} func=${2:-MAIN}
  printf '\033[1;31m[hermes-proxy] error:\033[0m exit %d at line %s in %s\n' "$code" "$line" "$func" >&2
  printf '  hint: re-run with: bash -x %s %s\n' "$0" "${*:-...}" >&2
}
trap '_on_err "$LINENO" "${FUNCNAME[0]:-MAIN}"' ERR

# --- locate self -------------------------------------------------------------
SOURCE="${BASH_SOURCE[0]}"
while [ -h "$SOURCE" ]; do
  DIR="$(cd -P "$(dirname "$SOURCE")" >/dev/null 2>&1 && pwd)"
  SOURCE="$(readlink "$SOURCE")"
  [[ "$SOURCE" != /* ]] && SOURCE="$DIR/$SOURCE"
done
SCRIPT_DIR="$(cd -P "$(dirname "$SOURCE")" >/dev/null 2>&1 && pwd)"

# --- optional .env -----------------------------------------------------------
if [ -f "$SCRIPT_DIR/.env" ]; then
  set -a
  # shellcheck disable=SC1091
  . "$SCRIPT_DIR/.env"
  set +a
fi

# --- config ------------------------------------------------------------------
STACK_NAME="${STACK_NAME:-local-hermes}"
CONTAINER="${CONTAINER:-${STACK_NAME}-claude-code-proxy}"
HERMES_CONTAINER="${HERMES_CONTAINER:-${STACK_NAME}-agent}"
IMAGE="${IMAGE:-${STACK_NAME}-claude-code-proxy:local}"
HERMES_IMAGE="${HERMES_IMAGE:-nousresearch/hermes-agent:v2026.7.20}"
NETWORK="${NETWORK:-${STACK_NAME}-net}"
PROXY_RUNTIME="${PROXY_RUNTIME:-host}"
HOST_CLAUDE_DIR="${HOST_CLAUDE_DIR:-$HOME/.claude}"
HOST_CLAUDE_JSON="${HOST_CLAUDE_JSON:-$HOME/.claude.json}"
PROXY_PORT="${PROXY_PORT:-18181}"
PROXY_BIND="${PROXY_BIND:-127.0.0.1}"
if [ -z "${HOST_PROXY_HOST:-}" ]; then
  case "$(uname -s 2>/dev/null || echo unknown)" in
    Linux) HOST_PROXY_HOST="0.0.0.0" ;;
    *) HOST_PROXY_HOST="127.0.0.1" ;;
  esac
fi
PROXY_HOME_VOLUME="${PROXY_HOME_VOLUME:-${STACK_NAME}-claude-home}"
WORKSPACE_VOLUME="${WORKSPACE_VOLUME:-${STACK_NAME}-workspace}"
HERMES_DATA_VOLUME="${HERMES_DATA_VOLUME:-${STACK_NAME}-data}"
HERMES_DASHBOARD_PORT="${HERMES_DASHBOARD_PORT:-9119}"
HERMES_API_PORT="${HERMES_API_PORT:-8642}"
HERMES_BIND="${HERMES_BIND:-127.0.0.1}"
HERMES_API_KEY="${HERMES_API_KEY:-$(openssl rand -hex 24)}"
CLAUDE_CODE_VERSION="${CLAUDE_CODE_VERSION:-latest}"
NODE_BASE="${NODE_BASE:-node:22-bookworm-slim}"

CLAUDE_CODE_PROXY_MODEL="${CLAUDE_CODE_PROXY_MODEL:-claude-opus-4-8}"
# Pass the client-requested model through to the Claude Code CLI (any valid Claude
# model ID), instead of forcing every request to CLAUDE_CODE_PROXY_MODEL. Default on
# so the bridge is not limited to a single model. Set to "false" to pin the default.
CLAUDE_CODE_PASS_MODEL="${CLAUDE_CODE_PASS_MODEL:-true}"
CLAUDE_CODE_EFFORT="${CLAUDE_CODE_EFFORT:-max}"
CLAUDE_CODE_PERMISSION_MODE="${CLAUDE_CODE_PERMISSION_MODE:-dontAsk}"
CLAUDE_CODE_MAX_BUDGET_USD="${CLAUDE_CODE_MAX_BUDGET_USD-1.00}"
# Empty allowlist by default: no tools are force-allowed here. Read-only posture
# is enforced by the denylist below plus the dontAsk permission mode. Set this to
# a comma-separated list to allow specific read-only MCP tools (e.g. GCP
# logging/monitoring/trace, GitHub, or kubectl).
CLAUDE_CODE_ALLOWED_TOOLS="${CLAUDE_CODE_ALLOWED_TOOLS-}"
# Write-capable Claude Code tools are denied so the bridge stays read-only.
CLAUDE_CODE_DISALLOWED_TOOLS="${CLAUDE_CODE_DISALLOWED_TOOLS-Bash,Edit,Write,NotebookEdit}"
CLAUDE_CODE_PROXY_API_KEY="${CLAUDE_CODE_PROXY_API_KEY:-}"
MEMORY="${MEMORY:-2g}"
CPUS="${CPUS:-1}"
HOST_PROXY_PID_FILE="${HOST_PROXY_PID_FILE:-$SCRIPT_DIR/.${STACK_NAME}-claude-code-proxy.pid}"
HOST_PROXY_LOG_FILE="${HOST_PROXY_LOG_FILE:-$SCRIPT_DIR/.${STACK_NAME}-claude-code-proxy.log}"
HOST_PROXY_WORKSPACE="${HOST_PROXY_WORKSPACE:-$SCRIPT_DIR/.${STACK_NAME}-workspace}"

log()  { printf '\033[1;34m[hermes-proxy]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[hermes-proxy]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[hermes-proxy] error:\033[0m %s\n' "$*" >&2; exit 1; }

need_docker() {
  command -v docker >/dev/null 2>&1 || die "docker is not installed or not on PATH"
  docker info >/dev/null 2>&1 || die "docker daemon is not reachable (is Docker running?)"
}

require_host_claude_auth() {
  [ -d "$HOST_CLAUDE_DIR" ] || die "host Claude Code auth directory not found: $HOST_CLAUDE_DIR

Run Claude Code on the host first and complete authentication, then rerun this script.
Expected default path: \$HOME/.claude
Override with: HOST_CLAUDE_DIR=/path/to/.claude $0 up"

  [ -s "$HOST_CLAUDE_JSON" ] || die "host Claude Code login file not found or empty: $HOST_CLAUDE_JSON

Run Claude Code on the host first and complete authentication, then rerun this script.
Expected default path: \$HOME/.claude.json
Override with: HOST_CLAUDE_JSON=$HOME/.claude.json $0 up"

  if [ -z "$(ls -A "$HOST_CLAUDE_DIR" 2>/dev/null || true)" ]; then
    die "host Claude Code auth directory is empty: $HOST_CLAUDE_DIR

Run Claude Code on the host first and complete authentication, then rerun this script."
  fi
}

# curl against the proxy, adding the bearer token only when an API key is set.
# Written without arrays so it stays correct under `set -u` on bash 3.2 (macOS).
proxy_curl() {
  if [ -n "$CLAUDE_CODE_PROXY_API_KEY" ]; then
    curl -fsS -H "Authorization: Bearer ${CLAUDE_CODE_PROXY_API_KEY}" "$@"
  else
    curl -fsS "$@"
  fi
}

hermes_curl() {
  curl -fsS -H "Authorization: Bearer ${HERMES_API_KEY}" "$@"
}

host_proxy_running() {
  [ -f "$HOST_PROXY_PID_FILE" ] && kill -0 "$(cat "$HOST_PROXY_PID_FILE")" >/dev/null 2>&1
}

stop_host_proxy() {
  if host_proxy_running; then
    local pid
    pid="$(cat "$HOST_PROXY_PID_FILE")"
    kill "$pid" >/dev/null 2>&1 || true
    rm -f "$HOST_PROXY_PID_FILE"
    log "stopped host proxy process $pid"
  fi
}

need_host_claude() {
  command -v claude >/dev/null 2>&1 || die "host claude command is not on PATH"
  command -v python3 >/dev/null 2>&1 || die "host python3 command is not on PATH"
}

# ----------------------------------------------------------------------------
# Build-context materialisation. Everything needed to build the image is
# written here from embedded heredocs; the canonical proxy is preferred if found.
# ----------------------------------------------------------------------------
resolve_proxy_src() {
  if [ -n "${CLAUDE_PROXY_SRC:-}" ] && [ -f "${CLAUDE_PROXY_SRC:-}" ]; then
    printf '%s' "$CLAUDE_PROXY_SRC"; return 0
  fi
  if [ -f "$SCRIPT_DIR/claude_code_proxy.py" ]; then
    printf '%s' "$SCRIPT_DIR/claude_code_proxy.py"; return 0
  fi
  if [ -f "$SCRIPT_DIR/../claude_code_proxy.py" ]; then
    printf '%s' "$SCRIPT_DIR/../claude_code_proxy.py"; return 0
  fi
  return 1
}

materialize_host_proxy_src() {
  local src generated
  if src="$(resolve_proxy_src)"; then
    printf '%s' "$src"
    return 0
  fi

  generated="$SCRIPT_DIR/.${STACK_NAME}-claude_code_proxy.py"
  embedded_proxy_py > "$generated"
  chmod 700 "$generated" 2>/dev/null || true
  log "using embedded host proxy source: $generated" >&2
  printf '%s' "$generated"
}

write_dockerfile() {
  cat > "$1/Dockerfile" <<DOCKER_EOF
# syntax=docker/dockerfile:1.7
# Hermes claude-code proxy image. Generated by docker-hermes-claude-bridge.sh.
ARG NODE_BASE=${NODE_BASE}
FROM \${NODE_BASE}

ARG CLAUDE_CODE_VERSION=${CLAUDE_CODE_VERSION}

# --- system + npm install (heavy, cached) ---------------------------------
# BuildKit cache mounts persist apt lists and the npm cache between builds,
# so re-installing the same versions is ~instant instead of a full re-download.
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \\
    --mount=type=cache,target=/var/lib/apt,sharing=locked \\
    --mount=type=cache,target=/root/.npm \\
    rm -f /etc/apt/apt.conf.d/docker-clean && \\
    apt-get update && \\
    apt-get install -y --no-install-recommends \\
        python3 curl ca-certificates bash tini && \\
    npm install -g @anthropic-ai/claude-code@\${CLAUDE_CODE_VERSION}

# Use the base image's non-root node user. On Linux this is usually UID 1000,
# which also makes host ~/.claude bind mounts readable for most developers.
RUN mkdir -p /app /workspace/.claude \\
 && chown -R node:node /app /workspace /home/node

# --- app code (changes often — copied AFTER the heavy layers so its changes
# don't bust the apt/npm cache). Final ownership/perm step is collapsed into
# the COPY itself via --chown / --chmod for fewer layers and ~100MB less in
# the layer cache compared to a follow-up chown.
COPY --chown=node:node --chmod=755 docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
COPY --chown=node:node --chmod=755 healthcheck.sh       /usr/local/bin/healthcheck.sh
COPY --chown=node:node             claude_code_proxy.py /app/claude_code_proxy.py

ENV HOME=/home/node \\
    CLAUDE_BIN=/usr/local/bin/claude \\
    CLAUDE_CODE_PROXY_CWD=/workspace \\
    PROXY_HOST=0.0.0.0 \\
    PROXY_PORT=18181 \\
    PYTHONUNBUFFERED=1

USER node
WORKDIR /workspace
EXPOSE 18181

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/docker-entrypoint.sh"]
HEALTHCHECK --interval=15s --timeout=3s --start-period=5s --retries=3 \\
  CMD ["/usr/local/bin/healthcheck.sh"]
DOCKER_EOF
}

write_entrypoint() {
  cat > "$1/docker-entrypoint.sh" <<'ENTRY_EOF'
#!/usr/bin/env bash
# Entrypoint for the claude-code proxy container.
# Builds the proxy command from environment variables (good defaults baked in),
# or runs an arbitrary command if one is passed (e.g. `bash`, `claude`).
set -euo pipefail

: "${PROXY_HOST:=0.0.0.0}"
: "${PROXY_PORT:=18181}"
: "${CLAUDE_BIN:=/usr/local/bin/claude}"
: "${CLAUDE_CODE_PROXY_CWD:=/workspace}"
: "${CLAUDE_CODE_PROXY_MODEL:=claude-opus-4-8}"
: "${CLAUDE_CODE_PASS_MODEL:=true}"
: "${CLAUDE_CODE_EFFORT:=max}"
: "${CLAUDE_CODE_PERMISSION_MODE:=dontAsk}"
: "${CLAUDE_CODE_MAX_BUDGET_USD:=1.00}"
: "${CLAUDE_CODE_DISALLOWED_TOOLS:=Bash,Edit,Write,NotebookEdit}"
: "${CLAUDE_CODE_ALLOWED_TOOLS:=}"
: "${CLAUDE_CODE_PROXY_API_KEY:=}"
: "${HOME:=/home/node}"

mkdir -p "$HOME" "$CLAUDE_CODE_PROXY_CWD/.claude"

# Seed a read-only Claude Code permission file if the workspace volume is empty.
# This is belt-and-suspenders: the proxy also passes the allow/deny lists on
# every request, which is the live enforcement point.
settings="$CLAUDE_CODE_PROXY_CWD/.claude/settings.local.json"
if [ ! -f "$settings" ]; then
  python3 - "$settings" "$CLAUDE_CODE_ALLOWED_TOOLS" "$CLAUDE_CODE_DISALLOWED_TOOLS" <<'PY'
import json, sys
path, allowed, denied = sys.argv[1], sys.argv[2], sys.argv[3]
split = lambda v: [x.strip() for x in v.split(",") if x.strip()]
with open(path, "w") as fh:
    json.dump({"permissions": {"allow": split(allowed), "deny": split(denied)}}, fh, indent=2)
    fh.write("\n")
PY
fi

# If a command was provided (docker run ... <cmd>), exec it instead of the proxy.
if [ "$#" -gt 0 ]; then
  exec "$@"
fi

set -- python3 /app/claude_code_proxy.py \
  --host "$PROXY_HOST" \
  --port "$PROXY_PORT" \
  --claude-bin "$CLAUDE_BIN" \
  --cwd "$CLAUDE_CODE_PROXY_CWD" \
  --model "$CLAUDE_CODE_PROXY_MODEL" \
  --effort "$CLAUDE_CODE_EFFORT" \
  --permission-mode "$CLAUDE_CODE_PERMISSION_MODE" \
  --disallowed-tools "$CLAUDE_CODE_DISALLOWED_TOOLS"

[ "${CLAUDE_CODE_PASS_MODEL:-true}" = "true" ] && set -- "$@" --pass-model
[ -n "$CLAUDE_CODE_ALLOWED_TOOLS" ]  && set -- "$@" --allowed-tools  "$CLAUDE_CODE_ALLOWED_TOOLS"
[ -n "$CLAUDE_CODE_MAX_BUDGET_USD" ] && set -- "$@" --max-budget-usd "$CLAUDE_CODE_MAX_BUDGET_USD"
[ -n "$CLAUDE_CODE_PROXY_API_KEY" ]  && set -- "$@" --api-key        "$CLAUDE_CODE_PROXY_API_KEY"

echo "[entrypoint] claude-code proxy -> ${PROXY_HOST}:${PROXY_PORT}" \
     "model=${CLAUDE_CODE_PROXY_MODEL} effort=${CLAUDE_CODE_EFFORT}" \
     "permission_mode=${CLAUDE_CODE_PERMISSION_MODE}" \
     "api_key_required=$([ -n "$CLAUDE_CODE_PROXY_API_KEY" ] && echo yes || echo no)"
exec "$@"
ENTRY_EOF
}

write_healthcheck() {
  cat > "$1/healthcheck.sh" <<'HC_EOF'
#!/bin/sh
# Container HEALTHCHECK: hit /health, carrying the bearer token when required.
PORT="${PROXY_PORT:-18181}"
if [ -n "${CLAUDE_CODE_PROXY_API_KEY:-}" ]; then
  exec curl -fsS -H "Authorization: Bearer ${CLAUDE_CODE_PROXY_API_KEY}" "http://127.0.0.1:${PORT}/health"
fi
exec curl -fsS "http://127.0.0.1:${PORT}/health"
HC_EOF
}

write_dockerignore() {
  cat > "$1/.dockerignore" <<'IGN_EOF'
*
!claude_code_proxy.py
!docker-entrypoint.sh
!healthcheck.sh
IGN_EOF
}

# Assemble a complete build context into $1.
populate_context() {
  local ctx="$1"
  write_dockerfile   "$ctx"
  write_entrypoint   "$ctx"
  write_healthcheck  "$ctx"
  write_dockerignore "$ctx"
  local src
  if src="$(resolve_proxy_src)"; then
    cp "$src" "$ctx/claude_code_proxy.py"
    log "using proxy source: $src"
  else
    embedded_proxy_py > "$ctx/claude_code_proxy.py"
    log "using embedded proxy source (no claude_code_proxy.py found nearby)"
  fi
}

# ----------------------------------------------------------------------------
# Commands
# ----------------------------------------------------------------------------
cmd_build() {
  need_docker
  local ctx; ctx="$(mktemp -d)"
  populate_context "$ctx"
  log "building image $IMAGE (claude-code ${CLAUDE_CODE_VERSION}, base ${NODE_BASE})"
  if DOCKER_BUILDKIT=1 docker build \
       --build-arg "NODE_BASE=${NODE_BASE}" \
       --build-arg "CLAUDE_CODE_VERSION=${CLAUDE_CODE_VERSION}" \
       -t "$IMAGE" "$ctx"; then
    rm -rf "$ctx"
    log "image built: $IMAGE"
  else
    local rc=$?
    rm -rf "$ctx"
    die "image build failed (exit $rc)"
  fi
}

image_exists() { docker image inspect "$IMAGE" >/dev/null 2>&1; }

proxy_running() { [ "$(docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null || echo false)" = "true" ]; }
hermes_running() { [ "$(docker inspect -f '{{.State.Running}}' "$HERMES_CONTAINER" 2>/dev/null || echo false)" = "true" ]; }

hermes_proxy_base_url() {
  if [ "$PROXY_RUNTIME" = "host" ]; then
    printf 'http://host.docker.internal:%s/v1' "$PROXY_PORT"
  else
    printf 'http://%s:%s/v1' "$CONTAINER" "$PROXY_PORT"
  fi
}

seed_proxy_home() {
  log "seeding proxy home volume $PROXY_HOME_VOLUME from host Claude Code auth"
  docker run --rm \
    --user root \
    --entrypoint /bin/bash \
    -v "${PROXY_HOME_VOLUME}:/home/node" \
    -v "${HOST_CLAUDE_DIR}:/host/.claude:ro" \
    -v "${HOST_CLAUDE_JSON}:/host/.claude.json:ro" \
    "$IMAGE" -lc '
      set -euo pipefail
      rm -rf /home/node/.claude
      mkdir -p /home/node
      cp -a /host/.claude /home/node/.claude
      cp /host/.claude.json /home/node/.claude.json
      chown -R node:node /home/node
      chmod 700 /home/node/.claude 2>/dev/null || true
      chmod 600 /home/node/.claude.json 2>/dev/null || true
    '
}

start_host_proxy() {
  need_host_claude
  local src claude_bin
  src="$(materialize_host_proxy_src)"
  claude_bin="$(command -v claude)"

  stop_host_proxy
  mkdir -p "$HOST_PROXY_WORKSPACE" "$HOST_PROXY_WORKSPACE/.claude"

  local -a cmd=(
    python3 "$src"
    --host "$HOST_PROXY_HOST"
    --port "$PROXY_PORT"
    --claude-bin "$claude_bin"
    --cwd "$HOST_PROXY_WORKSPACE"
    --model "$CLAUDE_CODE_PROXY_MODEL"
    --effort "$CLAUDE_CODE_EFFORT"
    --permission-mode "$CLAUDE_CODE_PERMISSION_MODE"
    --disallowed-tools "$CLAUDE_CODE_DISALLOWED_TOOLS"
  )
  [ "${CLAUDE_CODE_PASS_MODEL:-true}" = "true" ] && cmd+=( --pass-model )
  [ -n "$CLAUDE_CODE_ALLOWED_TOOLS" ]  && cmd+=( --allowed-tools "$CLAUDE_CODE_ALLOWED_TOOLS" )
  [ -n "$CLAUDE_CODE_MAX_BUDGET_USD" ] && cmd+=( --max-budget-usd "$CLAUDE_CODE_MAX_BUDGET_USD" )
  [ -n "$CLAUDE_CODE_PROXY_API_KEY" ]  && cmd+=( --api-key "$CLAUDE_CODE_PROXY_API_KEY" )

  log "starting host Claude Code proxy on ${HOST_PROXY_HOST}:${PROXY_PORT}"
  nohup "${cmd[@]}" </dev/null >"$HOST_PROXY_LOG_FILE" 2>&1 &
  echo $! > "$HOST_PROXY_PID_FILE"
  sleep 1
  host_proxy_running || {
    rm -f "$HOST_PROXY_PID_FILE"
    die "host proxy failed to start; see $HOST_PROXY_LOG_FILE"
  }
}

write_hermes_config() {
  docker run --rm \
    --entrypoint /bin/bash \
    -v "${HERMES_DATA_VOLUME}:/opt/data" \
    -e "CLAUDE_CODE_PROXY_API_KEY=${CLAUDE_CODE_PROXY_API_KEY}" \
    -e "CLAUDE_CODE_PROXY_MODEL=${CLAUDE_CODE_PROXY_MODEL}" \
    -e "PROXY_BASE_URL=$(hermes_proxy_base_url)" \
    "$HERMES_IMAGE" -lc '
      set -euo pipefail
      mkdir -p /opt/data
      /opt/hermes/.venv/bin/python - <<PY
import os
from pathlib import Path
import yaml

p = Path("/opt/data/config.yaml")
data = yaml.safe_load(p.read_text()) if p.exists() else {}
data = data or {}

base_url = os.environ["PROXY_BASE_URL"]
model = os.environ["CLAUDE_CODE_PROXY_MODEL"]
api_key = os.environ.get("CLAUDE_CODE_PROXY_API_KEY", "")

data["model"] = {
    "default": model,
    "provider": "claude-code-proxy",
    "base_url": base_url,
    "api_mode": "chat_completions",
}
providers = data.setdefault("providers", {})
providers["claude-code-proxy"] = {
    "name": "Claude Code Proxy",
    "base_url": base_url,
    "api_key": api_key,
    "default_model": model,
    "transport": "chat_completions",
}

p.write_text(yaml.safe_dump(data, sort_keys=False))
PY
      chown -R 10000:10000 /opt/data 2>/dev/null || true
    '
}

cmd_up() {
  need_docker
  case "$PROXY_RUNTIME" in
    host)
      if docker ps -a --format '{{.Names}}' | grep -qx "$CONTAINER"; then
        log "removing old proxy container $CONTAINER"
        docker rm -f "$CONTAINER" >/dev/null
      fi
      start_host_proxy
      ;;
    docker)
      require_host_claude_auth
      image_exists || cmd_build
      seed_proxy_home
      ;;
    *) die "unknown PROXY_RUNTIME=$PROXY_RUNTIME (use host or docker)" ;;
  esac

  docker network inspect "$NETWORK" >/dev/null 2>&1 || {
    log "creating docker network $NETWORK"
    docker network create "$NETWORK" >/dev/null
  }

  if [ "$PROXY_RUNTIME" = "docker" ]; then
    if docker ps -a --format '{{.Names}}' | grep -qx "$CONTAINER"; then
      log "removing existing container $CONTAINER"
      docker rm -f "$CONTAINER" >/dev/null
    fi

    local -a args=(
      run -d
      --name "$CONTAINER"
      --hostname "$CONTAINER"
      --restart unless-stopped
      --network "$NETWORK"
      --init
      -p "${PROXY_BIND}:${PROXY_PORT}:${PROXY_PORT}"
      -v "${PROXY_HOME_VOLUME}:/home/node"
      -v "${WORKSPACE_VOLUME}:/workspace"
      --tmpfs "/tmp:size=256m,exec"
      --memory "$MEMORY"
      --memory-swap "$MEMORY"
      --cpus "$CPUS"
      --pids-limit 256
      --user 1000:1000
      --cap-drop ALL
      --security-opt no-new-privileges:true
      --log-opt max-size=10m
      --log-opt max-file=3
      -e "PROXY_HOST=0.0.0.0"
      -e "PROXY_PORT=${PROXY_PORT}"
      -e "CLAUDE_CODE_PROXY_MODEL=${CLAUDE_CODE_PROXY_MODEL}"
      -e "CLAUDE_CODE_PASS_MODEL=${CLAUDE_CODE_PASS_MODEL}"
      -e "CLAUDE_CODE_EFFORT=${CLAUDE_CODE_EFFORT}"
      -e "CLAUDE_CODE_PERMISSION_MODE=${CLAUDE_CODE_PERMISSION_MODE}"
      -e "CLAUDE_CODE_MAX_BUDGET_USD=${CLAUDE_CODE_MAX_BUDGET_USD}"
      -e "CLAUDE_CODE_ALLOWED_TOOLS=${CLAUDE_CODE_ALLOWED_TOOLS}"
      -e "CLAUDE_CODE_DISALLOWED_TOOLS=${CLAUDE_CODE_DISALLOWED_TOOLS}"
    )
    [ -n "$CLAUDE_CODE_PROXY_API_KEY" ] && args+=( -e "CLAUDE_CODE_PROXY_API_KEY=${CLAUDE_CODE_PROXY_API_KEY}" )
    # Pass through corporate network proxy settings if present on the host.
    [ -n "${HTTP_PROXY:-}" ]  && args+=( -e "HTTP_PROXY=${HTTP_PROXY}" )
    [ -n "${HTTPS_PROXY:-}" ] && args+=( -e "HTTPS_PROXY=${HTTPS_PROXY}" )
    [ -n "${NO_PROXY:-}" ]    && args+=( -e "NO_PROXY=${NO_PROXY}" )
    args+=( "$IMAGE" )

    log "starting container $CONTAINER (published on ${PROXY_BIND}:${PROXY_PORT})"
    docker "${args[@]}" >/dev/null || die "failed to start proxy container $CONTAINER"
  fi

  log "writing Hermes config into volume $HERMES_DATA_VOLUME"
  write_hermes_config

  if docker ps -a --format '{{.Names}}' | grep -qx "$HERMES_CONTAINER"; then
    log "removing existing container $HERMES_CONTAINER"
    docker rm -f "$HERMES_CONTAINER" >/dev/null
  fi

  log "starting Hermes container $HERMES_CONTAINER (dashboard on ${HERMES_BIND}:${HERMES_DASHBOARD_PORT})"
  docker run -d \
    --name "$HERMES_CONTAINER" \
    --hostname "$HERMES_CONTAINER" \
    --restart unless-stopped \
    --network "$NETWORK" \
    --init \
    --add-host host.docker.internal:host-gateway \
    -p "${HERMES_BIND}:${HERMES_DASHBOARD_PORT}:9119" \
    -p "${HERMES_BIND}:${HERMES_API_PORT}:8642" \
    -v "${HERMES_DATA_VOLUME}:/opt/data" \
    --tmpfs "/tmp:size=256m" \
    -e HERMES_HOME=/opt/data \
    -e API_SERVER_ENABLED=true \
    -e API_SERVER_HOST=0.0.0.0 \
    -e API_SERVER_PORT=8642 \
    -e "API_SERVER_KEY=${HERMES_API_KEY}" \
    -e HERMES_DASHBOARD=1 \
    -e HERMES_DASHBOARD_HOST=0.0.0.0 \
    -e HERMES_DASHBOARD_PORT=9119 \
    -e HERMES_DASHBOARD_INSECURE=1 \
    -e HERMES_DASHBOARD_BASIC_AUTH_TTL_SECONDS=43200 \
    -e GATEWAY_ALLOW_ALL_USERS=true \
    -e HERMES_TUI_PROVIDER=claude-code-proxy \
    -e HERMES_INFERENCE_PROVIDER=claude-code-proxy \
    --memory 4g \
    --memory-swap 4g \
    --cpus 2 \
    --pids-limit 512 \
    --security-opt no-new-privileges:true \
    --log-opt max-size=10m \
    --log-opt max-file=3 \
    "$HERMES_IMAGE" gateway run >/dev/null \
    || die "failed to start Hermes container $HERMES_CONTAINER"

  sleep 1
  if [ "$PROXY_RUNTIME" = "docker" ]; then
    docker ps --filter "name=^/${CONTAINER}$" --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
  else
    log "host proxy pid: $(cat "$HOST_PROXY_PID_FILE")"
  fi
  docker ps --filter "name=^/${HERMES_CONTAINER}$" --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
  cat <<EOF

Done.

Open Hermes:
  http://${HERMES_BIND}:${HERMES_DASHBOARD_PORT}

Verify:
  $0 test

Proxy runtime:
  ${PROXY_RUNTIME}

Hermes provider base URL:
  $(hermes_proxy_base_url)
EOF
}

cmd_login() {
  need_docker
  if [ "$PROXY_RUNTIME" = "host" ]; then
    log "opening host Claude Code; complete /login if needed, then exit"
    claude || warn "interactive claude exited non-zero (ok if you completed /login)"
  else
    proxy_running || die "container '$CONTAINER' is not running; run: $0 up"
    log "opening Claude Code in $CONTAINER"
    docker exec -it -e HOME=/home/node "$CONTAINER" claude || \
      warn "interactive claude exited non-zero (ok if you completed /login)"
  fi
}

cmd_status() {
  need_docker
  if [ "$PROXY_RUNTIME" = "host" ]; then
    if host_proxy_running; then
      log "host proxy running: pid $(cat "$HOST_PROXY_PID_FILE")"
    else
      warn "host proxy is not running"
    fi
  else
    docker ps -a --filter "name=^/${CONTAINER}$" \
      --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}' || true
  fi
  docker ps -a --filter "name=^/${HERMES_CONTAINER}$" \
    --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}' || true
  if { [ "$PROXY_RUNTIME" = "host" ] && host_proxy_running; } || { [ "$PROXY_RUNTIME" = "docker" ] && proxy_running; }; then
    echo
    log "proxy health:"
    cmd_health || warn "health check failed (have you run '$0 login'? proxy still answers /health regardless)"
  fi
  if hermes_running; then
    echo
    log "Hermes health:"
    curl -fsS "http://127.0.0.1:${HERMES_API_PORT}/health" || warn "Hermes health failed"
    echo
  fi
}

cmd_health() {
  need_docker
  proxy_curl "http://127.0.0.1:${PROXY_PORT}/health"; echo
}

cmd_config() {
  need_docker
  proxy_curl "http://127.0.0.1:${PROXY_PORT}/config"; echo
}

cmd_test() {
  need_docker
  log "Proxy: GET /health"
  proxy_curl "http://127.0.0.1:${PROXY_PORT}/health"; echo
  log "Proxy: POST /v1/chat/completions"
  proxy_curl \
    -H 'content-type: application/json' \
    "http://127.0.0.1:${PROXY_PORT}/v1/chat/completions" \
    -d "{\"model\":\"${CLAUDE_CODE_PROXY_MODEL}\",\"messages\":[{\"role\":\"user\",\"content\":\"Reply with exactly: hermes claude-code proxy ok\"}],\"stream\":false}"
  echo
  log "Hermes: GET /health"
  curl -fsS "http://127.0.0.1:${HERMES_API_PORT}/health"; echo
  log "Hermes: POST /v1/chat/completions"
  hermes_curl \
    -H 'content-type: application/json' \
    "http://127.0.0.1:${HERMES_API_PORT}/v1/chat/completions" \
    -d "{\"model\":\"${CLAUDE_CODE_PROXY_MODEL}\",\"messages\":[{\"role\":\"user\",\"content\":\"Reply with exactly: hermes docker ok\"}],\"stream\":false}"
  echo
}

cmd_logs() {
  need_docker
  case "${1:-hermes}" in
    proxy)
      if [ "$PROXY_RUNTIME" = "host" ]; then
        touch "$HOST_PROXY_LOG_FILE"
        tail -f "$HOST_PROXY_LOG_FILE"
      else
        docker logs -f "$CONTAINER"
      fi
      ;;
    hermes) docker logs -f "$HERMES_CONTAINER" ;;
    *) die "unknown logs target: ${1:-} (use: logs hermes|proxy)" ;;
  esac
}

cmd_mcp_callback() {
  need_docker
  hermes_running || die "Hermes container '$HERMES_CONTAINER' is not running; run: $0 up"
  local callback_url="${1:-}"
  [ -n "$callback_url" ] || die "missing callback URL. Usage: $0 mcp-callback 'http://localhost:<port>/oauth/callback?state=...&code=...'"

  docker exec -e CALLBACK_URL="$callback_url" "$HERMES_CONTAINER" sh -lc 'curl -fsS "$CALLBACK_URL"'
  echo
  log "callback delivered to MCP OAuth listener"
}

cmd_mcp_status() {
  need_docker
  hermes_running || die "Hermes container '$HERMES_CONTAINER' is not running; run: $0 up"

  log "MCP config:"
  docker exec "$HERMES_CONTAINER" sh -lc '/opt/hermes/.venv/bin/python - <<'"'"'PY'"'"'
from pathlib import Path
import yaml

p = Path("/opt/data/config.yaml")
data = yaml.safe_load(p.read_text()) if p.exists() else {}
print(yaml.safe_dump({"mcp_servers": (data or {}).get("mcp_servers", {})}, sort_keys=False).strip())
PY'

  echo
  log "MCP auth cache:"
  docker exec "$HERMES_CONTAINER" sh -lc 'find /opt/data/.mcp-auth -maxdepth 3 -type f -printf "%p %s bytes\n" 2>/dev/null | sort || true'

  echo
  log "Recent MCP logs:"
  docker logs --since 10m "$HERMES_CONTAINER" 2>&1 | grep -Ei 'mcp|oauth|auth|callback|cancel|error|warning' || true
}

cmd_shell() {
  need_docker
  [ "$PROXY_RUNTIME" = "docker" ] || die "shell is only available when PROXY_RUNTIME=docker"
  proxy_running || die "proxy container not running"
  docker exec -it "$CONTAINER" bash
}
cmd_restart() {
  need_docker
  if [ "$PROXY_RUNTIME" = "host" ]; then
    start_host_proxy
    docker restart "$HERMES_CONTAINER" >/dev/null
    log "restarted host proxy and $HERMES_CONTAINER"
  else
    docker restart "$CONTAINER" "$HERMES_CONTAINER" >/dev/null
    log "restarted $CONTAINER and $HERMES_CONTAINER"
  fi
}

cmd_stop() {
  need_docker
  stop_host_proxy
  docker rm -f "$CONTAINER" >/dev/null 2>&1 && log "removed container $CONTAINER" || log "no container to remove"
  docker rm -f "$HERMES_CONTAINER" >/dev/null 2>&1 && log "removed container $HERMES_CONTAINER" || log "no Hermes container to remove"
  if [ "${1:-}" = "--purge" ]; then
    docker volume rm "$PROXY_HOME_VOLUME" "$WORKSPACE_VOLUME" "$HERMES_DATA_VOLUME" >/dev/null 2>&1 \
      && warn "purged volumes ${PROXY_HOME_VOLUME}, ${WORKSPACE_VOLUME}, ${HERMES_DATA_VOLUME} (host Claude auth was not touched)" \
      || true
  fi
}

cmd_open() {
  local url="http://${HERMES_BIND}:${HERMES_DASHBOARD_PORT}"
  log "opening $url"
  if command -v open >/dev/null 2>&1; then
    open "$url"
  elif command -v xdg-open >/dev/null 2>&1; then
    xdg-open "$url"
  else
    printf '%s\n' "$url"
  fi
}

cmd_extract() {
  local dir="${1:-$SCRIPT_DIR}"
  mkdir -p "$dir"
  write_dockerfile "$dir"
  write_entrypoint "$dir"
  write_healthcheck "$dir"
  write_dockerignore "$dir"
  if [ ! -f "$dir/claude_code_proxy.py" ]; then
    local src
    if src="$(resolve_proxy_src)"; then cp "$src" "$dir/claude_code_proxy.py"
    else embedded_proxy_py > "$dir/claude_code_proxy.py"; fi
  fi
  log "wrote build context to: $dir"
  ls -1 "$dir/Dockerfile" "$dir/docker-entrypoint.sh" "$dir/healthcheck.sh" "$dir/claude_code_proxy.py"
}

cmd_help() { sed -n '2,80p' "$0" | sed 's/^# \{0,1\}//'; }

main() {
  local cmd="${1:-help}"; shift || true

  # Mutating commands take an exclusive lock so two parallel invocations can't
  # race on container/network creation. Read-only commands skip the lock.
  case "$cmd" in
    build|up|start|run|login|stop|down|restart|extract|\
    mcp-callback)
      local lockfile="$SCRIPT_DIR/.${STACK_NAME}.lock"
      exec 200>"$lockfile" || die "cannot create lock file: $lockfile"
      command -v flock >/dev/null 2>&1 || die "flock(1) required (apt install util-linux)"
      flock -n 200 || die "another instance is holding $lockfile — refusing to run two ${cmd}s concurrently"
      ;;
  esac

  case "$cmd" in
    build)        cmd_build "$@" ;;
    up|start|run) cmd_up "$@" ;;
    login)        cmd_login "$@" ;;
    status)       cmd_status "$@" ;;
    health)       cmd_health "$@" ;;
    config)       cmd_config "$@" ;;
    test)         cmd_test "$@" ;;
    logs)         cmd_logs "$@" ;;
    open)         cmd_open "$@" ;;
    mcp-callback)                  cmd_mcp_callback "$@" ;;
    mcp-status)                    cmd_mcp_status "$@" ;;
    shell|exec)   cmd_shell "$@" ;;
    restart)      cmd_restart "$@" ;;
    stop)         cmd_stop "$@" ;;
    down)         cmd_stop "$@" ;;
    extract)      cmd_extract "$@" ;;
    help|-h|--help) cmd_help ;;
    *) die "unknown command: $cmd (try: $0 help)" ;;
  esac
}

# ----------------------------------------------------------------------------
# Embedded fallback copy of claude_code_proxy.py (used only when no canonical
# copy is found next to this script / in the parent dir / $CLAUDE_PROXY_SRC).
# Kept in sync with the standalone bridge; edit there and re-generate if needed.
# ----------------------------------------------------------------------------
embedded_proxy_py() {
  printf '%s\n' "$(cat <<'PROXY_PY'
#!/usr/bin/env python3
"""Small local OpenAI-compatible proxy for Hermes -> Claude Code CLI testing.

A minimal, dependency-free OpenAI-compatible proxy for Hermes custom providers.
It accepts /health, /v1/models and /v1/chat/completions, calls an authenticated
`claude -p`, and returns an OpenAI-style response for Hermes custom providers.
"""

from __future__ import annotations

import argparse
import hmac
import json
import os
import shlex
import subprocess
import time
import uuid
from pathlib import Path
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any


DEFAULT_CLAUDE_BIN = os.path.expanduser("~/.local/bin/claude")
DEFAULT_MODEL = "claude-opus-4-8"
# Claude Code model IDs advertised on /v1/models for discovery/UI. NOT a whitelist:
# with pass-model on, clients may request ANY valid Claude model ID. Override the
# advertised set with the CLAUDE_CODE_MODELS env var (comma-separated).
CLAUDE_CODE_MODELS = [
    m.strip()
    for m in os.getenv(
        "CLAUDE_CODE_MODELS",
        "claude-opus-4-8,claude-sonnet-5,claude-haiku-4-5,claude-fable-5",
    ).split(",")
    if m.strip()
]
DEFAULT_EFFORT = "medium"
DEFAULT_PERMISSION_MODE = "dontAsk"
DEFAULT_MAX_PROMPT_CHARS = 200_000


def _split_csv(value: str) -> list[str]:
    return [part.strip() for part in value.split(",") if part.strip()]


def _text_from_content(content: Any) -> str:
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        parts: list[str] = []
        for item in content:
            if isinstance(item, dict):
                if item.get("type") == "text" and isinstance(item.get("text"), str):
                    parts.append(item["text"])
            elif isinstance(item, str):
                parts.append(item)
        return "\n".join(parts)
    return "" if content is None else str(content)


def _prompt_from_messages(messages: list[dict[str, Any]]) -> str:
    sections: list[str] = []
    for message in messages:
        role = str(message.get("role") or "user")
        text = _text_from_content(message.get("content")).strip()
        if text:
            sections.append(f"{role.upper()}:\n{text}")
    return "\n\n".join(sections).strip()


def _safe_error_text(text: str) -> str:
    """Keep CLI errors useful while reducing accidental token leakage."""
    redacted = text.strip()
    for marker in ("sk-ant-", "Bearer ", "Authorization:", "api_key", "apiKey"):
        if marker in redacted:
            redacted = redacted.replace(marker, f"{marker[:3]}[redacted]")
    return redacted[-4000:]


def _looks_like_claude_model(model: str) -> bool:
    normalized = model.strip().lower()
    return normalized.startswith("claude-") or normalized.startswith("anthropic/")


class ClaudeProxyHandler(BaseHTTPRequestHandler):
    server_version = "ClaudeCodeProxy/0.2"

    def _send_json(self, code: int, payload: dict[str, Any]) -> None:
        body = json.dumps(payload).encode("utf-8")
        self.send_response(code)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _authorized(self) -> bool:
        expected = str(getattr(self.server, "api_key", "") or "")
        if not expected:
            return True

        auth_header = self.headers.get("authorization") or ""
        bearer = auth_header.removeprefix("Bearer ").strip()
        x_api_key = (self.headers.get("x-api-key") or "").strip()
        return hmac.compare_digest(bearer, expected) or hmac.compare_digest(x_api_key, expected)

    def _send_sse_completion(self, model: str, content: str) -> None:
        completion_id = f"chatcmpl-{uuid.uuid4().hex}"
        created = int(time.time())
        chunks = [
            {
                "id": completion_id,
                "object": "chat.completion.chunk",
                "created": created,
                "model": model,
                "choices": [{"index": 0, "delta": {"role": "assistant"}, "finish_reason": None}],
            },
            {
                "id": completion_id,
                "object": "chat.completion.chunk",
                "created": created,
                "model": model,
                "choices": [{"index": 0, "delta": {"content": content}, "finish_reason": None}],
            },
            {
                "id": completion_id,
                "object": "chat.completion.chunk",
                "created": created,
                "model": model,
                "choices": [{"index": 0, "delta": {}, "finish_reason": "stop"}],
            },
        ]
        self.send_response(200)
        self.send_header("content-type", "text/event-stream")
        self.send_header("cache-control", "no-cache")
        self.end_headers()
        for chunk in chunks:
            self.wfile.write(f"data: {json.dumps(chunk)}\n\n".encode("utf-8"))
        self.wfile.write(b"data: [DONE]\n\n")

    def log_message(self, fmt: str, *args: Any) -> None:
        print(f"[claude-code-proxy] {self.address_string()} - {fmt % args}", flush=True)

    def do_GET(self) -> None:
        if not self._authorized():
            self._send_json(401, {"error": {"message": "unauthorized"}})
            return

        if self.path.rstrip("/") == "/health":
            self._send_json(200, {"status": "ok"})
            return
        if self.path.rstrip("/") == "/config":
            self._send_json(
                200,
                {
                    "status": "ok",
                    "model": self.server.default_model,  # type: ignore[attr-defined]
                    "claude_bin": self.server.claude_bin,  # type: ignore[attr-defined]
                    "cwd": self.server.cwd,  # type: ignore[attr-defined]
                    "settings_local": self.server.settings_local,  # type: ignore[attr-defined]
                    "settings_local_exists": Path(self.server.settings_local).exists(),  # type: ignore[attr-defined]
                    "effort": self.server.effort,  # type: ignore[attr-defined]
                    "permission_mode": self.server.permission_mode,  # type: ignore[attr-defined]
                    "allowed_tools": self.server.allowed_tools,  # type: ignore[attr-defined]
                    "disallowed_tools": self.server.disallowed_tools,  # type: ignore[attr-defined]
                    "max_budget_usd": self.server.max_budget_usd,  # type: ignore[attr-defined]
                    "max_prompt_chars": self.server.max_prompt_chars,  # type: ignore[attr-defined]
                    "pass_model": self.server.pass_model,  # type: ignore[attr-defined]
                    "api_key_required": bool(getattr(self.server, "api_key", "") or ""),
                },
            )
            return
        if self.path.rstrip("/") == "/v1/models":
            seen: list[str] = []
            for mid in [self.server.default_model, *CLAUDE_CODE_MODELS]:  # type: ignore[attr-defined]
                if mid and mid not in seen:
                    seen.append(mid)
            self._send_json(
                200,
                {
                    "object": "list",
                    "data": [
                        {"id": mid, "object": "model", "created": 0, "owned_by": "claude-code-cli"}
                        for mid in seen
                    ],
                },
            )
            return
        path_only = self.path.rstrip("/")
        if path_only.startswith("/v1/models/"):
            mid = path_only[len("/v1/models/"):]
            if mid == self.server.default_model or mid in CLAUDE_CODE_MODELS or _looks_like_claude_model(mid):  # type: ignore[attr-defined]
                self._send_json(
                    200,
                    {"id": mid, "object": "model", "created": 0, "owned_by": "claude-code-cli"},
                )
                return
        self._send_json(404, {"error": {"message": "not found"}})

    def do_POST(self) -> None:
        if not self._authorized():
            self._send_json(401, {"error": {"message": "unauthorized"}})
            return

        if self.path.rstrip("/") != "/v1/chat/completions":
            self._send_json(404, {"error": {"message": "not found"}})
            return

        try:
            length = int(self.headers.get("content-length") or "0")
            body = self.rfile.read(length)
            request = json.loads(body.decode("utf-8"))
        except Exception as exc:
            self._send_json(400, {"error": {"message": f"invalid json: {exc}"}})
            return

        model = str(request.get("model") or self.server.default_model)  # type: ignore[attr-defined]
        if self.server.pass_model and not _looks_like_claude_model(model):  # type: ignore[attr-defined]
            self._send_json(
                400,
                {
                    "error": {
                        "message": (
                            f"model {model!r} cannot be run by claude-code-proxy. "
                            "This proxy executes the Claude Code CLI and only supports Claude model IDs. "
                            "Configure a Hermes provider that can serve the selected model."
                        )
                    }
                },
            )
            return

        prompt = _prompt_from_messages(request.get("messages") or [])
        if not prompt:
            self._send_json(400, {"error": {"message": "request has no prompt text"}})
            return

        max_prompt_chars = int(getattr(self.server, "max_prompt_chars", DEFAULT_MAX_PROMPT_CHARS))
        if len(prompt) > max_prompt_chars:
            self._send_json(
                413,
                {
                    "error": {
                        "message": f"prompt too large: {len(prompt)} chars exceeds {max_prompt_chars}"
                    }
                },
            )
            return

        allowed_tools = list(getattr(self.server, "allowed_tools", []) or [])
        disallowed_tools = list(getattr(self.server, "disallowed_tools", []) or [])
        cmd = [
            self.server.claude_bin,  # type: ignore[attr-defined]
            "--model",
            model if self.server.pass_model else self.server.default_model,  # type: ignore[attr-defined]
            "--effort",
            self.server.effort,  # type: ignore[attr-defined]
            "--permission-mode",
            self.server.permission_mode,  # type: ignore[attr-defined]
            "--no-session-persistence",
            "--output-format",
            "text",
        ]
        if self.server.max_budget_usd:  # type: ignore[attr-defined]
            cmd.extend(["--max-budget-usd", str(self.server.max_budget_usd)])  # type: ignore[attr-defined]
        if allowed_tools and allowed_tools != ["*"]:
            cmd.extend(["--allowedTools", ",".join(allowed_tools)])
        if disallowed_tools:
            cmd.extend(["--disallowedTools", ",".join(disallowed_tools)])
        if self.server.append_system_prompt:  # type: ignore[attr-defined]
            cmd.extend(["--append-system-prompt", self.server.append_system_prompt])  # type: ignore[attr-defined]
        cmd.extend(["-p", prompt])

        started = time.time()
        try:
            result = subprocess.run(
                cmd,
                cwd=self.server.cwd,  # type: ignore[attr-defined]
                text=True,
                capture_output=True,
                timeout=self.server.timeout_seconds,  # type: ignore[attr-defined]
            )
        except subprocess.TimeoutExpired:
            self._send_json(504, {"error": {"message": "claude command timed out"}})
            return

        latency_ms = int((time.time() - started) * 1000)
        print(
            f"[claude-code-proxy] model={model} chars={len(prompt)} "
            f"tools={len(allowed_tools)} exit={result.returncode} latency_ms={latency_ms}",
            flush=True,
        )

        if result.returncode != 0:
            message = _safe_error_text(result.stderr or result.stdout or "claude command failed")
            self._send_json(502, {"error": {"message": message, "exit_code": result.returncode}})
            return

        content = result.stdout.strip()
        if request.get("stream") is True:
            self._send_sse_completion(model, content)
            return

        self._send_json(
            200,
            {
                "id": f"chatcmpl-{uuid.uuid4().hex}",
                "object": "chat.completion",
                "created": int(time.time()),
                "model": model,
                "choices": [
                    {
                        "index": 0,
                        "message": {"role": "assistant", "content": content},
                        "finish_reason": "stop",
                    }
                ],
                "usage": {
                    "prompt_tokens": 0,
                    "completion_tokens": 0,
                    "total_tokens": 0,
                },
            },
        )


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", default="0.0.0.0")
    parser.add_argument("--port", type=int, default=18181)
    parser.add_argument("--claude-bin", default=os.getenv("CLAUDE_BIN", DEFAULT_CLAUDE_BIN))
    parser.add_argument("--cwd", default=os.getenv("CLAUDE_CODE_PROXY_CWD", os.getcwd()))
    parser.add_argument("--model", default=os.getenv("CLAUDE_CODE_PROXY_MODEL", DEFAULT_MODEL))
    parser.add_argument(
        "--allowed-tools",
        default=os.getenv("CLAUDE_CODE_ALLOWED_TOOLS", ""),
        help="Comma-separated Claude Code tool allowlist (empty means no allowlist).",
    )
    parser.add_argument(
        "--disallowed-tools",
        default=os.getenv("CLAUDE_CODE_DISALLOWED_TOOLS", "Bash,Edit,Write"),
        help="Comma-separated denylist. Defaults block shell/file mutation through Claude Code.",
    )
    parser.add_argument("--effort", default=os.getenv("CLAUDE_CODE_EFFORT", DEFAULT_EFFORT))
    parser.add_argument(
        "--permission-mode",
        default=os.getenv("CLAUDE_CODE_PERMISSION_MODE", DEFAULT_PERMISSION_MODE),
        choices=["acceptEdits", "auto", "bypassPermissions", "default", "dontAsk", "plan"],
    )
    parser.add_argument("--max-budget-usd", default=os.getenv("CLAUDE_CODE_MAX_BUDGET_USD", ""))
    parser.add_argument(
        "--max-prompt-chars",
        type=int,
        default=int(os.getenv("CLAUDE_CODE_MAX_PROMPT_CHARS", str(DEFAULT_MAX_PROMPT_CHARS))),
    )
    parser.add_argument(
        "--append-system-prompt",
        default=os.getenv(
            "CLAUDE_CODE_APPEND_SYSTEM_PROMPT",
            "You are being called by Hermes through a local proxy. Use only explicitly allowed tools. "
            "Do not create, update, delete, transition, comment, or write unless the user asks and the "
            "tool is explicitly allowed.",
        ),
    )
    parser.add_argument("--api-key", default=os.getenv("CLAUDE_CODE_PROXY_API_KEY", ""))
    parser.add_argument("--timeout", type=int, default=240)
    parser.add_argument("--pass-model", action="store_true")
    args = parser.parse_args()

    if not os.path.exists(args.claude_bin):
        raise SystemExit(f"claude binary not found: {args.claude_bin}")
    if not os.path.isdir(args.cwd):
        raise SystemExit(f"working directory not found: {args.cwd}")

    server = ThreadingHTTPServer((args.host, args.port), ClaudeProxyHandler)
    server.claude_bin = args.claude_bin  # type: ignore[attr-defined]
    server.cwd = args.cwd  # type: ignore[attr-defined]
    server.settings_local = str(Path(args.cwd) / ".claude" / "settings.local.json")  # type: ignore[attr-defined]
    server.default_model = args.model  # type: ignore[attr-defined]
    server.timeout_seconds = args.timeout  # type: ignore[attr-defined]
    server.pass_model = args.pass_model  # type: ignore[attr-defined]
    server.allowed_tools = _split_csv(args.allowed_tools)  # type: ignore[attr-defined]
    server.disallowed_tools = _split_csv(args.disallowed_tools)  # type: ignore[attr-defined]
    server.effort = args.effort  # type: ignore[attr-defined]
    server.permission_mode = args.permission_mode  # type: ignore[attr-defined]
    server.max_budget_usd = args.max_budget_usd  # type: ignore[attr-defined]
    server.max_prompt_chars = args.max_prompt_chars  # type: ignore[attr-defined]
    server.append_system_prompt = args.append_system_prompt  # type: ignore[attr-defined]
    server.api_key = args.api_key  # type: ignore[attr-defined]
    printable_cmd = shlex.join([args.claude_bin, "--model", args.model, "--effort", args.effort, "-p", "..."])
    print(
        f"[claude-code-proxy] listening on http://{args.host}:{args.port}/v1 "
        f"model={args.model} claude_bin={args.claude_bin} "
        f"cwd={args.cwd} settings_local={server.settings_local} "  # type: ignore[attr-defined]
        f"effort={args.effort} permission_mode={args.permission_mode} "
        f"allowed_tools={server.allowed_tools or '(none)'} "  # type: ignore[attr-defined]
        f"disallowed_tools={server.disallowed_tools or '(none)'} "  # type: ignore[attr-defined]
        f"api_key_required={bool(args.api_key)} command={printable_cmd}",
        flush=True,
    )
    server.serve_forever()


if __name__ == "__main__":
    main()

PROXY_PY
)"
}

main "$@"
