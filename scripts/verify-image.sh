#!/usr/bin/env bash
# Three container scenarios. No external network, USB, host printer paths,
# credentials or production queues. Profile jobs use a test-only file sink.
set -euo pipefail
image=${1:?usage: bash scripts/verify-image.sh IMAGE DISCOVERY_IMAGE}
discovery=${2:?supply the tested discovery image}
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
temporary=$(mktemp -d)
bus=epson-test-dbus-$$
avahi=epson-test-avahi-$$
cleanup_discovery() {
  timeout 15s docker rm -f "$avahi" >/dev/null 2>&1 || :
  if [[ -e "$temporary/run/dbus" || -e "$temporary/run/avahi-daemon" || -e "$temporary/run/epson-discovery.ready" ]]; then
    # Remove only CI-generated private paths as their owner, before stopping
    # the bus. The host runner cannot traverse the production-mode 0700 dirs.
    if ! timeout 15s docker exec "$bus" /bin/sh -ec \
      'rm -rf -- /run/dbus /run/avahi-daemon /run/epson-discovery.ready'; then
      # A failed bus may already have exited; use the same restricted UID/image.
      timeout 15s docker run --rm --network none --user 584792:584792 \
        --read-only --cap-drop ALL --security-opt no-new-privileges:true \
        --mount "type=bind,src=$temporary/run,dst=/run" --entrypoint /bin/sh \
        "$discovery" -ec 'rm -rf -- /run/dbus /run/avahi-daemon /run/epson-discovery.ready' || :
    fi
  fi
  timeout 15s docker rm -f "$bus" >/dev/null 2>&1 || :
}
cleanup() {
  status=$?
  trap - EXIT
  set +e
  if [[ $status -ne 0 ]]; then
    docker logs "$bus" 2>/dev/null
    docker logs "$avahi" 2>/dev/null
  fi
  cleanup_discovery
  rm -rf -- "$temporary"
  exit "$status"
}
trap cleanup EXIT
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
mkdir "$temporary/run"
chmod 0777 "$temporary/run"
discovery_common=(--user 584792:584792 --read-only --cap-drop ALL
  --security-opt no-new-privileges:true --pids-limit 64 --memory 128m
  --tmpfs '/tmp:rw,nosuid,nodev,size=32m,mode=1777'
  --mount "type=bind,src=$temporary/run,dst=/run")
docker run --rm --network none "${discovery_common[@]}" "$discovery" help
docker run -d --name "$bus" --network none "${discovery_common[@]}" "$discovery" dbus
attempt=0
until docker exec "$bus" test -S /run/dbus/system_bus_socket; do
  attempt=$((attempt + 1)); [[ $attempt -lt 30 ]] || { docker logs "$bus"; exit 1; }
  sleep 1
done
docker run -d --name "$avahi" --network "container:$bus" "${discovery_common[@]}" \
  -e AVAHI_INTERFACES=lo "$discovery" avahi
attempt=0
until docker exec "$bus" dbus-send --system --print-reply --reply-timeout=2000 \
  --dest=org.freedesktop.DBus /org/freedesktop/DBus org.freedesktop.DBus.GetNameOwner \
  string:org.freedesktop.Avahi > "$temporary/avahi-owner.txt" 2>&1; do
  attempt=$((attempt + 1))
  [[ $attempt -lt 30 ]] || { docker logs "$avahi"; cat "$temporary/avahi-owner.txt"; exit 1; }
  sleep 1
done
cat "$temporary/avahi-owner.txt"
attempt=0
until docker exec "$bus" test -f /run/epson-discovery.ready; do
  attempt=$((attempt + 1)); [[ $attempt -lt 30 ]] || { docker logs "$avahi"; exit 1; }
  sleep 1
done
# Replace --rm --network none without granting external network.
docker run --rm --network "container:$bus" "${common[@]:3}" \
  --mount "type=bind,src=$temporary/run,dst=/run" "$image" /tests/check-server.sh
docker logs "$avahi"
docker logs "$bus"
cleanup_discovery
printf '%s\n' 'Scenario 3/3: Generic ESC/P profile, PDF/PS/PWG to ephemeral test-only file sink'
# Reuse the build-stage cache to export only test tools. They are never added
# to the published runtime; the test executes the EXACT supplied image.
docker build --platform linux/amd64 --target profile-test-tools \
  --output "type=local,dest=$temporary/profile-tools" "$root"
# Normalize only this fresh export's mount root and two known executables.
# The private mktemp parent stays 0700; it is not part of the container mount.
profile_tools="$temporary/profile-tools"
[[ -d "$profile_tools" && ! -L "$profile_tools" ]]
for tool in profile-server profile-raster; do
  [[ -f "$profile_tools/$tool" && ! -L "$profile_tools/$tool" ]]
done
stat -c 'Profile export before: %a %u:%g %n' -- \
  "$profile_tools" "$profile_tools/profile-server" "$profile_tools/profile-raster"
chmod 0755 -- "$profile_tools" "$profile_tools/profile-server" "$profile_tools/profile-raster"
stat -c 'Profile export after: %a %u:%g %n' -- \
  "$profile_tools" "$profile_tools/profile-server" "$profile_tools/profile-raster"
docker run "${common[@]}" \
  --mount "type=bind,src=$temporary/profile-tools,dst=/profile-tools,readonly" \
  "$image" /tests/check-profile.sh
printf '%s\n' 'PASS: all 3 offline-container scenarios; NOT hardware or printing acceptance'
