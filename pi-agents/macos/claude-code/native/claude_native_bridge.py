#!/usr/bin/env python3
"""claude_native_bridge.py — OpenAI-compatible bridge to Claude Code with NATIVE tool calling.

Unlike ``mac/claude_code_bridge.py`` (one ``claude -p`` per request, text only), this bridge:

  * honours the OpenAI ``tools`` field — the client's tools (pi's bash/read/write/edit/…) are
    exposed to Claude as REAL functions through a tiny MCP server (``mcp_shim.py``) that Claude
    spawns; Claude's calls come back to the client as standard ``tool_calls`` responses, the
    client executes them and returns ``role: tool`` messages, and Claude continues its turn;
  * keeps ONE warm ``claude`` process per conversation (``--input-format stream-json``): a follow
    -up user message or a tool result is fed to the same process — no per-turn spawn cost,
    connector handshakes done once, Claude keeps its own context;
  * streams real deltas (``--include-partial-messages``), including incremental tool-call JSON.

    pi ──/v1/chat/completions (tools)──▶ bridge ──stdin stream-json──▶ claude -p ──MCP──▶ mcp_shim.py
                                          ▲                                                 │ unix socket
                                          └───────────── tool call → tool_calls response ◀──┘
    pi runs the tool → next request carries role:tool → bridge → shim → Claude continues.

Session routing is stateless for the client: the full OpenAI history arrives every request; the
bridge matches it against the history of each live session (prefix equality, or a ``tool`` message
whose ``tool_call_id`` is pending) and otherwise starts a fresh process seeded with the history.

Claude's own local tools are disallowed (the client owns the machine); its claude.ai connectors
stay available (allowlist via CLAUDE_CODE_ALLOWED_TOOLS, ``*`` = everything / bypassPermissions).
Stdlib only.
"""

from __future__ import annotations

import argparse
import hashlib
import hmac
import json
import os
import queue
import shutil
import signal
import socket
import subprocess
import tempfile
import threading
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any, Iterator, Optional

BRIDGE_VERSION = "1.0.0"
HERE = os.path.dirname(os.path.abspath(__file__))
SHIM = os.path.join(HERE, "mcp_shim.py")
DEFAULT_MODEL = "claude-opus-5"
DEFAULT_MODELS = ["claude-opus-5", "claude-fable-5-1", "claude-fable-5", "claude-opus-4-8", "claude-sonnet-5",
                  "claude-sonnet-4-6", "claude-haiku-4-5"]
# Context windows advertised on /v1/models. Without them an OpenAI-compatible client
# has no way to size its context budget and falls back to its own default — pi assumes
# 200k, so on a 1M model it auto-compacts at a fifth of the usable window.
MODEL_CONTEXT_WINDOWS = {
    "claude-opus-5": 1_000_000,
    "claude-fable-5-1": 1_000_000,
    "claude-fable-5": 1_000_000,
    "claude-opus-4-8": 1_000_000,
    "claude-sonnet-5": 1_000_000,
    "claude-sonnet-4-6": 1_000_000,
    "claude-haiku-4-5": 200_000,
}
# Conservative fallback for an id we don't know: better to compact early than to
# overrun the window and have the CLI reject the request.
DEFAULT_CONTEXT_WINDOW = 200_000
# WebSearch/WebFetch are deliberately NOT in here: pi has no web tool of its own, so denying
# Claude's would leave the agent with no way to reach the internet at all. They stay on for the
# same reason connectors do — the work happens inside Claude, not on the host.
DEFAULT_BUILTINS = ("Bash,Edit,Write,MultiEdit,NotebookEdit,Read,Glob,Grep,LS,Task,TodoWrite,TodoRead,"
                    "AskUserQuestion,Skill,SlashCommand,KillShell,BashOutput,EnterPlanMode,ExitPlanMode,PowerShell,"
                    "CronCreate,CronDelete,CronList,Monitor,RemoteTrigger,SendMessage,ListAgents,TaskOutput,TaskStop,"
                    "EnterWorktree,ExitWorktree,PushNotification")


def _model_obj(model_id: str) -> dict:
    """One OpenAI `/v1/models` entry, carrying the context window clients need.

    `context_length` is the field pi and most OpenAI-compatible clients read;
    `context_window` is emitted too because some clients look for that spelling.
    """
    window = MODEL_CONTEXT_WINDOWS.get(model_id, DEFAULT_CONTEXT_WINDOW)
    return {"id": model_id, "object": "model", "created": 0, "owned_by": "claude-code-native",
            "context_length": window, "context_window": window}


HOST_SERVER = "host"                       # MCP server name → tools appear as mcp__host__<name>
HOST_PREFIX = f"mcp__{HOST_SERVER}__"
_EFFORTS = ("low", "medium", "high", "xhigh", "max")
# Variables that make a spawned `claude` look like a third-party harness (extra-usage billing).
_SCRUB_ENV_PREFIXES = ("CLAUDE_CODE_",)
_SCRUB_ENV = {"CLAUDECODE", "ANTHROPIC_BASE_URL", "CLAUDE_AGENT_SDK_VERSION"}


# ── helpers ──────────────────────────────────────────────────────────────────
def _split_csv(v: str) -> list[str]:
    return [p.strip() for p in (v or "").split(",") if p.strip()]


def _text_of(content: Any) -> str:
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return "\n".join(p.get("text", "") for p in content if isinstance(p, dict) and p.get("type") == "text")
    return "" if content is None else str(content)


def effort_from_request(req: dict[str, Any]) -> Optional[str]:
    raw = req.get("reasoning_effort")
    if raw is None and isinstance(req.get("reasoning"), dict):
        raw = req["reasoning"].get("effort")
    v = str(raw or "").strip().lower()
    if v in ("none", "minimal"):
        return "low"
    return v if v in _EFFORTS else None


def normalize(messages: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """Canonical view of an OpenAI message list for prefix matching (and history seeding)."""
    out: list[dict[str, Any]] = []
    for m in messages or []:
        role = str(m.get("role") or "user")
        if role == "system":
            continue
        entry: dict[str, Any] = {"role": role, "text": _text_of(m.get("content")).strip()}
        if role == "assistant" and m.get("tool_calls"):
            entry["tool_calls"] = [{"id": tc.get("id"), "name": (tc.get("function") or {}).get("name"),
                                    "arguments": (tc.get("function") or {}).get("arguments")} for tc in m["tool_calls"]]
        if role == "tool":
            entry["tool_call_id"] = m.get("tool_call_id")
        out.append(entry)
    return out


def system_text(messages: list[dict[str, Any]]) -> str:
    return "\n\n".join(_text_of(m.get("content")).strip() for m in messages or [] if m.get("role") == "system" and _text_of(m.get("content")).strip())


def tools_from_request(req: dict[str, Any]) -> list[dict[str, Any]]:
    tools = []
    for t in req.get("tools") or []:
        fn = t.get("function") if isinstance(t, dict) else None
        if isinstance(fn, dict) and fn.get("name"):
            tools.append({"name": str(fn["name"]), "description": str(fn.get("description") or fn["name"]),
                          "parameters": fn.get("parameters") or {"type": "object", "properties": {}}})
    return tools


def tools_signature(tools: list[dict[str, Any]]) -> str:
    return hashlib.sha256(json.dumps([(t["name"], t["parameters"]) for t in tools], sort_keys=True).encode()).hexdigest()[:16]


def flatten_history(history: list[dict[str, Any]]) -> str:
    """Seed text for a fresh process when a conversation has prior turns."""
    lines = []
    for m in history:
        if m["role"] == "assistant":
            calls = "".join(f"\n[called {c['name']}({c['arguments']})]" for c in m.get("tool_calls") or [])
            lines.append(f"ASSISTANT:\n{m['text']}{calls}")
        elif m["role"] == "tool":
            lines.append(f"TOOL RESULT ({m.get('tool_call_id')}):\n{m['text']}")
        else:
            lines.append(f"USER:\n{m['text']}")
    return "\n\n".join(lines)


# ── a warm Claude Code process ───────────────────────────────────────────────
class SessionError(RuntimeError):
    def __init__(self, message: str, code: int = 502) -> None:
        super().__init__(message)
        self.code = code


class Session:
    """One `claude -p --input-format stream-json` process + its MCP shim connection."""

    def __init__(self, cfg: "Config", model: str, effort: str, tools: list[dict[str, Any]], system_prompt: str) -> None:
        self.id = uuid.uuid4().hex[:12]
        self.cfg, self.model, self.effort, self.tools = cfg, model, effort, tools
        self.tools_sig = tools_signature(tools)
        self.history: list[dict[str, Any]] = []          # normalized messages this process has seen
        self.lock = threading.Lock()                     # one HTTP turn at a time per session
        self.last_used = time.time()
        self.busy = False
        self.pending: dict[str, dict[str, Any]] = {}     # our tool_call id → {"mcp_id", "name", "arguments"}
        self.announced: dict[str, str] = {}              # tool_call ids announced to the client, not yet matched to a shim call
        self.call_seq = 0
        self.events: "queue.Queue[dict[str, Any]]" = queue.Queue()
        self.dead = False
        self.tmp = tempfile.mkdtemp(prefix="claude-native-")
        self.sock_path = os.path.join(self.tmp, "shim.sock")
        self.shim_conn: Optional[socket.socket] = None
        self.shim_lock = threading.Lock()
        self._start(system_prompt)

    # ── process ──
    def _start(self, system_prompt: str) -> None:
        srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        srv.bind(self.sock_path)
        srv.listen(1)
        mcp_cfg = os.path.join(self.tmp, "mcp.json")
        with open(mcp_cfg, "w", encoding="utf-8") as fh:
            json.dump({"mcpServers": {HOST_SERVER: {"command": self.cfg.python, "args": [SHIM, self.sock_path, self.id]}}}, fh)
        cmd = [self.cfg.claude_bin, "-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
               "--include-partial-messages", "--model", self.model, "--effort", self.effort, "--no-session-persistence",
               "--mcp-config", mcp_cfg]
        if self.cfg.allow_all:
            cmd += ["--permission-mode", "bypassPermissions"]
        else:
            cmd += ["--permission-mode", "default", "--allowedTools", ",".join([f"mcp__{HOST_SERVER}"] + self.cfg.allowed_tools)]
        if self.cfg.disallowed_tools:
            cmd += ["--disallowedTools", ",".join(self.cfg.disallowed_tools)]
        if self.cfg.max_budget_usd:
            cmd += ["--max-budget-usd", str(self.cfg.max_budget_usd)]
        appended = "\n\n".join(p for p in (self.cfg.append_system_prompt, system_prompt) if p)
        if appended:
            cmd += ["--append-system-prompt", appended]
        env = {k: v for k, v in os.environ.items() if k not in _SCRUB_ENV and not k.startswith(_SCRUB_ENV_PREFIXES)}
        self.proc = subprocess.Popen(cmd, cwd=self.cfg.cwd, env=env, text=True, stdin=subprocess.PIPE,
                                     stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
        self.stderr_tail: list[str] = []
        threading.Thread(target=self._pump_stdout, daemon=True).start()
        threading.Thread(target=self._pump_stderr, daemon=True).start()
        threading.Thread(target=self._accept_shim, args=(srv,), daemon=True).start()

    def _pump_stdout(self) -> None:
        try:
            assert self.proc.stdout is not None
            for line in self.proc.stdout:
                line = line.strip()
                if not line.startswith("{"):
                    continue
                try:
                    self.events.put(json.loads(line))
                except json.JSONDecodeError:
                    continue
        finally:
            self.dead = True
            self.events.put({"type": "_exit", "code": self.proc.poll()})

    def _pump_stderr(self) -> None:
        try:
            assert self.proc.stderr is not None
            for line in self.proc.stderr:
                self.stderr_tail = (self.stderr_tail + [line.rstrip()])[-20:]
        except (OSError, ValueError):
            pass

    def _accept_shim(self, srv: socket.socket) -> None:
        try:
            srv.settimeout(60)
            conn, _ = srv.accept()
        except (OSError, socket.timeout):
            return
        finally:
            srv.close()
        self.shim_conn = conn
        rfile = conn.makefile("r", encoding="utf-8")
        hello = json.loads(rfile.readline() or "{}")
        if hello.get("op") == "hello":
            conn.sendall((json.dumps({"op": "tools", "tools": self.tools}) + "\n").encode("utf-8"))
        for raw in rfile:
            try:
                msg = json.loads(raw)
            except json.JSONDecodeError:
                continue
            if msg.get("op") == "call":
                self.events.put({"type": "_host_call", "mcp_id": str(msg.get("id")), "name": msg.get("name"),
                                 "arguments": msg.get("arguments") or {}})

    def send_user(self, text: str) -> None:
        assert self.proc.stdin is not None
        self.proc.stdin.write(json.dumps({"type": "user", "message": {"role": "user", "content": [{"type": "text", "text": text}]}}) + "\n")
        self.proc.stdin.flush()

    def deliver_result(self, call_id: str, content: str, is_error: bool = False) -> bool:
        info = self.pending.pop(call_id, None)
        if not info or not self.shim_conn:
            return False
        with self.shim_lock:
            self.shim_conn.sendall((json.dumps({"op": "result", "id": info["mcp_id"], "content": content, "is_error": is_error}) + "\n").encode("utf-8"))
        return True

    def kill(self) -> None:
        self.dead = True
        try:
            if self.proc.poll() is None:
                os.killpg(os.getpgid(self.proc.pid), signal.SIGTERM)
                try:
                    self.proc.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    os.killpg(os.getpgid(self.proc.pid), signal.SIGKILL)
        except (ProcessLookupError, PermissionError, OSError):
            pass
        shutil.rmtree(self.tmp, ignore_errors=True)

    # ── one turn: read events until the turn ends or Claude waits on host tools ──
    def run_turn(self, deadline: float) -> Iterator[dict[str, Any]]:
        """Yield {'text': str} | {'tool_call': {...}} | {'tool_args': {'id','delta'}} then a final
        {'done': 'stop'|'tool_calls', 'usage': {...}} — after Claude's assistant message is complete
        and every mcp__host call in it has reached the shim (so pi can run them all at once)."""
        blocks: dict[int, dict[str, Any]] = {}       # content_block index → {type, name, id, json}
        host_calls_announced: list[str] = []         # our tool_call ids emitted this turn
        host_calls_pending_arrival = 0
        message_done = False
        usage: dict[str, Any] = {}
        while True:
            remaining = deadline - time.time()
            if remaining <= 0:
                raise SessionError("claude turn timed out", 504)
            try:
                ev = self.events.get(timeout=min(remaining, 1.0))
            except queue.Empty:
                if message_done and host_calls_announced and host_calls_pending_arrival == 0:
                    yield {"done": "tool_calls", "usage": usage}
                    return
                continue
            t = ev.get("type")
            if t == "_exit":
                tail = "\n".join(self.stderr_tail[-5:])
                raise SessionError(f"claude exited (code {ev.get('code')}): {tail[-800:]}", 502)
            if t == "_host_call":
                call_id = self._match_call(ev)
                self.pending[call_id] = {"mcp_id": ev["mcp_id"], "name": ev["name"], "arguments": ev["arguments"]}
                if host_calls_pending_arrival > 0:
                    host_calls_pending_arrival -= 1
                if message_done and host_calls_pending_arrival == 0:
                    yield {"done": "tool_calls", "usage": usage}
                    return
                continue
            if t == "stream_event":
                e = ev.get("event") or {}
                et = e.get("type")
                if et == "content_block_start":
                    cb = e.get("content_block") or {}
                    idx = e.get("index", 0)
                    blocks[idx] = {"type": cb.get("type"), "name": cb.get("name"), "json": "", "id": None}
                    if cb.get("type") == "tool_use" and str(cb.get("name", "")).startswith(HOST_PREFIX):
                        self.call_seq += 1
                        call_id = f"call_{self.id}_{self.call_seq}"
                        blocks[idx]["id"] = call_id
                        self.announced[call_id] = cb["name"]
                        host_calls_announced.append(call_id)
                        host_calls_pending_arrival += 1
                        yield {"tool_call": {"id": call_id, "name": cb["name"][len(HOST_PREFIX):], "index": len(host_calls_announced) - 1}}
                elif et == "content_block_delta":
                    d = e.get("delta") or {}
                    idx = e.get("index", 0)
                    blk = blocks.get(idx) or {}
                    if d.get("type") == "text_delta" and blk.get("type") == "text":
                        yield {"text": d.get("text", "")}
                    elif d.get("type") == "input_json_delta" and blk.get("id"):
                        blk["json"] += d.get("partial_json", "")
                        yield {"tool_args": {"id": blk["id"], "delta": d.get("partial_json", ""), "index": host_calls_announced.index(blk["id"])}}
                elif et == "message_stop":
                    message_done = True
                    if host_calls_announced and host_calls_pending_arrival == 0:
                        yield {"done": "tool_calls", "usage": usage}
                        return
                continue
            if t == "assistant":
                # Non-partial fallback (if partial events are unavailable): emit text blocks once.
                if not any(b.get("type") for b in blocks.values()):
                    for c in (ev.get("message") or {}).get("content") or []:
                        if c.get("type") == "text" and c.get("text"):
                            yield {"text": c["text"]}
                continue
            if t == "result":
                u = ev.get("usage") or {}
                usage = {"prompt_tokens": int(u.get("input_tokens", 0)) + int(u.get("cache_read_input_tokens", 0)) + int(u.get("cache_creation_input_tokens", 0)),
                         "completion_tokens": int(u.get("output_tokens", 0)), "cost_usd": ev.get("total_cost_usd")}
                usage["total_tokens"] = usage["prompt_tokens"] + usage["completion_tokens"]
                if ev.get("is_error"):
                    raise SessionError(str(ev.get("result") or "claude error")[-800:], 502)
                yield {"done": "stop", "usage": usage}
                return

    def _match_call(self, ev: dict[str, Any]) -> str:
        """Pair a shim call with the tool_use block we announced (same tool name, oldest unmatched)."""
        want = HOST_PREFIX + str(ev.get("name") or "")
        for cid, name in list(self.announced.items()):
            if name == want:
                self.announced.pop(cid, None)
                return cid
        self.call_seq += 1   # call arrived without a matching announced block (partial events off?)
        return f"call_{self.id}_{self.call_seq}"


# ── config / registry ────────────────────────────────────────────────────────
class Config:
    def __init__(self, a: argparse.Namespace) -> None:
        self.claude_bin = a.claude_bin
        self.python = a.python
        self.cwd = a.cwd
        self.default_model = a.model
        self.models = [a.model] + [m for m in _split_csv(a.models) if m != a.model]
        self.effort = a.effort
        allowed = _split_csv(a.allowed_tools)
        self.allow_all = allowed == ["*"]
        self.allowed_tools = [] if self.allow_all else allowed
        self.disallowed_tools = _split_csv(a.disallowed_tools)
        self.max_budget_usd = a.max_budget_usd
        self.append_system_prompt = a.append_system_prompt
        self.timeout = a.timeout
        self.idle_seconds = a.session_idle
        self.max_sessions = a.max_sessions
        self.api_key = a.api_key


class Registry:
    def __init__(self, cfg: Config) -> None:
        self.cfg = cfg
        self.sessions: dict[str, Session] = {}
        self.lock = threading.Lock()
        self.metrics = {"requests": 0, "errors": 0, "sessions_started": 0, "turns_reused": 0, "started": time.time()}
        threading.Thread(target=self._reaper, daemon=True).start()

    def _reaper(self) -> None:
        while True:
            time.sleep(30)
            now = time.time()
            with self.lock:
                for sid, s in list(self.sessions.items()):
                    if s.dead or (not s.busy and now - s.last_used > self.cfg.idle_seconds):
                        s.kill()
                        self.sessions.pop(sid, None)

    def find_for_tool_results(self, results: list[dict[str, Any]]) -> Optional[Session]:
        ids = {r.get("tool_call_id") for r in results}
        with self.lock:
            for s in self.sessions.values():
                if not s.dead and ids & set(s.pending):
                    return s
        return None

    def find_for_continuation(self, norm: list[dict[str, Any]], model: str, sig: str) -> Optional[Session]:
        """A live idle session whose history is exactly the incoming messages minus the newest user turn."""
        if not norm or norm[-1]["role"] != "user":
            return None
        prefix = norm[:-1]
        with self.lock:
            for s in self.sessions.values():
                if s.dead or s.busy or s.model != model or s.tools_sig != sig or s.pending:
                    continue
                if len(s.history) == len(prefix) and all(_same(a, b) for a, b in zip(s.history, prefix)):
                    return s
        return None

    def start(self, model: str, effort: str, tools: list[dict[str, Any]], system_prompt: str) -> Session:
        with self.lock:
            if len(self.sessions) >= self.cfg.max_sessions:
                victim = min((s for s in self.sessions.values() if not s.busy), key=lambda s: s.last_used, default=None)
                if victim:
                    victim.kill()
                    self.sessions.pop(victim.id, None)
            s = Session(self.cfg, model, effort, tools, system_prompt)
            self.sessions[s.id] = s
            self.metrics["sessions_started"] += 1
            return s

    def drop(self, s: Session) -> None:
        s.kill()
        with self.lock:
            self.sessions.pop(s.id, None)


def _same(a: dict[str, Any], b: dict[str, Any]) -> bool:
    if a.get("role") != b.get("role"):
        return False
    if a.get("role") == "tool":
        return a.get("tool_call_id") == b.get("tool_call_id")
    if a.get("text", "").strip() != b.get("text", "").strip():
        return False
    ta = [c.get("id") for c in a.get("tool_calls") or []]
    tb = [c.get("id") for c in b.get("tool_calls") or []]
    return ta == tb


# ── HTTP ─────────────────────────────────────────────────────────────────────
class Handler(BaseHTTPRequestHandler):
    server_version = f"ClaudeNativeBridge/{BRIDGE_VERSION}"

    @property
    def reg(self) -> Registry:
        return self.server.registry  # type: ignore[attr-defined]

    def log_message(self, fmt: str, *args: Any) -> None:
        if "/health" not in (args[0] if args else ""):
            print(f"[claude-native] {self.address_string()} - {fmt % args}", flush=True)

    def _json(self, code: int, payload: dict[str, Any]) -> None:
        body = json.dumps(payload).encode()
        self.send_response(code)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(body)))
        self.end_headers()
        try:
            self.wfile.write(body)
        except BrokenPipeError:
            pass

    def _authorized(self) -> bool:
        expected = self.reg.cfg.api_key or ""
        if not expected:
            return True
        bearer = (self.headers.get("authorization") or "").removeprefix("Bearer ").strip()
        return hmac.compare_digest(bearer, expected) or hmac.compare_digest((self.headers.get("x-api-key") or "").strip(), expected)

    def do_GET(self) -> None:
        if not self._authorized():
            return self._json(401, {"error": {"message": "unauthorized"}})
        path = self.path.rstrip("/")
        cfg = self.reg.cfg
        if path == "/health":
            return self._json(200, {"status": "ok", "version": BRIDGE_VERSION, "native_tools": True, "model": cfg.default_model,
                                    "sessions": len(self.reg.sessions)})
        if path == "/metrics":
            m = dict(self.reg.metrics)
            m["uptime_s"] = int(time.time() - m.pop("started"))
            m["sessions_live"] = len(self.reg.sessions)
            return self._json(200, m)
        if path == "/config":
            return self._json(200, {"version": BRIDGE_VERSION, "claude_bin": cfg.claude_bin, "cwd": cfg.cwd, "model": cfg.default_model,
                                    "models": cfg.models, "effort": cfg.effort, "connectors": "all (bypassPermissions)" if cfg.allow_all else cfg.allowed_tools,
                                    "disallowed_tools": cfg.disallowed_tools, "session_idle_s": cfg.idle_seconds, "max_sessions": cfg.max_sessions,
                                    "timeout_s": cfg.timeout, "native_tools": True})
        if path == "/v1/models":
            return self._json(200, {"object": "list", "data": [_model_obj(m) for m in cfg.models]})
        if path.startswith("/v1/models/"):
            mid = path[len("/v1/models/"):]
            return self._json(200, _model_obj(mid)) if mid in cfg.models else self._json(404, {"error": {"message": "model not found"}})
        self._json(404, {"error": {"message": "not found"}})

    def do_POST(self) -> None:
        if not self._authorized():
            return self._json(401, {"error": {"message": "unauthorized"}})
        if self.path.rstrip("/") != "/v1/chat/completions":
            return self._json(404, {"error": {"message": "not found"}})
        try:
            req = json.loads(self.rfile.read(int(self.headers.get("content-length") or "0")).decode())
        except Exception as exc:  # noqa: BLE001
            return self._json(400, {"error": {"message": f"invalid json: {exc}"}})
        cfg = self.reg.cfg
        model = str(req.get("model") or cfg.default_model)
        if model not in cfg.models and not model.startswith("claude-"):
            return self._json(400, {"error": {"message": f"model {model!r} is not a Claude model id"}})
        effort = effort_from_request(req) or cfg.effort
        tools = tools_from_request(req)
        sig = tools_signature(tools)
        norm = normalize(req.get("messages") or [])
        if not norm:
            return self._json(400, {"error": {"message": "no messages"}})
        stream = req.get("stream") is True
        self.reg.metrics["requests"] += 1

        # 1) tool results for a session that is waiting on the host
        trailing_tools = []
        for m in reversed(norm):
            if m["role"] == "tool":
                trailing_tools.append(m)
            else:
                break
        trailing_tools.reverse()
        session: Optional[Session] = None
        mode = "new"
        if trailing_tools:
            session = self.reg.find_for_tool_results(trailing_tools)
            mode = "tool_results" if session else "new"
        else:
            session = self.reg.find_for_continuation(norm, model, sig)
            mode = "continue" if session else "new"
        if session is None:
            session = self.reg.start(model, effort, tools, system_text(req.get("messages") or []))
        if mode != "new":
            self.reg.metrics["turns_reused"] += 1

        with session.lock:
            session.busy = True
            session.last_used = time.time()
            try:
                if mode == "tool_results":
                    for r in trailing_tools:
                        if not session.deliver_result(str(r.get("tool_call_id")), r["text"]):
                            print(f"[claude-native] warning: unknown tool_call_id {r.get('tool_call_id')}", flush=True)
                        session.history.append(r)
                elif mode == "continue":
                    session.send_user(norm[-1]["text"])
                    session.history.append(norm[-1])
                else:
                    seed = flatten_history(norm[:-1])
                    latest = norm[-1]
                    if latest["role"] == "tool":   # results for a session we lost (e.g. restart): replay everything as text
                        text = f"<conversation-history>\n{flatten_history(norm)}\n</conversation-history>\n\nContinue from the last tool result above."
                    elif seed:
                        text = f"<conversation-history>\n{seed}\n</conversation-history>\n\nRespond only to this latest message:\n{latest['text']}"
                    else:
                        text = latest["text"]
                    session.send_user(text)
                    session.history = list(norm)
                print(f"[claude-native] session={session.id} mode={mode} model={model} effort={effort} tools={len(tools)}", flush=True)
                if stream:
                    self._stream(session, model)
                else:
                    self._blocking(session, model)
            except SessionError as exc:
                self.reg.metrics["errors"] += 1
                self.reg.drop(session)
                if not stream:
                    self._json(exc.code, {"error": {"message": str(exc)}})
                else:
                    try:
                        self.wfile.write(self._frame(model, {"content": f"\n[claude-native error: {exc}]"}, "stop"))
                        self.wfile.write(b"data: [DONE]\n\n")
                    except BrokenPipeError:
                        pass
            finally:
                session.busy = False
                session.last_used = time.time()

    # ── responses ──
    def _frame(self, model: str, delta: dict[str, Any], finish: Optional[str] = None, usage: Optional[dict[str, Any]] = None, cid: str = "") -> bytes:
        chunk: dict[str, Any] = {"id": cid or f"chatcmpl-{uuid.uuid4().hex}", "object": "chat.completion.chunk", "created": int(time.time()),
                                 "model": model, "choices": [{"index": 0, "delta": delta, "finish_reason": finish}]}
        if usage:
            chunk["usage"] = {k: usage[k] for k in ("prompt_tokens", "completion_tokens", "total_tokens") if k in usage}
        return f"data: {json.dumps(chunk)}\n\n".encode()

    def _record_assistant(self, session: Session, text: str, calls: dict[str, dict[str, Any]]) -> None:
        entry: dict[str, Any] = {"role": "assistant", "text": text.strip()}
        if calls:
            entry["tool_calls"] = [{"id": cid, "name": c["name"], "arguments": c["arguments"]} for cid, c in calls.items()]
        session.history.append(entry)

    def _stream(self, session: Session, model: str) -> None:
        cid = f"chatcmpl-{uuid.uuid4().hex}"
        self.send_response(200)
        self.send_header("content-type", "text/event-stream")
        self.send_header("cache-control", "no-cache")
        self.end_headers()
        self.wfile.write(self._frame(model, {"role": "assistant", "content": ""}, cid=cid))
        self.wfile.flush()
        text, calls, order = "", {}, []
        last_sent = time.time()
        deadline = time.time() + self.reg.cfg.timeout
        finish, usage = "stop", {}
        for ev in session.run_turn(deadline):
            if "text" in ev:
                text += ev["text"]
                self.wfile.write(self._frame(model, {"content": ev["text"]}, cid=cid))
            elif "tool_call" in ev:
                tc = ev["tool_call"]
                calls[tc["id"]] = {"name": tc["name"], "arguments": ""}
                order.append(tc["id"])
                self.wfile.write(self._frame(model, {"tool_calls": [{"index": tc["index"], "id": tc["id"], "type": "function",
                                                                       "function": {"name": tc["name"], "arguments": ""}}]}, cid=cid))
            elif "tool_args" in ev:
                ta = ev["tool_args"]
                calls[ta["id"]]["arguments"] += ta["delta"]
                self.wfile.write(self._frame(model, {"tool_calls": [{"index": ta["index"], "function": {"arguments": ta["delta"]}}]}, cid=cid))
            elif "done" in ev:
                finish = "tool_calls" if ev["done"] == "tool_calls" else "stop"
                usage = ev.get("usage") or {}
            self.wfile.flush()
            last_sent = time.time()
        # Make sure every announced call has complete JSON arguments (pi needs valid JSON).
        for call_id, c in calls.items():
            info = session.pending.get(call_id)
            if info and not c["arguments"].strip():
                c["arguments"] = json.dumps(info["arguments"])
                self.wfile.write(self._frame(model, {"tool_calls": [{"index": order.index(call_id), "function": {"arguments": c["arguments"]}}]}, cid=cid))
        self.wfile.write(self._frame(model, {}, finish, usage, cid=cid))
        self.wfile.write(b"data: [DONE]\n\n")
        self.wfile.flush()
        self._record_assistant(session, text, calls)

    def _blocking(self, session: Session, model: str) -> None:
        deadline = time.time() + self.reg.cfg.timeout
        text, calls, finish, usage = "", {}, "stop", {}
        for ev in session.run_turn(deadline):
            if "text" in ev:
                text += ev["text"]
            elif "tool_call" in ev:
                calls[ev["tool_call"]["id"]] = {"name": ev["tool_call"]["name"], "arguments": ""}
            elif "tool_args" in ev:
                calls[ev["tool_args"]["id"]]["arguments"] += ev["tool_args"]["delta"]
            elif "done" in ev:
                finish = "tool_calls" if ev["done"] == "tool_calls" else "stop"
                usage = ev.get("usage") or {}
        for call_id, c in calls.items():
            info = session.pending.get(call_id)
            if info and not c["arguments"].strip():
                c["arguments"] = json.dumps(info["arguments"])
        message: dict[str, Any] = {"role": "assistant", "content": text or None}
        if calls:
            message["tool_calls"] = [{"id": cid, "type": "function", "function": {"name": c["name"], "arguments": c["arguments"]}} for cid, c in calls.items()]
        self._record_assistant(session, text, calls)
        self._json(200, {"id": f"chatcmpl-{uuid.uuid4().hex}", "object": "chat.completion", "created": int(time.time()), "model": model,
                         "choices": [{"index": 0, "message": message, "finish_reason": finish}],
                         "usage": {k: usage.get(k, 0) for k in ("prompt_tokens", "completion_tokens", "total_tokens")}})


class Server(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True

    def __init__(self, addr, registry: Registry) -> None:
        super().__init__(addr, Handler)
        self.registry = registry


# ── entrypoint ───────────────────────────────────────────────────────────────
def build_parser() -> argparse.ArgumentParser:
    e = os.getenv
    p = argparse.ArgumentParser(description="OpenAI-compatible Claude Code bridge with native tool calling and warm sessions.")
    p.add_argument("--host", default=e("BRIDGE_HOST", "127.0.0.1"))
    p.add_argument("--port", type=int, default=int(e("BRIDGE_PORT", "18186")))
    p.add_argument("--claude-bin", default=e("CLAUDE_BIN", shutil.which("claude") or os.path.expanduser("~/.local/bin/claude")))
    p.add_argument("--python", default=e("PYTHON_BIN", shutil.which("python3") or "python3"), help="interpreter for mcp_shim.py")
    p.add_argument("--cwd", default=e("CLAUDE_CODE_BRIDGE_CWD", os.path.expanduser("~")))
    p.add_argument("--model", default=e("CLAUDE_CODE_BRIDGE_MODEL", DEFAULT_MODEL))
    p.add_argument("--models", default=e("CLAUDE_CODE_BRIDGE_MODELS", ",".join(DEFAULT_MODELS)))
    p.add_argument("--effort", default=e("CLAUDE_CODE_EFFORT", "medium"), choices=_EFFORTS)
    p.add_argument("--allowed-tools", default=e("CLAUDE_CODE_ALLOWED_TOOLS", ""), help="connector tools to allow (comma) or '*' for all via bypassPermissions")
    p.add_argument("--disallowed-tools", default=e("CLAUDE_CODE_DISALLOWED_TOOLS", DEFAULT_BUILTINS))
    p.add_argument("--max-budget-usd", default=e("CLAUDE_CODE_MAX_BUDGET_USD", ""))
    p.add_argument("--append-system-prompt", default=e("CLAUDE_CODE_APPEND_SYSTEM_PROMPT", ""))
    p.add_argument("--timeout", type=int, default=int(e("CLAUDE_CODE_BRIDGE_TIMEOUT", "600")))
    p.add_argument("--session-idle", type=int, default=int(e("CLAUDE_NATIVE_SESSION_IDLE", "1800")))
    p.add_argument("--max-sessions", type=int, default=int(e("CLAUDE_NATIVE_MAX_SESSIONS", "8")))
    p.add_argument("--api-key", default=e("CLAUDE_CODE_BRIDGE_API_KEY", ""))
    return p


def main(argv: Optional[list[str]] = None) -> None:
    args = build_parser().parse_args(argv)
    if not os.path.exists(args.claude_bin):
        raise SystemExit(f"claude binary not found: {args.claude_bin!r}")
    if not os.path.isfile(SHIM):
        raise SystemExit(f"mcp_shim.py missing next to this file: {SHIM}")
    cfg = Config(args)
    reg = Registry(cfg)
    server = Server((args.host, args.port), reg)

    def _shutdown(signum, _frame):
        print(f"[claude-native] signal {signum} — shutting down", flush=True)
        for s in list(reg.sessions.values()):
            s.kill()
        threading.Thread(target=server.shutdown, daemon=True).start()

    for name in ("SIGINT", "SIGTERM"):
        signal.signal(getattr(signal, name), _shutdown)
    print(f"[claude-native] v{BRIDGE_VERSION} listening on http://{args.host}:{args.port}/v1 model={cfg.default_model} "
          f"effort={cfg.effort} connectors={'all' if cfg.allow_all else len(cfg.allowed_tools)} native_tools=on "
          f"session_idle={cfg.idle_seconds}s max_sessions={cfg.max_sessions}", flush=True)
    try:
        server.serve_forever()
    finally:
        server.server_close()


def _selfcheck() -> None:
    n = normalize([{"role": "system", "content": "s"}, {"role": "user", "content": "hi"},
                   {"role": "assistant", "content": None, "tool_calls": [{"id": "c1", "type": "function", "function": {"name": "bash", "arguments": "{}"}}]},
                   {"role": "tool", "tool_call_id": "c1", "content": "ok"}])
    assert [m["role"] for m in n] == ["user", "assistant", "tool"] and n[1]["tool_calls"][0]["id"] == "c1" and n[2]["tool_call_id"] == "c1"
    assert system_text([{"role": "system", "content": "a"}, {"role": "user", "content": "b"}]) == "a"
    t = tools_from_request({"tools": [{"type": "function", "function": {"name": "bash", "description": "run", "parameters": {"type": "object"}}}]})
    assert t[0]["name"] == "bash" and tools_signature(t) == tools_signature(t) and tools_signature([]) != tools_signature(t)
    assert effort_from_request({"reasoning_effort": "minimal"}) == "low" and effort_from_request({}) is None
    assert _same({"role": "user", "text": "x"}, {"role": "user", "text": "x "}) and not _same({"role": "user", "text": "x"}, {"role": "user", "text": "y"})
    assert "USER:\nhi" in flatten_history(n) and "TOOL RESULT (c1)" in flatten_history(n)
    print("selfcheck ok")


if __name__ == "__main__":
    if os.getenv("BRIDGE_SELFCHECK"):
        _selfcheck()
    else:
        main()
