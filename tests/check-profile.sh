#!/bin/sh
# Exactly two Print-Jobs, on the exact runtime libraries. Test-only device and
# state live under /tmp; caller supplies --network none and no USB mounts.
set -eu
test ! -e /dev/bus/usb
# Run these checks as the same restricted UID that will execute the tools.
stat -c 'Profile mounted tools: %a %u:%g %n' -- \
  /profile-tools /profile-tools/profile-server /profile-tools/profile-raster
grep ' /profile-tools ' /proc/self/mountinfo
test -d /profile-tools && test -x /profile-tools
for tool in /profile-tools/profile-server /profile-tools/profile-raster; do
  test -f "$tool" && test -r "$tool" && test -x "$tool"
done
umask 077
root=$(mktemp -d /tmp/epson-profile.XXXXXX)
export PROFILE_TEST_ROOT="$root" TMPDIR="$root"
export STATE_DIR="$root/state" SPOOL_DIR="$root/spool" STATE_FILE="$root/state.conf"
mkdir -p "$STATE_DIR" "$SPOOL_DIR"
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
start() {
  /profile-tools/profile-server -o server-port=8000 -o listen-hostname=127.0.0.1 \
    -o log-file=- -o log-level=debug server >> "$root/server.log" 2>&1 &
  server=$!
  deadline=$(($(date +%s) + 30))
  while :; do
    kill -0 "$server"
    code=0
    "$check" exists "$queue" "$driver" "$device" > "$root/startup-check.log" 2>&1 || code=$?
    case "$code" in 0|4) break ;; esac
    if [ "$(date +%s)" -ge "$deadline" ]; then
      cat "$root/startup-check.log"
      return 1
    fi
    sleep 1
  done
  if grep -Ei 'Unable to .*DNS-SD|DNS-SD.*(failed|error)|Avahi.*(failed|error)|daemon.*NULL' "$root/server.log"; then
    echo 'FAIL: PAPPL discovery initialization error despite running private Avahi' >&2
    return 1
  fi
}
stop() {
  kill "$server"; wait "$server"; server=
}
# Submit to the ephemeral file sink only, then wait for COMPLETED (not merely
# accepted). Capture the actual foomatic/GS command and require ESC/P bytes.
# These dollar variables belong to ipptool, not the shell.
# shellcheck disable=SC2016
submit() {
  name=$1 format=$2 file=$3 xy=$4 resolution=$5 quality=$6
  lines=$(wc -l < "$root/server.log")
  : > "$root/output.bin"
  {
    printf '%s\n' '{' 'NAME "Offline profile job"' 'OPERATION Print-Job' \
      'GROUP operation-attributes-tag' 'ATTR charset attributes-charset utf-8' \
      'ATTR language attributes-natural-language en' 'ATTR uri printer-uri $uri' \
      'ATTR name requesting-user-name profile-test' "ATTR name job-name $name" \
      "ATTR mimetype document-format $format" 'GROUP job-attributes-tag'
    if [ "$resolution" != none ]; then printf 'ATTR resolution printer-resolution %sdpi\n' "$resolution"; fi
    if [ "$quality" != none ]; then printf 'ATTR enum print-quality %s\n' "$quality"; fi
    printf '%s\n' 'FILE $filename' 'STATUS successful-ok' \
      'EXPECT job-id OF-TYPE integer DEFINE-VALUE job-id' '}' \
      '{' 'NAME "Offline job completed"' 'OPERATION Get-Job-Attributes' \
      'GROUP operation-attributes-tag' 'ATTR charset attributes-charset utf-8' \
      'ATTR language attributes-natural-language en' 'ATTR uri printer-uri $uri' \
      'ATTR integer job-id $job-id' 'ATTR keyword requested-attributes job-state,job-state-reasons' \
      'STATUS successful-ok' 'EXPECT job-state WITH-VALUE 9 REPEAT-NO-MATCH REPEAT-LIMIT 90' 'DELAY 1' '}'
  } > "$root/job.test"
  if ! ipptool -T 90 -tv -f "$file" "$uri" "$root/job.test" > "$root/ipp-job.log" 2>&1; then
    cat "$root/ipp-job.log"
    return 1
  fi
  cat "$root/ipp-job.log"
  tail -n "+$((lines + 1))" "$root/server.log" > "$root/fresh-job.log"
  awk -v expected_xy="$xy" -v normalized="$root/job.log" -f /tests/check-profile-log.awk \
    "$root/ipp-job.log" "$root/fresh-job.log"
  /profile-tools/profile-raster output "$root/output.bin"
  if [ "$format" = image/pwg-raster ]; then
    grep -F "PROFILE HEADER PASS" "$root/job.log" | grep -F "output=${xy}dpi"
  fi
}

printf '%s\n' 'Core test 1/2: fresh canonical queue, persistent defaults, one normal PDF job'
start
ghostscript-printer-app add -d "$queue" -m "$driver" -v "$device"
ghostscript-printer-app default -d "$queue"
# Includes all four standard/PWG resolutions, mono, normal/180x180 defaults,
# absence of vendor Resolution, and the matching system-default printer ID.
"$check" ready "$queue" "$driver" "$device"
stop
test -s "$STATE_FILE"
start
# One controlled reload, with no default repair before querying/printing.
"$check" ready "$queue" "$driver" "$device"
gs -q -dBATCH -dNOPAUSE -sDEVICE=pdfwrite -sOutputFile="$root/fixture.pdf" /tests/fixture.ps
submit pdf-normal application/pdf "$root/fixture.pdf" 180x180 none none

printf '%s\n' 'Core test 2/2: sgray_8 PWG 120x72 input, explicit 360x216 output overrides draft'
/profile-tools/profile-raster gray "$root/gray.pwg"
submit gray-explicit image/pwg-raster "$root/gray.pwg" 360x216 360x216 3
"$check" ready "$queue" "$driver" "$device"
printf '%s\n' 'PASS exactly two offline Print-Jobs; temporary file output, NOT physical acceptance'
