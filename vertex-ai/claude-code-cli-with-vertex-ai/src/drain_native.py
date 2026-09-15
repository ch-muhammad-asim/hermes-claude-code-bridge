import os
from urllib.request import Request, urlopen

request = Request('http://127.0.0.1:18182/drain', method='POST', data=b'',
                  headers={'Authorization': 'Bearer ' + os.environ['VERTEX_CLAUDE_BRIDGE_API_KEY']})
with urlopen(request, timeout=250) as response:
    response.read()
