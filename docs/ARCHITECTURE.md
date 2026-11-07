# Architecture

```
┌────────────────────────────────────────────────────────┐
│ NTFSBridgeApp (SwiftUI, @MainActor AppState)           │
│ Dashboard · DropZone · TransferRow · ManageFiles       │
│ EnableWriteSheet · RenameSheet · DeleteConfirm         │
└──────────────┬────────────────────────┬────────────────┘
               │                        │
┌──────────────▼────────┐  ┌────────────▼─────────────┐
│ NTFSBridgeCore        │  │ macOS system services    │
│ Drive / DriveDetector │──│ FileManager volumes,     │
│ BackendDetector       │  │ diskutil info/list,      │
│ BackendManager  ★     │  │ pluginkit (FSKit),       │
│ FilesystemCheck       │  │ bundled ntfs-3g (own),   │
│ MountManager          │  │ FUSE-T runtime (system), │
│ TransferEngine        │  │ vendor drivers           │
│ FileOps         ★     │  │                          │
│ Checksum (SHA-256)    │  │                          │
│ SafetyGuard           │  │                          │
│ ActivityLog           │  │                          │
└───────────────────────┘  └──────────────────────────┘
  ★ = Independent Edition additions
```

## Key decisions

1. **Owned engine, companion runtime.** The app bundles NTFS-3G 2026.9.28
   (pinned source, `Resources/bin/`, built by `scripts/bundle-engine.sh`)
   and treats FUSE-T as a detected system companion — never bundled
   (license requirement, see THIRD_PARTY_LICENSES.md). FSKit/commercial
   drivers remain detected hands-off options. Full rationale + field
   validation: `INDEPENDENT-EDITION-ASSESSMENT.md`.
2. **BackendManager over raw detection.** `BackendDetector` probes (binaries,
   runtimes, FSKit modules, live mounts). `BackendManager.resolve` adds the
   decision: bundled-before-system preference, macOS 13+ compatibility,
   plain-language activation steps, and — critically — genuine-writability
   verification from the kernel (`statfs`), never "a binary was seen".
   An FSKit-native engine plugs in later as a new resolution branch.
3. **Executed binary == reported backend.** `MountManager` resolves the
   remount binary with the same bundled-first order (explicit override for
   tests), so the UI claim and the spawned process never disagree.
4. **Copy engine correctness over speed.** `TransferEngine` streams every
   file in 1 MiB chunks to `<name>.ntfsbridge-partial-<uuid>` in the target
   directory, then atomically renames. Interruption ⇒ partials are removed,
   never a half file at the final name. SHA-256 verifies every file when
   enabled. Sources are opened read-only; there is no delete-source call
   anywhere in the codebase.
5. **File operations are small and jailed.** `FileOps` (rename /
   confirmed-delete / mkdir) constrains every target to the drive root,
   refuses the drive root itself, requires explicit confirmation for
   delete, and never overwrites on rename. The app layer re-gates all of
   it on writable mounts.
6. **Overwrite is opt-in per job.** `SafetyGuard.validateCopy` fails the
   whole job before any byte is written if a destination exists and the
   user did not tick overwrite.
7. **Commands are allow-listed.** `MountManager` only builds
   `info / list / unmount / eject / mount / verifyVolume` (+ the
   `ntfs-3g` remount). `SafetyGuard.forbidDestructiveCommand` rejects
   anything containing erase/format/partition/mkfs fragments, and there is
   no format API to call.
8. **Privilege is explicit.** Only the NTFS-3G remount needs root, and it
   runs through `osascript … with administrator privileges`, so macOS
   itself prompts. FSKit/commercial backends self-manage mounting; the app
   hands off instead of duplicating them. (A file-image mount needs no
   prompt at all — verified in testing.)
9. **Testability.** Disk/process boundaries are seams: plist parsing,
   backend decisions, resolution order, health evaluation, file ops, and
   the full copy engine are pure or injectable — 52 unit tests.
   `NTFSIntegration` (4 tests, env-gated) proves the stack on real NTFS;
   the manual hardware matrix lives in `NTFS-INTEGRATION-TESTS.md`.
