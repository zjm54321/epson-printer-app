#!/bin/sh
# Three behavior groups, on the exact runtime libraries. Test-only device and
# state live under /tmp; caller supplies --network none and no USB mounts.
set -eu
test ! -e /dev/bus/usb
umask 077
root=$(mktemp -d /tmp/epson-profile.XXXXXX)
export PROFILE_TEST_ROOT="$root" TMPDIR="$root"
export STATE_DIR="$root/state" SPOOL_DIR="$root/spool" STATE_FILE="$root/state.conf"
mkdir -p "$STATE_DIR" "$SPOOL_DIR" "$root/outputs"
server=
cleanup() {
  result=$?
  trap - EXIT
  if [ -n "$server" ]; then kill "$server" 2>/dev/null || :; wait "$server" 2>/dev/null || :; fi
  if [ "$result" -ne 0 ]; then cat "$root/server.log"; fi
  rm -rf -- "$root"
  exit "$result"
}
trap cleanup EXIT
driver=generic--esc-p-dot-matrix-printer--epson-recommended-en
queue=epson-lq1600kiii-epson
device=offline:profile-test
check=/usr/libexec/epson-printer-app/queue-check
uri="ipp://127.0.0.1:8000/ipp/print/$queue"
expect_code() {
  expected=$1; shift
  code=0
  "$@" || code=$?
  test "$code" -eq "$expected"
}
start() {
  /profile-tools/profile-server -o server-port=8000 -o listen-hostname=127.0.0.1 \
    -o log-file=- -o log-level=debug server >> "$root/server.log" 2>&1 &
  server=$!
  attempt=0
  until [ -S "$root/ghostscript-printer-app$(id -u).sock" ]; do
    kill -0 "$server"
    attempt=$((attempt + 1)); test "$attempt" -lt 30
    sleep 1
  done
}

printf '%s\n' 'Profile group 1/3: capabilities, identity, retained defaults, default queue'
expect_code 1 "$check" exists "$queue" "$driver" "$device"
start
expect_code 4 "$check" exists "$queue" "$driver" "$device"
expect_code 1 "$check" ready "$queue" "$driver" "$device"
ghostscript-printer-app add -d "$queue" -m "$driver" -v "$device"
"$check" exists "$queue" "$driver" "$device"
expect_code 1 "$check" exists "$queue" wrong-driver "$device"
expect_code 1 "$check" exists "$queue" "$driver" offline:wrong-device
expect_code 1 "$check" exists ../invalid "$driver" "$device"
ghostscript-printer-app default -d "$queue"
"$check" ready "$queue" "$driver" "$device"
ghostscript-printer-app add -d profile-other -m "$driver" -v "$device"
ghostscript-printer-app default -d profile-other
expect_code 1 "$check" ready "$queue" "$driver" "$device"
ghostscript-printer-app default -d "$queue"
ghostscript-printer-app modify -d "$queue" -o printer-resolution-default=120x72dpi -o print-quality-default=high
expect_code 1 "$check" ready "$queue" "$driver" "$device"
kill "$server"; wait "$server"; server=
test -s "$STATE_FILE"
# Only test-owned, idle state: emulate the old heuristic and obsolete vendor
# defaults. No production state is opened, copied or migrated by this test.
sed -i -e 's/^printer-resolution-default .*/printer-resolution-default 360x180dpi/' \
  -e '/^<\/Printer>/i resolution-default 360x180dpi' "$STATE_FILE"
start
"$check" exists "$queue" "$driver" "$device"
ghostscript-printer-app modify -d "$queue" -o printer-resolution-default=180dpi \
  -o print-quality-default=normal -o print-color-mode-default=monochrome
ghostscript-printer-app default -d "$queue"
"$check" ready "$queue" "$driver" "$device"
grep -F 'PROFILE CAPS/UPDATE PASS' "$root/server.log"

# Submit to the ephemeral file sink only, then wait for COMPLETED (not merely
# accepted). Capture the actual foomatic/GS command and require ESC/P bytes.
# These dollar variables belong to ipptool, not the shell.
# shellcheck disable=SC2016
submit() {
  name=$1 format=$2 file=$3 xy=$4 resolution=$5 quality=$6 vendor=$7
  lines=$(wc -l < "$root/server.log")
  : > "$root/output.bin"
  {
    printf '%s\n' '{' 'NAME "Offline profile job"' 'OPERATION Print-Job' \
      'GROUP operation-attributes-tag' 'ATTR charset attributes-charset utf-8' \
      'ATTR language attributes-natural-language en' 'ATTR uri printer-uri $uri' \
      'ATTR name requesting-user-name profile-test' "ATTR name job-name $name" \
      "ATTR mimetype document-format $format" 'ATTR boolean ipp-attribute-fidelity false' \
      'GROUP job-attributes-tag' 'ATTR keyword print-color-mode monochrome'
    if [ "$resolution" != none ]; then printf 'ATTR resolution printer-resolution %sdpi\n' "$resolution"; fi
    if [ "$quality" != none ]; then printf 'ATTR enum print-quality %s\n' "$quality"; fi
    if [ "$vendor" != none ]; then printf 'ATTR keyword resolution %s\n' "$vendor"; fi
    printf '%s\n' 'FILE $filename' 'STATUS successful-ok' \
      'STATUS successful-ok-ignored-or-substituted-attributes' \
      'EXPECT job-id OF-TYPE integer DEFINE-VALUE job-id' '}' \
      '{' 'NAME "Offline job completed"' 'OPERATION Get-Job-Attributes' \
      'GROUP operation-attributes-tag' 'ATTR charset attributes-charset utf-8' \
      'ATTR language attributes-natural-language en' 'ATTR uri printer-uri $uri' \
      'ATTR integer job-id $job-id' 'ATTR keyword requested-attributes job-state,job-state-reasons' \
      'STATUS successful-ok' 'EXPECT job-state WITH-VALUE 9 REPEAT-NO-MATCH REPEAT-LIMIT 90' 'DELAY 1' '}'
  } > "$root/job.test"
  ipptool -T 90 -t -f "$file" "$uri" "$root/job.test"
  tail -n "+$((lines + 1))" "$root/server.log" > "$root/job.log"
  grep -F -- '-sDEVICE=epson' "$root/job.log"
  grep -E -- "-r${xy}([[:space:]\"']|$)" "$root/job.log"
  /profile-tools/profile-raster output "$root/output.bin"
  cp "$root/output.bin" "$root/outputs/$name.bin"
  if [ "$format" = image/pwg-raster ]; then
    grep -F "PROFILE HEADER PASS" "$root/job.log" | grep -F "output=${xy}dpi"
  fi
}

printf '%s\n' 'Profile group 2/3: actual PDF/PS filters, four explicit pairs, quality and conflicts'
gs -q -dBATCH -dNOPAUSE -sDEVICE=pdfwrite -sOutputFile="$root/fixture.pdf" /tests/fixture.ps
for type in ps pdf; do
  format=application/postscript file=/tests/fixture.ps
  if [ "$type" = pdf ]; then format=application/pdf file="$root/fixture.pdf"; fi
  for xy in 60x60 120x72 180x180 360x216; do
    submit "$type-explicit-$xy" "$format" "$file" "$xy" "$xy" none none
  done
  submit "$type-draft" "$format" "$file" 60x60 none 3 none
  submit "$type-normal" "$format" "$file" 180x180 none 4 none
  submit "$type-high" "$format" "$file" 360x216 none 5 none
  submit "$type-conflict" "$format" "$file" 120x72 120x72 5 none
  submit "$type-stale-vendor" "$format" "$file" 180x180 180x180 3 360x216dpi
done

printf '%s\n' 'Profile group 3/3: real PWG black_1/sgray_8, complete source geometry and target DPI'
for type in black gray; do
  /profile-tools/profile-raster "$type" "$root/$type.pwg"
  # Input is 120x72: covers equal and unequal input/output DPI for both types.
  for xy in 60x60 120x72 180x180 360x216; do
    submit "$type-explicit-$xy" image/pwg-raster "$root/$type.pwg" "$xy" "$xy" none none
  done
  submit "$type-draft" image/pwg-raster "$root/$type.pwg" 60x60 none 3 none
  submit "$type-normal" image/pwg-raster "$root/$type.pwg" 180x180 none 4 none
  submit "$type-high" image/pwg-raster "$root/$type.pwg" 360x216 none 5 none
done
"$check" ready "$queue" "$driver" "$device"
printf '%s\n' 'PASS all three profile groups; ephemeral file output only, NOT physical acceptance'
