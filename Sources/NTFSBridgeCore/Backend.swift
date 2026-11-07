import Foundation

/// Proven NTFS write backends NTFS Bridge can use.
///
/// NTFS Bridge ships NO filesystem driver of its own. It detects which
/// proven third-party stack — if any — is installed and healthy, and only
/// then offers read/write mounting. When nothing is present it stays
/// honestly read-only and guides the user to a safe install.
public enum NTFSWriteBackend: String, Equatable, Sendable {
    /// No write backend found. Volumes stay read-only.
    case none
    /// Open-source FUSE path: NTFS-3G on top of macFUSE or FUSE-T (kext-free).
    case ntfs3gFuse
    /// Apple's user-space filesystem framework (macOS 15.4+/26+),
    /// e.g. NTFS4Mac, NTFSTool, iBoysoft Extension mode, PolyDrive.
    case fskit
    /// Commercial drivers (Paragon NTFS, Tuxera NTFS, iBoysoft Advanced mode).
    case commercial
}

public struct BackendStatus: Equatable, Sendable {
    public var backend: NTFSWriteBackend
    /// Human-readable detail, e.g. which binaries/extensions were found.
    public var detail: String
    /// Whether enabling write can be attempted right now.
    public var canEnableWrite: Bool
    /// Per-driver probe results, so the UI can show the user exactly
    /// what was found and what is missing.
    public var checks: [BackendCheck] = []
    /// The single most useful next action, computed from the checks.
    public var nextStep: String = ""

    public init(backend: NTFSWriteBackend, detail: String, canEnableWrite: Bool, checks: [BackendCheck] = [], nextStep: String = "") {
        self.backend = backend
        self.detail = detail
        self.canEnableWrite = canEnableWrite
        self.checks = checks
        self.nextStep = nextStep
    }
}

/// One row of the "which NTFS driver do I have?" breakdown.
public struct BackendCheck: Equatable, Sendable {
    /// e.g. "NTFS-3G driver binary".
    public var label: String
    /// Whether this probe found its driver piece.
    public var found: Bool
    /// What was found, or what to install when missing.
    public var hint: String

    public init(label: String, found: Bool, hint: String) {
        self.label = label
        self.found = found
        self.hint = hint
    }
}

/// Small seam for tests: the detector never touches the real filesystem
/// directly, it asks this environment.
public struct BackendEnvironment: Sendable {
    public var fileExists: @Sendable (String) -> Bool
    public var fskitModuleNames: [String]
    public var commercialAppNames: [String]
    /// Output of `/sbin/mount` (nil = skip the active-mount probe).
    public var mountOutput: String?

    public init(
        fileExists: @escaping @Sendable (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
        fskitModuleNames: [String] = [],
        commercialAppNames: [String] = [],
        mountOutput: String? = nil
    ) {
        self.fileExists = fileExists
        self.fskitModuleNames = fskitModuleNames
        self.commercialAppNames = commercialAppNames
        self.mountOutput = mountOutput
    }
}

public enum BackendDetector {
    static let ntfs3gPaths = [
        "/opt/homebrew/bin/ntfs-3g",
        "/usr/local/bin/ntfs-3g",
        "/opt/homebrew/sbin/mount_ntfs-3g",
        "/usr/local/sbin/mount_ntfs-3g",
    ]
    static let fuseTPaths = [
        // FUSE-T ships as an app/cask, NOT as a /Library/Filesystems bundle
        // (verified on a live Mac: only fuse-t.app + brew cask exist).
        "/Applications/fuse-t.app",
        "/opt/homebrew/Caskroom/fuse-t",
        "/usr/local/Caskroom/fuse-t",
        "/opt/homebrew/Cellar/fuse-t",
        "/usr/local/Cellar/fuse-t",
        "/Library/Filesystems/fuse-t.fs",
        "/Library/Application Support/FUSE-T",
    ]
    static let macFusePaths = [
        "/Library/Filesystems/macfuse.fs",
        "/Library/Filesystems/osxfuse.fs",
    ]
    static let commercialPaths = [
        "/Applications/Paragon NTFS for Mac.app",
        "/Library/Application Support/Paragon Software/NTFS for Mac",
        "/Applications/Tuxera Disk Manager.app",
        "/Library/Filesystems/tuxera_ntfs.fs",
        "/Library/Filesystems/ufsd_NTFS.fs",
        "/Applications/iBoysoft NTFS for Mac.app",
        "/Applications/NTFSTool.app",
        "/Applications/PolyDrive.app",
    ]

    /// Detects FSKit NTFS modules from `pluginkit -m -p com.apple.file-system`
    /// output lines. Kept as a pure function for testing.
    public static func fskitNTFSModules(in pluginkitLines: [String]) -> [String] {
        pluginkitLines.filter { line in
            let lower = line.lowercased()
            return lower.contains("ntfs") &&
                (lower.contains("fskit") || lower.contains("fskit") || lower.contains("ntfs"))
        }
    }

    /// Actionable handoff for drivers that own their own mounting.
    /// Installing the app is only half the job — the user must also mount
    /// the volume writable inside the vendor app (and approve its extension).
    public static func vendorHandoffMessage(detail: String, volumeName: String) -> String {
        if detail.lowercased().contains("ntfstool") {
            return "NTFSTool is installed, but '\(volumeName)' is still mounted read-only — the driver hasn't taken over yet. Open Ntfstool.app (in Applications), mount the disk writable there — if macOS asks, approve its extension in System Settings → Privacy & Security (a restart may be required) — then come back here and press Refresh."
        }
        return "The installed driver manages mounting itself. Open the vendor app to mount '\(volumeName)' read/write (approving its extension in System Settings if asked), then press Refresh here."
    }

    /// Devices with a live WRITABLE NTFS mount — proof a driver is not
    /// just installed but actively working. Pure function for testing.
    /// Matches mount lines mentioning ntfs without a read-only flag.
    public static func activeWritableNTFSMounts(in mountOutput: String) -> [String] {
        mountOutput.components(separatedBy: "\n").compactMap { line in
            let lower = line.lowercased()
            guard lower.contains("ntfs") else { return nil }
            guard !lower.contains("read-only") && !lower.contains("read_only") else { return nil }
            let device = line.split(separator: " ").first.map(String.init) ?? ""
            return device.hasPrefix("/dev/") ? device : nil
        }
    }

    public static func detect(in env: BackendEnvironment) -> BackendStatus {
        let hasNtfs3g = ntfs3gPaths.contains(where: env.fileExists)
        let hasFuseT = fuseTPaths.contains(where: env.fileExists)
        let hasMacFuse = macFusePaths.contains(where: env.fileExists)
        let commercialHits = commercialPaths.filter(env.fileExists) + env.commercialAppNames
        let fskitHits = env.fskitModuleNames.filter { $0.lowercased().contains("ntfs") }
        let activeMounts = env.mountOutput.map(activeWritableNTFSMounts(in:)) ?? []

        let checks = [
            BackendCheck(
                label: "NTFS-3G driver binary",
                found: hasNtfs3g,
                hint: hasNtfs3g ? (ntfs3gPaths.first(where: env.fileExists) ?? "found")
                    : "Not found — brew install ntfs-3g-mac"
            ),
            BackendCheck(
                label: "FUSE runtime (FUSE-T or macFUSE)",
                found: hasFuseT || hasMacFuse,
                hint: hasFuseT ? "FUSE-T present (kext-free)"
                    : hasMacFuse ? "macFUSE present (may need system-extension approval)"
                    : "Not found — brew install --cask fuse-t"
            ),
            BackendCheck(
                label: "FSKit NTFS module (macOS 26+)",
                found: !fskitHits.isEmpty,
                hint: fskitHits.isEmpty ? "None — install NTFS4Mac/NTFSTool and approve in System Settings"
                    : fskitHits.joined(separator: ", ")
            ),
            BackendCheck(
                label: "Commercial NTFS driver",
                found: !commercialHits.isEmpty,
                hint: commercialHits.isEmpty ? "None — Paragon / Tuxera / iBoysoft"
                    : commercialHits.joined(separator: ", ")
            ),
            BackendCheck(
                label: "Writable NTFS mount active",
                found: !activeMounts.isEmpty,
                hint: activeMounts.isEmpty ? "No writable NTFS mount right now"
                    : activeMounts.joined(separator: ", ")
            ),
        ]

        let ready = !fskitHits.isEmpty || !commercialHits.isEmpty
            || (hasNtfs3g && (hasFuseT || hasMacFuse)) || !activeMounts.isEmpty
        let nextStep: String
        if ready {
            nextStep = "Driver ready — select the drive, run Check health, then Enable NTFS write."
        } else if (hasFuseT || hasMacFuse) && !hasNtfs3g {
            nextStep = "FUSE runtime is installed but the NTFS engine is missing — easiest fix: brew install --cask ntfstool (free, no compilation) — then press Refresh."
        } else if hasNtfs3g {
            nextStep = "NTFS-3G is installed but no FUSE runtime was found — install it with: brew install --cask fuse-t — then press Refresh."
        } else {
            nextStep = "Easiest free path: brew install --cask ntfstool — then approve its extension in System Settings and press Refresh."
        }

        if !fskitHits.isEmpty {
            return BackendStatus(
                backend: .fskit,
                detail: "FSKit NTFS module(s): \(fskitHits.joined(separator: ", "))",
                canEnableWrite: true,
                checks: checks,
                nextStep: nextStep
            )
        }
        if !commercialHits.isEmpty {
            return BackendStatus(
                backend: .commercial,
                detail: "Commercial driver: \(commercialHits.joined(separator: ", "))",
                canEnableWrite: true,
                checks: checks,
                nextStep: nextStep
            )
        }
        if hasNtfs3g && (hasFuseT || hasMacFuse) {
            let fuse = hasFuseT ? "FUSE-T" : "macFUSE"
            return BackendStatus(
                backend: .ntfs3gFuse,
                detail: "NTFS-3G via \(fuse) (open source, GPLv2)",
                canEnableWrite: true,
                checks: checks,
                nextStep: nextStep
            )
        }
        if !activeMounts.isEmpty {
            // A driver the file-probes don't know is doing the job —
            // trust the live mount, not the install checklist.
            return BackendStatus(
                backend: .commercial,
                detail: "Writable NTFS mount active (\(activeMounts.joined(separator: ", "))) via an installed driver.",
                canEnableWrite: true,
                checks: checks,
                nextStep: nextStep
            )
        }
        if hasNtfs3g {
            return BackendStatus(
                backend: .none,
                detail: "NTFS-3G found but no FUSE runtime (install FUSE-T or macFUSE).",
                canEnableWrite: false,
                checks: checks,
                nextStep: nextStep
            )
        }
        return BackendStatus(
            backend: .none,
            detail: "No NTFS write driver installed. Volumes mount read-only.",
            canEnableWrite: false,
            checks: checks,
            nextStep: nextStep
        )
    }

    /// Live detection on this Mac.
    public static func detectLive() -> BackendStatus {
        let env = BackendEnvironment(
            fskitModuleNames: liveFSKitModules(),
            commercialAppNames: [],
            mountOutput: liveMountOutput()
        )
        return detect(in: env)
    }

    private static func liveMountOutput() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/sbin/mount")
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return nil }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
    }

    private static func liveFSKitModules() -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pluginkit")
        process.arguments = ["-m", "-p", "com.apple.file-system"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return [] }
        process.waitUntilExit()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return fskitNTFSModules(in: output.components(separatedBy: "\n"))
    }
}
