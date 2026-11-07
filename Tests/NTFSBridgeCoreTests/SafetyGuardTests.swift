import Foundation
import Testing
@testable import NTFSBridgeCore

@Suite("SafetyGuard")
struct SafetyGuardTests {
    @Test("blocks erase/format/partition commands")
    func blocksDestructive() {
        let cases = [
            ["diskutil", "eraseDisk", "APFS", "Foo", "/dev/disk4"],
            ["diskutil", "eraseVolume", "APFS", "Foo", "/dev/disk4s1"],
            ["diskutil", "partitionDisk", "/dev/disk4", "1", "APFS", "Foo", "100%"],
            ["newfs_ntfs", "/dev/disk4s1"],
            ["mkfs.ntfs", "/dev/disk4s1"],
        ]
        for args in cases {
            #expect(throws: SafetyError.self) { try SafetyGuard.forbidDestructiveCommand(args) }
        }
    }

    @Test("allows safe verbs")
    func allowsSafe() throws {
        try SafetyGuard.forbidDestructiveCommand(["diskutil", "unmount", "/Volumes/FOO"])
        try SafetyGuard.forbidDestructiveCommand(["diskutil", "eject", "/dev/disk4"])
        try SafetyGuard.forbidDestructiveCommand(["diskutil", "verifyVolume", "/dev/disk4s1"])
        try SafetyGuard.forbidDestructiveCommand(["diskutil", "info", "-plist", "/dev/disk4s1"])
    }

    @Test("refuses overwrite without consent")
    func overwriteNeedsConsent() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let src = dir.appendingPathComponent("a.txt")
        let dst = dir.appendingPathComponent("b.txt")
        try "hi".write(to: src, atomically: true, encoding: .utf8)
        try "existing".write(to: dst, atomically: true, encoding: .utf8)
        #expect(throws: SafetyError.self) {
            try SafetyGuard.validateCopy(source: src, destination: dst, allowOverwrite: false)
        }
        try SafetyGuard.validateCopy(source: src, destination: dst, allowOverwrite: true)
    }
}
