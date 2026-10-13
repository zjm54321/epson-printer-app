#!/usr/bin/env bash
set -euo pipefail
# Source-built SONAMEs live here, consistently ahead of Noble multiarch libs.
export LD_LIBRARY_PATH=/usr/lib
python3 - <<'PY'
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess

root = Path('/runtime')
manifest = Path('/corresponding-source/manifests')
packages = {}
base = Path('/usr/share/epson-printer-app/base-packages.tsv').read_text()
for line in base.splitlines():
    package, version, source, source_version = line.split('\t')
    packages[(package, version)] = (source, source_version)

def package_for(path):
    # Noble merged-/usr ownership records may use either spelling.
    candidates = [str(path), os.path.realpath(path)]
    candidates += [p.removeprefix('/usr') for p in candidates if p.startswith('/usr/lib/')]
    for candidate in dict.fromkeys(candidates):
        result = subprocess.run(['dpkg-query', '-S', candidate], text=True, capture_output=True)
        if result.returncode == 0:
            for line in result.stdout.splitlines():
                if ': ' not in line or line.startswith('diversion '):
                    continue
                owner = line.split(': ', 1)[0]
                text = subprocess.check_output(['dpkg-query', '-W', '-f=${Package}\t${Version}\t${source:Package}\t${source:Version}', owner], text=True)
                package, version, source, source_version = text.split('\t')
                packages[(package, version)] = (source, source_version)
                copyright = Path('/usr/share/doc') / package / 'copyright'
                if copyright.is_file():
                    # Distro doc directories may be symlinks (e.g. libgcc-s1).
                    # Do not overlay them with real directories during OCI COPY.
                    for target in (
                        root / 'usr/share/licenses/epson-printer-app/ubuntu' / package / 'copyright',
                        manifest.parent / 'licenses/ubuntu' / package / 'copyright',
                    ):
                        target.parent.mkdir(parents=True, exist_ok=True)
                        shutil.copyfile(copyright, target)
                return
    raise SystemExit('unattributed distro dependency: ' + str(path))

def copy_library(path):
    source = Path(path)
    real = source.resolve()
    # /lib is a symlink in Noble. Do not create a competing /runtime/lib directory.
    name = source.parent.resolve() / source.name
    for target in (real, name):
        destination = root / str(target).lstrip('/')
        destination.parent.mkdir(parents=True, exist_ok=True)
        if not destination.exists() and not destination.is_symlink():
            if target == real:
                shutil.copyfile(real, destination)
                shutil.copymode(real, destination)
            else:
                destination.symlink_to(os.path.relpath(real, name.parent))
    package_for(source)

elf_files = []
for path in sorted(root.rglob('*')):
    # PDF payloads are copied as opaque assets, never opened for ELF inspection.
    if path.suffix.lower() == '.pdf':
        continue
    if path.is_file() and not path.is_symlink():
        with path.open('rb') as stream:
            if stream.read(4) == b'\x7fELF':
                elf_files.append(path)
resolution = []
for path in elf_files:
    result = subprocess.run(['ldd', str(path)], text=True, capture_output=True)
    if result.returncode or 'not found' in result.stdout:
        raise SystemExit('unresolved ELF dependency: ' + str(path) + '\n' + result.stdout + result.stderr)
    resolution.append(str(path.relative_to(root)) + '\n' + result.stdout)
    for library in re.findall(r'(?:=>\s+|^\s*)(/[^\s]+)', result.stdout, re.MULTILINE):
        if re.match(r'/usr/lib/lib(?:cups|pappl|ppd)', library):
            staged = root / library.lstrip('/')
            if not staged.exists():
                raise SystemExit('source-built library missing from stage: ' + library)
            continue
        if re.search(r'/lib(?:cups|pappl|ppd)', library):
            raise SystemExit('distro library shadows a source build: ' + library)
        copy_library(library)

# The selected external poppler converter is also redistributed.
package_for(Path('/usr/bin/pdftops'))
manifest.joinpath('runtime-packages.tsv').write_text(''.join(
    '\t'.join((package, version, source, source_version)) + '\n'
    for (package, version), (source, source_version) in sorted(packages.items())))
manifest.joinpath('elf-resolution-build.txt').write_text('\n'.join(resolution))
hashes = []
for path in sorted((root / 'usr/lib').glob('lib*.so*')):
    if path.is_file() and not path.is_symlink():
        hashes.append(hashlib.sha256(path.read_bytes()).hexdigest() + '  /' + str(path.relative_to(root)))
manifest.joinpath('source-libraries.sha256').write_text('\n'.join(hashes) + '\n')

# Preserve upstream license notices with their original source-relative names.
for source in Path('/src').iterdir():
    for path in source.rglob('*'):
        if '.git' in path.parts or not path.is_file() or path.is_symlink():
            continue
        if re.match(r'^(copying|copyright|license|licence|notice)(\.|$)', path.name, re.IGNORECASE):
            relative = path.relative_to(source)
            destination = Path('/corresponding-source/licenses/upstream') / source.name / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(path, destination)
            runtime_notice = root / 'usr/share/licenses/epson-printer-app' / source.name / relative
            runtime_notice.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(path, runtime_notice)
data = root / 'usr/share/epson-printer-app'
data.mkdir(parents=True, exist_ok=True)
for path in manifest.iterdir():
    shutil.copyfile(path, data / path.name)
for name in ('sources.lock.json', 'THIRD_PARTY.md'):
    shutil.copyfile(Path('/recipe') / name, data / name)
PY
