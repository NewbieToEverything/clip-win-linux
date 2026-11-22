#!/usr/bin/python3
"""ClipBridge v5 receiver and bounded temporary-cache manager."""
import contextlib
import datetime
import errno
import fcntl
import hashlib
import json
import os
import re
import shutil
import stat
import struct
import sys
import tempfile
import time
import unicodedata
from pathlib import Path

WORKSPACES = ('workspace-a', 'workspace-b')
MIB = 1024 * 1024
GIB = 1024 * MIB
MAGIC = b'CBR5'


def load_config():
    defaults = {
        'png_limit_mib': 15,  # Accepted for existing configs. The Windows sender limits clipboard PNGs.
        'file_limit_mib': 128, 'batch_limit_mib': 256,
        'workspace_limit_mib': 512, 'global_limit_mib': 1024, 'entry_limit': 200,
        'path_depth_limit': 32, 'ttl_hours': 24, 'recent_protection_minutes': 60,
        'staging_idle_minutes': 60, 'low_disk_free_gib': 2,
        'pressure_trigger_percent': 80, 'pressure_target_percent': 60,
        'header_limit_mib': 1, 'request_index_limit_mib': 8,
        'request_record_limit': 50000,
    }
    path = Path.home() / '.config/clipbridge/config.json'
    if path.is_symlink():
        raise ValueError('ClipBridge config must not be a symlink')
    if path.exists():
        value = json.loads(path.read_text(encoding='utf-8'))
        if not isinstance(value, dict) or set(value) - set(defaults):
            raise ValueError('Invalid ClipBridge config keys')
        defaults.update(value)
    for key, value in defaults.items():
        if not isinstance(value, int) or value < 1:
            raise ValueError(f'Invalid ClipBridge config value: {key}')
    if defaults['pressure_target_percent'] >= defaults['pressure_trigger_percent'] or defaults['pressure_trigger_percent'] > 100:
        raise ValueError('Invalid ClipBridge pressure watermarks')
    if defaults['entry_limit'] > 2000 or defaults['path_depth_limit'] > 128:
        raise ValueError('ClipBridge config exceeds safety limits')
    return defaults


_CONFIG = load_config()
FILE_LIMIT = _CONFIG['file_limit_mib'] * MIB
BATCH_LIMIT = _CONFIG['batch_limit_mib'] * MIB
WORKSPACE_LIMIT = _CONFIG['workspace_limit_mib'] * MIB
GLOBAL_LIMIT = _CONFIG['global_limit_mib'] * MIB
ENTRY_LIMIT = _CONFIG['entry_limit']
DEPTH_LIMIT = _CONFIG['path_depth_limit']
TTL = _CONFIG['ttl_hours'] * 3600
RECENT = _CONFIG['recent_protection_minutes'] * 60
STAGING_IDLE = _CONFIG['staging_idle_minutes'] * 60
LOW_DISK = _CONFIG['low_disk_free_gib'] * GIB
PRESSURE_TRIGGER = _CONFIG['pressure_trigger_percent'] / 100
PRESSURE_TARGET = _CONFIG['pressure_target_percent'] / 100
HEADER_LIMIT = _CONFIG['header_limit_mib'] * MIB
REQUEST_INDEX_LIMIT = _CONFIG['request_index_limit_mib'] * MIB
REQUEST_RECORD_LIMIT = _CONFIG['request_record_limit']


def read_exact(stream, count):
    chunks = bytearray()
    while len(chunks) < count:
        part = stream.read(count - len(chunks))
        if not part:
            if not chunks:
                return None
            raise ValueError('Truncated frame')
        chunks.extend(part)
    return bytes(chunks)


def write_frame(stream, value):
    body = json.dumps(value, ensure_ascii=True, separators=(',', ':')).encode('ascii')
    stream.write(struct.pack('>I', len(body)))
    stream.write(body)
    stream.flush()


def safe_parts(name):
    if not isinstance(name, str) or not name or '\x00' in name:
        raise ValueError('Invalid source path')
    if name.startswith('/') or re.match(r'^[A-Za-z]:', name) or name.startswith('\\'):
        raise ValueError('Absolute source paths are not allowed')
    parts = name.split('/')
    if len(parts) > DEPTH_LIMIT or len(name.encode('utf-8')) > 4096:
        raise ValueError('Source path exceeds limits')
    reserved = re.compile(r'^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\..*)?$', re.I)
    for part in parts:
        if (not part or part in ('.', '..') or len(part.encode('utf-8')) > 255 or
                part[-1] in '. ' or any(unicodedata.category(c) in ('Cc', 'Cf', 'Cs', 'Zl', 'Zp') for c in part) or
                any(c in part for c in '<>:"|?*\\') or reserved.fullmatch(part)):
            raise ValueError('Unsafe source path component')
    return parts


def cache_roots():
    share = Path.home() / '.local/share/clipbridge'
    state = Path.home() / '.local/state/clipbridge'
    return share, state


def cache_lock(state):
    state.mkdir(parents=True, exist_ok=True)
    lock = (state / 'retention.lock').open('a')
    fcntl.flock(lock, fcntl.LOCK_EX)
    return lock


def safe_tree_size(root):
    total = 0
    if root.is_symlink():
        raise ValueError('Symlink found in a managed cache root')
    if not root.exists():
        return total
    for base, dirs, files in os.walk(root, followlinks=False):
        base_path = Path(base)
        for name in list(dirs):
            path = base_path / name
            if path.is_symlink():
                dirs.remove(name)
        for name in files:
            path = base_path / name
            try:
                st = path.lstat()
            except FileNotFoundError:
                continue
            if stat.S_ISREG(st.st_mode):
                total += st.st_size
    return total


def managed_tree_size(share, workspace=None):
    return safe_tree_size(share if workspace is None else share / workspace)


def batches(share):
    for workspace in WORKSPACES:
        base = share / workspace / 'batches'
        if base.is_dir() and not base.is_symlink():
            for batch in base.iterdir():
                if batch.is_dir() and not batch.is_symlink():
                    try:
                        created = (batch / 'manifest.json').stat().st_mtime
                    except OSError:
                        created = batch.stat().st_mtime
                    yield workspace, batch, created, safe_tree_size(batch)


def request_index(share):
    path = share / 'request-index.json'
    if path.is_symlink():
        raise ValueError('Unsafe request index')
    if not path.exists():
        return path, {}
    if path.stat().st_size > REQUEST_INDEX_LIMIT:
        raise ValueError('REQUEST_INDEX_LIMIT_EXCEEDED')
    value = json.loads(path.read_text(encoding='utf-8'))
    records = value.get('requests') if isinstance(value, dict) else None
    if not isinstance(records, dict):
        raise ValueError('Invalid request index')
    return path, records


def store_request(share, request_id, workspace, batch, state_name):
    path, records = request_index(share)
    if request_id not in records and len(records) >= REQUEST_RECORD_LIMIT:
        raise ValueError('REQUEST_INDEX_LIMIT_EXCEEDED')
    records[request_id] = {'workspace': workspace, 'batch_id': batch,
                           'state': state_name, 'updated_at': int(time.time())}
    body = json.dumps({'version': 1, 'requests': records}, separators=(',', ':')).encode('utf-8')
    if len(body) > REQUEST_INDEX_LIMIT:
        raise ValueError('REQUEST_INDEX_LIMIT_EXCEEDED')
    temporary = path.with_name('.request-index.tmp')
    temporary.write_bytes(body + b'\n')
    os.replace(temporary, path)


def request_index_reserve(share, request_id, workspace, batch):
    path, records = request_index(share)
    if request_id not in records and len(records) >= REQUEST_RECORD_LIMIT:
        raise ValueError('REQUEST_INDEX_LIMIT_EXCEEDED')
    projected = dict(records)
    projected[request_id] = {'workspace': workspace, 'batch_id': batch,
                             'state': 'committed', 'updated_at': int(time.time())}
    body_size = len(json.dumps({'version': 1, 'requests': projected}, separators=(',', ':')).encode('utf-8')) + 1
    if body_size > REQUEST_INDEX_LIMIT:
        raise ValueError('REQUEST_INDEX_LIMIT_EXCEEDED')
    # store_request writes a replacement file before its atomic rename.
    return body_size


def remove_batch(share, state, workspace, batch):
    expected = (share / workspace / 'batches').resolve()
    if batch.is_symlink() or batch.parent.resolve() != expected:
        raise ValueError('Refusing to remove an unmanaged cache path')
    try:
        manifest = json.loads((batch / 'manifest.json').read_text(encoding='utf-8'))
        request_id = manifest.get('request_id')
        if isinstance(request_id, str) and re.fullmatch(r'[a-f0-9]{32}', request_id):
            store_request(share, request_id, workspace, batch.name, 'expired')
    except FileNotFoundError:
        pass
    shutil.rmtree(batch)
    latest = share / workspace / 'latest.json'
    try:
        receipt = json.loads(latest.read_text(encoding='utf-8'))
        if receipt.get('batch_id') == batch.name:
            remaining = sorted((item for item in batches(share) if item[0] == workspace),
                               key=lambda row: row[2], reverse=True)
            if remaining:
                replacement = json.loads((remaining[0][1] / 'manifest.json').read_text(encoding='utf-8'))['receipt']
                temporary = latest.with_name('.latest-prune.tmp')
                temporary.write_text(json.dumps(replacement, ensure_ascii=False) + '\n', encoding='utf-8')
                os.replace(temporary, latest)
            else:
                latest.unlink()
    except (OSError, ValueError, TypeError, KeyError):
        pass
    # Request receipts live with batches; no Agent data is inspected.


def prune_locked(share, state, dry_run=False, now=None, projected_workspace=None, projected_global=0):
    now = time.time() if now is None else now
    removed = []
    staging_cutoff = now - STAGING_IDLE
    for workspace in WORKSPACES:
        staging = share / workspace / 'staging'
        if staging.is_dir() and not staging.is_symlink():
            for item in staging.iterdir():
                try:
                    if item.is_dir() and not item.is_symlink() and item.stat().st_mtime < staging_cutoff:
                        removed.append({'workspace': workspace, 'batch_id': item.name, 'reason': 'stale-staging'})
                        if not dry_run:
                            shutil.rmtree(item)
                except FileNotFoundError:
                    continue
    entries = list(batches(share))
    for workspace, batch, created, size in entries:
        if now - created >= TTL:
            removed.append({'workspace': workspace, 'batch_id': batch.name, 'reason': 'ttl'})
            if not dry_run:
                remove_batch(share, state, workspace, batch)
    if not dry_run:
        entries = list(batches(share))
    else:
        entries = [entry for entry in entries if now - entry[2] < TTL]

    total = managed_tree_size(share)
    by_workspace = {ws: sum(size for candidate, _, _, size in entries if candidate == ws)
                    for ws in WORKSPACES}
    for workspace in WORKSPACES:
        used = by_workspace[workspace]
        projected = projected_workspace if projected_workspace is not None and workspace == os.environ.get('CLIPBRIDGE_WS') else 0
        if used + projected >= WORKSPACE_LIMIT * PRESSURE_TRIGGER:
            target = int(WORKSPACE_LIMIT * PRESSURE_TARGET)
            for candidate, item, created, size in sorted(entries, key=lambda row: row[2]):
                if candidate != workspace or now - created < RECENT or used + projected <= target:
                    continue
                removed.append({'workspace': workspace, 'batch_id': item.name, 'reason': 'workspace-pressure'})
                used -= size
                if not dry_run:
                    remove_batch(share, state, workspace, item)
    if not dry_run:
        entries = list(batches(share))
        total = managed_tree_size(share)
    if total + projected_global >= GLOBAL_LIMIT * PRESSURE_TRIGGER:
        target = int(GLOBAL_LIMIT * PRESSURE_TARGET)
        for workspace, item, created, size in sorted(entries, key=lambda row: row[2]):
            if now - created < RECENT or total + projected_global <= target:
                continue
            removed.append({'workspace': workspace, 'batch_id': item.name, 'reason': 'global-pressure'})
            total -= size
            if not dry_run:
                remove_batch(share, state, workspace, item)
    return removed


def reserve_and_prune(share, state, workspace, required):
    prune_locked(share, state, projected_workspace=required, projected_global=required)
    used_global = managed_tree_size(share)
    used_workspace = managed_tree_size(share, workspace)
    if used_global + required > GLOBAL_LIMIT or used_workspace + required > WORKSPACE_LIMIT:
        raise ValueError('QUOTA_EXCEEDED')
    if shutil.disk_usage(share).free < LOW_DISK:
        raise ValueError('LOW_DISK_SPACE')


def batch_id(request_id):
    return datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%SZ-') + request_id


def committed_receipt(share, workspace, request_id):
    index_path, records = request_index(share)
    record = records.get(request_id)
    if record:
        if record.get('state') == 'expired':
            raise ValueError('EXPIRED')
        if record.get('workspace') != workspace:
            raise ValueError('REQUEST_ID_CONFLICT')
        batch = share / workspace / 'batches' / record.get('batch_id', '')
        try:
            manifest = json.loads((batch / 'manifest.json').read_text(encoding='utf-8'))
            if manifest.get('request_id') == request_id:
                return manifest['receipt']
        except (OSError, ValueError, KeyError):
            store_request(share, request_id, workspace, str(record.get('batch_id', '')), 'expired')
            raise ValueError('EXPIRED')
    root = share / workspace / 'batches'
    for batch in root.glob(f'*-{request_id}'):
        if batch.is_symlink() or not batch.is_dir():
            continue
        manifest = json.loads((batch / 'manifest.json').read_text(encoding='utf-8'))
        if manifest.get('request_id') == request_id:
            return manifest['receipt']
    return None


def assert_same_request(receipt, entries):
    previous = receipt.get('entries', [])
    requested = []
    for entry in entries:
        name = entry.get('source_relpath') or entry.get('source_name')
        requested.append((name, entry.get('entry_type'), entry.get('size', 0),
                          entry.get('sha256'), entry.get('source_root_index')))
    committed = [(item.get('source_relpath'), item.get('entry_type'), item.get('size', 0),
                  item.get('sha256'), item.get('source_root_index')) for item in previous]
    if requested != committed:
        raise ValueError('REQUEST_ID_CONFLICT')


def receive_entries(share, state, workspace, request_id, entries, source_stream):
    if not re.fullmatch(r'[a-f0-9]{32}', request_id or ''):
        raise ValueError('Invalid request_id')
    existing = committed_receipt(share, workspace, request_id)
    if not isinstance(entries, list) or not 0 < len(entries) <= ENTRY_LIMIT:
        raise ValueError('Invalid entry count')
    checked = []
    total = 0
    seen = set()
    for index, entry in enumerate(entries):
        if not isinstance(entry, dict):
            raise ValueError('Invalid entry metadata')
        name = entry.get('source_relpath') or entry.get('source_name')
        parts = safe_parts(name)
        if entry.get('source_name') is not None and entry.get('source_name') != parts[-1]:
            raise ValueError('source_name must match the final source path component')
        kind = entry.get('entry_type')
        if kind not in ('file', 'directory'):
            raise ValueError('Invalid entry_type')
        source_root_index = entry.get('source_root_index')
        if source_root_index is not None and (not isinstance(source_root_index, int) or
                not 1 <= source_root_index <= ENTRY_LIMIT):
            raise ValueError('Invalid source_root_index')
        key = (source_root_index, tuple(parts))
        if key in seen:
            raise ValueError('Duplicate source path')
        seen.add(key)
        size = entry.get('size', 0)
        digest = entry.get('sha256')
        if kind == 'directory':
            if size != 0:
                raise ValueError('Directory entries cannot contain payload bytes')
        elif (not isinstance(size, int) or size < 0 or size > FILE_LIMIT or
              not isinstance(digest, str) or not re.fullmatch(r'[a-f0-9]{64}', digest)):
            raise ValueError('Invalid file size or sha256')
        total += size
        checked.append((entry, parts, size, digest, index))
    if total > BATCH_LIMIT:
        raise ValueError('BATCH_LIMIT_EXCEEDED')
    if existing:
        assert_same_request(existing, entries)
        return existing
    lock = cache_lock(state)
    try:
        share.mkdir(parents=True, exist_ok=True)
        existing = committed_receipt(share, workspace, request_id)
        if existing:
            assert_same_request(existing, entries)
            return existing
        # The global lock covers admission, staging, commit, and ACK for both workspaces.
        workspace_root = share / workspace
        batch = batch_id(request_id)
        metadata_reserve = request_index_reserve(share, request_id, workspace, batch)
        metadata_reserve += 4096 + sum(len('/'.join(parts).encode('utf-8')) * 2 + 512
                                       for _, parts, _, _, _ in checked)
        reserve_and_prune(share, state, workspace, total + metadata_reserve)
        staging_root = workspace_root / 'staging'
        staging_root.mkdir(parents=True, exist_ok=True)
        if staging_root.is_symlink():
            raise ValueError('Unsafe staging root')
        destination_root = workspace_root / 'batches'
        destination_root.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(prefix=request_id + '-', dir=staging_root) as temp_name:
            stage = Path(temp_name)
            payload = stage / 'payload'
            payload.mkdir()
            mapped = []
            roots = []
            root_seen = set()
            root_indexes = {}
            root_records = {}
            for entry, parts, size, expected_hash, index in checked:
                root_name = parts[0]
                source_root_index = entry.get('source_root_index')
                root_key = ('index', source_root_index) if source_root_index is not None else ('name', root_name)
                if root_key not in root_indexes:
                    root_indexes[root_key] = source_root_index or (len(root_indexes) + 1)
                    root_records[root_key] = (root_name, root_indexes[root_key])
                prefix = f'items/{root_indexes[root_key]:04d}'
                relative = Path(prefix, *parts)
                target = payload / relative
                target.parent.mkdir(parents=True, exist_ok=True)
                if entry['entry_type'] == 'directory':
                    target.mkdir(exist_ok=True)
                else:
                    digest = hashlib.sha256()
                    remaining = size
                    with target.open('xb') as output:
                        while remaining:
                            block = source_stream.read(min(1024 * 1024, remaining))
                            if not block:
                                raise ValueError('Truncated payload')
                            output.write(block)
                            digest.update(block)
                            remaining -= len(block)
                        output.flush()
                        os.fsync(output.fileno())
                    actual_hash = digest.hexdigest()
                    if actual_hash != expected_hash:
                        raise ValueError('SHA256_MISMATCH')
                if root_key not in root_seen:
                    root_seen.add(root_key)
                    roots.append(root_records[root_key])
                mapped.append({'source_name': parts[-1], 'source_relpath': '/'.join(parts),
                               'source_root_index': source_root_index,
                               'stored_path': str((destination_root / batch / 'payload' / relative)),
                               'entry_type': entry['entry_type'], 'size': size,
                               'sha256': expected_hash, 'renamed': False, 'origin': entry.get('origin', 'explorer')})
            kinds = {item[0].get('kind') for item in checked}
            kind = 'image' if kinds == {'image'} else 'files'
            paths = [str(destination_root / batch / 'payload' / 'items' / f'{number:04d}' / name)
                     for name, number in roots]
            receipt = {'ok': True, 'version': 2, 'request_id': request_id, 'batch_id': batch,
                       'workspace': workspace, 'kind': kind, 'paths': paths,
                       'count': len(roots), 'bytes': total,
                       'sha256': [item['sha256'] for item in mapped if item['entry_type'] == 'file'],
                       'entries': mapped}
            manifest = {'request_id': request_id, 'workspace': workspace,
                        'created_at': datetime.datetime.now(datetime.timezone.utc).isoformat(),
                        'receipt': receipt, 'items': mapped}
            (stage / 'manifest.json').write_text(json.dumps(manifest, ensure_ascii=False) + '\n', encoding='utf-8')
            final = destination_root / batch
            os.rename(stage, final)
        store_request(share, request_id, workspace, batch, 'committed')
        latest = workspace_root / 'latest.json'
        temporary_latest = latest.with_name(f'.latest-{request_id}.tmp')
        temporary_latest.write_text(json.dumps(receipt, ensure_ascii=False) + '\n', encoding='utf-8')
        os.replace(temporary_latest, latest)
        return receipt
    finally:
        lock.close()


def dispatch(args):
    share, state = cache_roots()
    if args in (['prune', '--all'], ['prune', '--all', '--dry-run']):
        lock = cache_lock(state)
        try:
            result = prune_locked(share, state, '--dry-run' in args)
            return {'ok': True, 'dry_run': '--dry-run' in args, 'removed': result}
        finally:
            lock.close()
    if args == ['stats', '--all']:
        total = managed_tree_size(share)
        return {'ok': True, 'global_bytes': total, 'global_limit': GLOBAL_LIMIT,
                'workspaces': {ws: {'bytes': managed_tree_size(share, ws), 'limit': WORKSPACE_LIMIT}
                               for ws in WORKSPACES}}
    workspace = os.environ.get('CLIPBRIDGE_WS')
    if workspace not in WORKSPACES:
        raise ValueError('Missing or invalid CLIPBRIDGE_WS')
    if args == ['doctor']:
        root = share / workspace / 'batches'
        root.mkdir(parents=True, exist_ok=True)
        if root.is_symlink():
            raise ValueError('Unsafe workspace path')
        with tempfile.TemporaryFile(dir=root):
            return {'ok': True, 'workspace': workspace}
    if args == ['latest']:
        latest = share / workspace / 'latest.json'
        if not latest.is_file():
            raise ValueError('No cached transfer')
        return json.loads(latest.read_text(encoding='utf-8'))
    if args == ['serve', '--stdio']:
        return serve(share, state, workspace)
    raise ValueError('Invalid ClipBridge command')


def unwrap_download_path(source):
    if not isinstance(source, str) or len(source.encode('utf-8')) > 4096:
        raise ValueError('DOWNLOAD_PATH')
    lines = source.replace('\r\n', '\n').split('\n')
    if len(lines) == 1:
        return source
    if len(lines) > 9:
        raise ValueError('DOWNLOAD_WRAP_LIMIT')
    lines = [line.strip(' \t') for line in lines]
    if (not lines[0].startswith('/') or any(not line for line in lines)
            or any(any(ord(c) < 32 or ord(c) == 127 for c in line) for line in lines)):
        raise ValueError('DOWNLOAD_PATH')

    # Terminal wrapping can remove a word separator or break inside a name.
    # Only probe exact candidates, without scanning any directories.
    for line in lines[1:]:
        if line.startswith('/') and os.path.lexists(line):
            raise ValueError('DOWNLOAD_WRAP_AMBIGUOUS')
    candidates = {lines[0]}
    for continuation in lines[1:]:
        candidates = {prefix + separator + continuation for prefix in candidates
                      for separator in ('', ' ')}
    match = None
    for candidate in candidates:
        if candidate.startswith('//') or any(part in ('', '.', '..')
                                             for part in candidate.rstrip('/').split('/')[1:]):
            continue
        try:
            os.lstat(candidate)
        except (FileNotFoundError, NotADirectoryError):
            continue
        except OSError as error:
            if error.errno == errno.ENAMETOOLONG:
                continue
            raise
        if match is not None:
            raise ValueError('DOWNLOAD_WRAP_AMBIGUOUS')
        match = candidate
    if match is None:
        raise ValueError('DOWNLOAD_WRAP_NOT_FOUND')
    return match


def send_download(out, source):
    source = unwrap_download_path(source)
    if (not isinstance(source, str) or not source.startswith('/') or source.startswith('//')
            or len(source.encode('utf-8')) > 4096):
        raise ValueError('DOWNLOAD_PATH')
    parts = source.rstrip('/').split('/')[1:]
    if not parts or any(part in ('', '.', '..') or any(ord(c) < 32 or ord(c) == 127 for c in part)
                        for part in parts):
        raise ValueError('DOWNLOAD_PATH')

    entries = []
    seen = set()
    total = 0
    flags = os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK

    with contextlib.ExitStack() as handles:
        def open_at(name, parent=None, directory=False):
            fd = os.open(name, flags | (os.O_DIRECTORY if directory else 0), dir_fd=parent)
            handles.callback(os.close, fd)
            return fd

        def collect(parent, name, relative):
            nonlocal total
            safe_parts(relative)
            key = relative.casefold()
            if key in seen:
                raise ValueError('DOWNLOAD_NAME_COLLISION')
            if len(entries) >= ENTRY_LIMIT:
                raise ValueError('DOWNLOAD_LIMIT')
            seen.add(key)
            mode = os.stat(name, dir_fd=parent, follow_symlinks=False).st_mode
            if not (stat.S_ISDIR(mode) or stat.S_ISREG(mode)):
                raise ValueError('DOWNLOAD_TYPE')
            fd = open_at(name, parent)
            info = os.fstat(fd)
            if stat.S_ISDIR(info.st_mode):
                entries.append((relative, 'directory', fd, info))
                with os.scandir(fd) as children:
                    for child in children:
                        collect(fd, child.name, f'{relative}/{child.name}')
            elif stat.S_ISREG(info.st_mode):
                total += info.st_size
                if info.st_size > FILE_LIMIT or total > BATCH_LIMIT:
                    raise ValueError('DOWNLOAD_LIMIT')
                entries.append((relative, 'file', fd, info))
            else:
                raise ValueError('DOWNLOAD_TYPE')

        parent = open_at('/', directory=True)
        for part in parts[:-1]:
            parent = open_at(part, parent, directory=True)
        collect(parent, parts[-1], parts[-1])
        write_frame(out, {'ok': True, 'status': 'download', 'bytes': total,
                          'entries': [{'path': path, 'type': kind,
                                       'size': info.st_size if kind == 'file' else 0}
                                      for path, kind, _, info in entries]})
        hashes = []
        for _, kind, fd, info in entries:
            if kind == 'directory':
                continue
            digest = hashlib.sha256()
            remaining = info.st_size
            while remaining:
                block = os.read(fd, min(remaining, 1024 * 1024))
                if not block:
                    raise ValueError('DOWNLOAD_CHANGED')
                out.write(block)
                digest.update(block)
                remaining -= len(block)
            current = os.fstat(fd)
            if (info.st_size, info.st_mtime_ns, info.st_ctime_ns) != (
                    current.st_size, current.st_mtime_ns, current.st_ctime_ns):
                raise ValueError('DOWNLOAD_CHANGED')
            hashes.append(digest.hexdigest())
        write_frame(out, {'ok': True, 'status': 'download-complete', 'sha256': hashes})


def serve(share, state, workspace):
    # Wire format: CBR5 + u32 header length + UTF-8 JSON metadata + ordered raw files;
    # response: u32 length + JSON ACK. stdout is protocol only; diagnostics use stderr.
    inp, out = sys.stdin.buffer, sys.stdout.buffer
    write_frame(out, {'ok': True, 'version': 1, 'status': 'ready', 'workspace': workspace, 'download': True})
    while True:
        magic = read_exact(inp, 4)
        if magic is None:
            return {'ok': True, 'closed': True}
        try:
            if magic != MAGIC:
                raise ValueError('Invalid protocol magic')
            raw_len = read_exact(inp, 4)
            if raw_len is None:
                raise ValueError('Truncated header length')
            header_len = struct.unpack('>I', raw_len)[0]
            if not 1 <= header_len <= HEADER_LIMIT:
                raise ValueError('Invalid header length')
            header = json.loads(read_exact(inp, header_len).decode('utf-8'))
            if header.get('version') != 1 or header.get('workspace') != workspace:
                raise ValueError('Protocol version or workspace mismatch')
            if header.get('kind') == 'download':
                send_download(out, header.get('path'))
                continue
            entries = header.get('entries')
            if (not isinstance(entries, list) or header.get('file_count') != len(entries) or
                    header.get('kind') not in ('image', 'files') or
                    any(not isinstance(item, dict) or not isinstance(item.get('source_name'), str) or
                        not isinstance(item.get('source_relpath'), str) for item in entries)):
                raise ValueError('Invalid protocol entry metadata')
            if header.get('kind') == 'image' and (len(entries) != 1 or entries[0].get('kind') != 'image'):
                raise ValueError('Invalid image request')
            lengths = [item.get('size') for item in entries]
            if any(not isinstance(size, int) or size < 0 or size > FILE_LIMIT for size in lengths):
                raise ValueError('Invalid payload length')
            class LimitedInput:
                def __init__(self, source, sizes): self.source = source; self.sizes = list(sizes); self.index = 0; self.left = self.sizes[0] if self.sizes else 0
                def read(self, n=-1):
                    while self.index < len(self.sizes):
                        if self.left == 0:
                            self.index += 1
                            if self.index < len(self.sizes): self.left = self.sizes[self.index]
                            continue
                        amount = self.left if n < 0 else min(n, self.left)
                        data = self.source.read(amount)
                        self.left -= len(data)
                        return data
                    return b''
                def drain(self):
                    while self.read(1024 * 1024):
                        pass
            payload = LimitedInput(inp, lengths)
            receipt = receive_entries(share, state, workspace, header.get('request_id'), entries, payload)
            payload.drain()
            write_frame(out, receipt)
        except Exception as error:
            detail = str(error) if isinstance(error, ValueError) else type(error).__name__
            try:
                write_frame(out, {'ok': False, 'error': detail})
            except OSError:
                return {'ok': False, 'error': 'protocol write failed'}
            print(f'clipbridge: {detail}', file=sys.stderr, flush=True)
            return {'ok': False, 'error': detail}


def main(args):
    try:
        result = dispatch(args)
        if not (args == ['serve', '--stdio']):
            print(json.dumps(result, ensure_ascii=True))
    except Exception as error:
        detail = str(error) if isinstance(error, ValueError) else type(error).__name__
        print(json.dumps({'ok': False, 'error': detail}), file=sys.stderr)
        return 1
    return 0
