"""Hourly npm release check; may restart only the isolated development pilot."""
from __future__ import annotations
import json
import re
import ssl
from pathlib import Path
from urllib.request import Request, urlopen

DEPLOYMENT = "hermes-claude-code-pilot"
NAMESPACE = "devops-agent"
ANNOTATION = "pilot.example.com/claude-code-release"
REGISTRY = "https://registry.npmjs.org/@anthropic-ai%2fclaude-code/latest"


def release_patch(current: str, latest: str) -> dict | None:
    if not re.fullmatch(r'\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?', latest):
        raise ValueError("Invalid npm version")
    if current == latest:
        return None
    return {"spec": {"template": {"metadata": {"annotations": {ANNOTATION: latest}}}}}


def main():
    with urlopen(REGISTRY, timeout=20) as response:
        latest = json.load(response)["version"]
    credentials = Path('/var/run/secrets/kubernetes.io/serviceaccount')
    context = ssl.create_default_context(cafile=str(credentials / 'ca.crt'))
    token = (credentials / 'token').read_text().strip()
    url = f'https://kubernetes.default.svc/apis/apps/v1/namespaces/{NAMESPACE}/deployments/{DEPLOYMENT}'
    headers = {'Authorization': 'Bearer ' + token}
    with urlopen(Request(url, headers=headers), context=context, timeout=20) as response:
        deployment = json.load(response)
    current = deployment['spec']['template']['metadata'].get('annotations', {}).get(ANNOTATION, '')
    patch = release_patch(current, latest)
    if patch:
        request = Request(url, data=json.dumps(patch).encode(), method='PATCH',
                          headers={**headers, 'Content-Type': 'application/merge-patch+json'})
        with urlopen(request, context=context, timeout=20) as response:
            json.load(response)
    print(json.dumps({'deployment': DEPLOYMENT, 'previous_release': current,
                      'npm_latest': latest, 'rollout_requested': bool(patch)}))


if __name__ == '__main__':
    main()
