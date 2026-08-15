#!/usr/bin/env bash
# Generate every secret this stack needs, apply them to the cluster, and print them.
#
#   ./generate.sh              generate + apply both Secrets, then print
#   ./generate.sh --print      print what is already in the cluster, generate nothing
#   ./generate.sh --key-only   mint/fetch the 9Router API key and patch hermes-secrets
#   ./generate.sh --up         do everything: secrets, kubectl apply, key, cache warm
#   ./generate.sh --rotate     force-regenerate everything (invalidates issued 9Router API keys)
#
# The Hermes dashboard hash is scrypt and can ONLY be produced by the Hermes
# image itself, so a container engine must be running even though the workload
# lands in Kubernetes.
set -euo pipefail

cd "$(dirname "$0")"

NS="${NS:-9router}"
HERMES_IMAGE="${HERMES_IMAGE:-nousresearch/hermes-agent:v2026.8.13}"

c_ok=$'\033[32m'; c_warn=$'\033[33m'; c_key=$'\033[36m'; c_off=$'\033[0m'

die() { printf '%s🛑 %s%s\n' "$c_warn" "$1" "$c_off" >&2; exit 1; }

sec() {  # sec <secret-name> <key>
  kubectl -n "$NS" get secret "$1" -o "jsonpath={.data.$2}" 2>/dev/null \
    | base64 --decode 2>/dev/null || true
}

print_secrets() {
  local initpw jwt aks salt apikey hash dsecret nrkey pass
  initpw=$(sec 9router-secrets INITIAL_PASSWORD)
  jwt=$(sec 9router-secrets JWT_SECRET)
  aks=$(sec 9router-secrets API_KEY_SECRET)
  salt=$(sec 9router-secrets MACHINE_ID_SALT)
  apikey=$(sec hermes-secrets API_SERVER_KEY)
  hash=$(sec hermes-secrets HERMES_DASHBOARD_BASIC_AUTH_PASSWORD_HASH)
  dsecret=$(sec hermes-secrets HERMES_DASHBOARD_BASIC_AUTH_SECRET)
  nrkey=$(sec hermes-secrets OPENAI_API_KEY)
  pass="${HERMES_PASS_PLAINTEXT:-$(sec hermes-dashboard-login PASSWORD)}"

  cat <<EOF

${c_ok}━━━ 9Router ━━━${c_off}  namespace ${NS}
  dashboard      kubectl -n ${NS} port-forward svc/ninerouter 8080:8080  ->  http://localhost:8080
  password       ${c_key}${initpw}${c_off}
  api key        ${c_key}${nrkey:-<not minted yet — roll out, then ./generate.sh --key-only>}${c_off}
  JWT_SECRET     ${jwt}
  API_KEY_SECRET ${aks}
  MACHINE_ID_SALT ${salt}

${c_ok}━━━ Hermes ━━━${c_off}
  dashboard      kubectl -n ${NS} port-forward svc/hermes 9119:9119  ->  http://localhost:9119/login
  username       admin
  password       ${c_key}${pass:-<run ./generate.sh to create one>}${c_off}
  api key        ${c_key}${apikey}${c_off}
  session secret ${dsecret}
  password hash  ${hash}
EOF
  [ -n "$pass" ] && printf '\n%sThe Hermes password cannot be recovered from the hash — save it now.%s\n' "$c_warn" "$c_off"
  return 0
}

# A key that merely EXISTS is not enough: 9Router purges keys whose machine id
# no longer matches, so a stored key can be present and dead. Test it.
key_is_valid() {
  [ -n "$1" ] || return 1
  [ "$(kubectl -n "$NS" exec hermes-0 -c hermes -- sh -lc "curl -s -o /dev/null -w '%{http_code}' -H 'Authorization: Bearer $1' http://ninerouter:8080/v1/models" 2>/dev/null | tr -d '\r')" = "200" ]
}

# Hermes discovers 9Router's ~690 models on demand and caches them. A fresh
# install has an empty cache, so the picker shows only the configured default
# ("9router · 1 models") until something triggers discovery.
warm_model_cache() {
  local pass count
  pass="${HERMES_PASS_PLAINTEXT:-$(sec hermes-dashboard-login PASSWORD)}"
  [ -n "$pass" ] || return 0
  kubectl -n "$NS" get pod hermes-0 >/dev/null 2>&1 || return 0
  count=$(kubectl -n "$NS" exec hermes-0 -c hermes -- node -e "
const b='http://127.0.0.1:9119';
(async()=>{try{
  const r=await fetch(b+'/auth/password-login',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({provider:'basic',username:'admin',password:'$pass',next:'/'})});
  const ck=(r.headers.getSetCookie?r.headers.getSetCookie():[]).map(c=>c.split(';')[0]).join('; ');
  const d=await (await fetch(b+'/api/model/options?refresh=true',{headers:{cookie:ck}})).json();
  const n=(d.providers||[]).filter(p=>(p.name||'').includes('9Router')).map(p=>(p.models||[]).length);
  console.log(Math.max(0,...n));
}catch(e){console.log(0)}})();
" 2>/dev/null | tr -d '\r' | tail -1)
  [ "${count:-0}" -gt 1 ] && printf '%s✅ model catalog warmed — 9Router shows %s models%s\n' "$c_ok" "$count" "$c_off"
  return 0
}

mint_9router_key() {
  kubectl -n "$NS" get pod ninerouter-0 >/dev/null 2>&1 || {
    printf '%s⏭  ninerouter-0 not found — apply the manifests first%s\n' "$c_warn" "$c_off"; return 0; }
  kubectl -n "$NS" wait --for=condition=ready pod/ninerouter-0 --timeout=180s >/dev/null 2>&1 || {
    printf '%s⏭  ninerouter-0 not ready yet — retry: ./generate.sh --key-only%s\n' "$c_warn" "$c_off"; return 0; }

  local pw key
  pw=$(sec 9router-secrets INITIAL_PASSWORD)
  [ -n "$pw" ] || die "9router-secrets missing INITIAL_PASSWORD — run ./generate.sh first"

  # Runs inside the pod, where loopback is trusted, so no port-forward is needed.
  # node (v22, global fetch) rather than wget: the image has no curl, and its
  # wget is the busybox build with no --save-cookies for the session cookie.
  key=$(kubectl -n "$NS" exec ninerouter-0 -- node -e "
const b='http://127.0.0.1:8080', pw='$pw';
(async()=>{
  try{
    const r=await fetch(b+'/api/auth/login',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({password:pw})});
    const ck=(r.headers.getSetCookie?r.headers.getSetCookie():[]).map(c=>c.split(';')[0]).join('; ');
    const j=await (await fetch(b+'/api/keys',{headers:{cookie:ck}})).json();
    if(j.keys&&j.keys.length){console.log(j.keys[0].key);return;}
    const k=await (await fetch(b+'/api/keys',{method:'POST',headers:{'Content-Type':'application/json',cookie:ck},body:JSON.stringify({name:'hermes'})})).json();
    console.log(k.key||'');
  }catch(e){console.log('');}
})();
" 2>/dev/null | tr -d '\r' | tail -1 || true)

  [ -n "$key" ] || { printf '%s⏭  Could not obtain a 9Router API key — create one under Endpoint & Key%s\n' "$c_warn" "$c_off"; return 0; }

  if ! key_is_valid "$key"; then
    printf '%s⚠️  minted key does not authenticate yet — hermes will retry after restart%s\n' "$c_warn" "$c_off"
  fi

  kubectl -n "$NS" patch secret hermes-secrets \
    -p "{\"stringData\":{\"OPENAI_API_KEY\":\"$key\"}}" >/dev/null
  printf '%s✅ 9Router API key stored in hermes-secrets%s\n' "$c_ok" "$c_off"
  kubectl -n "$NS" rollout restart statefulset/hermes >/dev/null 2>&1 || true
  printf '%s♻️  restarted hermes to pick it up%s\n' "$c_ok" "$c_off"
}

ROTATE=0
UP=0
case "${1:-}" in
  --up)       UP=1 ;;
  --print)    print_secrets; exit 0 ;;
  --rotate)   ROTATE=1 ;;
  --key-only) mint_9router_key; kubectl -n "$NS" rollout status statefulset/hermes --timeout=180s >/dev/null 2>&1 || true; warm_model_cache; print_secrets; exit 0 ;;
  "")         ;;
  *)          die "unknown option: $1 (use --up, --print, --key-only or --rotate)" ;;
esac

command -v kubectl >/dev/null || die "kubectl not found"
command -v docker  >/dev/null || die "docker not found (needed only to hash the password)"
command -v openssl >/dev/null || die "openssl not found"
command -v envsubst >/dev/null || die "envsubst not found (brew install gettext)"
kubectl cluster-info >/dev/null 2>&1 || die "no reachable cluster — check kubectl config current-context"
docker info >/dev/null 2>&1 || die "no running container engine — start Docker Desktop or OrbStack"

printf '⏳ context: %s   namespace: %s\n' "$(kubectl config current-context)" "$NS"
kubectl get namespace "$NS" >/dev/null 2>&1 || kubectl create namespace "$NS" >/dev/null

docker image inspect "$HERMES_IMAGE" >/dev/null 2>&1 || {
  printf '⏳ pulling %s…\n' "$HERMES_IMAGE"; docker pull -q "$HERMES_IMAGE" >/dev/null; }

# Every 9Router secret is bound to its PVC and must survive re-runs:
#   INITIAL_PASSWORD  applied only when the PVC is first initialised
#   MACHINE_ID_SALT   derives /app/data/machine-id. Change it and 9Router
#                     rewrites that file and PURGES every API key bound to the
#                     old id — issued keys disappear and start returning 401
#   API_KEY_SECRET    the HMAC that signs issued keys; rotating invalidates them
#   JWT_SECRET        signs dashboard sessions; rotating logs you out
# Reuse whatever the cluster already holds; --rotate forces new values.
keep_or_new() {  # keep_or_new <secret> <key> <generator...>
  local existing; existing="$(sec "$1" "$2")"
  if [ -n "$existing" ] && [ "$ROTATE" != "1" ]; then printf '%s' "$existing"; else shift 2; "$@"; fi
}
# INITIAL_PASSWORD is NEVER rotated, even with --rotate: 9Router only reads it
# when it initialises an empty PVC, so a new value would leave the Secret
# disagreeing with the live database and lock you out of the dashboard (and out
# of key minting, which logs in with it). To change it, delete the PVC:
#   kubectl -n 9router delete statefulset ninerouter --cascade=foreground
#   kubectl -n 9router delete pvc data-ninerouter-0 && kubectl apply -k .
INITIAL_PASSWORD=$(sec 9router-secrets INITIAL_PASSWORD)
[ -n "$INITIAL_PASSWORD" ] || INITIAL_PASSWORD=$(openssl rand -hex 12)
if [ -n "$(sec 9router-secrets INITIAL_PASSWORD)" ] && [ "$ROTATE" != "1" ]; then
  printf '%s♻️  reusing the 9Router secrets already in the cluster — rotating MACHINE_ID_SALT\n   or API_KEY_SECRET would invalidate every issued API key. Force with --rotate.%s\n' "$c_warn" "$c_off"
fi

printf '⏳ hashing the Hermes dashboard password with scrypt…\n'
HERMES_PASS_PLAINTEXT="$(openssl rand -hex 24)"
HERMES_DASHBOARD_BASIC_AUTH_PASSWORD_HASH="$(docker run --rm \
  --entrypoint /opt/hermes/.venv/bin/python \
  -e PYTHONPATH=/opt/hermes -e P="$HERMES_PASS_PLAINTEXT" "$HERMES_IMAGE" \
  -c 'import os;from plugins.dashboard_auth.basic import hash_password;print(hash_password(os.environ["P"]))')"
[ -n "$HERMES_DASHBOARD_BASIC_AUTH_PASSWORD_HASH" ] || die "hash generation produced nothing"

JWT_SECRET=$(keep_or_new 9router-secrets JWT_SECRET openssl rand -hex 32)
API_KEY_SECRET=$(keep_or_new 9router-secrets API_KEY_SECRET openssl rand -hex 32)
MACHINE_ID_SALT=$(keep_or_new 9router-secrets MACHINE_ID_SALT openssl rand -hex 16)
API_SERVER_KEY=$(openssl rand -hex 32)
HERMES_DASHBOARD_BASIC_AUTH_SECRET=$(openssl rand -hex 32)
# Preserved across regenerations so Hermes keeps working without a re-mint.
NINEROUTER_API_KEY=$(sec hermes-secrets OPENAI_API_KEY)
[ "$ROTATE" = "1" ] && NINEROUTER_API_KEY=""

export INITIAL_PASSWORD JWT_SECRET API_KEY_SECRET MACHINE_ID_SALT \
       API_SERVER_KEY HERMES_DASHBOARD_BASIC_AUTH_PASSWORD_HASH \
       HERMES_DASHBOARD_BASIC_AUTH_SECRET NINEROUTER_API_KEY

envsubst < secrets/secret.template.yaml | kubectl apply -f - >/dev/null
printf '%s✅ applied Secrets 9router-secrets + hermes-secrets to namespace %s%s\n' "$c_ok" "$NS" "$c_off"

# Plaintext dashboard password, kept in its own Secret that is NOT mounted into
# any pod. It exists so --print can show it and --key-only can warm the model
# cache; the pod itself only ever sees the scrypt hash.
kubectl -n "$NS" create secret generic hermes-dashboard-login \
  --from-literal=PASSWORD="$HERMES_PASS_PLAINTEXT" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null

# Self-heal: an empty OPENAI_API_KEY is never useful — Hermes would come up Ready
# and 401 on every model call, which surfaces only as a 1-model picker. If
# 9Router is already running, mint one now instead of leaving that trap set.
if [ -z "$(sec hermes-secrets OPENAI_API_KEY)" ]; then
  printf '%s🔑 no 9Router API key in hermes-secrets — minting one%s\n' "$c_warn" "$c_off"
  mint_9router_key
fi
if [ "$UP" = "1" ]; then
  printf '⏳ applying manifests…\n'
  kubectl apply -k . >/dev/null 2>&1 || die "kubectl apply -k . failed"
  kubectl -n "$NS" rollout status statefulset/ninerouter --timeout=300s >/dev/null 2>&1 || true
  mint_9router_key
fi
kubectl -n "$NS" rollout status statefulset/hermes --timeout=180s >/dev/null 2>&1 || true
warm_model_cache

if [ "$UP" = "1" ]; then
  if key_is_valid "$(sec hermes-secrets OPENAI_API_KEY)"; then
    printf '%s✅ verified: Hermes can reach 9Router%s\n' "$c_ok" "$c_off"
  else
    printf '%s🛑 the 9Router key still does not authenticate — run ./generate.sh --key-only%s\n' "$c_warn" "$c_off"
  fi
fi

print_secrets

cat <<EOF
${c_ok}Next:${c_off}
  kubectl apply -k .
  kubectl -n ${NS} rollout status statefulset/ninerouter
  ./generate.sh --key-only          # mint the 9Router key and restart Hermes
  kubectl -n ${NS} port-forward svc/hermes 9119:9119
EOF
