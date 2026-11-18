import hashlib
import io
import json
import os
import select
import stat
import subprocess
import sys
import tempfile
import time
import unittest
import zipfile
from pathlib import Path

from PIL import Image

CLI = Path(__file__).resolve().parents[1] / 'debian/clipbridge'


class ReceiverTests(unittest.TestCase):
    def setUp(self):
        self.home = tempfile.TemporaryDirectory(dir='/tmp')
        self.addCleanup(self.home.cleanup)

    def command(self, args, workspace='workspace-a', data=b''):
        env = os.environ | {'HOME': self.home.name, 'CLIPBRIDGE_WS': workspace}
        env.pop('DISPLAY', None)
        env.pop('XAUTHORITY', None)
        return subprocess.run([sys.executable, CLI, *args], env=env,
                              input=data, capture_output=True, timeout=10)

    def ingest(self, fmt, data, workspace='workspace-a'):
        return self.command(['receive', f'--format={fmt}'], workspace, data)

    def test_png_bytes_and_routing(self):
        buffer = io.BytesIO()
        Image.new('RGB', (23, 12), 'red').save(buffer, format='PNG')
        image = buffer.getvalue()
        for workspace in ('workspace-a', 'workspace-b'):
            result = self.ingest('png', image, workspace)
            self.assertEqual(result.returncode, 0, result.stderr)
            receipt = json.loads(result.stdout)
            self.assertEqual(receipt['workspace'], workspace)
            path = Path(receipt['paths'][0])
            self.assertIn(workspace, path.parts)
            self.assertEqual(path.read_bytes(), image)
            self.assertEqual(receipt['sha256'], [hashlib.sha256(image).hexdigest()])
            self.assertEqual(json.loads(self.command(['latest'], workspace).stdout), receipt)
        self.assertNotEqual(self.ingest('png', image, 'workspace-c').returncode, 0)

    def test_progress_reports_received_bytes_before_eof(self):
        blob = io.BytesIO()
        Image.new('RGB', (23, 12), 'green').save(blob, format='PNG')
        data = blob.getvalue()
        env = os.environ | {'HOME': self.home.name, 'CLIPBRIDGE_WS': 'workspace-b'}
        with subprocess.Popen(
            [sys.executable, CLI, 'receive', '--format=png', '--progress'],
            env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            bufsize=0,
        ) as process:
            try:
                self.assertTrue(select.select([process.stderr], [], [], 4)[0])
                self.assertEqual(process.stderr.readline(), b'CLIPBRIDGE_PROGRESS 0\n')
                time.sleep(0.30)
                process.stdin.write(data[:32])
                self.assertTrue(select.select([process.stderr], [], [], 4)[0])
                self.assertEqual(process.stderr.readline(), b'CLIPBRIDGE_PROGRESS 32\n')
                process.stdin.write(data[32:])
                stdout, stderr = process.communicate(timeout=5)
            finally:
                if process.poll() is None:
                    process.kill()
        self.assertEqual(process.returncode, 0, stderr)
        self.assertEqual(stderr, f'CLIPBRIDGE_PROGRESS {len(data)}\n'.encode())
        self.assertEqual(json.loads(stdout)['bytes'], len(data))

    def test_archive_files_folders_unicode_and_manifest(self):
        blob = io.BytesIO()
        with zipfile.ZipFile(blob, 'w') as z:
            z.writestr('相片.PNG', b'photo')
            z.writestr('资料夹/', b'')
            z.writestr('资料夹/文档.txt', b'document')
            z.writestr('资料夹/空目录/', b'')
        result = self.ingest('archive', blob.getvalue())
        self.assertEqual(result.returncode, 0, result.stderr)
        receipt = json.loads(result.stdout)
        paths = [Path(path) for path in receipt['paths']]
        self.assertEqual(receipt['count'], 2)
        root = paths[0].parent.parent
        manifest = json.loads((root / 'manifest.json').read_text())['items']
        self.assertIn('资料夹/文档.txt', [item['original_name'] for item in manifest])
        directory = next(path for path in paths if path.is_dir())
        self.assertEqual((directory / '文档.txt').read_bytes(), b'document')
        self.assertTrue((directory / '空目录').is_dir())
        self.assertEqual(next(path for path in paths if path.is_file()).suffix, '.png')

    def test_invalid_archives_do_not_replace_latest(self):
        original = io.BytesIO()
        with zipfile.ZipFile(original, 'w') as z:
            z.writestr('report.txt', b'good')
        valid = self.ingest('archive', original.getvalue())
        self.assertEqual(valid.returncode, 0, valid.stderr)
        symlink = zipfile.ZipInfo('link')
        symlink.create_system = 3
        symlink.external_attr = (stat.S_IFLNK | 0o777) << 16
        for names in (('../outside',), ('/absolute',), ('C:/drive',), ('a', 'A'),
                      ('é', 'e\u0301'), ('a', 'a/b'), (symlink,)):
            with self.subTest(names=names):
                blob = io.BytesIO()
                with zipfile.ZipFile(blob, 'w') as z:
                    for name in names:
                        z.writestr(name, b'bad')
                result = self.ingest('archive', blob.getvalue())
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(result.stdout)
                self.assertFalse(json.loads(result.stderr)['ok'])
                self.assertEqual(self.command(['latest']).stdout, valid.stdout)
        self.assertNotEqual(self.ingest('png', b'not a PNG').returncode, 0)


if __name__ == '__main__':
    unittest.main()
