#!/usr/bin/env python3
"""Hermes-compatible bridge for Hermes -> Amazon Bedrock Claude.

This is a lightweight bridge. It accepts the subset of the chat completions API
that Hermes needs, translates it to Anthropic Messages requests on Bedrock
(`InvokeModel`, `anthropic_version: bedrock-2023-05-31`), authenticates with the
AWS SDK's default credential chain - which in-cluster resolves to EKS Pod
Identity - and translates the response back to the chat-completions JSON shape.

It intentionally does not use static AWS access keys.

Sibling of vertex-ai/kubernetes/bridge/vertex_claude_bridge.py: the translation
layer is deliberately identical, so a fix to the tool loop applies to both. Only
transport and auth differ (boto3 InvokeModel + SigV4 instead of a Google
AuthorizedSession against the Vertex partner endpoint).
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
from typing import Any

import boto3
from botocore.config import Config
from botocore.exceptions import ClientError, EndpointConnectionError


# Claude Sonnet 4.5 is INFERENCE_PROFILE-only on Bedrock: a bare
# anthropic.claude-sonnet-4-5-* modelId is rejected with a ValidationException that
# tells you to use an inference profile. The "us." prefix is a cross-region profile
# that may route inference to us-east-1/us-east-2/us-west-2 - the IAM policy has to
# allow the foundation model in all three (see modules/hermes-bedrock-iam).
DEFAULT_MODEL = "us.anthropic.claude-sonnet-4-5-20250929-v1:0"
DEFAULT_REGION = "us-east-1"
DEFAULT_MAX_TOKENS = 4096
# Bedrock's Anthropic version string, NOT Vertex's vertex-2023-10-16.
DEFAULT_ANTHROPIC_VERSION = "bedrock-2023-05-31"
DEFAULT_MAX_PROMPT_CHARS = 200_000
IMAGE_CACHE_ROOT = Path("/opt/data/image_cache")
MAX_IMAGE_BYTES = 10 * 1024 * 1024

# Bedrock signals transient conditions as modeled exceptions rather than bare HTTP
# status codes, so retry on the error code. ThrottlingException covers both
# on-demand capacity throttles and account-level TPM/RPM quota.
RETRYABLE_ERROR_CODES = {
    "ThrottlingException",
    "TooManyRequestsException",
    "ServiceUnavailableException",
    "InternalServerException",
    "ModelNotReadyException",
    "ModelTimeoutException",
}

# Client errors mapped to the HTTP status Hermes should see. Anything unmapped
# becomes a 502.
ERROR_CODE_STATUS = {
    "ValidationException": 400,
    "AccessDeniedException": 403,
    "ResourceNotFoundException": 404,
    "ThrottlingException": 429,
    "TooManyRequestsException": 429,
    "ModelTimeoutException": 504,
    "ServiceUnavailableException": 503,
    "ServiceQuotaExceededException": 429,
}


def _invoke_with_retries(client, model_id, body, max_retries):
    """InvokeModel with bounded exponential backoff on transient failures.

    Retries connection errors and the modeled transient exceptions above; re-raises
    the final error once retries are exhausted so the caller can map it to a status.
    """
    encoded = json.dumps(body).encode("utf-8")
    for attempt in range(max_retries + 1):
        try:
            return client.invoke_model(
                modelId=model_id,
                body=encoded,
                contentType="application/json",
                accept="application/json",
            )
        except ClientError as exc:
            code = exc.response.get("Error", {}).get("Code", "")
            if code in RETRYABLE_ERROR_CODES and attempt < max_retries:
                time.sleep(min(0.5 * (2 ** attempt), 8.0))
                continue
            raise
        except EndpointConnectionError:
            if attempt >= max_retries:
                raise
            time.sleep(min(0.5 * (2 ** attempt), 8.0))
    raise RuntimeError("unreachable: retry loop exhausted without return or raise")


def _log_usage(model, payload):
    """Emit token usage including prompt-cache hits for cost tracking.

    Bedrock bills Claude Sonnet 4.5 at $3 / 1M input and $15 / 1M output; cache
    reads bill ~0.1x input, cache writes ~1.25x (5m TTL). Derive cost from these
    counts - the sandbox's hard 20,000-token allowance makes them worth watching.
    """
    u = payload.get("usage") if isinstance(payload.get("usage"), dict) else {}
    print(
        f"[bedrock-claude-bridge] usage model={model} "
        f"input={int(u.get('input_tokens') or 0)} "
        f"output={int(u.get('output_tokens') or 0)} "
        f"cache_write={int(u.get('cache_creation_input_tokens') or 0)} "
        f"cache_read={int(u.get('cache_read_input_tokens') or 0)}",
        flush=True,
    )


def _apply_cache_control(body, ttl="1h"):
    """Place explicit prompt-cache breakpoints on the stable prefix.

    Bedrock supports prompt caching but not top-level automatic caching, so
    cache_control goes on content blocks directly: the last tool, the system
    prompt, and the last message block (caches tools + system + conversation
    prefix). Max 4 breakpoints; we use at most 3.

    ttl "1h" keeps the cached prefix alive across the multi-minute gaps typical of
    interactive Slack threads; the 5m default would expire and force a re-write
    (1.25x) instead of a read (0.1x). Set BEDROCK_CLAUDE_CACHE_TTL=5m if traffic is
    dense enough that cache writes dominate the usage logs, or to "" to send no ttl
    field at all (Bedrock then applies its 5m default).
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


def _safe_error_text(text: str) -> str:
    redacted = text.strip()
    for marker in ("Authorization:", "Bearer ", "AWS4-HMAC-SHA256", "x-amz-security-token", "aws_secret_access_key", "SessionToken", "api_key", "apiKey"):
        if marker in redacted:
            redacted = redacted.replace(marker, f"{marker[:3]}[redacted]")
    return redacted[-4000:]


def _status_from_client_error(exc: ClientError) -> tuple[int, str]:
    error = exc.response.get("Error", {}) if isinstance(exc.response, dict) else {}
    code = str(error.get("Code") or "")
    message = str(error.get("Message") or str(exc))
    http_status = 0
    metadata = exc.response.get("ResponseMetadata") if isinstance(exc.response, dict) else None
    if isinstance(metadata, dict):
        http_status = int(metadata.get("HTTPStatusCode") or 0)
    status = ERROR_CODE_STATUS.get(code) or (http_status if http_status >= 400 else 502)
    return status, f"{code}: {message}" if code else message


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

    message: dict[str, Any] = {"role": "assistant", "content": "\n".join(text_parts).strip() or None}
    if tool_calls:
        message["tool_calls"] = tool_calls
    return message


def _usage_from_anthropic_response(payload: dict[str, Any]) -> dict[str, int]:
    usage = payload.get("usage") if isinstance(payload.get("usage"), dict) else {}
    input_tokens = int(usage.get("input_tokens") or 0)
    output_tokens = int(usage.get("output_tokens") or 0)
    return {
        "prompt_tokens": input_tokens,
        "completion_tokens": output_tokens,
        "total_tokens": input_tokens + output_tokens,
    }


class BedrockClaudeBridgeHandler(BaseHTTPRequestHandler):
    server_version = "BedrockClaudeBridge/0.1"

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

    def do_GET(self) -> None:
        if not self._authorized():
            self._send_json(401, {"error": {"message": "unauthorized"}})
            return

        path = self.path.rstrip("/")
        if path == "/health":
            # Deliberately does NOT invoke the model: the readiness probe runs every
            # 10s, and an AI sandbox caps the account at 20,000 Bedrock tokens for
            # the whole lab. A probe that spent tokens would exhaust the allowance
            # before anyone asked the agent a question.
            self._send_json(
                200,
                {
                    "status": "ok",
                    "provider": "bedrock-claude",
                    "region": self.server.region,  # type: ignore[attr-defined]
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
                            "owned_by": "bedrock-anthropic",
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
                    "owned_by": "bedrock-anthropic",
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

        bedrock_body: dict[str, Any] = {
            "anthropic_version": self.server.anthropic_version,  # type: ignore[attr-defined]
            "max_tokens": int(request.get("max_tokens") or self.server.default_max_tokens),  # type: ignore[attr-defined]
            "messages": messages,
        }
        if system:
            bedrock_body["system"] = system
        for source_key, target_key in (("temperature", "temperature"), ("top_p", "top_p"), ("top_k", "top_k")):
            if source_key in request and request[source_key] is not None:
                bedrock_body[target_key] = request[source_key]
        stop_sequences = _split_stop(request.get("stop"))
        if stop_sequences:
            bedrock_body["stop_sequences"] = stop_sequences
        anthropic_tools = _tools_for_anthropic(request.get("tools"))
        if anthropic_tools:
            bedrock_body["tools"] = anthropic_tools
            tool_choice = _tool_choice_for_anthropic(request.get("tool_choice"))
            if tool_choice:
                bedrock_body["tool_choice"] = tool_choice
        if self.server.thinking_budget_tokens:  # type: ignore[attr-defined]
            # Sonnet 4.5 predates adaptive thinking, so it takes the older
            # explicit-budget form. budget_tokens must be < max_tokens and >= 1024.
            bedrock_body["thinking"] = {
                "type": "enabled",
                "budget_tokens": self.server.thinking_budget_tokens,  # type: ignore[attr-defined]
            }

        if self.server.prompt_caching:  # type: ignore[attr-defined]
            _apply_cache_control(bedrock_body, self.server.cache_ttl)  # type: ignore[attr-defined]

        payload = self._invoke(model, bedrock_body)
        if payload is None:
            return

        if request.get("stream") is True:
            self._send_streaming_chat_completion(model, payload)
        else:
            self._send_chat_completion(model, payload)

    def _invoke(self, model: str, bedrock_body: dict[str, Any]) -> dict[str, Any] | None:
        """Call Bedrock once and return the parsed Anthropic payload.

        Sends the error response itself and returns None on failure, so both the
        streaming and non-streaming paths share one call site and one error map.
        """
        started = time.time()
        try:
            response = _invoke_with_retries(
                self.server.client,  # type: ignore[attr-defined]
                model,
                bedrock_body,
                self.server.max_retries,  # type: ignore[attr-defined]
            )
        except ClientError as exc:
            status, message = _status_from_client_error(exc)
            print(
                f"[bedrock-claude-bridge] model={model} status={status} error={_safe_error_text(message)}",
                flush=True,
            )
            self._send_json(status, {"error": {"message": _safe_error_text(message), "status_code": status}})
            return None
        except Exception as exc:
            self._send_json(502, {"error": {"message": f"bedrock request failed: {_safe_error_text(str(exc))}"}})
            return None

        latency_ms = int((time.time() - started) * 1000)
        print(
            f"[bedrock-claude-bridge] model={model} status=200 latency_ms={latency_ms}",
            flush=True,
        )

        try:
            payload = json.loads(response["body"].read().decode("utf-8"))
        except Exception as exc:
            self._send_json(502, {"error": {"message": f"invalid bedrock json response: {exc}"}})
            return None

        _log_usage(model, payload)
        return payload

    def _send_chat_completion(self, model: str, payload: dict[str, Any]) -> None:
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

    def _send_streaming_chat_completion(self, model: str, payload: dict[str, Any]) -> None:
        # Hermes often prefers streaming responses. Bedrock's
        # InvokeModelWithResponseStream event shape is not the SSE shape Hermes
        # expects, so this bridge uses InvokeModel and wraps the final response in a
        # small chat-completions-compatible event stream. That keeps Hermes
        # compatibility while keeping the Bedrock call path deterministic - and it
        # keeps the tool-call translation identical between the two paths.
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
            chunk = {
                "id": completion_id,
                "object": "chat.completion.chunk",
                "created": created,
                "model": model,
                "choices": [{"index": 0, "delta": delta, "finish_reason": finish_reason}],
            }
            self.wfile.write(f"data: {json.dumps(chunk)}\n\n".encode("utf-8"))

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
        self.wfile.write(b"data: [DONE]\n\n")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", default=os.getenv("BEDROCK_CLAUDE_BRIDGE_HOST", "0.0.0.0"))
    parser.add_argument("--port", type=int, default=int(os.getenv("BEDROCK_CLAUDE_BRIDGE_PORT", "18182")))
    parser.add_argument(
        "--region",
        default=(
            os.getenv("AWS_REGION")
            or os.getenv("AWS_DEFAULT_REGION")
            or os.getenv("BEDROCK_CLAUDE_REGION")
            or DEFAULT_REGION
        ),
    )
    parser.add_argument("--model", default=os.getenv("ANTHROPIC_MODEL") or os.getenv("BEDROCK_CLAUDE_MODEL", DEFAULT_MODEL))
    parser.add_argument("--api-key", default=os.getenv("BEDROCK_CLAUDE_BRIDGE_API_KEY", ""))
    parser.add_argument("--anthropic-version", default=os.getenv("BEDROCK_CLAUDE_ANTHROPIC_VERSION", DEFAULT_ANTHROPIC_VERSION))
    parser.add_argument("--max-tokens", type=int, default=int(os.getenv("BEDROCK_CLAUDE_MAX_TOKENS", str(DEFAULT_MAX_TOKENS))))
    parser.add_argument("--timeout", type=int, default=int(os.getenv("BEDROCK_CLAUDE_TIMEOUT_SECONDS", "300")))
    parser.add_argument("--max-prompt-chars", type=int, default=int(os.getenv("BEDROCK_CLAUDE_MAX_PROMPT_CHARS", str(DEFAULT_MAX_PROMPT_CHARS))))
    parser.add_argument(
        "--thinking-budget-tokens",
        type=int,
        default=int(os.getenv("BEDROCK_CLAUDE_THINKING_BUDGET_TOKENS", "0")),
    )
    parser.add_argument("--max-retries", type=int, default=int(os.getenv("BEDROCK_CLAUDE_MAX_RETRIES", "2")))
    parser.add_argument("--prompt-caching", default=os.getenv("BEDROCK_CLAUDE_PROMPT_CACHING", "1"))
    parser.add_argument("--cache-ttl", default=os.getenv("BEDROCK_CLAUDE_CACHE_TTL", "1h"))
    args = parser.parse_args()

    # botocore's own retries are left at a single standard-mode attempt: the
    # bounded loop in _invoke_with_retries owns the backoff so the retry budget is
    # visible in one place and cannot multiply (3 botocore x 3 here = 9 calls).
    client = boto3.client(
        "bedrock-runtime",
        region_name=args.region,
        config=Config(
            read_timeout=args.timeout,
            connect_timeout=10,
            retries={"max_attempts": 1, "mode": "standard"},
        ),
    )

    server = ThreadingHTTPServer((args.host, args.port), BedrockClaudeBridgeHandler)
    server.client = client  # type: ignore[attr-defined]
    server.region = args.region  # type: ignore[attr-defined]
    server.default_model = args.model  # type: ignore[attr-defined]
    server.api_key = args.api_key  # type: ignore[attr-defined]
    server.anthropic_version = args.anthropic_version  # type: ignore[attr-defined]
    server.default_max_tokens = args.max_tokens  # type: ignore[attr-defined]
    server.timeout_seconds = args.timeout  # type: ignore[attr-defined]
    server.max_prompt_chars = args.max_prompt_chars  # type: ignore[attr-defined]
    server.thinking_budget_tokens = args.thinking_budget_tokens  # type: ignore[attr-defined]
    server.max_retries = args.max_retries  # type: ignore[attr-defined]
    server.prompt_caching = str(args.prompt_caching).strip().lower() not in ("0", "false", "no", "")  # type: ignore[attr-defined]
    server.cache_ttl = str(args.cache_ttl).strip()  # type: ignore[attr-defined]

    print(
        f"[bedrock-claude-bridge] listening on http://{args.host}:{args.port}/v1 "
        f"region={args.region} model={args.model} "
        f"api_key_required={bool(args.api_key)}",
        flush=True,
    )
    server.serve_forever()


if __name__ == "__main__":
    main()
