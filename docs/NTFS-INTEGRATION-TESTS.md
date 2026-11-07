# NTFS Integration Test Plan (§11)

Automated unit tests (`swift test`) cover logic on throwaway directories,
but NTFS behavior must be proven on a real NTFS filesystem. This runbook
maps every §11 requirement to how it is verified. **Never use the physical
Toshiba drive until the full matrix below is green on disposable images.**

## 0. Test fixture: disposable NTFS volume

macOS cannot format NTFS, so prepare the image on Windows/Linux, or reuse
an NTFS USB stick containing only expendable data:

- Windows: Disk Management → create a small (8–16 GB) NTFS partition on a
  spare stick (or `diskpart`), fill with sample trees (see §2).
- Dirty-state fixtures: hibernate a Windows VM with the volume attached
  (hibernation marker), or detach mid-write (dirty journal).
- Mount on the Mac, enable write in NTFS Bridge, note the mount path.

Run the automated slice:

```bash
NTFSBRIDGE_TEST_VOLUME=/Volumes/NTFS-TEST swift test --filter NTFSIntegration
```

Without the variable the suite prints SKIP per test and passes vacuously —
**a skip is not NTFS validation** and must never be reported as such.

## 1. Coverage matrix

| §11 requirement | Automated (`NTFSIntegration`) | Manual (this runbook) |
|---|---|---|
| NTFS detection | — (unit: DriveTests) | PlugNtfs stick → Refresh shows NTFS + RO/RW badge |
| Read-only mounting | — | No engine: badge RO, copy refused with message |
| Read/write mounting | `volumeWritable` (kernel statfs verdict) | Enable write → badge RW only after verification |
| Large file copy | `largeFileCopy` (256 MiB + SHA-256) | Multi-GB file, watch speed/ETA, verify log line |
| Nested folder copy | `awkwardTree` | 5+-level tree, compare file counts both sides |
| Unicode / Greek names | `awkwardTree`, `fileOps` (+ unit: FileOpsTests) | Open renamed files on Windows |
| Long filenames | unit: 200-char names | 200+ char names, confirm on Windows |
| Existing-file conflicts | — (unit: TransferEngineTests) | Copy twice: 2nd run refuses without tick, replaces with tick |
| SHA-256 verification | `largeFileCopy`, `awkwardTree` | Corrupt a dest copy manually → recopy detects mismatch |
| Interrupted transfers | — (unit: cancel paths) | Kill app mid-copy → no half-file at final name, no `.ntfsbridge-partial-*` left |
| USB disconnection | — | Pull stick mid-copy → job fails with file named, partials cleaned, honest error |
| Safe eject | — | Eject in app → unplug → replug → volume healthy |
| Windows compatibility | — | After every case: attach to Windows, open/copy back sample files, run `chkdsk` (expect clean) |
| Unsafe states | — (unit: hibernation/dirty evaluation) | Hibernated image → stays RO + Windows-fix instructions; dirty journal → ntfs-3g replay or Windows `chkdsk` first |

## 2. Sample tree (create on the fixture before testing)

- `Photos/2024/Αθήνα/` with mixed JPEG + a 1 GB video
- `Docs/σημειώσεις.txt`, `Docs/emoji-🎉-名前.txt`
- 200-char filename, deep nesting (8 levels), one 0-byte file, one symlink

## 2b. Chaos results observed 2026-11-07 (disposable 2 GiB image, bundled 2026.9.28 engine)

- Daemon `kill -9` mid-session: mount goes stale immediately
  (`ls: fts_read: Device not configured`). No hang, no panic — clients
  see a dead filesystem, loudly.
- Remount after unclean kill: succeeds without intervention (journal
  replayed by ntfs-3g; only hibernated volumes are refused). Post-
  recovery `ntfsfix` clean.
- Hibernation gate: a planted `hiberfil.sys` makes `FilesystemCheck`
  report unhealthy; removal restores healthy (automated in
  `NTFSIntegration.hibernationGate`).
- Daemon idle stability: mount + daemon persist across 20 s idle and
  normal IO; marker-file round-trip verified.
- NOT observed (open): the exact in-flight write error at kill instant —
  a throttled-copy probe hung on the already-dead NFS handle and was
  terminated without output. Raw `cp`-style copies have no temp-file
  protection by design; the app-level guarantee (temp + atomic rename)
  is covered by unit tests. A kill-during-TransferEngine run on hardware
  remains a manual-matrix item.
- Fixture destroyed after each round; physical Toshiba never written.

## 3. Sign-off order

1. `swift test` green (unit, any Mac).
2. `NTFSIntegration` green on disposable NTFS (real Mac + engine).
3. Manual matrix above green, ending with Windows `chkdsk` clean.
4. Only then: first guided copy to the physical Toshiba (small folder,
   verified), then the full migration.
