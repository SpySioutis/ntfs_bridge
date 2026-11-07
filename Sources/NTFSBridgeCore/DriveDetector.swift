import Foundation

/// Kernel mount-flag check. This is the authoritative answer to
/// "is this mount point read-only": `diskutil info -plist` exposes NO
/// read-only key (verified against live output — only the human-readable
/// text has "Media/Volume Read-Only"), so parsing diskutil could never
/// report it. `statfs` reads the live `MNT_RDONLY` flag instead.
public enum MountFlags {
    public static func mountIsReadOnly(at path: String) -> Bool? {
        var fs = statfs()
        guard statfs(path, &fs) == 0 else { return nil }
        return (Int32(fs.f_flags) & MNT_RDONLY) != 0
    }

    public static func volumeIsReadOnly(url: URL) -> Bool? {
        try? url.resourceValues(forKeys: [.volumeIsReadOnlyKey]).volumeIsReadOnly
    }
}

/// Parses `diskutil` output and FileManager volumes into [Drive].
/// Process execution is kept separate from parsing so tests can feed
/// recorded fixtures without touching real disks.
public enum DriveDetector {
    public struct DiskUtilInfo: Decodable {
        public var DeviceNode: String?
        public var VolumeName: String?
        public var MountPoint: String?
        public var FilesystemType: String?
        public var TotalSize: Int64?
        public var FreeSpace: Int64?
        public var Internal: Bool?
        public var Ejectable: Bool?
        public var Removable: Bool?

        enum CodingKeys: String, CodingKey {
            case DeviceNode = "DeviceNode"
            case VolumeName = "VolumeName"
            case MountPoint = "MountPoint"
            case FilesystemType = "FilesystemType"
            case TotalSize = "TotalSize"
            case FreeSpace = "FreeSpace"
            case Internal = "Internal"
            case Ejectable = "Ejectable"
            case Removable = "Removable"
        }
    }

    /// Device identifiers from `diskutil list -plist` (`AllDisks`).
    public struct DiskList: Decodable {
        public var AllDisks: [String]?

        enum CodingKeys: String, CodingKey {
            case AllDisks = "AllDisks"
        }
    }

    public static func parseDiskList(_ data: Data) throws -> [String] {
        (try PropertyListDecoder().decode(DiskList.self, from: data)).AllDisks ?? []
    }

    /// Builds a Drive from one decoded `diskutil info -plist` record.
    /// Returns nil when the record has no device node (not a real volume).
    /// NOTE: `mountReadOnly` is a placeholder here — diskutil's plist has
    /// no read-only key, so callers MUST override it with
    /// `MountFlags.mountIsReadOnly(at:)` (kernel truth) afterwards.
    public static func drive(from info: DiskUtilInfo) -> Drive? {
        guard let node = info.DeviceNode, !node.isEmpty else { return nil }
        let raw = info.FilesystemType ?? "unknown"
        let fs = raw.uppercased() == "NTFS" ? "NTFS" : raw
        return Drive(
            id: node,
            volumeName: info.VolumeName ?? node,
            mountPoint: info.MountPoint.map { URL(fileURLWithPath: $0) },
            filesystem: fs,
            totalBytes: info.TotalSize ?? 0,
            freeBytes: info.FreeSpace ?? 0,
            isExternal: !(info.Internal ?? true),
            isEjectable: info.Ejectable ?? (info.Removable ?? false),
            mountReadOnly: true
        )
    }

    /// Applies the kernel mount-flag truth to a Drive built from diskutil.
    /// Unmounted volumes stay read-only by definition (nothing to write to).
    public static func applyingMountTruth(_ drive: Drive) -> Drive {
        var copy = drive
        if let mount = drive.mountPoint {
            copy.mountReadOnly = MountFlags.mountIsReadOnly(at: mount.path)
                ?? MountFlags.volumeIsReadOnly(url: mount)
                ?? true
        } else {
            copy.mountReadOnly = true
        }
        return copy
    }

    public static func parseInfoPlist(_ data: Data) throws -> Drive? {
        let decoder = PropertyListDecoder()
        let info = try decoder.decode(DiskUtilInfo.self, from: data)
        return drive(from: info)
    }

    /// Decides whether a mounted path is a user volume worth showing.
    /// Pure function so the "TOSHIBA paradox" stays covered by tests:
    /// FileManager reports some USB drives as neither ejectable nor
    /// removable, while `diskutil info` correctly says Internal=false.
    /// System paths are never user volumes.
    public static func isUserVolume(
        mountPath: String,
        filesystem: String,
        info: DiskUtilInfo?,
        ejectable: Bool,
        removable: Bool
    ) -> Bool {
        if mountPath == "/" { return false }
        for prefix in ["/System/", "/private/", "/dev/"] where mountPath.hasPrefix(prefix) {
            return false
        }
        if info?.Internal == false { return true }
        if filesystem.uppercased() == "NTFS" { return true }
        return ejectable || removable
    }

    /// All mounted volume URLs. Callers filter with `isUserVolume`
    /// (diskutil truth), NOT with FileManager ejectable flags alone.
    public static func allMountedVolumes() -> [URL] {
        let keys: [URLResourceKey] = [.volumeIsLocalKey, .volumeNameKey]
        return FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: []) ?? []
    }

    /// Best-effort live enumeration without DiskArbitration private APIs:
    /// uses FileManager mounted volumes + per-volume resource values.
    /// External/NTFS detail is enriched by callers via `diskutil info`.
    /// NOTE: kept for compatibility; Discovery prefers `allMountedVolumes`
    /// + `isUserVolume` because ejectable flags lie for some USB drives.
    public static func liveExternalCandidates() -> [URL] {
        let keys: [URLResourceKey] = [.volumeIsLocalKey, .volumeIsEjectableKey, .volumeIsRemovableKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: []) ?? []
        return urls.filter { url in
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return false }
            return (values.volumeIsEjectable == true) || (values.volumeIsRemovable == true)
        }
    }

    public static func volumeFilesystem(at url: URL) -> String? {
        (try? url.resourceValues(forKeys: [.volumeLocalizedFormatDescriptionKey]))?.volumeLocalizedFormatDescription
    }
}
