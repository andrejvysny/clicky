#!/usr/bin/env bash
set -euo pipefail
clicky_repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
clicky_archive_path="${1:-/tmp/clicky-mac-source.tar.gz}"
python3 - "$clicky_repository_root" "$clicky_archive_path" <<'PY'
import hashlib
import pathlib
import subprocess
import sys
import tarfile

root = pathlib.Path(sys.argv[1]).resolve()
output = pathlib.Path(sys.argv[2]).resolve()
root_files = {'.gitignore', 'AGENTS.md', 'README.md', 'LICENSE', 'Package.swift'}
source_directories = {'leanring-buddy', 'leanring-buddy.xcodeproj', 'leanring-buddyTests',
                      'leanring-buddyUITests', 'Tests', 'Tools', 'docs', 'scripts'}
listed = subprocess.check_output(['git', '-C', str(root), 'ls-files', '-z', '--cached', '--others', '--exclude-standard'])
files = []
for name in sorted(set(listed.decode().split('\0')) - {''}):
    relative = pathlib.PurePosixPath(name)
    if name not in root_files and relative.parts[0] not in source_directories:
        continue
    if any(part in {'xcuserdata', '.build', '.swiftpm', '.git', 'node_modules'} for part in relative.parts):
        continue
    if relative.name.startswith(('.env', '.dev.vars')) or relative.suffix in {'.pem', '.key', '.p12'}:
        continue
    path = root / name
    if not path.is_file():
        continue  # Ignore tracked files that have been deleted in the working tree.
    if not path.resolve().is_relative_to(root):
        raise SystemExit('Cannot package a source symlink outside the checkout.')
    files.append((name, path))

output.parent.mkdir(parents=True, exist_ok=True)
with tarfile.open(output, 'w:gz') as archive:
    for name, path in files:
        info = archive.gettarinfo(str(path), arcname='clicky/' + name)
        info.uid = info.gid = 0
        info.uname = info.gname = ''
        if info.isfile():
            with path.open('rb') as source:
                archive.addfile(info, source)
        else:
            archive.addfile(info)
digest = hashlib.sha256(output.read_bytes()).hexdigest()
checksum = output.with_name(output.name + '.sha256')
checksum.write_text(digest + '  ' + output.name + '\n')
print(f'Packaged {len(files)} source files: {output}')
print(f'SHA-256: {digest}')
PY
