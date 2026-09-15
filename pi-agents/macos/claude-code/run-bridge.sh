#!/usr/bin/env bash
#
# run-bridge.sh — pi-agents backend: Claude Code CLI as the model (macOS / Linux).
#
# Hermes → pi_bridge.py (:18485) → pi (tools + Codex-style approvals) → Claude Code bridge
# (:18186, built-in tools OFF, read-only claude.ai connectors ON) → claude-opus-5 / fable-5-1 / …
#
# The Claude Code CLI is first-party, so it bills your Claude subscription normally — unlike
# pi's own Anthropic OAuth login, which Anthropic routes to "extra usage". Claude runs with
# built-in tools (Bash/Edit/Write/Read/…) disabled — pi does those under the guardrails — while
# Claude's claude.ai connectors (Atlassian/Jira, …) stay usable, read-only by default.
#
# Usage (from this folder):
#   ./run-bridge.sh                 # foreground pi bridge on 127.0.0.1:18485
#   ./run-bridge.sh upstream        # foreground pure-LLM Claude Code bridge on :18186
#   ./run-bridge.sh test            # /health + a safe completion (ls) + a held one (mkdir)
#   ./run-bridge.sh approve         # replays the mkdir turn with "approve" → it runs
#   ./run-bridge.sh models          # models the pi bridge advertises
#   ./run-bridge.sh selfcheck       # offline checks (pi_bridge.py + guardrail policy)
#   ./run-bridge.sh install-service   # both bridges as auto-start user services
#   ./run-bridge.sh uninstall-service | service-status | logs
#
# Config (env or a .env next to this script; see .env.example) — baked in at install:
#   BRIDGE_PORT 18485   UPSTREAM_PORT 18186   PI_BRIDGE_MODEL claude-opus-5
#   CLAUDE_CODE_EFFORT medium (low|medium|high|xhigh|max)   CLAUDE_CODE_MAX_BUDGET_USD (per turn)
#   PI_BRIDGE_CWD $HOME (fallback; the Hermes project dir wins)   PI_BRIDGE_APPROVAL ask|allow|deny
#   PI_BRIDGE_API_KEY   PI_BRIDGE_TIMEOUT 600   PI_GUARDRAILS_CONFIG ./guardrails.json
set -euo pipefail

BACKEND_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
[ -f "$BACKEND_DIR/.env" ] && { set -a; . "$BACKEND_DIR/.env"; set +a; }

BACKEND_NAME="claude-code"
PROVIDER_ID="claude-code-bridge"
BRIDGE_PORT="${BRIDGE_PORT:-18485}"
UPSTREAM_PORT="${UPSTREAM_PORT:-18186}"
MODEL="${PI_BRIDGE_MODEL:-claude-opus-5}"
LABEL="com.hermes.pi-bridge-claude-code"
# pi's system prompt: the shared SRE persona + the list of native connectors Claude keeps on this path.
export PI_BRIDGE_SYSTEM_PROMPT="${PI_BRIDGE_SYSTEM_PROMPT:-$BACKEND_DIR/../common/prompts/sre.md,$BACKEND_DIR/prompts/connectors.md}"
UPSTREAM_LABEL="com.hermes.claude-code-pure-llm"
CLAUDE_LAUNCHER="$BACKEND_DIR/../../../mac/run-bridge.sh"
# Baked into the upstream service runner (values with spaces are not supported here).
UPSTREAM_ENV="PI_CLAUDE_NATIVE=${PI_CLAUDE_NATIVE:-1} CLAUDE_CODE_EFFORT=${CLAUDE_CODE_EFFORT:-medium}${CLAUDE_CODE_MAX_BUDGET_USD:+ CLAUDE_CODE_MAX_BUDGET_USD=$CLAUDE_CODE_MAX_BUDGET_USD}${CLAUDE_BIN:+ CLAUDE_BIN=$CLAUDE_BIN}${PI_CLAUDE_CONNECTORS:+ PI_CLAUDE_CONNECTORS=$PI_CLAUDE_CONNECTORS}${CLAUDE_CODE_MCP_ALLOW:+ CLAUDE_CODE_MCP_ALLOW=$CLAUDE_CODE_MCP_ALLOW}"

upstream_require() {
  command -v claude >/dev/null 2>&1 || [ -n "${CLAUDE_BIN:-}" ] || { echo "[pi-bridge] error: claude not on PATH — install Claude Code and run: claude login" >&2; exit 1; }
  [ -x "$CLAUDE_LAUNCHER" ] || { echo "[pi-bridge] error: $CLAUDE_LAUNCHER missing" >&2; exit 1; }
}
# Claude's BUILT-IN tools are removed (pi runs bash/read/write/edit …). Claude's claude.ai
# CONNECTORS stay available, restricted to the read-only tools listed here — the same set the
# tool-enabled Claude bridge exposes to Hermes, minus anything that creates/edits/transitions.
# Connector calls run inside Claude with `--permission-mode default`, so every tool NOT in this
# allowlist is refused automatically ("requested permissions … not granted"). Override with
# CLAUDE_CODE_MCP_ALLOW in .env (comma-separated tool names) or set PI_CLAUDE_CONNECTORS=0 for
# the strict pure-LLM mode (`claude --tools ""`, no connectors at all).
CLAUDE_BUILTINS="Bash,Edit,Write,MultiEdit,NotebookEdit,Read,Glob,Grep,LS,WebFetch,WebSearch,Task,TodoWrite,TodoRead,AskUserQuestion,Skill,SlashCommand,KillShell,BashOutput,EnterPlanMode,ExitPlanMode,PowerShell,CronCreate,CronDelete,CronList,Monitor,RemoteTrigger,SendMessage,ListAgents,TaskOutput,TaskStop,EnterWorktree,ExitWorktree,PushNotification"
ATLASSIAN_READ="mcp__claude_ai_Atlassian__getAccessibleAtlassianResources,mcp__claude_ai_Atlassian__atlassianUserInfo,mcp__claude_ai_Atlassian__getJiraIssue,mcp__claude_ai_Atlassian__searchJiraIssuesUsingJql,mcp__claude_ai_Atlassian__getVisibleJiraProjects,mcp__claude_ai_Atlassian__getTransitionsForJiraIssue,mcp__claude_ai_Atlassian__lookupJiraAccountId,mcp__claude_ai_Atlassian__getJiraIssueRemoteIssueLinks,mcp__claude_ai_Atlassian__getJiraProjectIssueTypesMetadata,mcp__claude_ai_Atlassian__getJiraIssueTypeMetaWithFields,mcp__claude_ai_Atlassian__getIssueLinkTypes,mcp__claude_ai_Atlassian__getConfluenceSpaces,mcp__claude_ai_Atlassian__getConfluencePage,mcp__claude_ai_Atlassian__getPagesInConfluenceSpace,mcp__claude_ai_Atlassian__getConfluencePageDescendants,mcp__claude_ai_Atlassian__getConfluencePageFooterComments,mcp__claude_ai_Atlassian__getConfluencePageInlineComments,mcp__claude_ai_Atlassian__searchConfluenceUsingCql,mcp__claude_ai_Atlassian__search,mcp__claude_ai_Atlassian__fetch"
NATIVE_BRIDGE="$BACKEND_DIR/native/claude_native_bridge.py"
export PI_UPSTREAM_NATIVE_TOOLS="${PI_UPSTREAM_NATIVE_TOOLS:-$([ "${PI_CLAUDE_NATIVE:-1}" = "0" ] && echo 0 || echo 1)}"
upstream_run() {
  # Started from inside a Claude Code / Agent SDK session? Those variables make the spawned `claude`
  # look like a third-party app ("Third-party apps now draw from extra usage"). Drop them.
  unset CLAUDECODE CLAUDE_CODE_ENTRYPOINT CLAUDE_AGENT_SDK_VERSION CLAUDE_CODE_OAUTH_SCOPES ANTHROPIC_BASE_URL CLAUDE_CODE_DESKTOP_APP_VERSION 2>/dev/null || true
  if [ "${PI_CLAUDE_NATIVE:-1}" != "0" ]; then
    # NATIVE (default): pi's tools reach Claude as real function calls via an MCP shim; one warm
    # claude process per conversation; connectors read-only (allowlist) unless CLAUDE_CODE_MCP_ALLOW='*'.
    BRIDGE_PORT="$UPSTREAM_PORT" CLAUDE_CODE_BRIDGE_MODEL="$MODEL" CLAUDE_CODE_EFFORT="${CLAUDE_CODE_EFFORT:-medium}" \
    CLAUDE_CODE_ALLOWED_TOOLS="${CLAUDE_CODE_MCP_ALLOW:-$ATLASSIAN_READ}" CLAUDE_CODE_DISALLOWED_TOOLS="$CLAUDE_BUILTINS" \
    CLAUDE_CODE_BRIDGE_MODELS="${CLAUDE_CODE_BRIDGE_MODELS:-claude-opus-5,claude-fable-5-1,claude-fable-5,claude-opus-4-8,claude-sonnet-5,claude-sonnet-4-6,claude-haiku-4-5}" \
    CLAUDE_CODE_BRIDGE_TIMEOUT="${CLAUDE_CODE_BRIDGE_TIMEOUT:-600}" \
      exec python3 "$NATIVE_BRIDGE"
  fi
  if [ "${PI_CLAUDE_CONNECTORS:-1}" = "0" ]; then
    BRIDGE_PORT="$UPSTREAM_PORT" CLAUDE_CODE_TOOLS="none" CLAUDE_CODE_BRIDGE_MODEL="$MODEL" CLAUDE_CODE_EFFORT="${CLAUDE_CODE_EFFORT:-medium}" \
    CLAUDE_CODE_BRIDGE_MODELS="${CLAUDE_CODE_BRIDGE_MODELS:-claude-opus-5,claude-fable-5-1,claude-fable-5,claude-opus-4-8,claude-sonnet-5,claude-sonnet-4-6,claude-haiku-4-5}" \
    CLAUDE_CODE_BRIDGE_LABEL="$UPSTREAM_LABEL" CLAUDE_CODE_BRIDGE_TIMEOUT="${CLAUDE_CODE_BRIDGE_TIMEOUT:-600}" \
      exec "$CLAUDE_LAUNCHER" run
  fi
  BRIDGE_PORT="$UPSTREAM_PORT" CLAUDE_CODE_BRIDGE_MODEL="$MODEL" CLAUDE_CODE_EFFORT="${CLAUDE_CODE_EFFORT:-medium}" \
  CLAUDE_CODE_PERMISSION_MODE="default" \
  CLAUDE_CODE_DISALLOWED_TOOLS="$CLAUDE_BUILTINS" \
  CLAUDE_CODE_ALLOWED_TOOLS="${CLAUDE_CODE_MCP_ALLOW:-$ATLASSIAN_READ}" \
  CLAUDE_CODE_BRIDGE_MODELS="${CLAUDE_CODE_BRIDGE_MODELS:-claude-opus-5,claude-fable-5-1,claude-fable-5,claude-opus-4-8,claude-sonnet-5,claude-sonnet-4-6,claude-haiku-4-5}" \
  CLAUDE_CODE_BRIDGE_LABEL="$UPSTREAM_LABEL" CLAUDE_CODE_BRIDGE_TIMEOUT="${CLAUDE_CODE_BRIDGE_TIMEOUT:-600}" \
    exec "$CLAUDE_LAUNCHER" run
}

. "$BACKEND_DIR/../common/launcher.sh"
