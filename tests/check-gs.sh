#!/bin/sh
set -eu
test "$(id -u)" = 584792
test "$(id -g)" = 584792
/usr/local/bin/epson-entrypoint help
test "$(gs --version)" = 10.08.0
gs -h > /tmp/gs-help.txt
cat /tmp/gs-help.txt
for device in epson cups ps2write pdfwrite; do
  grep -Eq "(^|[[:space:]])$device([[:space:]]|$)" /tmp/gs-help.txt
done
sha256sum -c /usr/share/epson-printer-app/source-libraries.sha256
for binary in /usr/bin/ghostscript-printer-app /usr/libexec/epson-printer-app/queue-check \
              /usr/lib/ghostscript-printer-app/backend/usb \
              /usr/lib/ghostscript-printer-app/filter/*; do
  printf '\nELF resolution: %s\n' "$binary"
  ldd "$binary" > /tmp/ldd.txt
  cat /tmp/ldd.txt
  if grep -q 'not found' /tmp/ldd.txt; then exit 1; fi
  # Every selected source-built SONAME must resolve from /usr/lib, NOT Noble's
  # /usr/lib/x86_64-linux-gnu/libcups2t64 or other distro versions.
  if grep -E 'lib(cups|pappl|ppd)[^ ]* =>' /tmp/ldd.txt | grep -v '=> /usr/lib/lib'; then
    printf '%s\n' 'FAIL: distro library shadows a source-built SONAME' >&2
    exit 1
  fi
done
test -z "$(find /usr /bin /sbin -xdev -type f -perm /6000 -print)"
test -z "$(getcap -r / 2>/dev/null)"
printf '%s\n' 'PASS scenario 1: actual Ghostscript version/devices and ELF/security provenance'
