"""Publish only this suite's non-secret test outcome on a separate CI branch."""
import base64
import json
import os
from pathlib import Path
import sys
import urllib.error
import urllib.request

repo = os.environ['GITHUB_REPOSITORY']
base = 'https://api.github.com/repos/' + repo
token = os.environ['GH_TOKEN']
def request(path, data=None):
    body = None if data is None else json.dumps(data).encode()
    req = urllib.request.Request(base + path, data=body,
        headers={'Authorization': 'Bearer ' + token, 'Accept': 'application/vnd.github+json',
                 'Content-Type': 'application/json', 'User-Agent': 'Valheim-Pack-Checks'})
    if data is not None: req.method = 'PUT' if path.startswith('/contents/') else 'POST'
    with urllib.request.urlopen(req, timeout=30) as response: return json.load(response)

try:
    request('/git/ref/heads/ci-results')
except urllib.error.HTTPError as e:
    if e.code != 404: raise
    request('/git/refs', {'ref': 'refs/heads/ci-results', 'sha': os.environ['GITHUB_SHA']})
report_name = sys.argv[2] if len(sys.argv) > 2 else 'windows-result.json'
if report_name not in ['windows-result.json', 'release-result.json', 'unpacked-result.json']:
    raise ValueError('Unexpected report name')
path = '/contents/' + report_name
data = {'message': 'Record Valheim automation result', 'branch': 'ci-results',
        'content': base64.b64encode(Path(sys.argv[1]).read_bytes()).decode()}
try:
    data['sha'] = request(path + '?ref=ci-results')['sha']
except urllib.error.HTTPError as e:
    if e.code != 404: raise
request(path, data)
print('Outcome recorded on ci-results/' + report_name)
