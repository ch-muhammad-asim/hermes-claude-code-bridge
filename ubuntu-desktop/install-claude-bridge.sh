#!/usr/bin/env bash
#
# install-claude-bridge.sh — portable installer for the Claude Code Bridge.
#
# What it does:
#   1. Writes an embedded bridge to ~/.local/share/claude-code-bridge/
#   2. Installs a systemd unit at /etc/systemd/system/claude-code-bridge.service
#      so the bridge auto-starts at boot and restarts on failure.
#   3. Patches ~/.hermes/config.yaml to register a custom OpenAI-compatible
#      provider pointing at http://127.0.0.1:18181/v1 (idempotent).
#   4. Tests /health, /v1/models and /v1/chat/completions end-to-end.
#
# Designed to drop onto a fresh Ubuntu 22.04/24.04 desktop and just work,
# regardless of the user's home dir (no hardcoded home paths).
#
#   Usage:   ./install-claude-bridge.sh              # install / refresh
#            ./install-claude-bridge.sh --uninstall  # remove
#            ./install-claude-bridge.sh --skip-hermes-config
#
# Override via env:
#   BRIDGE_HOST  (default 127.0.0.1; legacy PROXY_HOST also accepted)
#   BRIDGE_PORT  (default 18181; legacy PROXY_PORT also accepted)
#   CLAUDE_BIN   (default $HOME/.local/bin/claude)
#   BRIDGE_CWD   (default $HOME; legacy PROXY_CWD also accepted)
#   MODEL_ID     (default claude-opus-4-8-proxy; Hermes-safe alias)
#   BRIDGE_MODELS (default all supported Claude models; comma-separated)
#   BRIDGE_USER  (default current user; legacy PROXY_USER also accepted)
#
set -euo pipefail

case "${1:-}" in
  -h|--help)
    awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"
    exit 0 ;;
esac

# --- config -----------------------------------------------------------------
PROXY_HOST="${BRIDGE_HOST:-${PROXY_HOST:-127.0.0.1}}"
PROXY_PORT="${BRIDGE_PORT:-${PROXY_PORT:-18181}}"
SERVICE_NAME="claude-code-bridge.service"
SERVICE_FILE="/etc/systemd/system/$SERVICE_NAME"
PROVIDER_NAME="claude-code-bridge"
# MODEL_ID is the id Hermes sees/advertises. It must NOT exactly match a name
# in Hermes' built-in provider catalog (e.g. "claude-opus-4-8") or Hermes
# auto-switches provider=custom -> anthropic and bypasses this bridge. The
# "-proxy" suffix is retained for compatibility and keeps it off the catalog.
# CLI_MODEL is the real model the bridge runs on the CLI (decoupled, since
# pass-model is off).
MODEL_ID="${MODEL_ID:-claude-opus-4-8-proxy}"
CLI_MODEL="${CLI_MODEL:-claude-opus-4-8}"
DEFAULT_MODEL_IDS="claude-fable-5,claude-opus-4-8,claude-opus-4-7,claude-opus-4-6,claude-sonnet-5,claude-sonnet-4-6,claude-haiku-4-5"
MODEL_IDS="${BRIDGE_MODELS:-${CLAUDE_CODE_BRIDGE_MODELS:-${MODEL_IDS:-$DEFAULT_MODEL_IDS}}}"

# Resolve the real user even when invoked via sudo
PROXY_USER="${BRIDGE_USER:-${PROXY_USER:-${SUDO_USER:-$USER}}}"
PROXY_HOME="$(getent passwd "$PROXY_USER" | cut -d: -f6)"
[ -n "$PROXY_HOME" ] || { echo "ERROR: cannot resolve home for $PROXY_USER" >&2; exit 1; }

CLAUDE_BIN="${CLAUDE_BIN:-$PROXY_HOME/.local/bin/claude}"
PROXY_CWD="${BRIDGE_CWD:-${PROXY_CWD:-$PROXY_HOME}}"

# Local Desktop default: expose the full Claude Code tool surface to Hermes.
# Override per-machine with ALLOWED_TOOLS / DISALLOWED_TOOLS to lock it down.
ALLOWED_TOOLS="${ALLOWED_TOOLS:-*}"
DISALLOWED_TOOLS="${DISALLOWED_TOOLS:-}"
PERMISSION_MODE="${PERMISSION_MODE:-${CLAUDE_CODE_PERMISSION_MODE:-bypassPermissions}}"
# pass-model OFF: single-model bridge. It ignores the incoming catalog-dodging
# alias and always runs CLI_MODEL via the CLI.
PASS_MODEL="${PASS_MODEL:-0}"
INSTALL_DIR="$PROXY_HOME/.local/share/claude-code-bridge"
PROXY_SCRIPT="$INSTALL_DIR/claude_code_bridge.py"
HERMES_CONFIG="$PROXY_HOME/.hermes/config.yaml"

SKIP_HERMES_CONFIG=0
DO_UNINSTALL=0
SKIP_TEST=0
QUICK_TEST=0

# --- arg parsing ------------------------------------------------------------
for arg in "$@"; do
  case "$arg" in
    --uninstall|-u)         DO_UNINSTALL=1 ;;
    --skip-hermes-config)   SKIP_HERMES_CONFIG=1 ;;
    --skip-test)            SKIP_TEST=1 ;;
    --quick)                QUICK_TEST=1 ;;  # only /health, no expensive chat completion
    -h|--help)
      awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"
      exit 0 ;;
    *) echo "ERROR: unknown arg: $arg" >&2; exit 1 ;;
  esac
done

# --- helpers ----------------------------------------------------------------
log()  { printf '\033[1;34m[claude-bridge]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[claude-bridge]\033[0m \xe2\x9c\x94 %s\n' "$*"; }
warn() { printf '\033[1;33m[claude-bridge]\033[0m WARN: %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[claude-bridge]\033[0m ERROR: %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

SUDO=""
if [ "$(id -u)" != 0 ]; then
  have sudo || die "this script needs sudo (or root) to install the systemd unit"
  SUDO="sudo"
fi

# --- uninstall path ---------------------------------------------------------
if [ "$DO_UNINSTALL" = "1" ]; then
  log "Stopping and removing $SERVICE_NAME"
  $SUDO systemctl disable --now "$SERVICE_NAME" 2>/dev/null || true
  $SUDO rm -f "$SERVICE_FILE"
  $SUDO systemctl daemon-reload || true
  rm -rf "$INSTALL_DIR"
  ok "Uninstalled."
  exit 0
fi

# --- sanity: required binaries ---------------------------------------------
have python3 || die "python3 not found (apt install python3)"
[ -x "$CLAUDE_BIN" ] || die "claude CLI not found or not executable at $CLAUDE_BIN
  Install Claude Code first: https://docs.anthropic.com/claude/code (override with CLAUDE_BIN=...)"
[ -d "$PROXY_CWD" ]  || die "BRIDGE_CWD/PROXY_CWD does not exist: $PROXY_CWD"

# --- write embedded bridge script ------------------------------------------
log "Installing bridge script to $PROXY_SCRIPT"
mkdir -p "$INSTALL_DIR"
cat > "$PROXY_SCRIPT" <<'CLAUDE_PROXY_PY_EOF'
#!/usr/bin/env python3
"""Small local OpenAI-compatible bridge for Hermes -> Claude Code CLI testing.

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
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any

DEFAULT_CLAUDE_BIN = os.path.expanduser("~/.local/bin/claude")
DEFAULT_MODEL = "claude-opus-4-8"
DEFAULT_MODELS = [
    "claude-fable-5",
    "claude-opus-4-8",
    "claude-opus-4-7",
    "claude-opus-4-6",
    "claude-sonnet-5",
    "claude-sonnet-4-6",
    "claude-haiku-4-5",
]
DEFAULT_EFFORT = "medium"
DEFAULT_PERMISSION_MODE = "bypassPermissions"
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
        return hmac.compare_digest(bearer, expected) or hmac.compare_digest(
            x_api_key, expected
        )

    def _send_sse_completion(self, model: str, content: str) -> None:
        completion_id = f"chatcmpl-{uuid.uuid4().hex}"
        created = int(time.time())
        chunks = [
            {
                "id": completion_id,
                "object": "chat.completion.chunk",
                "created": created,
                "model": model,
                "choices": [
                    {"index": 0, "delta": {"role": "assistant"}, "finish_reason": None}
                ],
            },
            {
                "id": completion_id,
                "object": "chat.completion.chunk",
                "created": created,
                "model": model,
                "choices": [
                    {"index": 0, "delta": {"content": content}, "finish_reason": None}
                ],
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
        print(f"[claude-code-bridge] {self.address_string()} - {fmt % args}", flush=True)

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
                    "models": self.server.models,  # type: ignore[attr-defined]
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
            self._send_json(
                200,
                {
                    "object": "list",
                    "data": [
                        {
                            "id": model_id,
                            "object": "model",
                            "created": 0,
                            "owned_by": "claude-code-cli",
                        }
                        for model_id in self.server.models  # type: ignore[attr-defined]
                    ],
                },
            )
            return
        if self.path.rstrip("/").startswith("/v1/models/"):
            model_id = self.path.rstrip("/")[len("/v1/models/") :]
            if model_id not in self.server.models:  # type: ignore[attr-defined]
                self._send_json(404, {"error": {"message": "model not found"}})
                return
            self._send_json(
                200,
                {
                    "id": model_id,
                    "object": "model",
                    "created": 0,
                    "owned_by": "claude-code-cli",
                },
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
                            f"model {model!r} cannot be run by claude-code-bridge. "
                            "This bridge executes the Claude Code CLI and only supports Claude model IDs. "
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

        max_prompt_chars = int(
            getattr(self.server, "max_prompt_chars", DEFAULT_MAX_PROMPT_CHARS)
        )
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
            model if self.server.pass_model else self.server.cli_model,  # type: ignore[attr-defined]
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
        if allowed_tools:
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
            f"[claude-code-bridge] model={model} chars={len(prompt)} "
            f"tools={len(allowed_tools)} exit={result.returncode} latency_ms={latency_ms}",
            flush=True,
        )

        if result.returncode != 0:
            message = _safe_error_text(
                result.stderr or result.stdout or "claude command failed"
            )
            self._send_json(
                502, {"error": {"message": message, "exit_code": result.returncode}}
            )
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
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=18181)
    parser.add_argument(
        "--claude-bin", default=os.getenv("CLAUDE_BIN", DEFAULT_CLAUDE_BIN)
    )
    parser.add_argument(
        "--cwd", default=os.getenv("CLAUDE_CODE_PROXY_CWD", os.getcwd())
    )
    parser.add_argument(
        "--model", default=os.getenv("CLAUDE_CODE_PROXY_MODEL", DEFAULT_MODEL)
    )
    parser.add_argument(
        "--models",
        default=os.getenv(
            "CLAUDE_CODE_BRIDGE_MODELS",
            os.getenv("CLAUDE_CODE_PROXY_MODELS", ",".join(DEFAULT_MODELS)),
        ),
        help="Comma-separated Claude model IDs advertised on /v1/models. The --model default is always included.",
    )
    parser.add_argument(
        # Model id actually passed to the claude CLI. Decoupled from --model so
        # the advertised id can be a catalog-dodging alias while the CLI runs a
        # real model.
        "--cli-model", default=os.getenv("CLAUDE_CODE_PROXY_CLI_MODEL", DEFAULT_MODEL)
    )
    parser.add_argument(
        "--allowed-tools",
        default=os.getenv("CLAUDE_CODE_ALLOWED_TOOLS", "*"),
        help="Comma-separated Claude Code tool allowlist. Default '*' grants all tools/connectors.",
    )
    parser.add_argument(
        "--disallowed-tools",
        default=os.getenv("CLAUDE_CODE_DISALLOWED_TOOLS", ""),
        help="Comma-separated denylist. Default empty denylist for trusted Desktop use.",
    )
    parser.add_argument(
        "--effort", default=os.getenv("CLAUDE_CODE_EFFORT", DEFAULT_EFFORT)
    )
    parser.add_argument(
        "--permission-mode",
        default=os.getenv("CLAUDE_CODE_PERMISSION_MODE", DEFAULT_PERMISSION_MODE),
        choices=[
            "acceptEdits",
            "auto",
            "bypassPermissions",
            "default",
            "dontAsk",
            "plan",
        ],
    )
    parser.add_argument(
        "--max-budget-usd", default=os.getenv("CLAUDE_CODE_MAX_BUDGET_USD", "")
    )
    parser.add_argument(
        "--max-prompt-chars",
        type=int,
        default=int(
            os.getenv("CLAUDE_CODE_MAX_PROMPT_CHARS", str(DEFAULT_MAX_PROMPT_CHARS))
        ),
    )
    parser.add_argument(
        "--append-system-prompt",
        default=os.getenv(
            "CLAUDE_CODE_APPEND_SYSTEM_PROMPT",
            "You are Claude Code, invoked by Hermes through a local bridge. You may use any "
            "available tool or connector to fulfil the request.",
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
    configured_models = _split_csv(args.models)
    ordered_models = [args.model] + [m for m in configured_models if m != args.model]
    seen_models = set()
    server.models = []  # type: ignore[attr-defined]
    for model_id in ordered_models:
        if model_id not in seen_models:
            server.models.append(model_id)  # type: ignore[attr-defined]
            seen_models.add(model_id)
    server.cli_model = args.cli_model  # type: ignore[attr-defined]
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
    printable_cmd = shlex.join(
        [args.claude_bin, "--model", args.model, "--effort", args.effort, "-p", "..."]
    )
    print(
        f"[claude-code-bridge] listening on http://{args.host}:{args.port}/v1 "
        f"model={args.model} models={server.models} claude_bin={args.claude_bin} "  # type: ignore[attr-defined]
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
CLAUDE_PROXY_PY_EOF
chmod 755 "$PROXY_SCRIPT"
chown "$PROXY_USER":"$PROXY_USER" "$PROXY_SCRIPT" 2>/dev/null || true
ok "Bridge script written ($(wc -l < "$PROXY_SCRIPT") lines)"

# --- write systemd unit -----------------------------------------------------
log "Installing systemd unit at $SERVICE_FILE"
TMP_UNIT="$(mktemp)"
cat > "$TMP_UNIT" <<UNIT
[Unit]
Description=Claude Code Bridge for Hermes Agent
Documentation=https://github.com/ch-muhammad-asim/hermes-claude-code-bridge/tree/main/ubuntu-desktop
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$PROXY_USER
Group=$PROXY_USER
WorkingDirectory=$PROXY_CWD
Environment=PATH=$PROXY_HOME/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
Environment=HOME=$PROXY_HOME
Environment=PYTHONUNBUFFERED=1
ExecStart=/usr/bin/python3 $PROXY_SCRIPT \\
  --host $PROXY_HOST \\
  --port $PROXY_PORT \\
  --claude-bin $CLAUDE_BIN \\
  --cwd $PROXY_CWD \\
  --model $MODEL_ID \\
  --models "$MODEL_IDS" \\
  --cli-model $CLI_MODEL \\
  --allowed-tools "$ALLOWED_TOOLS" \\
  --disallowed-tools "$DISALLOWED_TOOLS" \\
  --permission-mode $PERMISSION_MODE$( [ "$PASS_MODEL" = "1" ] && printf ' --pass-model' )
# Block the service "active" state until /health returns 200 (max 15s). Avoids
# a race where other units depending on this one start before the HTTP socket
# is listening.
ExecStartPost=/bin/sh -c 'for _ in \$(seq 30); do /usr/bin/curl -fsS -m 1 "http://$PROXY_HOST:$PROXY_PORT/health" >/dev/null 2>&1 && exit 0; sleep 0.5; done; exit 1'
Restart=always
RestartSec=3
TimeoutStartSec=30
StandardOutput=journal
StandardError=journal
SyslogIdentifier=claude-code-bridge

# --- Resource limits -------------------------------------------------------
# The bridge spawns claude-cli subprocesses, each of which can be memory-heavy.
# Cap parent + children so a runaway can't OOM the desktop.
MemoryMax=2G
MemoryHigh=1G
TasksMax=128
LimitNOFILE=4096
OOMScoreAdjust=-200

# --- Desktop trust model ---------------------------------------------------
# This local Desktop bridge intentionally exposes all Claude Code tools by
# default. Do not apply ProtectHome/ProtectSystem/ReadWritePaths here: those
# systemd restrictions make Bash/Edit/Write and MCP connector cache/config
# writes fail in confusing ways. Keep network binding at 127.0.0.1 unless you
# also add an API key and host firewall rule.
NoNewPrivileges=true
PrivateTmp=true
RestrictRealtime=true
RemoveIPC=true
SystemCallArchitectures=native

[Install]
WantedBy=multi-user.target
UNIT

# Idempotent: skip the daemon-reload + restart if the unit is byte-identical
# to what's already installed. Major speed win on repeat runs of the installer.
NEEDS_RELOAD=0
if [ ! -f "$SERVICE_FILE" ] || ! diff -q "$TMP_UNIT" "$SERVICE_FILE" >/dev/null 2>&1; then
  $SUDO install -m 0644 -o root -g root "$TMP_UNIT" "$SERVICE_FILE"
  NEEDS_RELOAD=1
fi
rm -f "$TMP_UNIT"

if [ "$NEEDS_RELOAD" = "1" ]; then
  $SUDO systemctl daemon-reload
  $SUDO systemctl enable "$SERVICE_NAME" >/dev/null
  $SUDO systemctl restart "$SERVICE_NAME"
  ok "Service (re)written, enabled and restarted"
else
  # Unit unchanged — but the embedded bridge script may have changed. Reload
  # the python process by restarting just the bridge. Faster than daemon-reload.
  $SUDO systemctl restart "$SERVICE_NAME"
  ok "Service unchanged; bridge process restarted to pick up script edits"
fi

# --- patch Hermes config ----------------------------------------------------
if [ "$SKIP_HERMES_CONFIG" = "0" ]; then
  if [ -f "$HERMES_CONFIG" ]; then
    log "Patching Hermes config at $HERMES_CONFIG"
    # Run as the target user so the file ownership and permissions stay correct
    sudo --preserve-env=PROVIDER_NAME,PROXY_HOST,PROXY_PORT,MODEL_ID,HERMES_CONFIG \
      PROVIDER_NAME="$PROVIDER_NAME" \
      PROXY_HOST="$PROXY_HOST" \
      PROXY_PORT="$PROXY_PORT" \
      MODEL_ID="$MODEL_ID" \
      HERMES_CONFIG="$HERMES_CONFIG" \
      -u "$PROXY_USER" python3 <<'PY'
import os, shutil, sys, datetime
from pathlib import Path
try:
    import yaml
except ImportError:
    print("PyYAML missing; skipping Hermes config patch (pip install pyyaml to enable).", file=sys.stderr)
    sys.exit(0)

cfg_path = Path(os.environ["HERMES_CONFIG"])
provider = os.environ["PROVIDER_NAME"]
base_url = f"http://{os.environ['PROXY_HOST']}:{os.environ['PROXY_PORT']}/v1"
model_id = os.environ["MODEL_ID"]

raw = cfg_path.read_text()
cfg = yaml.safe_load(raw) or {}

# Backup once per day
stamp = datetime.datetime.now().strftime("%Y%m%d")
backup = cfg_path.with_suffix(f".yaml.bak-{stamp}")
if not backup.exists():
    shutil.copy2(cfg_path, backup)
    print(f"Backed up to {backup}")

# Configure the default model to call our bridge as a "custom" OpenAI-compatible
# endpoint — exactly the shape the Hermes setup wizard writes when you pick
# "Local / custom endpoint" and click Connect.
model_cfg = cfg.get("model") or {}
desired = {
    "default": model_id,
    "provider": "custom",
    "base_url": base_url,
    "api_key": "",  # bridge is unauthenticated by default; set if you started it with --api-key
}
changed = any(model_cfg.get(k) != v for k, v in desired.items())
if changed:
    model_cfg.update(desired)
    cfg["model"] = model_cfg
    print(f"Updated model: default={model_id} provider=custom base_url={base_url}")

# Drop any earlier broken provider entry from previous install attempts.
providers_map = cfg.get("providers") or {}
if isinstance(providers_map, dict) and provider in providers_map:
    entry = providers_map.get(provider)
    if isinstance(entry, dict) and entry.get("type") == "openai":
        providers_map.pop(provider, None)
        cfg["providers"] = providers_map
        print(f"Cleaned up legacy providers.{provider} entry")

cfg_path.write_text(yaml.safe_dump(cfg, sort_keys=False, default_flow_style=False))
print(f"Wrote {cfg_path}")
PY
    ok "Hermes config updated"
  else
    warn "Hermes config not found at $HERMES_CONFIG — skipping (run Hermes once to generate it, then re-run this script)"
  fi
else
  log "Skipping Hermes config patch (--skip-hermes-config)"
fi

# --- end-to-end test --------------------------------------------------------
if [ "$SKIP_TEST" = "1" ]; then
  log "Skipping smoke test (--skip-test)"
else
  # The ExecStartPost hook above already waited for /health, so by the time we
  # reach here the bridge is guaranteed to be listening — no need for a sleep loop.
  log "GET /health"
  curl -fsS "http://$PROXY_HOST:$PROXY_PORT/health" || die "health check failed"
  echo

  log "GET /v1/models"
  curl -fsS "http://$PROXY_HOST:$PROXY_PORT/v1/models" || die "models endpoint failed"
  echo

  if [ "$QUICK_TEST" = "1" ]; then
    log "Skipping chat completion test (--quick)"
  else
    log "POST /v1/chat/completions (this calls claude-cli; may take 20-60s)"
    resp="$(curl -fsS --max-time 180 -X POST "http://$PROXY_HOST:$PROXY_PORT/v1/chat/completions" \
      -H 'content-type: application/json' \
      -d "{\"model\":\"$MODEL_ID\",\"messages\":[{\"role\":\"user\",\"content\":\"reply with exactly: claude-code-bridge ok\"}]}")" \
      || die "chat completion failed (see: journalctl -u $SERVICE_NAME)"

    answer="$(printf '%s' "$resp" | python3 -c 'import sys,json; print(json.load(sys.stdin)["choices"][0]["message"]["content"])')"
    ok "Got from Claude: $answer"
  fi
fi

# --- summary ----------------------------------------------------------------
G='\033[1;32m'; B='\033[1m'; R='\033[0m'
printf "\n${G}Claude Code Bridge installed.${R}\n"
printf "  Endpoint:     http://%s:%s/v1\n" "$PROXY_HOST" "$PROXY_PORT"
printf "  Model ID:     %s\n" "$MODEL_ID"
printf "  Models:       %s\n" "$MODEL_IDS"
printf "  Service:      %s (%s)\n" "$SERVICE_NAME" "$(systemctl is-active "$SERVICE_NAME")"
printf "  Script:       %s\n" "$PROXY_SCRIPT"
printf "  Runs as:      %s  (cwd: %s)\n" "$PROXY_USER" "$PROXY_CWD"
printf "  Hermes cfg:   %s  (provider: %s)\n\n" "$HERMES_CONFIG" "$PROVIDER_NAME"
printf "  Tools:        allowed=%s disallowed=%s permission_mode=%s\n\n" "$ALLOWED_TOOLS" "${DISALLOWED_TOOLS:-'(empty)'}" "$PERMISSION_MODE"
printf "${B}Security note:${R} this Desktop install is a full-trust local bridge bound to 127.0.0.1.\n"
printf "  Do not expose it on 0.0.0.0 without an API key and firewall rule.\n\n"
printf "${B}Useful commands:${R}\n"
printf "  systemctl status %s\n" "$SERVICE_NAME"
printf "  journalctl -u %s -f\n" "$SERVICE_NAME"
printf "  %s --uninstall\n\n" "$0"
printf "${B}In Hermes UI (Local / custom endpoint):${R}\n"
printf "  Endpoint URL:  http://%s:%s/v1\n" "$PROXY_HOST" "$PROXY_PORT"
printf "  API key:       (leave empty)\n"
printf "  Model:         %s\n" "$MODEL_ID"
