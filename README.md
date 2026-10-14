# Epson Printer Application Container

This repository builds container images for the [OpenPrinting Ghostscript Printer Application](https://github.com/OpenPrinting/ghostscript-printer-app) on Ubuntu 24.04 (linux/amd64). The target configuration bundles Ghostscript 10.08.0 and only the generic Epson ESC/P dot-matrix PPD (`Generic-ESC_P_Dot_Matrix_Printer-epson.ppd`, driver `epson`) for server-side rendering over IPP. Other candidate PPDs (`lq850`, `epsonc`) are omitted.

This is an image build repository only. Cluster manifests, deployment recipes, and infrastructure configurations are maintained separately. Automated CI checks do not access physical printers or perform production printing; validation uses isolated offline containers and ephemeral file sinks.

## Driver and Printer Configuration Target

The container image provides server-side rendering for the Epson LQ-1600KIII (non-H) dot-matrix printer via a USB-to-parallel bridge:

- **Retained PPD**: `Generic-ESC_P_Dot_Matrix_Printer-epson.ppd` (driver `epson`).
- **Driver slug**: `generic--esc-p-dot-matrix-printer--epson-recommended-en`
- **Canonical queue**: `epson-lq1600kiii-epson`
- **Discovery name**: Advertised over DNS-SD/mDNS as `Epson LQ-1600KIII` (persisted via local IPP administration; internal canonical queue name remains unchanged).
- **Device URI**: `cups:usb://USB2.0-Print/?serial=0.0`
- **Resolution tiers and client mapping**: Advertises four standard square IPP resolutions (`60x60dpi`, `120x120dpi`, `180x180dpi`, and `360x360dpi`) as a compatibility scheme targeting confirmed square-only capability filtering in Windows IPP components (such as `APMon.dll`). Presentation of all four tiers in native Windows print dialogs remains subject to live verification, and cannot be guaranteed across all Windows print stacks or UI variants. The server-side rendering filter transparently maps these tiers to physical ESC/P dot-matrix output: `60x60` &rarr; `60x60`, `120x120` &rarr; `120x72`, `180x180` &rarr; `180x180`, and `360x360` &rarr; `360x216`. Client logical rendering tiers do not represent physical 360×360 dot-matrix hardware capability. Default resolution is `180x180dpi` (`normal`).
- **Quality mapping**: `draft` &rarr; `60x60dpi` (GS: `60x60`), `normal` &rarr; `180x180dpi` (GS: `180x180`), `high` &rarr; `360x360dpi` (GS: `360x216`). Explicit resolution attributes take precedence over quality presets. Quality levels control raster rendering resolution, not mechanical bidirectional or unidirectional head passes.
- **Color mode**: Strictly monochrome (`print-color-mode monochrome`). Erroneous color capabilities and duplicate proprietary resolution controls are removed.
- **Media and options**: Supported media options, copies, orientation, and scaling are preserved; physical boundaries for all sheet dimensions and continuous stationery remain subject to physical hardware verification.
- **Hardware bridge**: Pinned for USB2.0-Print USB-to-parallel converters (`1a86:7584`). The stable device URI patch remains necessary because unreliable IEEE-1284 device IDs cause URI drift; the patch uses USB descriptors to construct deterministic device identities. On this specific bridge, `GET_PORT_STATUS` returns `EPIPE` regardless of whether the printer is powered on or off, so port status cannot be used to determine printer power, and absence of `/dev/usb/lp0` does not indicate an offline device.

## Runtime Security and Boundaries

The runtime image is designed for isolated, least-privilege execution:
- **Non-root execution**: Runs as UID/GID `584792:584792`.
- **Filesystem**: Supports a read-only root filesystem (`readOnlyRootFilesystem: true`), requiring only writable mounts for `/state` and `/tmp`.
- **Privilege stripping**: All SUID/SGID bits and file capabilities are stripped. The CUPS USB backend is mode `0755`.
- **Entrypoint**: Defaults to `help` (prints diagnostics) or `inspect` (displays Ghostscript version and installed PPDs) without starting network services. The `server` command must be invoked explicitly.
- **State isolation and startup safety**: Production container startup never generates or submits test print jobs. Restoring persistent state only resumes existing unfinished ordinary print jobs (currently 0 pending). Refraining from physical print submissions while the printer is powered off is an operational constraint for the current testing round, not a permanent architectural restriction against spooling ordinary client jobs.
- **Network discovery**: Avahi and D-Bus services are not started automatically; local network mDNS discovery requires separate orchestration.

## Compatibility and Security Notice

- **Hardware compatibility**: The user approved a physical print rendered with the generic `epson` driver at 360×180 dpi. The earlier `lq850` trial produced blurry output. Windows discovery, queue addition, and 2-tier square capability reporting (`60x60`, `180x180`) were previously confirmed with live client evidence; presentation of all four square tiers under the new friendly name, physical print quality for 360×216 dpi, and Android client discovery remain pending live verification.
- **Security posture**: Updating to Ghostscript 10.08.0 provides recent upstream releases, but makes no definitive claim of fixing specific historical CVEs or ensuring vulnerability-free operation. Deployers must pin cryptographic digests and restrict network exposure. The service must never be exposed to the public Internet.

## Artifacts and Traceability

Release builds publish three matching container images to the GitHub Container Registry (GHCR):
- **Runtime**: `ghcr.io/zjm54321/epson-printer-app@sha256:55b986fb6a3c37efb82692d161098aeb7cf9fd0da197bb29df935b43f0e9db0b`
- **Discovery**: `ghcr.io/zjm54321/epson-printer-discovery@sha256:f73cca094fe5622802f451e337196a5816131ed4881664224eef145222d0793c`
- **Source companion**: `ghcr.io/zjm54321/epson-printer-app-sources@sha256:68100b3e03cd4aed2c5a2a014d61d6c9cec7149a2c2e987c7893c57322f180a6`

Published from commit `66594761cd2ee46fa117530161fae3103b145ed5` via [CI run 38518321622](https://github.com/zjm54321/epson-printer-app/actions/runs/38518321622). Anonymous registry inspection verified all three image digests and configuration IDs match CI build records. These published artifacts incorporate the square compatible resolution mapping (`60x60`, `120x120`, `180x180`, `360x360`) and the persistent DNS-SD discovery name `Epson LQ-1600KIII`; downstream GitOps deployment and live client testing remain pending. The earlier `dfffa34` build is superseded as a historical milestone.

The source companion contains corresponding source archives, build recipes, and package manifests. Keep the matching companion available alongside each runtime release to support applicable source-distribution obligations. See [THIRD_PARTY.md](THIRD_PARTY.md) for licenses and pinned source hashes; this packaging is not a legal-compliance certification.

## Continuous Integration Gates

Build validation is tracked in [GitHub Actions](https://github.com/zjm54321/epson-printer-app/actions/workflows/image.yml). On push to `main` at commit `6659476`, CI run 38518321622 passed all gates:
1. Static analysis (`scripts/check-static.py`).
2. Exact runtime and discovery image tests (`scripts/verify-image.sh`):
   - Preflight: Ghostscript binary, device support, ELF contract, and private D-Bus/Avahi daemon readiness.
   - Profile verification: Exactly 2 offline PrintJobs and 1 controlled test-server restart (ephemeral file sinks only; no connection to physical hardware):
     * **Case 1**: Fresh test queue setup and friendly discovery name `Epson LQ-1600KIII` persistence across a controlled test-server restart, after which the test script submits one PDF fixture job at normal 180×180 dpi rendered to 7,156 ESC/P bytes with filter process exiting zero.
     * **Case 2**: One `sgray_8` PWG raster fixture with `120x72dpi` input requested at `360x360dpi` (overriding `draft` quality preset) rendered by Ghostscript to `-r360x216` (44,189 ESC/P bytes) with full original 1020x792 / row 1020 bits 8 header geometry preserved and zero filter exit status.
3. Source companion assembly and image publication matching verified build digests.

## Local Build and Verification

A Nix development shell (`nix develop`) is provided for linting tools; it does not supply a Docker daemon.

Build and verify using Docker:
```bash
# Build runtime image
docker build --platform linux/amd64 --target runtime -t epson-printer-app:test .

# Build discovery image
docker build --platform linux/amd64 --target discovery -t epson-printer-discovery:test .

# Run offline verification scenarios
bash scripts/verify-image.sh epson-printer-app:test epson-printer-discovery:test

# Build source companion
docker build --platform linux/amd64 --target sources -t epson-printer-app-sources:test .
```

## Package Visibility and Access

Published packages (`epson-printer-app`, `epson-printer-discovery`, and `epson-printer-app-sources`) are public on GHCR. Unauthenticated anonymous pull access has been verified for existing published packages. Downstream deployments reference immutable digests once new images are published.
