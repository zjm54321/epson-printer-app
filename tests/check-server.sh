#!/bin/sh
set -eu
test ! -e /dev/bus/usb
test -z "$(find /state -mindepth 1 -print -quit)"
test "$(find /usr/share/ppd/epson -type f -name '*.ppd' | wc -l)" -eq 3
# PAPPL's explicit drivers command inventories the installed catalogue; no find,
# add, autoadd, backend, device URI or document-submission command is used.
ghostscript-printer-app drivers > /tmp/drivers.txt
cat /tmp/drivers.txt
grep -Ei 'lq[-_ ]*850' /tmp/drivers.txt
/usr/local/bin/epson-entrypoint server -o listen-hostname=127.0.0.1 > /tmp/server.log 2>&1 &
server=$!
trap 'kill "$server" 2>/dev/null || :; wait "$server" 2>/dev/null || :; cat /tmp/server.log' EXIT
attempt=0
until ipptool -T 2 -tv ipp://127.0.0.1:8000/ipp/system /tests/get-printers.test > /tmp/ipp.txt 2>&1; do
  kill -0 "$server"
  attempt=$((attempt + 1))
  if [ "$attempt" -ge 30 ]; then cat /tmp/ipp.txt; exit 1; fi
  sleep 2
done
cat /tmp/ipp.txt
/usr/libexec/epson-printer-app/ipp-empty
if grep -Ei 'Unable to .*DNS-SD|DNS-SD.*(failed|error)|Avahi.*(failed|error)|daemon.*NULL' /tmp/server.log; then
  echo 'FAIL: PAPPL discovery initialization error despite running private Avahi' >&2
  exit 1
fi
printf '%s\n' 'PASS scenario 2: installed catalogue, fresh inert server, zero printer groups'
