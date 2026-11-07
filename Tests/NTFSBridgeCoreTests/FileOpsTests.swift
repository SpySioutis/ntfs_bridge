import Foundation
import Testing
@testable import NTFSBridgeCore

@Suite("FileOps")
struct FileOpsTests {
    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ntfsbridge-fileops-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test("creates folders and refuses duplicates")
    func createFolder() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let created = try FileOps.createFolder(named: "Photos", in: root)
        #expect(FileManager.default.fileExists(atPath: created.path))
        #expect(throws: FileOpError.self) {
            try FileOps.createFolder(named: "Photos", in: root)
        }
    }

    @Test("rejects dangerous names")
    func invalidNames() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        for bad in ["", "   ", "a/b", ".", "..", "../escape"] {
            #expect(throws: FileOpError.self) {
                try FileOps.createFolder(named: bad, in: root)
            }
        }
    }

    @Test("renames without overwriting")
    func rename() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("a.txt")
        try Data("x".utf8).write(to: file)
        try Data("y".utf8).write(to: root.appendingPathComponent("b.txt"))
        let renamed = try FileOps.rename(item: file, to: "c.txt", driveRoot: root)
        #expect(renamed.lastPathComponent == "c.txt")
        #expect(!FileManager.default.fileExists(atPath: file.path))
        // Existing target name fails instead of overwriting.
        #expect(throws: FileOpError.self) {
            try FileOps.rename(item: renamed, to: "b.txt", driveRoot: root)
        }
    }

    @Test("delete requires explicit confirmation")
    func deleteNeedsConfirmation() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("doomed.txt")
        try Data("x".utf8).write(to: file)
        #expect(throws: FileOpError.self) {
            try FileOps.delete(items: [file], driveRoot: root, confirmed: false)
        }
        #expect(FileManager.default.fileExists(atPath: file.path))
        try FileOps.delete(items: [file], driveRoot: root, confirmed: true)
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test("never deletes the drive root or outside paths")
    func deleteBoundaries() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(throws: FileOpError.self) {
            try FileOps.delete(items: [root], driveRoot: root, confirmed: true)
        }
        #expect(throws: FileOpError.self) {
            try FileOps.delete(
                items: [FileManager.default.temporaryDirectory.appendingPathComponent("elsewhere")],
                driveRoot: root, confirmed: true)
        }
        #expect(throws: FileOpError.self) {
            try FileOps.rename(
                item: FileManager.default.temporaryDirectory.appendingPathComponent("nope"),
                to: "x", driveRoot: root)
        }
        #expect(FileManager.default.fileExists(atPath: root.path))
    }

    @Test("unicode, greek and long names round-trip")
    func awkwardNames() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let names = [
            "Οικογενειακές φωτογραφίες",
            "αρχείο με κενά & τόνους.txt",
            "emoji-🎉-名前.txt",
            String(repeating: "a", count: 200) + ".txt",
        ]
        for name in names {
            let dir = try FileOps.createFolder(named: name, in: root)
            #expect(FileManager.default.fileExists(atPath: dir.path))
            let renamed = try FileOps.rename(item: dir, to: name + "-2", driveRoot: root)
            #expect(FileManager.default.fileExists(atPath: renamed.path))
            try FileOps.delete(items: [renamed], driveRoot: root, confirmed: true)
            #expect(!FileManager.default.fileExists(atPath: renamed.path))
        }
    }
}
