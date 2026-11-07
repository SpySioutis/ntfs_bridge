import Foundation

/// A mounted (or mountable) volume visible to NTFS Bridge.
public struct Drive: Identifiable, Equatable, Sendable {
    public let id: String          // device node, e.g. /dev/disk4s1
    public var deviceNode: String { id }
    public var volumeName: String
    public var mountPoint: URL?
    public var filesystem: String  // e.g. "NTFS", "APFS", "exFAT"
    public var totalBytes: Int64
    public var freeBytes: Int64
    public var isExternal: Bool
    public var isEjectable: Bool
    public var mountReadOnly: Bool

    public init(
        id: String,
        volumeName: String,
        mountPoint: URL?,
        filesystem: String,
        totalBytes: Int64,
        freeBytes: Int64,
        isExternal: Bool,
        isEjectable: Bool,
        mountReadOnly: Bool
    ) {
        self.id = id
        self.volumeName = volumeName
        self.mountPoint = mountPoint
        self.filesystem = filesystem
        self.totalBytes = totalBytes
        self.freeBytes = freeBytes
        self.isExternal = isExternal
        self.isEjectable = isEjectable
        self.mountReadOnly = mountReadOnly
    }

    public var isNTFS: Bool {
        filesystem.uppercased().contains("NTFS")
    }

    /// Write is enabled only when the volume is NTFS, mounted, and NOT read-only.
    /// NTFS Bridge never reports write support it has not observed.
    public var showsWritable: Bool {
        isNTFS && mountPoint != nil && !mountReadOnly
    }

    public var usedBytes: Int64 { max(0, totalBytes - freeBytes) }

    public var capacityFraction: Double {
        guard totalBytes > 0 else { return 0 }
        return Double(usedBytes) / Double(totalBytes)
    }
}
