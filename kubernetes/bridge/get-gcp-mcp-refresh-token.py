#!/usr/bin/env python3
"""ONE-TIME: obtain a long-lived Google OAuth refresh token for the Hermes GCP MCP
auth bridge. Run this on a laptop while signed into Chrome as hermes-agent@example.com.

This is the only manual auth step. After the refresh token is stored in the
hermes-agent-google-oauth Secret, gcp_mcp_auth_bridge.py auto-mints access tokens
forever; nobody re-authorizes again unless the grant is revoked or the client secret
is rotated.

Usage:
    export GOOGLE_MCP_OAUTH_CLIENT_ID='YOUR_OAUTH_CLIENT_ID.apps.googleusercontent.com'
    export GOOGLE_MCP_OAUTH_CLIENT_SECRET='<the web client secret>'
    python3 get-gcp-mcp-refresh-token.py

It opens the Google consent screen with access_type=offline + prompt=consent (the two
params Google requires to return a refresh token), catches the code on
http://127.0.0.1:19191/callback (already a registered redirect URI on this client),
exchanges it, and prints the refresh token. Then:

    kubectl -n devops-agent create secret generic hermes-agent-google-oauth \
      --from-literal=GOOGLE_MCP_OAUTH_CLIENT_ID="$GOOGLE_MCP_OAUTH_CLIENT_ID" \
      --from-literal=GOOGLE_MCP_OAUTH_CLIENT_SECRET="$GOOGLE_MCP_OAUTH_CLIENT_SECRET" \
      --from-literal=GOOGLE_MCP_OAUTH_REFRESH_TOKEN="<printed value>" \
      --dry-run=client -o yaml | kubectl apply -f -
"""
import base64
import hashlib
import http.server
import json
import os
import secrets
import subprocess
import urllib.parse
import urllib.request
import webbrowser


def _cred(name):
    """Read a credential from the env var, else from the live Kubernetes Secret via
    kubectl (server-side base64 decode, so no local base64/quirks). Needs KUBECONFIG set."""
    v = os.environ.get(name, "").strip()
    if v:
        return v
    out = subprocess.run(
        ["kubectl", "-n", "devops-agent", "get", "secret", "hermes-agent-google-oauth",
         "-o", "go-template={{.data." + name + "|base64decode}}"],
        capture_output=True, text=True)
    return out.stdout.strip()


CID = _cred("GOOGLE_MCP_OAUTH_CLIENT_ID")
CSECRET = _cred("GOOGLE_MCP_OAUTH_CLIENT_SECRET")
if not CID or not CSECRET:
    raise SystemExit(
        "Could not load client id/secret from env or kubectl.\n"
        "Ensure KUBECONFIG points at your-gcp-project-id and the "
        "hermes-agent-google-oauth Secret exists, then rerun.")
REDIRECT = "http://127.0.0.1:19191/callback"
# cloud-platform is accepted by the GCP MCP endpoints (verified) and read-only IAM on
# hermes-agent@example.com is the actual guardrail, per the deployment design.
SCOPE = "https://www.googleapis.com/auth/cloud-platform"

verifier = secrets.token_urlsafe(64)
challenge = base64.urlsafe_b64encode(
    hashlib.sha256(verifier.encode()).digest()).rstrip(b"=").decode()
state = secrets.token_urlsafe(16)

auth_url = "https://accounts.google.com/o/oauth2/v2/auth?" + urllib.parse.urlencode({
    "response_type": "code",
    "client_id": CID,
    "redirect_uri": REDIRECT,
    "scope": SCOPE,
    "access_type": "offline",   # <-- without this Google never returns a refresh token
    "prompt": "consent",        # <-- forces a fresh refresh token even on re-consent
    "code_challenge": challenge,
    "code_challenge_method": "S256",
    "state": state,
})

captured = {}


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        captured.update(urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query))
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b"Done. Close this tab and return to the terminal.")

    def log_message(self, *args):
        pass


print("Sign in as hermes-agent@example.com and approve. Opening browser:")
print(auth_url + "\n")
webbrowser.open(auth_url)
http.server.HTTPServer(("127.0.0.1", 19191), Handler).handle_request()

if captured.get("state", [None])[0] != state:
    raise SystemExit("state mismatch - aborting")
if "code" not in captured:
    raise SystemExit(f"no code returned: {captured}")

data = urllib.parse.urlencode({
    "grant_type": "authorization_code",
    "code": captured["code"][0],
    "redirect_uri": REDIRECT,
    "client_id": CID,
    "client_secret": CSECRET,
    "code_verifier": verifier,
}).encode()
tok = json.load(urllib.request.urlopen(
    urllib.request.Request("https://oauth2.googleapis.com/token", data=data)))

rt = tok.get("refresh_token")
if not rt:
    raise SystemExit(
        "No refresh_token returned. Revoke the prior grant for this app at "
        "https://myaccount.google.com/permissions (as hermes-agent@example.com) and rerun.")
print("\nGOOGLE_MCP_OAUTH_REFRESH_TOKEN (store in the hermes-agent-google-oauth Secret):\n")
print(rt)
