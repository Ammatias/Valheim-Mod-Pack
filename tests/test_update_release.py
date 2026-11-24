"""Verify that adding a mod cannot silently alter existing pack files."""
import hashlib
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tools'))
from update_release import add_record, collect_existing


class UpdateReleaseTests(unittest.TestCase):
    def test_addition_keeps_original_records_and_bytes(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            (root / 'BepInEx/config').mkdir(parents=True)
            data = b'enabled = true\r\n'
            (root / 'BepInEx/config/mod.cfg').write_bytes(data)
            record = {'path': 'BepInEx/config/mod.cfg', 'bytes': len(data),
                      'sha256': hashlib.sha256(data).hexdigest(), 'preserve': True}
            manifest = {'packages': [{'files': [record]}]}
            items = collect_existing(root, manifest)
            plugin = b'plugin'
            add_record(items, 'BepInEx/plugins/AutoServerPassword.dll', plugin, hashlib.sha256(plugin).hexdigest())
            self.assertEqual(items[record['path']], (record, data))
            self.assertEqual(len(items), 2)
            self.assertFalse(items['BepInEx/plugins/AutoServerPassword.dll'][0]['preserve'])
            (root / record['path']).write_bytes(b'modified')
            with self.assertRaisesRegex(ValueError, 'differs from published pack'):
                collect_existing(root, manifest)

    def test_reject_overwrite_password_store_and_hash_mismatch(self):
        original = b'original'
        sha = hashlib.sha256(original).hexdigest()
        items = {}
        add_record(items, 'BepInEx/plugins/mod.dll', original, sha)
        for name in ['BepInEx/plugins/MOD.dll', 'BepInEx/config/passwords.json', '../outside']:
            with self.assertRaises(ValueError):
                add_record(items, name, original, sha)
        with self.assertRaisesRegex(ValueError, 'checksum mismatch'):
            add_record(items, 'BepInEx/plugins/other.dll', b'wrong', sha)
