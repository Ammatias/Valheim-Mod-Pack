"""Check byte preservation and scope when mirroring release archives."""
import hashlib
import json
from pathlib import Path
import sys
import tempfile
import unittest
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tools'))
from publish_unpacked import apply_pack, extract_verified


class UnpackedTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)

    def tearDown(self):
        self.temp.cleanup()

    def fixture(self, items):
        archive = self.root / 'pack.zip'
        with zipfile.ZipFile(archive, 'w') as source:
            for name, data in items.items():
                source.writestr(name, data)
        records = [{'path': name, 'bytes': len(data), 'sha256': hashlib.sha256(data).hexdigest()}
                   for name, data in items.items()]
        manifest = {'schema': 1, 'pack_id': 'ammatias-midgard', 'packages': [
            {'files': records, 'bytes': archive.stat().st_size,
             'sha256': hashlib.sha256(archive.read_bytes()).hexdigest()}]}
        return manifest, archive

    def test_exact_bytes_and_pruning_without_removing_repository_documents(self):
        items = {'winhttp.dll': b'\x00loader\xff', 'BepInEx/config/mod.cfg': b'enabled=true\r\n',
                 'BepInEx/plugins/Example/texture.png': b'\x89PNG\r\n'}
        manifest, archive = self.fixture(items)
        stage = self.root / 'stage'
        stage.mkdir()
        extract_verified('Midgard', manifest, [archive], stage)
        folder = self.root / 'repository/Midgard'
        (folder / 'BepInEx/plugins').mkdir(parents=True)
        (folder / 'BepInEx/plugins/old.dll').write_bytes(b'old')
        for name in ['README.md', 'latest.json', 'Midgard-Modpack.bat']:
            (folder / name).write_bytes(b'keep')
        apply_pack(folder, stage)
        self.assertFalse((folder / 'BepInEx/plugins/old.dll').exists())
        for name, data in items.items():
            self.assertEqual((folder / name).read_bytes(), data)
        for name in ['README.md', 'latest.json', 'Midgard-Modpack.bat']:
            self.assertEqual((folder / name).read_bytes(), b'keep')

    def test_valid_archive_digest_cannot_hide_changed_file_bytes(self):
        manifest, archive = self.fixture({'BepInEx/plugins/mod.dll': b'wrong'})
        manifest['packages'][0]['files'][0]['sha256'] = hashlib.sha256(b'right').hexdigest()
        with self.assertRaisesRegex(ValueError, 'Runtime file hash mismatch'):
            extract_verified('Midgard', manifest, [archive], self.root / 'stage')

    def test_traversal_and_unmanaged_files_are_rejected(self):
        for name in ['../outside', 'worlds_local/world.db', 'README.md']:
            manifest, archive = self.fixture({name: b'not runtime'})
            with self.assertRaises(ValueError):
                extract_verified('Midgard', manifest, [archive], self.root / 'stage')
        self.assertFalse((self.root / 'outside').exists())
