import Foundation

/// Pre-mount health check for NTFS volumes.
///
/// Real fsck for NTFS on macOS depends on the installed backend
/// (`ntfsfix` from NTFS-3G, vendor checkers, or `diskutil verifyVolume`).
/// This type records what was checked and refuses write-enable when
/// the volume looks unclean, instead of mounting it anyway.
public struct FilesystemHealth: Equatable, Sendable {
    public var volumeHealthy: Bool
    public var checks: [String]
    public var warnings: [String]

    public init(volumeHealthy: Bool, checks: [String], warnings: [String] = []) {
        self.volumeHealthy = volumeHealthy
        self.checks = checks
        self.warnings = warnings
    }
}

public enum FilesystemCheck {
    /// Pure decision helper (testable).
    ///
    /// NTFS truth learned on a live Mac: `diskutil verifyVolume` can NEVER
    /// verify NTFS — it always fails with "Invalid request (-69886)" because
    /// macOS ships no NTFS verifier. Treating that as damage was a false
    /// positive that blocked healthy volumes. For NTFS the check is therefore
    /// the hibernation marker plus the write driver's own gatekeeping
    /// (NTFS-3G replays journals and refuses hibernated volumes itself;
    /// vendor drivers self-check). `verifyVolume` still applies to
    /// non-NTFS volumes.
    public static func evaluate(
        verifyExitCode: Int,
        verifyOutput: String,
        hibernatedMarkersPresent: Bool,
        filesystemIsNTFS: Bool
    ) -> FilesystemHealth {
        var warnings: [String] = []
        if hibernatedMarkersPresent {
            warnings.append("Windows hibernation marker detected — mounting read-only to avoid corruption. Shut Windows down fully (no hibernate / fast startup), or run chkdsk on Windows, then retry.")
            return FilesystemHealth(volumeHealthy: false, checks: ["hibernation-marker"], warnings: warnings)
        }
        if filesystemIsNTFS {
            return FilesystemHealth(
                volumeHealthy: true,
                checks: ["hibernation-marker", "driver-gatekeeper"],
                warnings: []
            )
        }
        let lower = verifyOutput.lowercased()
        if verifyExitCode != 0 || lower.contains("error") || lower.contains("invalid") || lower.contains("failed") {
            warnings.append("Volume verification reported a problem. Run chkdsk on Windows before enabling write.")
            return FilesystemHealth(volumeHealthy: false, checks: ["verifyVolume"], warnings: warnings)
        }
        return FilesystemHealth(volumeHealthy: true, checks: ["verifyVolume"])
    }

    /// Live check: hibernation marker at the volume root, plus
    /// `diskutil verifyVolume` (read-only) for NON-NTFS volumes only.
    /// Never modifies the disk.
    public static func check(device: String, mountPoint: URL?, filesystemIsNTFS: Bool) -> FilesystemHealth {
        var hibernated = false
        if let mountPoint {
            let hiber = mountPoint.appendingPathComponent("hiberfil.sys")
            hibernated = FileManager.default.fileExists(atPath: hiber.path)
        }
        if filesystemIsNTFS {
            return evaluate(
                verifyExitCode: 0,
                verifyOutput: "",
                hibernatedMarkersPresent: hibernated,
                filesystemIsNTFS: true
            )
        }
        var output = ""
        var exitCode = 0
        do {
            output = try MountManager.run(MountManager.verifyCommand(device: device), authorized: false)
        } catch {
            output = String(describing: error)
            exitCode = 1
        }
        return evaluate(
            verifyExitCode: exitCode,
            verifyOutput: output,
            hibernatedMarkersPresent: hibernated,
            filesystemIsNTFS: false
        )
    }
}
