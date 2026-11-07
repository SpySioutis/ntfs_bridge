import Foundation

/// Blocking disk discovery. Lives in Core (not in a @MainActor view model)
/// so it can be unit-tested and — critically — so it NEVER runs on the
/// main thread. Running `diskutil` synchronously inside SwiftUI's
/// launch-time attribute-graph update aborts the app
/// (AG::precondition_failure → SIGABRT). Callers must invoke
/// `collectSnapshot()` from a background thread/task and apply the
/// returned snapshot on the main actor.
public enum Discovery {
    public struct Snapshot: Sendable {
        public var drives: [Drive]
        public var backend: BackendStatus
        public var logLines: [String]
    }

    /// Full discovery, in order:
    /// 1. Mounted external volumes (FileManager, fast).
    /// 2. Every device from `diskutil list`, with per-device `diskutil info`
    ///    — this catches NTFS volumes macOS refused to auto-mount (dirty
    ///    journal, hibernation), the classic "nothing shows up" case.
    /// Read-only state always comes from the kernel (statfs), never from
    /// diskutil's plist, which exposes no read-only key.
    public static func collectSnapshot() -> Snapshot {
        var logs: [String] = []
        let backend = BackendDetector.detectLive()
        var found: [Drive] = []
        var seenIDs = Set<String>()

        for url in DriveDetector.allMountedVolumes() {
            let values = try? url.resourceValues(forKeys: [
                .volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey,
                .volumeLocalizedFormatDescriptionKey, .volumeIsReadOnlyKey,
                .volumeIsEjectableKey, .volumeIsRemovableKey,
            ])
            let name = values?.volumeName ?? url.lastPathComponent
            let fs = values?.volumeLocalizedFormatDescription ?? "unknown"
            // Resolve the device node for eject/health via diskutil (best effort).
            let device = deviceNode(forMountPoint: url.path) ?? url.path
            // diskutil truth decides: FileManager ejectable flags lie for
            // some USB drives (they report neither ejectable nor removable).
            let info = diskutilInfo(device: device)
            guard DriveDetector.isUserVolume(
                mountPath: url.path,
                filesystem: info?.FilesystemType ?? fs,
                info: info,
                ejectable: values?.volumeIsEjectable ?? false,
                removable: values?.volumeIsRemovable ?? false
            ) else { continue }
            var drive = Drive(
                id: device,
                volumeName: info?.VolumeName ?? name,
                mountPoint: url,
                filesystem: fs,
                totalBytes: Int64(values?.volumeTotalCapacity ?? 0),
                freeBytes: Int64(values?.volumeAvailableCapacity ?? 0),
                isExternal: true,
                isEjectable: true,
                mountReadOnly: true
            )
            if let enriched = enrichViaDiskutil(drive) { drive = enriched }
            drive = DriveDetector.applyingMountTruth(drive)
            if seenIDs.insert(drive.id).inserted {
                found.append(drive)
                logs.append("Detected mounted volume '\(drive.volumeName)' (\(drive.filesystem)) at \(url.path) — \(drive.mountReadOnly ? "read-only" : "writable")")
            }
        }

        // Catch unmounted external volumes (connected but never mounted).
        for device in allDiskDevices() {
            let node = "/dev/\(device)"
            if seenIDs.contains(node) { continue }
            guard let info = diskutilInfo(device: node),
                  let candidate = DriveDetector.drive(from: info)
            else { continue }
            let external = candidate.isExternal || candidate.isEjectable
            guard external, candidate.mountPoint == nil else { continue }
            seenIDs.insert(candidate.id)
            found.append(candidate)
            logs.append("Detected UNMOUNTED volume '\(candidate.volumeName)' (\(candidate.filesystem), \(candidate.id)) — press Mount to attach it.")
        }

        let sorted = found.sorted { $0.volumeName < $1.volumeName }
        if sorted.isEmpty {
            logs.append("Refresh found no external volumes. If the drive is plugged in: check cable/port, look in Disk Utility, install a write backend.")
        }
        logs.append("Refresh complete: \(sorted.count) external volume(s), backend: \(backend.backend.rawValue)")
        return Snapshot(drives: sorted, backend: backend, logLines: logs)
    }

    public static func runDiskutil(_ args: [String]) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return nil }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return pipe.fileHandleForReading.readDataToEndOfFile()
    }

    public static func allDiskDevices() -> [String] {
        guard let data = runDiskutil(["list", "-plist"]),
              let devices = try? DriveDetector.parseDiskList(data)
        else { return [] }
        return devices
    }

    public static func diskutilInfo(device: String) -> DriveDetector.DiskUtilInfo? {
        guard let data = runDiskutil(["info", "-plist", device]) else { return nil }
        return try? PropertyListDecoder().decode(DriveDetector.DiskUtilInfo.self, from: data)
    }

    public static func deviceNode(forMountPoint path: String) -> String? {
        // `diskutil info <mountpoint> -plist` → DeviceNode. Best effort, read-only.
        guard let data = runDiskutil(["info", "-plist", path]) else { return nil }
        return (try? DriveDetector.parseInfoPlist(data))?.id
    }

    public static func enrichViaDiskutil(_ drive: Drive) -> Drive? {
        guard let data = runDiskutil(["info", "-plist", drive.id]) else { return nil }
        return try? DriveDetector.parseInfoPlist(data)
            .map { info in
                var copy = drive
                // Read-only state is applied later via applyingMountTruth
                // (kernel statfs), because diskutil's plist carries no such key.
                copy.filesystem = info.filesystem
                if copy.totalBytes == 0 { copy.totalBytes = info.totalBytes }
                if copy.freeBytes == 0 { copy.freeBytes = info.freeBytes }
                return copy
            }
    }
}
