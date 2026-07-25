#!/usr/bin/env python3
"""claude_code_bridge.py — Claude Code–compatible bridge from Hermes to the Claude Code CLI.

Fulfils each request by invoking an already-authenticated ``claude -p`` process and
exposes it over an OpenAI-compatible chat-completions HTTP surface that Hermes (or any
chat-completions client) can point a custom provider at.

Highlights:
  * Real usage + cost — parses ``claude -p --output-format json`` and reports actual
    input/output/cache tokens and ``total_cost_usd`` in the ``usage`` block and access log.
  * Real streaming — ``--output-format stream-json`` events become incremental
    ``chat.completion.chunk`` SSE deltas as Claude produces them.
  * Model selection — forwards the client-requested model to ``claude --model`` (pass-model).
  * Concurrency control — a bounded semaphore caps concurrent ``claude`` subprocesses,
    returning a fast 429 when saturated so a burst can't fork-bomb the host.
  * Correct roles — ``system`` messages become ``--append-system-prompt``.
  * Operability — process-group kill on timeout, graceful SIGTERM/SIGINT drain,
    constant-time auth, and ``/health`` / ``/config`` / ``/v1/models`` / ``/metrics``.

Stdlib only; no third-party deps, so it stays trivially portable onto a developer host
or into a slim container.
"""

from __future__ import annotations

import argparse
import hmac
import json
import os
import shutil
import signal
import subprocess
import threading
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any, Iterator, Optional

BRIDGE_VERSION = "1.0.0"
_IS_WINDOWS = os.name == "nt"


def default_claude_bin() -> str:
    """Best-effort cross-platform default for the Claude Code CLI.

    Prefers an explicit env var, then whatever ``claude`` is on PATH (resolves
    ``claude.cmd``/``claude.exe`` on Windows), then the common POSIX install path.
    """
    env = os.getenv("CLAUDE_BIN")
    if env:
        return env
    found = shutil.which("claude")
    if found:
        return found
    return os.path.expanduser("~/.local/bin/claude")


def resolve_claude_bin(value: str) -> Optional[str]:
    """Return an existing path for ``value`` (direct path or a PATH lookup)."""
    if value and os.path.exists(value):
        return value
    return shutil.which(value) if value else None


DEFAULT_CLAUDE_BIN = default_claude_bin()
DEFAULT_MODEL = "claude-opus-4-8"
# The set of Claude model IDs the bridge advertises on ``/v1/models`` by default.
# The bridge just forwards ``--model`` to the Claude Code CLI, so this is the
# catalogue clients can pick from. Override per-deployment with --models /
# CLAUDE_CODE_BRIDGE_MODELS (comma-separated). The configured --model is always
# merged in so the default is never missing from the list.
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
# Allow-everything by default: bypass all permission prompts so the bridge exposes
# the FULL set of Claude Code tools/connectors to Hermes (e.g. the claude.ai
# MCP tools). Lock it down per-deployment with --disallowed-tools
# / --allowed-tools / --permission-mode if you want a narrower surface.
DEFAULT_PERMISSION_MODE = "bypassPermissions"
DEFAULT_MAX_PROMPT_CHARS = 200_000
DEFAULT_TIMEOUT = 240
DEFAULT_MAX_CONCURRENCY = 4
DEFAULT_QUEUE_WAIT = 30  # seconds a request waits for a concurrency slot before 429

_REDACT_MARKERS = ("sk-ant-", "Bearer ", "Authorization:", "api_key", "apiKey")


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


def split_messages(messages: list[dict[str, Any]]) -> tuple[str, str]:
    """Return (prompt, system_prompt).

    ``system`` messages are concatenated into the system prompt; user/assistant
    turns become the conversational prompt; the system role is passed via
    --append-system-prompt rather than dumped into the prompt body.
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
    return "\n\n".join(convo).strip(), "\n\n".join(system_parts).strip()


def _safe_error_text(text: str) -> str:
    redacted = (text or "").strip()
    for marker in _REDACT_MARKERS:
        if marker in redacted:
            redacted = redacted.replace(marker, f"{marker[:3]}[redacted]")
    return redacted[-4000:]


def looks_like_claude_model(model: str) -> bool:
    normalized = (model or "").strip().lower()
    return normalized.startswith("claude-") or normalized.startswith("anthropic/")


def _usage_block(usage: dict[str, Any]) -> dict[str, int]:
    """Map Claude Code usage → chat-completions usage (cache reads counted as input)."""
    inp = int(usage.get("input_tokens", 0) or 0)
    inp += int(usage.get("cache_read_input_tokens", 0) or 0)
    inp += int(usage.get("cache_creation_input_tokens", 0) or 0)
    out = int(usage.get("output_tokens", 0) or 0)
    return {"prompt_tokens": inp, "completion_tokens": out, "total_tokens": inp + out}


# ── the Claude Code invocation ────────────────────────────────────────────────
class ClaudeError(RuntimeError):
    def __init__(self, message: str, exit_code: int = 1) -> None:
        super().__init__(message)
        self.exit_code = exit_code


def build_command(cfg: "BridgeConfig", model: str, prompt: str, system_prompt: str,
                  output_format: str) -> list[str]:
    cmd = [
        cfg.claude_bin,
        "--model", model if cfg.pass_model else cfg.default_model,
        "--effort", cfg.effort,
        "--permission-mode", cfg.permission_mode,
        "--no-session-persistence",
        "--output-format", output_format,
    ]
    if output_format == "stream-json":
        cmd.append("--verbose")  # required by the CLI for stream-json with -p
    if cfg.max_budget_usd:
        cmd += ["--max-budget-usd", str(cfg.max_budget_usd)]
    # A bare "*" is not a valid Claude Code *allow* rule; "allow all" is expressed
    # via --permission-mode bypassPermissions, so skip --allowedTools for the * sentinel.
    if cfg.allowed_tools and cfg.allowed_tools != ["*"]:
        cmd += ["--allowedTools", ",".join(cfg.allowed_tools)]
    if cfg.disallowed_tools:
        cmd += ["--disallowedTools", ",".join(cfg.disallowed_tools)]
    appended = "\n\n".join(p for p in (cfg.append_system_prompt, system_prompt) if p)
    if appended:
        cmd += ["--append-system-prompt", appended]
    cmd += ["-p", prompt]
    return cmd


def _popen(cmd: list[str], cfg: "BridgeConfig") -> subprocess.Popen:
    # Put the child in its own group/session so a timeout can kill the whole
    # tree (claude may spawn children), portably across POSIX and Windows.
    kwargs: dict[str, Any] = {}
    if _IS_WINDOWS:
        kwargs["creationflags"] = subprocess.CREATE_NEW_PROCESS_GROUP  # type: ignore[attr-defined]
    else:
        kwargs["start_new_session"] = True
    return subprocess.Popen(
        cmd, cwd=cfg.cwd, text=True,
        stdout=subprocess.PIPE, stderr=subprocess.PIPE,
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


def run_blocking(cfg: "BridgeConfig", model: str, prompt: str, system_prompt: str) -> dict[str, Any]:
    """Run claude to completion in JSON mode; return {'text','usage','cost_usd'}."""
    cmd = build_command(cfg, model, prompt, system_prompt, "json")
    proc = _popen(cmd, cfg)
    try:
        out, err = proc.communicate(timeout=cfg.timeout_seconds)
    except subprocess.TimeoutExpired:
        _kill(proc)
        raise ClaudeError("claude command timed out", exit_code=504)
    if proc.returncode != 0:
        raise ClaudeError(_safe_error_text(err or out or "claude command failed"), proc.returncode)
    # -p --output-format json returns one JSON object.
    try:
        payload = json.loads(out)
    except json.JSONDecodeError:
        return {"text": out.strip(), "usage": {}, "cost_usd": None}
    if isinstance(payload, dict):
        return {
            "text": payload.get("result", "") or "",
            "usage": payload.get("usage", {}) or {},
            "cost_usd": payload.get("total_cost_usd"),
        }
    return {"text": out.strip(), "usage": {}, "cost_usd": None}


def run_streaming(cfg: "BridgeConfig", model: str, prompt: str, system_prompt: str) -> Iterator[dict[str, Any]]:
    """Run claude in stream-json mode; yield {'delta': str} then {'done', 'usage', 'cost_usd'}.

    stream-json emits one JSON object per line: system/init, assistant message
    events, and a final result event. We forward assistant text as deltas.
    """
    cmd = build_command(cfg, model, prompt, system_prompt, "stream-json")
    proc = _popen(cmd, cfg)
    deadline = time.time() + cfg.timeout_seconds
    usage: dict[str, Any] = {}
    cost: Optional[float] = None
    try:
        assert proc.stdout is not None
        for line in proc.stdout:
            if time.time() > deadline:
                _kill(proc)
                raise ClaudeError("claude command timed out", exit_code=504)
            line = line.strip()
            if not line:
                continue
            try:
                event = json.loads(line)
            except json.JSONDecodeError:
                continue
            etype = event.get("type")
            if etype == "assistant":
                for part in (event.get("message", {}) or {}).get("content", []) or []:
                    if isinstance(part, dict) and part.get("type") == "text" and part.get("text"):
                        yield {"delta": part["text"]}
            elif etype == "result":
                usage = event.get("usage", {}) or {}
                cost = event.get("total_cost_usd")
                if event.get("is_error"):
                    raise ClaudeError(_safe_error_text(str(event.get("result", "claude error"))), 502)
        rc = proc.wait(timeout=10)
        if rc != 0:
            err = (proc.stderr.read() if proc.stderr else "") or ""
            raise ClaudeError(_safe_error_text(err or "claude command failed"), rc)
    finally:
        if proc.poll() is None:
            _kill(proc)
    yield {"done": True, "usage": usage, "cost_usd": cost}


# ── config ────────────────────────────────────────────────────────────────────
class BridgeConfig:
    def __init__(self, args: argparse.Namespace) -> None:
        self.claude_bin = args.claude_bin
        self.cwd = args.cwd
        self.default_model = args.model
        # Advertised model catalogue: configured list plus the default model,
        # de-duplicated while preserving order (default first).
        configured = _split_csv(args.models)
        ordered = [args.model] + [m for m in configured if m != args.model]
        seen: set[str] = set()
        self.models = [m for m in ordered if not (m in seen or seen.add(m))]
        self.effort = args.effort
        self.permission_mode = args.permission_mode
        self.max_budget_usd = args.max_budget_usd
        self.allowed_tools = _split_csv(args.allowed_tools)
        self.disallowed_tools = _split_csv(args.disallowed_tools)
        self.append_system_prompt = args.append_system_prompt
        self.max_prompt_chars = args.max_prompt_chars
        self.timeout_seconds = args.timeout
        self.pass_model = args.pass_model
        self.api_key = args.api_key
        self.settings_local = str(Path(args.cwd) / ".claude" / "settings.local.json")


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
    server_version = f"ClaudeCodeBridge/{BRIDGE_VERSION}"

    # typed accessors for the attributes we set on the server instance
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
        print(f"[claude-code-bridge] {self.address_string()} - {fmt % args}", flush=True)

    def _model_obj(self, model_id: Optional[str] = None) -> dict[str, Any]:
        return {"id": model_id or self.cfg.default_model, "object": "model",
                "created": 0, "owned_by": "claude-code-cli"}

    # ── GET ──
    def do_GET(self) -> None:
        if not self._authorized():
            self._send_json(401, {"error": {"message": "unauthorized"}})
            return
        path = self.path.rstrip("/")
        if path == "/health":
            self._send_json(200, {"status": "ok", "version": BRIDGE_VERSION,
                                  "claude_version": self.server.claude_version,  # type: ignore[attr-defined]
                                  "in_flight": self.server.in_flight(),  # type: ignore[attr-defined]
                                  "model": self.cfg.default_model})
            return
        if path == "/metrics":
            self._send_json(200, self.server.metrics.snapshot(self.server.in_flight()))  # type: ignore[attr-defined]
            return
        if path == "/config":
            self._send_json(200, {
                "status": "ok", "version": BRIDGE_VERSION, "model": self.cfg.default_model,
                "models": self.cfg.models,
                "claude_bin": self.cfg.claude_bin, "cwd": self.cfg.cwd,
                "effort": self.cfg.effort, "permission_mode": self.cfg.permission_mode,
                "allowed_tools": self.cfg.allowed_tools, "disallowed_tools": self.cfg.disallowed_tools,
                "max_budget_usd": self.cfg.max_budget_usd, "max_prompt_chars": self.cfg.max_prompt_chars,
                "max_concurrency": self.server.max_concurrency,  # type: ignore[attr-defined]
                "pass_model": self.cfg.pass_model, "api_key_required": bool(self.cfg.api_key),
            })
            return
        if path == "/v1/models":
            self._send_json(200, {"object": "list",
                                  "data": [self._model_obj(m) for m in self.cfg.models]})
            return
        if path.startswith("/v1/models/"):
            model_id = path[len("/v1/models/"):]
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
        if self.path.rstrip("/") != "/v1/chat/completions":
            self._send_json(404, {"error": {"message": "not found"}})
            return
        try:
            length = int(self.headers.get("content-length") or "0")
            request = json.loads(self.rfile.read(length).decode("utf-8"))
        except Exception as exc:  # noqa: BLE001
            self._send_json(400, {"error": {"message": f"invalid json: {exc}"}})
            return

        model = str(request.get("model") or self.cfg.default_model)
        if self.cfg.pass_model and not looks_like_claude_model(model):
            self._send_json(400, {"error": {"message":
                f"model {model!r} cannot be run by the claude-code bridge; it executes the Claude "
                "Code CLI and only serves Claude model IDs."}})
            return

        prompt, system_prompt = split_messages(request.get("messages") or [])
        if not prompt:
            self._send_json(400, {"error": {"message": "request has no prompt text"}})
            return
        if len(prompt) > self.cfg.max_prompt_chars:
            self._send_json(413, {"error": {"message":
                f"prompt too large: {len(prompt)} chars exceeds {self.cfg.max_prompt_chars}"}})
            return

        # Concurrency slot — bound the number of live claude subprocesses.
        if not self.server.slot.acquire(timeout=self.server.queue_wait):  # type: ignore[attr-defined]
            self.server.metrics.rejected_busy += 1  # type: ignore[attr-defined]
            self._send_json(429, {"error": {"message": "bridge busy: too many concurrent requests"}})
            return
        try:
            if request.get("stream") is True:
                self._handle_stream(model, prompt, system_prompt)
            else:
                self._handle_blocking(model, prompt, system_prompt)
        finally:
            self.server.slot.release()  # type: ignore[attr-defined]

    def _handle_blocking(self, model: str, prompt: str, system_prompt: str) -> None:
        started = time.time()
        try:
            res = run_blocking(self.cfg, model, prompt, system_prompt)
        except ClaudeError as exc:
            self.server.metrics.record(error=True)  # type: ignore[attr-defined]
            self._send_json(exc.exit_code if exc.exit_code in (502, 504) else 502,
                            {"error": {"message": str(exc)}})
            return
        usage = _usage_block(res["usage"])
        self.server.metrics.record(cost=res["cost_usd"], out_tokens=usage["completion_tokens"])  # type: ignore[attr-defined]
        print(f"[claude-code-bridge] model={model} chars={len(prompt)} "
              f"out_tokens={usage['completion_tokens']} cost_usd={res['cost_usd']} "
              f"latency_ms={int((time.time()-started)*1000)}", flush=True)
        self._send_json(200, {
            "id": f"chatcmpl-{uuid.uuid4().hex}", "object": "chat.completion",
            "created": int(time.time()), "model": model,
            "choices": [{"index": 0, "message": {"role": "assistant", "content": res["text"]},
                         "finish_reason": "stop"}],
            "usage": usage,
        })

    def _handle_stream(self, model: str, prompt: str, system_prompt: str) -> None:
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
            usage: dict[str, Any] = {}
            cost = None
            for event in run_streaming(self.cfg, model, prompt, system_prompt):
                if "delta" in event:
                    self.wfile.write(frame({"content": event["delta"]}))
                    self.wfile.flush()
                elif event.get("done"):
                    usage, cost = event.get("usage", {}), event.get("cost_usd")
            self.wfile.write(frame({}, finish="stop"))
            self.wfile.write(b"data: [DONE]\n\n")
            ub = _usage_block(usage)
            self.server.metrics.record(cost=cost, out_tokens=ub["completion_tokens"])  # type: ignore[attr-defined]
            print(f"[claude-code-bridge] stream model={model} chars={len(prompt)} "
                  f"out_tokens={ub['completion_tokens']} cost_usd={cost} "
                  f"latency_ms={int((time.time()-started)*1000)}", flush=True)
        except ClaudeError as exc:
            self.server.metrics.record(error=True)  # type: ignore[attr-defined]
            # Best-effort in-band error, then close the stream.
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
                 claude_version: str) -> None:
        super().__init__(addr, handler)
        self.cfg = cfg
        self.metrics = Metrics()
        self.max_concurrency = max_concurrency
        self.queue_wait = queue_wait
        self.claude_version = claude_version
        self.slot = threading.BoundedSemaphore(max_concurrency)
        self._active = threading.Semaphore(max_concurrency)

    def in_flight(self) -> int:
        # available permits on a bounded semaphore -> derive active count
        # (threading.BoundedSemaphore exposes _value under the lock; read best-effort)
        return max(0, self.max_concurrency - self.slot._value)  # type: ignore[attr-defined]


# ── entrypoint ────────────────────────────────────────────────────────────────
def _detect_claude_version(claude_bin: str) -> str:
    try:
        out = subprocess.run([claude_bin, "--version"], capture_output=True, text=True, timeout=10)
        return (out.stdout or out.stderr or "").strip() or "unknown"
    except Exception:  # noqa: BLE001
        return "unknown"


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(description="ClaudeCode-compatible bridge to the Claude Code CLI (Hermes provider; chat-completions surface).")
    p.add_argument("--host", default=os.getenv("BRIDGE_HOST", "127.0.0.1"))
    p.add_argument("--port", type=int, default=int(os.getenv("BRIDGE_PORT", os.getenv("PROXY_PORT", "18181"))))
    p.add_argument("--claude-bin", default=os.getenv("CLAUDE_BIN", DEFAULT_CLAUDE_BIN))
    p.add_argument("--cwd", default=os.getenv("CLAUDE_CODE_BRIDGE_CWD", os.getenv("CLAUDE_CODE_PROXY_CWD", os.getcwd())))
    p.add_argument("--model", default=os.getenv("CLAUDE_CODE_BRIDGE_MODEL", os.getenv("CLAUDE_CODE_PROXY_MODEL", DEFAULT_MODEL)))
    p.add_argument("--models", default=os.getenv("CLAUDE_CODE_BRIDGE_MODELS", ",".join(DEFAULT_MODELS)),
                   help="comma-separated Claude model IDs advertised on /v1/models (the --model default is always included)")
    # Local Desktop default: allow EVERYTHING — the `*` wildcard grants all Claude
    # Code tools (built-ins + every connected MCP connector), with no denylist.
    # Narrow it per-deployment via CLAUDE_CODE_ALLOWED_TOOLS / --disallowed-tools.
    p.add_argument("--allowed-tools", default=os.getenv("CLAUDE_CODE_ALLOWED_TOOLS", "*"))
    p.add_argument("--disallowed-tools", default=os.getenv("CLAUDE_CODE_DISALLOWED_TOOLS", ""))
    p.add_argument("--effort", default=os.getenv("CLAUDE_CODE_EFFORT", DEFAULT_EFFORT))
    p.add_argument("--permission-mode", default=os.getenv("CLAUDE_CODE_PERMISSION_MODE", DEFAULT_PERMISSION_MODE),
                   choices=["acceptEdits", "auto", "bypassPermissions", "default", "dontAsk", "plan"])
    p.add_argument("--max-budget-usd", default=os.getenv("CLAUDE_CODE_MAX_BUDGET_USD", ""))
    p.add_argument("--max-prompt-chars", type=int,
                   default=int(os.getenv("CLAUDE_CODE_MAX_PROMPT_CHARS", str(DEFAULT_MAX_PROMPT_CHARS))))
    p.add_argument("--append-system-prompt", default=os.getenv(
        "CLAUDE_CODE_APPEND_SYSTEM_PROMPT",
        "You are Claude Code, invoked by Hermes through a local bridge. You may use any "
        "available tool or connector to fulfil the request."))
    p.add_argument("--api-key", default=os.getenv("CLAUDE_CODE_BRIDGE_API_KEY", os.getenv("CLAUDE_CODE_PROXY_API_KEY", "")))
    p.add_argument("--timeout", type=int, default=int(os.getenv("CLAUDE_CODE_BRIDGE_TIMEOUT", str(DEFAULT_TIMEOUT))))
    p.add_argument("--max-concurrency", type=int,
                   default=int(os.getenv("CLAUDE_CODE_BRIDGE_MAX_CONCURRENCY", str(DEFAULT_MAX_CONCURRENCY))))
    p.add_argument("--queue-wait", type=int,
                   default=int(os.getenv("CLAUDE_CODE_BRIDGE_QUEUE_WAIT", str(DEFAULT_QUEUE_WAIT))))
    # Honor the client-requested model by default (any valid Claude model ID), so the
    # bridge is not limited to a single model. Use --no-pass-model to pin --model.
    p.add_argument("--pass-model", dest="pass_model", action="store_true", default=True)
    p.add_argument("--no-pass-model", dest="pass_model", action="store_false")
    return p


def main(argv: Optional[list[str]] = None) -> None:
    args = build_parser().parse_args(argv)
    resolved = resolve_claude_bin(args.claude_bin)
    if not resolved:
        raise SystemExit(
            f"claude binary not found: {args.claude_bin!r}. Authenticate Claude Code "
            "and ensure `claude` is on PATH, or pass --claude-bin /full/path.")
    args.claude_bin = resolved
    if not os.path.isdir(args.cwd):
        raise SystemExit(f"working directory not found: {args.cwd}")

    cfg = BridgeConfig(args)
    claude_version = _detect_claude_version(args.claude_bin)
    server = BridgeServer((args.host, args.port), BridgeHandler, cfg,
                          max(1, args.max_concurrency), args.queue_wait, claude_version)

    def _shutdown(signum, _frame):  # graceful drain
        print(f"[claude-code-bridge] signal {signum} — shutting down", flush=True)
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

    print(f"[claude-code-bridge] v{BRIDGE_VERSION} listening on http://{args.host}:{args.port}/v1 "
          f"model={args.model} claude={claude_version} cwd={args.cwd} "
          f"effort={args.effort} permission_mode={args.permission_mode} "
          f"max_concurrency={args.max_concurrency} api_key_required={bool(args.api_key)} "
          f"allowed_tools={cfg.allowed_tools or '(none)'}", flush=True)
    connect_host = "127.0.0.1" if args.host in ("0.0.0.0", "::") else args.host
    print(
        "\n"
        "┌─ Connect Hermes ─────────────────────────────────────────────┐\n"
        "│ In Hermes setup, choose:  Local / custom endpoint            │\n"
        f"│   Base URL: {f'http://{connect_host}:{args.port}/v1':<49}│\n"
        f"│   API key:  {'(required — use your bridge api-key)' if args.api_key else '(leave empty — none required)':<49}│\n"
        f"│   Model:    {args.model:<49}│\n"
        "└──────────────────────────────────────────────────────────────┘",
        flush=True,
    )
    try:
        server.serve_forever()
    finally:
        server.server_close()


def _selfcheck() -> None:
    # offline checks for the two bits with real logic — message
    # splitting (system vs convo) and the Claude usage → chat-completions usage mapping.
    prompt, sysp = split_messages([
        {"role": "system", "content": "be terse"},
        {"role": "user", "content": [{"type": "text", "text": "hi"}]},
    ])
    assert sysp == "be terse", sysp
    assert prompt == "USER:\nhi", repr(prompt)
    u = _usage_block({"input_tokens": 10, "cache_read_input_tokens": 5, "output_tokens": 7})
    assert u == {"prompt_tokens": 15, "completion_tokens": 7, "total_tokens": 22}, u
    assert looks_like_claude_model("claude-opus-4-8") and not looks_like_claude_model("gpt-4o")
    assert build_command(BridgeConfig(build_parser().parse_args([])), "claude-opus-4-8", "p", "s",
                         "stream-json").count("--verbose") == 1
    models = BridgeConfig(build_parser().parse_args(["--model", "claude-sonnet-5",
                                                     "--models", "claude-sonnet-5,claude-opus-4-8"])).models
    assert models == ["claude-sonnet-5", "claude-opus-4-8"], models  # default first, de-duped
    assert DEFAULT_MODEL in BridgeConfig(build_parser().parse_args([])).models
    print("selfcheck ok")


if __name__ == "__main__":
    if os.getenv("BRIDGE_SELFCHECK"):
        _selfcheck()
    else:
        main()
