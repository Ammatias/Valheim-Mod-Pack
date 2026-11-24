"""Build content-addressed release components from a verified Midgard client ZIP."""
import argparse
import collections
import hashlib
import json
from pathlib import Path, PurePosixPath
import re
import stat
import zipfile

ROOT_FILES = {'winhttp.dll', 'doorstop_config.ini', '.doorstop_version'}

def safe_path(name):
    p = PurePosixPath(name)
    if (p.is_absolute() or '..' in p.parts or '.' in p.parts or '\\' in name
            or re.search(r'[:*?"<>|\x00-\x1f]', name) or str(p) != name):
        raise ValueError('Unsafe ZIP path: ' + name)
    return p

def build(source, output, version, base_url, pack="Midgard"):
    output.mkdir(parents=True, exist_ok=True)
    groups = collections.defaultdict(list)
    seen = set()
    with zipfile.ZipFile(source) as archive:
        for entry in archive.infolist():
            if entry.is_dir():
                continue
            p = safe_path(entry.filename)
            if stat.S_ISLNK(entry.external_attr >> 16):
                raise ValueError('Symlink in source ZIP')
            name = p.as_posix()
            if name.casefold() in seen:
                raise ValueError('Duplicate source file: ' + name)
            seen.add(name.casefold())
            if p.name.lower() == 'passwords.json' or re.search(r'(?i)^(?:logoutput.*\.log|.*\.log\.old)$', p.name):
                continue
            if name in ROOT_FILES or name.startswith('BepInEx/core/'):
                group = 'loader'
            elif name.startswith('BepInEx/patchers/'):
                group = 'patchers'
            elif name.startswith('BepInEx/config/'):
                if re.search(r'password.*\.json$|\.bak$|\.old$|\.log$', name, re.I):
                    continue
                group = 'defaults'
            elif name.startswith('BepInEx/plugins/'):
                group = 'mod-' + p.parts[2].removesuffix('.dll')
            else:
                continue
            data = archive.read(entry)
            if name.endswith(('.cfg', '.json', '.yml', '.yaml', '.ini')):
                text = data.decode('utf-8-sig', errors='replace')
                if re.search(r'(?im)^\s*(?:password|access[_ ]?token|api[_ ]?key|secret)\s*=\s*[^\s#;]+', text):
                    raise ValueError('Populated credential setting in client package: ' + name)
            record = {'path': name, 'sha256': hashlib.sha256(data).hexdigest(),
                      'bytes': len(data), 'preserve': name.startswith('BepInEx/config/')}
            groups[group].append((record, data))
    packages = []
    ids = set()
    for key, items in sorted(groups.items()):
        package_id = pack.lower() + '-' + re.sub('[^a-z0-9]+', '-', key.lower()).strip('-')
        if package_id in ids:
            raise ValueError('Component ID collision')
        ids.add(package_id)
        items.sort(key=lambda x: x[0]['path'])
        path = output / (package_id + '.zip')
        with zipfile.ZipFile(path, 'w', zipfile.ZIP_DEFLATED, compresslevel=6) as archive:
            for record, data in items:
                info = zipfile.ZipInfo(record['path'], (2026, 1, 1, 0, 0, 0))
                info.compress_type = zipfile.ZIP_DEFLATED
                info.external_attr = 0o100644 << 16
                archive.writestr(info, data)
        sha = hashlib.sha256(path.read_bytes()).hexdigest()
        asset = package_id + '-' + sha[:16] + '.zip'
        path.rename(output / asset)
        packages.append({'id': package_id, 'sha256': sha, 'bytes': (output / asset).stat().st_size,
                         'url': base_url.rstrip('/') + '/' + asset,
                         'files': [x[0] for x in items]})
    manifest = {'schema': 1, 'pack_id': 'ammatias-' + pack.lower(), 'version': version,
                'packages': packages}
    (output / (pack.lower() + '-manifest.json')).write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + '\n')
    return manifest

if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('source', type=Path)
    parser.add_argument('output', type=Path)
    parser.add_argument('--version', required=True)
    parser.add_argument('--pack', choices=['Midgard', 'Helheim'], default='Midgard')
    parser.add_argument('--base-url', required=True)
    args = parser.parse_args()
    result = build(args.source, args.output, args.version, args.base_url, args.pack)
    print(json.dumps({'components': len(result['packages']),
                      'files': sum(len(x['files']) for x in result['packages']),
                      'download_bytes': sum(x['bytes'] for x in result['packages'])}))
