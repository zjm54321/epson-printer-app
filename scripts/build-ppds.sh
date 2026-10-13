#!/usr/bin/env bash
set -euo pipefail
mkdir -p /runtime/usr/share/ppd/epson
python3 - <<'PY'
import hashlib
import json
import os
from pathlib import Path
import re
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
                content = result.stdout
                if ppd['file'] == 'Generic-ESC_P_Dot_Matrix_Printer-epson.ppd':
                    # Correct only the mono epson device's generated metadata.
                    for field, original, corrected in ((b'ColorDevice', b'True', b'False'),
                                                        (b'DefaultColorSpace', b'RGB', b'Gray')):
                        if len(re.findall(rb'^\*' + field + rb':', content, re.MULTILINE)) != 1:
                            raise SystemExit('unexpected Generic ESC/P color metadata')
                        pattern = rb'^(\*' + field + rb':[ \t]+)' + original + rb'([ \t]*\r?)$'
                        content, count = re.subn(pattern, lambda match: match[1] + corrected + match[2],
                                                 content, flags=re.MULTILINE)
                        if count != 1:
                            raise SystemExit('unexpected Generic ESC/P color metadata')
                    device = rb'-sDEVICE=epson(?=[%\s\"])'
                    if not re.search(device, content):
                        raise SystemExit('Generic ESC/P no longer uses the epson device')
                    if re.findall(device, content) != re.findall(device, result.stdout):
                        raise SystemExit('Generic ESC/P command changed')
                target.write_bytes(content)
                records.append({**ppd, 'databaseRoot': database, 'generatorPrinterID': printer,
                                'generatedSHA256': hashlib.sha256(result.stdout).hexdigest(),
                                'installedSHA256': hashlib.sha256(content).hexdigest()})
                break
        else:
            continue
        break
    else:
        raise SystemExit('cannot generate locked PPD ' + ppd['file'] + ': ' + result.stderr.decode(errors='replace'))
Path('/corresponding-source/manifests/generated-ppds.json').write_text(json.dumps(records, indent=2) + '\n')
PY
