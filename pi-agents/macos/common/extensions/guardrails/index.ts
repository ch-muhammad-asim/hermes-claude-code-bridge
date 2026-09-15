// guardrails — pi extension: Codex-style approvals for tool calls.
//
// Every tool call the model makes is classified by ./policy.mjs (read-only = safe, anything that
// mutates / escalates / leaves the allowed roots = needs approval). Then, depending on
// guardrails.json → "mode":
//
//   "ask"     (default) safe calls run silently; risky ones show a 3-option prompt in the terminal:
//               1. Yes, run it once
//               2. Yes, and don't ask again this session
//               3. No, and tell pi what to do differently
//             In headless runs (-p / --mode json) there is no prompt; PI_APPROVAL_NONINTERACTIVE
//             decides ("deny" default, or "allow").
//   "audit"   everything runs; the decision the policy would have made is logged (would_block).
//   "enforce" risky calls are blocked outright (read-only agent).
//
// Decisions are appended as JSON lines to $PI_GUARDRAILS_AUDIT (default ~/.pi-bridge-audit.jsonl)
// and echoed to stderr with a [guardrails] prefix.

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { appendFileSync, existsSync, readFileSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { compilePolicy, evaluate, summarize } from "./policy.mjs";

type Decision = { allow: boolean; reason: string };

const CHOICES = {
  once: "Yes, run it once",
  always: "Yes, and don't ask again this session",
  deny: "No, and tell pi what to do differently",
};

function loadPolicy() {
  const here = dirname(fileURLToPath(import.meta.url));
  const candidates = [process.env.PI_GUARDRAILS_CONFIG, join(here, "..", "..", "guardrails.json")].filter(Boolean) as string[];
  for (const path of candidates) {
    if (!existsSync(path)) continue;
    try { return { policy: compilePolicy(JSON.parse(readFileSync(path, "utf8"))), source: path }; }
    catch (err) { process.stderr.write(`[guardrails] WARNING: could not parse ${path}: ${(err as Error).message} — using defaults\n`); }
  }
  return { policy: compilePolicy({}), source: "defaults" };
}

const auditFile = process.env.PI_GUARDRAILS_AUDIT || join(homedir(), ".pi-bridge-audit.jsonl");
function audit(record: Record<string, unknown>) {
  const line = JSON.stringify({ ts: new Date().toISOString(), enforcer: "pi-extension", ...record });
  process.stderr.write(`[guardrails] ${line}\n`);
  try { appendFileSync(auditFile, line + "\n"); } catch { /* audit must never break a run */ }
}

function brief(input: unknown, max = 200): string {
  if (!input || typeof input !== "object") return "";
  const inp = input as Record<string, unknown>;
  for (const key of ["command", "path", "pattern", "url"]) {
    const v = inp[key];
    if (typeof v === "string" && v.trim()) return v.replace(/\s+/g, " ").slice(0, max);
  }
  return JSON.stringify(inp).slice(0, max);
}

export default function (pi: ExtensionAPI) {
  const { policy, source } = loadPolicy();
  const mode: "ask" | "audit" | "enforce" = policy.mode;
  let callsThisRun = 0;
  let sessionApproveAll = false;
  const seenThisRun = new Map<string, number>(); // tool+args → count (loop breaker)
  const LOOP_LIMIT = Number(process.env.PI_GUARDRAILS_REPEAT_LIMIT || 3);
  audit({ event: "policy_loaded", source, mode, tools: [...policy._allowedTools] });

  pi.on("before_agent_start", async (event) => {
    if (mode === "enforce") return { systemPrompt: `${event.systemPrompt}\n\n<guardrails>\n${summarize(policy)}\n</guardrails>` };
    if (mode === "ask") return { systemPrompt: `${event.systemPrompt}\n\nSome tool calls require the user's approval before they run. If a result says the user declined, do not retry a variant — ask what to do differently.` };
    return undefined;
  });

  pi.on("agent_start", async () => { callsThisRun = 0; seenThisRun.clear(); });

  pi.on("tool_call", async (event, ctx) => {
    callsThisRun += 1;
    const input = (event as { input?: unknown }).input;
    const summary = brief(input);
    const budgetHit = callsThisRun > policy.max_tool_calls_per_run;
    // Loop breaker: the same tool with the same arguments over and over burns minutes and tokens
    // (typically re-piping data the model already has). Third identical call is refused.
    const key = `${event.toolName}:${JSON.stringify(input ?? {})}`;
    const repeats = (seenThisRun.get(key) || 0) + 1;
    seenThisRun.set(key, repeats);
    if (repeats >= LOOP_LIMIT) {
      audit({ event: "loop_blocked", tool: event.toolName, arg: summary, reason: `identical call #${repeats}`, call: callsThisRun });
      return { block: true, reason: `You have already run exactly this ${event.toolName} call ${repeats - 1} times and have its result. Do not repeat it — answer from the data you already have.` };
    }
    const decision: Decision = budgetHit
      ? { allow: false, reason: `tool-call budget of ${policy.max_tool_calls_per_run} per run exhausted` }
      : evaluate(policy, event.toolName, input, { cwd: ctx.cwd });

    // Safe by policy → run, in every mode.
    if (decision.allow) {
      audit({ event: "allow", tool: event.toolName, arg: summary, reason: decision.reason, call: callsThisRun });
      return undefined;
    }
    if (mode === "audit" && !budgetHit) {
      audit({ event: "would_block", tool: event.toolName, arg: summary, reason: decision.reason, call: callsThisRun });
      return undefined;
    }
    if (mode === "enforce" || budgetHit) {
      audit({ event: "block", tool: event.toolName, arg: summary, reason: decision.reason, call: callsThisRun });
      return { block: true, reason: `BLOCKED by guardrails: ${decision.reason}. Do not retry a variant — tell the user what to run.`, terminate: Boolean(policy.terminate_on_block) || budgetHit };
    }

    // mode === "ask"
    if (sessionApproveAll) {
      audit({ event: "approved_session", tool: event.toolName, arg: summary, reason: decision.reason, call: callsThisRun });
      return undefined;
    }
    if (!ctx.hasUI) {
      const fallback = (process.env.PI_APPROVAL_NONINTERACTIVE || "deny").toLowerCase() === "allow" ? "allow" : "deny";
      audit({ event: fallback === "allow" ? "approved_noninteractive" : "denied_noninteractive", tool: event.toolName, arg: summary, reason: decision.reason, call: callsThisRun });
      if (fallback === "allow") return undefined;
      if (process.env.PI_APPROVAL_HANDSHAKE === "1") {
        // Chat handshake (Hermes via pi_bridge.py): the user approves by replying in the next turn.
        // terminate: the run ends here; pi_bridge.py renders the approval card from this event.
        return { block: true, terminate: true, reason: `NEEDS USER APPROVAL (${decision.reason}).` };
      }
      return { block: true, reason: `Not approved: headless run and PI_APPROVAL_NONINTERACTIVE is not "allow" (${decision.reason}).` };
    }
    const title = `Approve ${event.toolName}?  ${summary}${summary.length >= 200 ? "…" : ""}   — ${decision.reason}`;
    const choice = await ctx.ui.select(title, [CHOICES.once, CHOICES.always, CHOICES.deny]);
    if (choice === CHOICES.once) {
      audit({ event: "approved_once", tool: event.toolName, arg: summary, reason: decision.reason, call: callsThisRun });
      return undefined;
    }
    if (choice === CHOICES.always) {
      sessionApproveAll = true;
      audit({ event: "approved_session_start", tool: event.toolName, arg: summary, reason: decision.reason, call: callsThisRun });
      ctx.ui.notify("Approvals off for the rest of this session (guardrails still log).", "info");
      return undefined;
    }
    audit({ event: "denied_by_user", tool: event.toolName, arg: summary, reason: decision.reason, call: callsThisRun });
    return { block: true, reason: "The user declined this tool call. Ask the user what to do differently before trying again." };
  });
}
