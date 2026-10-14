# Corresponding sources and runtime boundary

The CUPS source has one locally applied, hash-pinned patch:
`patches/cups-usb-bridge-identity.patch`. It rejects short/truncated IEEE1284
responses and uses USB descriptors for URI selection only on VID/PID 1a86:7584;
valid IEEE1284 metadata and other vendors' URI logic remain. The upstream
no-reattach quirk is unchanged. Exact patches accompany the upstream archives,
recipes and corresponding-source artifact.

The separate `discovery` target uses Noble's Avahi/D-Bus packages. Their resolved
binary/source versions and licenses are retained, and their corresponding Ubuntu
sources are included in the single companion. Default help is inert; explicit
`dbus` / `avahi` modes run UID/GID 584792, foreground, without SUID/SGID/capabilities.
Shared private writable `/run` holds the bus socket and rendered Avahi config.
The executable `/usr/local/bin/epson-discovery-entrypoint` accepts `dbus` or
`avahi`. Avahi mode creates `/run/epson-discovery.ready` only after private D-Bus
GetNameOwner confirms `org.freedesktop.Avahi`; it clears the marker on startup
and exit, forwarding TERM to its foreground daemon. Queue bootstrap can wait on
that marker before starting PAPPL; app ENTRYPOINT remains unchanged.
The image defaults to generic eth0/epson-printer; GitOps can set interfaces/name.
IPv6, wide-area DNS, reflector and workstation publication are disabled.

This is a native Ubuntu 24.04 **linux/amd64** build of the existing OpenPrinting
Ghostscript Printer Application, not a replacement print implementation. The
default entrypoint prints local help only. `server` is explicit. The runtime
container carries PAPPL and Avahi client libraries, while the Avahi daemon and
private D-Bus service run in separate discovery sidecar containers.

## Pinned upstream inputs

`sources.lock.json` is authoritative for full commit IDs, URLs, the verified
Ubuntu index/amd64 digests and the official Ghostscript archive SHA256/size.

| Component | Selected revision | Runtime purpose |
| --- | --- | --- |
| CUPS | 2.4.16 | libcups, USB backend, read-only IPP inspection tools |
| PAPPL | 1.4.10 | existing printer-application framework |
| Ghostscript | 10.08.0 | EPSON/PS families plus cups conversion device |
| libcupsfilters / libppd | 2.1.1 / 2.1.1 | selected conversion / PPD support |
| cups-filters | 2.0.1 | foomatic-rip, gstoraster, pdftops only |
| pappl-retrofit | 49ad525a3715a57aae24c715ef0767b55ffb1991 | existing legacy-driver integration |
| Ghostscript Printer Application | 4afd1570bd3e70b30a5730a2748346d89b2c41ad | native `SNAP=0` application |
| Foomatic DB | 20240504, b1324cde08349583c44a20067a4d877e087d75fe | upstream Generic ESC/P Dot Matrix PPD (`epson`) |
| Ubuntu foomatic-db-engine | 4.0.13-6 | build-time PPD generator; not in runtime |

QPDF comes from Noble (build requires >=11), not a separate source build.
Ordinary Ubuntu security updates are allowed. The pinned base plus apt indexes
does **not** provide bit-identical reproducibility. Build/runtime package manifests
record binary **and source** versions. Full Git commits are verified before
archiving; generated Git archive SHA256s are recorded after acquisition, not
presented as independently preverified archive hashes. Ghostscript's official
archive is checked against the preverified SHA256 and byte length.

## Source companion and licenses

Build targets are `runtime`, `discovery` and `sources`. The scratch `sources` image contains:

* the exact upstream archives used, including complete upstream license files;
* `licenses/upstream/` preserving discovered license/notice paths, and original
  Ubuntu source archives plus Debian/Ubuntu patches and `.dsc` files;
* this Dockerfile, lock and build recipes under `build-recipe/`;
* the locally applied source patches;
* resolved binary/source package versions, selected PPD generator inputs,
  build-time ELF resolutions, source-library hashes and `SHA256SUMS`.

The companion requests exact corresponding source versions for **all** runtime
base packages, copied distro ELF dependencies and the Foomatic generator.
Other build-only tools are version-inventoried but not redistributed. Missing
historical apt sources fail the companion build;
they are not silently replaced with unrelated versions. This can make the source
artifact substantially larger than the runtime. Publish and retain the companion
alongside the corresponding runtime; neither manifests nor a URL-only list substitute
for corresponding sources.

Ghostscript is distributed under its upstream AGPL terms; other components and
Foomatic data carry their respective upstream licenses. This document does not
relicense those works or assign one blanket license to the assembled image.
Read the preserved COPYING/LICENSE/COPYRIGHT/NOTICE files and Ubuntu copyright
files for actual terms. Review distribution obligations before publication; the
artifact structure is evidence/support, not a legal-compliance certification.

## Runtime architecture and hardening

Source-built libraries are installed in `/usr/lib`; `LD_LIBRARY_PATH=/usr/lib`
places them ahead of Noble multiarch libraries with the same SONAME. Build-time
closure rejects unintended distribution library fallbacks for libcups, libppd,
libcupsfilters, and PAPPL.

The runtime image defaults to non-root execution:
* Image defaults to non-root UID/GID `584792:584792` with all SUID/SGID bits and file
  capabilities stripped; CUPS USB backend mode is `0755`.
* Deployment manifests enforce container security settings, including `no-new-privileges`,
  `cap-drop: ALL`, and a read-only root filesystem (`readOnlyRootFilesystem: true`).
* HOME is set to `/state`; non-root certificates and configuration reside in private
  storage paths under `/state`, requiring writable mounts only for persistent `/state` and
  ephemeral `/tmp`.
* Restoring persistent spool state resumes unfinished print jobs across restarts; startup
  never generates or submits automatic test jobs.
