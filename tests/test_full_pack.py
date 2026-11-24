import hashlib
import json
from pathlib import Path
import sys
import tempfile
import unittest
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tools'))
from full_pack import assemble
from build_pack import build


class FullPackTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.bat = self.root / 'Midgard-Modpack.bat'
        self.bat.write_bytes(b'@echo off\r\n')

    def tearDown(self):
        self.temp.cleanup()

    def item(self, name, data):
        return ({'path': name, 'bytes': len(data), 'sha256': hashlib.sha256(data).hexdigest(),
                 'preserve': name.startswith('BepInEx/config/')}, data)

    def test_release_has_only_zip_bat_and_correct_checksums(self):
        items = [self.item('BepInEx/plugins/example.dll', b'plugin'), self.item('winhttp.dll', b'loader')]
        output = self.root / 'release'
        m = assemble('Midgard', '2026.11.24.2', 'Ammatias/Valheim-Mod-Pack', items, output, self.bat)
        files = {x.name for x in (output / 'assets').iterdir()}
        self.assertEqual(files, {'Midgard-Modpack-2026.11.24.2.zip', 'Midgard-Modpack.bat', 'SHA256SUMS.txt'})
        for line in (output / 'assets/SHA256SUMS.txt').read_text().splitlines():
            sha, name = line.split('  ')
            self.assertEqual(hashlib.sha256((output / 'assets' / name).read_bytes()).hexdigest(), sha)
        self.assertEqual(len(m['packages']), 1)
        archive = output / 'assets/Midgard-Modpack-2026.11.24.2.zip'
        with zipfile.ZipFile(archive) as z:
            self.assertEqual(set(z.namelist()), {'BepInEx/plugins/example.dll', 'winhttp.dll'})
            self.assertEqual(z.read('winhttp.dll'), b'loader')
        self.assertEqual(m, json.loads((output / 'latest.json').read_text()))
        self.assertIn('/midgard-2026.11.24.2/', m['packages'][0]['url'])

    def test_modified_source_and_case_duplicate_are_rejected(self):
        r, data = self.item('winhttp.dll', b'original')
        with self.assertRaises(ValueError):
            assemble('Midgard', 'v', 'o/r', [(r, b'changed')], self.root / 'bad', self.bat)
        with self.assertRaises(ValueError):
            assemble('Midgard', 'v', 'o/r', [self.item('winhttp.dll', b'a'), self.item('Winhttp.dll', b'b')],
                     self.root / 'duplicate', self.bat)

    def test_builder_omits_worlds_password_storage_and_other_work_files(self):
        source = self.root / 'source.zip'
        with zipfile.ZipFile(source, 'w') as z:
            z.writestr('winhttp.dll', b'loader')
            z.writestr('BepInEx/plugins/mod.dll', b'mod')
            z.writestr('BepInEx/config/mod.cfg', b'enabled=true')
            z.writestr('BepInEx/config/passwords.json', b'private')
            z.writestr('worlds_local/world.db', b'world')
            z.writestr('_backups/old.zip', b'old')
        output = self.root / 'filtered'
        m = build(source, output, '2026.11.24.2',
                  'https://github.com/Ammatias/Valheim-Mod-Pack/releases/download/midgard-2026.11.24.2', 'Midgard')
        names = {x['path'] for x in m['packages'][0]['files']}
        self.assertEqual(names, {'winhttp.dll', 'BepInEx/plugins/mod.dll', 'BepInEx/config/mod.cfg'})

    def test_builder_refuses_populated_credentials_and_traversal(self):
        for name, data in [('BepInEx/config/mod.cfg', b'password=private'), ('../outside.dll', b'escape')]:
            source = self.root / 'bad-source.zip'
            with zipfile.ZipFile(source, 'w') as z:
                z.writestr(name, data)
            with self.assertRaises(ValueError):
                build(source, self.root / 'bad-build', '2026.11.24.2',
                      'https://github.com/Ammatias/Valheim-Mod-Pack/releases/download/midgard-2026.11.24.2', 'Midgard')


if __name__ == '__main__':
    unittest.main()
