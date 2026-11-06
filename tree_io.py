"""Long-path verification and guarded backup cleanup for the Codex migration."""
import hashlib
import json
import os
import re
import shutil
import stat
import sys
import time


def emit(**value):
    print(json.dumps(value, ensure_ascii=True), flush=True)


def extended(path):
    path = os.path.abspath(path)
    return path if path.startswith('\\\\?\\') else '\\\\?\\' + path


def digest(path):
    h = hashlib.sha256()
    with open(path, 'rb') as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b''):
            h.update(chunk)
    return h.digest()


def reparse(info):
    return bool(getattr(info, 'st_file_attributes', 0) & stat.FILE_ATTRIBUTE_REPARSE_POINT)


def verify(source, target):
    source, target = extended(source), extended(target)
    stack = [(source, target)]
    files = size = links = 0
    last = time.monotonic()
    while stack:
        left, right = stack.pop()
        with os.scandir(left) as entries:
            for entry in entries:
                if entry.name.endswith('.sqlite-shm'):
                    continue
                destination = os.path.join(right, entry.name)
                original = entry.stat(follow_symlinks=False)
                copied = os.stat(destination, follow_symlinks=False)
                if reparse(original):
                    if not reparse(copied) or os.readlink(entry.path) != os.readlink(destination):
                        raise ValueError('Link mismatch: ' + entry.name)
                    links += 1
                elif reparse(copied):
                    raise ValueError('Unexpected target link: ' + entry.name)
                elif stat.S_ISDIR(original.st_mode):
                    if not stat.S_ISDIR(copied.st_mode):
                        raise ValueError('Directory mismatch: ' + entry.name)
                    stack.append((entry.path, destination))
                else:
                    if not stat.S_ISREG(copied.st_mode) or original.st_size != copied.st_size:
                        raise ValueError('File size/type mismatch: ' + entry.name)
                    if original.st_size and digest(entry.path) != digest(destination):
                        raise ValueError('Hash mismatch: ' + entry.name)
                    files += 1
                    size += original.st_size
                if time.monotonic() - last >= 15:
                    emit(event='progress', files=files, bytes=size)
                    last = time.monotonic()
    return dict(files=files, bytes=size, links=links)


def remove_backup(backup, source, target, profile, destination_root, record_dir):
    backup, source, target = map(os.path.abspath, (backup, source, target))
    if not source.casefold().startswith(os.path.abspath(profile).casefold().rstrip('\\') + '\\'):
        raise ValueError('Unapproved source root')
    if not target.casefold().startswith(os.path.abspath(destination_root).casefold().rstrip('\\') + '\\'):
        raise ValueError('Unapproved destination root')
    if not backup.startswith(source) or not re.fullmatch(r'\.codex-migration-[a-f0-9]{32}', backup[len(source):]):
        raise ValueError('Unapproved backup name')
    if os.path.normcase(os.path.realpath(source)) != os.path.normcase(os.path.realpath(target)):
        raise ValueError('Source junction does not point at the destination')
    records = []
    for name in os.listdir(record_dir):
        if name.startswith('transaction-') and name.endswith('.json'):
            with open(os.path.join(record_dir, name), encoding='utf-8-sig') as handle:
                records.append(json.load(handle))
    if not any(r.get('source') == source and r.get('destination') == target and r.get('backup') == backup
               and r.get('phase') == 'linked_backup_retained' for r in records):
        raise ValueError('No matching migration transaction')
    root = extended(backup)
    if reparse(os.lstat(root)):
        raise ValueError('Backup root cannot be a link')
    checked = verify(backup, target)
    if checked['links']:
        raise ValueError('Backup contains links; retain it for review')
    # Inspect every node including excluded SQLite indexes before recursive deletion.
    for directory, dirs, names in os.walk(root, followlinks=False):
        for name in dirs + names:
            if reparse(os.lstat(os.path.join(directory, name))):
                raise ValueError('Backup contains a reparse point')
    def writable_retry(function, path, exception):
        os.chmod(path, stat.S_IWRITE)
        function(path)
    shutil.rmtree(root, onerror=writable_retry)
    return checked


def handle_request(request_path):
    global emit
    with open(request_path, encoding='utf-8-sig') as handle:
        request = json.load(handle)
    result_path = request['result']
    def save(**value):
        temporary = result_path + '.tmp'
        with open(temporary, 'w', encoding='utf-8') as handle:
            json.dump(value, handle, ensure_ascii=True)
        os.replace(temporary, result_path)
    emit = save
    try:
        if request['operation'] == 'verify':
            result = verify(*request['paths'])
        elif request['operation'] == 'remove-backup':
            result = remove_backup(*request['paths'], request['profile'], request['destination'], request['records'])
        else:
            raise ValueError('Unknown helper operation')
        save(event='result', **result)
        return 0
    except Exception as error:
        save(event='error', message=str(error))
        return 1
