# Epson Printer Application Container

This repository builds container images for the [OpenPrinting Ghostscript Printer Application](https://github.com/OpenPrinting/ghostscript-printer-app) on Ubuntu 24.04 (linux/amd64). The target configuration bundles Ghostscript 10.08.0 and only the generic Epson ESC/P dot-matrix PPD (`Generic-ESC_P_Dot_Matrix_Printer-epson.ppd`, driver `epson`) for server-side rendering over IPP. Other candidate PPDs (`lq850`, `epsonc`) are omitted.

This is an image build repository only. Cluster manifests, deployment recipes, and infrastructure configurations are maintained separately. Automated CI checks do not access physical printers or perform production printing; validation uses isolated offline containers and ephemeral file sinks.

## Driver and Printer Configuration Target

The container image provides server-side rendering for the Epson LQ-1600KIII (non-H) dot-matrix printer via a USB-to-parallel bridge:

- **Retained PPD**: `Generic-ESC_P_Dot_Matrix_Printer-epson.ppd` (driver `epson`).
- **Driver slug**: `generic--esc-p-dot-matrix-printer--epson-recommended-en`
- **Canonical queue**: `epson-lq1600kiii-epson`
- **Device URI**: `cups:usb://USB2.0-Print/?serial=0.0`
- **Resolution tiers**: Four standard IPP resolutions: `60x60dpi`, `120x72dpi`, `180x180dpi`, and `360x216dpi`. The four-tier limit is imposed by the underlying PAPPL library, not the IPP protocol. Default resolution is `180x180dpi` (`normal`).
- **Quality mapping**: `draft` &rarr; `60x60dpi`, `normal` &rarr; `180x180dpi`, `high` &rarr; `360x216dpi`. Explicit IPP resolution attributes take precedence over quality presets. Quality levels control raster rendering resolution, not mechanical bidirectional or unidirectional head passes.
- **Color mode**: Strictly monochrome (`print-color-mode monochrome`). Erroneous color capabilities and duplicate proprietary resolution controls are removed.
- **Media and options**: Supported media options, copies, orientation, and scaling are preserved; physical boundaries for all sheet dimensions and continuous stationery remain subject to physical hardware verification.
- **Hardware bridge**: Pinned for USB2.0-Print USB-to-parallel converters (`1a86:7584`). The stable device URI patch remains necessary because unreliable IEEE-1284 device IDs cause URI drift; the patch uses USB descriptors to construct deterministic device identities. On this specific bridge, `GET_PORT_STATUS` returns `EPIPE` regardless of whether the printer is powered on or off, so port status cannot be used to determine printer power, and absence of `/dev/usb/lp0` does not indicate an offline device.

## Runtime Security and Boundaries

The runtime image is designed for isolated, least-privilege execution:
- **Non-root execution**: Runs as UID/GID `584792:584792`.
- **Filesystem**: Supports a read-only root filesystem (`readOnlyRootFilesystem: true`), requiring only writable mounts for `/state` and `/tmp`.
- **Privilege stripping**: All SUID/SGID bits and file capabilities are stripped. The CUPS USB backend is mode `0755`.
- **Entrypoint**: Defaults to `help` (prints diagnostics) or `inspect` (displays Ghostscript version and installed PPDs) without starting network services. The `server` command must be invoked explicitly.
- **State isolation**: Restoring historical spool directories may resume queued print jobs; always supply a fresh, empty `/state` volume for inert testing.
- **Network discovery**: Avahi and D-Bus services are not started automatically; local network mDNS discovery requires separate orchestration.

## Compatibility and Security Notice

- **Hardware compatibility**: The user approved a physical print rendered with the generic `epson` driver at 360×180 dpi. The earlier `lq850` trial produced blurry output. The four new standard resolution choices and client UI options still need release and live-device verification.
- **Security posture**: Updating to Ghostscript 10.08.0 provides recent upstream releases, but makes no definitive claim of fixing specific historical CVEs or ensuring vulnerability-free operation. Deployers must pin cryptographic digests and restrict network exposure. The service must never be exposed to the public Internet.

## Artifacts and Traceability

Release builds publish three matching container images to the GitHub Container Registry (GHCR):
- **Runtime**: `ghcr.io/zjm54321/epson-printer-app:sha-<commit>`
- **Discovery**: `ghcr.io/zjm54321/epson-printer-discovery:sha-<commit>`
- **Source companion**: `ghcr.io/zjm54321/epson-printer-app-sources:sha-<commit>`

The source companion contains corresponding source archives, build recipes, and package manifests. Keep the matching companion available alongside each runtime release to support applicable source-distribution obligations. See [THIRD_PARTY.md](THIRD_PARTY.md) for licenses and pinned source hashes; this packaging is not a legal-compliance certification.

Always reference images by immutable digest (`@sha256:...`) in downstream deployments once published. Digests from prior commit `7c706be` represent the earlier testing milestone; current target configuration builds are pending CI completion.

## Continuous Integration Gates

Build validation is tracked in [GitHub Actions](https://github.com/zjm54321/epson-printer-app/actions/workflows/image.yml). Every pull request and `main` push must pass:
1. Static analysis (`scripts/check-static.py`).
2. Exact runtime and discovery image tests (`scripts/verify-image.sh`):
   - Scenario 1/3: Ghostscript binary, device support, and ELF contract.
   - Scenario 2/3: D-Bus and Avahi daemon readiness, queue-less isolated server startup.
   - Scenario 3/3: Generic ESC/P profile verification across three behavioral groups using an ephemeral file sink (identity/defaults/default queue, actual PDF/PS filters across four explicit resolution pairs plus quality fallback and conflicts, and real PWG black_1/sgray_8 rasterization across input/output DPI pairs).
3. Source companion assembly.

These checks represent release requirements for the upcoming build; specific test suite results remain pending until CI completes on `main`.

On pushes to `main`, CI tests the images once, verifies identical image IDs, and publishes the verified artifacts.

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
