#!/bin/sh
set -eu
case "${1:-help}" in
  help|--help|-h)
    printf '%s\n' 'Explicit modes: dbus or avahi. No daemon starts by default.' \
      'Share private writable /run between app, dbus and avahi containers.' \
      'AVAHI_INTERFACES defaults to eth0; AVAHI_HOST_NAME defaults to epson-printer.'
    ;;
  dbus)
    test "$(id -u)" = 584792
    umask 077
    mkdir -p /run/dbus
    exec dbus-daemon --config-file=/etc/epson-discovery/dbus-system.conf --nofork --nopidfile
    ;;
  avahi)
    test "$(id -u)" = 584792
    ready=/run/epson-discovery.ready
    rm -f "$ready"
    interfaces=${AVAHI_INTERFACES:-eth0}
    hostname=${AVAHI_HOST_NAME:-epson-printer}
    case "$interfaces" in ''|*[!A-Za-z0-9_.:,-]*) echo 'Invalid AVAHI_INTERFACES' >&2; exit 64;; esac
    case "$hostname" in ''|*[!A-Za-z0-9-]*) echo 'Invalid AVAHI_HOST_NAME' >&2; exit 64;; esac
    umask 077
    mkdir -p /run/avahi-daemon
    sed -e "s/@INTERFACES@/$interfaces/" -e "s/@HOST_NAME@/$hostname/" \
      /etc/epson-discovery/avahi-daemon.conf.in > /run/avahi-daemon/avahi-daemon.conf
    avahi-daemon --no-drop-root --no-chroot --no-rlimits --debug \
      --file=/run/avahi-daemon/avahi-daemon.conf &
    daemon=$!
    cleanup() {
      rm -f "$ready"
      kill -TERM "$daemon" 2>/dev/null || :
      wait "$daemon" 2>/dev/null || :
    }
    trap cleanup EXIT
    trap 'exit 143' TERM
    trap 'exit 130' INT
    attempt=0
    until dbus-send --system --print-reply --reply-timeout=2000 \
      --dest=org.freedesktop.DBus /org/freedesktop/DBus org.freedesktop.DBus.GetNameOwner \
      string:org.freedesktop.Avahi >/dev/null 2>&1; do
      kill -0 "$daemon"
      attempt=$((attempt + 1))
      if [ "$attempt" -ge 30 ]; then echo 'Avahi D-Bus registration timed out' >&2; exit 1; fi
      sleep 1
    done
    kill -0 "$daemon"
    : > "$ready"
    wait "$daemon"
    ;;
  *) echo 'Use explicit dbus or avahi mode, or help.' >&2; exit 64;;
esac
