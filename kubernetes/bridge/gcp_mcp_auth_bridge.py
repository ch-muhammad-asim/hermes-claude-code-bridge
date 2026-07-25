#!/usr/bin/env python3
"""Loopback auth bridge that fronts the Google Cloud MCP endpoints and injects a
fresh Google access token, so MCP clients point at 127.0.0.1 and do no OAuth at all.

Two token sources, selected automatically:

  * Workload Identity (RECOMMENDED, default) — when no refresh token is configured,
    the bridge fetches tokens from the GKE metadata server for the pod's
    Workload-Identity-bound Google service account. Keyless, auto-rotating, no
    human identity, no offline token to store or expire.
  * OAuth refresh token (ADDITIONAL, not recommended) — when
    GOOGLE_MCP_OAUTH_REFRESH_TOKEN is set, the bridge mints access tokens from that
    long-lived offline token (grant_type=refresh_token). Tied to a Workspace/OAuth
    user identity and needs manual rotation; kept only for environments without
    Workload Identity.

Either way IAM (read-only) is unchanged and remains the real guardrail.

Stdlib only; streams the upstream body to EOF with Connection: close, so both
plain-JSON and SSE MCP responses work without buffering. If clients ever need HTTP/1.1
keep-alive, switch to chunked framing.
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
# GKE metadata server — provides an access token for the pod's Workload-Identity-bound
# Google service account. No key, no refresh token; the token auto-rotates.
METADATA_TOKEN_URL = (
    "http://metadata.google.internal/computeMetadata/v1/"
    "instance/service-accounts/default/token"
)


def auth_mode():
    """Workload Identity by default; OAuth only when a refresh token is provided."""
    return "oauth" if os.environ.get("GOOGLE_MCP_OAUTH_REFRESH_TOKEN") else "workload-identity"
# Hop-by-hop headers (RFC 7230 §6.1) plus length/host, which urllib sets itself.
DROP_HEADERS = {
    "connection", "keep-alive", "proxy-authenticate", "proxy-authorization",
    "te", "trailers", "transfer-encoding", "upgrade", "content-length", "host",
}

_lock = threading.Lock()
_cache = {"token": None, "exp": 0.0}


def log(msg):
    print(f"[gcp-mcp-auth-bridge] {msg}", file=sys.stderr, flush=True)


def _mint_token():
    """Fetch a fresh Google access token from the active source (Workload Identity
    by default, or the OAuth refresh-token flow when a refresh token is configured)."""
    if auth_mode() == "oauth":
        data = urllib.parse.urlencode({
            "grant_type": "refresh_token",
            "client_id": os.environ["GOOGLE_MCP_OAUTH_CLIENT_ID"],
            "client_secret": os.environ["GOOGLE_MCP_OAUTH_CLIENT_SECRET"],
            "refresh_token": os.environ["GOOGLE_MCP_OAUTH_REFRESH_TOKEN"],
        }).encode()
        req = urllib.request.Request(
            TOKEN_URL, data=data,
            headers={"Content-Type": "application/x-www-form-urlencoded"})
    else:
        # Workload Identity: the GKE metadata server returns a token for the
        # KSA-bound Google service account. Requires the Metadata-Flavor header.
        req = urllib.request.Request(
            METADATA_TOKEN_URL, headers={"Metadata-Flavor": "Google"})
    with urllib.request.urlopen(req, timeout=20) as r:
        return json.load(r)


def get_token():
    """Return a valid access token, minting a new one when the cached one is within
    120s of expiry. Serialized so concurrent requests mint once."""
    now = time.time()
    with _lock:
        if _cache["token"] and now < _cache["exp"] - 120:
            return _cache["token"]
        payload = _mint_token()
        _cache["token"] = payload["access_token"]
        _cache["exp"] = now + float(payload.get("expires_in", 3600))
        log(f"minted access token via {auth_mode()} (expires_in={payload.get('expires_in')}s)")
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
        except Exception as e:  # noqa: BLE001 - surface as a clear gateway error
            log(f"token mint failed: {e}")
            self.send_error(502, "token mint failed")
            return

        length = int(self.headers.get("Content-Length", 0) or 0)
        body = self.rfile.read(length) if length else None
        headers = {k: v for k, v in self.headers.items()
                   if k.lower() not in DROP_HEADERS and k.lower() != "authorization"}
        headers["Authorization"] = "Bearer " + token

        req = urllib.request.Request(target, data=body, method=self.command, headers=headers)
        try:
            resp = urllib.request.urlopen(req, timeout=120)
        except urllib.error.HTTPError as e:
            resp = e  # forward upstream 4xx/5xx (e.g. IAM 403) verbatim
        except Exception as e:  # noqa: BLE001
            log(f"upstream error: {e}")
            self.send_error(502, "upstream error")
            return

        self.send_response(resp.status)
        for k, v in resp.headers.items():
            if k.lower() not in DROP_HEADERS:
                self.send_header(k, v)
        self.send_header("Connection", "close")
        self.end_headers()
        self.close_connection = True
        while True:
            chunk = resp.read(65536)
            if not chunk:
                break
            self.wfile.write(chunk)
        resp.close()

    do_GET = _handle
    do_POST = _handle

    def do_DELETE(self):
        self.send_error(405, "method not allowed")

    def log_message(self, *args):  # silence per-request access logging
        pass


def main():
    mode = auth_mode()
    if mode == "oauth":
        # OAuth mode needs the full client + refresh-token triple.
        for var in ("GOOGLE_MCP_OAUTH_CLIENT_ID", "GOOGLE_MCP_OAUTH_CLIENT_SECRET",
                    "GOOGLE_MCP_OAUTH_REFRESH_TOKEN"):
            if not os.environ.get(var):
                log(f"missing required env {var} for oauth mode; refusing to start")
                sys.exit(1)
    log(f"auth mode: {mode}")
    port = int(os.environ.get("GCP_MCP_TOKEN_PROXY_PORT", "19190"))
    # Fail fast if the token source is misconfigured, rather than 502-ing on first use.
    get_token()
    srv = ThreadingHTTPServer(("127.0.0.1", port), Handler)
    log(f"listening on 127.0.0.1:{port}; routes={list(ROUTES)}")
    srv.serve_forever()


if __name__ == "__main__":
    main()
