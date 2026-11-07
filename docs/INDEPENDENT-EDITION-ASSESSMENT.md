# NTFS Bridge Independent Edition — Architectural Assessment

> Phases 1–2 of the Independent Edition plan: full repository audit +
> evidence-based architecture decision. No code changed in this phase.
> Date: 2026-11-07. Sources: live repo read + upstream docs fetched Nov 2026
> (linked inline).

## PHASE 1 — Repository audit

### What works and must be preserved

The repo is a clean Swift 6 / SwiftPM project (`NTFSBridgeCore` library +
`NTFSBridgeApp` executable + `NTFSBridgeCoreTests`, 32 tests, Swift Testing
framework). Audited module by module:

- **Drive detection** (`DriveDetector`, `Discovery`): two-stage discovery
  (FileManager volumes, then `diskutil list` + per-device `info`) so
  unmounted/dirty NTFS volumes are still found. Read-only truth comes from
  the kernel (`statfs` `MNT_RDONLY`) — correct, because `diskutil -plist`
  exposes no read-only key. This is exactly right and must not be regressed.
- **Backend detection** (`BackendDetector`, pure + injectable): probes
  ntfs-3g binaries, FUSE-T/macFUSE runtimes, FSKit modules via `pluginkit`,
  vendor apps, **and live writable mounts** (`/sbin/mount` output) —
  trusting observed mounts over install checklists. Per-probe `BackendCheck`
  rows + a computed `nextStep` already power an honest UI. Good foundation
  for the required BackendManager.
- **Health gate** (`FilesystemCheck.evaluate`, pure): hibernation marker ⇒
  read-only; and the learned live-Mac truth that `diskutil verifyVolume`
  **always fails on NTFS** (-69886, Apple ships no NTFS verifier), so NTFS
  is gated on hibernation + the driver's own checks instead. Correct —
  re-verified against current upstream knowledge.
- **Copy engine** (`TransferEngine`, ~243 lines): pre-flight validation,
  recursive plans, symlinks recreated (not followed), 1 MiB streaming,
  temp-file + atomic rename, retry, cancel, speed/ETA progress, SHA-256
  verify with bad-copy removal. No delete-source anywhere. Solid; extend,
  don't rewrite.
- **Command safety** (`MountManager` allow-list + `SafetyGuard` substring
  block on erase/format/partition/mkfs): two independent layers, tested.
- **App shell** (`AppState` `@MainActor`): all blocking disk I/O off the
  main thread (a real launch-SIGABRT lesson is documented in comments —
  respect it), copy refused when read-only, JSONL activity log.

### Gaps vs the Independent Edition vision (§1–§2, §6–§8)

1. **No backend lifecycle management.** Detection exists; *installation,
   activation, and genuine-writability verification do not*. Hints still
   say `brew install …` — the exact Terminal/Homebrew dependence §7 bans.
   `canEnableWrite=true` means "a binary was seen", which §6 explicitly
   forbids equating with operational. There is no `BackendManager`.
2. **No bundled components.** The app consumes whatever the user happened
   to install (Homebrew paths `/opt/homebrew`, `/usr/local`). Nothing is
   shipped, nothing is version-pinned. "Self-contained" is currently false.
3. **Write path depends on third parties the user installs by hand**
   (FUSE-T/NTFS-3G via brew, FSKit drivers via DMG, or commercial tools).
   Vision §2 (zero commercial dependence, integrated UX) is not met.
4. **File management is copy-only.** Rename, delete-with-confirmation, and
   create-folder (§1) do not exist. (Trivially implementable once a
   writable POSIX mount exists — all three are ordinary file operations
   through the mount point, plus confirmation UI.)
5. **No THIRD_PARTY_LICENSES.** RESEARCH.md has a license table, but there
   is no compliance document, no source-availability mechanism, no
   per-binary attribution. Mandatory before bundling anything GPL.
6. **Stale test counts** (README: 20, MANUAL: 23, actual: 32) and no
   filesystem-integration tests (only unit/throwaway-dir tests). §11 needs
   image-based tests: Unicode/Greek/long names, disconnect mid-copy,
   hibernated/dirty images, Windows-compat spot checks.
7. **Distribution is ad-hoc signed only** (`codesign -`). No Developer ID,
   no notarization, placeholder bundle id `com.example.ntfsbridge`.
   No privileged helper (relies on per-mount `osascript` admin prompt —
   honest, but not the "no password every time" UX §7 wants).

### Verdict of Phase 1

~85% of the *application layer* the vision needs already exists and is
well-tested. What is missing is precisely one thing: **an owned,
integrated, verifiable write backend** — plus the manager, installer UX,
licenses, and distribution wrapping around it.

## PHASE 2 — Architecture research (evidence, not opinion)

### OPTION A — FSKit (native user-space filesystems)

Findings (Apple FSKit + live integrator reports, e.g. `ttntfs/fskit`):

- FSKit (macOS 15.4+, realistically **26+** for NTFS use) runs filesystems
  in user space: no kext, no SIP/Recovery changes. Correct long-term bet.
- **FSKit is a framework, not an NTFS driver.** Apple ships only a
  *read-only* NTFS module. A writable NTFS-on-FSKit still needs a full NTFS
  engine behind it. Young open efforts exist (`ntfs4mac`: FSKit +
  libntfs-3g; `ttntfs`: FSKit extension with stub-vs-real core switch) —
  promising, but immature, unsigned/unproven on valuable data, and they
  still wrap the *same* NTFS-3g-derived engine, not a new audited driver.
- Shipping an FSKit module requires, hard requirements: **paid Apple
  Developer account** (FSKit Module is a managed capability), two explicit
  App IDs + provisioning profiles carrying
  `com.apple.developer.fskit.fsmodule`, Xcode 26 / macOS 26 SDK, Release
  signed build (unsigned builds compile but `fskitd` refuses to load them),
  extension bundled inside the app, and **manual user approval** in System
  Settings → Login Items & Extensions → File System Extensions.
- Floor would rise to **macOS 26+**, abandoning the Ventura–Sonoma users
  the project currently supports.

Conclusion: FSKit is the right *destination*, wrong *vehicle for today* —
it adds the strictest signing/approval burden while still depending on an
immature NTFS engine underneath.

### OPTION B — Bundled open-source NTFS-3G + FUSE-T

Findings (upstream releases + the Oct-2026 Omnimount engineering guide,
which documents this exact stack shipped, signed, and notarized):

- **NTFS-3G is actively maintained** (Tuxera; releases 2026.2.25, 2026.7.7
  with heap-overflow fixes, 2026.9.28 in Ubuntu). Full NTFS read/write incl.
  journal replay, hibernation refusal, all file sizes. Same engine Linux
  ships. Concern "is it maintained?" is answered: yes.
- **FUSE-T** routes filesystem calls through a localhost NFS server to
  Apple's own in-kernel NFS client: **no kext, no Recovery, no reduced
  security**, Apple Silicon + Intel, macOS 13+. Critical detail: ntfs-3g
  must be **built against FUSE-T's libfuse** (`macos-fuse-t/ntfs-3g`
  fork) — the Homebrew build links macFUSE's libfuse and drags the kext
  back in.
- **macFUSE is rejected for bundling**: license ≥3.10 forbids binary
  redistribution with commercial software without written permission; the
  kext path needs Recovery + reduced security on Apple Silicon; and its
  kext-free FSKit backend only serves libfuse3 while ntfs-3g is
  fuse2-based (silent fallback to the kext backend — a trap).
- Shippability checklist is known and finite: Developer ID + notarization
  on **every** bundled binary; `disable-library-validation` entitlement
  (FUSE-T's library is signed by a different team); an `SMAppService`
  privileged helper (macOS 13+) so mounting doesn't re-prompt every time
  (or keep the existing `osascript` prompt as the v1 fallback — honest and
  already built); `statfs` `MNT_RDONLY` as the writability signal (already
  implemented here — notably, write-probe temp files give *false* results
  over NFS-backed FUSE-T mounts, so the current design is the right one).
- Works on **macOS 13+**: preserves the project's entire supported range.

### OPTION C — Own NTFS driver

Rejected for any near-term phase, per the vision's own constraint (§3):
MFT, allocation, journaling/recovery, indexing, security descriptors,
alternate streams, crash recovery — years of specialist work, and a
partial driver must never touch the 665–714 GB of real user data. Watch
(and potentially contribute to) `ntfs4mac`/`ttntfs` instead of competing
with them.

### Licensing (must-read before bundling)

- **ntfs-3g is GPLv2.** Invoked as a separate binary (fork/exec, the
  Mounty/Omnimount pattern — Omnimount itself ships GPL-3.0), the Swift app
  is not a derivative work by the standard interpretation, so app code can
  stay MIT. But distribution **must** include: verbatim GPLv2 text,
  attribution + version + source pointer, and a working source-availability
  mechanism for the exact bundled ntfs-3g build. This is what
  THIRD_PARTY_LICENSES (§10) must contain. Not legal advice — but
  non-optional homework.
- **FUSE-T redistribution terms must be verified from its upstream license
  before bundling** (`fuse-t.org` / `macos-fuse-t` org; libfuse side is
  LGPL). One secondary source describes the fuse-t server component in
  terms needing confirmation. Do not bundle until its license file is read
  and recorded.
- Do not claim "MIT end to end" once GPL binaries ship inside the bundle.

## Decision (priority order §4 applied)

| Criterion (in §4 order) | Bundled NTFS-3G + FUSE-T | FSKit-native now | Own driver |
|---|---|---|---|
| Reliability / integrity | Proven engine, journal replay, decades of use | Immature NTFS cores, unproven on real data | Unbuilt — zero |
| Security | No kext, no SIP/Recovery change | No kext either | N/A |
| Zero user cost | Free, bundlable (license homework noted) | Free but needs paid dev acct to ship | Free, infinitely late |
| Modern macOS compat | 13+ through 26/27 verified | 26+ only | N/A |
| Install ease | One app, bundled, one approval-free path | System Settings approval + newest OS only | N/A |
| Maintainability | Track upstream releases | Track Apple + immature drivers | Team of filesystem engineers |
| Independence | Full (no vendor app, no brew) | Full | Full |

**Recommended: implement Option B now (bundled NTFS-3G + FUSE-T as the
default integrated backend), design the BackendManager with an FSKit slot
so Option A plugs in later without re-architecture, and formally reject
Option C for this project.** Commercial backends stay as *detected,
hands-off* options (never required, never launched as controllers) so
existing users lose nothing.

## What Phase 3+ will build (staged, testable)

1. `BackendManager` (Core): component inventory (bundled vs system paths) →
   compatibility check (arch/OS/backend version matrix) → activation →
   mount → **genuine-writability verification** (`statfs` re-read post-mount
   + mount-table confirmation; never "binary seen = writable") → clear
   failure reports. Replaces raw `BackendDetector` use in `enableWrite`;
   detector stays as the probe layer.
2. `Resources/`-bundled ntfs-3g (built from pinned source against FUSE-T
   libfuse) + FUSE-T runtime handling; path resolution prefers bundled,
   falls back to system installs; version recorded in logs.
3. Guided setup UX (no Terminal/Homebrew): architecture/OS auto-detect →
   component checklist → install/activate → the one Apple approval
   explained in plain language (only where truly required) → health check
   → enable write. `SMAppService` helper evaluated; `osascript` prompt
   remains until the helper lands.
4. File operations: rename / delete-with-explicit-confirmation /
   create-folder through the writable mount (+ SafetyGuard extension,
   + tests). Copy engine untouched except shared confirmation plumbing.
5. `THIRD_PARTY_LICENSES` (component, version, source, license,
   redistribution/modification/attribution/source-availability terms) +
   in-bundle license texts + source-offer mechanism.
6. Test expansion on disposable NTFS images (never the Toshiba): large
   files, nested trees, Unicode/Greek/long names, conflict matrix, checksum
   failures, kill-mid-copy, USB-pull simulation, dirty/hibernated images,
   post-copy Windows-readability notes.
7. Distribution: real bundle id, Developer ID + notarization, Intel +
   Apple Silicon, documented minimum macOS, uninstall procedure.

## Decisions confirmed by product owner (2026-11-07)

- Architecture: **Option B now, FSKit slot reserved** — precise shape
  (settled 2026-11-07 after reading FUSE-T's license): the **engine
  (NTFS-3G 2026.9.28) is bundled**; **FUSE-T stays a system companion**,
  never bundled (its terms require a commercial license for bundling).
  User installs one free runtime installer + one app. Recorded in
  `THIRD_PARTY_LICENSES.md` including the commercial-use owner flag.
- macOS floor: **keep 13/14+**.
- Distribution: owner will cover **paid Apple Developer Program + notarization
  and GPL source-availability duties**. Exact signing/notarization steps
  in `docs/INSTALL.md` §6; per-release checklist in
  `THIRD_PARTY_LICENSES.md`.

## Field validation 2026-11-07 (this machine)

- Machine already runs the Option B architecture live: NTFSTool 4.7.2.18 +
  FUSE-T 1.2.9 serve the real 932 GiB Toshiba (666 GiB used) as a writable
  FUSE-T mount — existence proof for the chosen stack on the exact use case.
- Bundled engine end-to-end: upstream 2026.9.28 built by
  `scripts/bundle-engine.sh`, mounted a disposable 2 GiB NTFS image as a
  regular user (no admin prompt for file images), all 4 NTFSIntegration
  tests green (kernel writability, 256 MiB SHA-256 copy, Greek/long-name
  tree, rename/mkdir/confirmed-delete), post-test `ntfsfix` clean
  (MFT/MFTMirr OK, NTFS 3.1). Fixture destroyed afterwards.
- The physical Toshiba was never written by any test (read-only probes
  only: statfs verdict, capacity). First real-drive writes stay gated on
  the manual matrix in docs/NTFS-INTEGRATION-TESTS.md.

## Honest limitations to carry forward

- Any distributable build needs a **paid Apple Developer Program
  membership** (Developer ID + notarization) — true for Option B and A
  alike. There is no legitimate way to ship a trusted macOS filesystem app
  without it.
- This machine cannot validate end-to-end: sandboxed shell (even `swift
  test` manifest compilation is blocked here), no NTFS hardware, no
  FSKit-extension approval possible. All backend claims must be re-proven
  on a real Mac with a disposable NTFS image before touching the Toshiba.
- FUSE-T's exact redistribution terms are the one open license question —
  verified before bundling, recorded in THIRD_PARTY_LICENSES either way.
