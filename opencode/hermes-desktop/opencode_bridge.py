#!/usr/bin/env python3
"""opencode_bridge.py — OpenAI-compatible bridge from Hermes to the OpenCode CLI.

Fulfils each request by invoking an already-authenticated ``opencode run`` process and
exposes it over an OpenAI-compatible chat-completions HTTP surface, so Hermes (or any
chat-completions client) can point a *custom endpoint* provider at it and drive
OpenCode's **free** models (opencode zen: MiMo, DeepSeek, Nemotron, …).

Sibling of ``../../mac/claude_code_bridge.py`` — same wire protocol, different backend.

Highlights:
  * Free-by-default — the advertised catalogue is discovered from
    ``opencode models --verbose`` and filtered to models whose input *and* output
    cost is 0, so a mis-typed model can't silently start billing a paid provider.
    Escape hatch: ``--no-free-only`` / ``--models``.
  * Real usage — every ``step_finish`` event carries per-step tokens/cost; the bridge
    sums them across the whole agentic run and reports them in ``usage``.
  * Real streaming — ``--format json`` events become incremental
    ``chat.completion.chunk`` SSE deltas, de-duplicated by part id so re-emitted
    (growing) text parts only ever send their new suffix.
  * Prompt on stdin — never argv, so a 200k-char prompt can't hit ARG_MAX.
  * Concurrency control — a bounded semaphore caps concurrent ``opencode``
    subprocesses (free tiers rate-limit), with a fast 429 when saturated.
  * Housekeeping — ``opencode run`` always persists a session; the bridge deletes
    the sessions it created (``--keep-sessions`` to opt out).
  * Operability — process-group kill on timeout, graceful SIGTERM/SIGINT drain,
    constant-time auth, and ``/health`` / ``/config`` / ``/v1/models`` / ``/metrics``.

Stdlib only; no third-party deps, so it stays trivially portable onto a developer host
or into a slim container.
"""

from __future__ import annotations

import argparse
import base64
import hmac
import json
import os
import shutil
import signal
import subprocess
import tempfile
import threading
import time
import urllib.parse
import urllib.request
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any, Iterator, Optional

BRIDGE_VERSION = "1.0.0"
_IS_WINDOWS = os.name == "nt"


def default_opencode_bin() -> str:
    """Best-effort cross-platform default for the OpenCode CLI."""
    env = os.getenv("OPENCODE_BIN")
    if env:
        return env
    found = shutil.which("opencode")
    if found:
        return found
    return os.path.expanduser("~/.opencode/bin/opencode")


def resolve_opencode_bin(value: str) -> Optional[str]:
    """Return an existing path for ``value`` (direct path or a PATH lookup)."""
    if value and os.path.exists(value):
        return value
    return shutil.which(value) if value else None


DEFAULT_OPENCODE_BIN = default_opencode_bin()
# opencode zen's free tier — what the OpenCode desktop model picker labels "… Free".
DEFAULT_MODEL = "opencode/mimo-v2.5-free"
# Providers scanned for the advertised catalogue. `opencode` is opencode zen, which
# hosts the free models; add more (comma-separated) to surface your own keys' models.
DEFAULT_MODEL_PROVIDERS = "opencode"
# Last-resort catalogue. The live list always comes from `opencode models --verbose`
# (see discover_models), and every successful discovery is persisted to --model-cache,
# which is preferred over this list when discovery fails. These IDs are therefore only
# reached on a cold start with no network AND no cache — they are a seed, not the source
# of truth, and are expected to drift as opencode zen's free tier changes.
FALLBACK_FREE_MODELS = [
    "opencode/mimo-v2.5-free",
    "opencode/deepseek-v4-flash-free",
    "opencode/nemotron-3-ultra-free",
    "opencode/ling-3.0-flash-free",
    "opencode/laguna-s-2.1-free",
    "opencode/north-mini-code-free",
    "opencode/big-pickle",
]
# How often to re-run discovery so a long-lived process picks up models opencode zen
# adds or retires without a restart. 0 disables it.
DEFAULT_MODEL_REFRESH_INTERVAL = 3600
DEFAULT_MAX_PROMPT_CHARS = 200_000
# Images: chat-completions ``image_url`` parts are extracted to temp files and attached
# via ``opencode run --file``, which forwards them to the model. 0 disables image
# handling entirely (image parts are then silently dropped, as before).
DEFAULT_MAX_IMAGES = 4
DEFAULT_MAX_IMAGE_BYTES = 10 * 1024 * 1024
DEFAULT_TIMEOUT = 300
# Free tiers rate-limit aggressively, so default lower than the Claude bridge.
DEFAULT_MAX_CONCURRENCY = 2
DEFAULT_QUEUE_WAIT = 30  # seconds a request waits for a concurrency slot before 429

_REDACT_MARKERS = ("sk-ant-", "sk-", "Bearer ", "Authorization:", "api_key", "apiKey")
# Substrings that mark an upstream error as "retry later" rather than "bad request".
_RATE_LIMIT_MARKERS = ("rate limit", "rate_limit", "429", "too many requests", "quota", "overloaded")


# ── helpers ──────────────────────────────────────────────────────────────────
def _split_csv(value: str) -> list[str]:
    return [part.strip() for part in (value or "").split(",") if part.strip()]


def _text_from_content(content: Any) -> str:
    """Flatten a chat-completions message ``content`` (str or list of parts) to text."""
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        parts: list[str] = []
        for item in content:
            if isinstance(item, dict) and item.get("type") == "text" and isinstance(item.get("text"), str):
                parts.append(item["text"])
            elif isinstance(item, str):
                parts.append(item)
        return "\n".join(parts)
    return "" if content is None else str(content)


# ── images ───────────────────────────────────────────────────────────────────
_DATA_URL_PREFIX = "data:"
_EXT_BY_MIME = {
    "image/png": ".png", "image/jpeg": ".jpg", "image/jpg": ".jpg",
    "image/webp": ".webp", "image/gif": ".gif",
}


class ImageExtractionError(ValueError):
    """A client-supplied image could not be decoded/attached (HTTP 400)."""


def _decode_image_url(url: str, index: int) -> tuple[bytes, Optional[str]]:
    """Return (bytes, mime) for a chat-completions ``image_url`` value."""
    url = (url or "").strip()
    if not url:
        raise ImageExtractionError(f"message contains an empty image_url (image #{index + 1})")
    if url.startswith(_DATA_URL_PREFIX):
        header, _, payload = url.partition(",")
        mime = header[len(_DATA_URL_PREFIX):].split(";", 1)[0].strip().lower() or None
        try:
            data = base64.b64decode(payload, validate=True)
        except Exception as exc:
            raise ImageExtractionError(f"image #{index + 1}: invalid base64 data ({exc})") from exc
        return data, mime
    parsed = urllib.parse.urlparse(url)
    if parsed.scheme == "file":
        path = urllib.request.url2pathname(parsed.path)
        try:
            with open(path, "rb") as handle:
                return handle.read(), None
        except OSError as exc:
            raise ImageExtractionError(f"image #{index + 1}: cannot read {path!r} ({exc})") from exc
    if parsed.scheme in ("http", "https"):
        try:
            request = urllib.request.Request(url, headers={"User-Agent": "opencode-bridge"})
            with urllib.request.urlopen(request, timeout=30) as response:
                mime = (response.headers.get("content-type") or "").split(";", 1)[0].strip().lower()
                return response.read(), mime or None
        except OSError as exc:
            raise ImageExtractionError(f"image #{index + 1}: fetch failed ({exc})") from exc
    raise ImageExtractionError(
        f"image #{index + 1}: unsupported image_url scheme {parsed.scheme!r} "
        "(expected a data:, file: or http(s): URL)")


def extract_images(messages: list[dict[str, Any]], max_images: int,
                   max_bytes_per_image: int) -> list[tuple[bytes, Optional[str]]]:
    """Collect ``(data, mime)`` for every ``image_url`` content part in ``messages``.

    Order follows the conversation; each image is returned once even if a client
    re-sends history across turns.
    """
    found: list[tuple[bytes, Optional[str]]] = []
    for message in messages or []:
        content = message.get("content")
        if not isinstance(content, list):
            continue
        for item in content:
            if not (isinstance(item, dict) and item.get("type") == "image_url"):
                continue
            url = ""
            inner = item.get("image_url")
            if isinstance(inner, dict):
                url = str(inner.get("url") or "")
            elif isinstance(inner, str):
                url = inner
            found.append(_decode_image_url(url, len(found)))
    if max_images <= 0:
        if found:
            raise ImageExtractionError(
                "this bridge has image support disabled (--max-images 0); resend text-only")
        return []
    if len(found) > max_images:
        raise ImageExtractionError(
            f"too many images: {len(found)} exceeds the limit of {max_images} per request")
    oversized = [i + 1 for i, image in enumerate(found) if len(image[0]) > max_bytes_per_image]
    if oversized:
        raise ImageExtractionError(
            f"image(s) {oversized} exceed the per-image limit of {max_bytes_per_image // (1024 * 1024)} MiB")
    return found


def stage_image_files(images: list[tuple[bytes, Optional[str]]]) -> list[str]:
    """Write extracted images to temp files for ``opencode run --file``.

    Returns absolute paths; cleanup is delegated to ``tempfile.mkdtemp`` via
    :func:`cleanup_image_files` so a crashed run can never leave them behind.
    """
    directory = tempfile.mkdtemp(prefix="opencode-bridge-img-")
    paths: list[str] = []
    for index, (data, mime) in enumerate(images):
        ext = _EXT_BY_MIME.get((mime or "").lower())
        if not ext:
            head = bytes(data[:16])
            sniffed = ("png" if head.startswith(b"\x89PNG\r\n\x1a\n")
                       else "jpg" if head.startswith(b"\xff\xd8")
                       else "gif" if head.startswith(b"GIF8")
                       else "webp" if head[0:4] == b"RIFF" and head[8:12] == b"WEBP"
                       else "")
            ext = f".{sniffed}" if sniffed else ".bin"
        path = os.path.join(directory, f"image-{index + 1}{ext}")
        with open(path, "wb") as handle:
            handle.write(data)
        paths.append(path)
    return paths


def cleanup_image_files(paths: Optional[list[str]]) -> None:
    """Remove a staged temp directory (best-effort)."""
    if not paths:
        return
    parent = os.path.dirname(paths[0])
    shutil.rmtree(parent, ignore_errors=True)


def build_prompt(messages: list[dict[str, Any]]) -> str:
    """Flatten chat-completions messages into a single OpenCode prompt.

    ``opencode run`` has no ``--append-system-prompt``, so system turns are hoisted
    into a delimited block at the top of the prompt; user/assistant turns keep their
    roles so multi-turn context survives.
    """
    system_parts: list[str] = []
    convo: list[str] = []
    for message in messages or []:
        role = str(message.get("role") or "user").lower()
        text = _text_from_content(message.get("content")).strip()
        if not text:
            continue
        if role == "system":
            system_parts.append(text)
        else:
            convo.append(f"{role.upper()}:\n{text}")
    blocks: list[str] = []
    if system_parts:
        blocks.append("<system-instructions>\n" + "\n\n".join(system_parts) + "\n</system-instructions>")
    blocks.append("\n\n".join(convo))
    return "\n\n".join(b for b in blocks if b).strip()


def _safe_error_text(text: str) -> str:
    redacted = (text or "").strip()
    for marker in _REDACT_MARKERS:
        if marker in redacted:
            redacted = redacted.replace(marker, f"{marker[:3]}[redacted]")
    return redacted[-4000:]


def _usage_block(tokens: dict[str, int]) -> dict[str, int]:
    """Map summed OpenCode step tokens → chat-completions usage.

    OpenCode reports ``input``, ``output``, ``reasoning`` and ``cache.{read,write}``
    separately, and its own ``total`` is their sum. Cache traffic is prompt-side;
    reasoning is billed as output — so fold them in accordingly.
    """
    inp = int(tokens.get("input", 0)) + int(tokens.get("cache_read", 0)) + int(tokens.get("cache_write", 0))
    out = int(tokens.get("output", 0)) + int(tokens.get("reasoning", 0))
    return {"prompt_tokens": inp, "completion_tokens": out, "total_tokens": inp + out}


def _accumulate_tokens(total: dict[str, int], part: dict[str, Any]) -> None:
    """Add one ``step-finish`` part's token counts into ``total`` (in place)."""
    tok = part.get("tokens") or {}
    cache = tok.get("cache") or {}
    for key, value in (("input", tok.get("input")), ("output", tok.get("output")),
                       ("reasoning", tok.get("reasoning")),
                       ("cache_read", cache.get("read")), ("cache_write", cache.get("write"))):
        try:
            total[key] = total.get(key, 0) + int(value or 0)
        except (TypeError, ValueError):
            pass


def _finish_reason(reason: Optional[str]) -> str:
    """Map an OpenCode step-finish reason to an OpenAI ``finish_reason``."""
    return {"length": "length", "content-filter": "content_filter"}.get((reason or "").strip(), "stop")


def _tool_note(part: dict[str, Any]) -> Optional[str]:
    """Render a tool_use part as a one-line progress note (``--show-tools``)."""
    name = str(part.get("tool") or "tool")
    state = part.get("state") or {}
    args = state.get("input") if isinstance(state.get("input"), dict) else {}
    hint = ""
    # "name" covers the skill/agent tools — without it a failing `skill(name=…)` rendered
    # as a bare `skill()`, which hides *which* skill could not be loaded.
    for key in ("filePath", "path", "pattern", "command", "url", "query", "name", "description"):
        value = args.get(key)
        if isinstance(value, str) and value.strip():
            hint = value.strip().replace("\n", " ")[:120]
            break
    status = str(state.get("status") or "")
    mark = "✗" if status == "error" else "›"
    return f"\n{mark} {name}({hint})\n" if status in ("completed", "error") else None


# ── model discovery ───────────────────────────────────────────────────────────
def _parse_verbose_models(output: str) -> list[tuple[str, dict[str, Any]]]:
    """Parse ``opencode models <provider> --verbose``.

    The format is an id line (``provider/model``) followed by a pretty-printed JSON
    object whose braces sit in column 0 — so accumulate between those anchors.
    """
    models: list[tuple[str, dict[str, Any]]] = []
    pending: Optional[str] = None
    buffer: list[str] = []
    for line in (output or "").splitlines():
        if buffer:
            buffer.append(line)
            if line == "}":
                try:
                    meta = json.loads("\n".join(buffer))
                except json.JSONDecodeError:
                    meta = {}
                if pending:
                    models.append((pending, meta if isinstance(meta, dict) else {}))
                pending, buffer = None, []
            continue
        if line == "{":
            buffer = [line]
            continue
        stripped = line.strip()
        if stripped and stripped == line and "/" in stripped and not stripped.startswith(("{", "}", "[")):
            pending = stripped
    return models


def _is_free(meta: dict[str, Any]) -> bool:
    cost = meta.get("cost") or {}
    try:
        return float(cost.get("input", 0) or 0) == 0.0 and float(cost.get("output", 0) or 0) == 0.0
    except (TypeError, ValueError):
        return False


def discover_models(opencode_bin: str, providers: list[str], free_only: bool,
                    timeout: int = 60, refresh: bool = True) -> tuple[list[str], dict[str, dict[str, Any]]]:
    """Return (model_ids, metadata_by_id) from the OpenCode model catalogue.

    ``refresh`` adds ``--refresh``, which re-pulls the catalogue from models.dev so a
    newly published free model is seen. That needs network, so on failure the same
    command is retried against the local cache — a stale catalogue beats none.
    """
    ids: list[str] = []
    meta_by_id: dict[str, dict[str, Any]] = {}
    for provider in providers or [""]:
        base = [opencode_bin, "models"] + ([provider] if provider else []) + ["--verbose"]
        attempts = ([base + ["--refresh"]] if refresh else []) + [base]
        stdout = ""
        for cmd in attempts:
            try:
                proc = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
            except (OSError, subprocess.SubprocessError):
                continue
            if proc.returncode == 0 and proc.stdout.strip():
                stdout = proc.stdout
                break
        for model_id, meta in _parse_verbose_models(stdout):
            if model_id in meta_by_id:
                continue
            if free_only and not _is_free(meta):
                continue
            ids.append(model_id)
            meta_by_id[model_id] = meta
    return ids, meta_by_id


def _cache_payload(models: list[str], meta: dict[str, dict[str, Any]], free_only: bool) -> dict[str, Any]:
    """Shape the discovered catalogue for the on-disk cache."""
    entries: dict[str, Any] = {}
    for model_id in models:
        info = meta.get(model_id) or {}
        limit = info.get("limit") or {}
        entries[model_id] = {
            "name": info.get("name") or model_id,
            "context_length": limit.get("context"),
            "free": _is_free(info) if info else None,
        }
    return {"updated_at": int(time.time()), "free_only": free_only, "models": entries}


def write_model_cache(path: str, models: list[str], meta: dict[str, dict[str, Any]],
                      free_only: bool) -> None:
    """Persist a successful discovery so a later cold start isn't stuck on the seed list.

    Also read by the deployment's ``init-hermes-config`` to build the dashboard's model
    picker, which is why the file carries context lengths and not just IDs.
    """
    if not path:
        return
    try:
        os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
        tmp = f"{path}.tmp.{os.getpid()}"
        with open(tmp, "w", encoding="utf-8") as handle:
            # NOT sort_keys: discovery order is meaningful — the first entry is what a
            # retired default model falls back to, and it drives the picker's ordering.
            json.dump(_cache_payload(models, meta, free_only), handle, indent=2)
        os.replace(tmp, path)  # atomic: a reader never sees a half-written file
    except OSError as exc:
        print(f"[opencode-bridge] warning: could not write model cache {path}: {exc}", flush=True)


def read_model_cache(path: str) -> tuple[list[str], dict[str, dict[str, Any]]]:
    """Load a previously discovered catalogue. Returns ([], {}) when unusable."""
    if not path:
        return [], {}
    try:
        with open(path, encoding="utf-8") as handle:
            payload = json.load(handle)
        entries = payload.get("models")
        if not isinstance(entries, dict):
            return [], {}
        ids = [str(k) for k in entries]
        # Re-shape into the same metadata form discovery produces, so /v1/models keeps
        # reporting context_length and the free flag from cached data.
        meta = {}
        for model_id, info in entries.items():
            info = info if isinstance(info, dict) else {}
            meta[str(model_id)] = {
                "name": info.get("name"),
                "providerID": str(model_id).split("/", 1)[0],
                "limit": {"context": info.get("context_length")},
                "cost": {"input": 0, "output": 0} if info.get("free") else {},
            }
        return ids, meta
    except (OSError, json.JSONDecodeError, TypeError, ValueError):
        return [], {}


# ── the OpenCode invocation ───────────────────────────────────────────────────
class OpenCodeError(RuntimeError):
    def __init__(self, message: str, exit_code: int = 502) -> None:
        super().__init__(message)
        self.exit_code = exit_code


def classify_error(message: str) -> int:
    """502 for a generic upstream failure, 429 when the free tier is rate-limiting."""
    lowered = (message or "").lower()
    return 429 if any(marker in lowered for marker in _RATE_LIMIT_MARKERS) else 502


def build_command(cfg: "BridgeConfig", model: str, image_files: Optional[list[str]] = None) -> list[str]:
    cmd = [cfg.opencode_bin, "run", "--format", "json", "--model", model]
    if cfg.auto_approve:
        cmd.append("--auto")
    if cfg.show_reasoning:
        cmd.append("--thinking")
    if cfg.agent:
        cmd += ["--agent", cfg.agent]
    if cfg.variant:
        cmd += ["--variant", cfg.variant]
    if cfg.pure:
        cmd.append("--pure")
    # Attachments must be ``--file=<path>`` (not ``--file <path>``): yargs would
    # otherwise eat the following positional as a second file name.
    for path in image_files or []:
        cmd.append(f"--file={path}")
    cmd += ["--dir", cfg.cwd]
    return cmd


def _popen(cmd: list[str], cfg: "BridgeConfig") -> subprocess.Popen:
    # Put the child in its own group/session so a timeout can kill the whole tree
    # (opencode spawns tool subprocesses), portably across POSIX and Windows.
    kwargs: dict[str, Any] = {}
    if _IS_WINDOWS:
        kwargs["creationflags"] = subprocess.CREATE_NEW_PROCESS_GROUP  # type: ignore[attr-defined]
    else:
        kwargs["start_new_session"] = True
    return subprocess.Popen(
        cmd, cwd=cfg.cwd, text=True,
        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        **kwargs,
    )


def _kill(proc: subprocess.Popen) -> None:
    """Terminate the child (and its group on POSIX), escalating to kill."""
    try:
        if _IS_WINDOWS or not hasattr(os, "killpg"):
            proc.terminate()
            try:
                proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                proc.kill()
        else:
            os.killpg(os.getpgid(proc.pid), signal.SIGTERM)
            try:
                proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                os.killpg(os.getpgid(proc.pid), signal.SIGKILL)
    except (ProcessLookupError, PermissionError, OSError):
        pass


def delete_session(cfg: "BridgeConfig", session_id: str) -> None:
    """Best-effort cleanup of a session ``opencode run`` persisted for us."""
    if not session_id or not cfg.delete_sessions:
        return
    try:
        subprocess.run([cfg.opencode_bin, "session", "delete", session_id],
                       cwd=cfg.cwd, capture_output=True, text=True, timeout=30)
    except (OSError, subprocess.SubprocessError):
        pass


def run_events(cfg: "BridgeConfig", model: str, prompt: str,
               image_files: Optional[list[str]] = None) -> Iterator[dict[str, Any]]:
    """Run ``opencode run`` and yield normalized events.

    Yields ``{'delta': str}`` for assistant text (and tool/reasoning notes when
    enabled), then a final ``{'done': True, 'tokens': {...}, 'cost_usd': float,
    'finish_reason': str}``. The prompt goes in on stdin so it is never argv-bound.
    ``image_files`` are staged temp files attached via ``--file=<path>`` and the
    whole staging directory is removed when the run ends.
    """
    cmd = build_command(cfg, model, image_files)
    proc = _popen(cmd, cfg)
    deadline = time.time() + cfg.timeout_seconds
    tokens: dict[str, int] = {}
    cost = 0.0
    finish = "stop"
    session_id = ""
    # Text parts may be re-emitted as they grow; remember how much of each part id
    # we have already forwarded so a delta is only ever the new suffix.
    emitted: dict[str, int] = {}
    error: Optional[OpenCodeError] = None

    def _writer() -> None:
        try:
            assert proc.stdin is not None
            proc.stdin.write(prompt)
            proc.stdin.close()
        except (BrokenPipeError, OSError, ValueError):
            pass

    threading.Thread(target=_writer, daemon=True).start()
    try:
        assert proc.stdout is not None
        for line in proc.stdout:
            if time.time() > deadline:
                _kill(proc)
                raise OpenCodeError("opencode command timed out", exit_code=504)
            line = line.strip()
            if not line or not line.startswith("{"):
                continue  # CLI banners / progress chrome — not events
            try:
                event = json.loads(line)
            except json.JSONDecodeError:
                continue
            session_id = event.get("sessionID") or session_id
            etype = event.get("type")
            part = event.get("part") or {}
            if etype in ("text", "reasoning"):
                text = part.get("text") or ""
                if etype == "reasoning" and not cfg.show_reasoning:
                    continue
                seen = emitted.get(part.get("id") or "", 0)
                if len(text) > seen:
                    emitted[part.get("id") or ""] = len(text)
                    chunk = text[seen:]
                    yield {"delta": f"\n_thinking:_ {chunk}\n" if etype == "reasoning" else chunk}
            elif etype == "tool_use" and cfg.show_tools:
                note = _tool_note(part)
                if note:
                    yield {"delta": note}
            elif etype == "step_finish":
                _accumulate_tokens(tokens, part)
                try:
                    cost += float(part.get("cost") or 0)
                except (TypeError, ValueError):
                    pass
                finish = _finish_reason(part.get("reason"))
            elif etype == "error":
                info = event.get("error") or {}
                data = info.get("data") if isinstance(info.get("data"), dict) else {}
                message = str((data or {}).get("message") or info.get("name") or "opencode error")
                error = OpenCodeError(_safe_error_text(message), classify_error(message))
        rc = proc.wait(timeout=10)
        if error is not None:
            raise error
        if rc != 0:
            err = (proc.stderr.read() if proc.stderr else "") or ""
            message = _safe_error_text(err or f"opencode exited with code {rc}")
            raise OpenCodeError(message, classify_error(message))
    finally:
        if proc.poll() is None:
            _kill(proc)
        if session_id:
            threading.Thread(target=delete_session, args=(cfg, session_id), daemon=True).start()
        cleanup_image_files(image_files)
    yield {"done": True, "tokens": tokens, "cost_usd": cost, "finish_reason": finish}


def run_blocking(cfg: "BridgeConfig", model: str, prompt: str,
                 image_files: Optional[list[str]] = None) -> dict[str, Any]:
    """Drain ``run_events`` and return {'text','tokens','cost_usd','finish_reason'}."""
    chunks: list[str] = []
    tokens: dict[str, int] = {}
    cost = 0.0
    finish = "stop"
    for event in run_events(cfg, model, prompt, image_files):
        if "delta" in event:
            chunks.append(event["delta"])
        elif event.get("done"):
            tokens, cost, finish = event["tokens"], event["cost_usd"], event["finish_reason"]
    return {"text": "".join(chunks).strip(), "tokens": tokens, "cost_usd": cost, "finish_reason": finish}


# ── config ────────────────────────────────────────────────────────────────────
class BridgeConfig:
    def __init__(self, args: argparse.Namespace) -> None:
        self.opencode_bin = args.opencode_bin
        self.cwd = args.cwd
        self.default_model = args.model
        self.model_providers = _split_csv(args.model_providers)
        self.free_only = args.free_only
        self.agent = args.agent
        self.variant = args.variant
        self.auto_approve = args.auto_approve
        self.show_tools = args.show_tools
        self.show_reasoning = args.show_reasoning
        self.pure = args.pure
        self.delete_sessions = args.delete_sessions
        self.max_prompt_chars = args.max_prompt_chars
        self.max_images = args.max_images
        self.max_image_bytes = args.max_image_bytes
        self.timeout_seconds = args.timeout
        self.pass_model = args.pass_model
        self.api_key = args.api_key
        # Advertised catalogue: explicit --models wins, else discovery, else fallback.
        # The default model is always first so a client can never pick something the
        # bridge would refuse to run.
        self.model_cache = args.model_cache
        self.model_refresh_interval = args.model_refresh_interval
        # Catalogue mutates from the refresh thread while requests read it.
        self._lock = threading.Lock()
        configured = _split_csv(args.models)
        self.discovered_from = "flag" if configured else "pending"
        self.models = self._order(configured)
        self.model_meta: dict[str, dict[str, Any]] = {}
        # Whether the default model came from the catalogue itself rather than
        # only from being force-prepended (drives a startup warning).
        self.default_in_catalogue = args.model in configured

    def _order(self, ids: list[str]) -> list[str]:
        ordered = [self.default_model] + [m for m in ids if m != self.default_model]
        seen: set[str] = set()
        return [m for m in ordered if not (m in seen or seen.add(m))]

    def refresh_catalogue(self, *, refresh: bool = True) -> dict[str, Any]:
        """Repoint the advertised catalogue at whatever the CLI currently offers.

        Precedence: live discovery → on-disk cache → the seed list. Called at startup and
        again on a timer, so free models opencode zen adds appear and retired ones drop
        out without a restart. Returns a small summary for logging/the refresh endpoint.
        """
        if self.discovered_from == "flag":
            return {"source": "flag", "models": len(self.models), "changed": False}

        before = list(self.models)
        ids, meta = discover_models(self.opencode_bin, self.model_providers, self.free_only,
                                    refresh=refresh)
        if ids:
            source = "opencode-cli"
            write_model_cache(self.model_cache, ids, meta, self.free_only)
        else:
            ids, meta = read_model_cache(self.model_cache)
            source = "cache" if ids else "fallback"
            if not ids:
                ids, meta = list(FALLBACK_FREE_MODELS), {}

        with self._lock:
            self.model_meta = meta
            self.discovered_from = source
            self.default_in_catalogue = self.default_model in ids
            # If the configured default is gone from the catalogue (retired from the free
            # tier, renamed, typo'd), adopt the first discovered model rather than keep
            # advertising something the CLI can no longer run.
            if not self.default_in_catalogue and self.free_only and ids:
                previous = self.default_model
                self.default_model = ids[0]
                print(f"[opencode-bridge] default model {previous!r} is no longer in the "
                      f"{source} catalogue — falling back to {self.default_model!r}", flush=True)
            self.models = self._order(ids)

        added = [m for m in self.models if m not in before]
        removed = [m for m in before if m not in self.models]
        if before and (added or removed):
            print(f"[opencode-bridge] catalogue changed via {source}: "
                  f"+{added or '[]'} -{removed or '[]'}", flush=True)
        return {"source": source, "models": len(self.models), "default": self.default_model,
                "added": added, "removed": removed, "changed": bool(added or removed)}

    def start_refresh_loop(self) -> None:
        """Re-discover on a timer so the catalogue tracks the free tier by itself."""
        if self.model_refresh_interval <= 0 or self.discovered_from == "flag":
            return

        def _loop() -> None:
            while True:
                time.sleep(self.model_refresh_interval)
                try:
                    self.refresh_catalogue()
                except Exception as exc:  # noqa: BLE001 — a refresh must never kill serving
                    print(f"[opencode-bridge] model refresh failed: {exc}", flush=True)

        threading.Thread(target=_loop, daemon=True, name="model-refresh").start()

    def resolve_model(self, requested: str) -> tuple[Optional[str], Optional[str]]:
        """Return (model_id, error). Accepts bare ids and ``provider/model`` ids."""
        if not self.pass_model:
            return self.default_model, None
        wanted = (requested or "").strip()
        if not wanted:
            return self.default_model, None
        if wanted in self.models:
            return wanted, None
        # Convenience aliases: bare "mimo-v2.5-free" → "opencode/mimo-v2.5-free",
        # and a case-insensitive match, so Hermes' free-text model box is forgiving.
        if "/" not in wanted:
            for provider in self.model_providers or ["opencode"]:
                candidate = f"{provider}/{wanted}"
                if candidate in self.models:
                    return candidate, None
        for model in self.models:
            if model.lower() == wanted.lower():
                return model, None
        if not self.free_only and "/" in wanted:
            return wanted, None  # unrestricted mode: trust the client, let opencode judge
        return None, (
            f"model {wanted!r} is not available on this bridge. It serves "
            f"{'free ' if self.free_only else ''}OpenCode models: {', '.join(self.models[:12])}"
            f"{' …' if len(self.models) > 12 else ''}. See GET /v1/models."
        )


# ── metrics ────────────────────────────────────────────────────────────────────
class Metrics:
    def __init__(self) -> None:
        self._lock = threading.Lock()
        self.requests = 0
        self.errors = 0
        self.rejected_busy = 0
        self.total_cost_usd = 0.0
        self.total_output_tokens = 0
        self.started = time.time()

    def record(self, *, error: bool = False, cost: Optional[float] = None, out_tokens: int = 0) -> None:
        with self._lock:
            self.requests += 1
            if error:
                self.errors += 1
            if cost:
                self.total_cost_usd += float(cost)
            self.total_output_tokens += int(out_tokens or 0)

    def snapshot(self, in_flight: int) -> dict[str, Any]:
        with self._lock:
            return {
                "uptime_s": int(time.time() - self.started),
                "requests": self.requests,
                "errors": self.errors,
                "rejected_busy": self.rejected_busy,
                "in_flight": in_flight,
                "total_cost_usd": round(self.total_cost_usd, 6),
                "total_output_tokens": self.total_output_tokens,
            }


# ── HTTP handler ────────────────────────────────────────────────────────────────
class BridgeHandler(BaseHTTPRequestHandler):
    server_version = f"OpenCodeBridge/{BRIDGE_VERSION}"

    @property
    def cfg(self) -> BridgeConfig:
        return self.server.cfg  # type: ignore[attr-defined]

    def _send_json(self, code: int, payload: dict[str, Any]) -> None:
        body = json.dumps(payload).encode("utf-8")
        self.send_response(code)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(body)))
        self.end_headers()
        try:
            self.wfile.write(body)
        except BrokenPipeError:
            pass

    def _authorized(self) -> bool:
        expected = str(self.cfg.api_key or "")
        if not expected:
            return True
        bearer = (self.headers.get("authorization") or "").removeprefix("Bearer ").strip()
        x_api_key = (self.headers.get("x-api-key") or "").strip()
        return hmac.compare_digest(bearer, expected) or hmac.compare_digest(x_api_key, expected)

    def log_message(self, fmt: str, *args: Any) -> None:  # structured-ish access log
        print(f"[opencode-bridge] {self.address_string()} - {fmt % args}", flush=True)

    def _model_obj(self, model_id: str) -> dict[str, Any]:
        meta = self.cfg.model_meta.get(model_id) or {}
        obj: dict[str, Any] = {"id": model_id, "object": "model", "created": 0,
                               "owned_by": (meta.get("providerID") or "opencode-cli")}
        limit = meta.get("limit") or {}
        if limit.get("context"):
            obj["context_length"] = limit["context"]
        if meta.get("name"):
            obj["display_name"] = meta["name"]
        if meta:
            obj["free"] = _is_free(meta)
        return obj

    # ── GET ──
    def do_GET(self) -> None:
        if not self._authorized():
            self._send_json(401, {"error": {"message": "unauthorized"}})
            return
        path = self.path.rstrip("/")
        if path == "/health":
            self._send_json(200, {"status": "ok", "version": BRIDGE_VERSION,
                                  "opencode_version": self.server.opencode_version,  # type: ignore[attr-defined]
                                  "in_flight": self.server.in_flight(),  # type: ignore[attr-defined]
                                  "model": self.cfg.default_model})
            return
        if path == "/metrics":
            self._send_json(200, self.server.metrics.snapshot(self.server.in_flight()))  # type: ignore[attr-defined]
            return
        if path == "/config":
            self._send_json(200, {
                "status": "ok", "version": BRIDGE_VERSION, "model": self.cfg.default_model,
                "models": self.cfg.models, "models_source": self.cfg.discovered_from,
                "model_refresh_interval_s": self.cfg.model_refresh_interval,
                "model_cache": self.cfg.model_cache or "(disabled)",
                "model_providers": self.cfg.model_providers, "free_only": self.cfg.free_only,
                "opencode_bin": self.cfg.opencode_bin, "cwd": self.cfg.cwd,
                "agent": self.cfg.agent or "(opencode default)", "variant": self.cfg.variant or "(default)",
                "auto_approve": self.cfg.auto_approve, "show_tools": self.cfg.show_tools,
                "show_reasoning": self.cfg.show_reasoning, "delete_sessions": self.cfg.delete_sessions,
                "max_prompt_chars": self.cfg.max_prompt_chars, "timeout_s": self.cfg.timeout_seconds,
                "max_images": self.cfg.max_images,
                "max_image_bytes": self.cfg.max_image_bytes,
                "max_concurrency": self.server.max_concurrency,  # type: ignore[attr-defined]
                "pass_model": self.cfg.pass_model, "api_key_required": bool(self.cfg.api_key),
            })
            return
        if path == "/v1/models":
            self._send_json(200, {"object": "list",
                                  "data": [self._model_obj(m) for m in self.cfg.models]})
            return
        if path.startswith("/v1/models/"):
            model_id = path[len("/v1/models/"):]  # may contain the provider slash
            if model_id in self.cfg.models:
                self._send_json(200, self._model_obj(model_id))
            else:
                self._send_json(404, {"error": {"message": f"model {model_id!r} not found"}})
            return
        self._send_json(404, {"error": {"message": "not found"}})

    # ── POST ──
    def do_POST(self) -> None:
        if not self._authorized():
            self._send_json(401, {"error": {"message": "unauthorized"}})
            return
        # Force an immediate catalogue re-discovery. Useful right after opencode zen
        # changes its free tier, instead of waiting for the refresh interval.
        if self.path.rstrip("/") == "/v1/models/refresh":
            summary = self.cfg.refresh_catalogue()
            self._send_json(200, {"status": "ok", **summary, "models_list": self.cfg.models})
            return
        if self.path.rstrip("/") != "/v1/chat/completions":
            self._send_json(404, {"error": {"message": "not found"}})
            return
        try:
            length = int(self.headers.get("content-length") or "0")
            request = json.loads(self.rfile.read(length).decode("utf-8"))
        except Exception as exc:  # noqa: BLE001
            self._send_json(400, {"error": {"message": f"invalid json: {exc}"}})
            return

        model, model_error = self.cfg.resolve_model(str(request.get("model") or ""))
        if model_error or not model:
            self._send_json(400, {"error": {"message": model_error or "no model"}})
            return

        prompt = build_prompt(request.get("messages") or [])
        if not prompt:
            self._send_json(400, {"error": {"message": "request has no prompt text"}})
            return
        if len(prompt) > self.cfg.max_prompt_chars:
            self._send_json(413, {"error": {"message":
                f"prompt too large: {len(prompt)} chars exceeds {self.cfg.max_prompt_chars}"}})
            return
        try:
            images = extract_images(request.get("messages") or [],
                                    self.cfg.max_images, self.cfg.max_image_bytes)
        except ImageExtractionError as exc:
            self._send_json(400, {"error": {"message": str(exc)}})
            return
        image_files = stage_image_files(images) if images else []

        # Concurrency slot — bound the number of live opencode subprocesses.
        if not self.server.slot.acquire(timeout=self.server.queue_wait):  # type: ignore[attr-defined]
            self.server.metrics.rejected_busy += 1  # type: ignore[attr-defined]
            cleanup_image_files(image_files)  # staged but never handed to run_events
            self._send_json(429, {"error": {"message": "bridge busy: too many concurrent requests"}})
            return
        try:
            if request.get("stream") is True:
                self._handle_stream(model, prompt, image_files)
            else:
                self._handle_blocking(model, prompt, image_files)
        finally:
            self.server.slot.release()  # type: ignore[attr-defined]

    def _handle_blocking(self, model: str, prompt: str, image_files: Optional[list[str]] = None) -> None:
        started = time.time()
        try:
            res = run_blocking(self.cfg, model, prompt, image_files)
        except OpenCodeError as exc:
            self.server.metrics.record(error=True)  # type: ignore[attr-defined]
            self._send_json(exc.exit_code, {"error": {"message": str(exc)}})
            return
        usage = _usage_block(res["tokens"])
        self.server.metrics.record(cost=res["cost_usd"], out_tokens=usage["completion_tokens"])  # type: ignore[attr-defined]
        print(f"[opencode-bridge] model={model} chars={len(prompt)} "
              f"out_tokens={usage['completion_tokens']} cost_usd={res['cost_usd']} "
              f"latency_ms={int((time.time()-started)*1000)}", flush=True)
        self._send_json(200, {
            "id": f"chatcmpl-{uuid.uuid4().hex}", "object": "chat.completion",
            "created": int(time.time()), "model": model,
            "choices": [{"index": 0, "message": {"role": "assistant", "content": res["text"]},
                         "finish_reason": res["finish_reason"]}],
            "usage": usage,
        })

    def _handle_stream(self, model: str, prompt: str, image_files: Optional[list[str]] = None) -> None:
        completion_id = f"chatcmpl-{uuid.uuid4().hex}"
        created = int(time.time())
        started = time.time()

        def frame(delta: dict[str, Any], finish: Optional[str] = None) -> bytes:
            chunk = {"id": completion_id, "object": "chat.completion.chunk", "created": created,
                     "model": model, "choices": [{"index": 0, "delta": delta, "finish_reason": finish}]}
            return f"data: {json.dumps(chunk)}\n\n".encode("utf-8")

        self.send_response(200)
        self.send_header("content-type", "text/event-stream")
        self.send_header("cache-control", "no-cache")
        self.end_headers()
        try:
            self.wfile.write(frame({"role": "assistant"}))
            tokens: dict[str, int] = {}
            cost = 0.0
            finish = "stop"
            for event in run_events(self.cfg, model, prompt, image_files):
                if "delta" in event:
                    self.wfile.write(frame({"content": event["delta"]}))
                    self.wfile.flush()
                elif event.get("done"):
                    tokens, cost, finish = event["tokens"], event["cost_usd"], event["finish_reason"]
            self.wfile.write(frame({}, finish=finish))
            self.wfile.write(b"data: [DONE]\n\n")
            ub = _usage_block(tokens)
            self.server.metrics.record(cost=cost, out_tokens=ub["completion_tokens"])  # type: ignore[attr-defined]
            print(f"[opencode-bridge] stream model={model} chars={len(prompt)} "
                  f"out_tokens={ub['completion_tokens']} cost_usd={cost} "
                  f"latency_ms={int((time.time()-started)*1000)}", flush=True)
        except OpenCodeError as exc:
            self.server.metrics.record(error=True)  # type: ignore[attr-defined]
            # Headers are already sent, so surface the failure in-band, then close.
            try:
                self.wfile.write(frame({"content": f"\n[bridge error: {exc}]"}, finish="stop"))
                self.wfile.write(b"data: [DONE]\n\n")
            except BrokenPipeError:
                pass
        except BrokenPipeError:
            pass  # client hung up mid-stream


class BridgeServer(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True

    def __init__(self, addr, handler, cfg: BridgeConfig, max_concurrency: int, queue_wait: int,
                 opencode_version: str) -> None:
        super().__init__(addr, handler)
        self.cfg = cfg
        self.metrics = Metrics()
        self.max_concurrency = max_concurrency
        self.queue_wait = queue_wait
        self.opencode_version = opencode_version
        self.slot = threading.BoundedSemaphore(max_concurrency)

    def in_flight(self) -> int:
        # available permits on a bounded semaphore -> derive active count
        return max(0, self.max_concurrency - self.slot._value)  # type: ignore[attr-defined]


# ── entrypoint ────────────────────────────────────────────────────────────────
def _detect_opencode_version(opencode_bin: str) -> str:
    try:
        out = subprocess.run([opencode_bin, "--version"], capture_output=True, text=True, timeout=15)
        return (out.stdout or out.stderr or "").strip().splitlines()[0] if (out.stdout or out.stderr) else "unknown"
    except Exception:  # noqa: BLE001
        return "unknown"


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        description="OpenAI-compatible bridge to the OpenCode CLI (Hermes custom endpoint; free models by default).")
    p.add_argument("--host", default=os.getenv("BRIDGE_HOST", "127.0.0.1"))
    p.add_argument("--port", type=int, default=int(os.getenv("BRIDGE_PORT", "18282")))
    p.add_argument("--opencode-bin", default=os.getenv("OPENCODE_BIN", DEFAULT_OPENCODE_BIN))
    p.add_argument("--cwd", default=os.getenv("OPENCODE_BRIDGE_CWD", os.getcwd()),
                   help="directory opencode runs in (its tools read/write here)")
    p.add_argument("--model", default=os.getenv("OPENCODE_BRIDGE_MODEL", DEFAULT_MODEL),
                   help="default model, provider/model (e.g. opencode/mimo-v2.5-free)")
    p.add_argument("--models", default=os.getenv("OPENCODE_BRIDGE_MODELS", ""),
                   help="comma-separated model IDs to advertise; empty = discover from the opencode CLI")
    p.add_argument("--model-providers", default=os.getenv("OPENCODE_BRIDGE_MODEL_PROVIDERS", DEFAULT_MODEL_PROVIDERS),
                   help="comma-separated provider IDs scanned during discovery (default: opencode = opencode zen)")
    p.add_argument("--model-refresh-interval", type=int,
                   default=int(os.getenv("OPENCODE_BRIDGE_MODEL_REFRESH_INTERVAL",
                                         str(DEFAULT_MODEL_REFRESH_INTERVAL))),
                   help="seconds between catalogue re-discoveries so new/retired free models "
                        "are picked up without a restart (0 disables)")
    p.add_argument("--model-cache", default=os.getenv("OPENCODE_BRIDGE_MODEL_CACHE", ""),
                   help="path to persist the discovered catalogue; used instead of the built-in "
                        "seed list when discovery fails, and read by the k8s deployment to build "
                        "the dashboard's model picker")
    # Free-only by default: a Hermes typo must not start spending on a paid provider.
    p.add_argument("--free-only", dest="free_only", action="store_true", default=True)
    p.add_argument("--no-free-only", dest="free_only", action="store_false",
                   help="also allow paid models your opencode credentials can reach")
    p.add_argument("--agent", default=os.getenv("OPENCODE_BRIDGE_AGENT", ""),
                   help="opencode agent to run (e.g. build, plan); empty = opencode default")
    p.add_argument("--variant", default=os.getenv("OPENCODE_BRIDGE_VARIANT", ""),
                   help="provider reasoning variant (e.g. high, max, minimal)")
    p.add_argument("--auto-approve", dest="auto_approve", action="store_true", default=True,
                   help="pass --auto so tool permissions never block a headless run (default)")
    p.add_argument("--no-auto-approve", dest="auto_approve", action="store_false")
    p.add_argument("--show-tools", dest="show_tools", action="store_true",
                   default=os.getenv("OPENCODE_BRIDGE_SHOW_TOOLS", "") not in ("", "0", "false"),
                   help="emit one-line tool-call notes into the response text")
    p.add_argument("--show-reasoning", dest="show_reasoning", action="store_true",
                   default=os.getenv("OPENCODE_BRIDGE_SHOW_REASONING", "") not in ("", "0", "false"),
                   help="pass --thinking and include reasoning blocks in the response text")
    p.add_argument("--pure", action="store_true", help="run opencode without external plugins")
    p.add_argument("--delete-sessions", dest="delete_sessions", action="store_true", default=True,
                   help="delete each run's persisted opencode session afterwards (default)")
    p.add_argument("--keep-sessions", dest="delete_sessions", action="store_false")
    p.add_argument("--max-prompt-chars", type=int,
                   default=int(os.getenv("OPENCODE_BRIDGE_MAX_PROMPT_CHARS", str(DEFAULT_MAX_PROMPT_CHARS))))
    p.add_argument("--max-images", type=int,
                   default=int(os.getenv("OPENCODE_BRIDGE_MAX_IMAGES", str(DEFAULT_MAX_IMAGES))),
                   help="max image_url attachments accepted per request (0 disables image support)")
    p.add_argument("--max-image-bytes", type=int,
                   default=int(os.getenv("OPENCODE_BRIDGE_MAX_IMAGE_BYTES", str(DEFAULT_MAX_IMAGE_BYTES))),
                   help="per-image size limit in bytes (data: URLs and fetched http(s) images)")
    p.add_argument("--api-key", default=os.getenv("OPENCODE_BRIDGE_API_KEY", ""))
    p.add_argument("--timeout", type=int, default=int(os.getenv("OPENCODE_BRIDGE_TIMEOUT", str(DEFAULT_TIMEOUT))))
    p.add_argument("--max-concurrency", type=int,
                   default=int(os.getenv("OPENCODE_BRIDGE_MAX_CONCURRENCY", str(DEFAULT_MAX_CONCURRENCY))))
    p.add_argument("--queue-wait", type=int,
                   default=int(os.getenv("OPENCODE_BRIDGE_QUEUE_WAIT", str(DEFAULT_QUEUE_WAIT))))
    # Honor the client-requested model by default. Use --no-pass-model to pin --model.
    p.add_argument("--pass-model", dest="pass_model", action="store_true", default=True)
    p.add_argument("--no-pass-model", dest="pass_model", action="store_false")
    return p


def main(argv: Optional[list[str]] = None) -> None:
    args = build_parser().parse_args(argv)
    resolved = resolve_opencode_bin(args.opencode_bin)
    if not resolved:
        raise SystemExit(
            f"opencode binary not found: {args.opencode_bin!r}. Install OpenCode "
            "(https://opencode.ai) and ensure `opencode` is on PATH, or pass --opencode-bin /full/path.")
    args.opencode_bin = resolved
    if not os.path.isdir(args.cwd):
        raise SystemExit(f"working directory not found: {args.cwd}")

    cfg = BridgeConfig(args)
    opencode_version = _detect_opencode_version(args.opencode_bin)
    cfg.refresh_catalogue()
    cfg.start_refresh_loop()
    if not cfg.default_in_catalogue:
        # The default is always advertised (force-prepended); warn when the catalogue
        # itself didn't list it, since that usually means a typo or a paid model.
        print(f"[opencode-bridge] warning: default model {cfg.default_model!r} is not in the "
              f"{'free ' if cfg.free_only else ''}catalogue from `opencode models "
              f"{' '.join(cfg.model_providers)}` — requests may fail", flush=True)
    server = BridgeServer((args.host, args.port), BridgeHandler, cfg,
                          max(1, args.max_concurrency), args.queue_wait, opencode_version)

    def _shutdown(signum, _frame):  # graceful drain
        print(f"[opencode-bridge] signal {signum} — shutting down", flush=True)
        threading.Thread(target=server.shutdown, daemon=True).start()

    # SIGINT is available everywhere; SIGTERM/SIGBREAK vary by platform — register
    # each defensively so the bridge stays cross-platform (Linux/macOS/Windows).
    for signame in ("SIGINT", "SIGTERM", "SIGBREAK"):
        sig = getattr(signal, signame, None)
        if sig is not None:
            try:
                signal.signal(sig, _shutdown)
            except (ValueError, OSError, RuntimeError):
                pass

    print(f"[opencode-bridge] v{BRIDGE_VERSION} listening on http://{args.host}:{args.port}/v1 "
          f"model={cfg.default_model} opencode={opencode_version} cwd={args.cwd} "
          f"free_only={cfg.free_only} models={len(cfg.models)} ({cfg.discovered_from}) "
          f"max_concurrency={args.max_concurrency} api_key_required={bool(args.api_key)}", flush=True)
    connect_host = "127.0.0.1" if args.host in ("0.0.0.0", "::") else args.host
    print(
        "\n"
        "┌─ Connect Hermes ─────────────────────────────────────────────┐\n"
        "│ In Hermes → Settings → Model, choose: Custom endpoint        │\n"
        f"│   Base URL: {f'http://{connect_host}:{args.port}/v1':<49}│\n"
        f"│   API key:  {'(required — use your bridge api-key)' if args.api_key else '(leave empty — none required)':<49}│\n"
        f"│   Model:    {cfg.default_model:<49}│\n"
        "└──────────────────────────────────────────────────────────────┘",
        flush=True,
    )
    try:
        server.serve_forever()
    finally:
        server.server_close()


def _selfcheck() -> None:
    # Offline checks for the parts with real logic: prompt assembly, the OpenCode
    # token → chat-completions usage mapping, `models --verbose` parsing, model
    # resolution, error classification and command construction.
    prompt = build_prompt([
        {"role": "system", "content": "be terse"},
        {"role": "user", "content": [{"type": "text", "text": "hi"}]},
    ])
    assert prompt == "<system-instructions>\nbe terse\n</system-instructions>\n\nUSER:\nhi", repr(prompt)
    assert build_prompt([{"role": "user", "content": "hi"}]) == "USER:\nhi"

    tokens: dict[str, int] = {}
    _accumulate_tokens(tokens, {"tokens": {"input": 10, "output": 4, "reasoning": 2,
                                           "cache": {"read": 5, "write": 1}}})
    _accumulate_tokens(tokens, {"tokens": {"input": 3, "output": 1}})
    assert _usage_block(tokens) == {"prompt_tokens": 19, "completion_tokens": 7, "total_tokens": 26}, tokens

    parsed = _parse_verbose_models(
        'opencode/mimo-v2.5-free\n{\n  "id": "mimo-v2.5-free",\n  "providerID": "opencode",\n'
        '  "cost": {"input": 0, "output": 0}\n}\n'
        'paid/some-model\n{\n  "id": "some-model",\n  "cost": {"input": 3, "output": 15}\n}\n')
    assert [m for m, _ in parsed] == ["opencode/mimo-v2.5-free", "paid/some-model"], parsed
    assert _is_free(parsed[0][1]) and not _is_free(parsed[1][1])

    cfg = BridgeConfig(build_parser().parse_args(["--models", "opencode/mimo-v2.5-free,opencode/big-pickle"]))
    assert cfg.models == ["opencode/mimo-v2.5-free", "opencode/big-pickle"], cfg.models  # default first, de-duped
    assert cfg.resolve_model("big-pickle")[0] == "opencode/big-pickle"        # bare-id alias
    assert cfg.resolve_model("OpenCode/Big-Pickle")[0] == "opencode/big-pickle"  # case-insensitive
    assert cfg.resolve_model("")[0] == cfg.default_model                      # empty -> default
    resolved, err = cfg.resolve_model("gpt-4o")                              # paid/unknown -> refused
    assert resolved is None and err and "not available" in err, (resolved, err)
    assert BridgeConfig(build_parser().parse_args(
        ["--models", "opencode/big-pickle", "--no-free-only"])).resolve_model("openai/gpt-4o")[0] == "openai/gpt-4o"
    assert BridgeConfig(build_parser().parse_args(
        ["--no-pass-model"])).resolve_model("anything")[0] == DEFAULT_MODEL

    cmd = build_command(BridgeConfig(build_parser().parse_args(
        ["--show-reasoning", "--agent", "build", "--variant", "high", "--cwd", os.getcwd()])), "opencode/x-free")
    for expected in ("run", "--format", "json", "--model", "opencode/x-free", "--auto",
                     "--thinking", "--agent", "build", "--variant", "high", "--dir"):
        assert expected in cmd, (expected, cmd)
    assert "-p" not in cmd and "--prompt" not in cmd, cmd  # prompt goes over stdin

    # Model cache round-trip: what discovery produces must survive a write/read cycle
    # with context lengths and the free flag intact, since the deployment builds the
    # dashboard's model picker from this file.
    import tempfile
    with tempfile.TemporaryDirectory() as tmpdir:
        cache_path = os.path.join(tmpdir, "sub", "models.json")
        discovered = ["opencode/new-shiny-free", "opencode/mimo-v2.5-free"]
        discovered_meta = {
            "opencode/new-shiny-free": {"name": "New Shiny Free", "providerID": "opencode",
                                        "limit": {"context": 512000}, "cost": {"input": 0, "output": 0}},
            "opencode/mimo-v2.5-free": {"name": "MiMo V2.5 Free", "providerID": "opencode",
                                        "limit": {"context": 200000}, "cost": {"input": 0, "output": 0}},
        }
        write_model_cache(cache_path, discovered, discovered_meta, True)
        ids, meta = read_model_cache(cache_path)
        assert ids == discovered, ids
        assert meta["opencode/new-shiny-free"]["limit"]["context"] == 512000, meta
        assert _is_free(meta["opencode/new-shiny-free"]), meta
        assert read_model_cache(os.path.join(tmpdir, "absent.json")) == ([], {})
        with open(os.path.join(tmpdir, "junk.json"), "w", encoding="utf-8") as handle:
            handle.write("{not json")
        assert read_model_cache(os.path.join(tmpdir, "junk.json")) == ([], {})  # corrupt -> ignored
        assert read_model_cache("") == ([], {})
        write_model_cache("", discovered, discovered_meta, True)  # no path -> no-op, no raise

        # A retired default model must not stay advertised: the catalogue wins.
        stale = BridgeConfig(build_parser().parse_args(
            ["--model", "opencode/retired-free", "--model-cache", cache_path,
             "--opencode-bin", "/nonexistent-so-discovery-fails"]))
        stale.refresh_catalogue(refresh=False)
        assert stale.discovered_from == "cache", stale.discovered_from
        assert stale.default_model == "opencode/new-shiny-free", stale.default_model
        assert stale.models == discovered, stale.models          # cache order preserved
        assert stale.resolve_model("opencode/new-shiny-free")[0] == "opencode/new-shiny-free"

        # No cache and no CLI -> the seed list, and the default still resolves.
        seeded = BridgeConfig(build_parser().parse_args(
            ["--opencode-bin", "/nonexistent-so-discovery-fails"]))
        seeded.refresh_catalogue(refresh=False)
        assert seeded.discovered_from == "fallback", seeded.discovered_from
        assert seeded.models == FALLBACK_FREE_MODELS[:1] + [m for m in FALLBACK_FREE_MODELS[1:]], seeded.models

    assert classify_error("429 Too Many Requests") == 429
    assert classify_error("model not found") == 502
    assert _finish_reason("tool-calls") == "stop" and _finish_reason("length") == "length"
    assert "sk-[redacted]" in _safe_error_text("bad key sk-abc123")
    assert _tool_note({"tool": "read", "state": {"status": "completed",
                                                 "input": {"filePath": "/tmp/a.txt"}}}) == "\n› read(/tmp/a.txt)\n"
    assert _tool_note({"tool": "read", "state": {"status": "running"}}) is None
    # A failed skill load must name the skill, not render as a bare `skill()`.
    assert _tool_note({"tool": "skill", "state": {"status": "error",
                                                  "input": {"name": "lead-devops-sre"}}}) == "\n✗ skill(lead-devops-sre)\n"
    print("selfcheck ok")


if __name__ == "__main__":
    if os.getenv("BRIDGE_SELFCHECK"):
        _selfcheck()
    else:
        main()
