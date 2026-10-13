#!/usr/bin/env bash
set -euo pipefail
export LD_LIBRARY_PATH=/usr/lib:/usr/local/lib
export PKG_CONFIG_PATH=/usr/lib/pkgconfig:/usr/local/lib/pkgconfig:/usr/lib/x86_64-linux-gnu/pkgconfig
jobs=${BUILD_JOBS:-2}
mkdir -p /runtime/usr/{bin,lib,share} /runtime/usr/lib/ghostscript-printer-app/{backend,filter}

prepare() {
  if [[ -f autogen.sh ]]; then NOCONFIGURE=1 bash ./autogen.sh; else autoreconf -fi; fi
}
apply_patches() {
  python3 - "$1" <<'PY'
import hashlib
import json
from pathlib import Path
import subprocess
import sys

lock = json.loads(Path('/recipe/sources.lock.json').read_text())
upstream = {item['name']: item['commit'] for item in lock['upstream']}
supported = {
    'cups', 'pappl', 'ghostscript', 'libcupsfilters', 'libppd',
    'cups-filters', 'pappl-retrofit', 'ghostscript-printer-app',
}
component = sys.argv[1]
if component not in supported or component not in upstream:
    raise SystemExit(f'unsupported source patch component: {component}')
for item in lock['patches']:
    target = item.get('component')
    if target not in supported or target not in upstream:
        raise SystemExit(f'unsupported source patch component: {target}')
    if item.get('commit') != upstream[target]:
        raise SystemExit(f'source patch commit mismatch: {target}')
    if target != component:
        continue
    patch = Path('/recipe') / item['path']
    if hashlib.sha256(patch.read_bytes()).hexdigest() != item['sha256']:
        raise SystemExit(f'source patch digest mismatch: {patch}')
    subprocess.run(
        ['patch', '--batch', '--fuzz=0', '-p1', '-i', str(patch)],
        cwd=Path('/src') / component, check=True,
    )
PY
}
shared_libraries() {
  local stage=$1 file
  while IFS= read -r -d '' file; do
    mkdir -p "/runtime$(dirname "${file#"$stage"}")"
    cp -a "$file" "/runtime${file#"$stage"}"
  done < <(find "$stage/usr/lib" -name '*.so*' -print0)
}
autotools_library() {
  local name=$1; shift
  cd "/src/$name"
  apply_patches "$name"
  prepare
  ./configure --prefix=/usr --libdir=/usr/lib "$@"
  make -j"$jobs"
  make install
  make install DESTDIR="/stage/$name"
  shared_libraries "/stage/$name"
  ldconfig
}

# CUPS 2 libraries and the USB backend only; never build/install cupsd or network backends.
cd /src/cups
apply_patches cups
[[ -x configure ]] || prepare
./configure --prefix=/usr --libdir=/usr/lib --with-tls=gnutls --enable-libusb
make -j"$jobs" -C cups
mkdir -p /usr/include/cups
cp cups/*.h /usr/include/cups/
cp -a cups/libcups*.so* /usr/lib/
cp cups/libcups*.a /usr/lib/
install -m 0755 cups-config /usr/bin/cups-config
cp -a cups/libcups*.so* /runtime/usr/lib/
ldconfig
make -j"$jobs" -C backend usb
python3 /recipe/tests/check-usb-patch.py /src/cups/backend/usb-libusb.c
install -m 0755 backend/usb /runtime/usr/lib/ghostscript-printer-app/backend/usb
install -D -m 0644 backend/org.cups.usb-quirks /runtime/usr/share/cups/usb/org.cups.usb-quirks
# Read-only IPP inspection tooling, not a scheduler or a backend.
make -j"$jobs" -C tools ipptool
install -m 0755 tools/ipptool /runtime/usr/bin/ipptool

cd /src/pappl
apply_patches pappl
[[ -x configure ]] || prepare
./configure --prefix=/usr --libdir=/usr/lib --enable-libjpeg --enable-libpng --enable-libusb --with-dnssd=avahi
make -j"$jobs"
make install
make install DESTDIR=/stage/pappl
shared_libraries /stage/pappl
ldconfig

cd /src/ghostscript
apply_patches ghostscript
./configure --prefix=/usr --without-x --disable-gtk \
  --with-drivers=EPSON,PS,cups --enable-freetype --without-tesseract
make -j"$jobs"
make install
make install DESTDIR=/stage/ghostscript
install -m 0755 /stage/ghostscript/usr/bin/gs /runtime/usr/bin/gs
cp -a /stage/ghostscript/usr/share/ghostscript /runtime/usr/share/
test "$(gs --version)" = 10.08.0
gs -h > /corresponding-source/manifests/ghostscript-help.txt

autotools_library libcupsfilters --disable-avahi --disable-mutool
if [[ -d /stage/libcupsfilters/usr/share/cups ]]; then
  cp -a /stage/libcupsfilters/usr/share/cups/. /runtime/usr/share/cups/
fi
autotools_library libppd --disable-mutool --disable-pdftocairo --disable-acroread --enable-ppdc-utils

cd /src/cups-filters
apply_patches cups-filters
prepare
./configure --prefix=/usr --disable-mutool --enable-ppdc-utils
for filter in foomatic-rip gstoraster pdftops; do
  make -j"$jobs" "$filter"
  # libtool executables can be wrappers; install the actual binary when present.
  binary=$filter
  [[ ! -f ".libs/$filter" ]] || binary=".libs/$filter"
  install -m 0755 "$binary" "/runtime/usr/lib/ghostscript-printer-app/filter/$filter"
done
ln -s ../lib/ghostscript-printer-app/filter/foomatic-rip /runtime/usr/bin/foomatic-rip
# Selected pdftops conversion uses this executable, not all of poppler-utils.
install -m 0755 /usr/bin/pdftops /runtime/usr/bin/pdftops

autotools_library pappl-retrofit
if [[ -f /stage/pappl-retrofit/usr/share/legacy-printer-app/testpage.pdf ]]; then
  install -D -m 0644 /stage/pappl-retrofit/usr/share/legacy-printer-app/testpage.pdf \
    /runtime/usr/share/ghostscript-printer-app/testpage.pdf
fi

cd /src/ghostscript-printer-app
apply_patches ghostscript-printer-app
# The app Makefile emits four C integer macros: avoid zero-padded components.
# This app build version is separate from Ghostscript's reported 10.08.0.
app_version=10.8.0-1
make -j"$jobs" SNAP=0 VERSION="$app_version" LDFLAGS='-L/usr/lib -ljpeg'
make install SNAP=0 VERSION="$app_version" PREFIX=/usr prefix=/usr \
  LDFLAGS='-L/usr/lib -ljpeg' DESTDIR=/stage/ghostscript-printer-app
install -m 0755 ghostscript-printer-app /runtime/usr/bin/ghostscript-printer-app
for data in /stage/ghostscript-printer-app/usr/share/ghostscript-printer-app \
            /stage/ghostscript-printer-app/usr/local/share/ghostscript-printer-app; do
  if [[ -d $data ]]; then
    mkdir -p /runtime/usr/share/ghostscript-printer-app
    cp -a "$data/." /runtime/usr/share/ghostscript-printer-app/
  fi
done
install -D -m 0755 /recipe/scripts/entrypoint.sh /runtime/usr/local/bin/epson-entrypoint
# This client only issues Get-Printers and checks raw IPP group tags.
mkdir -p /runtime/usr/libexec/epson-printer-app
read -r -a cups_cflags < <(cups-config --cflags)
cc "${cups_cflags[@]}" /recipe/tests/ipp-empty.c -L/usr/lib -lcups \
  -o /runtime/usr/libexec/epson-printer-app/ipp-empty
cc -Wall -Wextra -Werror "${cups_cflags[@]}" /recipe/runtime/queue-check.c -L/usr/lib -lcups \
  -o /runtime/usr/libexec/epson-printer-app/queue-check
