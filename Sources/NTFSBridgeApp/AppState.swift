import Foundation
import NTFSBridgeCore
import SwiftUI

/// UI-facing transfer state for one copy job.
struct TransferJob: Identifiable {
    let id = UUID()
    var sources: [URL]
    var destinationName: String
    var progress: TransferProgress?
    var status: Status = .running
    var report: TransferReport?
    var error: String?

    enum Status: Equatable { case running, done, failed, cancelled }
}

/// Central UI state. All disk mutations go through here so the views
/// cannot bypass safety checks, logging, or the overwrite-consent flow.
@MainActor
final class AppState: ObservableObject {
    @Published var drives: [Drive] = []
    @Published var selectedID: String?
    @Published var backend: BackendStatus = BackendStatus(backend: .none, detail: "Detecting…", canEnableWrite: false)
    @Published var healthByDevice: [String: FilesystemHealth] = [:]
    @Published var transfers: [TransferJob] = []
    @Published var logLines: [ActivityLogEntry] = []
    @Published var isRefreshing = false
    @Published var lastError: String?

    let logStore = ActivityLogStore(persistTo: ActivityLogStore.defaultFileURL())
    private let engine = TransferEngine()
    private var copyTask: Task<Void, Never>?

    var selected: Drive? { drives.first(where: { $0.id == selectedID }) ?? drives.first }

    init() {
        logLines = logStore.allEntries
        // NOTE: no refresh() here. Blocking disk calls during init ran
        // inside SwiftUI's launch-time attribute-graph update and aborted
        // the app (AG::precondition_failure). Discovery is kicked off from
        // `.task` after first render and always runs off the main thread.
    }

    func log(_ message: String) {
        let entry = ActivityLogEntry(message: message)
        logStore.append(entry)
        logLines.append(entry)
    }

    // MARK: - Drive discovery

    /// Runs an escaping blocking closure on a background thread. Every
    /// disk call (diskutil, pluginkit, statfs) goes through here — the
    /// main thread never blocks, which is what aborted the app at launch.
    private func runBlocking<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await Task.detached(priority: .userInitiated, operation: work).value
    }

    func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        Task {
            let snapshot = await self.runBlocking { Discovery.collectSnapshot() }
            self.applySnapshot(snapshot)
        }
    }

    private func applySnapshot(_ snapshot: Discovery.Snapshot) {
        drives = snapshot.drives
        backend = snapshot.backend
        for line in snapshot.logLines { log(line) }
        if selectedID == nil { selectedID = drives.first?.id }
        isRefreshing = false
    }

    /// Mounts an unmounted volume through the system (never formats).
    /// NTFS mounts read-only unless a write backend takes over.
    /// Blocking work runs off the main thread (same launch-crash reason).
    func mount(_ drive: Drive) {
        Task {
            let outcome: (log: String, error: String?) = await self.runBlocking {
                do {
                    let out = try MountManager.run(MountManager.mountReadOnlyCommand(device: drive.id), authorized: false)
                    return ("Mounted \(drive.volumeName): \(out.trimmingCharacters(in: .whitespacesAndNewlines))", nil)
                } catch {
                    // Fall back to a default mount (lets vendor/FSKit drivers claim it).
                    do {
                        let out = try MountManager.run(MountManager.mountCommand(device: drive.id), authorized: false)
                        return ("Mounted \(drive.volumeName): \(out.trimmingCharacters(in: .whitespacesAndNewlines))", nil)
                    } catch {
                        return ("Mount FAILED for \(drive.volumeName): \(error)", "Mount failed for \(drive.volumeName): \(error). Check Disk Utility and the drive's health on Windows (chkdsk).")
                    }
                }
            }
            self.log(outcome.log)
            self.lastError = outcome.error
            self.refresh()
        }
    }

    // MARK: - Write enable / health / eject

    func checkHealth(_ drive: Drive) {
        Task {
            let health = await self.runBlocking {
                FilesystemCheck.check(device: drive.id, mountPoint: drive.mountPoint, filesystemIsNTFS: drive.isNTFS)
            }
            self.healthByDevice[drive.id] = health
            self.log("Health check \(drive.volumeName): \(health.volumeHealthy ? "healthy" : "NOT healthy") — \(health.warnings.joined(separator: "; "))")
        }
    }

    /// Attempts to enable NTFS write for the selected drive.
    ///
    /// Honest behavior: with no proven backend installed this function
    /// does NOT remount anything — it reports read-only and points at
    /// INSTALL.md. It never uses the deprecated hidden `mount_ntfs -o rw`
    /// path and never disables SIP or touches security policy.
    /// All blocking work runs off the main thread (see init note).
    func enableWrite(_ drive: Drive) {
        lastError = nil
        guard drive.isNTFS else {
            lastError = "Write-enable applies to NTFS volumes only."
            return
        }
        Task {
            let health = await self.runBlocking {
                FilesystemCheck.check(device: drive.id, mountPoint: drive.mountPoint, filesystemIsNTFS: drive.isNTFS)
            }
            self.healthByDevice[drive.id] = health
            self.log("Health check \(drive.volumeName): \(health.volumeHealthy ? "healthy" : "NOT healthy")")
            guard health.volumeHealthy else {
                self.lastError = health.warnings.first ?? "Volume is not healthy. Write stays disabled."
                self.log("Write NOT enabled for \(drive.volumeName): unhealthy.")
                return
            }
            switch self.backend.backend {
            case .none:
                self.lastError = "No NTFS write driver installed. See INSTALL.md (FUSE-T + NTFS-3G, an FSKit driver, or a commercial driver)."
                self.log("Write NOT enabled for \(drive.volumeName): no backend.")
            case .fskit, .commercial:
                self.lastError = BackendDetector.vendorHandoffMessage(detail: self.backend.detail, volumeName: drive.volumeName)
                self.log("Write handoff for \(drive.volumeName): vendor driver (\(self.backend.detail)).")
            case .ntfs3gFuse:
                guard let mount = drive.mountPoint else {
                    self.lastError = "Volume is not mounted."
                    return
                }
                self.log("Attempting NTFS-3G remount for \(drive.volumeName) (admin prompt follows)…")
                if let engine = await self.runBlocking({ BackendManager.bundledEngineInfoLive() }) {
                    self.log("Engine: \(engine.logLine).")
                } else {
                    self.log("Engine: no bundled provenance found — using system ntfs-3g, if present.")
                }
                let outcome: String? = await self.runBlocking {
                    do {
                        try MountManager.run(MountManager.unmountCommand(mountPoint: mount.path), authorized: false)
                        try MountManager.run(MountManager.ntfs3gMountCommand(device: drive.id, mountPoint: mount.path), authorized: true)
                        return nil
                    } catch {
                        return "Remount failed: \(error)"
                    }
                }
                if let outcome {
                    self.lastError = outcome
                    self.log("Remount failed for \(drive.volumeName): \(outcome).")
                } else if await self.runBlocking({ BackendManager.confirmWritableLive(at: mount.path) }) {
                    self.log("Remounted \(drive.volumeName) read/write via NTFS-3G (writability verified).")
                } else {
                    // Remount ran without error but the kernel still reports
                    // read-only: never claim Read & write on an unverified mount.
                    self.lastError = "The drive remounted but macOS still reports it read-only. It stays read-only — check health and retry, or see INSTALL.md."
                    self.log("Remount UNVERIFIED for \(drive.volumeName): kernel still reports read-only.")
                }
                self.refresh()
            }
        }
    }

    func eject(_ drive: Drive) {
        Task {
            let outcome: (log: String, error: String?) = await self.runBlocking {
                do {
                    let out = try MountManager.run(MountManager.ejectCommand(device: drive.id), authorized: false)
                    return ("Ejected \(drive.volumeName): \(out.trimmingCharacters(in: .whitespacesAndNewlines))", nil)
                } catch {
                    return ("Eject FAILED for \(drive.volumeName): \(error). Warn user before unplugging!", "Eject failed: \(error)")
                }
            }
            self.log(outcome.log)
            self.lastError = outcome.error
            self.refresh()
        }
    }

    // MARK: - Copy

    func startCopy(sources: [URL], allowOverwrite: Bool) {
        guard let drive = selected, let destRoot = drive.mountPoint else {
            lastError = "Select a mounted destination drive first."
            return
        }
        guard drive.showsWritable || !drive.isNTFS else {
            lastError = "Destination is read-only. Enable NTFS write first — files were NOT copied."
            log("Copy refused: \(drive.volumeName) is read-only.")
            return
        }
        var job = TransferJob(sources: sources, destinationName: drive.volumeName)
        transfers.append(job)
        let jobID = job.id
        log("Copy started: \(sources.map(\.lastPathComponent).joined(separator: ", ")) → \(drive.volumeName)")
        copyTask?.cancel()
        copyTask = Task {
            do {
                let report = try await engine.copy(
                    sources: sources,
                    to: destRoot,
                    allowOverwrite: allowOverwrite,
                    verifyChecksum: true
                ) { prog in
                    Task { @MainActor in
                        if let idx = self.transfers.firstIndex(where: { $0.id == jobID }) {
                            self.transfers[idx].progress = prog
                        }
                    }
                }
                Task { @MainActor in
                    if let idx = self.transfers.firstIndex(where: { $0.id == jobID }) {
                        self.transfers[idx].status = .done
                        self.transfers[idx].report = report
                    }
                    self.log("Copy finished: \(report.filesCopied) file(s), \(Formatters.bytes(report.bytesCopied)) in \(String(format: "%.1f", report.durationSeconds))s (checksum-verified).")
                    self.refresh()
                }
            } catch is CancellationError {
                Task { @MainActor in
                    if let idx = self.transfers.firstIndex(where: { $0.id == jobID }) {
                        self.transfers[idx].status = .cancelled
                    }
                    self.log("Copy cancelled by user. Partial files were cleaned up.")
                }
            } catch {
                let message: String
                if let t = error as? TransferError, case .cancelled = t {
                    Task { @MainActor in
                        if let idx = self.transfers.firstIndex(where: { $0.id == jobID }) {
                            self.transfers[idx].status = .cancelled
                        }
                    }
                    self.log("Copy cancelled by user. Partial files were cleaned up.")
                    return
                } else if let s = error as? SafetyError, case .destinationExistsWithoutConsent(let u) = s {
                    message = "File exists: \(u). Enable overwrite to replace it — nothing was overwritten."
                } else if let t = error as? TransferError, case .destinationExistsWithoutConsent(let p) = t {
                    message = "File exists: \(p). Enable overwrite to replace it — nothing was overwritten."
                } else if let t = error as? TransferError, case .verificationFailed(let p) = t {
                    message = "Checksum mismatch on \(p). Destination copy removed — retry the transfer."
                } else {
                    message = String(describing: error)
                }
                Task { @MainActor in
                    if let idx = self.transfers.firstIndex(where: { $0.id == jobID }) {
                        self.transfers[idx].status = .failed
                        self.transfers[idx].error = message
                    }
                    self.lastError = message
                    self.log("Copy FAILED: \(message)")
                }
            }
            _ = job
        }
    }

    func cancelCopy() {
        copyTask?.cancel()
    }

    func retry(job: TransferJob, allowOverwrite: Bool) {
        startCopy(sources: job.sources, allowOverwrite: allowOverwrite)
    }

    // MARK: - File management (needs a writable mount)

    private func manageRoot() -> URL? {
        guard let drive = selected, let root = drive.mountPoint,
              drive.showsWritable || !drive.isNTFS
        else { return nil }
        return root
    }

    func createFolder(name: String) {
        guard let root = manageRoot() else {
            lastError = "Select a writable mounted drive first."
            return
        }
        do {
            let created = try FileOps.createFolder(named: name, in: root)
            log("Created folder \(created.lastPathComponent).")
            refresh()
        } catch {
            lastError = describeFileOpError(error)
            log("Create folder FAILED: \(error)")
        }
    }

    func renameItem(at url: URL, to newName: String) {
        guard let root = manageRoot() else {
            lastError = "Select a writable mounted drive first."
            return
        }
        do {
            let dest = try FileOps.rename(item: url, to: newName, driveRoot: root)
            log("Renamed \(url.lastPathComponent) → \(dest.lastPathComponent).")
            refresh()
        } catch {
            lastError = describeFileOpError(error)
            log("Rename FAILED: \(error)")
        }
    }

    /// `confirmed` must come from the UI's explicit second-step confirmation.
    func deleteItems(_ urls: [URL], confirmed: Bool) {
        guard let root = manageRoot() else {
            lastError = "Select a writable mounted drive first."
            return
        }
        do {
            try FileOps.delete(items: urls, driveRoot: root, confirmed: confirmed)
            log("Deleted \(urls.count) item(s): \(urls.map(\.lastPathComponent).joined(separator: ", ")).")
            refresh()
        } catch {
            lastError = describeFileOpError(error)
            log("Delete FAILED: \(error)")
        }
    }

    private func describeFileOpError(_ error: Error) -> String {
        if let e = error as? FileOpError {
            switch e {
            case .confirmationRequired:
                return "Deletion needs explicit confirmation — nothing was deleted."
            case .destinationExists(let p):
                return "Already exists: \(p) — nothing was changed."
            case .invalidName(let n):
                return "Invalid name “\(n)”. Use a single folder/file name."
            case .outsideDriveRoot(let p):
                return "Refused: \(p) is outside the selected drive."
            case .refusingDriveRoot:
                return "Refused: the drive itself cannot be renamed or deleted."
            case .sourceMissing(let p):
                return "Not found: \(p)."
            case .ioFailed(let m):
                return m
            }
        }
        return String(describing: error)
    }
}
