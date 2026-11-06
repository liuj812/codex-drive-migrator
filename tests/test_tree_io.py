import json
import os
from pathlib import Path
import tempfile
import unittest

from tree_io import extended, handle_request, remove_backup, verify


class VerificationTests(unittest.TestCase):
    def setUp(self):
        self.fixture = tempfile.TemporaryDirectory(prefix='tree-io-', dir=Path(__file__).resolve().parent)
        self.root = Path(self.fixture.name)
        self.left = self.root / 'left'
        self.right = self.root / 'right'
        self.left.mkdir()
        self.right.mkdir()

    def tearDown(self):
        self.fixture.cleanup()

    def test_same_size_corruption_is_rejected(self):
        (self.left / 'db').write_bytes(b'one')
        (self.right / 'db').write_bytes(b'two')
        with self.assertRaisesRegex(ValueError, 'Hash mismatch'):
            verify(str(self.left), str(self.right))

    def test_wal_is_verified_but_shm_is_transient(self):
        for parent in (self.left, self.right):
            (parent / 'state.sqlite').write_bytes(b'database')
            (parent / 'state.sqlite-wal').write_bytes(b'pending transactions')
        (self.left / 'state.sqlite-shm').write_bytes(b'transient index')
        self.assertEqual(verify(str(self.left), str(self.right))['files'], 2)
        (self.right / 'state.sqlite-wal').write_bytes(b'corruption')
        with self.assertRaises(ValueError):
            verify(str(self.left), str(self.right))

    def test_empty_files_and_missing_directories(self):
        for parent in (self.left, self.right):
            (parent / 'empty.guard').touch()
        (self.left / 'empty-directory').mkdir()
        with self.assertRaises(FileNotFoundError):
            verify(str(self.left), str(self.right))
        (self.right / 'empty-directory').mkdir()
        self.assertEqual(verify(str(self.left), str(self.right))['files'], 1)

    def test_cleanup_rejects_unrelated_root(self):
        with self.assertRaises(ValueError):
            remove_backup(str(self.left), str(self.left), str(self.right), str(self.root), str(self.root), str(self.root))
        self.assertTrue(self.left.exists())

    def test_request_encoding_and_atomic_result(self):
        request = self.root / '请求.json'
        result = self.root / '结果.json'
        request.write_text(json.dumps({'operation': 'verify', 'paths': [str(self.left), str(self.right)], 'result': str(result)}), encoding='utf-8-sig')
        self.assertEqual(handle_request(str(request)), 0)
        self.assertEqual(json.loads(result.read_text(encoding='utf-8'))['event'], 'result')
        self.assertFalse(Path(str(result) + '.tmp').exists())

    @unittest.skipUnless(os.name == 'nt', 'NTFS junction test')
    def test_destination_junction_is_rejected(self):
        import subprocess
        target = self.root / 'outside'
        target.mkdir()
        (self.left / 'folder').mkdir()
        subprocess.run(['cmd', '/d', '/c', 'mklink', '/J', str(self.right / 'folder'), str(target)], check=True, capture_output=True)
        try:
            with self.assertRaisesRegex(ValueError, 'Unexpected target link'):
                verify(str(self.left), str(self.right))
        finally:
            os.rmdir(self.right / 'folder')


if __name__ == '__main__':
    unittest.main()
