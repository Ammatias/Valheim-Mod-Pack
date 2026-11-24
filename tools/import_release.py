"""Publish prebuilt, hashed components through the runner's normal GitHub token.

The transfer URL supplies only public modpack files. No NAS credentials are used.
Existing published tags are immutable; a failed upload stays a draft.
"""
import argparse
import concurrent.futures
import hashlib
import json
from pathlib import Path
import re
import subprocess
import tempfile
import urllib.parse
import urllib.request

def download(url, destination, size=None, sha=None):
    if not url.startswith('https://'):
        raise ValueError('HTTPS is required')
    h = hashlib.sha256()
    length = 0
    with urllib.request.urlopen(url, timeout=120) as response, destination.open('wb') as output:
        while data := response.read(1024 * 1024):
            length += len(data)
            if length > (size if size is not None else 5 * 1024 * 1024):
                raise ValueError('Download exceeds declared size')
            output.write(data)
            h.update(data)
    if size is not None and length != size or sha is not None and h.hexdigest() != sha:
        raise ValueError('Transfer checksum/size mismatch: ' + destination.name)

def publish(config_file, repo):
    config = json.loads(config_file.read_text())
    version = config['version']
    if not re.fullmatch(r'\d{4}\.\d{2}\.\d{2}\.\d+', version):
        raise ValueError('Invalid version')
    tag = 'pack-' + version
    existing = subprocess.run(['gh', 'release', 'view', tag, '--repo', repo, '--json', 'isDraft'], capture_output=True, text=True)
    if existing.returncode == 0 and not json.loads(existing.stdout)['isDraft']:
        print('Published version already exists; leaving it unchanged.')
        return
    with tempfile.TemporaryDirectory(prefix='valheim-release-') as temp:
        root = Path(temp)
        downloads = []
        for pack in ['Midgard', 'Helheim']:
            source = config['sources'][pack.lower()]
            manifest_file = root / (pack.lower() + '-manifest.json')
            download(source, manifest_file)
            manifest = json.loads(manifest_file.read_text())
            if manifest.get('schema') != 1 or manifest.get('pack_id') != 'ammatias-' + pack.lower() or manifest.get('version') != version:
                raise ValueError('Unexpected source manifest')
            prefix = f'https://github.com/{repo}/releases/download/{tag}/'
            transfer_prefix = source.rsplit('/', 1)[0] + '/'
            for package in manifest['packages']:
                asset = urllib.parse.urlsplit(package['url']).path.rsplit('/', 1)[-1]
                if not re.fullmatch(pack.lower() + r'-[a-z0-9-]+-[a-f0-9]{16}\.zip', asset):
                    raise ValueError('Unsafe asset name')
                if package['url'] != prefix + asset or not re.fullmatch(r'[a-f0-9]{64}', package['sha256']):
                    raise ValueError('Invalid asset metadata')
                downloads.append((transfer_prefix + asset, root / asset, package['bytes'], package['sha256']))
        with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
            futures = [pool.submit(download, *args) for args in downloads]
            for index, future in enumerate(concurrent.futures.as_completed(futures), 1):
                future.result()
                print(f'Verified {index}/{len(futures)} components', flush=True)
        if existing.returncode != 0:
            subprocess.run(['gh', 'release', 'create', tag, '--repo', repo, '--draft', '--title', 'Valheim Mod Pack ' + version,
                            '--notes', 'Midgard and Helheim client packs. Download the matching BAT and place it next to valheim.exe in a separate game folder.'], check=True)
        assets = [str(x) for x in sorted(root.iterdir())]
        assets += [str(Path(pack) / (pack + '-Modpack.bat')) for pack in ['Midgard', 'Helheim']]
        subprocess.run(['gh', 'release', 'upload', tag, '--repo', repo, '--clobber', *assets], check=True)
        subprocess.run(['gh', 'release', 'edit', tag, '--repo', repo, '--draft=false', '--latest'], check=True)
        print('Release published: https://github.com/' + repo + '/releases/tag/' + tag, flush=True)

if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('config', type=Path)
    parser.add_argument('--repo', required=True)
    args = parser.parse_args()
    publish(args.config, args.repo)
