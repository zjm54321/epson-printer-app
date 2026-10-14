#!/bin/sh
set -eu
case "${1:-help}" in
  help|--help|-h)
    printf '%s\n' \
      'Epson ESC/P printer application; default operation does not start a server.' \
      'inspect: Ghostscript version and installed PPD names only.' \
      'server [-o listen-hostname=127.0.0.1]: explicit printer-app startup on port 8000.' \
      'Restored /state may resume historical jobs; use the intended persistent state.' \
      'No automatic D-Bus, Avahi, queue creation, discovery command or test page.'
    ;;
  inspect)
    gs --version
    find /usr/share/ppd/epson -type f -name '*.ppd' -print
    ;;
  server)
    shift
    test "$(id -u)" = 584792
    test "$(id -g)" = 584792
    umask 077
    mkdir -p /state/state /state/spool /state/.cups/ssl
    exec /usr/bin/ghostscript-printer-app -o server-port=8000 -o log-file=- "$@" server
    ;;
  *)
    printf '%s\n' 'Unsupported entrypoint command; use help, inspect or explicit server.' >&2
    exit 64
    ;;
esac
