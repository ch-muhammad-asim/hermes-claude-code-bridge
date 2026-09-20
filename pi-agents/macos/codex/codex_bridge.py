#!/usr/bin/env python3
"""codex_bridge.py — OpenAI-compatible pure-LLM bridge in front of the `codex` CLI.

Each POST /v1/chat/completions becomes one headless ``codex exec --json`` run. Codex is used
as a PLAIN LLM: its own shell/apply-patch tools are kept out of the way (read-only sandbox plus
an explicit instruction), so the agent loop stays in pi — pi renders its tool schemas into the
prompt via ``common/extensions/text-tools-provider`` and executes the calls itself, in YOUR cwd.

    pi (own tools, your cwd) ──▶ codex_bridge.py :18288 ──▶ `codex exec --json` ──▶ gpt-5.6-sol

Sibling of ``../claude-code/native/claude_native_bridge.py`` (NATIVE tool calling over MCP) and
``../../../opencode/hermes-desktop/opencode_bridge.py`` (same wire protocol). Same operability:
streaming SSE, concurrency cap, timeout, /health /config /v1/models. Stdlib only.

Codex emits JSONL events; the ones that matter:
    {"type":"thread.started","thread_id":"…"}
    {"type":"item.completed","item":{"type":"agent_message","text":"…"}}
    {"type":"turn.completed","usage":{"input_tokens":…,"output_tokens":…}}
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import threading
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any, Iterator, Optional

BRIDGE_VERSION = "1.0.0"
DEFAULT_PORT = 18288
DEFAULT_MODEL = "gpt-5.6-sol"
DEFAULT_TIMEOUT = 600
DEFAULT_MAX_CONCURRENCY = 2
DEFAULT_QUEUE_WAIT = 30
DEFAULT_MAX_PROMPT_CHARS = 400_000

# Codex is an agent in its own right, but pi owns the tool loop here. Word this carefully: codex
# must stop using ITS OWN shell/apply-patch tools while still emitting the CALLER's tool-call
# format. An earlier, blunter version ("do not use any tools") made codex refuse to emit
# <tool_call> blocks at all and answer "I can't run that because you told me not to use tools".
PURE_LLM_PREAMBLE = (
    "You are the language model behind an OpenAI-compatible API. The CALLER runs the shell and "
    "edits files, not you.\n"
    "1. Do NOT invoke your own built-in shell, file-editing or patch tools — they run in a "
    "sandbox the caller cannot see, so their results are useless to it.\n"
    "2. DO call your MCP server tools (names beginning `mcp__`) normally and directly whenever "
    "they help — Atlassian/Jira, Slack, browser, REPL and any other connector. Those are yours to "
    "use, they are not the caller's shell, and you should finish that work before replying.\n"
    "3. When the system prompt below defines a tool-call format, you MUST use it for shell and "
    "file work: emit the call in exactly that format as your reply, and the caller will run it and "
    "send you the result. Emitting a call in the caller's format is required — it is not 'using a "
    "tool' in the sense forbidden by rule 1."
)


DEFAULT_CONTEXT_WINDOW = 272_000


def log(msg: str) -> None:
    print(f"[codex] {msg}", flush=True)


def _model_obj(slug: str, display: str = "", context: int = 0) -> dict:
    """One /v1/models entry. `context_length` is what pi sizes its context budget from."""
    window = context or DEFAULT_CONTEXT_WINDOW
    return {
        "id": slug, "object": "model", "created": 0, "owned_by": "codex-cli",
        "display_name": display or slug,
        "context_length": window, "context_window": window,
    }


def discover_models(codex_home: str) -> list[dict]:
    """Read codex's own model catalogue so pi's picker shows every model the TUI offers.

    `$CODEX_HOME/models_cache.json` is what codex itself renders; `visibility` is the field it
    filters on ("list" = offered to the user, "hide" = internal, e.g. auto-review and reserve
    entries). Discovery is best-effort: any failure falls back to the single configured model,
    which is what the bridge advertised before this existed.
    """
    path = os.path.join(codex_home, "models_cache.json")
    try:
        with open(path, encoding="utf-8") as fh:
            cached = json.load(fh)
    except (OSError, json.JSONDecodeError) as exc:
        log(f"model discovery skipped ({exc.__class__.__name__}: {path})")
        return []
    out: list[dict] = []
    for entry in cached.get("models") or []:
        if not isinstance(entry, dict) or entry.get("visibility") != "list":
            continue
        slug = entry.get("slug")
        if slug:
            out.append(_model_obj(slug, entry.get("display_name") or "",
                                  int(entry.get("context_window") or 0)))
    return out


class CodexError(Exception):
    def __init__(self, message: str, status: int = 502) -> None:
        super().__init__(message)
        self.message, self.status = message, status


# --------------------------------------------------------------------------- prompt flattening

def _part_text(part: Any) -> str:
    """OpenAI content parts may be strings or {type,text} dicts; images are not supported here."""
    if isinstance(part, str):
        return part
    if isinstance(part, dict):
        if part.get("type") == "text":
            return str(part.get("text") or "")
        if part.get("type") == "image_url":
            return "[image omitted — the codex bridge is text-only]"
    return ""


def message_text(message: dict) -> str:
    content = message.get("content")
    if isinstance(content, list):
        return "".join(_part_text(p) for p in content)
    return "" if content is None else str(content)


def flatten(messages: list[dict], pure_llm: bool) -> str:
    """Render the chat history into the single prompt `codex exec` accepts on stdin."""
    system = [message_text(m) for m in messages if m.get("role") == "system"]
    if pure_llm:
        system.insert(0, PURE_LLM_PREAMBLE)
    lines: list[str] = []
    if system:
        lines.append("\n\n".join(s for s in system if s.strip()))
    for m in messages:
        role = m.get("role")
        if role == "system":
            continue
        text = message_text(m)
        if not text.strip():
            continue
        lines.append(f"{'User' if role == 'user' else 'Assistant'}: {text}")
    return "\n\n".join(lines).strip()


# --------------------------------------------------------------------------- codex invocation

class Runner:
    def __init__(self, cfg: argparse.Namespace) -> None:
        self.cfg = cfg
        self.sem = threading.BoundedSemaphore(cfg.max_concurrency)
        self.started = time.time()
        self.in_flight = 0
        self.lock = threading.Lock()
        self._dump_seq = 0

    def next_dump(self) -> int:
        with self.lock:
            self._dump_seq += 1
            return self._dump_seq

    def acquire(self) -> None:
        if not self.sem.acquire(timeout=self.cfg.queue_wait):
            raise CodexError(f"bridge busy: {self.cfg.max_concurrency} codex runs already active", 503)
        with self.lock:
            self.in_flight += 1

    def release(self) -> None:
        with self.lock:
            self.in_flight -= 1
        self.sem.release()

    def run(self, prompt: str, model: str) -> dict:
        """One `codex exec` turn. Returns {"text", "usage", "thread_id"}."""
        if len(prompt) > self.cfg.max_prompt_chars:
            raise CodexError(f"prompt too large: {len(prompt)} > {self.cfg.max_prompt_chars} chars", 413)
        argv = [
            self.cfg.codex_bin, "exec", "--json", "--skip-git-repo-check",
            "--sandbox", self.cfg.sandbox, "--model", model, "--cd", self.cfg.cwd,
        ]
        if self.cfg.ephemeral:
            argv.append("--ephemeral")
        # Codex apps/plugins (Atlassian Rovo, Slack, documents…) are gated behind PERSISTED hook
        # trust, which is granted interactively in the TUI. `codex exec` has no prompt, so without
        # this flag the whole apps layer silently disappears and the model reports the tools as
        # unavailable — that is why pi saw no Atlassian while the codex TUI had it. This only skips
        # the trust PROMPT for hooks the user already enabled in ~/.codex/config.toml; the sandbox
        # (read-only by default) still constrains what codex itself may touch.
        if self.cfg.bypass_hook_trust:
            argv.append("--dangerously-bypass-hook-trust")
        argv.append("-")  # prompt arrives on stdin
        try:
            proc = subprocess.run(
                argv, input=prompt, capture_output=True, text=True, timeout=self.cfg.timeout,
            )
        except subprocess.TimeoutExpired:
            raise CodexError(f"codex exec exceeded {self.cfg.timeout}s", 504)
        except FileNotFoundError:
            raise CodexError(f"codex binary not found: {self.cfg.codex_bin}", 500)

        chunks: list[str] = []
        usage: dict = {}
        thread_id = ""
        error_text = ""
        for line in (proc.stdout or "").splitlines():
            line = line.strip()
            if not line or not line.startswith("{"):
                continue
            try:
                event = json.loads(line)
            except json.JSONDecodeError:
                continue
            kind = event.get("type")
            if kind == "thread.started":
                thread_id = event.get("thread_id", "")
            elif kind == "item.completed":
                item = event.get("item") or {}
                if item.get("type") == "agent_message":
                    chunks.append(str(item.get("text") or ""))
            elif kind == "turn.completed":
                usage = event.get("usage") or {}
            elif kind in ("turn.failed", "error"):
                error_text = json.dumps(event.get("error") or event)

        text = "\n".join(c for c in chunks if c).strip()
        if not text:
            detail = error_text or (proc.stderr or "").strip()[-800:] or f"exit {proc.returncode}"
            raise CodexError(f"codex returned no agent message ({detail})")
        return {
            "text": text,
            "thread_id": thread_id,
            "usage": {
                "prompt_tokens": usage.get("input_tokens", 0),
                "completion_tokens": usage.get("output_tokens", 0),
                "total_tokens": usage.get("input_tokens", 0) + usage.get("output_tokens", 0),
            },
        }


# --------------------------------------------------------------------------- HTTP surface

def chunk_text(text: str, size: int = 512) -> Iterator[str]:
    for i in range(0, len(text), size):
        yield text[i:i + size]


class Handler(BaseHTTPRequestHandler):
    runner: Runner = None  # type: ignore[assignment]
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt: str, *args: Any) -> None:  # quieter default access log
        log(f"{self.address_string()} - {fmt % args}")

    # ---- helpers
    def _json(self, payload: dict, status: int = 200) -> None:
        body = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _error(self, message: str, status: int) -> None:
        self._json({"error": {"message": message, "type": "bridge_error", "code": status}}, status)

    def _authorized(self) -> bool:
        key = self.runner.cfg.api_key
        if not key:
            return True
        header = self.headers.get("authorization", "")
        return header.startswith("Bearer ") and header[7:] == key

    def _models(self) -> list[dict]:
        cfg = self.runner.cfg
        if cfg.models:  # explicit override wins over discovery
            return [_model_obj(m.strip()) for m in cfg.models.split(",") if m.strip()]
        discovered = discover_models(cfg.codex_home)
        return discovered or [_model_obj(cfg.model)]

    # ---- routes
    def do_GET(self) -> None:
        path = self.path.split("?")[0].rstrip("/") or "/"
        if path == "/health":
            self._json({
                "status": "ok", "version": BRIDGE_VERSION, "model": self.runner.cfg.model,
                "in_flight": self.runner.in_flight,
                "uptime_s": round(time.time() - self.runner.started, 1),
            })
        elif path == "/config":
            cfg = vars(self.runner.cfg).copy()
            cfg["api_key"] = "set" if cfg.get("api_key") else ""
            self._json(cfg)
        elif path == "/v1/models":
            self._json({"object": "list", "data": self._models()})
        else:
            self._error(f"not found: {path}", 404)

    def do_POST(self) -> None:
        if self.path.split("?")[0].rstrip("/") != "/v1/chat/completions":
            return self._error(f"not found: {self.path}", 404)
        if not self._authorized():
            return self._error("unauthorized", 401)
        try:
            length = int(self.headers.get("content-length") or 0)
            body = json.loads(self.rfile.read(length) or b"{}")
        except (ValueError, json.JSONDecodeError):
            return self._error("invalid JSON body", 400)

        messages = body.get("messages") or []
        if not isinstance(messages, list) or not messages:
            return self._error("messages[] is required", 400)
        dump = self.runner.cfg.dump
        if dump:  # debugging aid: one file per turn, so an auxiliary call cannot hide the real one
            try:
                seq = self.runner.next_dump()
                with open(f"{dump}.{seq}.json", "w", encoding="utf-8") as fh:
                    json.dump(body, fh, indent=2)
            except OSError as exc:
                log(f"could not write dump {dump}: {exc}")
        model = body.get("model") or self.runner.cfg.model
        prompt = flatten(messages, self.runner.cfg.pure_llm)
        stream = bool(body.get("stream"))

        try:
            self.runner.acquire()
        except CodexError as exc:
            return self._error(exc.message, exc.status)
        try:
            log(f"turn model={model} chars={len(prompt)} stream={stream}")
            result = self.runner.run(prompt, model)
        except CodexError as exc:
            self.runner.release()
            return self._error(exc.message, exc.status)
        except Exception as exc:  # never leak a traceback to the client
            self.runner.release()
            return self._error(f"bridge failure: {exc}", 500)
        self.runner.release()

        cid = f"chatcmpl-{uuid.uuid4().hex}"
        if stream:
            self._stream(cid, model, result)
        else:
            self._json({
                "id": cid, "object": "chat.completion", "created": int(time.time()), "model": model,
                "choices": [{"index": 0, "finish_reason": "stop",
                             "message": {"role": "assistant", "content": result["text"]}}],
                "usage": result["usage"],
            })

    def _frame(self, cid: str, model: str, delta: dict, finish: Optional[str] = None) -> bytes:
        payload = {
            "id": cid, "object": "chat.completion.chunk", "created": int(time.time()), "model": model,
            "choices": [{"index": 0, "delta": delta, "finish_reason": finish}],
        }
        return f"data: {json.dumps(payload)}\n\n".encode()

    def _stream(self, cid: str, model: str, result: dict) -> None:
        self.send_response(200)
        self.send_header("content-type", "text/event-stream")
        self.send_header("cache-control", "no-cache")
        self.end_headers()
        try:
            self.wfile.write(self._frame(cid, model, {"role": "assistant", "content": ""}))
            for piece in chunk_text(result["text"]):
                self.wfile.write(self._frame(cid, model, {"content": piece}))
                self.wfile.flush()
            self.wfile.write(self._frame(cid, model, {}, "stop"))
            self.wfile.write(b"data: [DONE]\n\n")
            self.wfile.flush()
        except BrokenPipeError:
            # The client (pi) went away mid-stream — normal on interrupt, not an error.
            log("client disconnected during stream")


def parse_args() -> argparse.Namespace:
    env = os.environ.get
    p = argparse.ArgumentParser(description="OpenAI-compatible bridge over the codex CLI")
    p.add_argument("--port", type=int, default=int(env("CODEX_BRIDGE_PORT", env("BRIDGE_PORT", DEFAULT_PORT))))
    p.add_argument("--host", default=env("CODEX_BRIDGE_HOST", "127.0.0.1"))
    p.add_argument("--model", default=env("CODEX_BRIDGE_MODEL", DEFAULT_MODEL))
    p.add_argument("--models", default=env("CODEX_BRIDGE_MODELS", ""), help="comma list advertised on /v1/models")
    p.add_argument("--codex-bin", default=env("CODEX_BIN", shutil.which("codex") or "codex"))
    p.add_argument("--codex-home", default=env("CODEX_HOME", os.path.expanduser("~/.codex")),
                   help="where models_cache.json lives (model discovery)")
    p.add_argument("--cwd", default=env("CODEX_BRIDGE_CWD", os.path.expanduser("~")))
    p.add_argument("--sandbox", default=env("CODEX_BRIDGE_SANDBOX", "read-only"),
                   choices=["read-only", "workspace-write", "danger-full-access"])
    p.add_argument("--timeout", type=int, default=int(env("CODEX_BRIDGE_TIMEOUT", DEFAULT_TIMEOUT)))
    p.add_argument("--max-concurrency", type=int, default=int(env("CODEX_BRIDGE_MAX_CONCURRENCY", DEFAULT_MAX_CONCURRENCY)))
    p.add_argument("--queue-wait", type=int, default=int(env("CODEX_BRIDGE_QUEUE_WAIT", DEFAULT_QUEUE_WAIT)))
    p.add_argument("--max-prompt-chars", type=int, default=int(env("CODEX_BRIDGE_MAX_PROMPT_CHARS", DEFAULT_MAX_PROMPT_CHARS)))
    p.add_argument("--api-key", default=env("CODEX_BRIDGE_API_KEY", ""))
    p.add_argument("--no-hook-trust-bypass", dest="bypass_hook_trust", action="store_false",
                   default=env("CODEX_BRIDGE_BYPASS_HOOK_TRUST", "1") not in ("0", "false", ""),
                   help="do NOT pass --dangerously-bypass-hook-trust (codex apps/plugins then disappear)")
    p.add_argument("--dump", default=env("CODEX_BRIDGE_DUMP", ""),
                   help="write each incoming request body to this file (debugging)")
    p.add_argument("--ephemeral", action="store_true", default=env("CODEX_BRIDGE_EPHEMERAL", "1") not in ("0", "false", ""))
    p.add_argument("--no-pure-llm", dest="pure_llm", action="store_false", default=True,
                   help="let codex use its own tools instead of staying a plain LLM")
    return p.parse_args()


def main() -> None:
    cfg = parse_args()
    if not shutil.which(cfg.codex_bin) and not os.path.exists(cfg.codex_bin):
        raise SystemExit(f"[codex] error: codex binary not found: {cfg.codex_bin}")
    Handler.runner = Runner(cfg)
    server = ThreadingHTTPServer((cfg.host, cfg.port), Handler)
    server.daemon_threads = True
    log(f"listening on http://{cfg.host}:{cfg.port} — model={cfg.model} sandbox={cfg.sandbox} "
        f"cwd={cfg.cwd} pure_llm={cfg.pure_llm} apps={'on' if cfg.bypass_hook_trust else 'OFF'}")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        log("shutting down")
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
