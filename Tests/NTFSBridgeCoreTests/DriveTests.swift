import Foundation
import Testing
@testable import NTFSBridgeCore

@Suite("Drive + health + mount safety")
struct DriveTests {
    @Test("NTFS writability reflects the observed mount flag")
    func writability() {
        let ro = Drive(id: "/dev/disk4s1", volumeName: "TOSHIBA", mountPoint: URL(fileURLWithPath: "/Volumes/TOSHIBA"), filesystem: "NTFS", totalBytes: 1_000_000_000_000, freeBytes: 286_000_000_000, isExternal: true, isEjectable: true, mountReadOnly: true)
        #expect(ro.isNTFS)
        #expect(!ro.showsWritable)
        var rw = ro; rw.mountReadOnly = false
        #expect(rw.showsWritable)
    }

    @Test("hibernation marker keeps volume read-only")
    func hibernated() {
        let health = FilesystemCheck.evaluate(verifyExitCode: 0, verifyOutput: "OK", hibernatedMarkersPresent: true, filesystemIsNTFS: true)
        #expect(!health.volumeHealthy)
    }

    @Test("failed verification keeps non-NTFS volume read-only")
    func failedVerify() {
        let health = FilesystemCheck.evaluate(verifyExitCode: 1, verifyOutput: "error: journal dirty", hibernatedMarkersPresent: false, filesystemIsNTFS: false)
        #expect(!health.volumeHealthy)
    }

    @Test("verifyVolume failure never blocks NTFS (unsupported -69886)")
    func ntfsSkipsVerifyVolume() {
        // The live-Mac false positive: diskutil can't verify NTFS at all.
        let health = FilesystemCheck.evaluate(
            verifyExitCode: 1,
            verifyOutput: "Error starting file system verification for disk4s1 (TOSHIBA EXT): Invalid request (-69886)",
            hibernatedMarkersPresent: false,
            filesystemIsNTFS: true
        )
        #expect(health.volumeHealthy)
    }

    @Test("mount manager exposes no destructive command")
    func noDestructiveCommands() throws {
        let cmds = [
            MountManager.unmountCommand(mountPoint: "/Volumes/X"),
            MountManager.ejectCommand(device: "/dev/disk4"),
            MountManager.verifyCommand(device: "/dev/disk4s1"),
            MountManager.infoCommand(device: "/dev/disk4s1"),
            MountManager.listCommand(),
            MountManager.mountCommand(device: "/dev/disk4s1"),
            MountManager.mountReadOnlyCommand(device: "/dev/disk4s1"),
        ]
        for cmd in cmds {
            try SafetyGuard.forbidDestructiveCommand([cmd.executable] + cmd.arguments)
        }
        #expect(!cmds.flatMap(\.arguments).joined(separator: " ").lowercased().contains("erase"))
    }

    @Test("kernel mount flags report read-only root and writable tmp")
    func mountFlags() {
        // / is mounted with the read-only flag set (verified via diskutil text output).
        #expect(MountFlags.mountIsReadOnly(at: "/") == true)
        // A fresh directory under TMPDIR must be writable.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(MountFlags.mountIsReadOnly(at: dir.path) == false)
        // Nonexistent paths yield nil, never a guessed value.
        #expect(MountFlags.mountIsReadOnly(at: "/definitely/not/here-\(UUID().uuidString)") == nil)
    }

    @Test("disk list plist parses to device identifiers")
    func diskList() throws {
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0"><dict><key>AllDisks</key><array>
        <string>disk0</string><string>disk0s1</string><string>disk4s1</string>
        </array></dict></plist>
        """
        #expect(try DriveDetector.parseDiskList(Data(plist.utf8)) == ["disk0", "disk0s1", "disk4s1"])
    }

    @Test("discovery snapshot always completes with a summary line")
    func snapshotCompletes() {
        // Regression guard for the launch crash: full discovery must run
        // to completion off the main thread and always end with a summary.
        let snapshot = Discovery.collectSnapshot()
        #expect(snapshot.logLines.last?.hasPrefix("Refresh complete:") == true)
        for drive in snapshot.drives {
            #expect(!drive.id.isEmpty)
        }
    }

    @Test("user-volume predicate trusts diskutil over ejectable flags")
    func userVolumePredicate() {
        // The live TOSHIBA paradox: FileManager says ejectable=false,
        // removable=false, yet diskutil says Internal=false, Ejectable=true.
        let toshiba = DriveDetector.DiskUtilInfo(
            DeviceNode: "/dev/disk4s1", VolumeName: "TOSHIBA EXT",
            MountPoint: "/Volumes/TOSHIBA EXT", FilesystemType: "ntfs",
            TotalSize: 1_000_000_000_000, FreeSpace: 286_000_000_000,
            Internal: false, Ejectable: true, Removable: false
        )
        #expect(DriveDetector.isUserVolume(
            mountPath: "/Volumes/TOSHIBA EXT", filesystem: "ntfs",
            info: toshiba, ejectable: false, removable: false) == true)
        // System volumes are never user volumes, even if flags lie the other way.
        let sysInfo = DriveDetector.DiskUtilInfo(
            DeviceNode: "/dev/disk3s6", VolumeName: "VM",
            MountPoint: "/System/Volumes/VM", FilesystemType: "apfs",
            TotalSize: 1, FreeSpace: 1,
            Internal: true, Ejectable: false, Removable: false
        )
        #expect(DriveDetector.isUserVolume(
            mountPath: "/System/Volumes/VM", filesystem: "apfs",
            info: sysInfo, ejectable: false, removable: false) == false)
        #expect(DriveDetector.isUserVolume(
            mountPath: "/", filesystem: "apfs",
            info: nil, ejectable: false, removable: false) == false)
        // Classic ejectable USB stick still counts without diskutil.
        #expect(DriveDetector.isUserVolume(
            mountPath: "/Volumes/STICK", filesystem: "exFAT",
            info: nil, ejectable: true, removable: false) == true)
    }

    @Test("mount truth keeps unmounted volumes read-only")
    func unmountedIsReadOnly() {
        let drive = Drive(id: "/dev/disk4s1", volumeName: "TOSHIBA", mountPoint: nil, filesystem: "NTFS", totalBytes: 1000, freeBytes: 500, isExternal: true, isEjectable: true, mountReadOnly: false)
        #expect(DriveDetector.applyingMountTruth(drive).mountReadOnly == true)
        #expect(DriveDetector.applyingMountTruth(drive).showsWritable == false)
    }

    @Test("activity log persists JSONL")
    func activityLog() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: file) }
        let store = ActivityLogStore(persistTo: file)
        store.append("mounted /Volumes/TOSHIBA read-only")
        store.append("copy finished: 3 files")
        #expect(store.allEntries.count == 2)
        let reopened = ActivityLogStore(persistTo: file)
        #expect(reopened.allEntries.count == 2)
    }
}
