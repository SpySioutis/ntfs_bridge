import Foundation

/// Builds and runs ONLY safe disk commands.
///
/// Allow-listed verbs: `info`, `list`, `unmount`, `eject`, `mount`,
/// `verifyVolume`. There is intentionally no API to format, erase,
/// partition, or create a filesystem — SafetyGuard blocks those
/// fragments even if a caller ever constructed them.
public struct DiskCommand: Equatable, Sendable {
    public var executable: String
    public var arguments: [String]
    public var requiresAdmin: Bool

    public init(executable: String, arguments: [String], requiresAdmin: Bool = false) {
        self.executable = executable
        self.arguments = arguments
        self.requiresAdmin = requiresAdmin
    }

    public var displayString: String {
        ([executable] + arguments).joined(separator: " ")
    }
}

public enum MountManager {
    public static func infoCommand(device: String) -> DiskCommand {
        DiskCommand(executable: "/usr/sbin/diskutil", arguments: ["info", "-plist", device])
    }

    public static func unmountCommand(mountPoint: String) -> DiskCommand {
        DiskCommand(executable: "/usr/sbin/diskutil", arguments: ["unmount", mountPoint])
    }

    public static func ejectCommand(device: String) -> DiskCommand {
        DiskCommand(executable: "/usr/sbin/diskutil", arguments: ["eject", device])
    }

    public static func listCommand() -> DiskCommand {
        DiskCommand(executable: "/usr/sbin/diskutil", arguments: ["list", "-plist"])
    }

    /// Mounts an unmounted volume read-only-by-default via the system.
    /// Safe and non-destructive: mounting never formats or erases.
    public static func mountCommand(device: String) -> DiskCommand {
        DiskCommand(executable: "/usr/sbin/diskutil", arguments: ["mount", device])
    }

    public static func mountReadOnlyCommand(device: String) -> DiskCommand {
        DiskCommand(executable: "/usr/sbin/diskutil", arguments: ["mount", "readOnly", device])
    }

    public static func verifyCommand(device: String) -> DiskCommand {
        DiskCommand(executable: "/usr/sbin/diskutil", arguments: ["verifyVolume", device])
    }

    /// Bundled engine shipped inside NTFSBridge.app (staged by
    /// scripts/bundle-engine.sh). Nil until the maintainer runs it.
    public static func bundledNtfs3gPath() -> String? {
        guard let resources = Bundle.main.resourceURL else { return nil }
        let path = resources.appendingPathComponent("bin/ntfs-3g").path
        return FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }

    /// Safe NTFS-3G remount command for the FUSE backend.
    /// The caller MUST have unmounted the volume first and MUST have
    /// explicit user consent + a passed health check.
    /// Prefers the bundled engine, then system installs — mirroring
    /// `BackendManager.resolve`, so the UI's claim and the executed
    /// binary never disagree. An explicit `binary` overrides both
    /// (used by tests and diagnostics).
    public static func ntfs3gMountCommand(device: String, mountPoint: String, binary: String? = nil) -> DiskCommand {
        let resolved = binary
            ?? bundledNtfs3gPath()
            ?? ["/opt/homebrew/bin/ntfs-3g", "/usr/local/bin/ntfs-3g"]
                .first(where: { FileManager.default.fileExists(atPath: $0) })
            ?? "/opt/homebrew/bin/ntfs-3g"
        return DiskCommand(
            executable: resolved,
            arguments: [device, mountPoint, "-o", "local,allow_other,auto_xattr"],
            requiresAdmin: true
        )
    }

    @discardableResult
    public static func run(_ command: DiskCommand, authorized: Bool) throws -> String {
        try SafetyGuard.forbidDestructiveCommand([command.executable] + command.arguments)
        if command.requiresAdmin && !authorized {
            throw MountError.authorizationRequired(command.displayString)
        }
        let process = Process()
        if command.requiresAdmin {
            // Explicit admin authorization via AppleScript. The system
            // prompts the user; nothing is silently elevated.
            let script = "do shell script \(shellQuoted(command.displayString)) with administrator privileges"
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", script]
        } else {
            process.executableURL = URL(fileURLWithPath: command.executable)
            process.arguments = command.arguments
        }
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        try process.run()
        process.waitUntilExit()
        let out = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            throw MountError.commandFailed(command.displayString, err.isEmpty ? out : err)
        }
        return out
    }

    private static func shellQuoted(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}

public enum MountError: Error, Equatable {
    case authorizationRequired(String)
    case commandFailed(String, String)
}
