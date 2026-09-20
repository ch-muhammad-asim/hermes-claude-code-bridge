// text-tools-provider — pi provider that makes pi the EXECUTING agent on top of ANY text-only
// OpenAI-compatible chat endpoint: the pure-LLM OpenCode Bridge (free models), the pure-LLM
// Claude Code Bridge (`claude --tools ""`), or anything else that speaks /v1/chat/completions
// but drops the `tools` field.
//
// Problem: those bridges wrap a CLI agent (`opencode run`, `claude -p`) — a text-only surface.
// pi never received tool calls and the upstream agent ran the tools on the bridge host, with
// no way to ask the user anything.
//
// Fix: a custom `streamSimple` that emulates function calling over text —
//   * pi's tool schemas are rendered into the system prompt with a strict call protocol;
//   * the model's reply is streamed; a `<tool_call> … </tool_call>` block is parsed into a
//     real pi ToolCall (JSON form, or the <function=…><parameter=…> form MiMo emits natively);
//   * tool results go back as `<tool_result>` blocks.
// pi then executes the tool itself, in YOUR terminal, in YOUR cwd — which is what lets the
// approvals extension (../guardrails) show the Codex-style "approve once / always / deny" prompt.
//
// Pair it with a bridge started from `opencode/pure-llm.json` (all OpenCode tools denied), or
// OpenCode will also try to act on the same request. See ../../README.md.
//
// Env: PI_UPSTREAM_BASE_URL (default http://127.0.0.1:18385/v1), PI_UPSTREAM_API_KEY,
//      PI_UPSTREAM_MODELS (comma list, skips /v1/models discovery).
//
// The default export also takes an optional config object. Pass one when a wrapper extension wants a
// provider WITHOUT touching the environment — which is what lets several wrappers (claude-code on the
// native bridge, opencode-cli on a pure-LLM bridge, …) live in the SAME pi session: this module is
// imported once, so env set by the first wrapper would otherwise leak into the second.

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import {
  createAssistantMessageEventStream,
  type AssistantMessage,
  type AssistantMessageEventStream,
  type Context,
  type Message,
  type Model,
  type SimpleStreamOptions,
  type Tool,
  type ToolCall,
} from "@earendil-works/pi-ai";

// One provider id per backend (PI_UPSTREAM_PROVIDER_ID): "opencode-bridge", "claude-code-bridge", …
// Kept as a module constant for backwards compatibility; the real id is resolved per call in the
// default export (cfg.providerId ?? env ?? this).
export const PROVIDER_ID = process.env.PI_UPSTREAM_PROVIDER_ID || "opencode-bridge";
const DEFAULT_BASE_URL = "http://127.0.0.1:18385/v1";
const fallbackModels = (providerId: string): string[] =>
  providerId.includes("claude")
    ? ["claude-opus-5", "claude-fable-5-1", "claude-fable-5", "claude-sonnet-5", "claude-haiku-4-5"]
    : ["opencode/mimo-v2.5-free", "opencode/big-pickle", "opencode/nemotron-3-ultra-free"];

/** Everything a wrapper extension may pin explicitly instead of via the environment. */
export type UpstreamConfig = {
  providerId?: string;
  baseUrl?: string;
  /** Bearer token used for discovery and requests ("" = none). */
  apiKey?: string;
  /** What pi stores as the provider's key; "$NAME" means "read env var NAME". */
  apiKeyRef?: string;
  /** true = the upstream speaks OpenAI tools/tool_calls itself (no text emulation). */
  native?: boolean;
  /** Skip /v1/models discovery and register exactly these ids. */
  models?: string[];
};
const OPEN_TAG = "<tool_call>";
const CLOSE_TAG = "</tool_call>";

type UpstreamModel = { id: string; display_name?: string; context_length?: number; free?: boolean };

// ── discovery ──────────────────────────────────────────────────────────────────
async function discover(baseUrl: string, apiKey: string, providerId: string, models?: string[]): Promise<UpstreamModel[]> {
  const configured = models ?? (process.env.PI_UPSTREAM_MODELS || "").split(",").map((s) => s.trim()).filter(Boolean);
  if (configured.length) return configured.map((id) => ({ id }));
  try {
    const headers: Record<string, string> = {};
    if (apiKey) headers.authorization = `Bearer ${apiKey}`;
    const res = await fetch(`${baseUrl}/models`, { headers, signal: AbortSignal.timeout(10_000) });
    if (!res.ok) throw new Error(`HTTP ${res.status}`);
    const body = (await res.json()) as { data?: UpstreamModel[] };
    const models = (body.data || []).filter((m) => m && typeof m.id === "string");
    if (!models.length) throw new Error("empty model list");
    return models;
  } catch (err) {
    process.stderr.write(`[text-tools-provider] WARNING: discovery from ${baseUrl}/models failed (${(err as Error).message}); using fallback list\n`);
    return fallbackModels(providerId).map((id) => ({ id }));
  }
}

// ── prompt protocol ────────────────────────────────────────────────────────────
function toolProtocol(tools: Tool[]): string {
  const defs = tools.map((t) => `### ${t.name}\n${t.description.trim()}\nParameters (JSON Schema): ${JSON.stringify(t.parameters)}`).join("\n\n");
  return [
    "# Host tools (REAL — use them)",
    "The host running this conversation gives you the tools listed under \"Available tools\" below. They are executed by the",
    "host, NOT by your own runtime, so they never appear in your runtime's registered/native tool list — that is expected.",
    "Do NOT conclude you lack shell or file access because you cannot see a native Bash/Read tool: you HAVE them through the",
    "block below, in the user's current working directory. Never reply \"I can't run commands / no tools available\".",
    "",
    "To call a host tool, end your message with a block in this exact form (several blocks in a row are allowed when the",
    "calls are independent — they run in parallel) and write nothing after them:",
    "",
    OPEN_TAG,
    '{"name": "<tool name>", "arguments": { <arguments matching the schema> }}',
    CLOSE_TAG,
    "",
    "Example — the user asks what is in the current directory:",
    OPEN_TAG,
    '{"name": "bash", "arguments": {"command": "ls -la"}}',
    CLOSE_TAG,
    "",
    "Rules: arguments must be valid JSON; never invent tool results — wait for the <tool_result> block that follows, then",
    `continue. When no tool is needed, answer normally without ${OPEN_TAG}.`,
    "Some calls require the user's approval before running; if a result says the user declined, ask what to do differently instead of retrying.",
    "If you ALSO have native tools of your own (e.g. connectors such as Atlassian/Jira, Slack, Google Drive), call them natively —",
    "never through this block — and keep going within the same reply until you have their results; the one-call rule applies only",
    "to this block. Prefer finishing all native connector work before emitting a <tool_call> block. Data you already have",
    "(connector results, prior tool output) is in your context: answer from it directly — do NOT feed it back into bash/jq/heredocs,",
    "and never repeat a call you already made.",
    "",
    "## Available tools",
    defs,
  ].join("\n");
}

type OAIPart = { type: "text"; text: string } | { type: "image_url"; image_url: { url: string } };
type OAIMessage = { role: "system" | "user" | "assistant"; content: string | OAIPart[] };

function partsOf(content: string | Array<{ type: string; text?: string; data?: string; mimeType?: string }>): OAIPart[] {
  if (typeof content === "string") return [{ type: "text", text: content }];
  const out: OAIPart[] = [];
  for (const c of content) {
    if (c.type === "text" && c.text) out.push({ type: "text", text: c.text });
    else if (c.type === "image" && c.data) out.push({ type: "image_url", image_url: { url: `data:${c.mimeType || "image/png"};base64,${c.data}` } });
  }
  return out;
}

/**
 * pi 0.86 changed what a provider receives. Until 0.85 the request carried `systemPrompt` and
 * `tools` as fields on `Context`; from 0.86 `normalizeContext()` folds both into the transcript's
 * SYSTEM messages (`content`, `sections`, `toolsAdded`, `toolsRemoved`) and the provider is handed
 * a `TranscriptContext` that only has `messages`. Reading `context.tools` there yields undefined,
 * so no tool protocol is injected and the model answers in prose ("no tool-call format was
 * provided") while never calling anything. Resolve both shapes.
 */
type SystemLike = {
  role: "system";
  content: string | { text?: string }[];
  sections?: Record<string, string | null>;
  toolsAdded?: Tool[];
  toolsRemoved?: { name: string }[];
};

function resolveContext(context: Context): { systemPrompt: string; tools: Tool[] } {
  const parts: string[] = [];
  const tools = new Map<string, Tool>();
  // pre-0.86 shape first, so an older pi keeps working unchanged
  if (context.systemPrompt) parts.push(context.systemPrompt);
  for (const t of context.tools ?? []) tools.set(t.name, t);
  // 0.86+: walk the transcript in order — later messages add and remove tools
  for (const m of (context.messages ?? []) as Message[]) {
    if ((m as { role?: string }).role !== "system") continue;
    const sm = m as unknown as SystemLike;
    const text = typeof sm.content === "string"
      ? sm.content
      : (sm.content ?? []).map((c) => c.text ?? "").filter(Boolean).join("\n");
    if (text) parts.push(text);
    for (const v of Object.values(sm.sections ?? {})) if (v) parts.push(v);
    for (const t of sm.toolsAdded ?? []) tools.set(t.name, t);
    for (const r of sm.toolsRemoved ?? []) tools.delete(r.name);
  }
  return { systemPrompt: parts.join("\n\n"), tools: [...tools.values()] };
}

function convertMessages(context: Context): OAIMessage[] {
  const out: OAIMessage[] = [];
  const { systemPrompt, tools } = resolveContext(context);
  const system = [systemPrompt, tools.length ? toolProtocol(tools) : ""].filter(Boolean).join("\n\n");
  if (system) out.push({ role: "system", content: system });
  for (const m of context.messages as Message[]) {
    if ((m as { role?: string }).role === "system") continue; // already merged into `system` above
    if (m.role === "user") {
      out.push({ role: "user", content: partsOf(m.content as never) });
    } else if (m.role === "assistant") {
      const text: string[] = [];
      for (const c of m.content) {
        if (c.type === "text" && c.text) text.push(c.text);
        else if (c.type === "toolCall") text.push(`${OPEN_TAG}\n${JSON.stringify({ name: c.name, arguments: c.arguments })}\n${CLOSE_TAG}`);
      }
      if (text.length) out.push({ role: "assistant", content: text.join("\n") });
    } else if (m.role === "toolResult") {
      const parts = partsOf(m.content as never);
      const textOnly = parts.filter((p): p is { type: "text"; text: string } => p.type === "text").map((p) => p.text).join("\n");
      const header = `<tool_result tool="${m.toolName}" id="${m.toolCallId}"${m.isError ? ' error="true"' : ""}>`;
      const images = parts.filter((p) => p.type === "image_url");
      // An empty success must not look like a failure, or the model re-runs the command.
      const body = textOnly || (m.isError ? "(no error text)" : "OK — the command completed successfully with no output. Do not run it again.");
      const content: OAIPart[] = [{ type: "text", text: `${header}\n${body}\n</tool_result>` }, ...images];
      out.push({ role: "user", content });
    }
  }
  return out;
}

// ── tool-call parsing ──────────────────────────────────────────────────────────
function coerce(value: string, schema: Record<string, unknown> | undefined): unknown {
  const type = (schema?.type as string | undefined) || "";
  const v = value.trim();
  if (type === "integer" || type === "number") { const n = Number(v); return Number.isNaN(n) ? v : n; }
  if (type === "boolean") return /^(true|1|yes)$/i.test(v);
  if (type === "object" || type === "array") { try { return JSON.parse(v); } catch { return v; } }
  return value.replace(/^\n/, "").replace(/\n$/, "");
}

export function parseToolCall(raw: string, tools: Tool[]): { name: string; arguments: Record<string, unknown> } | undefined {
  let body = raw.trim().replace(/^```(?:json)?\s*/i, "").replace(/```\s*$/, "").trim();
  // JSON form: {"name": ..., "arguments": {...}}  (also tolerate "parameters"/"input")
  const start = body.indexOf("{");
  if (start >= 0) {
    try {
      const obj = JSON.parse(body.slice(start, body.lastIndexOf("}") + 1));
      const name = obj.name || obj.tool || obj.function?.name;
      let args = obj.arguments ?? obj.parameters ?? obj.input ?? obj.function?.arguments ?? {};
      if (typeof args === "string") { try { args = JSON.parse(args); } catch { /* keep */ } }
      if (typeof name === "string") return { name, arguments: typeof args === "object" && args ? args : {} };
    } catch { /* fall through to XML form */ }
  }
  // Native form: <function=bash>\n<parameter=command>ls -la</parameter>\n</function>
  const fn = body.match(/<function=([\w.-]+)>([\s\S]*?)(?:<\/function>|$)/);
  if (fn) {
    const tool = tools.find((t) => t.name === fn[1]);
    const props = ((tool?.parameters as { properties?: Record<string, Record<string, unknown>> } | undefined)?.properties) || {};
    const args: Record<string, unknown> = {};
    for (const m of fn[2].matchAll(/<parameter=([\w.-]+)>([\s\S]*?)(?:<\/parameter>|(?=<parameter=)|$)/g)) args[m[1]] = coerce(m[2], props[m[1]]);
    return { name: fn[1], arguments: args };
  }
  return undefined;
}

// ── streaming ──────────────────────────────────────────────────────────────────
async function* sseDeltas(res: Response, signal?: AbortSignal): AsyncGenerator<string> {
  const reader = res.body!.getReader();
  const decoder = new TextDecoder();
  let carry = "";
  while (true) {
    if (signal?.aborted) throw new Error("aborted");
    const { value, done } = await reader.read();
    if (done) break;
    carry += decoder.decode(value, { stream: true });
    let nl: number;
    while ((nl = carry.indexOf("\n")) >= 0) {
      const line = carry.slice(0, nl).trim();
      carry = carry.slice(nl + 1);
      if (!line.startsWith("data:")) continue;
      const data = line.slice(5).trim();
      if (data === "[DONE]") return;
      try {
        const chunk = JSON.parse(data);
        const delta = chunk.choices?.[0]?.delta?.content;
        if (typeof delta === "string" && delta) yield delta;
      } catch { /* ignore malformed frame */ }
    }
  }
}

let callCounter = 0;

function streamOpenCodeBridge(model: Model<never>, context: Context, options?: SimpleStreamOptions): AssistantMessageEventStream {
  const stream = createAssistantMessageEventStream();
  const activeTools = resolveContext(context).tools;
  (async () => {
    const output: AssistantMessage = {
      role: "assistant", content: [], api: model.api, provider: model.provider, model: model.id,
      usage: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } },
      stopReason: "pending", timestamp: Date.now(),
    };
    try {
      stream.push({ type: "start", partial: output });
      const headers: Record<string, string> = { "content-type": "application/json", ...(options?.headers || {}) };
      const apiKey = options?.apiKey || process.env.PI_UPSTREAM_API_KEY;
      if (apiKey && apiKey !== "not-needed") headers.authorization = `Bearer ${apiKey}`;
      const res = await fetch(`${model.baseUrl}/chat/completions`, {
        method: "POST", headers, signal: options?.signal,
        body: JSON.stringify({
          model: model.id, stream: true, messages: convertMessages(context),
          // pi's --thinking level → OpenAI reasoning_effort; the Claude bridge maps it to `claude --effort`,
          // other upstreams ignore it.
          ...(options?.reasoning && options.reasoning !== "off" ? { reasoning_effort: options.reasoning } : {}),
        }),
      });
      if (!res.ok || !res.body) throw new Error(`opencode bridge HTTP ${res.status}: ${(await res.text().catch(() => "")).slice(0, 500)}`);

      let buf = "";          // everything received
      let emitted = 0;       // chars of buf already streamed as text
      let textIndex = -1;    // content index of the open text block
      let inCall = false;
      let callStart = -1;

      const emitText = (upTo: number) => {
        if (upTo <= emitted) return;
        const delta = buf.slice(emitted, upTo);
        emitted = upTo;
        if (!delta) return;
        if (textIndex < 0) {
          output.content.push({ type: "text", text: "" });
          textIndex = output.content.length - 1;
          stream.push({ type: "text_start", contentIndex: textIndex, partial: output });
        }
        (output.content[textIndex] as { text: string }).text += delta;
        stream.push({ type: "text_delta", contentIndex: textIndex, delta, partial: output });
      };
      const closeText = () => {
        if (textIndex < 0) return;
        const block = output.content[textIndex] as { text: string };
        block.text = block.text.replace(/\s+$/, "");
        stream.push({ type: "text_end", contentIndex: textIndex, content: block.text, partial: output });
        textIndex = -1;
      };

      for await (const delta of sseDeltas(res, options?.signal)) {
        buf += delta;
        if (!inCall) {
          const at = buf.indexOf(OPEN_TAG, Math.max(0, emitted - OPEN_TAG.length));
          if (at >= 0) {
            emitText(at);
            closeText();
            inCall = true;
            callStart = at + OPEN_TAG.length;
          } else {
            // Hold back a tail that could be the start of "<tool_call>" so the tag never leaks as text.
            let hold = 0;
            for (let k = Math.min(OPEN_TAG.length - 1, buf.length); k > 0; k--) {
              if (buf.endsWith(OPEN_TAG.slice(0, k))) { hold = k; break; }
            }
            emitText(buf.length - hold);
          }
        }
      }
      if (!inCall) { emitText(buf.length); closeText(); }

      if (inCall) {
        // Every <tool_call>…</tool_call> block after the first text is a call; independent calls
        // in one message run in parallel in pi (one round trip instead of N).
        const blocks: string[] = [];
        let from = callStart;
        while (true) {
          const end = buf.indexOf(CLOSE_TAG, from);
          blocks.push(buf.slice(from, end >= 0 ? end : undefined));
          if (end < 0) break;
          const next = buf.indexOf(OPEN_TAG, end + CLOSE_TAG.length);
          if (next < 0) break;
          from = next + OPEN_TAG.length;
        }
        let parsedAny = false;
        for (const raw of blocks) {
          const parsed = parseToolCall(raw, activeTools);
          if (!parsed) continue;
          parsedAny = true;
          const id = `call_${Date.now().toString(36)}_${++callCounter}`;
          const toolCall: ToolCall = { type: "toolCall", id, name: parsed.name, arguments: parsed.arguments };
          output.content.push(toolCall);
          const idx = output.content.length - 1;
          stream.push({ type: "toolcall_start", contentIndex: idx, partial: output });
          stream.push({ type: "toolcall_delta", contentIndex: idx, delta: JSON.stringify(parsed.arguments), partial: output });
          stream.push({ type: "toolcall_end", contentIndex: idx, toolCall, partial: output });
        }
        if (!parsedAny) {
          // Unparseable block — surface it as text so the user sees what the model tried.
          emitted = callStart - OPEN_TAG.length;
          emitText(buf.length);
          closeText();
        }
      }

      // The bridge reports no usage on streamed replies; estimate so context accounting is not blind.
      output.usage.input = Math.ceil(JSON.stringify(convertMessages(context)).length / 4);
      output.usage.output = Math.ceil(buf.length / 4);
      output.usage.totalTokens = output.usage.input + output.usage.output;
      output.stopReason = output.content.some((c) => c.type === "toolCall") ? "toolUse" : "stop";
      stream.push({ type: "done", reason: output.stopReason, message: output });
      stream.end();
    } catch (error) {
      output.stopReason = options?.signal?.aborted ? "aborted" : "error";
      output.errorMessage = error instanceof Error ? error.message : String(error);
      stream.push({ type: "error", reason: output.stopReason, error: output });
      stream.end();
    }
  })();
  return stream;
}

// ── registration ───────────────────────────────────────────────────────────────
export default async function (pi: ExtensionAPI, cfg: UpstreamConfig = {}) {
  // Resolve everything HERE (not at module load): the module is cached, so a second wrapper
  // extension in the same session must still get its own id/url/mode.
  const providerId = cfg.providerId || process.env.PI_UPSTREAM_PROVIDER_ID || PROVIDER_ID;
  const baseUrl = (cfg.baseUrl || process.env.PI_UPSTREAM_BASE_URL || DEFAULT_BASE_URL).replace(/\/+$/, "");
  const apiKey = cfg.apiKey ?? process.env.PI_UPSTREAM_API_KEY ?? "";
  const upstream = await discover(baseUrl, apiKey, providerId, cfg.models);

  // native: the upstream understands OpenAI `tools`/`tool_calls` itself (the Claude Code NATIVE
  // bridge, native/claude_native_bridge.py) → use pi's stock OpenAI adapter, no text emulation at
  // all. Otherwise (pure-LLM bridges) emulate tool calls over text. Env: PI_UPSTREAM_NATIVE_TOOLS=1.
  const native = cfg.native ?? process.env.PI_UPSTREAM_NATIVE_TOOLS === "1";
  pi.registerProvider(providerId, {
    name: native ? `${providerId} (native tool calling)` : `${providerId} (text-only upstream, pi executes tools)`,
    baseUrl,
    apiKey: apiKey ? (cfg.apiKeyRef || "$PI_UPSTREAM_API_KEY") : "not-needed",
    api: "openai-completions",
    ...(native ? {} : { streamSimple: streamOpenCodeBridge as never }),
    models: upstream.map((m) => ({
      id: m.id,
      name: m.display_name || m.id,
      reasoning: true, // lets pi pass a --thinking level through (forwarded as reasoning_effort)
      input: ["text", "image"],
      cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
      contextWindow: m.context_length || 200_000,
      maxTokens: 32_768,
      ...(native ? { compat: { supportsStore: false, supportsDeveloperRole: false, supportsReasoningEffort: true,
                               supportsUsageInStreaming: true, supportsStrictMode: false, maxTokensField: "max_tokens" as const } } : {}),
    })),
  });
  process.stderr.write(`[text-tools-provider] ${providerId}: registered ${upstream.length} model(s) from ${baseUrl} (${native ? "native tool calling" : "tool calls emulated over text"})\n`);
}
