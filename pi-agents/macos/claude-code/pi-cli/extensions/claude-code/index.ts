// claude-code — pi provider for the TERMINAL: `pi` on Claude Code, native pi tools, no guardrails.
//
// Thin wrapper over ../../../../common/extensions/text-tools-provider: it pins the upstream to the
// pi-cli Claude Code NATIVE bridge (:18187 — pi's tools reach Claude as real functions through an MCP
// shim, one warm claude process per conversation, built-in tools off, ALL claude.ai connectors on)
// and names the provider `claude-code`, then hands over. Register it once in ~/.pi/agent/settings.json (install.sh
// does that) and every `pi` session uses Claude Code as its model, in whatever directory you are in.
//
// It also REMOVES pi's built-in `anthropic` provider. Both providers serve the same model ids
// (claude-opus-5, …); with both present a bare `pi` resolved the id to the built-in one, which
// authenticates with pi's own OAuth and is billed by Anthropic as third-party "extra usage"
// ("Third-party apps now draw from extra usage, not plan limits"). Set PI_CLI_KEEP_ANTHROPIC=1
// to keep it (then always pass --provider claude-code).
//
// Env (optional): PI_CLI_UPSTREAM (default http://127.0.0.1:18187/v1), PI_UPSTREAM_API_KEY.

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

export default async function (pi: ExtensionAPI) {
  process.env.PI_UPSTREAM_PROVIDER_ID = "claude-code";
  process.env.PI_UPSTREAM_BASE_URL = process.env.PI_CLI_UPSTREAM || "http://127.0.0.1:18187/v1";
  process.env.PI_UPSTREAM_NATIVE_TOOLS ??= "1"; // the pi-cli bridge is the NATIVE one: real function calls, no text emulation
  // Import AFTER the env is set: the shared provider reads PI_UPSTREAM_PROVIDER_ID at module load.
  const shared = await import("../../../../common/extensions/text-tools-provider/index.ts");
  await shared.default(pi);
  if (process.env.PI_CLI_KEEP_ANTHROPIC !== "1") {
    try {
      pi.unregisterProvider("anthropic");
      process.stderr.write("[claude-code] built-in anthropic provider disabled — all Claude models go through Claude Code (plan limits, not extra usage)\n");
    } catch (err) {
      process.stderr.write(`[claude-code] WARNING: could not disable the built-in anthropic provider: ${(err as Error).message}\n`);
    }
  }
}
