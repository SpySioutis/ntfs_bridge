# Security & safety

Data integrity outranks features. Rules the code enforces, not just documents:

1. **Never format / erase / repartition.** There is no format code path.
   `MountManager` only issues info/list/unmount/eject/mount/verifyVolume
   (+ ntfs-3g remount). `SafetyGuard.forbidDestructiveCommand` throws on
   any command containing erase/format/partition/mkfs fragments, and tests
   assert the allow-list.
2. **Never silently elevate.** The single privileged operation (NTFS-3G
   remount of a physical device) runs via `osascript … with administrator
   privileges`, so the OS prompts every time. No SIP change, no
   security-policy change, no hidden `mount -o rw`, no background root daemon.
3. **Never write to an unclean volume.** `FilesystemCheck` checks the
   hibernation marker and (for non-NTFS) `verifyVolume`. A dirty journal
   or hibernation marker keeps the volume read-only with instructions to
   clean it on Windows first.
4. **Never claim write access unverified.** The Read & write badge follows
   only a kernel `statfs` writable verdict re-read after mounting
   (`BackendManager.confirmWritableLive`, wired into `enableWrite`).
   Unknown mount state fails closed to read-only.
5. **Never overwrite silently.** Pre-flight validation fails the job if any
   destination exists and overwrite is off. Per-file re-checks run at write
   time too. Rename follows the same rule.
6. **Never delete without explicit confirmation.** `FileOps.delete`
   throws unless the UI passes `confirmed` from its second-step panel;
   targets are jailed to the drive root and the drive root itself is
   refused. There is no undo — the UI says so.
7. **Never lose a file to interruption.** Temp-file + atomic rename,
   partial cleanup on cancel/failure/retry, SHA-256 verification with the
   bad copy removed on mismatch, persistent JSONL activity log for
   post-mortems, unsafe-disconnect warnings on failed ejects.
8. **Least surprise on sources.** Sources are opened read-only. Copy is
   copy — no move, no delete-after-copy anywhere.
9. **Owned engine, audited provenance.** The bundled ntfs-3g is built from
   pinned upstream source (no opaque binaries): version + commit in
   `Resources/engine-info.json`, linkage audit in
   `Resources/engine-linkage.txt`, GPLv2 text in `Resources/licenses/`,
   and build-time gates rejecting macFUSE-linked or stray-dependency
   builds. It includes the upstream 2026.7.7 heap-overflow fixes; the
   remaining threat (malicious/corrupt images parsed by a privileged-at-
   mount driver) is contained by rules 2–4 plus no auto-mount of unknown
   volumes. Standing obligations: re-try each upstream release, never
   hand-patch engine source (see THIRD_PARTY_LICENSES.md).
10. **FUSE-T trust boundary.** FUSE-T is a system companion, not bundled:
    a user-space NFS loopback to Apple's in-kernel NFS client — no kext,
    no kernel code of ours or theirs. The engine loads FUSE-T's library
    (different signing team), so distribution signing must grant the
    *engine binary* `disable-library-validation` (see INSTALL.md §6).
11. **Permissions.** The app needs no special entitlement beyond
    user-selected file access (`com.apple.security.files.user-selected.read-write`).
    Full-disk access is not requested. See `NTFSBridge.entitlements`.
    Ad-hoc signing is a dev placeholder — releases need Developer ID +
    notarization (INSTALL.md §6).
