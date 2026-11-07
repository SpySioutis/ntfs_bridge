# Install & use

Supports **macOS Ventura 13+** (best on **macOS 26+**), **Apple Silicon
(M1–M4) and Intel**, USB / USB-C externals, Windows-compatible NTFS volumes.

## 1. Install NTFS Bridge

```bash
cd ntfs-bridge
./scripts/build-app.sh
open dist/NTFSBridge.app
```

Or run from source: `swift run NTFSBridgeApp`.
No kernel extension, no SIP change, no reboot.

## 2. One-time companion: FUSE-T (free, no Terminal)

The bundled NTFS engine needs the FUSE-T runtime to talk to macOS —
a kext-free component, so there is no Recovery-mode step and no reduced
security. FUSE-T is **not** shipped inside NTFS Bridge (its license
requires a commercial license for bundling — see
`THIRD_PARTY_LICENSES.md`); it is detected as a system companion:

1. Download FUSE-T from its official site (`fuse-t.org`) and run the
   installer (free for non-commercial use).
2. Open NTFS Bridge and press **Refresh**. The driver checklist shows
   the FUSE runtime as found.

Advanced alternative (not required): existing Homebrew (`fuse-t` cask),
FSKit drivers (NTFS4Mac/NTFSTool on macOS 26+), or commercial drivers are
all still detected automatically — the app uses whatever is honestly
present, preferring its bundled engine.

## 3. Copy your folders (the Toshiba scenario)

1. Plug in the NTFS drive. Confirm the badge: **Read-only** (engine or
   FUSE-T missing) or **Read & write** (ready).
2. Select the drive → **Check health**. If it reports a dirty journal or
   hibernation marker, plug the drive into Windows first and shut down
   cleanly / run `chkdsk`, then retry.
3. **Enable NTFS write…** → approve the one admin prompt. The app
   re-verifies writability with the kernel before the badge changes —
   an unverified remount stays read-only with an explanation.
4. Drag folders onto the drop zone (or Choose files… / paste). Keep
   **overwrite OFF** unless you mean it.
5. Watch progress (bytes, speed, ETA). Every file is SHA-256 verified;
   failures name the file and leave the old destination untouched.
6. Manage files if needed: create folders, rename, or delete (delete
   always asks twice — there is no undo).
7. **Eject safely** in the app before unplugging. If macOS warns about an
   unsafe removal, re-plug and eject cleanly before writing again.

## 4. Test without risking your drive

```bash
./scripts/create-test-image.sh   # disposable 2 GB image in /tmp, mounted
```

Copy test folders to *that* volume first. The automated suite also covers
the copy engine on throwaway directories (`swift test`), and the NTFS
integration tests run against a disposable NTFS volume:

```bash
NTFSBRIDGE_TEST_VOLUME=/Volumes/NTFS-TEST swift test --filter NTFSIntegration
```

Only after a clean test copy should you touch the 1 TB drive — and even
then, the app never formats, erases, or deletes sources. The full
hardware sign-off order is in `docs/NTFS-INTEGRATION-TESTS.md`.

## 5. Removal

- Delete `dist/NTFSBridge.app` (or the installed copy).
- Logs live at `~/Library/Application Support/NTFSBridge/` — delete to purge.
- FUSE-T is removed with its own uninstaller; NTFS Bridge installs no
  driver of its own. Drives revert to Apple's safe read-only NTFS.

## 6. Distribution (release owner)

Ad-hoc signing (`codesign -`) is a dev placeholder. A distributable
release additionally needs (paid Apple Developer Program):

1. Real bundle id (replace `com.example.ntfsbridge`).
2. Hardened-runtime Developer ID signature **including the bundled
   engine**, which must carry `com.apple.security.cs.disable-library-validation`
   (it loads FUSE-T's library, signed by a different team):
   `codesign --force --options runtime --deep --sign "Developer ID Application: …" dist/NTFSBridge.app`
   then verify entitlements with `codesign -d --entitlements -` on the engine.
3. Notarization: `ditto` to zip →
   `xcrun notarytool submit … --wait` → `xcrun stapler staple`.
4. Release checklist in `THIRD_PARTY_LICENSES.md` (FUSE-T commercial-use
   flag, engine-info match, deepStrict verify, staple).
