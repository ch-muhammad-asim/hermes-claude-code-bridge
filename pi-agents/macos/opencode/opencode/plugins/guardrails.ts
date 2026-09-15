// guardrails.ts — OpenCode plugin: the SAME policy the pi approvals extension uses, applied to
// the OpenCode agent that runs tools behind the tool-enabled OpenCode Bridge (:18383, Hermes).
//
// Why this exists: that bridge runs `opencode run --dangerously-skip-permissions` headless, so
// nobody can answer an approval prompt there. This plugin logs every tool decision (mode ask/
// audit) or blocks risky ones (mode enforce) so the Hermes path is at least observable.
//
// Loaded by OpenCode from the directory named by OPENCODE_CONFIG_DIR (…/pi-agents/opencode)
// — see ../../README.md → "Guardrails on the OpenCode side". `tool.execute.before` throws to
// reject a call; the model receives the error text and no tool runs.
//
// Decision engine: ../../extensions/guardrails/policy.mjs (shared with the pi extension).
// Overrides: $PI_GUARDRAILS_CONFIG, else ../../guardrails.json. Audit: $PI_GUARDRAILS_AUDIT
// (JSON lines) — defaults to ~/.pi-bridge-audit.jsonl so both enforcement points log to one file.

import { appendFileSync, existsSync, readFileSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { compilePolicy, evaluate } from "../../../common/extensions/guardrails/policy.mjs";

// OpenCode tool name → the pi-equivalent the policy engine reasons about, plus which
// argument carries the command / path. Tools not listed are passed through untouched
// (task = sub-agent whose own tool calls hit this hook again; skill/todo* are inert).
const TOOL_MAP: Record<string, { as: string; arg?: string }> = {
  bash: { as: "bash", arg: "command" },
  read: { as: "read", arg: "filePath" },
  list: { as: "ls", arg: "path" },
  glob: { as: "find", arg: "path" },
  grep: { as: "grep", arg: "path" },
  edit: { as: "edit", arg: "filePath" },
  write: { as: "write", arg: "filePath" },
  patch: { as: "write", arg: "filePath" },
  multiedit: { as: "edit", arg: "filePath" },
};

function loadPolicy() {
  const here = dirname(fileURLToPath(import.meta.url));
  const candidates = [process.env.PI_GUARDRAILS_CONFIG, join(here, "..", "..", "guardrails.json")].filter(Boolean) as string[];
  for (const path of candidates) {
    if (!existsSync(path)) continue;
    try { return { policy: compilePolicy(JSON.parse(readFileSync(path, "utf8"))), source: path }; }
    catch (err) { process.stderr.write(`[guardrails/opencode] WARNING: bad ${path}: ${(err as Error).message}\n`); }
  }
  return { policy: compilePolicy({}), source: "defaults" };
}

const auditFile = process.env.PI_GUARDRAILS_AUDIT || join(homedir(), ".pi-bridge-audit.jsonl");
function audit(record: Record<string, unknown>) {
  const line = JSON.stringify({ ts: new Date().toISOString(), enforcer: "opencode-plugin", ...record });
  process.stderr.write(`[guardrails/opencode] ${line}\n`);
  try { appendFileSync(auditFile, line + "\n"); } catch { /* never break a run over audit I/O */ }
}

export const GuardrailsPlugin = async (ctx: { directory?: string; worktree?: string }) => {
  const { policy, source } = loadPolicy();
  const cwd = ctx.directory || ctx.worktree || process.cwd();
  const budget: Record<string, number> = {};
  // OpenCode runs headless behind the bridge — nobody can answer an approval prompt here. So
  // "ask" (the pi default) degrades to audit-only on this side; only "enforce" blocks.
  const auditOnly = policy.mode !== "enforce";
  audit({ event: "policy_loaded", source, mode: policy.mode, cwd });

  return {
    "tool.execute.before": async (
      input: { tool: string; sessionID: string; callID: string },
      output: { args: Record<string, unknown> },
    ) => {
      const map = TOOL_MAP[input.tool];
      const n = (budget[input.sessionID] = (budget[input.sessionID] || 0) + 1);
      let decision: { allow: boolean; reason: string };
      if (n > policy.max_tool_calls_per_run) {
        decision = { allow: false, reason: `tool-call budget of ${policy.max_tool_calls_per_run} per session exhausted` };
      } else if (!map) {
        decision = { allow: true, reason: "not a policed tool" };
      } else {
        const piInput = map.as === "bash" ? { command: output.args?.[map.arg!] } : { path: output.args?.[map.arg!] };
        decision = evaluate(policy, map.as, piInput, { cwd });
      }
      const arg = map?.arg ? String(output.args?.[map.arg] ?? "").replace(/\s+/g, " ").slice(0, 200) : "";
      audit({ event: decision.allow ? "allow" : auditOnly ? "would_block" : "block", tool: input.tool, arg, reason: decision.reason, session: input.sessionID, call: n });
      if (!decision.allow && !auditOnly) {
        throw new Error(`BLOCKED by guardrails: ${decision.reason}. This agent is read-only; do not retry a variant — tell the operator what to run.`);
      }
    },
  };
};

export default GuardrailsPlugin;
