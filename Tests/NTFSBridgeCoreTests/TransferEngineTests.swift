import Foundation
import Testing
@testable import NTFSBridgeCore

@Suite("TransferEngine")
struct TransferEngineTests {
    private func makeTree() throws -> (src: URL, dst: URL, root: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ntfsbridge-\(UUID().uuidString)")
        let src = root.appendingPathComponent("src")
        let dst = root.appendingPathComponent("dst")
        try FileManager.default.createDirectory(at: src.appendingPathComponent("nested/deep"), withIntermediateDirectories: true)
        try Data("hello ntfs bridge".utf8).write(to: src.appendingPathComponent("a.txt"))
        try Data(repeating: 0xAB, count: 256 * 1024).write(to: src.appendingPathComponent("nested/big.bin"))
        try Data("deep file".utf8).write(to: src.appendingPathComponent("nested/deep/c.txt"))
        return (src, dst, root)
    }

    @Test("copies folders recursively and verifies checksums")
    func recursiveCopy() async throws {
        let (src, dst, root) = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = TransferEngine()
        let report = try await engine.copy(sources: [src], to: dst, allowOverwrite: false, verifyChecksum: true)
        #expect(report.filesCopied == 3)
        #expect(report.verified)
        // Source untouched.
        #expect(FileManager.default.fileExists(atPath: src.appendingPathComponent("a.txt").path))
        let copied = dst.appendingPathComponent("src/nested/big.bin")
        #expect(FileManager.default.fileExists(atPath: copied.path))
        #expect(try Checksum.verify(source: src.appendingPathComponent("nested/big.bin"), destination: copied))
        // No partial files leaked.
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dst.appendingPathComponent("src/nested").path)
            .filter { $0.contains(".ntfsbridge-partial-") }
        #expect(leftovers.isEmpty)
    }

    @Test("refuses overwrite without consent and allows it with consent")
    func overwritePolicy() async throws {
        let (src, dst, root) = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = TransferEngine()
        try await engine.copy(sources: [src], to: dst, verifyChecksum: false)
        await #expect(throws: SafetyError.self) {
            try await engine.copy(sources: [src], to: dst, allowOverwrite: false, verifyChecksum: false)
        }
        let report = try await engine.copy(sources: [src], to: dst, allowOverwrite: true, verifyChecksum: true)
        #expect(report.filesCopied == 3)
    }

    @Test("never deletes the source")
    func sourcePreserved() async throws {
        let (src, dst, root) = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let before = try Data(contentsOf: src.appendingPathComponent("a.txt"))
        _ = try await TransferEngine().copy(sources: [src], to: dst, verifyChecksum: false)
        #expect(try Data(contentsOf: src.appendingPathComponent("a.txt")) == before)
    }

    @Test("reports progress with fraction and speed")
    func progress() async throws {
        final class Collector: @unchecked Sendable {
            private let lock = NSLock()
            private(set) var items: [TransferProgress] = []
            func append(_ p: TransferProgress) { lock.lock(); items.append(p); lock.unlock() }
        }
        let (src, dst, root) = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let collector = Collector()
        _ = try await TransferEngine().copy(sources: [src], to: dst, verifyChecksum: false) { collector.append($0) }
        #expect(!collector.items.isEmpty)
        #expect(collector.items.last?.fraction == 1)
    }

    @Test("checksum mismatch helper detects corruption")
    func checksum() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = dir.appendingPathComponent("a"); let b = dir.appendingPathComponent("b")
        try Data("same".utf8).write(to: a); try Data("same".utf8).write(to: b)
        #expect(try Checksum.verify(source: a, destination: b))
        try Data("different".utf8).write(to: b)
        #expect(!(try Checksum.verify(source: a, destination: b)))
    }
}
