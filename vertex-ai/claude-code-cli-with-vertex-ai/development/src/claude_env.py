"""Sanitized child environment for the native Claude Code process (development Vertex AI only)."""
import os

PROJECT = os.environ.get('ANTHROPIC_VERTEX_PROJECT_ID', 'your-gcp-project-id')
# MODEL is the name Hermes uses (config.yaml model.default and the /v1/models listing).
MODEL = os.environ.get('ANTHROPIC_MODEL', 'claude-opus-5')
# CLI_MODEL is what the Claude Code process is started with. The bare id gives the CLI a 200k
# window on Vertex; the `[1m]` variant gives 1,000,000 (verified 2026-09-10: modelUsage
# contextWindow 1000000, canonicalModel claude-opus-5). Hermes is pinned to 1M and compacts at
# 20%, so prompts stay under the 200k long-context pricing step in normal operation.
CLI_MODEL = os.environ.get('NATIVE_CLI_MODEL', MODEL + '[1m]')
CLI = os.environ.get('CLAUDE_BIN', '/cli/node_modules/.bin/claude')


def child_environment(home: str) -> dict:
    # No inherited login, provider override, API key, proxy, integration credential or
    # credential-file path. Configure metadata-based Vertex ADC for the deployment.
    return {
        'PATH': '/usr/local/bin:/usr/bin:/bin',
        'HOME': home,
        'CLAUDE_CONFIG_DIR': home + '/.claude',
        'TMPDIR': home,
        'CLAUDE_CODE_USE_VERTEX': '1',
        'ANTHROPIC_VERTEX_PROJECT_ID': PROJECT,
        'GOOGLE_CLOUD_PROJECT': PROJECT,
        'GCLOUD_PROJECT': PROJECT,
        'CLOUD_ML_REGION': os.environ.get('CLOUD_ML_REGION', 'global'),
        'ANTHROPIC_MODEL': CLI_MODEL,
        'ANTHROPIC_DEFAULT_OPUS_MODEL': CLI_MODEL,
        'ANTHROPIC_DEFAULT_SONNET_MODEL': 'claude-sonnet-4-6',
        'ANTHROPIC_DEFAULT_HAIKU_MODEL': 'claude-sonnet-4-6',
        'CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC': '1',
        'DISABLE_AUTOUPDATER': '1',
        'ENABLE_PROMPT_CACHING_1H': '1',
    }
