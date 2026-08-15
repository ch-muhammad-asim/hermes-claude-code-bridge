#!/bin/sh
# Flatten Codex Responses-API "namespace" tools so a Chat Completions upstream
# can actually call them.
#
# WHY THIS PATCHES A BUNDLED CHUNK, NOT open-sse/
# ------------------------------------------------
# The image ships readable sources at /app/open-sse/translator/request/
# openai-responses.js, but they are NOT executed: `open-sse/...` does not even
# resolve from /app at runtime. The code that runs is webpack-bundled into
# /app/.next/server/chunks/*.js. Bind-mounting the readable file changes
# nothing — verified by instrumenting it and never seeing the log line.
#
# WHAT IT CHANGES
# ---------------
# Codex sends: { type:"namespace", name:"functions", tools:[{type:"function",name:"exec",...}] }
# The stock translator keeps only tools with a top-level `name`, so the
# namespace becomes ONE parameterless function literally called "functions"
# and the child `exec` is never exposed. The model then answers:
#   "The functions.exec tool isn't available in my current context."
# This rewrites the tool array to flatten namespace children into plain
# function tools and drop `tool_search` (meaningless to a Chat upstream).
#
# Fails loudly: if the pattern is absent (new 9Router build), it logs and
# starts unpatched rather than silently doing nothing.
set -e

CHUNKS=/app/.next/server/chunks
NEEDLE='let r=[...Array.isArray(b.tools)?b.tools:[],...m];'
REPLACE='let r=(function(_t){const _o=[];for(const _x of _t){if(!_x||typeof _x!=="object")continue;if(_x.type==="tool_search")continue;if(_x.type==="namespace"&&Array.isArray(_x.tools)){for(const _c of _x.tools){if(_c&&typeof _c==="object"&&(_c.type==="function"||_c.type==="custom"))_o.push(_c);}continue;}_o.push(_x);}return _o;})([...Array.isArray(b.tools)?b.tools:[],...m]);'

patched=0
for f in "$CHUNKS"/*.js; do
  [ -f "$f" ] || continue
  if grep -qF '__CODEX_NS_FLATTEN__' "$f" 2>/dev/null; then
    echo "[codex-patch] already applied: $f"
    patched=1
    continue
  fi
  if grep -qF "$NEEDLE" "$f" 2>/dev/null; then
    node -e '
      const fs=require("fs"), f=process.argv[1], n=process.argv[2], r=process.argv[3];
      const s=fs.readFileSync(f,"utf8");
      if(!s.includes(n)) process.exit(3);
      fs.writeFileSync(f, s.split(n).join(r+"/*__CODEX_NS_FLATTEN__*/"));
    ' "$f" "$NEEDLE" "$REPLACE"
    echo "[codex-patch] namespace flattening applied to $f"
    patched=1
  fi
done

[ "$patched" = "1" ] || echo "[codex-patch] WARNING: pattern not found — starting UNPATCHED (9Router build changed?)"

exec /entrypoint.sh "$@"
