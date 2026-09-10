"""Authenticated protocol/error and streamed-usage smoke test in the pilot only."""
import json
import os
from urllib.request import Request, urlopen
from urllib.error import HTTPError

key = os.environ['VERTEX_CLAUDE_BRIDGE_API_KEY']
def post(url, body, token=key):
    return urlopen(Request(url, data=json.dumps(body).encode(), headers={
        'Authorization':'Bearer '+token,'Content-Type':'application/json',
        'Accept':'application/json, text/event-stream'}), timeout=270)

for url in ('http://127.0.0.1:18182/v1/chat/completions','http://127.0.0.1:19193/mcp'):
    try:
        post(url, {}, 'invalid')
        raise AssertionError('Unauthenticated request succeeded')
    except HTTPError as exc:
        assert exc.code == 401, exc.code
try:
    post('http://127.0.0.1:18182/v1/chat/completions', {'messages':[{'role':'user',
        'content':[{'type':'image_url','image_url':{'url':'data:test'}}]}]})
    raise AssertionError('Image silently accepted')
except HTTPError as exc:
    assert exc.code == 400
print(json.dumps({'test':'live-auth-and-unsupported-input','pass':True}), flush=True)

with post('http://127.0.0.1:18182/v1/chat/completions', {'model':'claude-opus-5','stream':True,
          'messages':[{'role':'user','content':'What is 2+2? Answer with one word. Do not use tools.'}]}) as response:
    chunks = [json.loads(line[6:]) for line in response.read().decode().splitlines()
              if line.startswith('data: ') and line != 'data: [DONE]']
answer = ''.join(c.get('delta',{}).get('content','') for chunk in chunks for c in chunk.get('choices',[]))
usage = chunks[-1]['usage']
assert answer.strip().lower().rstrip('.') in ('four','4'), answer
assert usage['completion_tokens'] > 0 and usage['total_tokens'] == usage['prompt_tokens'] + usage['completion_tokens']
print(json.dumps({'test':'sse-control-and-usage','pass':True,'answer':answer,'usage':usage}))
