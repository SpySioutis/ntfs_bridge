import Foundation
import Testing
@testable import NTFSBridgeCore

@Suite("BackendManager")
struct BackendManagerTests {
    private static let bundledDir = "/Applications/NTFSBridge.app/Contents/Resources/bin"

    private func envWithBundledEngine(fusePresent: Bool = true) -> BackendEnvironment {
        BackendEnvironment(fileExists: { path in
            if path == Self.bundledDir + "/ntfs-3g" { return true }
            if fusePresent, path == "/Applications/fuse-t.app" { return true }
            return false
        })
    }

    @Test("prefers bundled ntfs-3g over system installs")
    func prefersBundled() {
        let env = BackendEnvironment(fileExists: { path in
            path == Self.bundledDir + "/ntfs-3g"
                || path == "/opt/homebrew/bin/ntfs-3g"
                || path == "/Applications/fuse-t.app"
        })
        let resolved = BackendManager.resolve(
            in: env, layout: BackendLayout(bundledBinDir: Self.bundledDir))
        #expect(resolved.backend == .ntfs3gFuse)
        #expect(resolved.source == .bundled)
        #expect(resolved.ntfs3gPath == Self.bundledDir + "/ntfs-3g")
    }

    @Test("falls back to system ntfs-3g when no bundle present")
    func systemFallback() {
        let env = BackendEnvironment(fileExists: { path in
            path == "/opt/homebrew/bin/ntfs-3g" || path == "/Applications/fuse-t.app"
        })
        let resolved = BackendManager.resolve(
            in: env, layout: BackendLayout(bundledBinDir: nil))
        #expect(resolved.backend == .ntfs3gFuse)
        #expect(resolved.source == .system)
        #expect(resolved.ntfs3gPath == "/opt/homebrew/bin/ntfs-3g")
    }

    @Test("bundled engine without FUSE is not enough")
    func bundledNeedsFuse() {
        let resolved = BackendManager.resolve(
            in: envWithBundledEngine(fusePresent: false),
            layout: BackendLayout(bundledBinDir: Self.bundledDir))
        #expect(resolved.backend == .none)
        #expect(resolved.source == nil)
    }

    @Test("fskit detection passes through as system-managed")
    func fskitPassthrough() {
        let env = BackendEnvironment(
            fileExists: { _ in false },
            fskitModuleNames: ["com.example.NTFS.fskit"])
        let resolved = BackendManager.resolve(in: env, layout: .live)
        #expect(resolved.backend == .fskit)
        #expect(resolved.source == .system)
    }

    @Test("writability requires a kernel writable verdict")
    func writabilityMatrix() {
        #expect(BackendManager.evaluateWritability(mountIsReadOnly: false) == .writable)
        #expect(BackendManager.evaluateWritability(mountIsReadOnly: true) != .writable)
        // Unknown mount state fails closed — never show Read & write unverified.
        #expect(BackendManager.evaluateWritability(mountIsReadOnly: nil) != .writable)
    }

    @Test("live writability check fails closed on bogus paths")
    func liveCheckFailClosed() {
        #expect(!BackendManager.confirmWritableLive(at: "/nonexistent-ntfsbridge-probe-\(UUID().uuidString)"))
    }

    @Test("compatibility gates old macOS, allows 13+")
    func compatibilityMatrix() {
        let old = BackendManager.checkCompatibility(osMajor: 12, arch: "arm64")
        #expect(!old.compatible)
        for major in [13, 14, 15, 26] {
            let ok = BackendManager.checkCompatibility(osMajor: major, arch: "arm64")
            #expect(ok.compatible)
        }
        let intel = BackendManager.checkCompatibility(osMajor: 14, arch: "x86_64")
        #expect(intel.compatible)
    }

    @Test("remount honors an explicit binary override")
    func mountCommandOverride() {
        let cmd = MountManager.ntfs3gMountCommand(
            device: "/dev/disk4s1", mountPoint: "/Volumes/X", binary: "/tmp/fake-ntfs-3g")
        #expect(cmd.executable == "/tmp/fake-ntfs-3g")
        #expect(cmd.requiresAdmin)
    }

    @Test("remount falls back to system paths without a bundle")
    func mountCommandFallback() {
        // In the test bundle there is no Resources/bin/ntfs-3g, so the
        // bundled preference is nil and system resolution applies.
        #expect(MountManager.bundledNtfs3gPath() == nil)
        let cmd = MountManager.ntfs3gMountCommand(device: "/dev/disk4s1", mountPoint: "/Volumes/X")
        #expect(cmd.executable.hasSuffix("ntfs-3g"))
        #expect(cmd.requiresAdmin)
    }

    @Test("engine provenance parses, absent or corrupt yields nil")
    func engineInfoParsing() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ntfsbridge-engineinfo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(BackendManager.bundledEngineInfo(at: dir) == nil)
        #expect(BackendManager.bundledEngineInfo(at: nil) == nil)
        let json = """
        {"engine":"ntfs-3g","version":"2026.9.28","source_revision":"7f0f841",
         "license":"GPLv2","bundled_at":"2026-11-07T13:43:25Z"}
        """
        try Data(json.utf8).write(to: dir.appendingPathComponent("engine-info.json"))
        let info = try #require(BackendManager.bundledEngineInfo(at: dir))
        #expect(info.version == "2026.9.28")
        #expect(info.sourceRevision == "7f0f841")
        #expect(info.logLine == "NTFS-3G 2026.9.28 (source 7f0f841)")
        try Data("not json{".utf8).write(to: dir.appendingPathComponent("engine-info.json"))
        #expect(BackendManager.bundledEngineInfo(at: dir) == nil)
    }

    @Test("activation steps never send users to Terminal or Homebrew")
    func activationStepsPlainLanguage() {
        let cases: [ResolvedBackend] = [
            BackendManager.resolve(in: envWithBundledEngine(), layout: BackendLayout(bundledBinDir: Self.bundledDir)),
            BackendManager.resolve(in: BackendEnvironment(fileExists: { _ in false }), layout: BackendLayout(bundledBinDir: nil)),
        ]
        for resolved in cases {
            let steps = BackendManager.activationSteps(for: resolved)
            #expect(!steps.isEmpty)
            let joined = steps.joined(separator: "\n").lowercased()
            #expect(!joined.contains("brew"))
            #expect(!joined.contains("terminal"))
        }
    }
}
