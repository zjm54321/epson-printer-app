# Corresponding sources and runtime boundary

This is a native Ubuntu 24.04 **linux/amd64** build of the existing OpenPrinting
Ghostscript Printer Application, not a replacement print implementation. The
default entrypoint prints local help only. `server` is explicit. No CUPS scheduler,
network backend, Avahi daemon, D-Bus service, supervisor, HP/HPIJS driver or firmware
is installed by the source-build recipe. Avahi **client libraries** remain PAPPL
dependencies; discovery is not a separately launched component here.

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
| Foomatic DB | 20240504, b1324cde08349583c44a20067a4d877e087d75fe | three upstream Epson/ESC-P PPDs |
| Ubuntu foomatic-db-engine | 4.0.13-6 | build-time PPD generator; not in runtime |

QPDF comes from Noble (build requires >=11), not a separate source build.
Ordinary Ubuntu security updates are allowed. The pinned base plus apt indexes
does **not** provide bit-identical reproducibility. Build/runtime package manifests
record binary **and source** versions. Full Git commits are verified before
archiving; generated Git archive SHA256s are recorded after acquisition, not
presented as independently preverified archive hashes. Ghostscript's official
archive is checked against the preverified SHA256 and byte length.

## Source companion and licenses

Build targets are `runtime` and `sources`. The scratch `sources` image contains:

* the exact upstream archives used, including complete upstream license files;
* `licenses/upstream/` preserving discovered license/notice paths, and original
  Ubuntu source archives plus Debian/Ubuntu patches and `.dsc` files;
* this Dockerfile, lock, fixtures and build/test scripts under `build-recipe/`;
* a patches inventory (currently **no local upstream patches**);
* resolved binary/source package versions, selected PPD generator inputs,
  build-time ELF resolutions, source-library hashes and `SHA256SUMS`.

The companion requests exact corresponding source versions for **all** runtime
base packages, copied distro ELF dependencies and the Foomatic generator.
Other build-only tools are version-inventoried but not redistributed. Missing
historical apt sources fail the companion build;
they are not silently replaced with unrelated versions. This can make the source
artifact substantially larger than the runtime. Publish and retain the companion
alongside the tested runtime; neither manifests nor a URL-only list substitute
for corresponding sources.

Ghostscript is distributed under its upstream AGPL terms; other components and
Foomatic data carry their respective upstream licenses. This document does not
relicense those works or assign one blanket license to the assembled image.
Read the preserved COPYING/LICENSE/COPYRIGHT/NOTICE files and Ubuntu copyright
files for actual terms. Review distribution obligations before publication; the
artifact structure is evidence/support, not a legal-compliance certification.

## Narrow runtime and test claims

Source-built libraries are installed in `/usr/lib`; `LD_LIBRARY_PATH=/usr/lib`
places them ahead of Noble multiarch libraries with the same SONAME. Build-time
closure rejects a distro libcups/libppd/libcupsfilters/PAPPL resolution. Scenario
1 rechecks actual runtime `ldd` paths and source-library hashes for the app, USB
backend and filters, as well as actual `gs --version` and required devices. Pins
alone, headers and `cups-config` output are not runtime-version proof.

Runtime UID/GID is 584792; no SUID/SGID/file capabilities are retained. USB backend
mode is 0755, not the upstream packaging's 4755. Runtime tests use cap-drop ALL,
no-new-privileges, read-only root, no network, no USB and fresh tmpfs `/state` and
`/tmp`. HOME is `/state`; nonroot CUPS/GnuTLS certificates belong under
`/state/.cups/ssl`, never writable `/etc`. State/spool directories are private.
Group 0 device-access permission is a later deployment choice, not proof that
nonroot libusb operations work. Never loosen these restrictions to make a test pass.

**Fresh state is mandatory for inert tests. Restored state can resume old jobs.**
The explicit server test uses the existing retrofit save callback and verifies
zero queues with Get-Printers, including absence of any printer-attributes group.
It does not start automatic discovery, create a queue, submit a job or invoke a
USB backend. A separate scenario invokes only installed foomatic-rip with the
selected installed LQ-850 PPD and the repository-owned one-page PostScript fixture,
writing to a temporary file and checking ESC/P bytes. This is not a claim that
the physical printer is an LQ-850 or an exact LQ-1600KIII match.

Exactly three functional scenarios are defined in `scripts/verify-image.sh`.
Actual build/configure paths, generated PPD behavior, inert PAPPL startup and
filter conversion must pass on the CI Docker runner before publishing. No local
Docker daemon installation, physical printing, host mutation or automatic test
page is part of this repository's validation.
