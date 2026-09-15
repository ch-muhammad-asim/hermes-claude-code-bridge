"""preStop: stop accepting new Hermes requests and wait briefly for the running native task."""
import os
from urllib.request import Request, urlopen

port = os.environ.get('NATIVE_PROVIDER_PORT', '18184')
request = Request(f'http://127.0.0.1:{port}/drain', method='POST', data=b'',
                  headers={'Authorization': 'Bearer ' + os.environ['VERTEX_CLAUDE_BRIDGE_API_KEY']})
try:
    with urlopen(request, timeout=25) as response:
        response.read()
except Exception:
    pass  # best effort; the pod's grace period bounds the wait
