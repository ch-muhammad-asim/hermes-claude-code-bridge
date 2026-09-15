#!/bin/sh
# Container HEALTHCHECK: hit /health, carrying the bearer token when one is required.
PORT="${PROXY_PORT:-18181}"
if [ -n "${CLAUDE_CODE_PROXY_API_KEY:-}" ]; then
  exec curl -fsS -H "Authorization: Bearer ${CLAUDE_CODE_PROXY_API_KEY}" "http://127.0.0.1:${PORT}/health"
fi
exec curl -fsS "http://127.0.0.1:${PORT}/health"
