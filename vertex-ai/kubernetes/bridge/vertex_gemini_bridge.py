#!/usr/bin/env python3
"""Hermes-compatible bridge for Hermes -> Vertex AI Gemini.

Unlike the sibling `vertex_claude_bridge.py`, this bridge does **not** translate
schemas. Vertex AI exposes an OpenAI-compatible surface for Gemini at

    /v1/projects/{project}/locations/{location}/endpoints/openapi/chat/completions

which already speaks the chat-completions dialect Hermes emits (including tools,
tool calls, tool results and SSE streaming). So the only work left is:

  * authenticate to Google with ADC / GKE Workload Identity (no JSON key),
  * gate inbound requests on the shared bridge API key,
  * qualify the model id with the `google/` publisher prefix Vertex requires,
  * normalise the model id back on the way out so Hermes sees what it asked for,
  * retry transient Vertex failures instead of surfacing them as hard errors.

Keeping it a proxy rather than a translator means new Gemini request fields work
the day Vertex ships them, with no change here.
"""

from __future__ import annotations

import argparse
import hmac
import json
import os
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any

import google.auth
from google.auth.transport.requests import AuthorizedSession


DEFAULT_MODEL = "gemini-3.5-flash"
# Gemini 3.x is served from the multi-region `global` endpoint. Regional
# locations return 404 "Publisher model ... not found" for it, so `global`
# is the default rather than a per-region value.
DEFAULT_LOCATION = "global"
DEFAULT_MAX_TOKENS = 8192
DEFAULT_MAX_PROMPT_CHARS = 200_000
GOOGLE_CLOUD_SCOPE = "https://www.googleapis.com/auth/cloud-platform"
RETRYABLE_STATUS = {429, 500, 502, 503, 504}
PUBLISHER_PREFIX = "google/"


def _vertex_host(location: str) -> str:
    """Vertex host for a location: `global` has no regional prefix."""
    if not location or location == "global":
        return "aiplatform.googleapis.com"
    return f"{location}-aiplatform.googleapis.com"


def _qualify_model(model: str) -> str:
    """Vertex's OpenAI surface requires the publisher-qualified model id."""
    model = (model or DEFAULT_MODEL).strip()
    if "/" in model:
        return model
    return f"{PUBLISHER_PREFIX}{model}"


def _bare_model(model: str) -> str:
    return (model or "").split("/", 1)[-1]


def _safe_error_text(text: str) -> str:
    """Trim upstream error bodies so a stray HTML page can't flood the logs."""
    text = (text or "").strip()
    return text[:600]


def _log_usage(model: str, payload: dict[str, Any]) -> None:
    """Emit token usage for cost tracking.

    Gemini bills thinking tokens as output, and reports them separately under
    `completion_tokens_details.reasoning_tokens` — surfaced here because a
    thinking model can spend most of its output budget before emitting any
    visible text, which otherwise looks like an empty reply.
    """
    usage = payload.get("usage") if isinstance(payload.get("usage"), dict) else {}
    details = usage.get("completion_tokens_details") or {}
    print(
        f"[vertex-gemini-bridge] usage model={model} "
        f"input={int(usage.get('prompt_tokens') or 0)} "
        f"output={int(usage.get('completion_tokens') or 0)} "
        f"reasoning={int(details.get('reasoning_tokens') or 0)} "
        f"total={int(usage.get('total_tokens') or 0)}",
        flush=True,
    )


def _post_with_retries(session, url, body, timeout, max_retries, stream=False):
    """POST to Vertex with bounded exponential backoff on transient failures.

    Retries connection errors and 429/5xx; returns the final response (which may
    still carry an error status) once the retry budget is exhausted.
    """
    for attempt in range(max_retries + 1):
        try:
            resp = session.post(url, json=body, timeout=timeout, stream=stream)
        except Exception:
            if attempt >= max_retries:
                raise
            time.sleep(min(0.5 * (2**attempt), 8.0))
            continue
        if resp.status_code in RETRYABLE_STATUS and attempt < max_retries:
            resp.close()
            time.sleep(min(0.5 * (2**attempt), 8.0))
            continue
        return resp


class VertexGeminiBridgeHandler(BaseHTTPRequestHandler):
    server_version = "VertexGeminiBridge/0.1"

    def log_message(self, fmt: str, *args: Any) -> None:  # quieter access log
        print(f"[vertex-gemini-bridge] {fmt % args}", flush=True)

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

    def _vertex_url(self) -> str:
        project_id = self.server.project_id  # type: ignore[attr-defined]
        location = self.server.location  # type: ignore[attr-defined]
        host = _vertex_host(location)
        return (
            f"https://{host}/v1/projects/{project_id}/locations/{location}"
            f"/endpoints/openapi/chat/completions"
        )

    def _model_entry(self) -> dict[str, Any]:
        return {
            "id": self.server.default_model,  # type: ignore[attr-defined]
            "object": "model",
            "created": 0,
            "owned_by": "vertex-ai-google",
        }

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
                    "provider": "vertex-gemini",
                    "project_id": self.server.project_id,  # type: ignore[attr-defined]
                    "location": self.server.location,  # type: ignore[attr-defined]
                    "model": self.server.default_model,  # type: ignore[attr-defined]
                },
            )
            return

        if path == "/v1/models":
            self._send_json(200, {"object": "list", "data": [self._model_entry()]})
            return

        if path == f"/v1/models/{self.server.default_model}":  # type: ignore[attr-defined]
            self._send_json(200, self._model_entry())
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
            request = json.loads(self.rfile.read(length).decode("utf-8"))
        except Exception as exc:
            self._send_json(400, {"error": {"message": f"invalid json: {exc}"}})
            return
        if not isinstance(request, dict):
            self._send_json(400, {"error": {"message": "body must be a JSON object"}})
            return

        messages = request.get("messages") or []
        prompt_chars = sum(len(json.dumps(m.get("content") or "")) for m in messages if isinstance(m, dict))
        max_prompt_chars = self.server.max_prompt_chars  # type: ignore[attr-defined]
        if prompt_chars > max_prompt_chars:
            self._send_json(
                413,
                {"error": {"message": f"prompt too large: {prompt_chars} chars > {max_prompt_chars}"}},
            )
            return

        requested_model = str(request.get("model") or self.server.default_model)  # type: ignore[attr-defined]
        body = dict(request)
        body["model"] = _qualify_model(requested_model)
        # A thinking model spends output budget on reasoning before any visible
        # text, so an unset/low cap reads as an empty completion. Always send one.
        if not body.get("max_tokens"):
            body["max_tokens"] = self.server.max_tokens  # type: ignore[attr-defined]
        for key in self.server.drop_keys:  # type: ignore[attr-defined]
            body.pop(key, None)

        if body.get("stream"):
            self._handle_streaming(body, requested_model)
        else:
            self._handle_completion(body, requested_model)

    def _handle_completion(self, body: dict[str, Any], display_model: str) -> None:
        session = self.server.session  # type: ignore[attr-defined]
        try:
            resp = _post_with_retries(
                session,
                self._vertex_url(),
                body,
                self.server.timeout,  # type: ignore[attr-defined]
                self.server.max_retries,  # type: ignore[attr-defined]
            )
        except Exception as exc:
            self._send_json(502, {"error": {"message": f"vertex request failed: {exc}"}})
            return

        if resp.status_code != 200:
            self._send_json(
                resp.status_code,
                {"error": {"message": f"vertex error {resp.status_code}: {_safe_error_text(resp.text)}"}},
            )
            return

        try:
            payload = resp.json()
        except Exception:
            self._send_json(
                502,
                {"error": {"message": f"vertex returned non-JSON: {_safe_error_text(resp.text)}"}},
            )
            return

        _log_usage(body["model"], payload)
        # Hand back the id Hermes asked for; it matches responses to its config.
        payload["model"] = _bare_model(display_model)
        self._send_json(200, payload)

    def _handle_streaming(self, body: dict[str, Any], display_model: str) -> None:
        """Relay Vertex's chat-completions SSE straight through to Hermes.

        Vertex already emits `chat.completion.chunk` events in the shape Hermes
        expects, so this forwards frames verbatim rather than re-chunking. Only
        the model id is rewritten, for the same reason as the non-streaming path.
        """
        session = self.server.session  # type: ignore[attr-defined]
        try:
            resp = _post_with_retries(
                session,
                self._vertex_url(),
                body,
                self.server.timeout,  # type: ignore[attr-defined]
                self.server.max_retries,  # type: ignore[attr-defined]
                stream=True,
            )
        except Exception as exc:
            self._send_json(502, {"error": {"message": f"vertex request failed: {exc}"}})
            return

        if resp.status_code != 200:
            self._send_json(
                resp.status_code,
                {"error": {"message": f"vertex error {resp.status_code}: {_safe_error_text(resp.text)}"}},
            )
            return

        # BaseHTTPRequestHandler speaks HTTP/1.0, so an SSE body has neither a
        # content-length nor chunked framing — the client must read until EOF.
        # Advertising keep-alive here makes it wait for a length that never
        # comes and the stream hangs, so close the connection instead.
        self.send_response(200)
        self.send_header("content-type", "text/event-stream")
        self.send_header("cache-control", "no-cache")
        self.send_header("connection", "close")
        self.end_headers()
        self.close_connection = True

        bare = _bare_model(display_model)
        # Hermes streams by default, so without this the streaming path would be
        # the common case yet log no token usage at all. Vertex puts usage on the
        # final chunk; keep the last one we see and log it when the stream ends.
        final_usage: dict[str, Any] | None = None
        try:
            for line in resp.iter_lines(decode_unicode=True):
                if line is None:
                    continue
                if not line:
                    self.wfile.write(b"\n")
                    self.wfile.flush()
                    continue
                if line.startswith("data: ") and line[6:].strip() != "[DONE]":
                    try:
                        chunk = json.loads(line[6:])
                        chunk["model"] = bare
                        if isinstance(chunk.get("usage"), dict):
                            final_usage = chunk["usage"]
                        line = "data: " + json.dumps(chunk)
                    except Exception:
                        pass  # pass through anything we can't parse
                self.wfile.write(f"{line}\n".encode("utf-8"))
                self.wfile.flush()
            self.wfile.write(b"\n")
            self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            return  # client hung up mid-stream
        finally:
            resp.close()
            if final_usage is not None:
                _log_usage(body["model"], {"usage": final_usage})


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", default=os.getenv("VERTEX_GEMINI_BRIDGE_HOST", "0.0.0.0"))
    parser.add_argument("--port", type=int, default=int(os.getenv("VERTEX_GEMINI_BRIDGE_PORT", "18182")))
    parser.add_argument(
        "--project-id",
        default=(
            os.getenv("VERTEX_GEMINI_PROJECT_ID")
            or os.getenv("GOOGLE_CLOUD_PROJECT")
            or os.getenv("GCP_PROJECT_ID")
            or ""
        ),
    )
    parser.add_argument(
        "--location",
        default=os.getenv("CLOUD_ML_REGION") or os.getenv("VERTEX_GEMINI_LOCATION") or DEFAULT_LOCATION,
    )
    parser.add_argument(
        "--model",
        default=os.getenv("GEMINI_MODEL") or os.getenv("VERTEX_GEMINI_MODEL") or DEFAULT_MODEL,
    )
    parser.add_argument(
        "--api-key",
        default=os.getenv("VERTEX_GEMINI_BRIDGE_API_KEY") or os.getenv("VERTEX_CLAUDE_BRIDGE_API_KEY", ""),
    )
    parser.add_argument(
        "--max-tokens",
        type=int,
        default=int(os.getenv("VERTEX_GEMINI_MAX_TOKENS", str(DEFAULT_MAX_TOKENS))),
    )
    parser.add_argument("--timeout", type=int, default=int(os.getenv("VERTEX_GEMINI_TIMEOUT_SECONDS", "300")))
    parser.add_argument(
        "--max-prompt-chars",
        type=int,
        default=int(os.getenv("VERTEX_GEMINI_MAX_PROMPT_CHARS", str(DEFAULT_MAX_PROMPT_CHARS))),
    )
    parser.add_argument("--max-retries", type=int, default=int(os.getenv("VERTEX_GEMINI_MAX_RETRIES", "2")))
    parser.add_argument(
        "--drop-keys",
        default=os.getenv("VERTEX_GEMINI_DROP_KEYS", ""),
        help="Comma-separated request fields to strip before forwarding to Vertex.",
    )
    args = parser.parse_args()

    credentials, detected_project = google.auth.default(scopes=[GOOGLE_CLOUD_SCOPE])
    project_id = args.project_id or detected_project
    if not project_id:
        raise SystemExit("project id not set: pass --project-id or set GOOGLE_CLOUD_PROJECT")

    server = ThreadingHTTPServer((args.host, args.port), VertexGeminiBridgeHandler)
    server.session = AuthorizedSession(credentials)  # type: ignore[attr-defined]
    server.project_id = project_id  # type: ignore[attr-defined]
    server.location = args.location  # type: ignore[attr-defined]
    server.default_model = _bare_model(args.model)  # type: ignore[attr-defined]
    server.api_key = args.api_key  # type: ignore[attr-defined]
    server.max_tokens = args.max_tokens  # type: ignore[attr-defined]
    server.timeout = args.timeout  # type: ignore[attr-defined]
    server.max_prompt_chars = args.max_prompt_chars  # type: ignore[attr-defined]
    server.max_retries = args.max_retries  # type: ignore[attr-defined]
    server.drop_keys = [k.strip() for k in args.drop_keys.split(",") if k.strip()]  # type: ignore[attr-defined]

    print(
        f"[vertex-gemini-bridge] listening on {args.host}:{args.port} "
        f"project={project_id} location={args.location} model={server.default_model} "
        f"auth={'on' if args.api_key else 'off'}",
        flush=True,
    )
    server.serve_forever()


if __name__ == "__main__":
    main()
