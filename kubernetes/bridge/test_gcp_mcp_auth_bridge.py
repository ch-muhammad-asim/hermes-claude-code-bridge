#!/usr/bin/env python3
"""Self-check for gcp_mcp_auth_bridge: route mapping + token caching/refresh.
Run: python3 test_gcp_mcp_auth_bridge.py   (stdlib only, no network)."""
import os

os.environ.setdefault("GOOGLE_MCP_OAUTH_CLIENT_ID", "x")
os.environ.setdefault("GOOGLE_MCP_OAUTH_CLIENT_SECRET", "y")
os.environ.setdefault("GOOGLE_MCP_OAUTH_REFRESH_TOKEN", "z")

import gcp_mcp_auth_bridge as p


def test_routes():
    r = p.Handler._route
    dummy = object()
    assert r(dummy, "/logging") == "https://logging.googleapis.com/mcp"
    assert r(dummy, "/monitoring") == "https://monitoring.googleapis.com/mcp"
    assert r(dummy, "/trace") == "https://cloudtrace.googleapis.com/mcp"
    assert r(dummy, "/logging/extra") == "https://logging.googleapis.com/mcp/extra"
    assert r(dummy, "/nope") is None
    assert r(dummy, "/loggingX") is None  # prefix must be a path boundary


def test_token_cache(monkeypatched):
    calls = {"n": 0}

    class FakeResp:
        def __enter__(self): return self
        def __exit__(self, *a): return False
        def read(self): calls["n"] += 1; return b'{"access_token":"tok","expires_in":3600}'

    p.urllib.request.urlopen = lambda *a, **k: FakeResp()
    p._cache.update(token=None, exp=0.0)

    now = monkeypatched["now"]
    p.time.time = lambda: now[0]
    assert p.get_token() == "tok"
    assert calls["n"] == 1
    assert p.get_token() == "tok"          # still cached
    assert calls["n"] == 1
    now[0] += 3600                          # past expiry window
    assert p.get_token() == "tok"
    assert calls["n"] == 2                  # re-minted


if __name__ == "__main__":
    test_routes()
    test_token_cache({"now": [1000.0]})
    print("ok")
