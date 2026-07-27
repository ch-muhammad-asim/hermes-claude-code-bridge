#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
#  Generate (and optionally apply) every Secret the OmniRoute + Hermes stack needs.
#
#  It prints a "SAVE THIS" block with the two dashboard passwords, because those are
#  the only values you cannot recover later — everything else is regenerable.
#
#    ./generate-secrets.sh                 # generate, print, and apply to the cluster
#    ./generate-secrets.sh --print-only    # generate and print, apply nothing
#    ./generate-secrets.sh -n my-namespace # target a different namespace
#
#  Requires: openssl, kubectl, and docker (only for the Hermes dashboard hash, which
#  must come from Hermes' own scrypt hasher in the matching image).
# ──────────────────────────────────────────────────────────────────────────────
set -euo pipefail

NAMESPACE="omniroute"
HERMES_IMAGE="nousresearch/hermes-agent:v2026.7.20"
APPLY=1

while [ $# -gt 0 ]; do
  case "$1" in
    --print-only) APPLY=0; shift ;;
    -n|--namespace) NAMESPACE="${2:?--namespace needs a value}"; shift 2 ;;
    --hermes-image) HERMES_IMAGE="${2:?--hermes-image needs a value}"; shift 2 ;;
    -h|--help) sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown argument: $1 (try --help)" >&2; exit 64 ;;
  esac
done

need() { command -v "$1" >/dev/null 2>&1 || { echo "missing required tool: $1" >&2; exit 1; }; }
need openssl
[ "$APPLY" -eq 1 ] && need kubectl

pw() { openssl rand -base64 24 | tr -d '/+=' | cut -c1-24; }

# ── Generate ────────────────────────────────────────────────────────────────
OMNIROUTE_DASHBOARD_PASSWORD="$(pw)"          # INITIAL_PASSWORD — first-boot login
JWT_SECRET="$(openssl rand -base64 48)"
API_KEY_SECRET="$(openssl rand -hex 32)"
STORAGE_ENCRYPTION_KEY="$(openssl rand -hex 32)"   # optional, see note below

HERMES_DASHBOARD_PASSWORD="$(pw)"
API_SERVER_KEY="$(openssl rand -hex 32)"
HERMES_DASHBOARD_BASIC_AUTH_SECRET="$(openssl rand -hex 32)"

# Hermes hashes dashboard passwords with scrypt. The hash MUST come from its own
# hash_password() in the same image the StatefulSet runs — a generic bcrypt/sha256 hash
# applies cleanly and then silently rejects every login. --entrypoint is required, or
# the image's s6-overlay init boots the supervisor and pollutes stdout.
HERMES_DASHBOARD_BASIC_AUTH_PASSWORD_HASH=""
if command -v docker >/dev/null 2>&1; then
  echo "Hashing the Hermes dashboard password with $HERMES_IMAGE …" >&2
  HERMES_DASHBOARD_BASIC_AUTH_PASSWORD_HASH="$(
    docker run --rm \
      --entrypoint /opt/hermes/.venv/bin/python \
      -e PYTHONPATH=/opt/hermes \
      -e HERMES_DASHBOARD_PASSWORD="$HERMES_DASHBOARD_PASSWORD" \
      "$HERMES_IMAGE" \
      -c 'import os; from plugins.dashboard_auth.basic import hash_password; print(hash_password(os.environ["HERMES_DASHBOARD_PASSWORD"]))' \
      2>/dev/null | tail -1
  )"
fi
case "$HERMES_DASHBOARD_BASIC_AUTH_PASSWORD_HASH" in
  scrypt\$*) : ;;
  *) echo "WARNING: could not produce a scrypt hash (is docker running?). The Hermes secret will be created without a working dashboard password." >&2
     HERMES_DASHBOARD_BASIC_AUTH_PASSWORD_HASH="" ;;
esac

# ── Print ───────────────────────────────────────────────────────────────────
cat <<EOF

╔══════════════════════════════════════════════════════════════════════════════╗
║  SAVE THIS — the passwords below cannot be recovered later                    ║
╚══════════════════════════════════════════════════════════════════════════════╝

  Namespace: $NAMESPACE

  ── OmniRoute dashboard ─────────────────────────────────────────────────────
  URL       : https://<your omniroute host>        (or: kubectl -n $NAMESPACE port-forward svc/omniroute 20128:20128)
  Password  : $OMNIROUTE_DASHBOARD_PASSWORD
              (INITIAL_PASSWORD — seeds the FIRST boot only; change it afterwards
               in Settings → Security)

  ── Hermes dashboard ────────────────────────────────────────────────────────
  URL       : https://<your hermes host>           (or: kubectl -n $NAMESPACE port-forward svc/hermes 9119:9119)
  Username  : admin
  Password  : $HERMES_DASHBOARD_PASSWORD

  ── Generated secret values (regenerable — no need to store) ────────────────
  JWT_SECRET                          : $JWT_SECRET
  API_KEY_SECRET                      : $API_KEY_SECRET
  API_SERVER_KEY                      : $API_SERVER_KEY
  HERMES_DASHBOARD_BASIC_AUTH_SECRET  : $HERMES_DASHBOARD_BASIC_AUTH_SECRET
  HERMES_DASHBOARD_..._PASSWORD_HASH  : ${HERMES_DASHBOARD_BASIC_AUTH_PASSWORD_HASH:-<none — docker unavailable>}

  ── Optional, NOT applied by default ────────────────────────────────────────
  STORAGE_ENCRYPTION_KEY              : $STORAGE_ENCRYPTION_KEY
      Encrypts the whole SQLite DB at rest. If you add it later you must BACK IT UP:
      without this exact value an existing database can never be opened again.
      kubectl -n $NAMESPACE patch secret omniroute-secrets --type merge \\
        -p '{"stringData":{"STORAGE_ENCRYPTION_KEY":"$STORAGE_ENCRYPTION_KEY"}}'

EOF

if [ "$APPLY" -eq 0 ]; then
  cat <<EOF
  ── Not applied (--print-only). To apply: ───────────────────────────────────
  kubectl create namespace $NAMESPACE --dry-run=client -o yaml | kubectl apply -f -

  kubectl -n $NAMESPACE create secret generic omniroute-secrets \\
    --from-literal=JWT_SECRET='$JWT_SECRET' \\
    --from-literal=API_KEY_SECRET='$API_KEY_SECRET' \\
    --from-literal=INITIAL_PASSWORD='$OMNIROUTE_DASHBOARD_PASSWORD' \\
    --dry-run=client -o yaml | kubectl apply -f -

  kubectl -n $NAMESPACE create secret generic hermes-secrets \\
    --from-literal=API_SERVER_KEY='$API_SERVER_KEY' \\
    --from-literal=HERMES_DASHBOARD_BASIC_AUTH_USERNAME='admin' \\
    --from-literal=HERMES_DASHBOARD_BASIC_AUTH_PASSWORD_HASH='$HERMES_DASHBOARD_BASIC_AUTH_PASSWORD_HASH' \\
    --from-literal=HERMES_DASHBOARD_BASIC_AUTH_SECRET='$HERMES_DASHBOARD_BASIC_AUTH_SECRET' \\
    --from-literal=OMNIROUTE_CLIENT_API_KEY='' \\
    --dry-run=client -o yaml | kubectl apply -f -

EOF
  exit 0
fi

# ── Apply ───────────────────────────────────────────────────────────────────
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f - >/dev/null

kubectl -n "$NAMESPACE" create secret generic omniroute-secrets \
  --from-literal=JWT_SECRET="$JWT_SECRET" \
  --from-literal=API_KEY_SECRET="$API_KEY_SECRET" \
  --from-literal=INITIAL_PASSWORD="$OMNIROUTE_DASHBOARD_PASSWORD" \
  --dry-run=client -o yaml | kubectl apply -f -

# OMNIROUTE_CLIENT_API_KEY starts empty on purpose: it is minted in the OmniRoute
# dashboard (Settings → API Keys) once it is up. Hermes starts fine without it and
# falls back to its built-in free-model list until you patch it in.
kubectl -n "$NAMESPACE" create secret generic hermes-secrets \
  --from-literal=API_SERVER_KEY="$API_SERVER_KEY" \
  --from-literal=HERMES_DASHBOARD_BASIC_AUTH_USERNAME="admin" \
  --from-literal=HERMES_DASHBOARD_BASIC_AUTH_PASSWORD_HASH="$HERMES_DASHBOARD_BASIC_AUTH_PASSWORD_HASH" \
  --from-literal=HERMES_DASHBOARD_BASIC_AUTH_SECRET="$HERMES_DASHBOARD_BASIC_AUTH_SECRET" \
  --from-literal=OMNIROUTE_CLIENT_API_KEY="" \
  --dry-run=client -o yaml | kubectl apply -f -

cat <<EOF

  ✅ Applied. Key names only (never the values):
$(kubectl -n "$NAMESPACE" get secret omniroute-secrets hermes-secrets -o json \
    | python3 -c 'import json,sys; [print("     "+i["metadata"]["name"]+": "+", ".join(sorted(i["data"]))) for i in json.load(sys.stdin)["items"]]' 2>/dev/null)

  Next:
    kubectl apply -k .
    kubectl -n $NAMESPACE rollout status statefulset/omniroute --timeout=300s
    kubectl -n $NAMESPACE rollout status statefulset/hermes    --timeout=300s

  Then in the OmniRoute dashboard: add Providers → OpenCode Go (makes the free
  models callable), mint an API key under Settings → API Keys, and hand it to Hermes:

    kubectl -n $NAMESPACE patch secret hermes-secrets --type merge \\
      -p '{"stringData":{"OMNIROUTE_CLIENT_API_KEY":"<the key>"}}'
    kubectl -n $NAMESPACE rollout restart statefulset/hermes

EOF
