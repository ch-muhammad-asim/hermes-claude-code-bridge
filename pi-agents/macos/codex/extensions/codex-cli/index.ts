// codex-cli — pi provider for the TERMINAL: `pi` on the OpenAI Codex CLI, native pi tools.
//
// Thin wrapper over ../../../common/extensions/text-tools-provider: it pins the upstream to the
// pure-LLM codex bridge (:18288 — `codex exec --json` in a read-only sandbox, told not to use its
// own tools, so the model is a plain LLM) and names the provider `codex-cli`, then hands over.
// Register it once in ~/.pi/agent/settings.json (install.sh does that) and
// `pi --provider codex-cli` runs the pi agent on Codex, in whatever directory you are in.
//
// The upstream is TEXT-ONLY: `codex exec` has no OpenAI `tools` field, so the shared provider
// renders pi's tool schemas into the system prompt and parses `<tool_call>` blocks back into real
// pi ToolCalls. pi then executes them itself, in YOUR cwd — same shape as the opencode-cli
// provider (../../pi-opencode-cli), and the opposite of claude-code (../../claude-code/pi-cli),
// which talks to a NATIVE bridge.
//
// Config is passed explicitly rather than through the environment so this can coexist with the
// claude-code and opencode-cli providers in the same pi session.
//
// Env (optional): PI_CODEX_CLI_UPSTREAM (default http://127.0.0.1:18288/v1),
//                 PI_CODEX_CLI_API_KEY, PI_CODEX_CLI_MODELS (comma list, skips discovery).

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

export default async function (pi: ExtensionAPI) {
  const shared = await import("../../../common/extensions/text-tools-provider/index.ts");
  const models = (process.env.PI_CODEX_CLI_MODELS || "").split(",").map((s) => s.trim()).filter(Boolean);
  await shared.default(pi, {
    providerId: "codex-cli",
    baseUrl: process.env.PI_CODEX_CLI_UPSTREAM || "http://127.0.0.1:18288/v1",
    apiKey: process.env.PI_CODEX_CLI_API_KEY || "",
    apiKeyRef: "$PI_CODEX_CLI_API_KEY",
    native: false, // pure-LLM upstream: tool calls are emulated over text
    ...(models.length ? { models } : {}),
  });
  // Remove pi's built-in `openai-codex` provider, exactly as the claude-code extension removes
  // `anthropic`. Both offer similar model ids, so `/model` can silently move a session onto the
  // built-in one — which calls OpenAI's API directly, bypassing this bridge entirely: no codex CLI,
  // so no MCP servers and no Codex-plan billing. PI_CODEX_CLI_KEEP_BUILTIN=1 opts out.
  if (process.env.PI_CODEX_CLI_KEEP_BUILTIN !== "1") {
    try {
      pi.unregisterProvider("openai-codex");
      process.stderr.write("[codex-cli] built-in openai-codex provider disabled — Codex models go through the codex CLI bridge (MCP servers available)\n");
    } catch (err) {
      process.stderr.write(`[codex-cli] WARNING: could not disable the built-in openai-codex provider: ${(err as Error).message}\n`);
    }
  }
}
