# NTFS Bridge — macOS app for safe read/write on external NTFS drives

A native macOS (SwiftUI) app that lets you use an existing NTFS-formatted
external drive (e.g. a 1 TB Toshiba with ~665 GB of files) on a Mac:
see it in a dashboard, copy folders to it, verify the copies, manage files,
and eject safely — **without formatting it and without losing Windows
compatibility.**

## How writing works (honest version)

macOS reads NTFS natively but ships **no supported NTFS write driver**.
NTFS Bridge therefore ships its own proven write engine and never pretends:

- The app bundles **NTFS-3G 2026.9.28** (built from pinned upstream source
  by `scripts/bundle-engine.sh`, provenance in
  `Resources/engine-info.json`) — the same reference engine Linux ships.
- The engine needs **FUSE-T** (free for non-commercial use) as a system
  companion: a kext-free runtime, no Recovery-mode change, installed once
  from its official installer. FUSE-T is never bundled (its license
  requires a commercial license for bundling — see
  `THIRD_PARTY_LICENSES.md`), only detected.
- With **no engine or no FUSE-T**, volumes stay **read-only** and the app
  says so. Nothing is silently remounted. The deprecated hidden
  `mount -o rw` path, SIP disabling, and security-policy changes are
  **never used.**

See [docs/RESEARCH.md](docs/RESEARCH.md) for the driver evaluation,
[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for the design,
[docs/INDEPENDENT-EDITION-ASSESSMENT.md](docs/INDEPENDENT-EDITION-ASSESSMENT.md)
for the independence plan and its field validation,
[docs/INSTALL.md](docs/INSTALL.md) for setup,
[docs/NTFS-INTEGRATION-TESTS.md](docs/NTFS-INTEGRATION-TESTS.md) for the
hardware test plan, and [THIRD_PARTY_LICENSES.md](THIRD_PARTY_LICENSES.md)
for every third-party component and its obligations.

## Layout

- `Package.swift` — SwiftPM package (library + app + tests)
- `Sources/NTFSBridgeCore/` — testable logic: drive detection, backend
  detection + `BackendManager`, mount commands, health checks, copy engine
  (`TransferEngine`), file operations (`FileOps`), checksums, activity log,
  safety guards
- `Sources/NTFSBridgeApp/` — SwiftUI app (dashboard, transfers, file
  management, eject, logs)
- `Resources/` — bundled engine (`bin/ntfs-3g`), its GPLv2 text, provenance
  (`engine-info.json`) and linkage audit (`engine-linkage.txt`)
- `Tests/NTFSBridgeCoreTests/` — 52 unit tests + 4 NTFS integration tests
  (`swift test`; integration tests need `NTFSBRIDGE_TEST_VOLUME`)
- `scripts/` — `build-app.sh` (packaging), `bundle-engine.sh` (pinned
  engine build), `create-test-image.sh` (disposable test volume)
- `docs/` — research, architecture, install, security, test plan, assessment

## Build, test, run

Prerequisites: Xcode 16+ (Xcode 27 on macOS 26/27 tested), Swift 6,
macOS 14+ SDK. FUSE-T installed (for the engine and integration tests).

```bash
cd ntfs-bridge
swift build                          # debug build
swift test                           # 52 unit tests, all must pass
./scripts/bundle-engine.sh           # build bundled engine (needs NTFS3G_SRC, once per pin)
./scripts/build-app.sh               # produces dist/NTFSBridge.app (release)
open dist/NTFSBridge.app
```

NTFS integration tests (disposable volume only — never the real drive):

```bash
NTFSBRIDGE_TEST_VOLUME=/Volumes/NTFS-TEST swift test --filter NTFSIntegration
```

## What the app does

- **Dashboard** — external drives with name, filesystem, capacity, free
  space, and an explicit **Read-only / Read & write** badge (kernel
  verdict, never a guess).
- **Enable NTFS write** — health check first; remount only via the resolved
  engine (bundled first) and only after an explicit macOS admin prompt;
  success is re-verified against the kernel before the badge changes.
- **File transfer** — drag & drop or file picker/paste, nested folders,
  large files, progress + speed + ETA, cancel, retry, SHA-256 verification,
  temp-file atomic writes (no half-written files), never deletes sources,
  never overwrites without your explicit tick.
- **File management** — create folders, rename (never overwrites), delete
  with explicit two-step confirmation. Gated on writable mounts; the drive
  itself can never be renamed or deleted.
- **Safe eject** — `diskutil eject` with unsafe-disconnect warnings.
- **Activity log** — every mount, copy, error, and eject, persisted as JSONL
  under `~/Library/Application Support/NTFSBridge/`.
