# syntax=docker/dockerfile:1.7
# Claude Code → OpenAI-compatible bridge image.
#
# Mirrors the image built by ../docker/docker-hermes-claude-bridge.sh, but as a
# checked-in Dockerfile so `docker compose up` can build it without that script
# (which needs flock(1) and is therefore Linux-only).
ARG NODE_BASE=node:22-bookworm-slim
FROM ${NODE_BASE}

# `latest` tracks the current Claude Code release. Pin it (e.g. 2.1.205) for a
# fully reproducible image.
ARG CLAUDE_CODE_VERSION=latest

# --- system + npm install (heavy, cached) ------------------------------------
# BuildKit cache mounts keep the apt lists and npm cache between builds, so
# rebuilding the same versions is near-instant instead of a full re-download.
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    --mount=type=cache,target=/root/.npm \
    rm -f /etc/apt/apt.conf.d/docker-clean && \
    apt-get update && \
    apt-get install -y --no-install-recommends \
        python3 curl ca-certificates bash tini && \
    npm install -g @anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}

# Reuse the base image's non-root `node` user (UID 1000 on Linux), which also
# makes a host ~/.claude bind mount readable for most developers.
# /workspace is sticky-world-writable (1777, like /tmp) because the container runs
# as the HOST uid, which is unknown at build time — the bind-mounted ~/.claude only
# works if the process uid matches its owner. A dir owned by node:node would be
# unwritable for every other uid, and the entrypoint would die writing
# settings.local.json.
RUN mkdir -p /app /workspace/.claude \
 && chown -R node:node /app /home/node \
 && chmod -R 1777 /workspace

# --- app code (changes often — copied AFTER the heavy layers so edits here
# don't bust the apt/npm cache). Ownership/mode are folded into COPY to save a
# layer and avoid a duplicate ~100 MB chown layer.
COPY --chown=node:node --chmod=755 docker-entrypoint.sh  /usr/local/bin/docker-entrypoint.sh
COPY --chown=node:node --chmod=755 healthcheck.sh        /usr/local/bin/healthcheck.sh
COPY --chown=node:node             claude_code_bridge.py /app/claude_code_bridge.py

ENV HOME=/home/node \
    CLAUDE_BIN=/usr/local/bin/claude \
    CLAUDE_CODE_PROXY_CWD=/workspace \
    PROXY_HOST=0.0.0.0 \
    PROXY_PORT=18181 \
    PYTHONUNBUFFERED=1

USER node
WORKDIR /workspace
EXPOSE 18181

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/docker-entrypoint.sh"]
HEALTHCHECK --interval=15s --timeout=3s --start-period=5s --retries=3 \
  CMD ["/usr/local/bin/healthcheck.sh"]
