"""Regression checks for verification before a draft is published."""
import hashlib
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tools'))
from repack_releases import verify_assets


class DraftVerificationTests(unittest.TestCase):
    def test_draft_assets_are_checked_via_release_list(self):
        with tempfile.TemporaryDirectory() as temp:
            assets = Path(temp)
            for name in ['Midgard.zip', 'Midgard-Modpack.bat', 'SHA256SUMS.txt']:
                (assets / name).write_bytes(name.encode())
            uploaded = [{'name': p.name, 'size': p.stat().st_size,
                         'digest': 'sha256:' + hashlib.sha256(p.read_bytes()).hexdigest()}
                        for p in assets.iterdir()]
            draft = {'tag_name': 'midgard-test', 'draft': True, 'assets': uploaded}
            with patch('repack_releases.gh_json', return_value=[draft]) as api:
                self.assertEqual(verify_assets('owner/repo', 'midgard-test', assets), draft)
                self.assertIn('releases?per_page=', api.call_args.args[1])
            uploaded[0]['digest'] = 'sha256:' + '0' * 64
            with patch('repack_releases.gh_json', return_value=[draft]):
                with self.assertRaisesRegex(ValueError, 'digest mismatch'):
                    verify_assets('owner/repo', 'midgard-test', assets)
