# 🤖 Hermes + Claude Code CLI with Vertex AI

Bridge code for using Claude Code as the reasoning loop on Vertex AI, with
Hermes managing tool execution, conversation history, memory and skills.

| Directory | Contents |
| --- | --- |
| 🧩 [`src/`](src/) | Pilot provider, HTTP bridge, tool adapter and CLI update helper |
| 🛠️ [`development/`](development/) | Development provider, executor and Kubernetes deployment examples |
| 🔌 [`integrations/`](integrations/) | Optional MCP adapters and example configuration |
| 🧪 [`tests/`](tests/) | Offline unit tests and separate live integration scripts |

## ⚙️ Configuration

The default reasoning model is **Opus 5** (`claude-opus-5`). The development
native CLI uses `claude-opus-5[1m]`.

Use Python 3.11 or newer and provide the Claude Code CLI and Hermes runtime
required by your chosen provider. The files assume container paths such as
`/opt/hermes`, `/cli`, `/state` and `/work`; adapt those paths for local use.

Set `ANTHROPIC_VERTEX_PROJECT_ID` for Vertex AI and `GCP_PROJECT_ALLOWED` for
the executor's project restriction to your own project ID. Replace
`your-gcp-project-id` and `hermes.example.com` in
example configuration before use. Configure credentials at runtime through
environment variables or a secret manager. Keep credential files, local
configuration, conversation state and request dumps out of version control.

See the [development notes](development/README.md) for the architecture and
limitations of the deployment example. These files are examples, not a record
of a live deployment. Render the development example locally with `kubectl kustomize .`.

## ✅ Local checks

The unit tests need `jsonschema` in the active Python environment:

```sh
python3 -m pip install -r requirements-test.txt
python3 -m unittest discover -s tests -p 'test_*.py'
```

The `live_*.py` scripts contact configured services and can modify isolated test
state. Run them only against an environment you have explicitly configured for
integration testing.
