# Codex CLI + Codex Desktop via 9Router

This directory documents the **working 9Router setup for OpenAI Codex CLI and Codex Desktop** using an OpenCode Free model.

Validated environment:

- 9Router: `decolua/9router:0.5.55`
- 9Router base URL: `http://127.0.0.1:8080/v1`
- Responses endpoint: `POST /v1/responses`
- OpenCode Free provider prefix: `oc/`
- Tested model: `oc/mimo-v2.5-free`
- Codex CLI: `0.147.0`
- Codex Desktop on macOS

## Current status

| Capability | Status |
|---|---|
| 9Router `/v1/responses` | ✅ Working |
| SSE streaming | ✅ Working |
| reasoning events | ✅ Working |
| named function calling through 9Router | ✅ Working |
| Codex CLI text inference with MiMo | ✅ Working |
| Codex Desktop text inference through model alias | ✅ Working |
| Codex Desktop local shell execution through MiMo alias | ✅ Working (needs the Codex tool patch) |

Desktop shell execution required one patch to 9Router. Without it, `list the contents of pwd` returns
*"the functions.exec tool isn't available"*: Codex wraps its tools in a Responses `namespace` container, and
9Router's stock translator collapses that container into a single parameterless function called `functions`,
so the child `exec` is never exposed to the model.

The fix is [`patches/apply-codex-tool-patch.sh`](patches/apply-codex-tool-patch.sh), wired into the sibling
Compose stack as an entrypoint wrapper. Verified in Codex Desktop for both reads and writes: `list the contents of pwd` returns a real
listing, and `create a new directory test-1` runs `mkdir test-1` successfully. Details and reproduction in [TROUBLESHOOTING.md](TROUBLESHOOTING.md); run
[`./verify.sh`](verify.sh) to assert the patch is live and working.

---

## Architecture

### Codex CLI

```text
Codex CLI
    |
    | OpenAI Responses API
    v
9Router :8080
    |
    | oc/mimo-v2.5-free
    v
OpenCode Free / MiMo
```

Codex remains the client/agent. 9Router provides routing and protocol translation.

### Codex Desktop workaround

Codex Desktop may insist on selecting a built-in model name such as:

```text
gpt-5.6-sol
```

9Router can alias that model name to the free model:

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

The Desktop UI can still display `5.6 Sol Light`; that is the model name Codex Desktop selected before 9Router rewrites it.

---

# 1. Start 9Router

Use the sibling Docker Compose deployment:

```bash
cd 9router/docker-compose
docker compose up -d
```

Or use the helper already provided by that deployment:

```bash
./generate.sh --up
```

9Router should be reachable at:

```text
http://127.0.0.1:8080
```

API base URL:

```text
http://127.0.0.1:8080/v1
```

---

# 2. Configure the 9Router API key

Use a **9Router-generated API key**.

Do not use these internal server values as bearer keys:

```text
API_KEY_SECRET
JWT_SECRET
INITIAL_PASSWORD
```

For the current shell:

```bash
export NINEROUTER_API_KEY='YOUR_9ROUTER_API_KEY'
```

> ⚠️ **That export outranks `.env` for Docker Compose.** Compose resolves `${NINEROUTER_API_KEY}` from the
> shell *before* the env file, so running `docker compose up -d` in this same shell bakes the exported value
> into Hermes and silently ignores whatever `generate.sh` wrote. The symptom is a stack that looks healthy
> while every model call 401s. `generate.sh` and `verify.sh` both defend against it — `generate.sh` shells
> out to Compose with the variable unset, and `verify.sh` falls back to `.env` when the export does not
> authenticate — but a bare `docker compose up -d` does not. Either use a clean shell for Compose, or
> `unset NINEROUTER_API_KEY` first.

For macOS GUI processes such as Codex Desktop:

```bash
launchctl setenv NINEROUTER_API_KEY 'YOUR_9ROUTER_API_KEY'
```

Verify it exists without printing the secret:

```bash
test -n "$(launchctl getenv NINEROUTER_API_KEY)" \
  && echo "key set" \
  || echo "key missing"
```

For a terminal session you can import the same value:

```bash
export NINEROUTER_API_KEY="$(launchctl getenv NINEROUTER_API_KEY)"
```

---

# 3. Confirm OpenCode Free models

```bash
curl -sS http://127.0.0.1:8080/v1/models \
  -H "Authorization: Bearer $NINEROUTER_API_KEY" \
  | jq -r '.data[].id' \
  | grep '^oc/'
```

The model validated in this setup is:

```text
oc/mimo-v2.5-free
```

Free model availability can change, so `/v1/models` is the source of truth.

---

# 4. Codex config.toml

File:

```text
~/.codex/config.toml
```

Add/merge this provider configuration:

```toml
model = "oc/mimo-v2.5-free"
model_provider = "ninerouter"

[model_providers.ninerouter]
name = "9Router"
base_url = "http://127.0.0.1:8080/v1"
env_key = "NINEROUTER_API_KEY"
wire_api = "responses"
```

Keep your existing plugins, MCP servers, trusted projects, Desktop options, and other settings.

---

# 5. Test the Responses API

```bash
curl -N http://127.0.0.1:8080/v1/responses \
  -H "Authorization: Bearer $NINEROUTER_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "oc/mimo-v2.5-free",
    "input": "Reply exactly: 9Router Codex works",
    "stream": true
  }'
```

A successful stream contains events similar to:

```text
response.created
response.in_progress
response.output_item.added
response.reasoning_summary_text.delta
response.output_text.delta
response.output_text.done
response.output_item.done
response.completed
```

Expected final text:

```text
9Router Codex works
```

---

# 6. Test named function calling

This verifies tool-schema transport and Responses function-call translation:

```bash
curl -N http://127.0.0.1:8080/v1/responses \
  -H "Authorization: Bearer $NINEROUTER_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "oc/mimo-v2.5-free",
    "input": "Use the get_current_directory tool to determine the current directory. Do not guess.",
    "tools": [
      {
        "type": "function",
        "name": "get_current_directory",
        "description": "Get the current working directory",
        "parameters": {
          "type": "object",
          "properties": {},
          "additionalProperties": false
        },
        "strict": true
      }
    ],
    "tool_choice": "required",
    "stream": true
  }'
```

A working response includes a function item such as:

```json
{
  "type": "function_call",
  "name": "get_current_directory",
  "arguments": "{}"
}
```

and events such as:

```text
response.function_call_arguments.delta
response.function_call_arguments.done
response.output_item.done
response.completed
```

This confirms **named function calling** through 9Router.

The curl request does not execute the function itself; the client is responsible for execution and returning the result.

---

# 7. Codex CLI

The reliable launch command is:

```bash
codex -m oc/mimo-v2.5-free
```

Inside Codex run:

```text
/status
```

Expected:

```text
Model:          oc/mimo-v2.5-free
Model provider: 9Router - http://127.0.0.1:8080/v1
```

Text inference has been validated with this configuration.

Useful alias:

```bash
alias codex9='codex -m oc/mimo-v2.5-free'
```

Then:

```bash
codex9
```

## Model metadata warning

Codex currently prints a warning similar to:

```text
Model metadata for `oc/mimo-v2.5-free` not found.
Defaulting to fallback metadata; this can degrade performance and cause issues.
```

This does not prevent text inference. It means Codex does not have built-in metadata for the third-party model ID.

---

# 8. Why plain `codex` may still select Sol

In testing, launching:

```bash
codex
```

selected:

```text
gpt-5.6-sol
```

while the provider was correctly set to 9Router.

`/status` showed the equivalent of:

```text
Model:          gpt-5.6-sol
Model provider: 9Router - http://127.0.0.1:8080/v1
```

Because 9Router sees a bare `gpt-*` model name, it normally routes it to its OpenAI provider. If no OpenAI credentials exist, the result is:

```text
No active credentials for provider: openai
```

Using `-m oc/mimo-v2.5-free` fixes this for the CLI.

For Desktop, use the alias workaround below.

---

# 9. Codex Desktop model alias workaround

Create this mapping in 9Router:

```text
gpt-5.6-sol -> oc/mimo-v2.5-free
```

The alias API is an authenticated dashboard/admin route. A normal 9Router inference bearer key is not sufficient for `/api/models/alias`.

## Login to the 9Router dashboard API

For zsh, use:

```bash
printf '9Router dashboard password: '
IFS= read -r -s NINEROUTER_PASSWORD
printf '\n'
```

Verify it was captured before attempting login:

```bash
if [[ -n "$NINEROUTER_PASSWORD" ]]; then
  echo "password captured (${#NINEROUTER_PASSWORD} characters)"
else
  echo "password is empty - do not call login API"
fi
```

Login and save the cookie:

```bash
curl -sS -c /tmp/9router-cookie \
  -X POST \
  -H 'Content-Type: application/json' \
  -d "$(jq -n --arg password "$NINEROUTER_PASSWORD" '{password:$password}')" \
  http://127.0.0.1:8080/api/auth/login | jq
```

Expected:

```json
{
  "success": true,
  "mustChangePassword": false
}
```

## Create the alias

```bash
curl -sS -b /tmp/9router-cookie \
  -X PUT \
  -H 'Content-Type: application/json' \
  -d '{
    "alias": "gpt-5.6-sol",
    "model": "oc/mimo-v2.5-free"
  }' \
  http://127.0.0.1:8080/api/models/alias | jq
```

Expected:

```json
{
  "success": true,
  "model": "oc/mimo-v2.5-free",
  "alias": "gpt-5.6-sol"
}
```

Verify:

```bash
curl -sS -b /tmp/9router-cookie \
  http://127.0.0.1:8080/api/models/alias | jq
```

Expected mapping:

```json
{
  "aliases": {
    "gpt-5.6-sol": "oc/mimo-v2.5-free"
  }
}
```

---

# 10. Test the Desktop alias directly

Test exactly the model name Desktop sends:

```bash
curl -N http://127.0.0.1:8080/v1/responses \
  -H "Authorization: Bearer $NINEROUTER_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "gpt-5.6-sol",
    "input": "Reply exactly: Desktop alias works",
    "stream": true
  }'
```

The route should now be:

```text
gpt-5.6-sol
    |
    | 9Router alias
    v
oc/mimo-v2.5-free
    |
    v
OpenCode Free / MiMo
```

No OpenAI credentials are required for this alias route.

---

# 11. Restart Codex Desktop

After configuring the environment and alias:

1. Quit the app completely with `Cmd+Q`.
2. Reopen it.
3. Start a new Codex conversation.
4. Send `hi`.

Validated result: normal text responses work and the previous `No active credentials for provider: openai` error disappears.

The UI may still display:

```text
5.6 Sol Light
```

This is expected because Desktop selected `gpt-5.6-sol`; 9Router rewrites it after the request leaves Desktop.

---

# 12. Model self-identification is not proof of routing

If you ask:

```text
which model is this?
```

MiMo may answer something like:

```text
I'm GPT-5.
```

Do not use model self-identification as proof of the upstream model.

The request is presented as a Sol session by Codex Desktop, and the language model cannot inspect 9Router's alias database.

Use the 9Router alias configuration, logs, and routing behavior as the source of truth.

---

# 13. Desktop tool limitation

**Current observed behavior:** Desktop text inference works through the alias, but local shell/tool execution does not yet work with this MiMo route.

Example prompt:

```text
list the contents of pwd
```

Observed response:

```text
I'm unable to execute shell commands directly in this environment.
The functions.exec tool isn't available in my current context.
```

This is different from the earlier named-function curl test.

The curl test used a standard Responses function tool with an explicit name:

```json
{
  "type": "function",
  "name": "get_current_directory"
}
```

Codex uses richer Responses-native tool types for agentic workflows, including local shell tools. 9Router 0.5.55 preserves these tool types when talking to a native Codex-style upstream, but its **Responses -> Chat Completions translator** cannot directly represent unnamed hosted tools such as `local_shell` as ordinary Chat Completions functions. Such tools can therefore be omitted when the request is converted for an OpenCode/Chat-compatible upstream.

That makes the current state:

```text
Desktop text generation             ✅
Named function curl test            ✅
Desktop local shell via MiMo alias  ⚠️ not working
```

This is the next compatibility issue to solve if full Desktop agent behavior is required.

Potential implementation work in 9Router would need to bridge both directions:

```text
Responses local_shell tool
        -> Chat-compatible function representation

Chat tool call
        -> Responses local_shell_call

local_shell_call_output
        -> Chat tool result
```

A request-side conversion alone is not enough; Codex must receive the correct Responses-native call/output item types so that it knows to execute the local shell action.

---

# 14. Alias caveat

The alias is global to this 9Router instance.

With:

```text
gpt-5.6-sol -> oc/mimo-v2.5-free
```

any client using this 9Router instance and requesting `gpt-5.6-sol` will be redirected to MiMo.

Also, Desktop may construct prompts/tool configuration using Sol metadata while MiMo is the actual upstream model. Advanced model-specific behavior can differ.

---

# 15. Remove the alias

With an authenticated dashboard cookie:

```bash
curl -sS -b /tmp/9router-cookie \
  -X DELETE \
  'http://127.0.0.1:8080/api/models/alias?alias=gpt-5.6-sol' \
  | jq
```

---

# 16. Cleanup

```bash
rm -f /tmp/9router-cookie
unset NINEROUTER_PASSWORD
```

---

# 17. Troubleshooting

## `No active credentials for provider: openai`

Cause:

```text
Codex requested gpt-*
    -> 9Router inferred OpenAI
    -> no OpenAI credentials
```

CLI fix:

```bash
codex -m oc/mimo-v2.5-free
```

Desktop text-routing workaround:

```text
gpt-5.6-sol -> oc/mimo-v2.5-free
```

## `/api/models/alias` returns `Unauthorized`

The alias endpoint is an admin/dashboard API. Login through `/api/auth/login` and use the returned cookie.

## zsh: `read: -p: no coprocess`

`read -p` has different semantics in zsh.

Use:

```bash
printf 'Password: '
IFS= read -r -s PASSWORD
printf '\n'
```

## `Model metadata ... not found`

Expected for a third-party model missing from Codex's internal model catalog. Text inference can still work with fallback metadata.

## MCP startup interrupted

An MCP/plugin startup warning is separate from 9Router inference routing and should be debugged independently.

---

# Final validated state

## CLI

```text
Codex CLI
    |
    | model = oc/mimo-v2.5-free
    v
9Router /v1/responses
    v
OpenCode Free / MiMo
```

Validated: text inference.

## Desktop

```text
Codex Desktop
    |
    | displays 5.6 Sol Light
    | sends gpt-5.6-sol
    v
9Router alias
    |
    | gpt-5.6-sol -> oc/mimo-v2.5-free
    v
OpenCode Free / MiMo
```

Validated: text inference.

Not yet validated/working: Desktop local shell execution through the MiMo alias.
