# Third-Party Licenses — NTFS Bridge Independent Edition

> Compliance record for every externally developed component the app ships
> or orchestrates. Read this before adding, upgrading, or removing a
> bundled binary. This is a licensing record, not legal advice.

## Status legend

- **BUNDLED** — ships inside `NTFSBridge.app/Contents/Resources/`.
  Full obligations below apply at distribution time.
- **PLANNED** — approved for bundling; not yet shipped.
- **SYSTEM** — detected/used if present, never shipped, never required.
- **EXCLUDED** — evaluated and rejected for bundling, with reason.

## Components

### ntfs-3g — PLANNED (bundled engine)

- Version: **2026.9.28 line** (deliberately not 2026.2.25: pre-2026.7.7
  builds carry known heap-buffer-overflow CVEs fixed in 2026.7.7).
  Record the exact fork commit here when bundling.
- Source: FUSE-T-compatible fork `https://github.com/macos-fuse-t/ntfs-3g`
  (branch `edge`; upstream `https://github.com/tuxera/ntfs-3g`, Tuxera Inc.).
  macOS build must link FUSE-T's libfuse — enforced by the otool gate in
  `scripts/bundle-engine.sh`.
- License: **GPLv2** (COPYING file from the exact source tree must ship in
  `Resources/licenses/ntfs-3g-COPYING`).
- Redistribution: binary may be bundled; must include license text,
  attribution, version + source pointer, and a written source-availability
  offer for the exact build (fulfilled via this repo's pinned-source build
  script + this file).
- Modification: any patch to the engine must be published as source alongside.
- App-code status: NTFS Bridge invokes ntfs-3g as a **separate process**
  (fork/exec, same pattern as Mounty/Omnimount); app Swift code is not a
  derivative work of the engine and remains under its own license. Do not
  link engine code into app binaries.

### FUSE-T runtime — SYSTEM companion, NEVER bundled (license requirement)

- Source: `https://www.fuse-t.org`, `macos-fuse-t` org. Installed on this
  build machine: 1.2.9 (cask).
- License (verbatim from `/Library/Application Support/FUSE-T/LICENSE.rtf`,
  read 2026-11-07): binary distribution is **free for non-commercial use**
  (BSD-style attribution conditions); **commercial use and/or bundling
  with commercial software requires a commercial license from the FUSE-T
  authors**. The included libfuse is **LGPL** (forked from osxfuse/fuse).
- Decision: NTFS Bridge **ships no FUSE-T code**. The bundled ntfs-3g
  links FUSE-T's library dynamically at `/usr/local/lib` (RPATH) and
  `BackendManager` treats FUSE-T as a detected system companion
  (`.system`), never as a bundled component. The user installs FUSE-T
  once from its official installer (free for non-commercial use) — no
  Terminal, no Homebrew. This keeps the app license-clean under both the
  FUSE-T terms and the LGPL (no LGPL code is embedded; the system dylib
  remains user-replaceable).
- Attribution: FUSE-T © its authors, libfuse LGPL — recorded here even
  though no redistribution occurs, as good practice.
- OWNER FLAG: if NTFS Bridge is ever distributed commercially (sold,
  subscription, or bundled with a paid product), a FUSE-T commercial
  license must be obtained BEFORE release. Until then this item stays
  open in every release checklist.

### Apple FSKit framework — SYSTEM (present/future slot)

- License: Apple SDK terms, no extra license. No redistribution: part of macOS.
- The `BackendManager` FSKit branch is reserved for a future native module;
  current `.fskit` status only reflects system-managed third-party drivers.

### macFUSE — EXCLUDED from bundling

- License ≥ 3.10 forbids binary redistribution with commercial software
  without prior written permission, and the kext path needs Recovery +
  reduced security on Apple Silicon. Additionally its kext-free FSKit
  backend serves libfuse3 only, while ntfs-3g is fuse2-based (silent kext
  fallback trap). Users' existing installs are still *detected* (`.system`).

### Commercial drivers (Paragon / Tuxera / iBoysoft) — SYSTEM, never required

- Proprietary per-seat licenses. Detected hands-off only; the app never
  launches, controls, or depends on them.

## Outstanding actions

1. [x] Engine staged 2026-11-07: `scripts/bundle-engine.sh` built
   upstream tuxera/ntfs-3g tag 2026.9.28 (`7f0f841`) into
   `Resources/bin/ntfs-3g` (arm64, ad-hoc signed; `--disable-library`
   static link; `--with-fuse=external` against FUSE-T headers;
   linkage gate passed — libfuse-t + system libs only, recorded in
   `Resources/engine-linkage.txt`; COPYING staged; provenance in
   `Resources/engine-info.json`). Reports `ntfs-3g 2026.9.28 external
   FUSE 29`. Includes the 2026.7.7 heap-overflow fixes.
   `scripts/build-app.sh` bundles `Resources/` into the app, and
   `MountManager` prefers the bundled binary.
   - Two build lessons encoded in the script (no source patches):
     upstream configure needs a `fuse.pc` alias (FUSE-T ships the same
     2.9 API as module `fuse-t`; alias is truthful, verified in
     fuse_common.h) and `-D_FILE_OFFSET_BITS=64` (missing from the
     .pc flags; without it the build fails in ntfs-3g.c).
   - Standing mitigations regardless of engine age: read-only default,
     hibernation/dirty health gate, no auto-mount of unknown volumes,
     SafetyGuard command allow-list.
   - Fallback: macos-fuse-t/ntfs-3g fork (`edge`, 2023, 2022.10.3 line)
     also builds via the same script but predates the CVE fixes — use
     only if upstream regresses on a future SDK. Do NOT patch upstream
     source ourselves (that is maintaining a filesystem fork).
2. [x] FUSE-T terms verified from the installed LICENSE.rtf (see above):
   SYSTEM companion only, never bundled; commercial-use flag recorded.
3. [x] Engine provenance in the activity log: `BackendManager.EngineInfo`
   parses `Resources/engine-info.json` (nil on absent/corrupt, never
   guessed) and `AppState.enableWrite` logs it before remounting.
   Covered by `BackendManagerTests.engineInfoParsing`.
4. [ ] Release checklist (every release): FUSE-T commercial-license flag
   re-confirmed; `Resources/engine-info.json` matches the staged binary;
   `codesign --verify --deep --strict` green; notarization stapled.
