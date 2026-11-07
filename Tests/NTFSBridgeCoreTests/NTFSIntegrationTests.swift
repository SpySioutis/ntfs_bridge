import Foundation
import Testing
@testable import NTFSBridgeCore

/// Filesystem integration tests against a REAL mounted NTFS volume.
///
/// Opt-in: set NTFSBRIDGE_TEST_VOLUME to a disposable NTFS mount point
/// (see docs/NTFS-INTEGRATION-TESTS.md). Without it every test prints
/// SKIP and returns — a skip is NOT a pass, and the suite report must
/// never be quoted as NTFS validation on machines without a volume.
///
/// NEVER point this at the user's physical drive: the tests write,
/// rename, and delete.
@Suite("NTFSIntegration")
struct NTFSIntegrationTests {
    private func testVolume() -> URL? {
        guard let path = ProcessInfo.processInfo.environment["NTFSBRIDGE_TEST_VOLUME"],
              !path.isEmpty
        else {
            print("SKIP NTFSIntegration: set NTFSBRIDGE_TEST_VOLUME to a disposable NTFS mount.")
            return nil
        }
        let url = URL(fileURLWithPath: path)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
            print("SKIP NTFSIntegration: \(path) is not a mounted directory.")
            return nil
        }
        return url
    }

    /// Unique scratch dir per test; removed afterwards (delete path itself
    /// is exercised by the delete test).
    private func scratch(in volume: URL, _ name: String) throws -> URL {
        let dir = volume.appendingPathComponent("ntfsbridge-it-\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
        return dir
    }

    @Test("volume is genuinely writable (kernel verdict)")
    func volumeWritable() throws {
        guard let volume = testVolume() else { return }
        #expect(BackendManager.confirmWritableLive(at: volume.path))
    }

    @Test("large file copies with checksum verification")
    func largeFileCopy() async throws {
        guard let volume = testVolume() else { return }
        let scratch = try scratch(in: volume, "large")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let src = scratch.appendingPathComponent("src-256m.bin")
        let dst = scratch.appendingPathComponent("dst")
        try FileManager.default.createDirectory(at: dst, withIntermediateDirectories: true)
        // 256 MiB deterministic payload (full gigabytes are a manual case).
        let chunk = Data(repeating: 0x5A, count: 1_048_576)
        let handle = try FileHandle(forWritingTo: {
            FileManager.default.createFile(atPath: src.path, contents: nil)
            return src
        }())
        for _ in 0..<256 { try handle.write(contentsOf: chunk) }
        try handle.close()
        let engine = TransferEngine()
        let report = try await engine.copy(sources: [src], to: dst, verifyChecksum: true)
        #expect(report.filesCopied == 1)
        #expect(report.verified)
        #expect(try Checksum.verify(source: src, destination: dst.appendingPathComponent(src.lastPathComponent)))
    }

    @Test("nested folders, greek and long names round-trip")
    func awkwardTree() async throws {
        guard let volume = testVolume() else { return }
        let scratch = try scratch(in: volume, "tree")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let nested = scratch.appendingPathComponent("Οικογένεια/" + String(repeating: "d", count: 100))
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data("γειά σου ntfs".utf8).write(to: nested.appendingPathComponent("σημείωση 🎉.txt"))
        let dst = scratch.appendingPathComponent("dst")
        let engine = TransferEngine()
        let report = try await engine.copy(
            sources: [scratch.appendingPathComponent("Οικογένεια")], to: dst, verifyChecksum: true)
        #expect(report.filesCopied == 1)
        #expect(report.verified)
    }

    @Test("hibernation marker keeps the live volume read-only")
    func hibernationGate() throws {
        guard let volume = testVolume() else { return }
        let scratch = try scratch(in: volume, "hiber")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let marker = scratch.appendingPathComponent("hiberfil.sys")
        FileManager.default.createFile(atPath: marker.path, contents: Data("fake-hibernation".utf8))
        let flagged = FilesystemCheck.check(device: "test-device", mountPoint: scratch, filesystemIsNTFS: true)
        #expect(!flagged.volumeHealthy)
        try FileManager.default.removeItem(at: marker)
        let clean = FilesystemCheck.check(device: "test-device", mountPoint: scratch, filesystemIsNTFS: true)
        #expect(clean.volumeHealthy)
    }

    @Test("rename, mkdir and confirmed delete work on the volume")
    func fileOps() throws {
        guard let volume = testVolume() else { return }
        let scratch = try scratch(in: volume, "ops")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let dir = try FileOps.createFolder(named: "Δοκιμή", in: scratch)
        let renamed = try FileOps.rename(item: dir, to: "Δοκιμή-2", driveRoot: volume)
        #expect(FileManager.default.fileExists(atPath: renamed.path))
        #expect(throws: FileOpError.self) {
            try FileOps.delete(items: [renamed], driveRoot: volume, confirmed: false)
        }
        try FileOps.delete(items: [renamed], driveRoot: volume, confirmed: true)
        #expect(!FileManager.default.fileExists(atPath: renamed.path))
    }
}
