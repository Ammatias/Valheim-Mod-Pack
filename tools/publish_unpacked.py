"""Publish byte-verified, unpacked client packs in their repository folders."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import sys
import tempfile

from build_pack import ROOT_FILES, safe_path
from file_inventory import write_inventory
from import_release import download

PACKS = ('Midgard', 'Helheim')
MANAGED_DIRS = ('BepInEx/core', 'BepInEx/plugins', 'BepInEx/patchers', 'BepInEx/config')
LFS_THRESHOLD = 100 * 1024 * 1024


def managed(name):
    return name in ROOT_FILES or any(name.startswith(folder + '/') for folder in MANAGED_DIRS)


def extract_verified(pack, manifest, archives, destination):
    import zipfile
    if manifest.get('schema') != 1 or manifest.get('pack_id') != 'ammatias-' + pack.lower():
        raise ValueError('Wrong pack manifest')
    if len(archives) != len(manifest['packages']) or not archives:
        raise ValueError('Missing archives')
    seen = set()
    records = []
    for package, archive in zip(manifest['packages'], archives):
        with archive.open('rb') as stream:
            digest = hashlib.file_digest(stream, 'sha256').hexdigest()
        if archive.stat().st_size != package['bytes'] or digest != package['sha256']:
            raise ValueError('Archive checksum/size mismatch')
        expected = {}
        for record in package['files']:
            name = safe_path(record['path']).as_posix()
            if not managed(name) or name.casefold() in seen or record['bytes'] < 0:
                raise ValueError('Unexpected/duplicate runtime path: ' + name)
            seen.add(name.casefold())
            expected[name] = record
        with zipfile.ZipFile(archive) as source:
            if len(source.infolist()) != len(expected):
                raise ValueError('Archive entry count differs from manifest')
            extracted = set()
            for entry in source.infolist():
                name = safe_path(entry.filename).as_posix()
                if name not in expected or name in extracted or entry.is_dir() or stat.S_ISLNK(entry.external_attr >> 16):
                    raise ValueError('Unexpected archive entry: ' + name)
                record = expected[name]
                if entry.file_size != record['bytes']:
                    raise ValueError('Archive entry size differs from manifest')
                target = destination / name
                target.parent.mkdir(parents=True, exist_ok=True)
                digest = hashlib.sha256()
                with source.open(entry) as incoming, target.open('wb') as outgoing:
                    while data := incoming.read(1024 * 1024):
                        digest.update(data)
                        outgoing.write(data)
                if target.stat().st_size != record['bytes'] or digest.hexdigest() != record['sha256']:
                    raise ValueError('Runtime file hash mismatch: ' + name)
                extracted.add(name)
        records.extend(package['files'])
    return records


def apply_pack(folder, stage):
    # Replace only directories and root files owned by the pack. Keep its
    # launcher, README, version metadata and other repository documents.
    for name in MANAGED_DIRS:
        target = folder / name
        if target.exists():
            shutil.rmtree(target)
    for name in ROOT_FILES:
        (folder / name).unlink(missing_ok=True)
    shutil.copytree(stage, folder, dirs_exist_ok=True)


def publish(root, repo):
    result = {}
    lfs_paths = []
    with tempfile.TemporaryDirectory(prefix='unpacked-valheim-') as temp:
        work = Path(temp)
        for pack in PACKS:
            manifest = json.loads((root / pack / 'latest.json').read_text(encoding='utf-8'))
            archives = []
            for index, package in enumerate(manifest['packages']):
                prefix = f'https://github.com/{repo}/releases/download/'
                if not package['url'].startswith(prefix) or not re.fullmatch(r'[a-f0-9]{64}', package['sha256']):
                    raise ValueError('Unexpected archive source')
                archive = work / f'{pack}-{index}.zip'
                download(package['url'], archive, package['bytes'], package['sha256'])
                archives.append(archive)
            stage = work / pack
            stage.mkdir()
            records = extract_verified(pack, manifest, archives, stage)
            lfs_paths.extend(pack + '/' + f['path'] for f in records if f['bytes'] > LFS_THRESHOLD)
            result[pack] = {'version': manifest['version'], 'files': len(records),
                            'bytes': sum(f['bytes'] for f in records)}
            print(f'{pack}: all {len(records)} unpacked files verified.', flush=True)
        # Both packs are fully verified before the working tree is changed.
        for pack in PACKS:
            apply_pack(root / pack, work / pack)
            manifest = json.loads((root / pack / 'latest.json').read_text(encoding='utf-8'))
            write_inventory(pack, manifest, root / pack / 'FILES.md')
        attributes = ['# Large DLLs use Git LFS; text and other assets remain ordinary files.',
                      '/Midgard/** -text', '/Helheim/** -text']
        attributes.extend(json.dumps(name) + ' filter=lfs diff=lfs merge=lfs -text'
                          for name in sorted(lfs_paths))
        (root / '.gitattributes').write_text('\n'.join(attributes) + '\n', encoding='utf-8')
        git = lambda *args, **kwargs: subprocess.run(['git', '-C', str(root), *args], check=True, **kwargs)
        git('lfs', 'install', '--local')
        git('config', 'user.name', 'github-actions[bot]')
        git('config', 'user.email', '41898282+github-actions[bot]@users.noreply.github.com')
        git('add', '-A', '--', '.gitattributes', *PACKS)
        git('lfs', 'fsck')
        changed = subprocess.run(['git', '-C', str(root), 'diff', '--cached', '--quiet']).returncode
        if changed not in (0, 1):
            raise RuntimeError('Cannot inspect staged files')
        if changed:
            git('commit', '-m', 'Publish unpacked Midgard and Helheim files [skip ci]')
            git('push', 'origin', 'HEAD:main')
        commit = git('rev-parse', 'HEAD', capture_output=True, text=True).stdout.strip()
        remote = git('ls-remote', 'origin', 'refs/heads/main', capture_output=True, text=True).stdout.split()[0]
        if remote != commit:
            raise ValueError('Remote branch differs from the verified publication')
        return {'packs': result, 'mirror_commit': commit, 'large_file_paths': lfs_paths}


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--repo', required=True)
    parser.add_argument('--root', type=Path, default=Path.cwd())
    args = parser.parse_args()
    report = {'success': False, 'commit': os.environ.get('GITHUB_SHA'), 'message': ''}
    try:
        report.update(publish(args.root, args.repo))
        report['success'] = True
    except Exception as error:
        report['message'] = str(error)
        raise
    finally:
        if 'GITHUB_REPOSITORY' in os.environ:
            with tempfile.NamedTemporaryFile('w', suffix='.json', delete=False) as stream:
                json.dump(report, stream)
                name = stream.name
            subprocess.run([sys.executable, str(Path(__file__).with_name('report_check.py')),
                            name, 'unpacked-result.json'], check=True)
            Path(name).unlink()
