#!/usr/bin/env python3
"""Loopback auth bridge for Google Cloud MCP endpoints.

Hermes points at 127.0.0.1:19190 while this bridge injects OAuth bearer tokens
minted from the offline refresh token for devops@saqlainmushtaq.com.
"""
import json
import os
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ROUTES = {
    "/logging": "https://logging.googleapis.com/mcp",
    "/monitoring": "https://monitoring.googleapis.com/mcp",
    "/trace": "https://cloudtrace.googleapis.com/mcp",
}
TOKEN_URL = "https://oauth2.googleapis.com/token"
DROP_HEADERS = {
    "connection", "keep-alive", "proxy-authenticate", "proxy-authorization",
    "te", "trailers", "transfer-encoding", "upgrade", "content-length", "host",
}

_lock = threading.Lock()
_cache = {"token": None, "exp": 0.0}


def log(msg):
    print(f"[gcp-mcp-auth-bridge] {msg}", file=sys.stderr, flush=True)


def get_token():
    now = time.time()
    with _lock:
        if _cache["token"] and now < _cache["exp"] - 120:
            return _cache["token"]
        data = urllib.parse.urlencode({
            "grant_type": "refresh_token",
            "client_id": os.environ["GOOGLE_MCP_OAUTH_CLIENT_ID"],
            "client_secret": os.environ["GOOGLE_MCP_OAUTH_CLIENT_SECRET"],
            "refresh_token": os.environ["GOOGLE_MCP_OAUTH_REFRESH_TOKEN"],
        }).encode()
        req = urllib.request.Request(
            TOKEN_URL,
            data=data,
            headers={"Content-Type": "application/x-www-form-urlencoded"},
        )
        with urllib.request.urlopen(req, timeout=20) as response:
            payload = json.load(response)
        _cache["token"] = payload["access_token"]
        _cache["exp"] = now + float(payload.get("expires_in", 3600))
        log(f"minted access token (expires_in={payload.get('expires_in')}s)")
        return _cache["token"]


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def _route(self, path):
        for prefix, base in ROUTES.items():
            if path == prefix or path.startswith(prefix + "/"):
                return base + path[len(prefix):]
        return None

    def _handle(self):
        parsed = urllib.parse.urlparse(self.path)
        if parsed.path == "/healthz":
            body = b"ok\n"
            self.send_response(200)
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Connection", "close")
            self.end_headers()
            self.close_connection = True
            self.wfile.write(body)
            return

        target = self._route(parsed.path)
        if not target:
            self.send_error(404, "no route for path")
            return
        if parsed.query:
            target += "?" + parsed.query

        try:
            token = get_token()
        except Exception as exc:
            log(f"token mint failed: {exc}")
            self.send_error(502, "token mint failed")
            return

        length = int(self.headers.get("Content-Length", 0) or 0)
        body = self.rfile.read(length) if length else None
        headers = {
            key: value
            for key, value in self.headers.items()
            if key.lower() not in DROP_HEADERS and key.lower() != "authorization"
        }
        headers["Authorization"] = "Bearer " + token

        req = urllib.request.Request(target, data=body, method=self.command, headers=headers)
        try:
            response = urllib.request.urlopen(req, timeout=120)
        except urllib.error.HTTPError as exc:
            response = exc
        except Exception as exc:
            log(f"upstream error: {exc}")
            self.send_error(502, "upstream error")
            return

        self.send_response(response.status)
        for key, value in response.headers.items():
            if key.lower() not in DROP_HEADERS:
                self.send_header(key, value)
        self.send_header("Connection", "close")
        self.end_headers()
        self.close_connection = True
        while True:
            chunk = response.read(65536)
            if not chunk:
                break
            self.wfile.write(chunk)
        response.close()

    do_GET = _handle
    do_POST = _handle

    def do_DELETE(self):
        self.send_error(405, "method not allowed")

    def log_message(self, *args):
        pass


def main():
    for var in (
        "GOOGLE_MCP_OAUTH_CLIENT_ID",
        "GOOGLE_MCP_OAUTH_CLIENT_SECRET",
        "GOOGLE_MCP_OAUTH_REFRESH_TOKEN",
    ):
        if not os.environ.get(var):
            log(f"missing required env {var}; refusing to start")
            sys.exit(1)
    port = int(os.environ.get("GCP_MCP_TOKEN_PROXY_PORT", "19190"))
    get_token()
    server = ThreadingHTTPServer(("127.0.0.1", port), Handler)
    log(f"listening on 127.0.0.1:{port}; routes={list(ROUTES)}")
    server.serve_forever()


if __name__ == "__main__":
    main()
