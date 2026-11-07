# Research: NTFS write options on modern macOS

Evaluated November 2026 on MacBook (arm64, macOS 26.2 SDK / 26.7.2 runtime).
Conclusion: **no from-scratch NTFS driver** — NTFS Bridge orchestrates one
of the proven stacks below and stays read-only when none is present.

## 1. Native macOS NTFS: read-only

- macOS ships `/System/Library/Filesystems/ntfs.fs` with **read-only** mounts.
- There is no supported Apple NTFS write path. The old unofficial
  `mount_ntfs -o rw` hack is unmaintained, unsafe on Ventura+, and can
  corrupt volumes. **NTFS Bridge never uses it.**

## 2. NTFS-3G + FUSE (open source, free)

- **NTFS-3G** (GPLv2, Tuxera-maintained, the same engine Linux ships) is the
  reference open-source read/write NTFS implementation.
- Needs a FUSE runtime on macOS:
  - **FUSE-T** — kext-free, no Recovery-mode security reduction. Preferred
    for free setups. Community builds link `ntfs-3g` against FUSE-T's
    libfuse so the whole path is kext-free.
  - **macFUSE** — mature, but on Apple Silicon historically requires
    approving a system extension and possibly lowering security in
    Recovery mode. Works on Ventura → Tahoe when the versions match.
- Verdict: **supported backend #1** (`NTFSWriteBackend.ntfs3gFuse`).
  Free, auditable, Apple Silicon + Intel, Ventura+. The app detects
  `ntfs-3g` + a FUSE runtime and only then offers remount.

## 3. FSKit user-space drivers (macOS 15.4+/26+, no kext)

Apple's **FSKit** lets filesystems run in user space like an app extension —
no kernel extension, no SIP change, security stays intact:

- **NTFS4Mac** (open source, FSKit + libntfs-3g) — free, Apple Silicon +
  Intel, read/write mounting on macOS 26 (formats on 15, mounts read-only
  there due to an OS bug).
- **TT NTFS Native / NTFSTool** (open source, FSKit port) — free on macOS 26
  for physical disks; hibernated disks intentionally stay read-only.
- **iBoysoft NTFS for Mac v9+ Extension mode**, **PolyDrive** — commercial /
  freemium FSKit options with similar properties.
- Verdict: **supported backend #2** (`NTFSWriteBackend.fskit`), the
  best-supported path on macOS 26. Detected via
  `pluginkit -m -p com.apple.file-system` entries containing "ntfs".

## 4. Commercial kext / system-extension drivers

- **Paragon NTFS for Mac** (~$20–30, 10-day trial) and **Tuxera NTFS**
  (~$15–31, 14-day trial): fast, vendored installers, but on Apple Silicon
  they require approving a system extension and often **reduced security in
  Recovery mode + a restart**. iBoysoft "Advanced mode" is the same class.
- Verdict: **supported backend #3** (`NTFSWriteBackend.commercial`).
  The app detects them and hands mounting to the vendor app rather than
  fighting it. Licensing: proprietary, per-seat.

## 5. What was rejected

- Writing an NTFS driver from scratch: years of work, extreme corruption
  risk, unjustifiable next to NTFS-3G/libntfs-3g and FSKit ports.
- Mounty-style hidden remounts and `mount -o rw` force-mounts: unsafe.
- Anything requiring SIP to be disabled: refused by design (see SECURITY.md).

## Licensing summary

| Component | License |
|---|---|
| NTFS Bridge Swift code | MIT |
| NTFS Bridge bundle (ships ntfs-3g binary) | MIT app code + bundled GPLv2 binary (see THIRD_PARTY_LICENSES.md) |
| NTFS-3G / libntfs-3g | GPLv2 |
| FUSE-T | BSD-style |
| macFUSE | BSD-style |
| FSKit (Apple framework) | Apple SDK terms, no extra license |
| NTFS4Mac / TT NTFS | Open source (see upstream repos) |
| Paragon / Tuxera / iBoysoft | Proprietary per-seat |

## Recommendation for the 1 TB Toshiba use case

1. Update macOS to 26+, back up what you can.
2. Install **FUSE-T + NTFS-3G** (free) **or** an FSKit driver (NTFS4Mac /
   NTFSTool), or buy Paragon/Tuxera if you want vendor support.
3. Run NTFS Bridge → health check → Enable NTFS write → copy → verify →
   eject. The drive stays NTFS and works on Windows unchanged.
