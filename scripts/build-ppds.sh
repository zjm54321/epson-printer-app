#!/usr/bin/env bash
set -euo pipefail
mkdir -p /runtime/usr/share/ppd/epson
python3 - <<'PY'
import json
import os
from pathlib import Path
import subprocess

lock = json.loads(Path('/recipe/sources.lock.json').read_text())
records = []
for ppd in lock['ppds']:
    # The two layouts cover the checked-out DB root vs. its db/ directory;
    # both use the SAME locked upstream XML, never distro replacement data.
    for database in ('/src/foomatic-db', '/src/foomatic-db/db'):
        for printer in (ppd['printer'], ppd['printer'].removeprefix('printer/')):
            result = subprocess.run(['foomatic-ppdfile', '-p', printer, '-d', ppd['driver']],
                                    env={**os.environ, 'FOOMATICDB': database},
                                    stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            if result.returncode == 0 and result.stdout.startswith(b'*PPD-Adobe:') and b'FoomaticRIPCommandLine' in result.stdout:
                target = Path('/runtime/usr/share/ppd/epson') / ppd['file']
                target.write_bytes(result.stdout)
                records.append({**ppd, 'databaseRoot': database, 'generatorPrinterID': printer})
                break
        else:
            continue
        break
    else:
        raise SystemExit('cannot generate locked PPD ' + ppd['file'] + ': ' + result.stderr.decode(errors='replace'))
Path('/corresponding-source/manifests/generated-ppds.json').write_text(json.dumps(records, indent=2) + '\n')
PY
