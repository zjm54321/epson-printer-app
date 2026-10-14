# Epson Printer Application Container

This repository builds container images for the [OpenPrinting Ghostscript Printer Application](https://github.com/OpenPrinting/ghostscript-printer-app) on Ubuntu 24.04 (linux/amd64). The target configuration bundles Ghostscript 10.08.0 and only the generic Epson ESC/P dot-matrix PPD (`Generic-ESC_P_Dot_Matrix_Printer-epson.ppd`, driver `epson`) for server-side rendering over IPP. Other candidate PPDs (`lq850`, `epsonc`) are omitted.

This is an image build repository only. Cluster manifests, deployment recipes, and infrastructure configurations are maintained separately. Automated CI checks do not access physical printers or perform production printing; validation uses isolated offline containers and ephemeral file sinks.

## Driver and Printer Configuration Target

The container image provides server-side rendering for the Epson LQ-1600KIII (non-H) dot-matrix printer via a USB-to-parallel bridge:

- **Retained PPD**: `Generic-ESC_P_Dot_Matrix_Printer-epson.ppd` (driver `epson`).
- **Driver slug**: `generic--esc-p-dot-matrix-printer--epson-recommended-en`
- **Canonical queue and public path**: Internal queue name `epson-lq1600kiii-epson` is preserved for administrative and state continuity. The canonical public IPP endpoint is `/ipp/print/epson_lq-1600kiii` (web: `/epson_lq-1600kiii/`). The old public web path returns HTTP 404.
- **Discovery name and model metadata**: Advertised over DNS-SD/mDNS as `Epson LQ-1600KIII` (persisted via local IPP administration). Model is `Epson LQ-1600KIII` with fallback IEEE-1284 device ID `MFG:EPSON;MDL:LQ-1600KIII;CMD:ESCP24K,PRPXL24,BDC;CLS:PRINTER;` when adapter identification is empty or matches the legacy short ID. Genuine hardware IDs (including serial numbers) are preserved. The CMD field reflects hardware command modes and does not add server document formats. Unmeasured pages-per-minute attributes are omitted rather than publishing arbitrary speed estimates.
- **Device URI and hardware bridge**: Pinned for USB2.0-Print USB-to-parallel converters (`1a86:7584`). Actual sysfs exposes product `USB2.0-Print` without manufacturer or serial strings; `cups:usb://USB2.0-Print/?serial=0.0` uses a backend fallback descriptor, not a real hardware serial. The stable URI patch remains necessary because IEEE-1284 ID probing is unreliable on this bridge; `GET_PORT_STATUS` returns `EPIPE` regardless of power state, and absence of `/dev/usb/lp0` does not indicate an offline device.
- **Resolution tiers and client mapping**: Advertises four standard square IPP resolutions (`60x60dpi`, `120x120dpi`, `180x180dpi`, and `360x360dpi`) as a compatibility scheme targeting confirmed square-only capability filtering in Windows IPP components (such as `APMon.dll`). Native `PrintCapabilities` enumeration on the test host verified all four square resolution options. The server-side rendering filter transparently maps these tiers to physical ESC/P dot-matrix output: `60x60` &rarr; `60x60`, `120x120` &rarr; `120x72`, `180x180` &rarr; `180x180`, and `360x360` &rarr; `360x216`. Client logical rendering tiers do not represent physical 360×360 dot-matrix hardware capability. Default resolution is `180x180dpi` (`normal`).
- **Quality mapping**: `draft` &rarr; `60x60dpi` (GS: `60x60`), `normal` &rarr; `180x180dpi` (GS: `180x180`), `high` &rarr; `360x360dpi` (GS: `360x216`). Explicit resolution attributes take precedence over quality presets. Quality levels control raster rendering resolution, not mechanical bidirectional or unidirectional head passes.
- **Color mode and default media**: Strictly monochrome (`print-color-mode monochrome`). Default media is A4 (`iso_a4_210x297mm`, `media-source=auto`), matching both server defaults and verified Windows user print tickets.
- **Raster rendering and feature boundaries**: Server-side rasterization uses Ghostscript's generic `epson` device (`gdevepsn.c`), producing standard dot-matrix raster graphics. All directly configurable native options are provided as-is. Standard IPP attributes such as N-up layout and X/Y offsets are not implemented or advertised by the underlying PAPPL stack, and are absent from Windows client captures. No additional special dot-matrix controls (resident fonts, printhead sweep direction, hardware halftone algorithms, N-up, or image shift) are implemented in this change.
- **Media and options**: The Windows XML capability enumeration lists 17 named standard media choices, copies, orientation, scaling, collation, reverse order, and monochrome output. However, physical paper handling limits, custom paper sizes, and continuous-feed stationery boundaries remain unverified on hardware, and the server retains generic media boundaries.

## Runtime Security and Boundaries

The runtime image is designed for isolated, least-privilege execution:
- **Non-root execution**: Runs as UID/GID `584792:584792`.
- **Filesystem**: Supports a read-only root filesystem (`readOnlyRootFilesystem: true`), requiring only writable mounts for `/state` and `/tmp`.
- **Privilege stripping**: All SUID/SGID bits and file capabilities are stripped. The CUPS USB backend is mode `0755`.
- **Entrypoint**: Defaults to `help` (prints diagnostics) or `inspect` (displays Ghostscript version and installed PPDs) without starting network services. The `server` command must be invoked explicitly.
- **State isolation and startup safety**: Production container startup never generates or submits test print jobs. Restoring persistent state only resumes existing unfinished ordinary print jobs (currently 0 pending). Refraining from physical print submissions while the printer is powered off is an operational constraint for the current testing round, not a permanent architectural restriction against spooling ordinary client jobs.
- **Network discovery**: Avahi and D-Bus services are not started automatically; local network mDNS discovery requires separate orchestration.

## Compatibility and Security Notice

- **Hardware and client compatibility**: The user approved a physical print rendered with the generic `epson` driver at 360×180 dpi. The earlier `lq850` trial produced blurry output. On the tested Windows client, the queue is registered to the canonical endpoint `http://192.168.1.127:8000/ipp/print/epson_lq-1600kiii` (model `LQ-1600KIII`, manufacturer `EPSON`, stored device ID `MFG:EPSON;MDL:LQ-1600KIII;`, UUID `b1bd5f3a...`). Native `PrintCapabilities` XML enumeration (SHA-256 `6db6a4f9731130ecc6e8e8067e4cbb19e377789225abebe0b5a7cca26125b29e`) confirmed all four logical square resolutions (`60x60`, `120x120`, `180x180`, `360x360`) under friendly name `Epson LQ-1600KIII`, along with 17 named media choices, orientation, quality, collation, reverse printing, scaling, copies, and monochrome. Separate active print tickets (`DefaultPrintTicket`/`UserPrintTicket`) confirmed default ISO A4 and normal 180×180 dpi grayscale. This client evidence was captured prior to the final CMD/CLS metadata enrichment; display of the expanded device ID has not been re-verified on Windows, and nominal print speed and physical serial number remain unavailable. Extra dot-matrix controls (printer-resident fonts, head direction, hardware halftoning, N-up, image shift) are unsupported by the driver/stack and not implemented; physical handling of custom paper sizes remains unverified on hardware. Physical print quality for 360×216 dpi and Android client discovery remain pending live verification.
- **Security posture**: Updating to Ghostscript 10.08.0 provides recent upstream releases, but makes no definitive claim of fixing specific historical CVEs or ensuring vulnerability-free operation. Deployers must pin cryptographic digests and restrict network exposure. The service must never be exposed to the public Internet.

## Artifacts and Traceability

Release builds publish three matching container images to the GitHub Container Registry (GHCR):
- **Runtime**: `ghcr.io/zjm54321/epson-printer-app@sha256:82e5e6bc4ceeaead818c2a8c1653354f25b9319ed0c615a30f21772c8cecefad`
- **Discovery**: `ghcr.io/zjm54321/epson-printer-discovery@sha256:b8f007fda2a0818c1d26e85443a6e3fe6aac8aa299878b5932d8ca7bd9ec9646`
- **Source companion**: `ghcr.io/zjm54321/epson-printer-app-sources@sha256:0fa701ee931253cabf581f77ff7cee3af4e740e7714c6813627070e837f86dc0`

Published from commit `87636cd7910809ba7bfe98a6ea7f2034dd64190a` via [CI run 38543535151](https://github.com/zjm54321/epson-printer-app/actions/runs/38543535151). Anonymous registry inspection verified all three image digests and configuration IDs match CI build records. These published artifacts incorporate the full fallback IEEE-1284 device ID (`MFG:EPSON;MDL:LQ-1600KIII;CMD:ESCP24K,PRPXL24,BDC;CLS:PRINTER;`), and are live in production via GitOps commit `d02a372`.

The source companion contains corresponding source archives, build recipes, and package manifests. Keep the matching companion available alongside each runtime release to support applicable source-distribution obligations. See [THIRD_PARTY.md](THIRD_PARTY.md) for licenses and pinned source hashes; this packaging is not a legal-compliance certification.

## Continuous Integration Gates

Build validation is tracked in [GitHub Actions](https://github.com/zjm54321/epson-printer-app/actions/workflows/image.yml). On push to `main` at commit `87636cd`, CI run 38543535151 passed all gates:
1. Static analysis (`scripts/check-static.py`).
2. Exact runtime and discovery image tests (`scripts/verify-image.sh`):
   - Preflight: Ghostscript binary, device support, ELF contract, and private D-Bus/Avahi daemon readiness.
   - Profile verification: Exactly 2 offline PrintJobs and 1 controlled test-server restart (ephemeral file sinks only; no connection to physical hardware):
     * **Case 1**: Fresh test queue setup with explicit hostname preserving bare `epson-printer` from Avahi `.local` override (avoiding UUID shifts across restarts); submission of one PDF fixture job at normal 180×180 dpi A4 before restart rendering 6,445 ESC/P bytes with zero filter exit code; controlled test-server restart proving retained queue identity, full fallback device ID, A4 defaults, new public path `/ipp/print/epson_lq-1600kiii`, and completed job ID 1 retained. New web endpoint returns HTTP 200; old path is rejected.
     * **Case 2**: One `sgray_8` PWG raster fixture with `120x72dpi` A4 input requested at `360x360dpi` (overriding `draft` quality preset) rendered by Ghostscript to `-r360x216` (42,899 ESC/P bytes) with full original 992x841, row 992, bits 8 header geometry preserved and zero filter exit status.
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
