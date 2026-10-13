#!/usr/bin/env bash
set -euo pipefail
export PKG_CONFIG_PATH=/usr/lib/pkgconfig:/usr/local/lib/pkgconfig:/usr/lib/x86_64-linux-gnu/pkgconfig
mkdir -p /profile-test-tools
read -r -a flags < <(pkg-config --cflags --libs pappl libppd libcupsfilters libpappl-retrofit)
cc -Wall -Wextra -I/src/pappl-retrofit -I/src/pappl-retrofit/pappl-retrofit \
  -I/src/ghostscript-printer-app /recipe/tests/profile-server.c "${flags[@]}" -ljpeg -lcups \
  -o /profile-test-tools/profile-server
read -r -a cups_cflags < <(cups-config --cflags)
cc -Wall -Wextra -Werror "${cups_cflags[@]}" /recipe/tests/profile-raster.c -L/usr/lib -lcups \
  -o /profile-test-tools/profile-raster
# Test artifacts must not inherit a restrictive compiler/build umask.
chmod 0755 /profile-test-tools /profile-test-tools/profile-server /profile-test-tools/profile-raster
