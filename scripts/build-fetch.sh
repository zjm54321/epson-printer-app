#!/usr/bin/env bash
set -euo pipefail
mkdir -p /src /corresponding-source/upstream /corresponding-source/licenses/upstream
python3 - <<'PY'
import hashlib
import json
from pathlib import Path
import re
import subprocess

lock = json.loads(Path('/recipe/sources.lock.json').read_text())
records = []
for item in lock['upstream']:
    name = item['name']
    destination = Path('/src') / name
    destination.mkdir()
    if 'git' in item:
        commit = item['commit']
        if not re.fullmatch('[0-9a-f]{40}', commit):
            raise SystemExit('invalid full commit pin: ' + name)
        def git(*args, output=False):
            command = ['git', '-C', str(destination), *args]
            return subprocess.check_output(command, text=True).strip() if output else subprocess.run(command, check=True)
        git('init', '--quiet')
        git('fetch', '--depth=1', item['git'], commit)
        if git('rev-parse', 'FETCH_HEAD', output=True) != commit:
            raise SystemExit('commit mismatch: ' + name)
        git('checkout', '--detach', 'FETCH_HEAD')
        # The locked object may be an annotated tag (PAPPL 1.4.10).
        # Keep the object pin, and separately inventory the peeled commit.
        resolved_commit = git('rev-parse', 'HEAD', output=True)
        if any(line.startswith('160000 ') for line in git('ls-tree', '-r', 'HEAD', output=True).splitlines()):
            raise SystemExit('unhandled submodule: ' + name)
        # Archive exactly the verified commit, including all upstream licenses.
        archive = Path('/corresponding-source/upstream') / (name + '-' + commit + '.tar')
        git('archive', '--format=tar', '--prefix=' + name + '/', '--output=' + str(archive), 'HEAD')
    else:
        archive = Path('/corresponding-source/upstream') / (name + '-' + item['version'] + '.tar.xz')
        subprocess.run(['curl', '--fail', '--location', '--retry', '3', '--proto', '=https',
                        '--tlsv1.2', '--output', str(archive), item['url']], check=True)
        data = archive.read_bytes()
        if len(data) != item['size'] or hashlib.sha256(data).hexdigest() != item['sha256']:
            raise SystemExit('archive SHA256/size mismatch: ' + name)
        subprocess.run(['tar', '-xJf', str(archive), '--strip-components=1', '-C', str(destination)], check=True)
    records.append({**item, **({'resolvedCommit': resolved_commit} if 'git' in item else {}),
                    'retainedArchive': archive.name,
                    'retainedSHA256': hashlib.sha256(archive.read_bytes()).hexdigest()})
Path('/corresponding-source/manifests/upstream.json').write_text(json.dumps(records, indent=2) + '\n')
PY
