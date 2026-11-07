# NTFS Bridge — LLM Context Report

> Generated 2026-11-07 from a live read of the repo. Purpose: give an LLM
> everything it needs to work on this project without re-discovering it.
> Source of truth is the code; docs state intent and two of them have stale
> test counts (noted in §9).

## 1. One-paragraph summary

NTFS Bridge is a native macOS SwiftUI app (Swift 6, SwiftPM, macOS 14+ SDK,
Xcode 16+) that lets a user keep using an **existing NTFS-formatted external
drive** (the motivating case: a 1 TB Toshiba with ~714 GB of files) on a Mac
**without formatting it**, so it keeps working on Windows. macOS reads NTFS
natively but has **no supported NTFS write path**, so the app ships **no
filesystem driver of its own**. It is a *safe orchestrator*: detect drives →
show read-only vs read/write honestly → health-check → remount read/write
only through a proven installed third-party backend (NTFS-3G+FUSE,
FSKit driver, or commercial driver) with an explicit macOS admin prompt →
copy folders with progress + SHA-256 verification → safe eject → persistent
activity log. With no backend installed it stays loudly read-only and never
fakes writing.

## 2. Non-negotiable design rules (enforced in code, not just docs)

1. **No driver in this repo.** No format/erase/partition code path exists.
2. **Never silently elevate.** The single privileged op (NTFS-3G remount)
   runs via `osascript … with administrator privileges`; macOS prompts.
   No SIP change, no hidden `mount -o rw`, no root daemon.
3. **Never write to an unclean volume.** Hibernation marker
   (`hiberfil.sys`) or dirty state ⇒ stays read-only, user told to fix on
   Windows (`chkdsk` / clean shutdown).
4. **Never overwrite silently.** Pre-flight + per-file checks fail the job
   unless the user ticked overwrite.
5. **Never leave half-written files.** Stream to
   `<name>.ntfsbridge-partial-<uuid>`, then atomic rename; partials cleaned
   on cancel/failure/retry; checksum mismatch ⇒ bad copy removed.
6. **Copy is copy.** No delete-source / move anywhere in the codebase.
7. **Commands are allow-listed** (`info/list/unmount/eject/mount/
   verifyVolume` + ntfs-3g remount); `SafetyGuard` throws on
   erase/format/partition/mkfs fragments.

## 3. Repo layout (workspace root: `ntfs-bridge/`)

| Path | What it is |
|---|---|
| `Package.swift` | SwiftPM: library `NTFSBridgeCore`, executable `NTFSBridgeApp`, test target `NTFSBridgeCoreTests`. swift-tools 6.0, macOS 14+ |
| `Sources/NTFSBridgeCore/` | Testable logic (9 files, ~1200 lines). No UI imports |
| `Sources/NTFSBridgeApp/` | SwiftUI app (4 files, ~715 lines) |
| `Tests/NTFSBridgeCoreTests/` | 4 files, **32** `@Test` cases (Swift Testing framework) |
| `docs/` | `RESEARCH.md`, `ARCHITECTURE.md`, `INSTALL.md`, `SECURITY.md` |
| `MANUAL.md` | Bilingual (EN/EL) user manual, 344 lines |
| `README.md` | Project overview + build instructions |
| `scripts/build-app.sh` | Release build → assembles + ad-hoc-signs `dist/NTFSBridge.app` |
| `scripts/create-test-image.sh` | Disposable 2 GB ExFAT sparse image in `/tmp` for safe copy trials |
| `start.command` | Double-click launcher (builds on first run, then opens app) |
| `NTFSBridge.entitlements` | No sandbox, no kext; only user-selected + downloads read-write file access |
| `dist/NTFSBridge.app` | Last packaged app bundle (rebuilt 2026-11-07) |
| `.build/` | Debug build artifacts present |

## 4. Module guide — `NTFSBridgeCore`

| File (~lines) | Contents |
|---|---|
| `Backend.swift` (~292) | `NTFSWriteBackend` enum (`.none/.ntfs3gFuse/.fskit/.commercial`), `BackendStatus` + per-row `BackendCheck[]` + `nextStep` string for the UI checklist, `BackendEnvironment` seam (injectable `fileExists`), `BackendDetector` (pure decision logic + `detectLive()` thin wrapper) |
| `Drive.swift` (~54) | `Drive` struct: id=device node, name, mountPoint, filesystem, capacities, external/ejectable flags, `mountReadOnly`. Derived: `isNTFS`, `showsWritable` (NTFS + mounted + NOT read-only), `usedBytes`, `capacityFraction` |
| `DriveDetector.swift` (~148) | `MountFlags` (authoritative read-only check via `statfs` `MNT_RDONLY` — `diskutil -plist` exposes NO read-only key), `DriveDetector` plist parsing (`DiskUtilInfo`, `DiskList`) kept separate from process execution so tests use fixtures; `isUserVolume` predicate trusts diskutil over FileManager ejectable flags (which lie for some USB drives) |
| `Discovery.swift` (~135) | `Discovery.collectSnapshot()` — **must run off the main thread** (blocking `diskutil` on main at launch aborts via `AG::precondition_failure`). Order: FileManager volumes → `diskutil list` + per-device `info` (catches unmounted NTFS, e.g. dirty/hibernated) → `BackendDetector.detectLive()`. Returns `Snapshot(drives, backend, logLines)` |
| `FilesystemCheck.swift` (~90) | `FilesystemHealth` + `FilesystemCheck.evaluate(...)` (pure). Key learned truth: `diskutil verifyVolume` **always fails on NTFS** (-69886, no Apple NTFS verifier), so for NTFS the check is hibernation-marker + driver's own gatekeeping; `verifyVolume` still gates non-NTFS |
| `MountManager.swift` (~109) | `DiskCommand` (executable+args+requiresAdmin) + builders for the 7 allow-listed verbs + `ntfs3gMountCommand` (picks `/opt/homebrew/bin` vs `/usr/local/bin`, `-o local,allow_other,auto_xattr`, requiresAdmin). `run(_:authorized:)` guards via SafetyGuard, refuses unauthorised admin, runs via `osascript` for admin |
| `TransferEngine.swift` (~243) | `copy(sources:to:allowOverwrite:verifyChecksum:maxRetries:progress:)` async. Full pre-flight validation before any byte; recursive plan; dirs recreated; symlinks recreated (not followed); 1 MiB streaming; retries; per-file overwrite re-check; cancellation; speed/ETA progress; `TransferReport(filesCopied, bytesCopied, verified, duration)`; `TransferError` (cancelled/exists-without-consent/verification/io) |
| `Checksum.swift` (~27) | SHA-256 streamed in 1 MiB chunks (CryptoKit), `verify(source:destination:)` |
| `SafetyGuard.swift` (~54) | `forbidDestructiveCommand` (case-insensitive substring block on erase/format/partition/mkfs family), `validateCopy` (source must exist, no self-copy, no overwrite without consent) |
| `ActivityLog.swift` (~83) | `ActivityLogEntry(date,message)` Codable; `ActivityLogStore` thread-safe (NSLock), JSONL under `~/Library/Application Support/NTFSBridge/`, reloads on init |

## 5. Module guide — `NTFSBridgeApp` (SwiftUI, `@MainActor AppState`)

| File (~lines) | Contents |
|---|---|
| `AppState.swift` (~272) | `TransferJob` (id/sources/progress/status/report/error) + `AppState`: drives, selection, backend, health-per-device, transfers, log lines. Init does **no** disk I/O (launch-crash lesson); `refresh()` + all blocking work via `runBlocking` → detached task. All disk mutations funnel through here (mount, health check, enable-write, copy w/ cancel+retry, eject) with logging + overwrite-consent flow |
| `ContentView.swift` (~399) | Dashboard (drive list, capacity bar, RO/RW badge), driver-status checklist (✓/✗ per probe + next step), health row, drop zone + file picker/paste, transfer rows (progress/speed/ETA/cancel/retry), enable-write sheet, eject, activity log view |
| `Formatters.swift` (~29) | Byte/speed/ETA formatting |
| `NTFSBridgeApp.swift` (~15) | App entry; discovery kicked off from `.task` after first render |

## 6. Write backends (detection order / priority)

1. **`.fskit`** — FSKit user-space drivers (macOS 15.4+/26+): NTFS4Mac, NTFSTool, iBoysoft Extension mode, PolyDrive. Detected via `pluginkit -m -p com.apple.file-system` lines containing "ntfs". Kext-free, preferred on macOS 26. App hands mounting to the driver.
2. **`.ntfs3gFuse`** — NTFS-3G binary (`/opt/homebrew` or `/usr/local`) **plus** a FUSE runtime (`fuse-t.fs` or `macfuse.fs`). ntfs-3g alone (no FUSE) ⇒ cannot enable write. Only backend where *this app* performs the remount (after unmount + health pass + consent + admin prompt).
3. **`.commercial`** — Paragon / Tuxera / iBoysoft Advanced (vendor app detected). App hands off to vendor tooling; never touches their security/Recovery-mode steps.
4. **`.none`** — honestly read-only; UI shows per-probe checklist + the single most useful next install step.

Rejected and never used: from-scratch NTFS driver, Mounty-style hidden remounts, deprecated `mount_ntfs -o rw`, anything requiring SIP disabled.

## 7. User flows (happy paths + gates)

- **Dashboard:** plug drive → Refresh → badge Read-only / Read & write / Not mounted + capacity bar + driver checklist + last health result.
- **Enable write:** select NTFS drive → Check health (hibernation ⇒ blocked with Windows-fix instructions) → Enable → one macOS admin prompt → backend remount (FUSE) or vendor/FSKit handoff → Refresh shows Read & write.
- **Copy:** drag-drop / picker / paste → overwrite OFF by default → progress (bytes/speed/ETA) → per-file SHA-256 → failures name the file, old destination untouched → cancel removes partials, retry supported.
- **Eject:** `diskutil eject` in-app; failed eject ⇒ unsafe-disconnect warning (re-plug + clean eject before writing again).
- **Logs:** every mount/copy/error/eject appended to JSONL; viewable in-app.

## 8. Build, test, run, uninstall

```bash
cd ntfs-bridge
swift build            # debug build
swift test             # 32 tests, all must pass
./scripts/build-app.sh # release → dist/NTFSBridge.app (ad-hoc signed)
open dist/NTFSBridge.app
./scripts/create-test-image.sh  # disposable /tmp volume for safe trials
```

Write-backend installs (one needed for writing): `brew install --cask fuse-t`
+ `brew install --cask ntfstool` (recommended free path; FUSE-T alone is NOT
enough — NTFS-3G is the engine), or an FSKit driver DMG, or a commercial
driver (vendor installer governs its Recovery-mode steps). First launch from
an ad-hoc-signed bundle: right-click → Open. Uninstall: delete the app +
optionally `~/Library/Application Support/NTFSBridge/`; backends removed via
their own uninstallers (nothing driver-like belongs to this app).

## 9. Current state + things an LLM should know before touching code

- **Working tree:** clean git state is unclear (no `.git` readable from this
  session — `git log/status` returned nothing); `.build/debug` and
  `dist/NTFSBridge.app` exist from a 2026-11-07 build.
- **Test counts in docs are stale:** README says 20, MANUAL says 23.
  **Actual: 32** `@Test`s — BackendDetector 13, Drive/health/mount 11,
  SafetyGuard 3, TransferEngine 5. Update the docs if you add tests.
- **Tests use Swift Testing** (`@Suite`/`@Test`/`#expect`), not XCTest
  method names — `grep "func test"` finds nothing.
- **`swift test` currently fails in a sandboxed shell** with
  `sandbox-exec: sandbox_apply: Operation not permitted` while compiling
  `Package.swift` (environment restriction, not a code error). Run it in an
  unsandboxed terminal; last known state per docs/MANUAL is all-green.
- **Hard-won live-Mac lessons baked into the code** (do not "simplify" these
  away): read-only truth comes from `statfs`, never diskutil plist;
  `verifyVolume` never gates NTFS; discovery never runs on the main thread
  (or the app SIGABRTs at launch); `isUserVolume` trusts diskutil over
  FileManager ejectable flags.
- **Tech facts:** Swift 6, `Sendable` throughout Core, CryptoKit SHA-256,
  `osascript` admin prompt, `pluginkit` FSKit probing, JSONL log with
  ISO-8601 dates, bundle id `com.example.ntfsbridge` (placeholder — change
  before distribution), `LSMinimumSystemVersion` 14.0.
- **Licensing:** app itself MIT (per RESEARCH.md); orchestrated engines keep
  their own licenses (NTFS-3G GPLv2, FUSE-T/macFUSE BSD-style, commercial
  drivers proprietary per-seat).
