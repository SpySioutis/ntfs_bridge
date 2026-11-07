import Foundation

/// Where a backend's engine comes from.
///
/// The Independent Edition goal is `.bundled`: the engine ships inside
/// NTFSBridge.app so the user installs one app and nothing else.
/// `.system` covers engines managed outside the app (existing installs,
/// vendor drivers, FSKit modules) — detected and used, never required.
public enum BackendSource: String, Equatable, Sendable {
    case bundled
    case system
}

/// Provenance of the bundled engine, as stamped by scripts/bundle-engine.sh.
/// Logged at enable-write time so post-mortems always name the exact engine.
public struct EngineInfo: Codable, Equatable, Sendable {
    public var version: String
    public var sourceRevision: String

    public init(version: String, sourceRevision: String) {
        self.version = version
        self.sourceRevision = sourceRevision
    }

    enum CodingKeys: String, CodingKey {
        case version
        case sourceRevision = "source_revision"
    }

    public var logLine: String {
        "NTFS-3G \(version) (source \(sourceRevision))"
    }
}

/// A fully resolved backend choice: WHAT engine + WHERE it comes from.
///
/// `BackendDetector` answers "what can this Mac do?".
/// `BackendManager` answers "what should the app use, and is it real?".
public struct ResolvedBackend: Equatable, Sendable {
    public var backend: NTFSWriteBackend
    /// nil when backend == .none (nothing to attribute).
    public var source: BackendSource?
    /// Resolved ntfs-3g binary path when backend == .ntfs3gFuse.
    public var ntfs3gPath: String?
    public var detail: String

    public init(backend: NTFSWriteBackend, source: BackendSource? = nil, ntfs3gPath: String? = nil, detail: String) {
        self.backend = backend
        self.source = source
        self.ntfs3gPath = ntfs3gPath
        self.detail = detail
    }
}

/// Filesystem layout the manager resolves engines against.
///
/// Bundled binaries live under `<App>.app/Contents/Resources/bin`
/// (populated by the packaging script once binary bundling lands;
/// until then `bundledBinDir` is nil and resolution falls back to
/// system installs — honestly reported via `.system`).
public struct BackendLayout: Sendable {
    public var bundledBinDir: String?

    public init(bundledBinDir: String? = nil) {
        self.bundledBinDir = bundledBinDir
    }

    /// Layout for this running app. Returns a layout with no bundled
    /// directory when the app bundle has no `bin` resources (yet).
    public static var live: BackendLayout {
        guard let resources = Bundle.main.resourceURL else {
            return BackendLayout(bundledBinDir: nil)
        }
        let dir = resources.appendingPathComponent("bin").path
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dir, isDirectory: &isDir), isDir.boolValue else {
            return BackendLayout(bundledBinDir: nil)
        }
        return BackendLayout(bundledBinDir: dir)
    }
}

/// Compatibility of a backend with this Mac. Pure and testable.
public struct BackendCompatibility: Equatable, Sendable {
    public var compatible: Bool
    public var reason: String

    public init(compatible: Bool, reason: String) {
        self.compatible = compatible
        self.reason = reason
    }
}

/// Genuine-writability verdict. `.writable` is returned ONLY when the
/// kernel reports the mount writable — never from "a binary was seen".
public enum WritabilityVerdict: Equatable, Sendable {
    case writable
    case readOnly(String)
}

/// Backend lifecycle manager: inventory → compatibility → resolution →
/// activation guidance → genuine-writability verification.
///
/// An FSKit-native engine plugs in later as a new resolution branch;
/// until then `.fskit` resolves to system-managed drivers (NTFS4Mac /
/// NTFSTool / vendor Extension mode) that own their own mounting.
public enum BackendManager {
    /// Minimum macOS major version for the bundled FUSE-T based path.
    /// FUSE-T's NFS-loopback mounting is a macOS 13+ story in practice
    /// (SMAppService privileged helper, no kext on any version).
    public static let minimumOSMajor = 13

    /// Resolves which engine the app should use, preferring a bundled
    /// binary over system installs. Detection itself is delegated to
    /// `BackendDetector` (the probe layer); this function adds the
    /// bundled-vs-system decision on top.
    public static func resolve(in env: BackendEnvironment, layout: BackendLayout) -> ResolvedBackend {
        let detected = BackendDetector.detect(in: env)

        let fuseFound = detected.checks.first(where: { $0.label.hasPrefix("FUSE runtime") })?.found ?? false

        if let dir = layout.bundledBinDir {
            let bundledNtfs3g = (dir as NSString).appendingPathComponent("ntfs-3g")
            if env.fileExists(bundledNtfs3g), fuseFound {
                return ResolvedBackend(
                    backend: .ntfs3gFuse,
                    source: .bundled,
                    ntfs3gPath: bundledNtfs3g,
                    detail: "Bundled NTFS-3G (\(bundledNtfs3g)) via system FUSE runtime."
                )
            }
        }

        switch detected.backend {
        case .ntfs3gFuse:
            return ResolvedBackend(
                backend: .ntfs3gFuse,
                source: .system,
                ntfs3gPath: ntfs3gSystemPath(in: env),
                detail: "System NTFS-3G (\(detected.detail)). Install the bundled engine by updating NTFS Bridge."
            )
        case .fskit:
            return ResolvedBackend(
                backend: .fskit,
                source: .system,
                detail: "System-managed FSKit driver (\(detected.detail)). Mounting is owned by the driver."
            )
        case .commercial:
            return ResolvedBackend(
                backend: .commercial,
                source: .system,
                detail: "System-managed commercial driver (\(detected.detail)). Mounting is owned by the vendor app."
            )
        case .none:
            return ResolvedBackend(
                backend: .none,
                source: nil,
                detail: detected.detail
            )
        }
    }

    /// Best-effort system ntfs-3g path (first hit in detector order).
    public static func ntfs3gSystemPath(in env: BackendEnvironment) -> String? {
        BackendDetector.ntfs3gPaths.first(where: env.fileExists)
    }

    /// Whether the bundled engine can run on this Mac. Architecture is
    /// informational (arm64 + x86_64 both supported); the OS floor is
    /// the gate. Pure function for testing; live values come from
    /// `ProcessInfo`.
    public static func checkCompatibility(osMajor: Int, arch: String) -> BackendCompatibility {
        if osMajor < minimumOSMajor {
            return BackendCompatibility(
                compatible: false,
                reason: "macOS \(osMajor) is below the minimum (macOS \(minimumOSMajor)+) for the bundled write engine. Volumes stay read-only."
            )
        }
        return BackendCompatibility(
            compatible: true,
            reason: "macOS \(osMajor) (\(arch)) supports the bundled NTFS-3G + FUSE engine. No kernel extension, no Recovery-mode change."
        )
    }

    /// Reads engine provenance from a bundle Resources directory.
    /// Returns nil when absent or malformed — callers log "unknown engine",
    /// never a guessed version. Pure (injectable URL) for testing.
    public static func bundledEngineInfo(at resourcesURL: URL?) -> EngineInfo? {
        guard let resourcesURL else { return nil }
        let url = resourcesURL.appendingPathComponent("engine-info.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(EngineInfo.self, from: data)
    }

    /// Live provenance for this running app (nil in unit tests / unbundled).
    public static func bundledEngineInfoLive() -> EngineInfo? {
        bundledEngineInfo(at: Bundle.main.resourceURL)
    }

    /// Live compatibility on this Mac.
    public static func checkCompatibilityLive() -> BackendCompatibility {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        #if arch(arm64)
        let arch = "arm64"
        #else
        let arch = "x86_64"
        #endif
        return checkCompatibility(osMajor: v.majorVersion, arch: arch)
    }

    /// Pure writability decision. `mountIsReadOnly` is the kernel's
    /// `statfs` verdict (see `MountFlags`): the ONLY signal trusted.
    /// Unknown (nil) fails closed to read-only — §6 forbids showing
    /// "Read & write" on an unverified mount.
    public static func evaluateWritability(mountIsReadOnly: Bool?) -> WritabilityVerdict {
        switch mountIsReadOnly {
        case .some(false):
            return .writable
        case .some(true):
            return .readOnly("The system reports this volume as read-only.")
        case .none:
            return .readOnly("Mount state could not be confirmed — staying read-only rather than risking data.")
        }
    }

    /// Live genuine-writability check for a mount point. Fail-closed:
    /// any uncertainty (unmounted, statfs failure) returns false.
    public static func confirmWritableLive(at path: String) -> Bool {
        evaluateWritability(mountIsReadOnly: MountFlags.mountIsReadOnly(at: path)) == .writable
    }

    /// Plain-language setup steps for the guided installer UX (§7).
    /// Deliberately contains no Terminal commands and no Homebrew:
    /// the user installs one app, not a toolchain.
    public static func activationSteps(for resolved: ResolvedBackend) -> [String] {
        switch resolved.backend {
        case .ntfs3gFuse where resolved.source == .bundled:
            return [
                "Connect your NTFS drive to the Mac.",
                "Select the drive in NTFS Bridge and press Check health.",
                "Press Enable NTFS write and approve the single administrator prompt from macOS.",
                "When the badge changes to Read & write, copy your files — then eject safely in the app.",
            ]
        case .ntfs3gFuse:
            return [
                "Connect your NTFS drive to the Mac.",
                "Select the drive in NTFS Bridge and press Check health.",
                "Press Enable NTFS write and approve the single administrator prompt from macOS.",
                "Tip: updating NTFS Bridge installs its own built-in engine, so this step disappears.",
            ]
        case .fskit, .commercial:
            return [
                "Connect your NTFS drive to the Mac.",
                BackendDetector.vendorHandoffMessage(detail: resolved.detail, volumeName: "the drive"),
                "If macOS asks, approve the driver's extension in System Settings, then press Refresh in NTFS Bridge.",
            ]
        case .none:
            return [
                "No write engine is available right now, so the drive stays safely read-only.",
                "Reinstall or update NTFS Bridge — the write engine ships inside the app.",
            ]
        }
    }
}
