"""Migrate a verified combined release into two independently checked releases."""
import argparse
import base64
import concurrent.futures
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import time
import urllib.parse
import zipfile

from build_pack import safe_path
from full_pack import assemble
from import_release import download


def gh_json(repo, endpoint, data=None, method=None):
    args = ['gh', 'api', f'repos/{repo}/{endpoint}']
    if method:
        args += ['--method', method]
    if data is not None:
        args += ['--input', '-']
    r = subprocess.run(args, input=None if data is None else json.dumps(data), text=True,
                       capture_output=True, check=True)
    return json.loads(r.stdout) if r.stdout.strip() else None


def find_release(repo, tag):
    p = subprocess.run(['gh', 'release', 'view', tag, '--repo', repo,
                        '--json', 'isDraft'], capture_output=True, text=True)
    return None if p.returncode else json.loads(p.stdout)


def verify_assets(repo, tag, assets):
    release = gh_json(repo, 'releases/tags/' + tag)
    uploaded = {x['name']: x for x in release['assets']}
    if set(uploaded) != {p.name for p in assets.iterdir()}:
        raise ValueError('Release asset list differs from the three expected files')
    for p in assets.iterdir():
        with p.open('rb') as f:
            digest = hashlib.file_digest(f, 'sha256').hexdigest()
        a = uploaded[p.name]
        if a['size'] != p.stat().st_size or a.get('digest') != 'sha256:' + digest:
            raise ValueError('GitHub asset digest mismatch: ' + p.name)
    return release


def commit_manifests(repo, manifests):
    head = gh_json(repo, 'git/ref/heads/main')['object']['sha']
    tree = gh_json(repo, 'git/commits/' + head)['tree']['sha']
    entries = []
    for pack, manifest in manifests.items():
        content = json.dumps(manifest, ensure_ascii=False, indent=2) + '\n'
        blob = gh_json(repo, 'git/blobs', {'content': content, 'encoding': 'utf-8'})
        entries.append({'path': pack + '/latest.json', 'mode': '100644', 'type': 'blob', 'sha': blob['sha']})
    tree = gh_json(repo, 'git/trees', {'base_tree': tree, 'tree': entries})['sha']
    commit = gh_json(repo, 'git/commits', {'message': 'Point each launcher at its own complete ZIP release [skip ci]',
                                         'tree': tree, 'parents': [head]})['sha']
    gh_json(repo, 'git/refs/heads/main', {'sha': commit, 'force': False}, 'PATCH')
    return commit


def repack(config_file, repo):
    cfg = json.loads(config_file.read_text())
    version = cfg['version']
    source_tag = cfg['source_tag']
    if not re.fullmatch(r'\d{4}\.\d{2}\.\d{2}\.\d+', version):
        raise ValueError('Invalid version')
    complete = all((r := find_release(repo, p.lower() + '-' + version)) and not r['isDraft']
                   for p in ['Midgard', 'Helheim'])
    if complete:
        for pack in ['Midgard', 'Helheim']:
            value = gh_json(repo, 'contents/' + pack + '/latest.json?ref=main')
            current = json.loads(base64.b64decode(value['content']))
            if current.get('version') != version or len(current.get('packages', [])) != 1:
                complete = False
                break
    if complete:
        print('Both separate releases are already published and routed correctly.', flush=True)
        return {'version': version, 'already_published': True}
    source_release = gh_json(repo, 'releases/tags/' + source_tag)
    source_assets = {x['name']: x for x in source_release['assets']}
    manifests = {}
    results = {}
    with tempfile.TemporaryDirectory(prefix='separate-valheim-releases-') as temp:
        root = Path(temp)
        source = root / 'source'
        source.mkdir()
        for pack in ['Midgard', 'Helheim']:
            name = pack.lower() + '-manifest.json'
            a = source_assets[name]
            sha = a['digest'].removeprefix('sha256:')
            download(a['browser_download_url'], source / name, a['size'], sha)
            manifest = json.loads((source / name).read_text())
            assert manifest['pack_id'] == 'ammatias-' + pack.lower()
            manifests[pack] = manifest
        tasks = []
        for pack, manifest in manifests.items():
            for component in manifest['packages']:
                asset = urllib.parse.urlsplit(component['url']).path.rsplit('/', 1)[-1]
                assert asset in source_assets and asset.startswith(pack.lower() + '-') and asset.endswith('.zip')
                tasks.append((component['url'], source / asset, component['bytes'], component['sha256']))
        with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
            for i, future in enumerate(concurrent.futures.as_completed([pool.submit(download, *t) for t in tasks]), 1):
                future.result()
                print(f'Source components verified: {i}/{len(tasks)}', flush=True)
        new_manifests = {}
        for pack, old in manifests.items():
            records_and_data = []
            for component in old['packages']:
                asset = urllib.parse.urlsplit(component['url']).path.rsplit('/', 1)[-1]
                expected = {x['path']: x for x in component['files']}
                with zipfile.ZipFile(source / asset) as archive:
                    assert len(archive.infolist()) == len(expected)
                    for entry in archive.infolist():
                        name = safe_path(entry.filename).as_posix()
                        assert name in expected and not entry.is_dir()
                        data = archive.read(entry)
                        assert len(data) == expected[name]['bytes'] and hashlib.sha256(data).hexdigest() == expected[name]['sha256']
                        records_and_data.append((expected[name], data))
            output = root / pack
            new = assemble(pack, version, repo, records_and_data, output, Path(pack) / (pack + '-Modpack.bat'))
            del records_and_data
            new_manifests[pack] = new
            tag = pack.lower() + '-' + version
            release = find_release(repo, tag)
            if release is None:
                subprocess.run(['gh', 'release', 'create', tag, '--repo', repo, '--draft',
                                '--title', pack + ' ' + version, '--notes',
                                f'{pack} client pack: one ZIP with mods and BepInEx, the BAT launcher and SHA256SUMS.txt.'], check=True)
            if release is None or release['isDraft']:
                subprocess.run(['gh', 'release', 'upload', tag, '--repo', repo, '--clobber',
                                *[str(p) for p in sorted((output / 'assets').iterdir())]], check=True)
                verify_assets(repo, tag, output / 'assets')
                subprocess.run(['gh', 'release', 'edit', tag, '--repo', repo, '--draft=false', '--latest=false'], check=True)
            verified = verify_assets(repo, tag, output / 'assets')
            results[pack] = {'tag': tag, 'url': verified['html_url'], 'assets': len(verified['assets']),
                             'archive': new['packages'][0]['url'], 'sha256': new['packages'][0]['sha256'],
                             'bytes': new['packages'][0]['bytes'], 'files': len(new['packages'][0]['files'])}
        manifest_commit = commit_manifests(repo, new_manifests)
        if cfg.get('retire_source'):
            delay = min(600, max(0, int(cfg.get('retire_delay_seconds', 0))))
            if delay:
                print(f'Both pack releases are ready. Allowing {delay}s for cached older launchers before retiring the mixed release.', flush=True)
                time.sleep(delay)
            subprocess.run(['gh', 'release', 'delete', source_tag, '--repo', repo, '--yes'], check=True)
        subprocess.run(['gh', 'release', 'edit', 'helheim-' + version, '--repo', repo, '--latest'], check=True)
        return {'version': version, 'packs': results, 'manifest_commit': manifest_commit,
                'source_retired': bool(cfg.get('retire_source'))}


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('config', type=Path)
    parser.add_argument('--repo', required=True)
    args = parser.parse_args()
    report = {'success': False, 'commit': os.environ.get('GITHUB_SHA'), 'message': ''}
    try:
        report.update(repack(args.config, args.repo))
        report['success'] = True
        print(json.dumps(report), flush=True)
    except Exception as error:
        report['message'] = str(error)
        raise
    finally:
        if 'GITHUB_REPOSITORY' in os.environ:
            with tempfile.NamedTemporaryFile('w', suffix='.json', delete=False) as f:
                json.dump(report, f)
                name = f.name
            subprocess.run([sys.executable, str(Path(__file__).with_name('report_check.py')),
                            name, 'release-result.json'], check=True)
            Path(name).unlink()
