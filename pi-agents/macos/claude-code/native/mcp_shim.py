#!/usr/bin/env python3
"""mcp_shim.py — a tiny MCP (stdio) server that Claude Code spawns; it exposes the CLIENT's tools.

Used by claude_native_bridge.py to give `claude -p` REAL function calling for pi's tools:

    claude -p ──(MCP stdio)──▶ mcp_shim.py ──(unix socket, JSON lines)──▶ claude_native_bridge.py ──▶ pi

* ``tools/list``  → the tool definitions the bridge received in the OpenAI request (name,
                    description, JSON-schema parameters). Claude sees them as ``mcp__host__<name>``.
* ``tools/call``  → forwarded to the bridge, which emits an OpenAI ``tool_calls`` response to pi and
                    BLOCKS here until pi sends the tool result back in its next request. The result
                    is returned to Claude as the MCP tool output, and Claude continues its turn.

Protocol on the socket (one JSON object per line, both directions):
    shim → bridge : {"op": "hello", "session": S}
    bridge → shim : {"op": "tools", "tools": [{name, description, parameters}, …]}   (reply to hello)
    shim → bridge : {"op": "call", "id": <mcp request id>, "name": str, "arguments": {…}}
    bridge → shim : {"op": "result", "id": <same>, "content": str, "is_error": bool}
Stdlib only; MCP protocol version 2024-11-05 (JSON-RPC 2.0 over newline-delimited stdio).
"""

from __future__ import annotations

import json
import os
import socket
import sys
import threading
from typing import Any

PROTOCOL_VERSION = "2024-11-05"


def _log(msg: str) -> None:
    sys.stderr.write(f"[mcp-shim] {msg}\n")
    sys.stderr.flush()


class Bridge:
    """JSON-lines client to the bridge over a unix socket; one request in flight per id."""

    def __init__(self, path: str, session: str) -> None:
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.connect(path)
        self.rfile = self.sock.makefile("r", encoding="utf-8")
        self.lock = threading.Lock()
        self.pending: dict[str, tuple[threading.Event, dict[str, Any]]] = {}
        self.tools: list[dict[str, Any]] = []
        self._send({"op": "hello", "session": session})
        first = json.loads(self.rfile.readline())
        self.tools = first.get("tools") or []
        threading.Thread(target=self._reader, daemon=True).start()

    def _send(self, obj: dict[str, Any]) -> None:
        with self.lock:
            self.sock.sendall((json.dumps(obj) + "\n").encode("utf-8"))

    def _reader(self) -> None:
        for line in self.rfile:
            try:
                msg = json.loads(line)
            except json.JSONDecodeError:
                continue
            if msg.get("op") == "result":
                slot = self.pending.get(str(msg.get("id")))
                if slot:
                    slot[1].update(msg)
                    slot[0].set()
        # socket closed: release everything with an error so claude is not stuck forever
        for ev, box in list(self.pending.values()):
            box.setdefault("content", "bridge connection closed")
            box.setdefault("is_error", True)
            ev.set()

    def call(self, req_id: str, name: str, arguments: dict[str, Any]) -> dict[str, Any]:
        ev, box = threading.Event(), {}
        self.pending[req_id] = (ev, box)
        self._send({"op": "call", "id": req_id, "name": name, "arguments": arguments})
        ev.wait()
        self.pending.pop(req_id, None)
        return box


def main() -> None:
    sock_path = os.environ.get("MCP_SHIM_SOCKET") or (sys.argv[1] if len(sys.argv) > 1 else "")
    session = os.environ.get("MCP_SHIM_SESSION") or (sys.argv[2] if len(sys.argv) > 2 else "default")
    if not sock_path:
        _log("usage: mcp_shim.py <socket> <session>")
        sys.exit(2)
    bridge = Bridge(sock_path, session)
    out_lock = threading.Lock()

    def reply(obj: dict[str, Any]) -> None:
        with out_lock:
            sys.stdout.write(json.dumps(obj) + "\n")
            sys.stdout.flush()

    def handle(req: dict[str, Any]) -> None:
        method, rid, params = req.get("method"), req.get("id"), req.get("params") or {}
        if method == "initialize":
            reply({"jsonrpc": "2.0", "id": rid, "result": {
                "protocolVersion": PROTOCOL_VERSION,
                "capabilities": {"tools": {"listChanged": False}},
                "serverInfo": {"name": "host", "version": "1.0.0"}}})
        elif method == "notifications/initialized":
            return
        elif method == "ping":
            reply({"jsonrpc": "2.0", "id": rid, "result": {}})
        elif method == "tools/list":
            reply({"jsonrpc": "2.0", "id": rid, "result": {"tools": [
                {"name": t["name"], "description": t.get("description") or t["name"],
                 "inputSchema": t.get("parameters") or {"type": "object", "properties": {}}}
                for t in bridge.tools]}})
        elif method == "tools/call":
            name = str(params.get("name") or "")
            args = params.get("arguments") or {}
            res = bridge.call(str(rid), name, args if isinstance(args, dict) else {})
            reply({"jsonrpc": "2.0", "id": rid, "result": {
                "content": [{"type": "text", "text": str(res.get("content", ""))}],
                "isError": bool(res.get("is_error"))}})
        elif rid is not None:
            reply({"jsonrpc": "2.0", "id": rid, "error": {"code": -32601, "message": f"method not found: {method}"}})

    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            req = json.loads(line)
        except json.JSONDecodeError:
            continue
        if req.get("method") == "tools/call":
            threading.Thread(target=handle, args=(req,), daemon=True).start()  # calls block; keep serving pings
        else:
            handle(req)


if __name__ == "__main__":
    main()
