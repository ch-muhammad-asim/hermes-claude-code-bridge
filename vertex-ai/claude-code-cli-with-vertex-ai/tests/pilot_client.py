"""Small synchronous MCP test client; runs in the pilot, never prints authentication."""
import json
import os
from urllib.request import Request, urlopen


class Client:
    def __init__(self):
        self.counter = 0
        self.headers = {'Authorization': 'Bearer ' + os.environ['VERTEX_CLAUDE_BRIDGE_API_KEY'],
                        'Content-Type': 'application/json', 'Accept': 'application/json, text/event-stream'}
        self.request('initialize', {'protocolVersion':'2025-03-26', 'capabilities':{},
                     'clientInfo':{'name':'pilot-validation','version':'1'}})
        self.request('notifications/initialized', {}, notification=True)

    def request(self, method, params, notification=False):
        self.counter += 1
        body = {'jsonrpc':'2.0','method':method,'params':params}
        if not notification:
            body['id'] = self.counter
        with urlopen(Request('http://127.0.0.1:19193/mcp', data=json.dumps(body).encode(),
                             headers=self.headers), timeout=180) as response:
            if response.headers.get('mcp-session-id'):
                self.headers['Mcp-Session-Id'] = response.headers['mcp-session-id']
            raw = response.read().decode()
        if notification:
            return None
        if raw.startswith('event:') or raw.startswith('data:'):
            values = [json.loads(line[6:]) for line in raw.splitlines() if line.startswith('data: ')]
            result = next(v for v in values if v.get('id') == self.counter)
        else:
            result = json.loads(raw)
        if 'error' in result:
            raise RuntimeError(result['error'])
        return result['result']

    def call(self, name, arguments):
        result = self.request('tools/call', {'name':name,'arguments':arguments})
        if result.get('isError'):
            raise RuntimeError(str(result)[:1200])
        value = result.get('structuredContent')
        if value is None:
            value = json.loads(next(c['text'] for c in result['content'] if c['type']=='text'))
        return value

    def tool(self, name, arguments):
        return self.call('hermes_call_tool', {'name':name,'arguments':arguments})
