import datetime
import hashlib
import json
import os
import re
import signal
import stat
import sys
import tempfile
import time
import unicodedata
import uuid
import zipfile
from pathlib import Path

WORKSPACES = ('workspace-a', 'workspace-b')
MIB = 1024 * 1024
ARCHIVE_LIMIT = 200 * MIB
ENTRY_LIMIT = 2000


def timeout(*_):
    raise ValueError('Upload timed out')


def copy(source, target, limit, progress=None):
    checksum = hashlib.sha256()
    size = 0
    read = source.read1 if progress else source.read
    block_size = 64 * 1024 if progress else MIB
    reported = 0
    last_report = time.monotonic()
    if progress:
        progress(0)
    while block := read(block_size):
        size += len(block)
        if size > limit:
            raise ValueError('Size limit exceeded')
        target.write(block)
        checksum.update(block)
        if progress and time.monotonic() - last_report >= 0.25:
            progress(size)
            reported = size
            last_report = time.monotonic()
    if progress and size != reported:
        progress(size)
    return size, checksum.hexdigest()


def archive_items(stream, payload):
    entries = {}
    total = 0
    with zipfile.ZipFile(stream) as archive:
        infos = archive.infolist()
        if not 0 < len(infos) <= ENTRY_LIMIT:
            raise ValueError('Invalid archive entry count')
        for info in infos:
            name = info.orig_filename.rstrip('/')
            parts = name.split('/')
            if (len(parts) > 32 or len(name.encode()) > 2048 or
                any(not part or part in ('.', '..') or part[-1] in '. ' or
                    len(part.encode()) > 255 or re.search(r'[\\:<>|?*"\x00-\x1f\x7f]', part) or
                    re.fullmatch(r'(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\..*)?', part, re.I)
                    for part in parts)):
                raise ValueError('Unsafe archive path')
            kind = stat.S_IFMT(info.external_attr >> 16)
            if kind not in (0, stat.S_IFDIR if info.is_dir() else stat.S_IFREG):
                raise ValueError('Unsupported archive entry type')
            key = tuple(unicodedata.normalize('NFC', part).casefold() for part in parts)
            if key in entries:
                raise ValueError('Duplicate archive path')
            entries[key] = (parts, info)
            total += info.file_size
            if total > ARCHIVE_LIMIT or (info.is_dir() and info.file_size):
                raise ValueError('Archive expansion limit exceeded')
        roots = {}
        manifest = []
        remaining = ARCHIVE_LIMIT
        for key, (parts, info) in sorted(entries.items()):
            for length in range(1, len(key)):
                parent = entries.get(key[:length])
                if parent is None or parent[0] != parts[:length] or not parent[1].is_dir():
                    raise ValueError('Invalid archive directory tree')
            if len(parts) == 1:
                suffix = Path(parts[0]).suffix.lower()
                if not re.fullmatch(r'\.[a-z0-9]{1,12}', suffix):
                    suffix = ''
                index = len(roots) + 1
                roots[key[0]] = f'd{index:03d}' if info.is_dir() else f'f{index:03d}{suffix}'
            relative = Path(roots[key[0]], *parts[1:])
            destination = payload / relative
            item = {'original_name': '/'.join(parts), 'stored_name': relative.as_posix(),
                    'directory': info.is_dir()}
            if info.is_dir():
                destination.mkdir()
            else:
                with archive.open(info) as source, destination.open('xb') as target:
                    size, digest = copy(source, target, remaining)
                remaining -= size
                item.update(size=size, sha256=digest)
            manifest.append(item)
    return list(roots.values()), manifest


def write_json(path, value):
    path.write_text(json.dumps(value, ensure_ascii=False) + '\n', encoding='utf-8')


def report_received(size):
    print(f'CLIPBRIDGE_PROGRESS {size}', file=sys.stderr, flush=True)


def receive(root, workspace, kind, progress=False):
    signal.signal(signal.SIGALRM, timeout)
    signal.alarm(120)
    batch_id = datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%SZ-') + uuid.uuid4().hex
    staging = root / 'staging'
    destination_dir = root / ('images' if kind == 'png' else 'batches')
    staging.mkdir(parents=True, exist_ok=True)
    destination_dir.mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(dir=staging) as temporary:
        temporary = Path(temporary)
        with (temporary / 'input').open('w+b') as blob:
            limit = 15 * MIB if kind == 'png' else ARCHIVE_LIMIT
            size, digest = copy(sys.stdin.buffer, blob, limit, report_received if progress else None)
            blob.seek(0)
            if kind == 'png':
                from PIL import Image
                with Image.open(blob, formats=['PNG']) as image:
                    if image.width * image.height > 25_000_000 or image.n_frames != 1:
                        raise ValueError('Invalid PNG dimensions or frame count')
                    image.verify()
                blob.seek(0)
                with Image.open(blob, formats=['PNG']) as image:
                    image.load()
                destination = destination_dir / f'i-{batch_id}.png'
                source = temporary / 'input'
                paths = [str(destination)]
            else:
                source = temporary / 'batch'
                payload = source / 'payload'
                payload.mkdir(parents=True)
                roots, manifest = archive_items(blob, payload)
                write_json(source / 'manifest.json', {'items': manifest})
                destination = destination_dir / batch_id
                paths = [str(destination / 'payload' / name) for name in roots]
        receipt = {'ok': True, 'version': 1, 'workspace': workspace, 'batch_id': batch_id,
                   'kind': 'image' if kind == 'png' else 'archive', 'paths': paths,
                   'count': len(paths), 'sha256': [digest], 'bytes': size}
        write_json(temporary / 'latest', receipt)
        source.rename(destination)
        (temporary / 'latest').replace(root / 'latest.json')
    signal.alarm(0)
    return receipt


def dispatch(args):
    workspace = os.environ.get('CLIPBRIDGE_WS')
    if workspace not in WORKSPACES:
        raise ValueError('Missing or invalid CLIPBRIDGE_WS')
    root = Path.home() / '.local/share/clipbridge' / workspace
    if not re.fullmatch(r'/[a-zA-Z0-9_./-]+', str(root)):
        raise ValueError('Workspace path cannot be pasted safely')
    if args == ['doctor']:
        root.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryFile(dir=root):
            return {'ok': True, 'workspace': workspace}
    if args == ['latest']:
        return json.loads((root / 'latest.json').read_text())
    progress = args[-1:] == ['--progress']
    if progress:
        args = args[:-1]
    formats = {('receive', '--format', 'png'): 'png', ('receive', '--format', 'archive'): 'archive',
               ('receive', '--format=png'): 'png', ('receive', '--format=archive'): 'archive'}
    if tuple(args) not in formats:
        raise ValueError('Invalid path-first command')
    return receive(root, workspace, formats[tuple(args)], progress)


def main(args):
    try:
        print(json.dumps(dispatch(args), ensure_ascii=True))
    except Exception as error:
        detail = str(error) if isinstance(error, ValueError) else type(error).__name__
        print(json.dumps({'ok': False, 'error': detail}), file=sys.stderr)
        return 1
    return 0
