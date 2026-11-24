"""Publish a pack update while preserving every unchanged runtime file."""
import base64
import hashlib
import json
from pathlib import Path
import re
import subprocess
import tempfile

from build_pack import safe_path
from full_pack import assemble
from import_release import download
from publish_unpacked import managed
from repack_releases import commit_manifests, find_release, gh_json, verify_assets


def collect_existing(root, manifest):
    result = {}
    for package in manifest['packages']:
        for record in package['files']:
            name = safe_path(record['path']).as_posix()
            if not managed(name) or name.casefold() in {x.casefold() for x in result}:
                raise ValueError('Unexpected/duplicate existing file')
            data = (root / name).read_bytes()
            if len(data) != record['bytes'] or hashlib.sha256(data).hexdigest() != record['sha256']:
                raise ValueError('Existing file differs from published pack: ' + name)
            result[name] = (record, data)
    return result


def add_record(items, name, data, expected_sha):
    name = safe_path(name).as_posix()
    if (not managed(name) or Path(name).name.casefold() == 'passwords.json'
            or name.casefold() in {x.casefold() for x in items}):
        raise ValueError('Addition must be a new runtime file')
    if hashlib.sha256(data).hexdigest() != expected_sha:
        raise ValueError('Addition checksum mismatch')
    record = {'path': name, 'sha256': expected_sha, 'bytes': len(data),
              'preserve': name.startswith('BepInEx/config/')}
    items[name] = (record, data)


def update(config, repo):
    pack, version = config['pack'], config['version']
    if pack not in ['Midgard', 'Helheim'] or not re.fullmatch(r'\d{4}\.\d{2}\.\d{2}\.\d+', version):
        raise ValueError('Invalid pack or version')
    tag = pack.lower() + '-' + version
    current = gh_json(repo, 'contents/' + pack + '/latest.json?ref=main')
    manifest = json.loads(base64.b64decode(current['content']))
    existing_release = find_release(repo, tag)
    if manifest.get('version') == version and existing_release and not existing_release['isDraft']:
        return {'version': version, 'pack': pack, 'already_published': True}
    if manifest.get('version') != config['base_version'] or manifest['pack_id'] != 'ammatias-' + pack.lower():
        raise ValueError('Base pack version differs from the requested update')
    folder = Path(pack)
    items = collect_existing(folder, manifest)
    with tempfile.TemporaryDirectory(prefix='valheim-pack-update-') as temp:
        work = Path(temp)
        for index, addition in enumerate(config['additions']):
            prefix = f'https://raw.githubusercontent.com/{repo}/'
            if not addition['url'].startswith(prefix):
                raise ValueError('Unexpected addition source')
            target = work / f'addition-{index}'
            download(addition['url'], target, addition['bytes'], addition['sha256'])
            add_record(items, addition['path'], target.read_bytes(), addition['sha256'])
        output = work / 'release'
        new = assemble(pack, version, repo, list(items.values()), output, folder / (pack + '-Modpack.bat'))
        if existing_release is None:
            subprocess.run(['gh', 'release', 'create', tag, '--repo', repo, '--draft',
                            '--title', pack + ' ' + version, '--notes', config['notes']], check=True)
        if existing_release is None or existing_release['isDraft']:
            subprocess.run(['gh', 'release', 'upload', tag, '--repo', repo, '--clobber',
                            *[str(p) for p in sorted((output / 'assets').iterdir())]], check=True)
            verify_assets(repo, tag, output / 'assets')
            subprocess.run(['gh', 'release', 'edit', tag, '--repo', repo, '--draft=false', '--latest'], check=True)
        verified = verify_assets(repo, tag, output / 'assets')
        manifest_commit = commit_manifests(repo, {pack: new})
        return {'version': version, 'pack': pack, 'tag': tag, 'url': verified['html_url'],
                'assets': len(verified['assets']), 'archive': new['packages'][0]['url'],
                'sha256': new['packages'][0]['sha256'], 'bytes': new['packages'][0]['bytes'],
                'files': len(new['packages'][0]['files']), 'manifest_commit': manifest_commit}
