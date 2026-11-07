import Foundation
import Testing
@testable import NTFSBridgeCore

@Suite("BackendDetector")
struct BackendDetectorTests {
    @Test("reports none when nothing installed")
    func none() {
        let env = BackendEnvironment(fileExists: { _ in false })
        let status = BackendDetector.detect(in: env)
        #expect(status.backend == .none)
        #expect(status.canEnableWrite == false)
    }

    @Test("detects ntfs-3g plus FUSE-T")
    func fuseT() {
        let env = BackendEnvironment(fileExists: { path in
            path == "/opt/homebrew/bin/ntfs-3g" || path == "/Library/Filesystems/fuse-t.fs"
        })
        let status = BackendDetector.detect(in: env)
        #expect(status.backend == .ntfs3gFuse)
        #expect(status.canEnableWrite == true)
    }

    @Test("detects ntfs-3g plus macFUSE")
    func macFuse() {
        let env = BackendEnvironment(fileExists: { path in
            path == "/usr/local/bin/ntfs-3g" || path == "/Library/Filesystems/macfuse.fs"
        })
        let status = BackendDetector.detect(in: env)
        #expect(status.backend == .ntfs3gFuse)
    }

    @Test("ntfs-3g without FUSE cannot enable write")
    func danglingNtfs3g() {
        let env = BackendEnvironment(fileExists: { $0 == "/opt/homebrew/bin/ntfs-3g" })
        let status = BackendDetector.detect(in: env)
        #expect(status.backend == .none)
        #expect(status.canEnableWrite == false)
    }

    @Test("prefers FSKit over FUSE")
    func fskitFirst() {
        let env = BackendEnvironment(
            fileExists: { $0 == "/opt/homebrew/bin/ntfs-3g" || $0 == "/Library/Filesystems/fuse-t.fs" },
            fskitModuleNames: ["com.example.ntfs-fskit (NTFS)"],
            commercialAppNames: []
        )
        #expect(BackendDetector.detect(in: env).backend == .fskit)
    }

    @Test("parses pluginkit lines")
    func pluginkit() {
        let lines = ["com.apple.apfs.fs", "com.example.ntfs4mac.NTFS-filesystem", ""]
        #expect(BackendDetector.fskitNTFSModules(in: lines).count == 1)
        #expect(BackendDetector.fskitNTFSModules(in: ["com.apple.apfs.fs"]).isEmpty)
    }

    @Test("commercial driver enables write")
    func commercial() {
        let env = BackendEnvironment(fileExists: { $0 == "/Applications/Paragon NTFS for Mac.app" })
        let status = BackendDetector.detect(in: env)
        #expect(status.backend == .commercial)
        #expect(status.canEnableWrite == true)
    }

    @Test("parses writable vs read-only ntfs mounts")
    func activeMounts() {
        let output = """
        /dev/disk3s1s1 on / (apfs, sealed, local, read-only, journaled)
        /dev/disk4s1 on /Volumes/TOSHIBA (ntfs, local, nodev, nosuid, read-only, noowners)
        /dev/disk5s1 on /Volumes/WORK (ntfs, local, nodev, nosuid, noowners)
        """
        #expect(BackendDetector.activeWritableNTFSMounts(in: output) == ["/dev/disk5s1"])
        #expect(BackendDetector.activeWritableNTFSMounts(in: "nothing here").isEmpty)
    }

    @Test("live writable mount counts as an understood driver")
    func liveMountUnderstood() {
        let output = "/dev/disk5s1 on /Volumes/WORK (ntfs, local, nodev, nosuid, noowners)\n"
        let env = BackendEnvironment(fileExists: { _ in false }, mountOutput: output)
        let status = BackendDetector.detect(in: env)
        #expect(status.canEnableWrite == true)
        #expect(status.checks.count == 5)
        #expect(status.checks.last?.label == "Writable NTFS mount active")
        #expect(status.checks.last?.found == true)
    }

    @Test("checks report what is missing")
    func checksReportMissing() {
        let status = BackendDetector.detect(in: BackendEnvironment(fileExists: { _ in false }))
        #expect(status.checks.count == 5)
        #expect(status.checks.allSatisfy { !$0.found })
        #expect(status.checks[0].hint.contains("brew"))
    }

    @Test("detects FUSE-T installed as an app, without ntfs-3g")
    func fuseTAppAloneIsNotEnough() {
        // The exact live-Mac scenario: fuse-t.app present, no NTFS engine.
        let env = BackendEnvironment(fileExists: { $0 == "/Applications/fuse-t.app" })
        let status = BackendDetector.detect(in: env)
        #expect(status.backend == .none)
        #expect(status.canEnableWrite == false)
        #expect(status.checks[1].found == true)   // FUSE runtime ✓
        #expect(status.checks[0].found == false)  // NTFS-3G ✗
        #expect(status.nextStep.contains("ntfstool"))
    }

    @Test("vendor handoff names the NTFSTool next actions")
    func vendorHandoff() {
        let msg = BackendDetector.vendorHandoffMessage(
            detail: "Commercial driver: /Applications/NTFSTool.app",
            volumeName: "TOSHIBA EXT"
        )
        #expect(msg.contains("Ntfstool.app"))
        #expect(msg.contains("TOSHIBA EXT"))
        #expect(msg.contains("Refresh"))
        let generic = BackendDetector.vendorHandoffMessage(detail: "FSKit NTFS module(s): x", volumeName: "D")
        #expect(generic.contains("vendor app"))
    }

    @Test("next step guides each missing-piece case")
    func nextStep() {
        let none = BackendDetector.detect(in: BackendEnvironment(fileExists: { _ in false }))
        #expect(none.nextStep.contains("ntfstool"))
        let dangling = BackendDetector.detect(in: BackendEnvironment(fileExists: { $0 == "/opt/homebrew/bin/ntfs-3g" }))
        #expect(dangling.nextStep.contains("fuse-t"))
        let ready = BackendDetector.detect(in: BackendEnvironment(
            fileExists: { $0 == "/opt/homebrew/bin/ntfs-3g" || $0 == "/Applications/fuse-t.app" }
        ))
        #expect(ready.canEnableWrite == true)
        #expect(ready.nextStep.contains("Check health"))
    }
}
