import Foundation

/// Refuses destructive operations anywhere in NTFS Bridge.
/// The app has no format / erase / partition code path by design;
/// this guard is a second line of defence for any command we build.
public enum SafetyError: Error, Equatable {
    case destructiveCommandBlocked(String)
    case sourceMissing(URL)
    case destinationExistsWithoutConsent(URL)
    case unsafeDestination(URL)
}

public enum SafetyGuard {
    /// Fragments that must never appear in a command NTFS Bridge runs.
    /// Matching is case-insensitive and substring-based on purpose:
    /// a destructive intent hidden in any argument is still blocked.
    private static let forbiddenFragments = [
        "erasevolume", "erasedisk", "erase", "format",
        "partitiondisk", "reformat", "newfs_", "mkfs",
        "diskutil erasedisk", "diskutil erasevolume",
        "diskutil partitiondisk", "diskutil reformat",
    ]

    /// Throws if the command looks destructive. Used before every privileged run.
    public static func forbidDestructiveCommand(_ arguments: [String]) throws {
        let joined = arguments.joined(separator: " ").lowercased()
        for fragment in forbiddenFragments where joined.contains(fragment) {
            throw SafetyError.destructiveCommandBlocked(arguments.joined(separator: " "))
        }
    }

    /// Validates a copy destination before any byte is written.
    /// - Parameters:
    ///   - source: file or directory to copy (must exist).
    ///   - destination: final destination URL (must not exist unless overwrite is allowed).
    public static func validateCopy(
        source: URL,
        destination: URL,
        allowOverwrite: Bool
    ) throws {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: source.path, isDirectory: &isDir) else {
            throw SafetyError.sourceMissing(source)
        }
        // Never copy a volume onto itself.
        guard source.standardizedFileURL.path != destination.standardizedFileURL.path else {
            throw SafetyError.unsafeDestination(destination)
        }
        // Refuse to write outside the chosen destination tree traversal.
        if FileManager.default.fileExists(atPath: destination.path), !allowOverwrite {
            throw SafetyError.destinationExistsWithoutConsent(destination)
        }
    }
}
