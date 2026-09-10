"""Initialize separate persistent pilot state; never copy working-agent conversations."""
import copy
import json
import os
from pathlib import Path
import yaml

state = Path('/state')
for name in ('hermes', 'client', 'compare', 'native', 'hermes/skills', 'hermes/memories'):
    (state / name).mkdir(parents=True, exist_ok=True)
common = {
    'model': {'default': 'claude-opus-5', 'provider': 'pilot-native',
              'base_url': 'http://127.0.0.1:18182/v1', 'api_mode': 'chat_completions'},
    'providers': {'pilot-native': {'base_url': 'http://127.0.0.1:18182/v1',
                  'api_key': os.environ['VERTEX_CLAUDE_BRIDGE_API_KEY']},
                  # Comparison baseline: direct Vertex, no Claude Code. Used only by /state/compare.
                  'vertex-direct': {'base_url': 'http://127.0.0.1:18183/v1',
                  'api_key': os.environ['VERTEX_CLAUDE_BRIDGE_API_KEY']}},
    'memory': {'memory_enabled': True, 'user_profile_enabled': True, 'write_approval': False},
    'skills': {'write_approval': False},
    'platforms': {}, 'hooks': {},
    'auxiliary': {'background_review': {'enabled': False}, 'title_generation': {'enabled': False}},
    'agent': {'max_turns': 2},
    'toolsets': {'cli': [], 'gateway': []},
}
MCP_TOOLSETS = ['mcp-gcp-logging-sre-readonly',
                'mcp-gcp-monitoring-sre-readonly', 'mcp-gcp-trace-sre-readonly', 'mcp-playwright-browser']
for name in ('hermes', 'client', 'compare'):
    config = copy.deepcopy(common)
    config['mcp_servers'] = (json.loads(Path('/integrations/mcp_servers.json').read_text())
                             if name in ('hermes', 'compare') else {})
    soul = ('# Combined development pilot\n\n'
            'Claude Code runs the task loop through the configured provider on Vertex AI. '
            'Hermes owns integration execution, memory and skills. External writes are denied. '
            'Answer from real tool evidence, report uncertainty, and never fabricate actions.\n')
    if name == 'compare':
        # Hermes-alone comparison arm: same model/effort/integrations via direct Vertex, Hermes
        # iterates its own tool calls (hence max_turns), memory off so arms do not cross-contaminate.
        config['model'] = {'default': 'claude-opus-5', 'provider': 'vertex-direct',
                           'base_url': 'http://127.0.0.1:18183/v1', 'api_mode': 'chat_completions'}
        config['memory'] = {'memory_enabled': False, 'user_profile_enabled': False, 'write_approval': False}
        config['agent'] = {'max_turns': 16}
        config['toolsets'] = {'cli': MCP_TOOLSETS + ['skills', 'memory'], 'gateway': []}
        soul = ('# Comparison baseline (Hermes alone)\n\n'
                'You run the task loop directly on Vertex AI with the same integration tools. '
                'External writes are denied. Answer from real tool evidence, report uncertainty, '
                'and never fabricate actions.\n')
    path = state / name / 'config.yaml'
    path.write_text(yaml.safe_dump(config))
    path.chmod(0o600)
    (state / name / 'SOUL.md').write_text(soul)
for owner in ('client', 'compare'):
    for name in ('memories', 'skills'):
        link = state / owner / name
        if not link.exists():
            link.symlink_to('../hermes/' + name, target_is_directory=True)
# Completion marker belongs to this process generation, not a previous pod.
(state / 'hermes' / 'discovery.json').unlink(missing_ok=True)
