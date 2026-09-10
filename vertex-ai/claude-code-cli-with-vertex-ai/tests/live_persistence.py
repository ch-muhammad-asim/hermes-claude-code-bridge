"""Run after replacing the pod that executed live_adapter.py and the native smoke task."""
from pilot_client import Client
import json
from pathlib import Path

c = Client()
marker_file = Path('/state/client/validation-marker')
marker = marker_file.read_text()
assert marker in json.dumps(c.call('hermes_context', {}))
assert 'Verify evidence' in json.dumps(c.tool('skill_view', {'name':marker}))
assert 'Fixture only.' in json.dumps(c.tool('skill_view', {'name':marker,'file_path':'references/check.md'}))
assert 'pilot-native-smoke' in json.dumps(c.tool('skill_view', {'name':'pilot-native-smoke'}))
proof = Path('/state/native/workspace/pilot-native-proof.txt')
assert proof.read_text() == 'native-file-ok'
print(json.dumps({'test':'replacement-pod-persistence','pass':True,
                  'verified':['memory','skill','skill-reference','native-created-skill','native-file']}))
for name in (marker, 'pilot-native-smoke'):
    result = c.tool('skill_manage', {'operations':[{'action':'delete','name':name}]})
    assert 'error' not in result and result.get('result',{}).get('success') is not False, result
result = c.tool('memory', {'action':'remove','target':'memory','old_text':marker})
assert marker not in json.dumps(c.call('hermes_context', {})), result
proof.unlink()
marker_file.unlink()
print(json.dumps({'test':'synthetic-fixture-cleanup','pass':True}))
