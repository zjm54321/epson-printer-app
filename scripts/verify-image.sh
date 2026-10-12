#!/usr/bin/env bash
# Exactly three functional scenarios. No daemon installation, network, USB,
# host printer paths, credentials, print queues or printer backends are used.
set -euo pipefail
image=${1:?usage: bash scripts/verify-image.sh IMAGE}
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
temporary=$(mktemp -d)
trap 'rm -rf -- "$temporary"' EXIT
common=(--rm --network none --user 584792:584792 --group-add 0
  --read-only --cap-drop ALL --security-opt no-new-privileges:true
  --pids-limit 128 --memory 512m --cpus 1
  --tmpfs '/state:rw,nosuid,nodev,noexec,size=64m,uid=584792,gid=584792,mode=0700'
  --tmpfs '/tmp:rw,nosuid,nodev,size=128m,mode=1777'
  --mount "type=bind,src=$root/tests,dst=/tests,readonly"
  --entrypoint /bin/sh)
printf '%s\n' 'Scenario 1/3: Ghostscript/device and ELF contract'
docker run "${common[@]}" "$image" /tests/check-gs.sh
printf '%s\n' 'Scenario 2/3: installed catalogue and fresh queue-less isolated server'
docker run "${common[@]}" "$image" /tests/check-server.sh
printf '%s\n' 'Scenario 3/3: installed PPD + foomatic-rip, owned fixture to temporary file ONLY'
docker run "${common[@]}" "$image" -ec '
  test ! -e /dev/bus/usb
  foomatic-rip --ppd /usr/share/ppd/epson/Epson-LQ-850-lq850.ppd /tests/fixture.ps > /tmp/lq850-output.bin
  test -s /tmp/lq850-output.bin
  cat /tmp/lq850-output.bin
' > "$temporary/lq850-output.bin"
python3 - "$temporary/lq850-output.bin" <<'PY'
from pathlib import Path
import sys
data = Path(sys.argv[1]).read_bytes()
if not data or not any(marker in data for marker in (b'\x1b@', b'\x1b*', b'\x1b(')):
    raise SystemExit('FAIL: installed filter did not produce recognizable ESC/P bytes')
if data.startswith((b'%!PS', b'%PDF')):
    raise SystemExit('FAIL: output is an unconverted source document')
print('PASS scenario 3: temporary output contains ESC/P bytes (' + str(len(data)) + ' bytes)')
PY
printf '%s\n' 'PASS: all 3 offline-container scenarios; NOT hardware or printing acceptance'
