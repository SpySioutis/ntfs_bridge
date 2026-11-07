import Foundation

/// Errors for on-drive file operations (rename / delete / create-folder).
public enum FileOpError: Error, Equatable {
    case confirmationRequired(String)
    case destinationExists(String)
    case invalidName(String)
    case outsideDriveRoot(String)
    case refusingDriveRoot(String)
    case sourceMissing(String)
    case ioFailed(String)
}

/// File management on a mounted writable volume: rename, explicit-confirm
/// delete, create-folder. Copying stays in `TransferEngine`; these are the
/// small POSIX operations a writable mount makes possible.
///
/// Safety rules (all enforced, all tested):
/// - Every target must live inside the drive root. Nothing outside the
///   selected drive is ever touched.
/// - The drive root itself can never be renamed or deleted.
/// - Delete requires `confirmed == true`, which the UI only passes after
///   an explicit second-step confirmation. Otherwise it throws.
/// - Rename never overwrites: an existing target name fails the op.
/// - Names must be a single path component (no `/`, no `.` / `..`).
public enum FileOps {
    public static func validateName(_ name: String) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.contains("/"),
              trimmed != ".",
              trimmed != "..",
              URL(fileURLWithPath: trimmed).lastPathComponent == trimmed
        else {
            throw FileOpError.invalidName(name)
        }
        return trimmed
    }

    private static func standardized(_ url: URL) -> String {
        url.standardizedFileURL.path
    }

    /// Throws unless `url` is inside `root` (and is not the root itself
    /// when `allowRoot` is false).
    public static func requireInsideRoot(_ url: URL, root: URL, allowRoot: Bool = false) throws {
        let rootPath = standardized(root)
        let target = standardized(url)
        guard target == rootPath ? allowRoot : target.hasPrefix(rootPath + "/") else {
            throw FileOpError.outsideDriveRoot(url.path)
        }
    }

    public static func createFolder(named name: String, in root: URL) throws -> URL {
        let valid = try validateName(name)
        let dest = root.appendingPathComponent(valid)
        if FileManager.default.fileExists(atPath: dest.path) {
            throw FileOpError.destinationExists(dest.path)
        }
        do {
            try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: false)
        } catch {
            throw FileOpError.ioFailed("Create folder failed: \(error)")
        }
        return dest
    }

    /// Renames `item` to a sibling name. Never overwrites.
    public static func rename(item: URL, to newName: String, driveRoot: URL) throws -> URL {
        guard FileManager.default.fileExists(atPath: item.path) else {
            throw FileOpError.sourceMissing(item.path)
        }
        try requireInsideRoot(item, root: driveRoot)
        guard standardized(item) != standardized(driveRoot) else {
            throw FileOpError.refusingDriveRoot(item.path)
        }
        let valid = try validateName(newName)
        let dest = item.deletingLastPathComponent().appendingPathComponent(valid)
        if FileManager.default.fileExists(atPath: dest.path) {
            throw FileOpError.destinationExists(dest.path)
        }
        do {
            try FileManager.default.moveItem(at: item, to: dest)
        } catch {
            throw FileOpError.ioFailed("Rename failed: \(error)")
        }
        return dest
    }

    /// Permanently deletes drive items. `confirmed` must be true — the UI
    /// passes it only after explicit user confirmation. There is no undo.
    public static func delete(items: [URL], driveRoot: URL, confirmed: Bool) throws {
        guard confirmed else {
            throw FileOpError.confirmationRequired(
                items.map(\.lastPathComponent).joined(separator: ", "))
        }
        for item in items {
            try requireInsideRoot(item, root: driveRoot)
            guard standardized(item) != standardized(driveRoot) else {
                throw FileOpError.refusingDriveRoot(item.path)
            }
        }
        for item in items {
            do {
                try FileManager.default.removeItem(at: item)
            } catch {
                throw FileOpError.ioFailed("Delete failed for \(item.lastPathComponent): \(error)")
            }
        }
    }
}
