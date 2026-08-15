#!/usr/bin/env bash
# Generate every secret this stack needs and write them to .env.
#
#   ./generate.sh              generate secrets, keep any existing .env as .env.bak
#   ./generate.sh --print      re-print the secrets already in .env, generate nothing
#   ./generate.sh --key-only   only fetch/refresh NINEROUTER_API_KEY from a running 9Router
#   ./generate.sh --up         do everything: secrets, compose up, key, cache warm
#   ./generate.sh --rotate     force-regenerate everything (invalidates issued 9Router API keys)
#
# The Hermes dashboard hash is scrypt and can ONLY be produced by the Hermes
# image itself, so a container engine must be running.
set -euo pipefail

cd "$(dirname "$0")"

HERMES_IMAGE="${HERMES_IMAGE:-nousresearch/hermes-agent:v2026.8.13}"
ENV_FILE=".env"
CREDS_FILE="${CREDS_FILE:-}"

c_ok=$'\033[32m'; c_warn=$'\033[33m'; c_key=$'\033[36m'; c_off=$'\033[0m'

die() { printf '%s🛑 %s%s\n' "$c_warn" "$1" "$c_off" >&2; exit 1; }

# Read a KEY=value out of .env, unescaping Compose's doubled $$.
env_get() {
  [ -f "$ENV_FILE" ] || return 0
  sed -n "s/^$1=//p" "$ENV_FILE" | tail -1 | sed 's/\$\$/$/g'
}

print_secrets() {
  local pass hash secret apikey nrkey jwt aks salt initpw
  pass=$(env_get HERMES_DASHBOARD_PASSWORD_PLAINTEXT)
  hash=$(env_get HERMES_DASHBOARD_PASSWORD_HASH)
  secret=$(env_get HERMES_DASHBOARD_SECRET)
  apikey=$(env_get HERMES_API_SERVER_KEY)
  nrkey=$(env_get NINEROUTER_API_KEY)
  jwt=$(env_get JWT_SECRET)
  aks=$(env_get API_KEY_SECRET)
  salt=$(env_get MACHINE_ID_SALT)
  initpw=$(env_get INITIAL_PASSWORD)

  cat <<EOF

${c_ok}━━━ 9Router ━━━${c_off}
  dashboard      http://localhost:8080
  password       ${c_key}${initpw}${c_off}
  api key        ${c_key}${nrkey:-<not fetched yet — start the stack, then ./generate.sh --key-only>}${c_off}
  JWT_SECRET     ${jwt}
  API_KEY_SECRET ${aks}
  MACHINE_ID_SALT ${salt}

${c_ok}━━━ Hermes ━━━${c_off}
  dashboard      http://localhost:9119/login
  username       admin
  password       ${c_key}${pass}${c_off}
  api (loopback) http://127.0.0.1:8642
  api key        ${c_key}${apikey}${c_off}
  session secret ${secret}
  password hash  ${hash}

${c_warn}Stored in $(pwd)/${ENV_FILE} (gitignored). The Hermes password is not
recoverable from the hash — keep it somewhere safe.${c_off}
EOF
}

# A key that merely EXISTS is not enough: 9Router purges keys whose machine id
# no longer matches, so a stored key can be present and dead. Test it.
key_is_valid() {
  [ -n "$1" ] || return 1
  [ "$(docker compose exec -T hermes sh -lc "curl -s -o /dev/null -w '%{http_code}' -H 'Authorization: Bearer $1' http://9router:8080/v1/models" 2>/dev/null | tr -d '\r')" = "200" ]
}

# Hermes discovers 9Router's ~690 models on demand and caches them. A fresh
# install has an empty cache, so the picker shows only the configured default
# ("9router · 1 models") until something triggers discovery. Do it here instead
# of making the user find the Refresh Models button.
warm_model_cache() {
  local pass port jar count
  pass="$(env_get HERMES_DASHBOARD_PASSWORD_PLAINTEXT)"
  port="$(env_get HERMES_DASHBOARD_HOST_PORT)"; port="${port:-9119}"
  [ -n "$pass" ] || return 0
  docker compose ps --status running 2>/dev/null | grep -q hermes || return 0
  jar="$(mktemp)"
  curl -sf -o /dev/null -c "$jar" -X POST -H 'Content-Type: application/json' \
    -d "{\"provider\":\"basic\",\"username\":\"admin\",\"password\":\"$pass\",\"next\":\"/\"}" \
    "http://localhost:$port/auth/password-login" 2>/dev/null || { rm -f "$jar"; return 0; }
  count="$(curl -sf -b "$jar" "http://localhost:$port/api/model/options?refresh=true" 2>/dev/null \
    | python3 -c 'import json,sys
d=json.load(sys.stdin)
print(max([len(p.get("models") or []) for p in d.get("providers",[]) if "9Router" in (p.get("name") or "")] or [0]))' 2>/dev/null || echo 0)"
  rm -f "$jar"
  [ "${count:-0}" -gt 1 ] && printf '%s✅ model catalog warmed — 9Router shows %s models%s\n' "$c_ok" "$count" "$c_off"
  return 0
}

fetch_9router_key() {
  local pw key
  pw="$(env_get INITIAL_PASSWORD)"; pw="${pw:-changeme123}"
  docker compose ps --status running 2>/dev/null | grep -q 9router || {
    printf '%s⏭  9Router not running — skipping key fetch. Start it, then: ./generate.sh --key-only%s\n' "$c_warn" "$c_off"
    return 0
  }
  # Wait for it to actually answer: it accepts connections before it can serve
  # /api/auth/login on first boot, and racing that just silently skips the mint.
  local i=0
  until curl -sf -o /dev/null "http://localhost:8080/login" 2>/dev/null || [ $i -ge 60 ]; do
    sleep 2; i=$((i+1))
  done
  local jar; jar="$(mktemp)"
  curl -sf -c "$jar" -X POST -H 'Content-Type: application/json' \
    -d "{\"password\":\"$pw\"}" http://localhost:8080/api/auth/login >/dev/null 2>&1 || {
      rm -f "$jar"
      printf '%s⏭  Could not log in to 9Router (password changed?) — fetch the key from Endpoint & Key%s\n' "$c_warn" "$c_off"
      return 0
    }
  key="$(curl -sf -b "$jar" http://localhost:8080/api/keys 2>/dev/null \
    | python3 -c 'import json,sys; d=json.load(sys.stdin); k=d.get("keys") or []; print(k[0]["key"] if k else "")' 2>/dev/null || true)"

  # Keep a stored key only if it still authenticates.
  if [ -n "$key" ] && ! key_is_valid "$key"; then
    printf '%s♻️  stored 9Router key no longer authenticates — minting a replacement%s\n' "$c_warn" "$c_off"
    key=""
  fi

  # A freshly initialised 9Router has no keys at all — mint one.
  if [ -z "$key" ]; then
    key="$(curl -sf -b "$jar" -X POST -H 'Content-Type: application/json' \
      -d '{"name":"hermes"}' http://localhost:8080/api/keys 2>/dev/null \
      | python3 -c 'import json,sys; print(json.load(sys.stdin).get("key",""))' 2>/dev/null || true)"
    [ -n "$key" ] && printf '%s🆕 created a 9Router API key named "hermes"%s\n' "$c_ok" "$c_off"
  fi
  rm -f "$jar"
  [ -n "$key" ] || { printf '%s⏭  Could not obtain a 9Router API key — create one under Endpoint & Key%s\n' "$c_warn" "$c_off"; return 0; }

  # Replace any existing line rather than appending a duplicate.
  if [ -f "$ENV_FILE" ]; then
    grep -v '^NINEROUTER_API_KEY=' "$ENV_FILE" > "$ENV_FILE.tmp" || true
    mv "$ENV_FILE.tmp" "$ENV_FILE"
  fi
  printf 'NINEROUTER_API_KEY=%s\n' "$key" >> "$ENV_FILE"
  printf '%s✅ NINEROUTER_API_KEY fetched from the running 9Router%s\n' "$c_ok" "$c_off"

  # Hermes reads the key from its environment at start, so a running container
  # is still holding the old value. Recreate it (restart re-uses the old env)
  # before anything tries to use the new key.
  if docker compose ps --status running 2>/dev/null | grep -q hermes; then
    printf '♻️  recreating hermes so it picks up the key…\n'
    docker compose up -d --force-recreate hermes >/dev/null 2>&1 || true
    local i=0
    while [ "$(docker inspect --format '{{.State.Health.Status}}' hermes 2>/dev/null)" = "starting" ] && [ $i -lt 40 ]; do
      sleep 3; i=$((i+1))
    done
  fi
}

ROTATE=0
UP=0
case "${1:-}" in
  --up)       UP=1 ;;
  --print)    [ -f "$ENV_FILE" ] || die "no $ENV_FILE yet — run ./generate.sh first"; print_secrets; exit 0 ;;
  --key-only) fetch_9router_key; warm_model_cache; print_secrets; exit 0 ;;
  --rotate)   ROTATE=1 ;;
  "")         ;;
  *)          die "unknown option: $1 (use --up, --print, --key-only or --rotate)" ;;
esac

command -v docker >/dev/null || die "docker not found"
docker info >/dev/null 2>&1 || die "no running container engine — start Docker Desktop or OrbStack"
command -v openssl >/dev/null || die "openssl not found"

printf '⏳ pulling %s (skipped if present)…\n' "$HERMES_IMAGE"
docker image inspect "$HERMES_IMAGE" >/dev/null 2>&1 || docker pull -q "$HERMES_IMAGE" >/dev/null

if [ -f "$ENV_FILE" ]; then
  cp "$ENV_FILE" "$ENV_FILE.bak"
  printf '%s📦 existing %s backed up to %s.bak%s\n' "$c_warn" "$ENV_FILE" "$ENV_FILE" "$c_off"
fi

# Every 9Router secret is bound to its data volume and must survive re-runs:
#
#   INITIAL_PASSWORD  applied only when the volume is first initialised
#   MACHINE_ID_SALT   derives /app/data/machine-id. Change it and 9Router
#                     rewrites that file and PURGES every API key bound to the
#                     old id — issued keys vanish from the apiKeys table and
#                     start returning 401
#   API_KEY_SECRET    the HMAC that signs issued keys; rotating it invalidates them
#   JWT_SECRET        signs dashboard sessions; rotating it logs you out
#
# So reuse whatever is already in .env, and only mint what is missing.
# `--rotate` forces new values — expect to re-run `--key-only` afterwards.
keep_or_new() {  # keep_or_new <VAR> <generator...>
  local existing; existing="$(env_get "$1")"
  if [ -n "$existing" ] && [ "$ROTATE" != "1" ]; then printf '%s' "$existing"; else shift; "$@"; fi
}

NINEROUTER_PASS="$(keep_or_new INITIAL_PASSWORD openssl rand -hex 12)"
NINEROUTER_SALT="$(keep_or_new MACHINE_ID_SALT openssl rand -hex 16)"
NINEROUTER_AKS="$(keep_or_new API_KEY_SECRET  openssl rand -hex 32)"
NINEROUTER_JWT="$(keep_or_new JWT_SECRET      openssl rand -hex 32)"

if [ -f "$ENV_FILE" ] && [ "$ROTATE" != "1" ]; then
  printf '%s♻️  reusing the existing 9Router secrets — rotating MACHINE_ID_SALT or\n   API_KEY_SECRET would invalidate every issued API key. Force with --rotate.%s\n' "$c_warn" "$c_off"
fi

KEEP_NR_KEY="$(env_get NINEROUTER_API_KEY)"
[ "$ROTATE" = "1" ] && KEEP_NR_KEY=""

HERMES_PASS="$(openssl rand -hex 24)"
printf '⏳ hashing the Hermes dashboard password with scrypt…\n'
HERMES_HASH="$(docker run --rm --entrypoint /opt/hermes/.venv/bin/python \
  -e PYTHONPATH=/opt/hermes -e P="$HERMES_PASS" "$HERMES_IMAGE" \
  -c 'import os;from plugins.dashboard_auth.basic import hash_password;print(hash_password(os.environ["P"]))')"
[ -n "$HERMES_HASH" ] || die "hash generation produced nothing — is $HERMES_IMAGE the right tag?"

# Compose interpolates $ in .env values, so every literal $ must be doubled.
HERMES_HASH_ESCAPED="$(printf '%s' "$HERMES_HASH" | sed 's/\$/$$/g')"

cat > "$ENV_FILE" <<EOF
# Generated by ./generate.sh on $(date -u '+%Y-%m-%dT%H:%M:%SZ'). Do not commit.
# Re-print these values any time with: ./generate.sh --print

# ── 9Router ──────────────────────────────────────────────────────────
INITIAL_PASSWORD=$NINEROUTER_PASS
JWT_SECRET=$NINEROUTER_JWT
API_KEY_SECRET=$NINEROUTER_AKS
MACHINE_ID_SALT=$NINEROUTER_SALT

# ── Hermes dashboard ─────────────────────────────────────────────────
# The hash is scrypt; \$ is doubled to \$\$ so Compose passes it through intact.
HERMES_DASHBOARD_USERNAME=admin
HERMES_DASHBOARD_PASSWORD_HASH=$HERMES_HASH_ESCAPED
HERMES_DASHBOARD_SECRET=$(openssl rand -hex 32)
# Kept only so --print can show it. Hermes never reads this key.
HERMES_DASHBOARD_PASSWORD_PLAINTEXT=$HERMES_PASS

# ── Hermes API (loopback only by default) ────────────────────────────
HERMES_API_SERVER_KEY=$(openssl rand -hex 32)
EOF

# Carry a working 9Router key forward; --key-only refreshes it on demand.
if [ -n "$KEEP_NR_KEY" ]; then
  printf 'NINEROUTER_API_KEY=%s\n' "$KEEP_NR_KEY" >> "$ENV_FILE"
fi

chmod 600 "$ENV_FILE"
printf '%s✅ wrote %s%s\n' "$c_ok" "$ENV_FILE" "$c_off"

# Always (re)check the key: an empty or stale one is never useful — Hermes comes
# up healthy and 401s every model call, which surfaces only as a 1-model picker.
if [ "$UP" = "1" ]; then
  printf '⏳ starting the stack…\n'
  docker compose up -d >/dev/null 2>&1 || die "docker compose up failed"
  i=0
  while [ "$(docker inspect --format '{{.State.Health.Status}}' 9router 2>/dev/null)" != "healthy" ] && [ $i -lt 60 ]; do
    sleep 3; i=$((i+1))
  done
fi

fetch_9router_key
# One retry: on a cold start 9Router can still be initialising when the first
# attempt runs, and a silent skip leaves a dead key behind.
if [ "$UP" = "1" ] && ! key_is_valid "$(env_get NINEROUTER_API_KEY)"; then
  printf '%s↻ key not usable yet — retrying once%s\n' "$c_warn" "$c_off"
  sleep 10
  fetch_9router_key
fi
warm_model_cache

if [ "$UP" = "1" ]; then
  if key_is_valid "$(env_get NINEROUTER_API_KEY)"; then
    printf '%s✅ verified: Hermes can reach 9Router%s\n' "$c_ok" "$c_off"
  else
    printf '%s🛑 the 9Router key still does not authenticate — run ./generate.sh --key-only%s\n' "$c_warn" "$c_off"
  fi
fi

if [ -n "$CREDS_FILE" ]; then
  mkdir -p "$(dirname "$CREDS_FILE")"
  print_secrets > "$CREDS_FILE"
  chmod 600 "$CREDS_FILE"
  printf '%s✅ also written to %s%s\n' "$c_ok" "$CREDS_FILE" "$c_off"
fi

print_secrets

cat <<EOF
${c_ok}Next:${c_off}
  docker compose up -d --force-recreate
  ./generate.sh --key-only     # once 9Router is up, to capture its API key
EOF
