# Epson Printer Application Container

This repository builds container images for the [OpenPrinting Ghostscript Printer Application](https://github.com/OpenPrinting/ghostscript-printer-app) on Ubuntu 24.04 (linux/amd64). It bundles Ghostscript 10.08.0 and selected Epson ESC/P dot-matrix PPDs (`epson`, `lq850`, `epsonc`) to expose legacy printers over driverless IPP.

This is an image build repository only. Cluster manifests, deployment recipes, and infrastructure configurations are maintained separately. The build and CI checks do not access physical printers or submit print jobs.

## Runtime Security and Boundaries

The runtime image is designed for isolated, least-privilege execution:
- **Non-root execution**: Runs as UID/GID `584792:584792`.
- **Filesystem**: Supports a read-only root filesystem (`readOnlyRootFilesystem: true`), requiring only writable mounts for `/state` and `/tmp`.
- **Privilege stripping**: All SUID/SGID bits and file capabilities are stripped. The CUPS USB backend is mode `0755`.
- **Entrypoint**: Defaults to `help` (prints diagnostics) or `inspect` (displays Ghostscript version and installed PPDs) without starting network services. The `server` command must be invoked explicitly.
- **State isolation**: Restoring historical spool directories may resume queued print jobs; always supply a fresh, empty `/state` volume for inert testing.
- **Network discovery**: Avahi and D-Bus services are not started automatically; local network mDNS discovery requires separate orchestration.

## Compatibility and Security Notice

- **Hardware compatibility**: The selected PPDs are Epson ESC/P driver candidates. Compatibility with specific hardware (such as the Epson LQ-1600KIII) is unverified until tested with an actual device.
- **Security posture**: Updating to Ghostscript 10.08.0 provides recent upstream releases, but makes no definitive claim of fixing specific historical CVEs or ensuring vulnerability-free operation. Deployers must pin cryptographic digests and restrict network exposure.

## Artifacts and Traceability

Release builds publish two matching container images to the GitHub Container Registry (GHCR):
- **Runtime**: `ghcr.io/zjm54321/epson-printer-app:sha-<commit>`
- **Source companion**: `ghcr.io/zjm54321/epson-printer-app-sources:sha-<commit>`

The source companion contains corresponding source archives, build recipes, and package manifests. Keep the matching companion available alongside each runtime release to support applicable source-distribution obligations. See [THIRD_PARTY.md](THIRD_PARTY.md) for licenses and pinned source hashes; this packaging is not a legal-compliance certification.

Always reference images by immutable digest (`@sha256:...`) in downstream deployments once published.

## Continuous Integration Gates

Build validation is tracked in [GitHub Actions](https://github.com/zjm54321/epson-printer-app/actions/workflows/image.yml). Every pull request and `main` push must pass:
1. Static analysis (`scripts/check-static.py`).
2. Exact runtime image tests (`scripts/verify-image.sh`):
   - Ghostscript binary and device verification.
   - Queue-less isolated server startup without network or USB devices.
   - Offline rasterization of a PostScript test fixture into ESC/P control bytes using `foomatic-rip` and `Epson-LQ-850-lq850.ppd`.
3. Source companion assembly.

These are release requirements, not a claim that the initial implementation has passed them. Consult the workflow results for build and test evidence.

On pushes to `main`, CI tests the images once, verifies identical image IDs, and publishes the verified artifact.

## Local Build and Verification

A Nix development shell (`nix develop`) is provided for linting tools; it does not supply a Docker daemon.

Build and verify using Docker:
```bash
# Build runtime image
docker build --platform linux/amd64 --target runtime -t epson-printer-app:test .

# Run offline verification scenarios
bash scripts/verify-image.sh epson-printer-app:test

# Build source companion
docker build --platform linux/amd64 --target sources -t epson-printer-app-sources:test .
```

## Maintainer Setup: Initial GHCR Package Visibility

GHCR initializes new container packages as **Private** by default:
1. Wait for the initial workflow run on `main` to publish both packages.
2. In GitHub, navigate to **Packages** for `epson-printer-app` and `epson-printer-app-sources`.
3. Under **Package Settings** &rarr; **Danger Zone** &rarr; **Change visibility**, select **Public** for each package.
4. Verify unauthenticated anonymous pull access before referencing digests in downstream configurations.

GitHub does not allow a public package to be made private again.
