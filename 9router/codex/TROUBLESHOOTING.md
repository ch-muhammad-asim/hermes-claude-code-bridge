# Codex Desktop + 9Router Troubleshooting

This document focuses on the remaining Codex Desktop compatibility issue when text inference works through 9Router, but Codex cannot execute local shell commands through the routed model.

Observed error:

```text
I apologize, but I'm unable to execute shell commands directly in this environment.
The `functions.exec` tool isn't available in my current context.
```

This is **not** an API-key problem and is **not** the same problem as the earlier `No active credentials for provider: openai` error.

The working parts are already:

```text
Codex Desktop
    |
    | model = gpt-5.6-sol
    v
9Router alias
    |
    | gpt-5.6-sol -> oc/mimo-v2.5-free
    v
OpenCode Free / MiMo
```

Normal text inference works.

The remaining problem is **tool translation**.

---

# 1. What is happening

Codex Desktop sends an OpenAI Responses API request with tool definitions.

9Router receives that request and translates it into a Chat Completions-style request for the OpenCode/MiMo upstream.

The current 9Router Responses -> Chat translator can handle normal named function tools well, but Codex Desktop can use richer Responses-native tool definitions such as:

```text
namespace
local_shell
tool_search
custom
```

A normal function tool looks like:

```json
{
  "type": "function",
  "name": "get_current_directory",
  "parameters": {
    "type": "object",
    "properties": {}
  }
}
```

This already works through 9Router.

The problem is that namespace/hosted tools may not have a top-level `name`, or may wrap child tools that need to be exposed individually to a Chat Completions upstream.

That can result in MiMo seeing instructions that mention a tool such as:

```text
functions.exec
```

but never receiving a callable function definition for it.

The result is:

```text
The functions.exec tool isn't available in my current context.
```

---

# 2. Root cause (verified)

Reproduced against `decolua/9router:0.5.55` by POSTing a Codex-shaped request to `/v1/responses`:

```json
"tools": [
  {"type":"namespace","name":"functions","tools":[{"type":"function","name":"exec", ...}]},
  {"type":"local_shell"}
]
```

The model's own reasoning gave it away:

```text
looking at the available tools provided to me, I only see one function called "functions"
which has an empty description and no parameters defined. There is no "exec" tool
```

So the namespace is **not** dropped. It *has* a top-level `name`, so the converter turns the whole
container into ONE parameterless function literally called `functions`, and the child `exec` is never
exposed. `local_shell`, which has no `name`, is dropped by the same filter.

The conversion lives here, and the `name` guard is what does it:

```js
const name = tool.name;
if (!name || typeof name !== "string" || name.trim() === "") return null;
```

# 3. ⚠️ Correction: patching `open-sse/` does nothing

The readable source at

```text
/app/open-sse/translator/request/openai-responses.js
```

**is shipped but never executed.** `open-sse/...` does not even resolve from `/app` at runtime
(`ERR_MODULE_NOT_FOUND`); the code that runs is webpack-bundled into

```text
/app/.next/server/chunks/8499.js
```

This was verified by instrumenting the readable file with a `console.error` and never seeing the line,
while 9Router's own request log still reported `1 TOOL` for a two-child namespace.

**Bind-mounting a patched `openai-responses.js` therefore has no effect.** The working fix patches the
bundled chunk at container start.

# 4. Expected behavior after namespace flattening

Before:

```text
Codex Desktop
    |
    | namespace: functions
    |   -> exec
    v
9Router Responses -> Chat translator
    |
    | namespace not flattened
    v
MiMo receives no callable exec function
    |
    v
"functions.exec is not available"
```

After:

```text
Codex Desktop
    |
    | namespace: functions
    |   -> exec
    v
9Router
    |
    | flatten namespace
    v
Chat function: exec
    |
    v
MiMo can emit tool_call(name="exec")
```

If Codex accepts the returned function call and maps it to the local tool runtime, shell execution should begin working.

---

# 5. Repo layout

```text
9router/
├── docker-compose/
│   └── docker-compose.yaml     # entrypoint wrapper + bind mount
└── codex/
    ├── README.md
    ├── TROUBLESHOOTING.md
    └── patches/
        └── apply-codex-tool-patch.sh
```

---

# 6. The fix, as shipped

[`patches/apply-codex-tool-patch.sh`](patches/apply-codex-tool-patch.sh) rewrites the bundled chunk at
startup and then execs the image entrypoint. It is wired up in the Compose file:

```yaml
services:
  9router:
    entrypoint: ["/patch/apply-codex-tool-patch.sh"]
    # Compose's `entrypoint:` override RESETS the image CMD — restate it or the
    # wrapper execs the entrypoint with no command (su-exec usage error).
    command: ["node", "custom-server.js"]
    volumes:
      - ../codex/patches/apply-codex-tool-patch.sh:/patch/apply-codex-tool-patch.sh:ro
```

Apply it:

```bash
cd 9router/docker-compose
docker compose up -d --force-recreate 9router
docker compose logs 9router | grep codex-patch
```

Expected:

```text
[codex-patch] namespace flattening applied to /app/.next/server/chunks/8499.js
```

The script is idempotent (marker comment), and if the pattern is missing on a future 9Router build it logs
a warning and starts **unpatched** rather than failing silently:

```text
[codex-patch] WARNING: pattern not found — starting UNPATCHED (9Router build changed?)
```

# 7. Verify it yourself

[`verify.sh`](verify.sh) asserts the whole chain and exits non-zero on the first failure, so it works as a
post-deploy gate:

```bash
cd 9router/codex && ./verify.sh
```

```text
── patch applied at startup
  ✓ container logged: namespace flattening applied
── patch marker present in the bundled chunk
  ✓ marker found in 8499.js
── both namespace children forwarded upstream
  ✓ model lists both: exec, read_file
  ✓ 9Router forwarded 2 tools (unpatched sends 1)
── model emits a real function_call to exec
  ✓ function_call -> exec

Codex tool patch verified
```

It reads the API key from `../docker-compose/.env` unless `NINEROUTER_API_KEY` is set, and honours
`NINEROUTER_URL` and `CODEX_TEST_MODEL`. Run it after every 9Router image bump — that is exactly when the
bundled-chunk pattern is most likely to move.

# 8. Verified result

| | Before | After |
|---|---|---|
| Tools forwarded for a 2-child namespace | `1 TOOL` | `2 TOOL` |
| Model asked to name its tools | *"no tools to list"* / only `functions` | `exec`, `read_file` |
| `list the contents of pwd` | *"functions.exec isn't available"* | `function_call exec {"command":"ls -la"}` |
| Codex Desktop, read | refused | ✅ *Listed files* — real directory listing |
| Codex Desktop, write | refused | ✅ *Ran mkdir test-1* — directory created |

Reproduce:

```bash
curl -sS http://127.0.0.1:8080/v1/responses -H "Authorization: Bearer $NINEROUTER_API_KEY" -H 'content-type: application/json' -d '{"model":"oc/mimo-v2.5-free","stream":false,"input":[{"role":"user","content":[{"type":"input_text","text":"List the contents of the current directory. You must call the exec tool."}]}],"tools":[{"type":"namespace","name":"functions","tools":[{"type":"function","name":"exec","description":"Run a shell command","parameters":{"type":"object","properties":{"command":{"type":"string"}},"required":["command"]}}]}]}'
```

# 9. Still open: `local_shell`

`{"type":"local_shell"}` has no `name` and is still filtered out. Codex Desktop's shell tool arrives inside
the `functions` namespace (which this fixes), but if a Desktop build sends a bare `local_shell` instead, it
will not be exposed. Converting it to a named function is possible, though Codex would then have to map the
returned `function_call` back onto its local shell runtime — untested, so it is deliberately not done here.
