# 🧩 common — shared by every macOS backend

Nothing here is started directly; each backend folder (`../opencode`, `../claude-code`, …) points at these files.

| Path | Purpose |
|------|---------|
| `pi_bridge.py` | 🖥️ OpenAI-compatible endpoint for Hermes; one headless `pi -p --mode json` run per request; approval handshake; follows the Hermes project directory |
| `extensions/text-tools-provider/` | 🔌 pi provider for an OpenAI-compatible upstream. `PI_UPSTREAM_NATIVE_TOOLS=1` → pi's stock OpenAI adapter (real `tools`/`tool_calls`, used with the Claude Code native bridge); otherwise renders pi's tool schemas into the prompt and parses `<tool_call>` blocks (text-only upstreams such as the OpenCode free-tier bridge). `PI_UPSTREAM_PROVIDER_ID` names it per backend. Its default export also takes an optional `{providerId, baseUrl, apiKey, native, models}` — pass that instead of env when several wrappers share one pi session (e.g. `claude-code` + `opencode-cli` in the terminal) |
| `extensions/guardrails/` | 🛡️ `policy.mjs` (classifier), `index.ts` (pi hook: 3-option prompt / chat handshake / audit), `selfcheck.mjs` (~140 offline cases) |
| `prompts/sre.md` | 🧑‍🔧 Default persona appended to pi's system prompt |
| `launcher.sh` | ▶️ `run · upstream · test · approve · models · selfcheck · install-service · logs` — a backend's `run-bridge.sh` sets ports/labels/`upstream_run` and sources this |
| `install-lib.sh` | 🧰 Shared bootstrap steps (Python, Node, pi, self-checks, services) — a backend's `install.sh` adds `backend_install_deps` and sources this |
| `guardrails.json` | ⚙️ Default policy overrides used when a backend has none of its own |

Test the shared pieces offline:

```bash
BRIDGE_SELFCHECK=1 python3 pi_bridge.py && node extensions/guardrails/selfcheck.mjs | tail -1
```
