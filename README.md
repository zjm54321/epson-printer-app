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
- **State isolation and startup safety**: Production container startup never generates or submits test print jobs. Restoring persistent state may resume existing unfinished print jobs; use a fresh spool volume for inert testing.
- **Network discovery**: Avahi and D-Bus services are not started automatically; local network mDNS discovery requires separate orchestration.

## Compatibility and Security Notice

- **Hardware compatibility**: The user approved a physical print rendered with the generic `epson` driver at 360×180 dpi. The earlier `lq850` trial produced blurry output. Physical quality for 360×216 dpi and the other standard resolution choices, as well as client UI options, remain to be verified on physical hardware.
- **Security posture**: Updating to Ghostscript 10.08.0 provides recent upstream releases, but makes no definitive claim of fixing specific historical CVEs or ensuring vulnerability-free operation. Deployers must pin cryptographic digests and restrict network exposure. The service must never be exposed to the public Internet.

## Artifacts and Traceability

Release builds publish three matching container images to the GitHub Container Registry (GHCR):
- **Runtime**: `ghcr.io/zjm54321/epson-printer-app@sha256:1d6b04eacbf6d9cf8a940fdfc0f5de05907d2ab24a74a37c7f17db1477754230`
- **Discovery**: `ghcr.io/zjm54321/epson-printer-discovery@sha256:ba6adad65f1f1576e28d2d0a622f2b85604dc5d032ead93d27c4bf70c2bf3abc`
- **Source companion**: `ghcr.io/zjm54321/epson-printer-app-sources@sha256:973d7feb14637ee09229db64f241c5bd914437e087391b4f161587d82434c94e`

Published from commit `dfffa343b79d8066c431759e8af3295b9df04882` via [CI run 38436891490](https://github.com/zjm54321/epson-printer-app/actions/runs/38436891490). Downstream deployments pin these exact immutable digests.

The source companion contains corresponding source archives, build recipes, and package manifests. Keep the matching companion available alongside each runtime release to support applicable source-distribution obligations. See [THIRD_PARTY.md](THIRD_PARTY.md) for licenses and pinned source hashes; this packaging is not a legal-compliance certification.

## Continuous Integration Gates

Build validation is tracked in [GitHub Actions](https://github.com/zjm54321/epson-printer-app/actions/workflows/image.yml). Every pull request and `main` push must pass:
1. Static analysis (`scripts/check-static.py`).
2. Exact runtime and discovery image tests (`scripts/verify-image.sh`):
   - Preflight: Ghostscript binary, device support, ELF contract, and private D-Bus/Avahi daemon readiness.
   - Profile verification: Exactly 2 offline PrintJobs and 1 controlled test-server restart (ephemeral file sinks only; no connection to physical hardware):
     * **Case 1**: Fresh test queue and canonical defaults (`normal` / `180x180dpi` plus four capabilities), followed by a controlled test-server restart proving retained defaults; test script submits one PDF fixture job rendered to 7,156 ESC/P bytes with filter process exiting zero.
     * **Case 2**: One `sgray_8` PWG raster fixture with `120x72dpi` input rendered to `360x216dpi` explicit output overriding `draft` quality (44,189 ESC/P bytes), validating original 1020x792 / row 1020 bits 8 header geometry, Ghostscript parameters, and zero filter exit status.
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
