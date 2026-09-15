#!/usr/bin/env bash
# Print the required OmniRoute secrets as .env lines.
#
#   cp env.example .env
#   ./generate-secrets.sh >> .env
#
# Then edit .env and blank out the empty duplicates from env.example, or just
# rely on the appended values winning (later lines override earlier ones in
# docker compose env_file parsing).
set -euo pipefail

printf 'JWT_SECRET=%s\n' "$(openssl rand -base64 48)"
printf 'API_KEY_SECRET=%s\n' "$(openssl rand -hex 32)"
printf 'INITIAL_PASSWORD=%s\n' "$(openssl rand -base64 24 | tr -d '/+=' | cut -c1-24)"
# Uncomment if you want database-at-rest encryption from the very first boot.
# Back this value up: without it an existing database cannot be opened.
printf '# STORAGE_ENCRYPTION_KEY=%s\n' "$(openssl rand -hex 32)"
