import hashlib
import io
import json
import os
import select
import stat
import struct
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

    def env(self, workspace='workspace-a'):
        env = os.environ | {'HOME': self.home.name, 'CLIPBRIDGE_WS': workspace}
        env.pop('DISPLAY', None)
        env.pop('XAUTHORITY', None)
        return env

    def command(self, args, workspace='workspace-a', data=b''):
        return subprocess.run([sys.executable, CLI, *args], env=self.env(workspace),
                              input=data, capture_output=True, timeout=10)

    def ingest(self, fmt, data, workspace='workspace-a', progress=False):
        args = ['receive', f'--format={fmt}'] + (['--progress'] if progress else [])
        return self.command(args, workspace, data)

    def test_png_bytes_workspace_and_generated_screenshot_name(self):
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
            self.assertTrue(path.name.startswith('screenshot-'))
            self.assertEqual(path.read_bytes(), image)
            self.assertEqual(receipt['sha256'], [hashlib.sha256(image).hexdigest()])
            self.assertEqual(json.loads(self.command(['latest'], workspace).stdout), receipt)
        self.assertNotEqual(self.ingest('png', image, 'workspace-c').returncode, 0)

    def test_archive_preserves_unicode_names_tree_and_hashes(self):
        blob = io.BytesIO()
        with zipfile.ZipFile(blob, 'w') as z:
            z.writestr('相片 (最终版).PNG', b'photo')
            z.writestr('资料夹/', b'')
            z.writestr('资料夹/文档 2026.txt', b'document')
            z.writestr('资料夹/空目录/', b'')
        result = self.ingest('archive', blob.getvalue())
        self.assertEqual(result.returncode, 0, result.stderr)
        receipt = json.loads(result.stdout)
        paths = [Path(path) for path in receipt['paths']]
        self.assertEqual(receipt['count'], 2)
        self.assertEqual(paths[0].name, '相片 (最终版).PNG')
        self.assertEqual(paths[0].read_bytes(), b'photo')
        directory = next(path for path in paths if path.is_dir())
        self.assertEqual(directory.name, '资料夹')
        self.assertEqual((directory / '文档 2026.txt').read_bytes(), b'document')
        self.assertTrue((directory / '空目录').is_dir())
        batch = paths[0].parents[3]
        manifest = json.loads((batch / 'manifest.json').read_text())['items']
        self.assertIn('资料夹/文档 2026.txt', [item['source_relpath'] for item in manifest])
        self.assertTrue(all(not item['renamed'] for item in manifest))
        by_name = {item['source_name']: item for item in manifest if item['entry_type'] == 'file'}
        self.assertEqual(by_name['相片 (最终版).PNG']['sha256'], hashlib.sha256(b'photo').hexdigest())

    def test_duplicate_basenames_get_separate_parents_and_unicode_is_not_normalized(self):
        blob = io.BytesIO()
        with zipfile.ZipFile(blob, 'w') as z:
            z.writestr('0001/report.pdf', b'one')
            z.writestr('0002/report.pdf', b'two')
            z.writestr('0003/é.txt', b'nfc')
            z.writestr('0004/e\u0301.txt', b'nfd')
        result = self.ingest('archive', blob.getvalue())
        self.assertEqual(result.returncode, 0, result.stderr)
        receipt = json.loads(result.stdout)
        report_paths = [Path(e['stored_path']) for e in receipt['entries'] if e['source_name'] == 'report.pdf']
        self.assertEqual(len(report_paths), 2)
        self.assertEqual({path.name for path in report_paths}, {'report.pdf'})
        self.assertNotEqual(report_paths[0].parent, report_paths[1].parent)
        nfc, nfd = [Path(e['stored_path']).name for e in receipt['entries'] if e['source_name'].endswith('.txt')]
        self.assertNotEqual(nfc, nfd)

    def test_invalid_archives_do_not_replace_latest(self):
        original = io.BytesIO()
        with zipfile.ZipFile(original, 'w') as z:
            z.writestr('report.txt', b'good')
        valid = self.ingest('archive', original.getvalue())
        self.assertEqual(valid.returncode, 0, valid.stderr)
        latest = self.command(['latest']).stdout
        symlink = zipfile.ZipInfo('link')
        symlink.create_system = 3
        symlink.external_attr = (stat.S_IFLNK | 0o777) << 16
        for name in ('../outside', '/absolute', 'C:/drive', 'bad\\name'):
            with self.subTest(name=name):
                blob = io.BytesIO()
                with zipfile.ZipFile(blob, 'w') as z:
                    z.writestr(name, b'bad')
                result = self.ingest('archive', blob.getvalue())
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(result.stdout)
                self.assertEqual(self.command(['latest']).stdout, latest)
        blob = io.BytesIO()
        with zipfile.ZipFile(blob, 'w') as z:
            z.writestr('a', b'file')
            z.writestr('a/b', b'child')
        self.assertNotEqual(self.ingest('archive', blob.getvalue()).returncode, 0)
        self.assertEqual(self.command(['latest']).stdout, latest)
        blob = io.BytesIO()
        with zipfile.ZipFile(blob, 'w') as z:
            z.writestr(symlink, b'outside')
        self.assertNotEqual(self.ingest('archive', blob.getvalue()).returncode, 0)
        self.assertEqual(self.command(['latest']).stdout, latest)
        self.assertNotEqual(self.ingest('png', b'not a PNG').returncode, 0)

    def test_progress_reports_received_bytes_before_eof(self):
        buffer = io.BytesIO()
        Image.new('RGB', (23, 12), 'green').save(buffer, format='PNG')
        data = buffer.getvalue()
        with subprocess.Popen(
            [sys.executable, CLI, 'receive', '--format=png', '--progress'],
            env=self.env('workspace-b'), stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=subprocess.PIPE, bufsize=0,
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

    def test_stdio_persistent_channel_handles_sequential_uploads(self):
        env = self.env('workspace-a')
        process = subprocess.Popen([sys.executable, CLI, 'serve', '--stdio'], env=env,
                                   stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                   stderr=subprocess.PIPE, bufsize=0)
        self.addCleanup(lambda: process.kill() if process.poll() is None else None)

        def read_frame():
            length = struct.unpack('>I', process.stdout.read(4))[0]
            return json.loads(process.stdout.read(length))

        self.assertEqual(read_frame()['status'], 'ready')

        def send(request_id, name, data):
            header = {'version': 1, 'workspace': 'workspace-a', 'request_id': request_id,
                      'kind': 'files', 'file_count': 1,
                      'entries': [{'source_name': name, 'source_relpath': name,
                                   'entry_type': 'file', 'size': len(data),
                                   'sha256': hashlib.sha256(data).hexdigest(), 'kind': 'files'}]}
            raw = json.dumps(header, ensure_ascii=False).encode()
            process.stdin.write(b'CBR5' + struct.pack('>I', len(raw)) + raw + data)
            process.stdin.flush()
            return read_frame()

        first = send('a' * 32, '报告 1.txt', b'first')
        duplicate = send('a' * 32, '报告 1.txt', b'first')
        second = send('b' * 32, '报告 2.txt', b'second')
        receipts = [first, duplicate, second]
        self.assertTrue(all(receipt['ok'] for receipt in receipts))
        self.assertEqual(first['batch_id'], duplicate['batch_id'])
        self.assertEqual([Path(r['paths'][0]).name for r in (first, second)], ['报告 1.txt', '报告 2.txt'])
        self.assertEqual(Path(receipts[0]['paths'][0]).read_bytes(), b'first')
        self.assertEqual(Path(receipts[2]['paths'][0]).read_bytes(), b'second')
        self.assertIsNone(process.poll())
        process.stdin.close()
        self.assertEqual(process.wait(timeout=3), 0)
        process.stdout.close()
        process.stderr.close()

    def test_expired_request_id_is_rejected_after_prune(self):
        process = subprocess.Popen([sys.executable, CLI, 'serve', '--stdio'], env=self.env(),
                                   stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                   stderr=subprocess.PIPE, bufsize=0)
        length = struct.unpack('>I', process.stdout.read(4))[0]
        ready = json.loads(process.stdout.read(length))
        self.assertEqual(ready['status'], 'ready')

        def send(process, request_id, data):
            name = 'cached.txt'
            header = {'version': 1, 'workspace': 'workspace-a', 'request_id': request_id,
                      'kind': 'files', 'file_count': 1,
                      'entries': [{'source_name': name, 'source_relpath': name,
                                   'entry_type': 'file', 'size': len(data),
                                   'sha256': hashlib.sha256(data).hexdigest()}]}
            raw = json.dumps(header).encode()
            process.stdin.write(b'CBR5' + struct.pack('>I', len(raw)) + raw + data)
            process.stdin.flush()
            length = struct.unpack('>I', process.stdout.read(4))[0]
            return json.loads(process.stdout.read(length))

        receipt = send(process, 'c' * 32, b'content')
        process.stdin.close()
        self.assertEqual(process.wait(timeout=3), 0)
        process.stdout.close()
        process.stderr.close()
        batch = Path(receipt['paths'][0]).parents[3]
        old = time.time() - 25 * 3600
        os.utime(batch / 'manifest.json', (old, old))
        self.assertEqual(self.command(['prune', '--all']).returncode, 0)
        retry = subprocess.Popen([sys.executable, CLI, 'serve', '--stdio'], env=self.env(),
                                 stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                 stderr=subprocess.PIPE, bufsize=0)
        length = struct.unpack('>I', retry.stdout.read(4))[0]
        self.assertEqual(json.loads(retry.stdout.read(length))['status'], 'ready')
        response = send(retry, 'c' * 32, b'content')
        self.assertFalse(response['ok'])
        self.assertEqual(response['error'], 'EXPIRED')
        retry.stdin.close()
        self.assertEqual(retry.wait(timeout=3), 0)
        retry.stdout.close()
        retry.stderr.close()

    def test_prune_removes_expired_batches_and_keeps_latest_valid(self):
        blob = io.BytesIO()
        Image.new('RGB', (2, 2), 'blue').save(blob, format='PNG')
        first = json.loads(self.ingest('png', blob.getvalue()).stdout)
        second = json.loads(self.ingest('png', blob.getvalue()).stdout)
        first_batch = Path(first['paths'][0]).parents[3]
        second_batch = Path(second['paths'][0]).parents[3]
        old = time.time() - 25 * 3600
        os.utime(first_batch / 'manifest.json', (old, old))
        preview = self.command(['prune', '--all', '--dry-run'], workspace='workspace-a')
        self.assertEqual(preview.returncode, 0, preview.stderr)
        self.assertEqual(json.loads(preview.stdout)['removed'][0]['reason'], 'ttl')
        self.assertTrue(first_batch.exists())
        pruned = self.command(['prune', '--all'], workspace='workspace-b')
        self.assertEqual(pruned.returncode, 0, pruned.stderr)
        self.assertFalse(first_batch.exists())
        self.assertTrue(second_batch.exists())
        self.assertEqual(json.loads(self.command(['latest']).stdout)['batch_id'], second['batch_id'])
        os.utime(second_batch / 'manifest.json', (old, old))
        self.assertEqual(self.command(['prune', '--all']).returncode, 0)
        self.assertFalse(second_batch.exists())
        self.assertNotEqual(self.command(['latest']).returncode, 0)

    def test_pressure_prune_respects_recent_protection_and_hard_quota(self):
        share = Path(self.home.name) / '.local/share/clipbridge'
        batches = share / 'workspace-a/batches'
        old = batches / 'old-batch'
        recent = batches / 'recent-batch'
        for batch, filename, size in ((old, 'old.bin', 420 * 1024 * 1024),
                                      (recent, 'recent.bin', 1024 * 1024)):
            payload = batch / 'payload'
            payload.mkdir(parents=True)
            with (payload / filename).open('wb') as stream:
                stream.truncate(size)
            (batch / 'manifest.json').write_text(json.dumps({'workspace': 'workspace-a'}))
        old_time = time.time() - 2 * 3600
        os.utime(old / 'manifest.json', (old_time, old_time))
        result = self.command(['prune', '--all'])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(old.exists())
        self.assertTrue(recent.exists())

        full = batches / 'full-recent-batch'
        (full / 'payload').mkdir(parents=True)
        with (full / 'payload' / 'full.bin').open('wb') as stream:
            stream.truncate(512 * 1024 * 1024)
        (full / 'manifest.json').write_text(json.dumps({'workspace': 'workspace-a'}))
        image = io.BytesIO()
        Image.new('RGB', (2, 2), 'black').save(image, format='PNG')
        rejected = self.ingest('png', image.getvalue())
        self.assertNotEqual(rejected.returncode, 0)
        self.assertIn('QUOTA_EXCEEDED', rejected.stderr.decode())
        self.assertTrue(recent.exists())

    def test_prune_includes_legacy_v4_cache_and_updates_its_latest_pointer(self):
        root = Path(self.home.name) / '.cache/clipbridge/workspace-a'
        images = root / 'images'
        images.mkdir(parents=True)
        old = images / 'old.png'
        latest = images / 'recent.png'
        old.write_bytes(b'old')
        latest.write_bytes(b'recent')
        old_time = time.time() - 25 * 3600
        os.utime(old, (old_time, old_time))
        (root / 'latest.json').write_text(json.dumps({'path': str(old)}))
        result = self.command(['prune', '--all'])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(old.exists())
        self.assertTrue(latest.exists())
        self.assertEqual(json.loads((root / 'latest.json').read_text())['path'], str(latest))
        stats = json.loads(self.command(['stats', '--all']).stdout)
        self.assertEqual(stats['workspaces']['workspace-a']['bytes'],
                         latest.stat().st_size + (root / 'latest.json').stat().st_size)


if __name__ == '__main__':
    unittest.main()
