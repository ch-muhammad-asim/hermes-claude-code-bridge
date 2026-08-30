#!/usr/bin/env python3
"""chat-completions-compatible proxy for Hermes -> Claude Code CLI.

This bridge accepts /health, /config, /v1/models and /v1/chat/completions, calls
an authenticated `claude -p`, and returns chat-completions responses for Hermes
custom providers.

It runs the CLI with `--output-format stream-json`, which unlocks four things
over a plain blocking/text response:

  * Real streaming      - token-level `text_delta` events are translated to
                          chat-completions SSE `chat.completion.chunk` deltas as they
                          arrive, instead of one faked burst after completion.
  * Session continuity  - each Hermes conversation is mapped (by a hash of its
                          non-assistant turns) to a persistent Claude Code
                          `--session-id`, so follow-up turns `--resume` the same
                          session. This preserves working context and turns the
                          large system-prompt/skills `cache_creation` cost into
                          cheap `cache_read` on later turns. Requires no Hermes
                          changes and degrades gracefully to full-history replay.
  * Real usage & cost   - token counts and `total_cost_usd` are read from the
                          final `result` event and reported in `usage`.
  * Robustness          - bounded concurrency, per-session locking, idle/total
                          timeouts, client-disconnect subprocess kill, and
                          retry-before-first-byte on transient failures.

Every capability is flag-gated; if stream parsing yields nothing the response
still completes from the final `result` event.
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import hmac
import json
import os
import re
import shlex
import shutil
import subprocess
import tempfile
import threading
import time
import urllib.parse
import urllib.request
import uuid
from collections import OrderedDict
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any


DEFAULT_CLAUDE_BIN = os.path.expanduser("~/.local/bin/claude")
DEFAULT_MODEL = "claude-opus-4-8"
# Claude Code model IDs advertised on /v1/models for discovery/UI (e.g. the Hermes
# model picker). This is NOT a whitelist: with pass-model enabled, clients may request
# ANY valid Claude model ID (see _looks_like_claude_model). Override the advertised set
# with the CLAUDE_CODE_MODELS env var (comma-separated).
CLAUDE_CODE_MODELS = [
    m.strip()
    for m in os.getenv(
        "CLAUDE_CODE_MODELS",
        "claude-opus-4-8,claude-sonnet-5,claude-haiku-4-5",
    ).split(",")
    if m.strip()
]
DEFAULT_EFFORT = "medium"
DEFAULT_PERMISSION_MODE = "dontAsk"

# Images: chat-completions ``image_url`` parts are staged to a per-request temp
# dir that is handed to the CLI via ``--add-dir`` so its Read tool can view
# them. 32 MiB fits full-screen Retina screenshots; 0 disables image handling
# (image parts are then silently dropped, as before).
DEFAULT_MAX_IMAGES = 4
DEFAULT_MAX_IMAGE_BYTES = 32 * 1024 * 1024
DEFAULT_MAX_PROMPT_CHARS = 200_000
DEFAULT_SESSION_STORE = "/opt/data/proxy-sessions.json"
DEFAULT_MAX_SESSIONS = 2000



# ── images ────────────────────────────────────────────────────────────────────
_IMAGE_EXT = {
    "image/png": ".png", "image/jpeg": ".jpg", "image/jpg": ".jpg",
    "image/webp": ".webp", "image/gif": ".gif",
}


class ImageExtractionError(ValueError):
    """A client-supplied image could not be decoded/attached (HTTP 400)."""


def _decode_image_url(url: str, index: int) -> tuple[bytes, str | None]:
    """Return (bytes, mime) for a chat-completions ``image_url`` value."""
    url = (url or "").strip()
    if not url:
        raise ImageExtractionError(f"message contains an empty image_url (image #{index + 1})")
    if url.startswith("data:"):
        header, _, payload = url.partition(",")
        mime = header[5:].split(";")[0].strip().lower() or None
        try:
            # Some clients line-wrap base64 payloads; strip whitespace before the
            # strict decode or a perfectly good image is rejected as corrupt.
            data = base64.b64decode(re.sub(r"\s+", "", payload), validate=True)
        except Exception as exc:  # noqa: BLE001
            raise ImageExtractionError(f"image #{index + 1}: invalid base64 data ({exc})") from exc
        return data, mime
    parsed = urllib.parse.urlparse(url)
    if parsed.scheme == "file":
        file_path = urllib.request.url2pathname(parsed.path)
        try:
            with open(file_path, "rb") as fh:
                return fh.read(), None
        except OSError as exc:
            raise ImageExtractionError(f"image #{index + 1}: cannot read {file_path!r} ({exc})") from exc
    if parsed.scheme in ("http", "https"):
        try:
            with urllib.request.urlopen(url, timeout=30) as resp:
                return resp.read(), (resp.headers.get_content_type() or None)
        except Exception as exc:  # noqa: BLE001
            raise ImageExtractionError(f"image #{index + 1}: fetch failed ({exc})") from exc
    raise ImageExtractionError(
        f"image #{index + 1}: unsupported image_url scheme {parsed.scheme!r} "
        "(use a data: URI or an http(s)/file URL)")


def extract_images(messages: list[dict[str, Any]], max_images: int,
                   max_bytes_per_image: int) -> list[tuple[bytes, str | None]]:
    """Collect ``(data, mime)`` for every ``image_url`` content part in ``messages``."""
    declared = 0
    for message in messages or []:
        content = message.get("content")
        if not isinstance(content, list):
            continue
        for item in content:
            if isinstance(item, dict) and item.get("type") == "image_url":
                declared += 1
    if max_images <= 0:
        if declared:
            raise ImageExtractionError(
                "this proxy has image support disabled (--max-images 0); resend text-only")
        return []
    if declared > max_images:
        raise ImageExtractionError(
            f"too many images: {declared} exceeds the limit of {max_images} per request")
    found: list[tuple[bytes, str | None]] = []
    for message in messages or []:
        content = message.get("content")
        if not isinstance(content, list):
            continue
        for item in content:
            if not (isinstance(item, dict) and item.get("type") == "image_url"):
                continue
            inner = item.get("image_url")
            url = inner.get("url") if isinstance(inner, dict) else inner
            found.append(_decode_image_url(str(url or ""), len(found)))
    oversized = [i + 1 for i, image in enumerate(found) if len(image[0]) > max_bytes_per_image]
    if oversized:
        raise ImageExtractionError(
            f"image(s) {oversized} exceed the per-image limit of {max_bytes_per_image // (1024 * 1024)} MiB")
    return found


def stage_image_files(images: list[tuple[bytes, str | None]]) -> tuple[str | None, list[str]]:
    """Write extracted images into a fresh temp dir; return (dir, file paths).

    The dir is handed to the CLI via ``--add-dir`` so the Read tool can view the
    files; the caller must remove it (cleanup_image_dir) when the request ends.
    """
    if not images:
        return None, []
    directory = tempfile.mkdtemp(prefix="claude-bridge-images-")
    paths: list[str] = []
    for index, (data, mime) in enumerate(images):
        ext = _IMAGE_EXT.get((mime or "").lower())
        if not ext:
            head = data[:12]
            sniffed = ("png" if head.startswith(b"\x89PNG\r\n\x1a\n")
                       else "jpg" if head.startswith(b"\xff\xd8")
                       else "webp" if head[8:12] == b"WEBP"
                       else "gif" if head.startswith((b"GIF87a", b"GIF89a"))
                       else "png")
            ext = f".{sniffed}"
        file_path = os.path.join(directory, f"image-{index + 1}{ext}")
        with open(file_path, "wb") as fh:
            fh.write(data)
        paths.append(file_path)
    return directory, paths


def cleanup_image_dir(directory: str | None) -> None:
    if directory:
        shutil.rmtree(directory, ignore_errors=True)


def image_attachment_note(paths: list[str]) -> str:
    """Prompt suffix telling the CLI to view the staged files with Read."""
    if not paths:
        return ""
    listing = "\n".join(f"  {p}" for p in paths)
    return ("\n\n[The user attached the following image file(s). "
            "View each with the Read tool before answering:\n" + listing + "\n]")


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
        content = message.get("content")
        text = _text_from_content(content).strip()
        if not text and isinstance(content, list) and any(
                isinstance(part, dict) and part.get("type") == "image_url" for part in content):
            text = "(see attached image)"  # attachments ride separately via --add-dir
        if text:
            sections.append(f"{role.upper()}:\n{text}")
    return "\n\n".join(sections).strip()


def _latest_user_text(messages: list[dict[str, Any]]) -> str:
    """Text of the most recent user turn, for resume requests."""
    for message in reversed(messages):
        if str(message.get("role")) == "user":
            content = message.get("content")
            text = _text_from_content(content).strip()
            if not text and isinstance(content, list) and any(
                    isinstance(part, dict) and part.get("type") == "image_url" for part in content):
                text = "(see attached image)"
            if text:
                return text
    return _prompt_from_messages(messages)


def _convo_key(messages: list[dict[str, Any]]) -> str:
    """Stable hash identifying a conversation by its non-assistant turns.

    Assistant content is excluded so the key does not depend on the exact text
    Hermes echoes back for our prior reply. The key over a request's full
    message list equals the key over the *next* request's history-minus-new-turn,
    which is how a follow-up turn finds the session to resume.
    """
    items: list[list[str]] = []
    for message in messages:
        role = str(message.get("role") or "user")
        if role == "assistant":
            continue
        items.append([role, _text_from_content(message.get("content")).strip()])
    if not items:
        return ""
    raw = json.dumps(items, ensure_ascii=False, separators=(",", ":"))
    return hashlib.sha256(raw.encode("utf-8")).hexdigest()


def _safe_error_text(text: object) -> str:
    """Keep CLI errors useful while reducing accidental token leakage.

    Accepts any object: the CLI reports `api_error_status` as an integer HTTP
    status, so this is not always a str. Coercing here keeps a non-string from
    turning a clean 502 into an unhandled AttributeError (which the client sees
    as an empty reply rather than an error it can act on).
    """
    redacted = str(text).strip()
    for marker in ("sk-ant-", "Bearer ", "Authorization:", "api_key", "apiKey"):
        if marker in redacted:
            redacted = redacted.replace(marker, f"{marker[:3]}[redacted]")
    return redacted[-4000:]


def _looks_like_claude_model(model: str) -> bool:
    normalized = model.strip().lower()
    return normalized.startswith("claude-") or normalized.startswith("anthropic/")


def _usage_from_result(result_event: dict[str, Any]) -> dict[str, Any]:
    usage = result_event.get("usage") or {}
    cache_read = int(usage.get("cache_read_input_tokens") or 0)
    cache_creation = int(usage.get("cache_creation_input_tokens") or 0)
    prompt_tokens = int(usage.get("input_tokens") or 0) + cache_read + cache_creation
    completion_tokens = int(usage.get("output_tokens") or 0)
    return {
        "prompt_tokens": prompt_tokens,
        "completion_tokens": completion_tokens,
        "total_tokens": prompt_tokens + completion_tokens,
        # Non-standard extensions Hermes can use for spend tracking.
        "cost_usd": result_event.get("total_cost_usd"),
        "cache_read_input_tokens": cache_read,
        "cache_creation_input_tokens": cache_creation,
    }


class SessionStore:
    """Thread-safe, LRU-bounded, disk-persisted conversation -> session-id map."""

    def __init__(self, path: str, max_entries: int = DEFAULT_MAX_SESSIONS) -> None:
        self.path = path
        self.max_entries = max_entries
        self._lock = threading.Lock()
        self._data: "OrderedDict[str, str]" = OrderedDict()
        self._load()

    def _load(self) -> None:
        try:
            with open(self.path, "r", encoding="utf-8") as handle:
                raw = json.load(handle)
            if isinstance(raw, dict):
                for key, value in raw.items():
                    if isinstance(key, str) and isinstance(value, str):
                        self._data[key] = value
        except FileNotFoundError:
            pass
        except Exception as exc:  # corrupt store should never crash the proxy
            print(f"[claude-code-proxy] session store load failed: {exc}", flush=True)

    def _save_locked(self) -> None:
        try:
            tmp = f"{self.path}.tmp"
            Path(self.path).parent.mkdir(parents=True, exist_ok=True)
            with open(tmp, "w", encoding="utf-8") as handle:
                json.dump(self._data, handle)
            os.replace(tmp, self.path)
        except Exception as exc:
            print(f"[claude-code-proxy] session store save failed: {exc}", flush=True)

    def get(self, key: str) -> str | None:
        if not key:
            return None
        with self._lock:
            value = self._data.get(key)
            if value is not None:
                self._data.move_to_end(key)
            return value

    def put(self, key: str, session_id: str) -> None:
        if not key or not session_id:
            return
        with self._lock:
            self._data[key] = session_id
            self._data.move_to_end(key)
            while len(self._data) > self.max_entries:
                self._data.popitem(last=False)
            self._save_locked()

    def drop(self, key: str) -> None:
        if not key:
            return
        with self._lock:
            if key in self._data:
                del self._data[key]
                self._save_locked()

    def count(self) -> int:
        with self._lock:
            return len(self._data)


def _session_lock(server: Any, session_id: str) -> threading.Lock:
    """Return a per-session mutex so concurrent turns can't corrupt one session."""
    with server.session_locks_master:  # type: ignore[attr-defined]
        lock = server.session_locks.get(session_id)  # type: ignore[attr-defined]
        if lock is None:
            lock = threading.Lock()
            server.session_locks[session_id] = lock  # type: ignore[attr-defined]
        return lock


class ClaudeProxyHandler(BaseHTTPRequestHandler):
    server_version = "ClaudeCodeProxy/0.3"

    # ----- low-level response helpers -------------------------------------

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

    def log_message(self, fmt: str, *args: Any) -> None:
        print(f"[claude-code-proxy] {self.address_string()} - {fmt % args}", flush=True)

    # ----- SSE streaming helpers ------------------------------------------

    def _write_sse(self, obj: dict[str, Any]) -> None:
        try:
            self.wfile.write(f"data: {json.dumps(obj)}\n\n".encode("utf-8"))
            self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            self._client_gone = True

    def _start_sse(self, completion_id: str, created: int, model: str) -> None:
        self.send_response(200)
        self.send_header("content-type", "text/event-stream")
        self.send_header("cache-control", "no-cache")
        self.send_header("connection", "keep-alive")
        self.end_headers()
        self._sse_started = True
        self._write_sse(
            {
                "id": completion_id,
                "object": "chat.completion.chunk",
                "created": created,
                "model": model,
                "choices": [{"index": 0, "delta": {"role": "assistant"}, "finish_reason": None}],
            }
        )

    def _emit_delta(self, completion_id: str, created: int, model: str, text: str) -> None:
        if self._client_gone or not text:
            return
        if not self._sse_started:
            self._start_sse(completion_id, created, model)
        self._write_sse(
            {
                "id": completion_id,
                "object": "chat.completion.chunk",
                "created": created,
                "model": model,
                "choices": [{"index": 0, "delta": {"content": text}, "finish_reason": None}],
            }
        )

    def _finish_sse(
        self, completion_id: str, created: int, model: str, usage: dict[str, Any] | None
    ) -> None:
        if self._client_gone:
            return
        if not self._sse_started:
            self._start_sse(completion_id, created, model)
        self._write_sse(
            {
                "id": completion_id,
                "object": "chat.completion.chunk",
                "created": created,
                "model": model,
                "choices": [{"index": 0, "delta": {}, "finish_reason": "stop"}],
                "usage": usage or {},
            }
        )
        try:
            self.wfile.write(b"data: [DONE]\n\n")
            self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            self._client_gone = True

    # ----- GET ------------------------------------------------------------

    def do_GET(self) -> None:
        if not self._authorized():
            self._send_json(401, {"error": {"message": "unauthorized"}})
            return

        path = self.path.rstrip("/")
        if path == "/health":
            self._send_json(200, {"status": "ok"})
            return
        if path == "/config":
            srv = self.server
            self._send_json(
                200,
                {
                    "status": "ok",
                    "model": srv.default_model,  # type: ignore[attr-defined]
                    "claude_bin": srv.claude_bin,  # type: ignore[attr-defined]
                    "cwd": srv.cwd,  # type: ignore[attr-defined]
                    "additional_dirs": srv.additional_dirs,  # type: ignore[attr-defined]
                    "settings_local": srv.settings_local,  # type: ignore[attr-defined]
                    "settings_local_exists": Path(srv.settings_local).exists(),  # type: ignore[attr-defined]
                    "effort": srv.effort,  # type: ignore[attr-defined]
                    "permission_mode": srv.permission_mode,  # type: ignore[attr-defined]
                    "allowed_tools": srv.allowed_tools,  # type: ignore[attr-defined]
                    "disallowed_tools": srv.disallowed_tools,  # type: ignore[attr-defined]
                    "max_budget_usd": srv.max_budget_usd,  # type: ignore[attr-defined]
                    "max_prompt_chars": srv.max_prompt_chars,  # type: ignore[attr-defined]
                    "pass_model": srv.pass_model,  # type: ignore[attr-defined]
                    "stream_output": srv.stream_output,  # type: ignore[attr-defined]
                    "session_persistence": srv.session_persistence,  # type: ignore[attr-defined]
                    "session_store": srv.session_store_path,  # type: ignore[attr-defined]
                    "session_count": srv.sessions.count(),  # type: ignore[attr-defined]
                    "max_concurrency": srv.max_concurrency,  # type: ignore[attr-defined]
                    "idle_timeout": srv.idle_timeout,  # type: ignore[attr-defined]
                    "timeout_seconds": srv.timeout_seconds,  # type: ignore[attr-defined]
                    "max_retries": srv.max_retries,  # type: ignore[attr-defined]
                    "api_key_required": bool(getattr(srv, "api_key", "") or ""),
                },
            )
            return
        if path == "/v1/models":
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
        if path.startswith("/v1/models/"):
            mid = path[len("/v1/models/"):]
            if mid == self.server.default_model or mid in CLAUDE_CODE_MODELS or _looks_like_claude_model(mid):  # type: ignore[attr-defined]
                self._send_json(
                    200,
                    {"id": mid, "object": "model", "created": 0, "owned_by": "claude-code-cli"},
                )
                return
        self._send_json(404, {"error": {"message": "not found"}})

    # ----- POST -----------------------------------------------------------

    def do_POST(self) -> None:
        self._sse_started = False
        self._client_gone = False

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

        srv = self.server
        model = str(request.get("model") or srv.default_model)  # type: ignore[attr-defined]
        if srv.pass_model and not _looks_like_claude_model(model):  # type: ignore[attr-defined]
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

        messages = request.get("messages") or []
        prompt = _prompt_from_messages(messages)
        if not prompt:
            self._send_json(400, {"error": {"message": "request has no prompt text"}})
            return

        max_prompt_chars = int(getattr(srv, "max_prompt_chars", DEFAULT_MAX_PROMPT_CHARS))
        if len(prompt) > max_prompt_chars:
            self._send_json(
                413,
                {"error": {"message": f"prompt too large: {len(prompt)} chars exceeds {max_prompt_chars}"}},
            )
            return

        try:
            images = extract_images(messages,
                                    int(getattr(srv, "max_images", DEFAULT_MAX_IMAGES)),
                                    int(getattr(srv, "max_image_bytes", DEFAULT_MAX_IMAGE_BYTES)))
        except ImageExtractionError as exc:
            self._send_json(400, {"error": {"message": str(exc)}})
            return
        image_dir, image_paths = stage_image_files(images)

        stream = request.get("stream") is True and srv.stream_output  # type: ignore[attr-defined]

        # Bound concurrent CLI subprocesses to protect sidecar memory.
        if not srv.concurrency.acquire(timeout=srv.queue_timeout):  # type: ignore[attr-defined]
            cleanup_image_dir(image_dir)  # staged but never handed to the CLI
            self._send_json(503, {"error": {"message": "proxy busy: concurrency limit reached"}})
            return
        try:
            self._handle_completion(request, model, messages, prompt, stream,
                                    image_dir, image_attachment_note(image_paths))
        finally:
            srv.concurrency.release()  # type: ignore[attr-defined]
            cleanup_image_dir(image_dir)

    def _build_cmd(self, model: str, prompt: str, resume_id: str | None, new_id: str | None,
                   image_dir: str | None = None) -> list[str]:
        srv = self.server
        cmd = [
            srv.claude_bin,  # type: ignore[attr-defined]
            "--model",
            model if srv.pass_model else srv.default_model,  # type: ignore[attr-defined]
            "--effort",
            srv.effort,  # type: ignore[attr-defined]
            "--permission-mode",
            srv.permission_mode,  # type: ignore[attr-defined]
            "--output-format",
            "stream-json",
            "--verbose",
            "--include-partial-messages",
        ]
        if srv.session_persistence:  # type: ignore[attr-defined]
            if resume_id:
                cmd.extend(["--resume", resume_id])
            elif new_id:
                cmd.extend(["--session-id", new_id])
        else:
            cmd.append("--no-session-persistence")
        if srv.max_budget_usd:  # type: ignore[attr-defined]
            cmd.extend(["--max-budget-usd", str(srv.max_budget_usd)])  # type: ignore[attr-defined]
        if srv.allowed_tools and srv.allowed_tools != ["*"]:  # type: ignore[attr-defined]
            allowed = list(srv.allowed_tools)  # type: ignore[attr-defined]
            if image_dir and "Read" not in allowed:
                allowed.append("Read")  # staged images are useless if Read is blocked
            cmd.extend(["--allowedTools", ",".join(allowed)])
        if srv.disallowed_tools:  # type: ignore[attr-defined]
            cmd.extend(["--disallowedTools", ",".join(srv.disallowed_tools)])  # type: ignore[attr-defined]
        # Expose approved read roots (image cache, skills) to Claude Code. Only pass
        # dirs that exist so a not-yet-created cache dir can't crash the run.
        extra_dirs = list(srv.additional_dirs)  # type: ignore[attr-defined]
        if image_dir:
            extra_dirs.append(image_dir)
        for directory in extra_dirs:
            if os.path.isdir(directory):
                cmd.extend(["--add-dir", directory])
        # The guardrail system prompt only needs to be set when the session is
        # created; resumes already carry it.
        if srv.append_system_prompt and not resume_id:  # type: ignore[attr-defined]
            cmd.extend(["--append-system-prompt", srv.append_system_prompt])  # type: ignore[attr-defined]
        cmd.extend(["-p", prompt])
        return cmd

    def _handle_completion(
        self,
        request: dict[str, Any],
        model: str,
        messages: list[dict[str, Any]],
        full_prompt: str,
        stream: bool,
        image_dir: str | None = None,
        image_note: str = "",
    ) -> None:
        srv = self.server
        completion_id = f"chatcmpl-{uuid.uuid4().hex}"
        created = int(time.time())

        # Decide whether to resume an existing Claude Code session.
        resume_id: str | None = None
        prev_key = ""
        store_key = ""
        last_is_user = bool(messages) and str(messages[-1].get("role")) == "user"
        if srv.session_persistence and last_is_user:  # type: ignore[attr-defined]
            prev_key = _convo_key(messages[:-1])
            store_key = _convo_key(messages)
            resume_id = srv.sessions.get(prev_key)  # type: ignore[attr-defined]

        prompt = (_latest_user_text(messages) if resume_id else full_prompt) + image_note
        new_id = None if resume_id else str(uuid.uuid4())

        attempts = int(srv.max_retries) + 1  # type: ignore[attr-defined]
        result: dict[str, Any] = {}
        for attempt in range(attempts):
            cmd = self._build_cmd(model, prompt, resume_id, new_id, image_dir)
            lock = _session_lock(srv, resume_id) if resume_id else None
            if lock:
                lock.acquire()
            try:
                result = self._execute(cmd, stream, model, completion_id, created)
            finally:
                if lock:
                    lock.release()

            if result.get("ok") or result.get("started") or self._client_gone:
                break

            # Nothing has been sent to the client yet, so we can safely retry.
            if resume_id:
                # The stored session is stale/broken: drop it and replay the full
                # history into a fresh session.
                srv.sessions.drop(prev_key)  # type: ignore[attr-defined]
                resume_id = None
                new_id = str(uuid.uuid4())
                prompt = full_prompt + image_note
                continue
            if attempt < attempts - 1:
                time.sleep(min(2 ** attempt, 8))
                continue

        session_id = result.get("session_id")
        if (
            srv.session_persistence  # type: ignore[attr-defined]
            and result.get("ok")
            and session_id
            and store_key
        ):
            srv.sessions.put(store_key, session_id)  # type: ignore[attr-defined]

        usage = result.get("usage")
        print(
            f"[claude-code-proxy] model={model} chars={len(prompt)} stream={stream} "
            f"resume={'yes' if resume_id else 'no'} ok={result.get('ok')} "
            f"exit={result.get('exit_code')} session={session_id} "
            f"prompt_tokens={(usage or {}).get('prompt_tokens')} "
            f"completion_tokens={(usage or {}).get('completion_tokens')} "
            f"cache_read={(usage or {}).get('cache_read_input_tokens')} "
            f"cost_usd={(usage or {}).get('cost_usd')} latency_ms={result.get('latency_ms')}",
            flush=True,
        )

        if self._client_gone:
            return

        if not result.get("ok"):
            message = _safe_error_text(result.get("error") or "claude command failed")
            if stream and self._sse_started:
                # Mid-stream failure: close the SSE cleanly.
                self._finish_sse(completion_id, created, model, usage)
            elif stream:
                self._send_json(502, {"error": {"message": message, "exit_code": result.get("exit_code")}})
            else:
                self._send_json(502, {"error": {"message": message, "exit_code": result.get("exit_code")}})
            return

        content = result.get("content") or ""
        if stream:
            self._finish_sse(completion_id, created, model, usage)
            return

        self._send_json(
            200,
            {
                "id": completion_id,
                "object": "chat.completion",
                "created": created,
                "model": model,
                "choices": [
                    {
                        "index": 0,
                        "message": {"role": "assistant", "content": content},
                        "finish_reason": "stop",
                    }
                ],
                "usage": usage
                or {"prompt_tokens": 0, "completion_tokens": 0, "total_tokens": 0},
            },
        )

    def _execute(
        self, cmd: list[str], stream: bool, model: str, completion_id: str, created: int
    ) -> dict[str, Any]:
        """Run one claude invocation, translating stream-json to chat-completions output.

        Returns a result dict: ok, started, content, usage, session_id, error,
        exit_code, latency_ms.
        """
        srv = self.server
        started_at = time.time()
        session_id: str | None = None
        usage: dict[str, Any] | None = None
        result_text = ""
        delta_text: list[str] = []
        error_text: str | None = None
        rate_limited = False
        any_delta = False

        try:
            proc = subprocess.Popen(
                cmd,
                cwd=srv.cwd,  # type: ignore[attr-defined]
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                bufsize=1,
            )
        except Exception as exc:
            return {
                "ok": False,
                "started": False,
                "content": "",
                "usage": None,
                "session_id": None,
                "error": f"failed to launch claude: {exc}",
                "exit_code": None,
                "latency_ms": 0,
            }

        stderr_lines: list[str] = []

        def _drain_stderr() -> None:
            try:
                assert proc.stderr is not None
                for line in proc.stderr:
                    stderr_lines.append(line)
            except Exception:
                pass

        last_activity = [time.time()]
        stop_watchdog = threading.Event()

        def _watchdog() -> None:
            idle = srv.idle_timeout  # type: ignore[attr-defined]
            total = srv.timeout_seconds  # type: ignore[attr-defined]
            while not stop_watchdog.wait(0.5):
                now = time.time()
                if (
                    (idle and now - last_activity[0] > idle)
                    or (total and now - started_at > total)
                    or self._client_gone
                ):
                    try:
                        proc.kill()
                    except Exception:
                        pass
                    return

        threading.Thread(target=_drain_stderr, daemon=True).start()
        threading.Thread(target=_watchdog, daemon=True).start()

        try:
            assert proc.stdout is not None
            for raw_line in proc.stdout:
                last_activity[0] = time.time()
                line = raw_line.strip()
                if not line:
                    continue
                try:
                    event = json.loads(line)
                except json.JSONDecodeError:
                    continue

                etype = event.get("type")
                if etype == "system" and event.get("subtype") == "init":
                    session_id = event.get("session_id") or session_id
                elif etype == "stream_event":
                    inner = event.get("event") or {}
                    if inner.get("type") == "content_block_delta":
                        delta = inner.get("delta") or {}
                        if delta.get("type") == "text_delta":
                            text = delta.get("text") or ""
                            if text:
                                delta_text.append(text)
                                any_delta = True
                                if stream:
                                    self._emit_delta(completion_id, created, model, text)
                                    if self._client_gone:
                                        try:
                                            proc.kill()
                                        except Exception:
                                            pass
                                        break
                elif etype == "rate_limit_event":
                    info = event.get("rate_limit_info") or {}
                    if info.get("status") not in ("allowed", None):
                        rate_limited = True
                elif etype == "result":
                    session_id = event.get("session_id") or session_id
                    usage = _usage_from_result(event)
                    if event.get("is_error"):
                        error_text = (
                            event.get("api_error_status")
                            or event.get("result")
                            or "claude reported an error"
                        )
                    else:
                        result_text = event.get("result") or "".join(delta_text)
        finally:
            stop_watchdog.set()
            try:
                proc.wait(timeout=5)
            except Exception:
                try:
                    proc.kill()
                except Exception:
                    pass

        exit_code = proc.returncode
        latency_ms = int((time.time() - started_at) * 1000)
        stderr_text = "".join(stderr_lines).strip()

        ok = error_text is None and bool(result_text or any_delta) and (exit_code == 0 or exit_code is None)
        if not ok and error_text is None:
            if rate_limited:
                error_text = "claude rate-limited"
            else:
                error_text = stderr_text or f"claude exited with code {exit_code}"

        return {
            "ok": ok,
            "started": self._sse_started if stream else False,
            "content": result_text or "".join(delta_text),
            "usage": usage,
            "session_id": session_id,
            "error": error_text,
            "exit_code": exit_code,
            "rate_limited": rate_limited,
            "latency_ms": latency_ms,
        }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=18181)
    parser.add_argument("--claude-bin", default=os.getenv("CLAUDE_BIN", DEFAULT_CLAUDE_BIN))
    parser.add_argument("--cwd", default=os.getenv("CLAUDE_CODE_PROXY_CWD", os.getcwd()))
    parser.add_argument(
        "--additional-dirs",
        default=os.getenv("CLAUDE_CODE_ADDITIONAL_DIRS", ""),
        help="Comma-separated read roots passed to Claude Code with --add-dir (e.g. image cache, skills).",
    )
    parser.add_argument("--model", default=os.getenv("CLAUDE_CODE_PROXY_MODEL", DEFAULT_MODEL))
    parser.add_argument(
        "--allowed-tools",
        default=os.getenv("CLAUDE_CODE_ALLOWED_TOOLS", ""),
        help="Comma-separated Claude Code tool allowlist of MCP tools.",
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
    parser.add_argument(
        "--max-images",
        type=int,
        default=int(os.getenv("CLAUDE_CODE_MAX_IMAGES", str(DEFAULT_MAX_IMAGES))),
        help="max image_url attachments per request; 0 disables image support",
    )
    parser.add_argument(
        "--max-image-bytes",
        type=int,
        default=int(os.getenv("CLAUDE_CODE_MAX_IMAGE_BYTES", str(DEFAULT_MAX_IMAGE_BYTES))),
        help="per-image size limit in bytes",
    )
    parser.add_argument("--api-key", default=os.getenv("CLAUDE_CODE_PROXY_API_KEY", ""))
    parser.add_argument("--timeout", type=int, default=int(os.getenv("CLAUDE_CODE_TIMEOUT", "600")))
    parser.add_argument("--pass-model", action="store_true")

    # New capability flags.
    parser.add_argument(
        "--stream-output",
        action=argparse.BooleanOptionalAction,
        default=os.getenv("CLAUDE_CODE_STREAM_OUTPUT", "1") not in ("0", "false", "False"),
        help="Translate Claude stream-json into chat-completions SSE deltas for streaming requests.",
    )
    parser.add_argument(
        "--session-persistence",
        action=argparse.BooleanOptionalAction,
        default=os.getenv("CLAUDE_CODE_SESSION_PERSISTENCE", "1") not in ("0", "false", "False"),
        help="Map conversations to persistent Claude Code sessions and resume them across turns.",
    )
    parser.add_argument(
        "--session-store",
        default=os.getenv("CLAUDE_CODE_SESSION_STORE", DEFAULT_SESSION_STORE),
        help="Path to the JSON conversation->session-id map (persisted on the PVC).",
    )
    parser.add_argument(
        "--max-sessions",
        type=int,
        default=int(os.getenv("CLAUDE_CODE_MAX_SESSIONS", str(DEFAULT_MAX_SESSIONS))),
    )
    parser.add_argument(
        "--max-concurrency",
        type=int,
        default=int(os.getenv("CLAUDE_CODE_MAX_CONCURRENCY", "4")),
        help="Maximum simultaneous claude subprocesses.",
    )
    parser.add_argument(
        "--queue-timeout",
        type=int,
        default=int(os.getenv("CLAUDE_CODE_QUEUE_TIMEOUT", "30")),
        help="Seconds a request waits for a concurrency slot before returning 503.",
    )
    parser.add_argument(
        "--idle-timeout",
        type=int,
        default=int(os.getenv("CLAUDE_CODE_IDLE_TIMEOUT", "180")),
        help="Kill a claude run if it produces no output for this many seconds (0 disables).",
    )
    parser.add_argument(
        "--max-retries",
        type=int,
        default=int(os.getenv("CLAUDE_CODE_MAX_RETRIES", "1")),
        help="Retries on transient failures before any bytes are sent to the client.",
    )
    args = parser.parse_args()

    if not os.path.exists(args.claude_bin):
        raise SystemExit(f"claude binary not found: {args.claude_bin}")
    if not os.path.isdir(args.cwd):
        raise SystemExit(f"working directory not found: {args.cwd}")

    server = ThreadingHTTPServer((args.host, args.port), ClaudeProxyHandler)
    server.claude_bin = args.claude_bin  # type: ignore[attr-defined]
    server.cwd = args.cwd  # type: ignore[attr-defined]
    server.additional_dirs = _split_csv(args.additional_dirs)  # type: ignore[attr-defined]
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
    server.max_images = args.max_images  # type: ignore[attr-defined]
    server.max_image_bytes = args.max_image_bytes  # type: ignore[attr-defined]
    server.append_system_prompt = args.append_system_prompt  # type: ignore[attr-defined]
    server.api_key = args.api_key  # type: ignore[attr-defined]
    server.stream_output = args.stream_output  # type: ignore[attr-defined]
    server.session_persistence = args.session_persistence  # type: ignore[attr-defined]
    server.session_store_path = args.session_store  # type: ignore[attr-defined]
    server.sessions = SessionStore(args.session_store, args.max_sessions)  # type: ignore[attr-defined]
    server.session_locks = {}  # type: ignore[attr-defined]
    server.session_locks_master = threading.Lock()  # type: ignore[attr-defined]
    server.max_concurrency = args.max_concurrency  # type: ignore[attr-defined]
    server.concurrency = threading.BoundedSemaphore(max(1, args.max_concurrency))  # type: ignore[attr-defined]
    server.queue_timeout = args.queue_timeout  # type: ignore[attr-defined]
    server.idle_timeout = args.idle_timeout  # type: ignore[attr-defined]
    server.max_retries = args.max_retries  # type: ignore[attr-defined]

    printable_cmd = shlex.join(
        [args.claude_bin, "--model", args.model, "--effort", args.effort, "--output-format", "stream-json", "-p", "..."]
    )
    print(
        f"[claude-code-proxy] listening on http://{args.host}:{args.port}/v1 "
        f"model={args.model} claude_bin={args.claude_bin} cwd={args.cwd} "
        f"additional_dirs={server.additional_dirs or '(none)'} "  # type: ignore[attr-defined]
        f"settings_local={server.settings_local} effort={args.effort} "  # type: ignore[attr-defined]
        f"permission_mode={args.permission_mode} stream_output={args.stream_output} "
        f"session_persistence={args.session_persistence} session_store={args.session_store} "
        f"sessions_loaded={server.sessions.count()} max_concurrency={args.max_concurrency} "  # type: ignore[attr-defined]
        f"idle_timeout={args.idle_timeout} timeout={args.timeout} "
        f"allowed_tools={server.allowed_tools or '(none)'} "  # type: ignore[attr-defined]
        f"disallowed_tools={server.disallowed_tools or '(none)'} "  # type: ignore[attr-defined]
        f"api_key_required={bool(args.api_key)} command={printable_cmd}",
        flush=True,
    )
    server.serve_forever()


if __name__ == "__main__":
    main()
