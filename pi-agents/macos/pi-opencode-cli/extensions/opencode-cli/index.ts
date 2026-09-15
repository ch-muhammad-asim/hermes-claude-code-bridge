// opencode-cli — pi provider for the TERMINAL: `pi` on OpenCode's FREE models, native pi tools.
//
// Thin wrapper over ../../../common/extensions/text-tools-provider: it pins the upstream to the
// pi-opencode-cli pure-LLM OpenCode bridge (:18386 — `opencode run` with every OpenCode tool denied
// via opencode/pure-llm.json, so the model is a plain LLM) and names the provider `opencode-cli`,
// then hands over. Register it once in ~/.pi/agent/settings.json (install.sh does that) and
// `pi --provider opencode-cli` runs the pi agent on free models, in whatever directory you are in.
//
// The upstream is TEXT-ONLY: OpenCode's `run` surface has no OpenAI `tools` field, so the shared
// provider renders pi's tool schemas into the system prompt and parses `<tool_call>` blocks back
// into real pi ToolCalls. pi then executes them itself, in YOUR cwd. That is the opposite of the
// claude-code provider (../../claude-code/pi-cli), which talks to a NATIVE bridge.
//
// Config is passed explicitly rather than through the environment so this can coexist with the
// claude-code provider in the same pi session (both wrappers import the same cached module).
//
// Env (optional): PI_OPENCODE_CLI_UPSTREAM (default http://127.0.0.1:18386/v1),
//                 PI_OPENCODE_CLI_API_KEY, PI_OPENCODE_CLI_MODELS (comma list, skips discovery).

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

export default async function (pi: ExtensionAPI) {
  const shared = await import("../../../common/extensions/text-tools-provider/index.ts");
  const models = (process.env.PI_OPENCODE_CLI_MODELS || "").split(",").map((s) => s.trim()).filter(Boolean);
  await shared.default(pi, {
    providerId: "opencode-cli",
    baseUrl: process.env.PI_OPENCODE_CLI_UPSTREAM || "http://127.0.0.1:18386/v1",
    apiKey: process.env.PI_OPENCODE_CLI_API_KEY || "",
    apiKeyRef: "$PI_OPENCODE_CLI_API_KEY",
    native: false, // pure-LLM upstream: tool calls are emulated over text
    ...(models.length ? { models } : {}),
  });
}
