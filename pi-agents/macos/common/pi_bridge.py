#!/usr/bin/env python3
"""pi_bridge.py — OpenAI-compatible bridge from Hermes to the pi coding agent (shared by all backends).

Every chat completion becomes one headless ``pi -p --mode json`` run. pi is the agent:
it plans, calls its tools (bash, read, write, edit, grep, find, ls) and returns the answer.
The model behind pi is whatever pure-LLM upstream the backend folder starts (OpenCode free
models, Claude Code CLI, …), reached through the ``text-tools-provider`` extension, which
emulates function calling over text. ``--provider-id`` names that provider per backend.

    Hermes ──▶ pi_bridge.py :18484 ──▶ pi -p (tools + guardrails) ──▶ opencode bridge :18385 ──▶ mimo

Guardrails (Codex-style approvals) come from ``extensions/guardrails``. A chat UI has no
terminal prompt, so approvals are a chat handshake controlled by ``--approval``:
  * ``ask``   (default) safe read-only calls run; a risky call is NOT run — pi shows the user
              the exact command and asks them to reply ``approve``. When the newest user
              message is an approval (``approve``, ``yes``, ``go ahead``, ``ok``, ``run it``,
              ``confirm``), risky calls in THAT turn are allowed.
  * ``allow`` every call runs (POC); risky ones are still logged and shown in the reply.
  * ``deny``  risky calls are always refused (read-only agent).
Every decision is appended to the audit log (``~/.pi-bridge-audit.jsonl``).

Sibling of ``../opencode/hermes-desktop/opencode_bridge.py`` — same wire protocol, same
operability (streaming SSE, concurrency cap, timeouts, /health /config /metrics /v1/models).
Stdlib only.
"""

from __future__ import annotations

import argparse
import base64
import hmac
import json
import os
import re
import shutil
import signal
import subprocess
import tempfile
import threading
import time
import urllib.request
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any, Iterator, Optional

BRIDGE_VERSION = "1.0.0"
HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_UPSTREAM = "http://127.0.0.1:18385/v1"
DEFAULT_MODEL = "opencode/mimo-v2.5-free"
DEFAULT_TIMEOUT = 600
DEFAULT_MAX_CONCURRENCY = 2
DEFAULT_QUEUE_WAIT = 30
DEFAULT_MAX_PROMPT_CHARS = 400_000
DEFAULT_MAX_IMAGES = 4
DEFAULT_MAX_IMAGE_BYTES = 32 * 1024 * 1024
FALLBACK_MODELS = {  # used only until the upstream's /v1/models answers
    "claude": ["claude-opus-5", "claude-fable-5-1", "claude-fable-5", "claude-sonnet-5", "claude-haiku-4-5"],
    "opencode": ["opencode/mimo-v2.5-free", "opencode/big-pickle", "opencode/nemotron-3-ultra-free"],
}
_IS_WINDOWS = os.name == "nt"


# ── helpers ──────────────────────────────────────────────────────────────────
def _split_csv(value: str) -> list[str]:
    return [p.strip() for p in (value or "").split(",") if p.strip()]


def _text_of(content: Any) -> str:
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return "\n".join(i["text"] for i in content if isinstance(i, dict) and i.get("type") == "text" and isinstance(i.get("text"), str))
    return "" if content is None else str(content)


def split_messages(messages: list[dict[str, Any]]) -> tuple[str, str, str]:
    """Return (system_text, transcript_prompt, last_user_text).

    System turns go to ``--append-system-prompt``; user/assistant turns are flattened into the
    stdin prompt with role labels so multi-turn context survives one headless run.
    """
    system: list[str] = []
    convo: list[str] = []
    last_user = ""
    for m in messages or []:
        role = str(m.get("role") or "user").lower()
        text = _text_of(m.get("content")).strip()
        has_image = isinstance(m.get("content"), list) and any(isinstance(p, dict) and p.get("type") == "image_url" for p in m["content"])
        if role == "system":
            if text:
                system.append(text)
            continue
        if not text and has_image:
            text = "(see attached image)"
        if not text:
            continue
        if role == "user" and not text.startswith("[System:"):
            last_user = text  # Hermes injects "[System: … continue …]" user turns on stream retries; ignore those
        convo.append(f"{role.upper()}:\n{text}")
    if len(convo) == 1 and convo[0].startswith("USER:\n"):
        prompt = convo[0][len("USER:\n"):]  # single turn: hand pi the bare prompt
    elif convo and convo[-1].startswith("USER:\n"):
        # Multi-turn: frame earlier turns as context so the model answers ONLY the latest one
        # (otherwise it tends to re-answer the first message at the end of its reply).
        history = "\n\n".join(convo[:-1])
        latest = convo[-1][len("USER:\n"):]
        prompt = (f"<conversation-history>\n{history}\n</conversation-history>\n\n"
                  f"Respond only to this latest message (the history above is context, already answered):\n{latest}")
    else:
        prompt = "\n\n".join(convo)
    return "\n\n".join(system), prompt, last_user


_APPROVAL_START = re.compile(r"^(?:yes|y|ok|okay|sure|approved?|confirm(?:ed)?|go\s*ahead|do\s*it|run\s*it|proceed|allowed?)\b", re.IGNORECASE)
_APPROVAL_VETO = {"but", "not", "don't", "dont", "first", "after", "before", "if", "unless", "except", "no", "never", "instead", "only"}


_CWD_LINE = re.compile(r"^\s*Current working directory:\s*(.+?)\s*$", re.MULTILINE)


def cwd_from_system(system_text: str, fallback: str, enabled: bool) -> str:
    """Hermes writes ``Current working directory: <project>`` into its system prompt for the
    project selected in the sidebar. Honour it so pi's tools run where the user is looking."""
    if not enabled or not system_text:
        return fallback
    m = _CWD_LINE.search(system_text)
    if not m:
        return fallback
    candidate = os.path.expanduser(m.group(1).strip().strip("`'\""))
    return candidate if os.path.isabs(candidate) and os.path.isdir(candidate) else fallback


def is_approval(text: str) -> bool:
    """A short, unconditional consent in the newest user message ("approve", "yes, run it", "go ahead")."""
    t = (text or "").strip().lower()
    if not t or len(t) > 200 or "?" in t or not _APPROVAL_START.match(t):
        return False
    words = re.findall(r"[a-z']+", t)
    return len(words) <= 8 and not any(w in _APPROVAL_VETO for w in words)


# ── images ───────────────────────────────────────────────────────────────────
class ImageError(ValueError):
    pass


_EXT = {"image/png": ".png", "image/jpeg": ".jpg", "image/jpg": ".jpg", "image/webp": ".webp", "image/gif": ".gif"}


def stage_images(messages: list[dict[str, Any]], max_images: int, max_bytes: int) -> list[str]:
    urls: list[str] = []
    for m in messages or []:
        c = m.get("content")
        if isinstance(c, list):
            for p in c:
                if isinstance(p, dict) and p.get("type") == "image_url":
                    inner = p.get("image_url")
                    urls.append(inner.get("url", "") if isinstance(inner, dict) else str(inner or ""))
    if not urls:
        return []
    if max_images <= 0:
        raise ImageError("image support is disabled on this bridge (--max-images 0)")
    if len(urls) > max_images:
        raise ImageError(f"too many images: {len(urls)} > {max_images}")
    directory = tempfile.mkdtemp(prefix="pi-bridge-img-")
    paths: list[str] = []
    for i, url in enumerate(urls):
        if url.startswith("data:"):
            header, _, payload = url.partition(",")
            mime = header[5:].split(";", 1)[0].strip().lower()
            try:
                data = base64.b64decode(re.sub(r"\s+", "", payload), validate=True)
            except Exception as exc:
                shutil.rmtree(directory, ignore_errors=True)
                raise ImageError(f"image #{i + 1}: invalid base64 ({exc})") from exc
        elif url.startswith(("http://", "https://")):
            try:
                with urllib.request.urlopen(urllib.request.Request(url, headers={"User-Agent": "pi-bridge"}), timeout=30) as r:
                    mime = (r.headers.get("content-type") or "").split(";")[0].strip().lower()
                    data = r.read()
            except OSError as exc:
                shutil.rmtree(directory, ignore_errors=True)
                raise ImageError(f"image #{i + 1}: fetch failed ({exc})") from exc
        else:
            shutil.rmtree(directory, ignore_errors=True)
            raise ImageError(f"image #{i + 1}: unsupported image_url scheme")
        if len(data) > max_bytes:
            shutil.rmtree(directory, ignore_errors=True)
            raise ImageError(f"image #{i + 1} exceeds {max_bytes // (1024 * 1024)} MiB")
        ext = _EXT.get(mime) or (".png" if data.startswith(b"\x89PNG") else ".jpg" if data.startswith(b"\xff\xd8") else ".bin")
        path = os.path.join(directory, f"image-{i + 1}{ext}")
        with open(path, "wb") as fh:
            fh.write(data)
        paths.append(path)
    return paths


def cleanup_files(paths: list[str]) -> None:
    for p in paths:
        shutil.rmtree(os.path.dirname(p), ignore_errors=True)


# ── config ───────────────────────────────────────────────────────────────────
class BridgeConfig:
    def __init__(self, a: argparse.Namespace) -> None:
        self.pi_bin = a.pi_bin
        self.cwd = a.cwd
        self.cwd_from_prompt = a.cwd_from_prompt
        self.upstream = a.upstream.rstrip("/")
        self.upstream_key = a.upstream_key
        self.provider_id = a.provider_id
        self.default_model = a.model
        self.approval = a.approval
        self.extensions_dir = a.extensions_dir
        self.guardrails_config = a.guardrails_config
        self.audit_log = a.audit_log
        self.system_prompt_file = a.system_prompt
        self.thinking = a.thinking
        self.show_tools = a.show_tools
        self.show_output = max(0, int(a.show_output))
        self.show_reasoning = a.show_reasoning
        self.context_files = a.context_files
        self.tools = a.tools
        self.timeout = a.timeout
        self.keepalive_seconds = max(1, int(a.keepalive))
        self.max_prompt_chars = a.max_prompt_chars
        self.max_images = a.max_images
        self.max_image_bytes = a.max_image_bytes
        self.api_key = a.api_key
        self.pass_model = a.pass_model
        self._lock = threading.Lock()
        self.models: list[str] = _split_csv(a.models) or [self.default_model]
        self.models_source = "flag" if a.models else "pending"
        self.model_meta: dict[str, dict[str, Any]] = {}
        self._last_refresh = 0.0

    def refresh_models(self) -> None:
        if self.models_source == "flag":
            return
        try:
            req = urllib.request.Request(f"{self.upstream}/models", headers={"User-Agent": "pi-bridge"})
            if self.upstream_key:
                req.add_header("authorization", f"Bearer {self.upstream_key}")
            with urllib.request.urlopen(req, timeout=15) as r:
                data = json.load(r).get("data") or []
            ids = [d["id"] for d in data if isinstance(d, dict) and isinstance(d.get("id"), str)]
            meta = {d["id"]: d for d in data if isinstance(d, dict) and "id" in d}
            source = "upstream" if ids else "fallback"
        except Exception as exc:  # noqa: BLE001
            print(f"[pi-bridge] model discovery from {self.upstream}/models failed: {exc}", flush=True)
            ids, meta, source = [], {}, "fallback"
        if not ids:
            ids = list(FALLBACK_MODELS["claude" if "claude" in self.provider_id else "opencode"])
        ordered = [self.default_model] + [m for m in ids if m != self.default_model]
        with self._lock:
            self.models = ordered
            self.model_meta = meta
            self.models_source = source
            self._last_refresh = time.time()

    def resolve_model(self, requested: str) -> tuple[Optional[str], Optional[str]]:
        if not self.pass_model:
            return self.default_model, None
        wanted = (requested or "").strip()
        if not wanted:
            return self.default_model, None
        # Still on the seed list (upstream was down at start-up)? Re-discover, at most once a minute.
        if self.models_source != "upstream" and time.time() - getattr(self, "_last_refresh", 0) > 60:
            self.refresh_models()
        for m in self.models:
            if m == wanted or m.lower() == wanted.lower() or m.split("/", 1)[-1] == wanted:
                return m, None
        return None, f"model {wanted!r} is not available; this bridge serves: {', '.join(self.models)}. See GET /v1/models."


# ── the pi invocation ────────────────────────────────────────────────────────
class PiError(RuntimeError):
    def __init__(self, message: str, code: int = 502) -> None:
        super().__init__(message)
        self.code = code


_EFFORT_TO_THINKING = {"none": "off", "minimal": "minimal", "low": "low", "medium": "medium", "high": "high", "xhigh": "xhigh", "max": "max"}


def thinking_from_request(req: dict[str, Any], default: str) -> str:
    """Map OpenAI ``reasoning_effort`` (what Hermes' Min/Low/Med/High selector sends) to pi's --thinking level."""
    raw = req.get("reasoning_effort")
    if raw is None and isinstance(req.get("reasoning"), dict):
        raw = req["reasoning"].get("effort")
    return _EFFORT_TO_THINKING.get(str(raw or "").strip().lower(), default)


def build_command(cfg: BridgeConfig, model: str, system_file: Optional[str], image_files: list[str],
                  thinking: Optional[str] = None) -> list[str]:
    cmd = [cfg.pi_bin, "-p", "--mode", "json", "--no-session", "--no-extensions", "--no-skills",
           "--no-prompt-templates", "--no-themes", "--no-approve",
           "-e", os.path.join(cfg.extensions_dir, "text-tools-provider"),
           "-e", os.path.join(cfg.extensions_dir, "guardrails"),
           "--provider", cfg.provider_id, "--model", model]
    if not cfg.context_files:
        cmd.append("--no-context-files")
    if cfg.tools:
        cmd += ["--tools", cfg.tools]
    level = thinking if thinking is not None else cfg.thinking
    if level:
        cmd += ["--thinking", level]
    for f in _split_csv(cfg.system_prompt_file):  # one or more files, comma-separated
        cmd += ["--append-system-prompt", f]
    if system_file:
        cmd += ["--append-system-prompt", system_file]
    for p in image_files:
        cmd.append(f"@{p}")
    return cmd


def child_env(cfg: BridgeConfig, approve: bool) -> dict[str, str]:
    env = dict(os.environ)
    env["PI_UPSTREAM_BASE_URL"] = cfg.upstream
    env["PI_UPSTREAM_PROVIDER_ID"] = cfg.provider_id
    if cfg.upstream_key:
        env["PI_UPSTREAM_API_KEY"] = cfg.upstream_key
    env["PI_APPROVAL_NONINTERACTIVE"] = "allow" if approve else "deny"
    env["PI_APPROVAL_HANDSHAKE"] = "1" if cfg.approval == "ask" else "0"
    if cfg.guardrails_config:
        env["PI_GUARDRAILS_CONFIG"] = cfg.guardrails_config
    if cfg.audit_log:
        env["PI_GUARDRAILS_AUDIT"] = cfg.audit_log
    env.setdefault("PI_OFFLINE", "1")  # no update checks in a server loop
    return env


def _popen(cmd: list[str], cwd: str, env: dict[str, str]) -> subprocess.Popen:
    kwargs: dict[str, Any] = {"creationflags": subprocess.CREATE_NEW_PROCESS_GROUP} if _IS_WINDOWS else {"start_new_session": True}  # type: ignore[attr-defined]
    return subprocess.Popen(cmd, cwd=cwd, env=env, text=True, stdin=subprocess.PIPE,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, **kwargs)


def _kill(proc: subprocess.Popen) -> None:
    try:
        if _IS_WINDOWS or not hasattr(os, "killpg"):
            proc.terminate()
        else:
            os.killpg(os.getpgid(proc.pid), signal.SIGTERM)
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            if _IS_WINDOWS or not hasattr(os, "killpg"):
                proc.kill()
            else:
                os.killpg(os.getpgid(proc.pid), signal.SIGKILL)
    except (ProcessLookupError, PermissionError, OSError):
        pass


def _hint(args: Any, max_len: int = 160) -> str:
    args = args if isinstance(args, dict) else {}
    for key in ("command", "path", "pattern", "url"):
        v = args.get(key)
        if isinstance(v, str) and v.strip():
            v = v.strip().replace("\n", " ⏎ ")
            return v if len(v) <= max_len else v[:max_len - 1] + "…"
    return ""


def _approval_card(name: str, args: Any, reason_text: str) -> str:
    """What Hermes shows when pi held a risky call — the chat equivalent of Codex's prompt."""
    args = args if isinstance(args, dict) else {}
    m = re.search(r"NEEDS USER APPROVAL \((.*)\)\.?(?:\s|$)", reason_text, re.DOTALL)
    why = m.group(1) if m else "the policy flagged this call as risky"
    if name == "bash" and isinstance(args.get("command"), str):
        what = f"```bash\n{args['command'].strip()}\n```"
    else:
        shown = {k: (v[:200] + "…" if isinstance(v, str) and len(v) > 200 else v) for k, v in args.items()}
        what = f"```json\n{json.dumps({'tool': name, **shown}, indent=2, ensure_ascii=False)}\n```"
    return (" · ⏸ held\n\n"
            f"**⏸ Approval required** — {why}\n\n"
            f"{what}\n"
            "Reply **approve** to run it, or tell me what to do differently.\n")


def _tool_start(name: str, args: Any) -> str:
    """One blockquote line per tool call; the result status is appended when it finishes."""
    hint = _hint(args)
    return f"> 🔧 `{name}`" + (f" `{hint}`" if hint else "")


def _tool_end(is_error: bool, result_text: str, seconds: float, preview_lines: int = 0) -> str:
    """Status appended to the tool's blockquote line, plus an optional quoted output preview.
    Ends with ONE newline so consecutive tool lines stay in the same blockquote."""
    dur = f"{seconds:.1f}s"
    if is_error:
        # The failure text is normally the LAST line (error message / exit code), not the first.
        last = ([l for l in result_text.strip().splitlines() if l.strip()] or ["error"])[-1][:200]
        out = f" · ❌ {last} ({dur})\n"
    else:
        lines = result_text.count("\n") + (1 if result_text and not result_text.endswith("\n") else 0)
        size = f"{lines} line{'s' if lines != 1 else ''}" if lines else "no output"
        out = f" · ✅ {size} ({dur})\n"
    if preview_lines > 0 and result_text.strip():
        shown = result_text.rstrip("\n").splitlines()
        more = len(shown) - preview_lines
        body = "\n".join(f"> {l[:200]}" for l in shown[:preview_lines])
        if more > 0:
            body += f"\n> … {more} more line{'s' if more != 1 else ''}"
        out += f">\n> ```\n{body}\n> ```\n"
    return out


def _footer(model: str, tools: int, held: int, seconds: float) -> str:
    parts = [f"🥧 pi · {model}", f"{tools} tool call{'s' if tools != 1 else ''}"]
    if held:
        parts.append(f"{held} awaiting approval")
    parts.append(f"{seconds:.1f}s")
    return "_" + " · ".join(parts) + "_"


def run_events(cfg: BridgeConfig, model: str, prompt: str, system_text: str, approve: bool,
               image_files: list[str], thinking: Optional[str] = None) -> Iterator[dict[str, Any]]:
    """Run pi once; yield {'delta': str} chunks then {'done': True, 'usage': {...}, 'finish_reason': str}."""
    system_file: Optional[str] = None
    if system_text:
        fd, system_file = tempfile.mkstemp(prefix="pi-bridge-sys-", suffix=".md")
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write(system_text)
    cmd = build_command(cfg, model, system_file, image_files, thinking)
    run_cwd = cwd_from_system(system_text, cfg.cwd, cfg.cwd_from_prompt)
    if run_cwd != cfg.cwd:
        print(f"[pi-bridge] cwd from Hermes project: {run_cwd}", flush=True)
    proc = _popen(cmd, run_cwd, child_env(cfg, approve))
    deadline = time.time() + cfg.timeout
    usage = {"input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0}
    finish = "stop"
    error: Optional[PiError] = None
    stderr_lines: list[str] = []
    streamed_for_msg = 0
    pending_tools: dict[str, tuple[str, Any, float]] = {}
    approval_requested = False
    tool_calls = 0
    after_tool = False
    run_started = time.time()
    tail = ""  # last chars emitted — lets separators be exact regardless of how the model ended its text

    def out(text: str) -> dict[str, Any]:
        nonlocal tail
        tail = (tail + text)[-2:]
        return {"delta": text}

    def sep(blank_line: bool) -> str:
        """Newlines needed so the next chunk starts on a fresh line (blank_line: after an empty line)."""
        if not tail:
            return ""
        if blank_line:
            return "" if tail.endswith("\n\n") else ("\n" if tail.endswith("\n") else "\n\n")
        return "" if tail.endswith("\n") else "\n"

    def _writer() -> None:
        try:
            assert proc.stdin is not None
            proc.stdin.write(prompt)
            proc.stdin.close()
        except (BrokenPipeError, OSError, ValueError):
            pass

    def _drain() -> None:
        try:
            assert proc.stderr is not None
            for raw in iter(proc.stderr.readline, ""):
                stderr_lines.append(raw)
                if raw.startswith("[guardrails]") or raw.startswith("[text-tools-provider]"):
                    print(f"[pi-bridge] {raw.rstrip()}", flush=True)
        except (OSError, ValueError):
            pass

    def _watchdog() -> None:
        while time.time() < deadline and proc.poll() is None:
            time.sleep(0.5)
        if proc.poll() is None:
            _kill(proc)

    for target in (_writer, _drain, _watchdog):
        threading.Thread(target=target, daemon=True).start()
    try:
        assert proc.stdout is not None
        for line in proc.stdout:
            if time.time() > deadline:
                raise PiError("pi run timed out", 504)
            line = line.strip()
            if not line.startswith("{"):
                continue
            try:
                ev = json.loads(line)
            except json.JSONDecodeError:
                continue
            t = ev.get("type")
            if t == "message_start" and (ev.get("message") or {}).get("role") == "assistant":
                streamed_for_msg = 0
            elif t == "message_update":
                ame = ev.get("assistantMessageEvent") or {}
                if ame.get("type") == "text_delta" and ame.get("delta"):
                    if after_tool:  # blank line: leave the tool blockquote before model text
                        after_tool = False
                        yield out(sep(True))
                    streamed_for_msg += len(ame["delta"])
                    yield out(ame["delta"])
                elif ame.get("type") == "thinking_delta" and cfg.show_reasoning and ame.get("delta"):
                    yield out(f"_{ame['delta']}_")
            elif t == "message_end":
                msg = ev.get("message") or {}
                if msg.get("role") != "assistant":
                    continue
                text = "".join(c.get("text", "") for c in msg.get("content") or [] if c.get("type") == "text")
                if len(text) > streamed_for_msg and not approval_requested:  # provider did not stream: emit the remainder
                    if after_tool:
                        after_tool = False
                        yield out(sep(True))
                    yield out(text[streamed_for_msg:])
                u = msg.get("usage") or {}
                for k in usage:
                    usage[k] += int(u.get(k) or 0)
                if msg.get("stopReason") == "error":
                    error = PiError(str(msg.get("errorMessage") or "pi error")[-2000:], 502)
                elif msg.get("stopReason") == "length":
                    finish = "length"
            elif t == "tool_execution_start":
                tool_calls += 1
                pending_tools[str(ev.get("toolCallId"))] = (str(ev.get("toolName")), ev.get("args"), time.time())
                if cfg.show_tools:
                    # consecutive tool lines share one blockquote; after model text start a new one
                    yield out(sep(not after_tool) + _tool_start(str(ev.get("toolName")), ev.get("args")))
            elif t == "tool_execution_end":
                res = ev.get("result") or {}
                txt = "".join(c.get("text", "") for c in (res.get("content") or []) if isinstance(c, dict))
                name, args, t0 = pending_tools.pop(str(ev.get("toolCallId")), (str(ev.get("toolName")), ev.get("args"), time.time()))
                if ev.get("isError") and "NEEDS USER APPROVAL" in txt:
                    approval_requested = True
                    card = _approval_card(name, args, txt)
                    yield out(card if cfg.show_tools else sep(True) + card.split("\n", 2)[-1])
                elif cfg.show_tools:
                    after_tool = True
                    yield out(_tool_end(bool(ev.get("isError")), txt, time.time() - t0, cfg.show_output))
        try:
            rc = proc.wait(timeout=10)
        except subprocess.TimeoutExpired:
            _kill(proc)
            rc = proc.wait(timeout=10)
        if error is not None:
            raise error
        if rc != 0:
            if time.time() > deadline:
                raise PiError("pi run timed out", 504)
            err = "".join(l for l in stderr_lines if not l.startswith("[")).strip()
            raise PiError((err or f"pi exited with code {rc}")[-2000:], 502)
    finally:
        if proc.poll() is None:
            _kill(proc)
        if system_file:
            try:
                os.unlink(system_file)
            except OSError:
                pass
        cleanup_files(image_files)
    if cfg.show_tools and tool_calls:
        yield out(sep(True) + _footer(model, tool_calls, 1 if approval_requested else 0, time.time() - run_started))
    yield {"done": True, "usage": usage, "finish_reason": finish}


def _usage_block(u: dict[str, int]) -> dict[str, int]:
    inp = u["input"] + u["cacheRead"] + u["cacheWrite"]
    return {"prompt_tokens": inp, "completion_tokens": u["output"], "total_tokens": inp + u["output"]}


# ── metrics ──────────────────────────────────────────────────────────────────
class Metrics:
    def __init__(self) -> None:
        self._lock = threading.Lock()
        self.requests = self.errors = self.rejected_busy = self.approved_turns = 0
        self.started = time.time()

    def record(self, *, error: bool = False, approved: bool = False) -> None:
        with self._lock:
            self.requests += 1
            self.errors += int(error)
            self.approved_turns += int(approved)

    def snapshot(self, in_flight: int) -> dict[str, Any]:
        with self._lock:
            return {"uptime_s": int(time.time() - self.started), "requests": self.requests, "errors": self.errors,
                    "rejected_busy": self.rejected_busy, "approved_turns": self.approved_turns, "in_flight": in_flight}


# ── HTTP ─────────────────────────────────────────────────────────────────────
class Handler(BaseHTTPRequestHandler):
    server_version = f"PiBridge/{BRIDGE_VERSION}"

    @property
    def cfg(self) -> BridgeConfig:
        return self.server.cfg  # type: ignore[attr-defined]

    def log_message(self, fmt: str, *args: Any) -> None:
        print(f"[pi-bridge] {self.address_string()} - {fmt % args}", flush=True)

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
        expected = self.cfg.api_key or ""
        if not expected:
            return True
        bearer = (self.headers.get("authorization") or "").removeprefix("Bearer ").strip()
        return hmac.compare_digest(bearer, expected) or hmac.compare_digest((self.headers.get("x-api-key") or "").strip(), expected)

    def _model_obj(self, mid: str) -> dict[str, Any]:
        meta = self.cfg.model_meta.get(mid) or {}
        obj = {"id": mid, "object": "model", "created": 0, "owned_by": "pi-agent"}
        for k in ("context_length", "display_name", "free"):
            if meta.get(k) is not None:
                obj[k] = meta[k]
        return obj

    def do_GET(self) -> None:
        if not self._authorized():
            return self._json(401, {"error": {"message": "unauthorized"}})
        path = self.path.rstrip("/")
        srv = self.server  # type: ignore[assignment]
        if path == "/health":
            return self._json(200, {"status": "ok", "version": BRIDGE_VERSION, "pi_version": srv.pi_version,  # type: ignore[attr-defined]
                                    "upstream": self.cfg.upstream, "model": self.cfg.default_model,
                                    "approval": self.cfg.approval, "in_flight": srv.in_flight()})  # type: ignore[attr-defined]
        if path == "/metrics":
            return self._json(200, srv.metrics.snapshot(srv.in_flight()))  # type: ignore[attr-defined]
        if path == "/config":
            return self._json(200, {"version": BRIDGE_VERSION, "pi_bin": self.cfg.pi_bin, "cwd": self.cfg.cwd, "cwd_from_prompt": self.cfg.cwd_from_prompt,
                                    "upstream": self.cfg.upstream, "provider_id": self.cfg.provider_id, "model": self.cfg.default_model, "models": self.cfg.models,
                                    "models_source": self.cfg.models_source, "approval": self.cfg.approval,
                                    "extensions_dir": self.cfg.extensions_dir, "guardrails_config": self.cfg.guardrails_config,
                                    "audit_log": self.cfg.audit_log, "system_prompt": self.cfg.system_prompt_file,
                                    "tools": self.cfg.tools or "(all pi built-ins)", "context_files": self.cfg.context_files,
                                    "show_tools": self.cfg.show_tools, "show_output": self.cfg.show_output, "show_reasoning": self.cfg.show_reasoning,
                                    "timeout_s": self.cfg.timeout, "max_concurrency": srv.max_concurrency,  # type: ignore[attr-defined]
                                    "api_key_required": bool(self.cfg.api_key)})
        if path == "/v1/models":
            return self._json(200, {"object": "list", "data": [self._model_obj(m) for m in self.cfg.models]})
        if path.startswith("/v1/models/"):
            mid = path[len("/v1/models/"):]
            return self._json(200, self._model_obj(mid)) if mid in self.cfg.models else self._json(404, {"error": {"message": "model not found"}})
        self._json(404, {"error": {"message": "not found"}})

    def do_POST(self) -> None:
        if not self._authorized():
            return self._json(401, {"error": {"message": "unauthorized"}})
        if self.path.rstrip("/") == "/v1/models/refresh":
            self.cfg.refresh_models()
            return self._json(200, {"status": "ok", "models": self.cfg.models, "source": self.cfg.models_source})
        if self.path.rstrip("/") != "/v1/chat/completions":
            return self._json(404, {"error": {"message": "not found"}})
        try:
            req = json.loads(self.rfile.read(int(self.headers.get("content-length") or "0")).decode())
        except Exception as exc:  # noqa: BLE001
            return self._json(400, {"error": {"message": f"invalid json: {exc}"}})
        model, err = self.cfg.resolve_model(str(req.get("model") or ""))
        if err or not model:
            return self._json(400, {"error": {"message": err or "no model"}})
        messages = req.get("messages") or []
        system_text, prompt, last_user = split_messages(messages)
        if not prompt:
            return self._json(400, {"error": {"message": "request has no prompt text"}})
        if len(prompt) + len(system_text) > self.cfg.max_prompt_chars:
            return self._json(413, {"error": {"message": f"prompt too large (> {self.cfg.max_prompt_chars} chars)"}})
        try:
            images = stage_images(messages, self.cfg.max_images, self.cfg.max_image_bytes)
        except ImageError as exc:
            return self._json(400, {"error": {"message": str(exc)}})
        approve = self.cfg.approval == "allow" or (self.cfg.approval == "ask" and is_approval(last_user))
        thinking = thinking_from_request(req, self.cfg.thinking)
        srv = self.server
        if not srv.slot.acquire(timeout=srv.queue_wait):  # type: ignore[attr-defined]
            srv.metrics.rejected_busy += 1  # type: ignore[attr-defined]
            cleanup_files(images)
            return self._json(429, {"error": {"message": "bridge busy: too many concurrent pi runs"}})
        try:
            if req.get("stream") is True:
                self._stream(model, prompt, system_text, approve, images, thinking)
            else:
                self._blocking(model, prompt, system_text, approve, images, thinking)
        finally:
            srv.slot.release()  # type: ignore[attr-defined]

    def _blocking(self, model: str, prompt: str, system_text: str, approve: bool, images: list[str], thinking: Optional[str] = None) -> None:
        started = time.time()
        chunks: list[str] = []
        usage = {"input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0}
        finish = "stop"
        try:
            for ev in run_events(self.cfg, model, prompt, system_text, approve, images, thinking):
                if "delta" in ev:
                    chunks.append(ev["delta"])
                elif ev.get("done"):
                    usage, finish = ev["usage"], ev["finish_reason"]
        except PiError as exc:
            self.server.metrics.record(error=True)  # type: ignore[attr-defined]
            return self._json(exc.code, {"error": {"message": str(exc)}})
        self.server.metrics.record(approved=approve)  # type: ignore[attr-defined]
        print(f"[pi-bridge] model={model} approve={approve} thinking={thinking or '-'} chars={len(prompt)} latency_ms={int((time.time() - started) * 1000)}", flush=True)
        self._json(200, {"id": f"chatcmpl-{uuid.uuid4().hex}", "object": "chat.completion", "created": int(time.time()), "model": model,
                         "choices": [{"index": 0, "message": {"role": "assistant", "content": "".join(chunks).strip()}, "finish_reason": finish}],
                         "usage": _usage_block(usage)})

    def _stream(self, model: str, prompt: str, system_text: str, approve: bool, images: list[str], thinking: Optional[str] = None) -> None:
        cid, created, started = f"chatcmpl-{uuid.uuid4().hex}", int(time.time()), time.time()

        def frame(delta: dict[str, Any], finish: Optional[str] = None) -> bytes:
            return f"data: {json.dumps({'id': cid, 'object': 'chat.completion.chunk', 'created': created, 'model': model, 'choices': [{'index': 0, 'delta': delta, 'finish_reason': finish}]})}\n\n".encode()

        self.send_response(200)
        self.send_header("content-type", "text/event-stream")
        self.send_header("cache-control", "no-cache")
        self.end_headers()
        # pi runs in a worker; the handler thread forwards its events and emits an empty-delta
        # keepalive chunk whenever nothing has been sent for a while (a long tool run would
        # otherwise look like a dead stream to Hermes, which then retries with a "[System: …]" turn).
        import queue as _queue
        q: "_queue.Queue[Any]" = _queue.Queue()

        def _pump() -> None:
            try:
                for ev in run_events(self.cfg, model, prompt, system_text, approve, images, thinking):
                    q.put(ev)
            except PiError as exc:
                q.put(exc)
            except Exception as exc:  # noqa: BLE001
                q.put(PiError(str(exc), 502))
            finally:
                q.put(None)

        threading.Thread(target=_pump, daemon=True).start()
        try:
            self.wfile.write(frame({"role": "assistant"}))
            self.wfile.flush()
            finish = "stop"
            while True:
                try:
                    ev = q.get(timeout=self.cfg.keepalive_seconds)
                except _queue.Empty:
                    self.wfile.write(frame({}))  # keepalive
                    self.wfile.flush()
                    continue
                if ev is None:
                    break
                if isinstance(ev, PiError):
                    raise ev
                if "delta" in ev:
                    self.wfile.write(frame({"content": ev["delta"]}))
                    self.wfile.flush()
                elif ev.get("done"):
                    finish = ev["finish_reason"]
            self.wfile.write(frame({}, finish=finish))
            self.wfile.write(b"data: [DONE]\n\n")
            self.server.metrics.record(approved=approve)  # type: ignore[attr-defined]
            print(f"[pi-bridge] stream model={model} approve={approve} chars={len(prompt)} latency_ms={int((time.time() - started) * 1000)}", flush=True)
        except PiError as exc:
            self.server.metrics.record(error=True)  # type: ignore[attr-defined]
            try:
                self.wfile.write(frame({"content": f"\n[pi-bridge error: {exc}]"}, finish="stop"))
                self.wfile.write(b"data: [DONE]\n\n")
            except BrokenPipeError:
                pass
        except BrokenPipeError:
            pass


class Server(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True

    def __init__(self, addr, cfg: BridgeConfig, max_concurrency: int, queue_wait: int, pi_version: str) -> None:
        super().__init__(addr, Handler)
        self.cfg, self.metrics, self.max_concurrency, self.queue_wait, self.pi_version = cfg, Metrics(), max_concurrency, queue_wait, pi_version
        self.slot = threading.BoundedSemaphore(max_concurrency)

    def in_flight(self) -> int:
        return max(0, self.max_concurrency - self.slot._value)  # type: ignore[attr-defined]


# ── entrypoint ───────────────────────────────────────────────────────────────
def build_parser() -> argparse.ArgumentParser:
    e = os.getenv
    p = argparse.ArgumentParser(description="OpenAI-compatible bridge: Hermes → pi coding agent (tools + Codex-style approvals) → OpenCode free models.")
    p.add_argument("--host", default=e("BRIDGE_HOST", "127.0.0.1"))
    p.add_argument("--port", type=int, default=int(e("BRIDGE_PORT", "18484")))
    p.add_argument("--pi-bin", default=e("PI_BIN", shutil.which("pi") or os.path.expanduser("~/.local/bin/pi")))
    p.add_argument("--cwd", default=e("PI_BRIDGE_CWD", os.path.expanduser("~")), help="default directory pi's tools operate in")
    p.add_argument("--cwd-from-prompt", dest="cwd_from_prompt", action="store_true", default=e("PI_BRIDGE_CWD_FROM_PROMPT", "1") not in ("0", "false", ""),
                   help="follow the 'Current working directory: <path>' line Hermes puts in its system prompt (the selected project)")
    p.add_argument("--no-cwd-from-prompt", dest="cwd_from_prompt", action="store_false")
    p.add_argument("--upstream", default=e("PI_UPSTREAM_BASE_URL", DEFAULT_UPSTREAM), help="pure-LLM OpenCode bridge base URL")
    p.add_argument("--upstream-key", default=e("PI_UPSTREAM_API_KEY", ""))
    p.add_argument("--provider-id", default=e("PI_BRIDGE_PROVIDER_ID", "opencode-bridge"),
                   help="pi provider id registered by the text-tools-provider extension (one per backend)")
    p.add_argument("--model", default=e("PI_BRIDGE_MODEL", DEFAULT_MODEL))
    p.add_argument("--models", default=e("PI_BRIDGE_MODELS", ""), help="comma-separated ids to advertise; empty = discover from upstream")
    p.add_argument("--approval", choices=["ask", "allow", "deny"], default=e("PI_BRIDGE_APPROVAL", "ask"))
    p.add_argument("--extensions-dir", default=e("PI_BRIDGE_EXTENSIONS", os.path.join(HERE, "extensions")))
    p.add_argument("--guardrails-config", default=e("PI_GUARDRAILS_CONFIG", os.path.join(HERE, "guardrails.json")))
    p.add_argument("--audit-log", default=e("PI_GUARDRAILS_AUDIT", os.path.expanduser("~/.pi-bridge-audit.jsonl")))
    p.add_argument("--system-prompt", default=e("PI_BRIDGE_SYSTEM_PROMPT", os.path.join(HERE, "prompts", "sre.md")),
                   help="file(s) appended to pi's system prompt, comma-separated ('' to disable)")
    p.add_argument("--tools", default=e("PI_BRIDGE_TOOLS", ""), help="comma-separated pi tool allowlist; empty = all built-ins")
    p.add_argument("--thinking", default=e("PI_BRIDGE_THINKING", ""))
    p.add_argument("--context-files", dest="context_files", action="store_true", default=e("PI_BRIDGE_CONTEXT_FILES", "1") not in ("0", "false", ""))
    p.add_argument("--no-context-files", dest="context_files", action="store_false", help="ignore AGENTS.md / CLAUDE.md in cwd")
    p.add_argument("--show-tools", dest="show_tools", action="store_true", default=e("PI_BRIDGE_SHOW_TOOLS", "1") not in ("0", "false", ""))
    p.add_argument("--no-show-tools", dest="show_tools", action="store_false")
    p.add_argument("--show-output", type=int, default=int(e("PI_BRIDGE_SHOW_OUTPUT", "0")),
                   help="quote up to N lines of each tool's output under its activity line (0 = off)")
    p.add_argument("--show-reasoning", dest="show_reasoning", action="store_true", default=e("PI_BRIDGE_SHOW_REASONING", "") not in ("", "0", "false"))
    p.add_argument("--timeout", type=int, default=int(e("PI_BRIDGE_TIMEOUT", str(DEFAULT_TIMEOUT))))
    p.add_argument("--keepalive", type=int, default=int(e("PI_BRIDGE_KEEPALIVE", "10")),
                   help="seconds of silence before an empty SSE chunk is sent while a tool runs (streaming only)")
    p.add_argument("--max-concurrency", type=int, default=int(e("PI_BRIDGE_MAX_CONCURRENCY", str(DEFAULT_MAX_CONCURRENCY))))
    p.add_argument("--queue-wait", type=int, default=int(e("PI_BRIDGE_QUEUE_WAIT", str(DEFAULT_QUEUE_WAIT))))
    p.add_argument("--max-prompt-chars", type=int, default=int(e("PI_BRIDGE_MAX_PROMPT_CHARS", str(DEFAULT_MAX_PROMPT_CHARS))))
    p.add_argument("--max-images", type=int, default=int(e("PI_BRIDGE_MAX_IMAGES", str(DEFAULT_MAX_IMAGES))))
    p.add_argument("--max-image-bytes", type=int, default=int(e("PI_BRIDGE_MAX_IMAGE_BYTES", str(DEFAULT_MAX_IMAGE_BYTES))))
    p.add_argument("--api-key", default=e("PI_BRIDGE_API_KEY", ""))
    p.add_argument("--pass-model", dest="pass_model", action="store_true", default=True)
    p.add_argument("--no-pass-model", dest="pass_model", action="store_false")
    return p


def _pi_version(pi_bin: str) -> str:
    try:
        out = subprocess.run([pi_bin, "--version"], capture_output=True, text=True, timeout=20)
        return (out.stdout or out.stderr).strip().splitlines()[0]
    except Exception:  # noqa: BLE001
        return "unknown"


def main(argv: Optional[list[str]] = None) -> None:
    args = build_parser().parse_args(argv)
    if not args.pi_bin or not os.path.exists(args.pi_bin):
        raise SystemExit(f"pi binary not found ({args.pi_bin!r}); npm install -g @earendil-works/pi-coding-agent or set PI_BIN")
    if not os.path.isdir(args.cwd):
        raise SystemExit(f"working directory not found: {args.cwd}")
    for sub in ("text-tools-provider", "guardrails"):
        if not os.path.isdir(os.path.join(args.extensions_dir, sub)):
            raise SystemExit(f"extension missing: {os.path.join(args.extensions_dir, sub)}")
    for f in _split_csv(args.system_prompt):
        if not os.path.isfile(f):
            raise SystemExit(f"system prompt file not found: {f}")
    cfg = BridgeConfig(args)
    cfg.refresh_models()
    server = Server((args.host, args.port), cfg, max(1, args.max_concurrency), args.queue_wait, _pi_version(args.pi_bin))

    def _shutdown(signum, _frame):
        print(f"[pi-bridge] signal {signum} — shutting down", flush=True)
        threading.Thread(target=server.shutdown, daemon=True).start()

    for name in ("SIGINT", "SIGTERM", "SIGBREAK"):
        sig = getattr(signal, name, None)
        if sig is not None:
            try:
                signal.signal(sig, _shutdown)
            except (ValueError, OSError, RuntimeError):
                pass
    print(f"[pi-bridge] v{BRIDGE_VERSION} listening on http://{args.host}:{args.port}/v1 pi={server.pi_version} "
          f"upstream={cfg.upstream} model={cfg.default_model} models={len(cfg.models)} ({cfg.models_source}) "
          f"approval={cfg.approval} cwd={cfg.cwd} audit={cfg.audit_log}", flush=True)
    host = "127.0.0.1" if args.host in ("0.0.0.0", "::") else args.host
    print("\n┌─ Connect Hermes ─────────────────────────────────────────────┐\n"
          "│ Settings → Providers → Custom Endpoints → New endpoint       │\n"
          f"│   Endpoint URL: {f'http://{host}:{args.port}/v1':<45}│\n"
          f"│   Default Model: {cfg.default_model:<44}│\n"
          f"│   Approval mode: {cfg.approval:<44}│\n"
          "└──────────────────────────────────────────────────────────────┘", flush=True)
    try:
        server.serve_forever()
    finally:
        server.server_close()


def _selfcheck() -> None:
    sys_text, prompt, last = split_messages([
        {"role": "system", "content": "be terse"},
        {"role": "user", "content": "hi"},
        {"role": "assistant", "content": "hello"},
        {"role": "user", "content": [{"type": "text", "text": "approve"}]},
    ])
    assert sys_text == "be terse" and last == "approve" and "USER:\nhi\n\nASSISTANT:\nhello" in prompt and prompt.rstrip().endswith("approve"), (sys_text, prompt, last)
    assert split_messages([{"role": "user", "content": "just this"}])[1] == "just this"
    assert split_messages([{"role": "user", "content": "approve"}, {"role": "user", "content": "[System: The previous response was cut off. Continue.]"}])[2] == "approve"
    for ok in ("approve", "Approved", "yes", "yes, run it", "go ahead", "OK!", "run it", "approve the mkdir please"):
        assert is_approval(ok), ok
    for no in ("yes but first list the files", "no", "approve? what does that mean", "list pwd", ""):
        assert not is_approval(no), no
    cfg = BridgeConfig(build_parser().parse_args(["--models", "opencode/a,opencode/b", "--model", "opencode/a", "--system-prompt", ""]))
    assert cfg.resolve_model("b")[0] == "opencode/a" or cfg.resolve_model("b")[0] == "opencode/b"
    assert cfg.resolve_model("opencode/b")[0] == "opencode/b" and cfg.resolve_model("")[0] == "opencode/a"
    assert cfg.resolve_model("nope")[0] is None
    cmd = build_command(cfg, "opencode/a", None, ["/tmp/x.png"])
    two = build_command(BridgeConfig(build_parser().parse_args(["--system-prompt", "/a.md,/b.md"])), "m", None, [])
    assert two.count("--append-system-prompt") == 2 and "/b.md" in two, two
    for part in ("-p", "--mode", "json", "--no-session", "--no-extensions", "--provider", "opencode-bridge", "@/tmp/x.png"):
        assert part in cmd, (part, cmd)
    cmd = build_command(BridgeConfig(build_parser().parse_args(["--provider-id", "claude-code-bridge", "--system-prompt", ""])), "claude-opus-5", None, [])
    for part in ("--provider", "claude-code-bridge", "text-tools-provider"):
        assert any(part in c for c in cmd), (part, cmd)
    for part in ():
        assert part in cmd, (part, cmd)
    env = child_env(cfg, approve=False)
    assert env["PI_APPROVAL_NONINTERACTIVE"] == "deny" and env["PI_APPROVAL_HANDSHAKE"] == "1"
    assert child_env(cfg, approve=True)["PI_APPROVAL_NONINTERACTIVE"] == "allow"
    assert thinking_from_request({"reasoning_effort": "low"}, "") == "low"
    assert thinking_from_request({"reasoning_effort": "none"}, "") == "off"
    assert thinking_from_request({"reasoning": {"effort": "high"}}, "") == "high"
    assert thinking_from_request({}, "medium") == "medium" and thinking_from_request({"reasoning_effort": "bogus"}, "") == ""
    assert "--thinking" in build_command(cfg, "m", None, [], "low") and "--thinking" not in build_command(cfg, "m", None, [], "")
    assert _usage_block({"input": 10, "output": 5, "cacheRead": 2, "cacheWrite": 1}) == {"prompt_tokens": 13, "completion_tokens": 5, "total_tokens": 18}
    assert _tool_start("bash", {"command": "ls -la"}) == "> 🔧 `bash` `ls -la`"
    assert _tool_end(False, "a\nb\n", 0.42) == " · ✅ 2 lines (0.4s)\n"
    assert _tool_end(False, "a\nb\nc\n", 0.1, 2) == " · ✅ 3 lines (0.1s)\n>\n> ```\n> a\n> b\n> … 1 more line\n> ```\n"
    assert "changes the system (not read-only)" in _approval_card("bash", {"command": "mkdir x"}, "NEEDS USER APPROVAL (`mkdir` changes the system (not read-only)).")
    assert _tool_end(True, "total 24\nmkdir: x: File exists\n", 1.0).startswith(" · ❌ mkdir: x: File exists")
    assert "**⏸ Approval required**" in _approval_card("bash", {"command": "mkdir x"}, "NEEDS USER APPROVAL (mutating command).")
    assert "awaiting approval" in _footer("m", 2, 1, 3.0) and "2 tool calls" in _footer("m", 2, 0, 3.0)
    h = split_messages([{"role": "user", "content": "hi"}, {"role": "assistant", "content": "hello"}, {"role": "user", "content": "now list files"}])[1]
    assert h.startswith("<conversation-history>") and h.rstrip().endswith("now list files"), h
    home = os.path.expanduser("~")
    assert cwd_from_system(f"Host: x\nCurrent working directory: {home}\nmore", "/fallback", True) == home
    assert cwd_from_system("Current working directory: /definitely/not/here", "/fallback", True) == "/fallback"
    assert cwd_from_system(f"Current working directory: {home}", "/fallback", False) == "/fallback"
    assert cwd_from_system("no such line", "/fallback", True) == "/fallback"
    print("selfcheck ok")


if __name__ == "__main__":
    if os.getenv("BRIDGE_SELFCHECK"):
        _selfcheck()
    else:
        main()
