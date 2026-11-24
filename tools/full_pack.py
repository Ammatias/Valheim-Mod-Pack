"""Create one complete client ZIP, a BAT and SHA256SUMS.txt for a pack release."""
import hashlib
import json
from pathlib import Path
import shutil
import zipfile


def assemble(pack, version, repo, records_and_data, output, launcher):
    output.mkdir(parents=True, exist_ok=True)
    assets = output / 'assets'
    assets.mkdir(exist_ok=True)
    archive = assets / f'{pack}-Modpack-{version}.zip'
    records = []
    seen = set()
    with zipfile.ZipFile(archive, 'w', zipfile.ZIP_DEFLATED, compresslevel=6) as z:
        for record, data in sorted(records_and_data, key=lambda x: x[0]['path']):
            name = record['path']
            if name.casefold() in seen or hashlib.sha256(data).hexdigest() != record['sha256'] or len(data) != record['bytes']:
                raise ValueError('Duplicate/changed pack file: ' + name)
            seen.add(name.casefold())
            info = zipfile.ZipInfo(name, (2026, 1, 1, 0, 0, 0))
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = 0o100644 << 16
            z.writestr(info, data)
            records.append(record)
    with zipfile.ZipFile(archive) as z:
        if z.testzip() is not None or len(z.infolist()) != len(records):
            raise ValueError('Combined ZIP verification failed')
    with archive.open('rb') as f:
        archive_sha = hashlib.file_digest(f, 'sha256').hexdigest()
    launcher_out = assets / f'{pack}-Modpack.bat'
    shutil.copyfile(launcher, launcher_out)
    launcher_sha = hashlib.sha256(launcher_out.read_bytes()).hexdigest()
    (assets / 'SHA256SUMS.txt').write_text(
        f'{archive_sha}  {archive.name}\n{launcher_sha}  {launcher_out.name}\n', encoding='ascii')
    tag = pack.lower() + '-' + version
    manifest = {'schema': 1, 'pack_id': 'ammatias-' + pack.lower(), 'version': version,
                'packages': [{'id': pack.lower() + '-full', 'bytes': archive.stat().st_size,
                              'sha256': archive_sha,
                              'url': f'https://github.com/{repo}/releases/download/{tag}/{archive.name}',
                              'files': records}]}
    (output / 'latest.json').write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + '\n')
    return manifest
