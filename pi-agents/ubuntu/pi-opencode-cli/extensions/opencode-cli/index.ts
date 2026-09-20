// opencode-cli — pi provider for the TERMINAL on Ubuntu: `pi` on OpenCode's free models, with
// pi's own tools in your own working directory.
//
// The macOS twin is ../../../macos/pi-opencode-cli/extensions/opencode-cli. This is not a symlink
// because the two platforms do not agree on the upstream port: macOS runs its own pure-LLM bridge
// on :18386, while on Ubuntu the pure-LLM upstream is pi-upstream-opencode.service on :18385 —
// already running for the Hermes-facing bridge (:18484) and reused here. Pointing at :18386 on
// Ubuntu silently discovers nothing and the provider registers zero models.
//
// The upstream is TEXT-ONLY, so the shared provider renders pi's tool schemas into the system
// prompt and parses <tool_call> blocks back into real pi ToolCalls; pi executes them in YOUR cwd.
//
// Env (optional): PI_OPENCODE_CLI_UPSTREAM (default http://127.0.0.1:18385/v1),
//                 PI_OPENCODE_CLI_API_KEY, PI_OPENCODE_CLI_MODELS (comma list, skips discovery).

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

export default async function (pi: ExtensionAPI) {
  const shared = await import("../../../../macos/common/extensions/text-tools-provider/index.ts");
  const models = (process.env.PI_OPENCODE_CLI_MODELS || "").split(",").map((s) => s.trim()).filter(Boolean);
  await shared.default(pi, {
    providerId: "opencode-cli",
    baseUrl: process.env.PI_OPENCODE_CLI_UPSTREAM || "http://127.0.0.1:18385/v1",
    apiKey: process.env.PI_OPENCODE_CLI_API_KEY || "",
    apiKeyRef: "$PI_OPENCODE_CLI_API_KEY",
    native: false, // pure-LLM upstream: tool calls are emulated over text
    ...(models.length ? { models } : {}),
  });
}
