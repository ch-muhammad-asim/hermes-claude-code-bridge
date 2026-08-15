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

# 2. Why the current translator drops tools

File in upstream 9Router:

```text
open-sse/translator/request/openai-responses.js
```

The translator converts Responses API tools to Chat Completions function tools.

Its current logic requires a tool to have a non-empty `name`:

```js
const name = tool.name;
if (!name || typeof name !== "string" || name.trim() === "") return null;
```

That is fine for ordinary function tools.

It is not sufficient for Responses-native hosted/container tools such as:

```json
{
  "type": "local_shell"
}
```

or namespace wrappers such as:

```json
{
  "type": "namespace",
  "name": "functions",
  "tools": [
    {
      "type": "function",
      "name": "exec"
    }
  ]
}
```

A Chat Completions model cannot call the namespace object itself. It needs the child callable functions flattened into ordinary function tools.

---

# 3. First fix to try: flatten Codex namespaces

This is the recommended first patch because the observed model response specifically refers to:

```text
functions.exec
```

That strongly suggests an `exec` function exists inside a namespace but is not being exposed to MiMo as a normal Chat function.

Edit:

```text
open-sse/translator/request/openai-responses.js
```

Find:

```js
const responseTools = [
  ...(Array.isArray(body.tools) ? body.tools : []),
  ...additionalTools,
];
```

Replace it with:

```js
function expandResponsesTools(tools = []) {
  const expanded = [];

  for (const tool of tools) {
    if (!tool || typeof tool !== "object") continue;

    // Deferred tool discovery is not directly useful to a Chat Completions
    // upstream. The actual callable tools must be exposed explicitly.
    if (tool.type === "tool_search") {
      continue;
    }

    // Codex can expose callable tools inside a namespace.
    // Chat Completions does not understand namespace containers,
    // so flatten child tools into ordinary function/custom tools.
    if (tool.type === "namespace" && Array.isArray(tool.tools)) {
      for (const child of tool.tools) {
        if (!child || typeof child !== "object") continue;

        if (child.type === "function" || child.type === "custom") {
          expanded.push({
            ...child,
            description: [
              child.description,
              tool.name
                ? `Originally exposed by Codex namespace: ${tool.name}`
                : null,
            ]
              .filter(Boolean)
              .join("\n\n"),
          });
        }
      }

      continue;
    }

    expanded.push(tool);
  }

  return expanded;
}

const responseTools = expandResponsesTools([
  ...(Array.isArray(body.tools) ? body.tools : []),
  ...additionalTools,
]);
```

Leave the existing conversion logic below this block intact.

---

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

# 5. Recommended repo layout for the patch

Keep patches beside the Codex documentation:

```text
9router/
├── docker-compose/
└── codex/
    ├── README.md
    ├── TROUBLESHOOTING.md
    └── patches/
        └── openai-responses.js
```

Copy the patched upstream file into:

```text
9router/codex/patches/openai-responses.js
```

---

# 6. Bind-mount the patched translator into 9Router

In the 9Router Docker Compose service, add a read-only bind mount for the patched translator.

Example:

```yaml
services:
  9router:
    volumes:
      - 9router-data:/app/data
      - ../codex/patches/openai-responses.js:/app/open-sse/translator/request/openai-responses.js:ro
```

The exact existing volume names may differ; preserve the current Compose configuration and only add the translator bind mount.

Then recreate 9Router:

```bash
cd 9router/docker-compose

docker compose up -d --force-recreate 9router
```

Follow logs:

```bash
docker compose logs -f 9router
```

---

# 7. Restart Codex Desktop after patching

Fully quit Codex/ChatGPT Desktop:

```text
Cmd+Q
```

Then reopen it and start a **new** Codex chat.

Test:

```text
Run pwd using your tools.
Do not guess.
```

Then:

```text
Run ls -la and show me the files.
```

If it works, the namespace compatibility issue is solved.

---

# 8. If it still fails: inspect whether Desktop is using `local_shell`

If the model still reports that shell execution is unavailable, Codex Desktop may be exposing a Responses-native hosted tool such as:

```json
{
  "type": "local_shell"
}
```

This tool has no ordinary Chat Completions function name.

The existing translator therefore cannot represent it directly as a standard Chat function.

In that case a second compatibility bridge is required.

---

# 9. Native `local_shell` bridge design

The required request-side translation is conceptually:

```text
Responses:
{ type: "local_shell" }

        |
        v

9Router request translator

        |
        v

Chat function declaration:
{
  "type": "function",
  "function": {
    "name": "__codex_local_shell",
    "description": "Execute a local shell command through the Codex client",
    "parameters": {
      "type": "object",
      "properties": {
        "command": {
          "type": "array",
          "items": { "type": "string" }
        },
        "working_directory": {
          "type": "string"
        },
        "timeout_ms": {
          "type": "integer"
        },
        "env": {
          "type": "object",
          "additionalProperties": { "type": "string" }
        }
      },
      "required": ["command"],
      "additionalProperties": false
    }
  }
}
```

MiMo would then emit:

```text
tool_call
name = __codex_local_shell
```

But that is only half the solution.

---

# 10. Response-side translation is also required

Codex Desktop must receive a Responses-native shell call item, not an arbitrary function name.

The response translator therefore needs to map:

```text
Chat tool_call: __codex_local_shell
```

into something equivalent to:

```json
{
  "type": "local_shell_call",
  "call_id": "call_123",
  "action": {
    "type": "exec",
    "command": ["pwd"],
    "working_directory": "/path/to/workspace",
    "timeout_ms": 10000,
    "env": {}
  }
}
```

Codex Desktop can then execute the shell action locally.

The return path must also be supported:

```text
Codex Desktop
    |
    | local_shell_call_output
    v
9Router
    |
    | convert to Chat tool result
    v
MiMo
```

So the full bridge is:

```text
Responses local_shell
        -> Chat __codex_local_shell function

Chat __codex_local_shell tool_call
        -> Responses local_shell_call

Responses local_shell_call_output
        -> Chat role=tool result
```

Implementing only the request-side function declaration is not enough.

---

# 11. Do not change the working routing configuration

At this point these components are already known to work:

```text
NINEROUTER_API_KEY
9Router /v1/responses
oc/mimo-v2.5-free
Codex CLI explicit model override
Codex Desktop text inference
9Router alias:
gpt-5.6-sol -> oc/mimo-v2.5-free
```

Do not add OpenAI credentials merely to work around the shell issue.

Do not remove the working model alias while debugging tool translation.

The remaining problem is specifically:

```text
Responses tool definitions
        ->
9Router translation
        ->
Chat-compatible OpenCode/MiMo tools
```

---

# 12. Useful debugging strategy

When testing Desktop shell behavior, inspect 9Router logs and saved request details.

You want to compare:

```text
raw client request tools
```

with:

```text
translated upstream tools
```

The key questions are:

1. Does the Desktop request contain a `namespace` tool?
2. Does that namespace contain an `exec`, `exec_command`, or `shell_command` child?
3. Does the Desktop request contain `local_shell`?
4. After translation, is the callable shell tool still present in `translatedBody.tools`?
5. Does MiMo return a `tool_calls` delta?
6. Does 9Router translate that tool call back into the correct Responses API item type?

If the tool exists in the raw request but disappears from the translated request, the bug is request-side translation.

If MiMo returns a tool call but Codex does not execute it, the bug is response-side translation / item type mapping.

---

# 13. Current status summary

```text
9Router Responses transport             ✅ working
SSE streaming                           ✅ working
reasoning events                        ✅ working
normal text inference                   ✅ working
named function calling via curl         ✅ working
Codex CLI text inference                ✅ working
Codex Desktop text via alias            ✅ working
Codex Desktop shell execution           ⚠️ not working yet
```

Recommended next step:

```text
1. Flatten namespace tools first.
2. Re-test Codex Desktop shell execution.
3. Only if still failing, implement the local_shell bridge.
```

The observed `functions.exec` wording makes **namespace flattening** the best first fix to test.
