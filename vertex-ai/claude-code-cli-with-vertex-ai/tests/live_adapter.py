"""Run with pilot_client.py available. Real reads; writes only to isolated pilot state."""
from pilot_client import Client
import datetime
import json
import os
from pathlib import Path


def check(value):
    if isinstance(value, dict):
        assert not value.get('error'), str(value)[:800]
        assert not value.get('isError'), str(value)[:800]
        assert value.get('success') is not False, str(value)[:800]
        for child in value.values():
            check(child)
    elif isinstance(value, list):
        for child in value:
            check(child)
    elif isinstance(value, str) and value.startswith('{'):
        try:
            decoded = json.loads(value)
        except ValueError:
            return
        check(decoded)


project = os.environ["GCP_PROJECT_ALLOWED"]
c = Client()
status = c.call('hermes_context', {})['integrations']
assert len(status) == 4 and all(s['connected'] for s in status), status
print(json.dumps({'test':'discovery','pass':True,'servers':len(status)}))
now = datetime.datetime.now(datetime.timezone.utc)
cases = [
    ('logging', 'mcp__gcp_logging_sre_readonly__list_log_names', {'parent':f'projects/{project}','pageSize':1}),
    ('monitoring', 'mcp__gcp_monitoring_sre_readonly__list_metric_descriptors', {'name':f'projects/{project}','pageSize':1}),
    ('trace', 'mcp__gcp_trace_sre_readonly__list_traces', {'projectId':project,'pageSize':1,
        'startTime':(now-datetime.timedelta(hours=1)).isoformat(), 'endTime':now.isoformat()}),
    ('browser', 'mcp__playwright_browser__browser_navigate', {'url':'https://example.com'}),
]
failures = []
for label, name, arguments in cases:
    try:
        result = c.tool(name, arguments)
        check(result)
        if label == 'browser':
            assert 'Example Domain' in json.dumps(result), str(result)[:500]
        print(json.dumps({'test':label,'pass':True,'truncated':result.get('truncated')}), flush=True)
    except Exception as exc:
        failures.append(label)
        print(json.dumps({'test':label,'pass':False,'error':str(exc)[:800]}), flush=True)

for name in ('delegate_task','mcp__gcp_logging_sre_readonly__delete_log','terminal'):
    assert c.tool(name,{})['denied']
assert c.tool('mcp__gcp_trace_sre_readonly__list_traces', {'projectId':'other-production-project'})['denied']
print(json.dumps({'test':'mutation-recursion-and-environment-denial','pass':True}))

# Keep these synthetic fixtures across a pod replacement; cleanup in the persistence test.
marker = 'pilot-validation-' + now.strftime('%H%M%S')
check(c.tool('memory', {'action':'add','target':'memory','content':marker}))
assert marker in json.dumps(c.call('hermes_context', {}))
content = '---\nname: '+marker+'\ndescription: Use when validating the isolated pilot.\n---\n\nCheck evidence before making claims.\n'
check(c.tool('skill_manage', {'operations':[{'action':'create','name':marker,'content':content}]}))
check(c.tool('skill_manage', {'operations':[{'action':'patch','name':marker,'old_string':'Check evidence','new_string':'Verify evidence'}]}))
check(c.tool('skill_manage', {'operations':[{'action':'write_file','name':marker,'file_path':'references/check.md','file_content':'Fixture only.'}]}))
assert 'Verify evidence' in json.dumps(c.tool('skill_view', {'name':marker}))
assert 'Fixture only.' in json.dumps(c.tool('skill_view', {'name':marker,'file_path':'references/check.md'}))
Path('/state/client/validation-marker').write_text(marker)
print(json.dumps({'test':'memory-and-skill-crud','pass':True,'fixture':marker}))
assert not failures, failures
