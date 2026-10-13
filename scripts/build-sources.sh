#!/usr/bin/env bash
set -euo pipefail
# Enable source indexes from exactly the same signed Ubuntu suites as binaries.
python3 - <<'PY'
from pathlib import Path
for path in Path('/etc/apt/sources.list.d').glob('*.sources'):
    text = path.read_text()
    lines = []
    for line in text.splitlines():
        if line.startswith('Types:') and 'deb-src' not in line.split():
            line += ' deb-src'
        lines.append(line)
    path.write_text('\n'.join(lines) + '\n')
PY
apt-get update
python3 - <<'PY'
from pathlib import Path
import shutil
import subprocess

root = Path('/corresponding-source')
packages = set()
for name in ('runtime-packages.tsv', 'discovery-packages.tsv', 'build-packages.tsv'):
    for line in (root / 'manifests' / name).read_text().splitlines():
        binary, _, source, version = line.split('\t')
        if name != 'build-packages.tsv' or binary == 'foomatic-db-engine':
            packages.add((source, version))
# Include the precise Foomatic generator source as well as redistributed packages.
# Other build-only tools are version-inventoried, not copied into the runtime.
# Failure to retrieve an exact source version fails this companion target, rather
# than substituting a newer source or asserting compliance from binary names.
for source, version in sorted(packages):
    directory = root / 'ubuntu' / (source + '_' + version.replace(':', '_'))
    directory.mkdir(parents=True, exist_ok=True)
    subprocess.run(['apt-get', 'source', '--download-only', '--only-source', source + '=' + version],
                   cwd=directory, check=True)
shutil.copytree('/recipe', root / 'build-recipe', dirs_exist_ok=True)
patches = root / 'patches'
shutil.copytree('/recipe/patches', patches, dirs_exist_ok=True)
PY
cd /corresponding-source
find upstream ubuntu build-recipe licenses patches manifests -type f -print0 \
  | sort -z | xargs -0 sha256sum > SHA256SUMS
