#!/usr/bin/env python3
"""Hermes-compatible bridge for Hermes -> Vertex AI Claude.

This bridge accepts the subset of the
chat completions API that Hermes needs, translates it to Anthropic
Messages requests on Vertex AI, authenticates with Google ADC / Workload
Identity, and translates the response back to the chat-completions JSON shape.

It intentionally does not use service account JSON keys.
"""

from __future__ import annotations

import argparse
import base64
import hmac
import json
import mimetypes
import os
from pathlib import Path
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any, Iterable

import subprocess
import threading
import urllib.error
import urllib.request


DEFAULT_MODEL = "claude-opus-5"
DEFAULT_LOCATION = "global"
DEFAULT_MAX_TOKENS = 4096
# Ceiling used when the CLIENT OMITS max_tokens. Hermes deliberately sends no
# max_tokens on the context-compression summary call — upstream comment: "NO
# max_tokens: the output cap must never truncate a summary" — because the
# Anthropic Messages wire forwards it and a hard cap cuts the summary
# mid-section. Anthropic requires the field, so the bridge has to supply one;
# substituting the small chat default (VERTEX_CLAUDE_MAX_TOKENS, 8192 in prod)
# guaranteed every ~250k-token compaction came back finish_reason=length. With
# compression.abort_on_summary_failure=true that truncation is a hard abort, so
# the session never compacted, grew until a 413, and auto-reset. Absent means
# "do not cap me": use this ceiling instead.
DEFAULT_UNCAPPED_MAX_TOKENS = 32000
# Adaptive-thinking effort applied when the caller sends no reasoning_effort.
# Empty string disables thinking entirely.
DEFAULT_THINKING_EFFORT = ""
# Floor for max_tokens whenever adaptive thinking is on, so a small caller cap
# cannot be consumed entirely by thinking (measured: 1200 yielded no text).
_MIN_THINKING_MAX_TOKENS = 4096
DEFAULT_ANTHROPIC_VERSION = "vertex-2023-10-16"
DEFAULT_MAX_PROMPT_CHARS = 200_000
IMAGE_CACHE_ROOT = Path("/opt/data/image_cache")
MAX_IMAGE_BYTES = 10 * 1024 * 1024
RETRYABLE_STATUS = {429, 500, 502, 503, 504}

# ── stdlib ADC session ────────────────────────────────────────────────────────
# Security: no runtime pip installs on live servers. The bridge used
# google-auth only to mint the ADC access token; on GKE that token comes from the
# metadata server — the same platform ADC path — so we fetch it with urllib and
# drop the third-party dependencies entirely. Local dev falls back to the gcloud
# CLI's application-default token.

_METADATA_TOKEN_URL = (
    "http://metadata.google.internal/computeMetadata/v1/"
    "instance/service-accounts/default/token"
)
_json_dumps = json.dumps


class _Resp:
    """Minimal requests.Response stand-in (status_code / text / json)."""

    def __init__(self, status_code: int, body: bytes) -> None:
        self.status_code = status_code
        self._body = body

    @property
    def text(self) -> str:
        return self._body.decode("utf-8", "replace")

    def json(self) -> Any:
        return json.loads(self._body.decode("utf-8"))


class AdcSession:
    """Stdlib replacement for google-auth's AuthorizedSession.

    Fetches and caches the ADC access token (metadata server on GKE/GCE, gcloud
    CLI fallback for local development) and POSTs JSON with a Bearer header.
    """

    def __init__(self) -> None:
        self._token = ""
        self._expires_at = 0.0
        self._lock = threading.Lock()

    def _fetch_token(self) -> tuple[str, float]:
        try:
            req = urllib.request.Request(
                _METADATA_TOKEN_URL, headers={"Metadata-Flavor": "Google"}
            )
            with urllib.request.urlopen(req, timeout=10) as response:
                payload = json.load(response)
            return payload["access_token"], time.time() + int(payload.get("expires_in", 300))
        except (urllib.error.URLError, OSError, KeyError, ValueError):
            result = subprocess.run(
                ["gcloud", "auth", "application-default", "print-access-token"],
                capture_output=True, text=True, timeout=30,
            )
            if result.returncode != 0:
                raise RuntimeError(
                    "ADC unavailable: metadata server unreachable and gcloud fallback "
                    f"failed: {result.stderr.strip()[:200]}"
                )
            return result.stdout.strip(), time.time() + 300

    def token(self) -> str:
        with self._lock:
            if not self._token or time.time() > self._expires_at - 60:
                self._token, self._expires_at = self._fetch_token()
            return self._token

    def post(self, url: str, json: Any = None, timeout: float = 60):
        # requests-style `json=` kwarg kept for the call sites; alias the module.
        body = _json_dumps(json).encode("utf-8")
        req = urllib.request.Request(
            url,
            data=body,
            method="POST",
            headers={
                "Authorization": f"Bearer {self.token()}",
                "Content-Type": "application/json",
            },
        )
        try:
            with urllib.request.urlopen(req, timeout=timeout) as response:
                return _Resp(response.status, response.read())
        except urllib.error.HTTPError as exc:
            return _Resp(exc.code, exc.read())


def _post_with_retries(session, url, body, timeout, max_retries):
    """POST to Vertex with bounded exponential backoff on transient failures.

    Retries connection errors and 429/5xx; returns the final response (which may
    still carry an error status) once retries are exhausted.
    """
    for attempt in range(max_retries + 1):
        try:
            resp = session.post(url, json=body, timeout=timeout)
        except Exception:
            if attempt >= max_retries:
                raise
            time.sleep(min(0.5 * (2 ** attempt), 8.0))
            continue
        if resp.status_code in RETRYABLE_STATUS and attempt < max_retries:
            time.sleep(min(0.5 * (2 ** attempt), 8.0))
            continue
        return resp


def _log_usage(model, payload):
    """Emit token usage including prompt-cache hits for cost tracking.

    (rates verified for claude-opus-4-8; re-check Vertex pricing for claude-opus-5)
    $5 / 1M input, $25 / 1M output; cache reads bill ~0.1x input,
    cache writes ~1.25x (5m TTL). Derive cost from these counts.
    """
    u = payload.get("usage") if isinstance(payload.get("usage"), dict) else {}
    print(
        f"[vertex-claude-bridge] usage model={model} "
        f"input={int(u.get('input_tokens') or 0)} "
        f"output={int(u.get('output_tokens') or 0)} "
        f"cache_write={int(u.get('cache_creation_input_tokens') or 0)} "
        f"cache_read={int(u.get('cache_read_input_tokens') or 0)}",
        flush=True,
    )


def _apply_cache_control(body, ttl="1h"):
    """Place explicit prompt-cache breakpoints on the stable prefix.

    Vertex does not support top-level automatic caching, so cache_control goes on
    content blocks directly: the last tool, the system prompt, and the last message
    block (caches tools + system + conversation prefix). Max 4 breakpoints; we use
    at most 3. Opus 4.8 needed a >=4096-token prefix for a cache entry to form;
    caching is confirmed working on claude-opus-5 (observed cache_write in the
    bridge usage logs), exact minimum prefix for Opus 5 not independently verified.

    ttl "1h" keeps the cached prefix alive across the multi-minute gaps typical of
    interactive conversations; the 5m default would expire and force a re-write
    (1.25x) instead of a read (0.1x). Set VERTEX_CLAUDE_CACHE_TTL=5m if traffic is
    dense enough that cache writes dominate the usage logs.
    """
    cc = {"type": "ephemeral"}
    if ttl:
        cc["ttl"] = ttl
    tools = body.get("tools")
    if isinstance(tools, list) and tools:
        tools[-1] = {**tools[-1], "cache_control": cc}
    system = body.get("system")
    if isinstance(system, str) and system:
        body["system"] = [{"type": "text", "text": system, "cache_control": cc}]
    elif isinstance(system, list) and system:
        system[-1] = {**system[-1], "cache_control": cc}
    messages = body.get("messages")
    if isinstance(messages, list) and messages:
        content = messages[-1].get("content")
        if isinstance(content, list) and content:
            content[-1] = {**content[-1], "cache_control": cc}


def _split_stop(stop: Any) -> list[str] | None:
    if isinstance(stop, str):
        return [stop]
    if isinstance(stop, list):
        return [str(item) for item in stop if item is not None]
    return None


def _text_from_chat_content(content: Any) -> str:
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        parts: list[str] = []
        for item in content:
            if isinstance(item, str):
                parts.append(item)
            elif isinstance(item, dict):
                if item.get("type") == "text" and isinstance(item.get("text"), str):
                    parts.append(item["text"])
                elif isinstance(item.get("text"), str):
                    parts.append(item["text"])
        return "\n".join(parts)
    return "" if content is None else str(content)


def _image_source_from_url(url: str) -> dict[str, Any] | None:
    if url.startswith("data:image/") and ";base64," in url:
        header, data = url.split(",", 1)
        media_type = header.removeprefix("data:").split(";", 1)[0]
        return {
            "type": "base64",
            "media_type": media_type,
            "data": data,
        }

    path_text = url.removeprefix("file://")
    if not path_text.startswith(str(IMAGE_CACHE_ROOT) + "/"):
        return None

    path = Path(path_text).resolve()
    try:
        path.relative_to(IMAGE_CACHE_ROOT.resolve())
    except ValueError:
        return None
    if not path.is_file() or path.stat().st_size > MAX_IMAGE_BYTES:
        return None

    media_type = mimetypes.guess_type(path.name)[0] or "image/png"
    if media_type not in {"image/png", "image/jpeg", "image/gif", "image/webp"}:
        return None

    return {
        "type": "base64",
        "media_type": media_type,
        "data": base64.b64encode(path.read_bytes()).decode("ascii"),
    }


def _image_block_from_chat_item(item: dict[str, Any]) -> dict[str, Any] | None:
    if item.get("type") == "image" and isinstance(item.get("source"), dict):
        source = item["source"]
        if source.get("type") == "base64" and source.get("media_type") and source.get("data"):
            return {"type": "image", "source": source}

    image_url = item.get("image_url") or item.get("url")
    if isinstance(image_url, dict):
        image_url = image_url.get("url")
    if not isinstance(image_url, str):
        return None

    source = _image_source_from_url(image_url)
    return {"type": "image", "source": source} if source else None


def _content_blocks_from_chat_content(content: Any) -> list[dict[str, Any]]:
    if isinstance(content, str):
        text = content.strip()
        return [{"type": "text", "text": text}] if text else []
    if not isinstance(content, list):
        text = _text_from_chat_content(content).strip()
        return [{"type": "text", "text": text}] if text else []

    blocks: list[dict[str, Any]] = []
    for item in content:
        if isinstance(item, str):
            text = item.strip()
            if text:
                blocks.append({"type": "text", "text": text})
            continue
        if not isinstance(item, dict):
            continue
        if item.get("type") == "text" and isinstance(item.get("text"), str):
            text = item["text"].strip()
            if text:
                blocks.append({"type": "text", "text": text})
            continue
        image_block = _image_block_from_chat_item(item)
        if image_block:
            blocks.append(image_block)
    return blocks


def _json_arguments(value: Any) -> str:
    if isinstance(value, str):
        return value
    if value is None:
        return "{}"
    try:
        return json.dumps(value)
    except TypeError:
        return json.dumps({"value": str(value)})


def _parse_json_arguments(value: Any) -> dict[str, Any]:
    if isinstance(value, dict):
        return value
    if isinstance(value, str) and value.strip():
        try:
            parsed = json.loads(value)
            return parsed if isinstance(parsed, dict) else {"value": parsed}
        except json.JSONDecodeError:
            return {"value": value}
    return {}


def _content_blocks_from_chat_message(message: dict[str, Any]) -> list[dict[str, Any]]:
    role = str(message.get("role") or "user")
    content_blocks = _content_blocks_from_chat_content(message.get("content"))

    if role == "assistant":
        for tool_call in message.get("tool_calls") or []:
            if not isinstance(tool_call, dict):
                continue
            function = tool_call.get("function") if isinstance(tool_call.get("function"), dict) else {}
            name = function.get("name")
            if not name:
                continue
            content_blocks.append(
                {
                    "type": "tool_use",
                    "id": str(tool_call.get("id") or f"toolu_{uuid.uuid4().hex}"),
                    "name": str(name),
                    "input": _parse_json_arguments(function.get("arguments")),
                }
            )

    if role == "tool":
        tool_result_text = _text_from_chat_content(message.get("content"))
        content_blocks = [
            {
                "type": "tool_result",
                "tool_use_id": str(message.get("tool_call_id") or ""),
                "content": tool_result_text,
            }
        ]

    return content_blocks


def _messages_for_anthropic(messages: list[dict[str, Any]]) -> tuple[str | None, list[dict[str, Any]]]:
    system_parts: list[str] = []
    anthropic_messages: list[dict[str, Any]] = []

    for message in messages:
        role = str(message.get("role") or "user")
        if role == "system":
            content = _text_from_chat_content(message.get("content")).strip()
            if not content:
                continue
            system_parts.append(content)
            continue

        if role == "tool":
            role = "user"
        elif role not in {"user", "assistant"}:
            role = "user"

        content_blocks = _content_blocks_from_chat_message(message)
        if not content_blocks:
            continue

        # Anthropic requires alternating user/assistant messages in many cases.
        # If two adjacent messages have the same role, merge their content blocks.
        if anthropic_messages and anthropic_messages[-1]["role"] == role:
            anthropic_messages[-1]["content"].extend(content_blocks)
        else:
            anthropic_messages.append(
                {
                    "role": role,
                    "content": content_blocks,
                }
            )

    if not anthropic_messages:
        raise ValueError("request has no prompt text")

    system = "\n\n".join(system_parts).strip() or None
    return system, anthropic_messages


def _tools_for_anthropic(tools: Any) -> list[dict[str, Any]]:
    anthropic_tools: list[dict[str, Any]] = []
    if not isinstance(tools, list):
        return anthropic_tools
    for tool in tools:
        if not isinstance(tool, dict):
            continue
        function = tool.get("function") if tool.get("type") == "function" else tool
        if not isinstance(function, dict) or not function.get("name"):
            continue
        anthropic_tools.append(
            {
                "name": str(function["name"]),
                "description": str(function.get("description") or ""),
                "input_schema": function.get("parameters") if isinstance(function.get("parameters"), dict) else {"type": "object"},
            }
        )
    return anthropic_tools


def _tool_choice_for_anthropic(tool_choice: Any) -> dict[str, Any] | None:
    if tool_choice in (None, "auto"):
        return {"type": "auto"}
    if tool_choice == "none":
        return None
    if tool_choice in ("required", "any"):
        return {"type": "any"}
    if isinstance(tool_choice, dict):
        function = tool_choice.get("function")
        if isinstance(function, dict) and function.get("name"):
            return {"type": "tool", "name": str(function["name"])}
    return {"type": "auto"}


def _vertex_host(location: str) -> str:
    # Regional/multi-regional hosts use {location}-aiplatform.googleapis.com.
    # Global uses the base host.
    return "aiplatform.googleapis.com" if location == "global" else f"{location}-aiplatform.googleapis.com"


def _safe_error_text(text: str) -> str:
    redacted = text.strip()
    for marker in ("Authorization:", "Bearer ", "access_token", "refresh_token", "api_key", "apiKey"):
        if marker in redacted:
            redacted = redacted.replace(marker, f"{marker[:3]}[redacted]")
    return redacted[-4000:]


def _extract_text_from_anthropic_response(payload: dict[str, Any]) -> str:
    content = payload.get("content") or []
    if isinstance(content, list):
        parts: list[str] = []
        for item in content:
            if isinstance(item, dict):
                if item.get("type") == "text" and isinstance(item.get("text"), str):
                    parts.append(item["text"])
        return "\n".join(parts).strip()
    return str(content).strip()


# Vertex `output_config.effort` accepts low | medium | high | max. Hermes uses
# the wider OpenAI-style vocabulary (none|minimal|low|medium|high|xhigh|max|
# ultra) per auxiliary task, so map it here and let an explicit request value
# override the bridge default. "none"/"minimal" disable thinking for that call.
_EFFORT_MAP = {
    "none": "", "off": "", "false": "", "0": "",
    "minimal": "low", "low": "low", "medium": "medium", "high": "high",
    "xhigh": "max", "max": "max", "ultra": "max",
}


def _effort_for_anthropic(requested: Any, default: str) -> str:
    """Resolve the adaptive-thinking effort for one request ("" = no thinking)."""
    for candidate in (requested, default):
        if candidate is None:
            continue
        key = str(candidate).strip().lower()
        if not key:
            continue
        if key in _EFFORT_MAP:
            return _EFFORT_MAP[key]
    return ""


def _finish_reason_from_anthropic(payload: dict[str, Any]) -> str:
    stop_reason = payload.get("stop_reason")
    if stop_reason == "tool_use":
        return "tool_calls"
    if stop_reason in (None, "end_turn", "stop_sequence"):
        return "stop"
    if stop_reason == "max_tokens":
        return "length"
    return str(stop_reason)


def _chat_message_from_anthropic_response(payload: dict[str, Any]) -> dict[str, Any]:
    content = payload.get("content") or []
    text_parts: list[str] = []
    tool_calls: list[dict[str, Any]] = []
    if isinstance(content, list):
        for item in content:
            if not isinstance(item, dict):
                continue
            if item.get("type") == "text" and isinstance(item.get("text"), str):
                text_parts.append(item["text"])
            elif item.get("type") == "tool_use" and item.get("name"):
                tool_calls.append(
                    {
                        "id": str(item.get("id") or f"toolu_{uuid.uuid4().hex}"),
                        "type": "function",
                        "function": {
                            "name": str(item["name"]),
                            "arguments": _json_arguments(item.get("input")),
                        },
                    }
                )
    else:
        text_parts.append(str(content))

    # `content: null` is the OpenAI convention for a tool-call-only reply. With
    # adaptive thinking a truncated response can also carry a thinking block and
    # no text; returning null there hands the client an unusable message, so fall
    # back to an empty string whenever there are no tool calls to justify null.
    text = "\n".join(text_parts).strip()
    message: dict[str, Any] = {
        "role": "assistant",
        "content": text or (None if tool_calls else ""),
    }
    if tool_calls:
        message["tool_calls"] = tool_calls
    return message


def _usage_from_anthropic_response(payload: dict[str, Any]) -> dict[str, Any]:
    usage = payload.get("usage") if isinstance(payload.get("usage"), dict) else {}
    input_tokens = int(usage.get("input_tokens") or 0)
    output_tokens = int(usage.get("output_tokens") or 0)
    cache_read = int(usage.get("cache_read_input_tokens") or 0)
    cache_write = int(usage.get("cache_creation_input_tokens") or 0)
    # Anthropic excludes cached input from input_tokens; OpenAI includes it.
    prompt_tokens = input_tokens + cache_read + cache_write
    return {
        "prompt_tokens": prompt_tokens,
        "prompt_tokens_details": {"cached_tokens": cache_read, "cache_write_tokens": cache_write},
        "completion_tokens": output_tokens,
        "total_tokens": prompt_tokens + output_tokens,
    }


class VertexClaudeBridgeHandler(BaseHTTPRequestHandler):
    server_version = "VertexClaudeBridge/0.1"

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

    def _vertex_url(self, model: str, method: str) -> str:
        project_id = self.server.project_id  # type: ignore[attr-defined]
        location = self.server.location  # type: ignore[attr-defined]
        host = _vertex_host(location)
        return (
            f"https://{host}/v1/projects/{project_id}/locations/{location}"
            f"/publishers/anthropic/models/{model}:{method}"
        )

    def do_GET(self) -> None:
        if not self._authorized():
            self._send_json(401, {"error": {"message": "unauthorized"}})
            return

        path = self.path.rstrip("/")
        if path == "/health":
            self._send_json(
                200,
                {
                    "status": "ok",
                    "provider": "vertex-claude",
                    "project_id": self.server.project_id,  # type: ignore[attr-defined]
                    "location": self.server.location,  # type: ignore[attr-defined]
                    "model": self.server.default_model,  # type: ignore[attr-defined]
                },
            )
            return

        if path == "/v1/models":
            self._send_json(
                200,
                {
                    "object": "list",
                    "data": [
                        {
                            "id": self.server.default_model,  # type: ignore[attr-defined]
                            "object": "model",
                            "created": 0,
                            "owned_by": "vertex-ai-anthropic",
                        }
                    ],
                },
            )
            return

        if path == f"/v1/models/{self.server.default_model}":  # type: ignore[attr-defined]
            self._send_json(
                200,
                {
                    "id": self.server.default_model,  # type: ignore[attr-defined]
                    "object": "model",
                    "created": 0,
                    "owned_by": "vertex-ai-anthropic",
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
            raw_body = self.rfile.read(length)
            request = json.loads(raw_body.decode("utf-8"))
        except Exception as exc:
            self._send_json(400, {"error": {"message": f"invalid json: {exc}"}})
            return

        try:
            model = str(request.get("model") or self.server.default_model)  # type: ignore[attr-defined]
            system, messages = _messages_for_anthropic(request.get("messages") or [])
        except Exception as exc:
            self._send_json(400, {"error": {"message": str(exc)}})
            return

        prompt_chars = sum(len(_text_from_chat_content(message.get("content"))) for message in request.get("messages") or [])
        if prompt_chars > self.server.max_prompt_chars:  # type: ignore[attr-defined]
            self._send_json(
                413,
                {
                    "error": {
                        "message": (
                            f"prompt too large: {prompt_chars} chars exceeds "
                            f"{self.server.max_prompt_chars}"  # type: ignore[attr-defined]
                        )
                    }
                },
            )
            return

        vertex_body: dict[str, Any] = {
            "anthropic_version": self.server.anthropic_version,  # type: ignore[attr-defined]
            # An explicit client cap wins; omission means "uncapped" (see
            # DEFAULT_UNCAPPED_MAX_TOKENS) and must NOT fall back to the small
            # chat default, or compression summaries truncate.
            "max_tokens": int(
                request.get("max_tokens")
                or self.server.uncapped_max_tokens  # type: ignore[attr-defined]
            ),
            "messages": messages,
        }
        if system:
            vertex_body["system"] = system
        for source_key, target_key in (("temperature", "temperature"), ("top_p", "top_p"), ("top_k", "top_k")):
            if source_key in request and request[source_key] is not None:
                vertex_body[target_key] = request[source_key]
        stop_sequences = _split_stop(request.get("stop"))
        if stop_sequences:
            vertex_body["stop_sequences"] = stop_sequences
        anthropic_tools = _tools_for_anthropic(request.get("tools"))
        if anthropic_tools:
            vertex_body["tools"] = anthropic_tools
            tool_choice = _tool_choice_for_anthropic(request.get("tool_choice"))
            if tool_choice:
                vertex_body["tool_choice"] = tool_choice
        # Extended thinking. claude-opus-5 on Vertex rejects the older
        # {"type":"enabled","budget_tokens":N} shape outright:
        #   "thinking.type.enabled" is not supported for this model. Use
        #   "thinking.type.adaptive" and "output_config.effort".
        # Adaptive lets the model decide how much to think per request; effort
        # sets the ceiling. The caller's own reasoning_effort wins when present,
        # so Hermes keeps native per-task control (cheap effort for auxiliary
        # tasks, full effort for the main agent) exactly like a first-party
        # client — the bridge only supplies the default.
        effort = _effort_for_anthropic(
            request.get("reasoning_effort"),
            self.server.thinking_effort,  # type: ignore[attr-defined]
        )
        if effort:
            vertex_body["thinking"] = {"type": "adaptive"}
            vertex_body["output_config"] = {"effort": effort}
            # Adaptive thinking spends from the SAME max_tokens as the answer.
            # Measured on claude-opus-5 with a hard SRE question: ~1.7k tokens of
            # thinking at effort=medium, ~2.3k at high. At max_tokens=1200 the
            # entire budget went to thinking and the reply came back with NO text
            # block at all (stop_reason=max_tokens, blocks=['thinking']). Floor
            # the cap so a small caller-supplied limit cannot starve the answer.
            if int(vertex_body["max_tokens"]) < _MIN_THINKING_MAX_TOKENS:
                vertex_body["max_tokens"] = _MIN_THINKING_MAX_TOKENS
            # Verified against Vertex: "`temperature` may only be set to 1 when
            # thinking is enabled or in adaptive mode." Drop the sampling
            # parameters rather than 400 every request.
            for _sampling in ("temperature", "top_p", "top_k"):
                vertex_body.pop(_sampling, None)

        if self.server.prompt_caching:  # type: ignore[attr-defined]
            _apply_cache_control(vertex_body, self.server.cache_ttl)  # type: ignore[attr-defined]

        if request.get("stream") is True:
            stream_options = request.get("stream_options") or {}
            include_usage = isinstance(stream_options, dict) and stream_options.get("include_usage") is True
            self._handle_streaming_chat_completion(model, vertex_body, include_usage=include_usage)
        else:
            self._handle_chat_completion(model, vertex_body)

    def _handle_chat_completion(self, model: str, vertex_body: dict[str, Any]) -> None:
        started = time.time()
        url = self._vertex_url(model, "rawPredict")
        try:
            response = _post_with_retries(
                self.server.session,  # type: ignore[attr-defined]
                url,
                vertex_body,
                self.server.timeout_seconds,  # type: ignore[attr-defined]
                self.server.max_retries,  # type: ignore[attr-defined]
            )
        except Exception as exc:
            self._send_json(502, {"error": {"message": f"vertex request failed: {exc}"}})
            return

        latency_ms = int((time.time() - started) * 1000)
        print(
            f"[vertex-claude-bridge] model={model} status={response.status_code} latency_ms={latency_ms}",
            flush=True,
        )

        if response.status_code >= 400:
            self._send_json(
                response.status_code,
                {"error": {"message": _safe_error_text(response.text), "status_code": response.status_code}},
            )
            return

        try:
            payload = response.json()
        except Exception as exc:
            self._send_json(502, {"error": {"message": f"invalid vertex json response: {exc}"}})
            return

        _log_usage(model, payload)
        message = _chat_message_from_anthropic_response(payload)
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
                        "message": message,
                        "finish_reason": _finish_reason_from_anthropic(payload),
                    }
                ],
                "usage": _usage_from_anthropic_response(payload),
            },
        )

    def _handle_streaming_chat_completion(
        self, model: str, vertex_body: dict[str, Any], *, include_usage: bool = False
    ) -> None:
        # Hermes often prefers streaming responses. Vertex's partner-model
        # streaming shape is not identical to Hermes' SSE expectation, so for
        # this bridge we use rawPredict and wrap the final text in a small
        # chat-completions-compatible
        # event stream. This preserves Hermes compatibility while keeping the
        # Vertex call path deterministic.
        started = time.time()
        url = self._vertex_url(model, "rawPredict")
        try:
            response = _post_with_retries(
                self.server.session,  # type: ignore[attr-defined]
                url,
                vertex_body,
                self.server.timeout_seconds,  # type: ignore[attr-defined]
                self.server.max_retries,  # type: ignore[attr-defined]
            )
        except Exception as exc:
            self._send_json(502, {"error": {"message": f"vertex streaming fallback request failed: {exc}"}})
            return

        latency_ms = int((time.time() - started) * 1000)
        print(
            f"[vertex-claude-bridge] stream_fallback model={model} status={response.status_code} "
            f"latency_ms={latency_ms}",
            flush=True,
        )

        if response.status_code >= 400:
            self._send_json(
                response.status_code,
                {"error": {"message": _safe_error_text(response.text), "status_code": response.status_code}},
            )
            return

        try:
            payload = response.json()
        except Exception as exc:
            self._send_json(502, {"error": {"message": f"invalid vertex json response: {exc}"}})
            return

        _log_usage(model, payload)
        message = _chat_message_from_anthropic_response(payload)
        content = str(message.get("content") or "")
        finish_reason = _finish_reason_from_anthropic(payload)

        completion_id = f"chatcmpl-{uuid.uuid4().hex}"
        created = int(time.time())
        self.send_response(200)
        self.send_header("content-type", "text/event-stream")
        self.send_header("cache-control", "no-cache")
        self.end_headers()

        def send_chunk(delta: dict[str, Any], finish_reason: str | None = None) -> None:
            payload = {
                "id": completion_id,
                "object": "chat.completion.chunk",
                "created": created,
                "model": model,
                "choices": [{"index": 0, "delta": delta, "finish_reason": finish_reason}],
            }
            self.wfile.write(f"data: {json.dumps(payload)}\n\n".encode("utf-8"))

        send_chunk({"role": "assistant"})
        if content:
            send_chunk({"content": content})
        for index, tool_call in enumerate(message.get("tool_calls") or []):
            send_chunk(
                {
                    "tool_calls": [
                        {
                            "index": index,
                            "id": tool_call["id"],
                            "type": "function",
                            "function": tool_call["function"],
                        }
                    ]
                }
            )
        send_chunk({}, finish_reason=finish_reason)
        if include_usage:
            usage_chunk = {
                "id": completion_id,
                "object": "chat.completion.chunk",
                "created": created,
                "model": model,
                "choices": [],
                "usage": _usage_from_anthropic_response(payload),
            }
            self.wfile.write(f"data: {json.dumps(usage_chunk)}\n\n".encode("utf-8"))
        self.wfile.write(b"data: [DONE]\n\n")


def _iter_sse_payloads(lines: Iterable[str]) -> Iterable[dict[str, Any]]:
    for line in lines:
        if not line:
            continue
        if not line.startswith("data:"):
            continue
        data = line.removeprefix("data:").strip()
        if data == "[DONE]":
            break
        try:
            payload = json.loads(data)
        except json.JSONDecodeError:
            continue
        if isinstance(payload, dict):
            yield payload


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", default=os.getenv("VERTEX_CLAUDE_BRIDGE_HOST", "0.0.0.0"))
    parser.add_argument("--port", type=int, default=int(os.getenv("VERTEX_CLAUDE_BRIDGE_PORT", "18182")))
    parser.add_argument(
        "--project-id",
        default=(
            os.getenv("ANTHROPIC_VERTEX_PROJECT_ID")
            or os.getenv("GOOGLE_CLOUD_PROJECT")
            or os.getenv("GCP_PROJECT_ID")
            or ""
        ),
    )
    parser.add_argument("--location", default=os.getenv("CLOUD_ML_REGION") or os.getenv("VERTEX_CLAUDE_LOCATION", DEFAULT_LOCATION))
    parser.add_argument("--model", default=os.getenv("ANTHROPIC_MODEL") or os.getenv("VERTEX_CLAUDE_MODEL", DEFAULT_MODEL))
    parser.add_argument("--api-key", default=os.getenv("VERTEX_CLAUDE_BRIDGE_API_KEY", ""))
    parser.add_argument("--anthropic-version", default=os.getenv("VERTEX_CLAUDE_ANTHROPIC_VERSION", DEFAULT_ANTHROPIC_VERSION))
    parser.add_argument("--max-tokens", type=int, default=int(os.getenv("VERTEX_CLAUDE_MAX_TOKENS", str(DEFAULT_MAX_TOKENS))))
    parser.add_argument(
        "--uncapped-max-tokens",
        type=int,
        default=int(os.getenv("VERTEX_CLAUDE_UNCAPPED_MAX_TOKENS", str(DEFAULT_UNCAPPED_MAX_TOKENS))),
        help="Cap applied when the client sends no max_tokens (compression summaries).",
    )
    parser.add_argument("--timeout", type=int, default=int(os.getenv("VERTEX_CLAUDE_TIMEOUT_SECONDS", "300")))
    parser.add_argument("--max-prompt-chars", type=int, default=int(os.getenv("VERTEX_CLAUDE_MAX_PROMPT_CHARS", str(DEFAULT_MAX_PROMPT_CHARS))))
    parser.add_argument(
        "--thinking-effort",
        default=os.getenv("VERTEX_CLAUDE_THINKING_EFFORT", DEFAULT_THINKING_EFFORT),
        help="Adaptive-thinking effort: none|low|medium|high|max. Overridden per request by reasoning_effort.",
    )
    parser.add_argument(
        "--thinking-budget-tokens",
        type=int,
        default=int(os.getenv("VERTEX_CLAUDE_THINKING_BUDGET_TOKENS", "0")),
    )
    parser.add_argument("--max-retries", type=int, default=int(os.getenv("VERTEX_CLAUDE_MAX_RETRIES", "2")))
    parser.add_argument("--prompt-caching", default=os.getenv("VERTEX_CLAUDE_PROMPT_CACHING", "1"))
    parser.add_argument("--cache-ttl", default=os.getenv("VERTEX_CLAUDE_CACHE_TTL", "1h"))
    args = parser.parse_args()

    if not args.project_id:
        raise SystemExit("missing --project-id or ANTHROPIC_VERTEX_PROJECT_ID/GOOGLE_CLOUD_PROJECT/GCP_PROJECT_ID")

    project_id = args.project_id
    session = AdcSession()
    session.token()  # fail fast at startup if no ADC path is available

    server = ThreadingHTTPServer((args.host, args.port), VertexClaudeBridgeHandler)
    server.session = session  # type: ignore[attr-defined]
    server.project_id = project_id  # type: ignore[attr-defined]
    server.location = args.location  # type: ignore[attr-defined]
    server.default_model = args.model  # type: ignore[attr-defined]
    server.api_key = args.api_key  # type: ignore[attr-defined]
    server.anthropic_version = args.anthropic_version  # type: ignore[attr-defined]
    server.default_max_tokens = args.max_tokens  # type: ignore[attr-defined]
    server.uncapped_max_tokens = max(args.uncapped_max_tokens, args.max_tokens)  # type: ignore[attr-defined]
    server.timeout_seconds = args.timeout  # type: ignore[attr-defined]
    server.max_prompt_chars = args.max_prompt_chars  # type: ignore[attr-defined]
    server.thinking_budget_tokens = args.thinking_budget_tokens  # type: ignore[attr-defined]
    server.thinking_effort = str(args.thinking_effort or "").strip()  # type: ignore[attr-defined]
    server.max_retries = args.max_retries  # type: ignore[attr-defined]
    server.prompt_caching = str(args.prompt_caching).strip().lower() not in ("0", "false", "no", "")  # type: ignore[attr-defined]
    server.cache_ttl = str(args.cache_ttl).strip()  # type: ignore[attr-defined]

    print(
        f"[vertex-claude-bridge] listening on http://{args.host}:{args.port}/v1 "
        f"project={project_id} location={args.location} model={args.model} "
        f"api_key_required={bool(args.api_key)}",
        flush=True,
    )
    server.serve_forever()


if __name__ == "__main__":
    main()
