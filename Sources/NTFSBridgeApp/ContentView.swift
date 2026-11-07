import NTFSBridgeCore
import SwiftUI
import UniformTypeIdentifiers

/// Lists every mounted volume on this Mac so an empty drive list is
/// diagnosable ("the app sees nothing at all" vs "it sees disks but not mine").
private var allVolumesDiagnostic: String {
    let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: [.volumeNameKey], options: []) ?? []
    if urls.isEmpty { return "This Mac reports no mounted volumes at all — macOS volume enumeration itself is failing." }
    let names = urls.map { (try? $0.resourceValues(forKeys: [.volumeNameKey]))?.volumeName ?? $0.path }
    return "Mounted volumes this Mac reports: \(names.joined(separator: ", ")). If your drive is not among them, macOS has not mounted it."
}

struct ContentView: View {
    @StateObject private var state = AppState()
    @State private var showImporter = false
    @State private var showEnableWrite = false
    @State private var allowOverwrite = false
    @State private var dropHighlighted = false

    var body: some View {
        NavigationSplitView {
            // Sidebar: connected external drives.
            List(selection: $state.selectedID) {
                Section("External drives") {
                    if state.drives.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("No external drives found.").bold()
                            Text(allVolumesDiagnostic)
                                .font(.caption).foregroundStyle(.secondary)
                            Text("Checklist: drive powered and cabled (try another port/cable) · visible in Disk Utility? · if visible there but greyed out, select it here after Refresh and press Mount · clean dirty NTFS on Windows (chkdsk, full shutdown).")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .tag("empty-diagnostics")
                    }
                    ForEach(state.drives) { drive in
                        Label {
                            VStack(alignment: .leading) {
                                Text(drive.volumeName).font(.headline)
                                Text("\(drive.filesystem) • \(Formatters.bytes(drive.freeBytes)) free")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: drive.isNTFS ? "externaldrive.fill" : "externaldrive")
                        }
                        .tag(drive.id)
                        .badge(drive.isNTFS ? (drive.showsWritable ? "RW" : "RO") : nil)
                    }
                }
            }
            .navigationTitle("NTFS Bridge")
            .toolbar {
                Button { state.refresh() } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }.disabled(state.isRefreshing)
            }
        } detail: {
            if let drive = state.selected {
                DriveDetailView(
                    drive: drive,
                    backend: state.backend,
                    health: state.healthByDevice[drive.id],
                    state: state,
                    showEnableWrite: $showEnableWrite,
                    showImporter: $showImporter,
                    allowOverwrite: $allowOverwrite,
                    dropHighlighted: $dropHighlighted
                )
            } else {
                Text("Connect an external drive to begin.").foregroundStyle(.secondary)
            }
        }
        .task {
            // First discovery runs after first render, never during init:
            // blocking disk calls inside SwiftUI's launch update abort the app.
            state.refresh()
        }
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true
        ) { result in
            if let urls = try? result.get() {
                state.startCopy(sources: urls, allowOverwrite: allowOverwrite)
            }
        }
        .sheet(isPresented: $showEnableWrite) {
            if let drive = state.selected {
                EnableWriteSheet(drive: drive, backend: state.backend, state: state)
            }
        }
        .alert("Something needs attention", isPresented: Binding(
            get: { state.lastError != nil },
            set: { if !$0 { state.lastError = nil } }
        )) {
            Button("OK") { state.lastError = nil }
        } message: {
            Text(state.lastError ?? "")
        }
    }
}

struct DriveDetailView: View {
    let drive: Drive
    let backend: BackendStatus
    let health: FilesystemHealth?
    @ObservedObject var state: AppState
    @Binding var showEnableWrite: Bool
    @Binding var showImporter: Bool
    @Binding var allowOverwrite: Bool
    @Binding var dropHighlighted: Bool
    @State private var newFolderName = ""
    @State private var showRenameImporter = false
    @State private var renameTarget: URL?
    @State private var renameName = ""
    @State private var showRenameSheet = false
    @State private var showDeleteImporter = false
    @State private var deleteTargets: [URL] = []

    private var canManage: Bool {
        drive.mountPoint != nil && (drive.showsWritable || !drive.isNTFS)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Drive header.
                HStack {
                    Image(systemName: "externaldrive.fill").font(.largeTitle)
                    VStack(alignment: .leading) {
                        Text(drive.volumeName).font(.title2).bold()
                        Text("\(drive.filesystem) • \(drive.id)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    ReadWriteBadge(drive: drive)
                }

                // Capacity.
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("\(Formatters.bytes(drive.usedBytes)) of \(Formatters.bytes(drive.totalBytes)) used")
                            .font(.caption)
                        Spacer()
                        Text("\(Formatters.bytes(drive.freeBytes)) free").font(.caption)
                    }
                    ProgressView(value: drive.capacityFraction)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("NTFS driver status: \(backend.detail)")
                        .font(.caption).foregroundStyle(.secondary)
                    if !backend.canEnableWrite, !backend.nextStep.isEmpty {
                        Label(backend.nextStep, systemImage: "arrow.turn.up.right")
                            .font(.callout).foregroundStyle(.orange)
                    }
                    ForEach(backend.checks.indices, id: \.self) { i in
                        let check = backend.checks[i]
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: check.found ? "checkmark.circle.fill" : "xmark.circle")
                                .foregroundStyle(check.found ? .green : .secondary)
                                .font(.caption)
                            VStack(alignment: .leading, spacing: 0) {
                                Text(check.label).font(.caption)
                                Text(check.hint).font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                if let health {
                    Text(health.volumeHealthy ? "Health: OK (\(health.checks.joined(separator: ", ")))"
                         : "Health: ATTENTION — \(health.warnings.joined(separator: " ") )")
                        .font(.caption)
                        .foregroundStyle(health.volumeHealthy ? .green : .red)
                }

                // Actions.
                HStack {
                    if drive.mountPoint == nil {
                        Button("Mount") { state.mount(drive) }
                            .buttonStyle(.borderedProminent)
                        Text("Connected but not mounted — mounting never formats or erases.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Button("Check health") { state.checkHealth(drive) }
                        if drive.isNTFS && !drive.showsWritable {
                            Button("Enable NTFS write…") { showEnableWrite = true }
                                .buttonStyle(.borderedProminent)
                        }
                        Button("Eject safely") { state.eject(drive) }
                    }
                    Spacer()
                }

                Divider()

                // Transfer controls.
                VStack(alignment: .leading, spacing: 8) {
                    Text("Copy to this drive").font(.headline)
                    if drive.mountPoint == nil {
                        Text("Mount the drive first — copying is unavailable until it has a mount point.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    Text("Drag folders onto the drop zone, or choose files. Sources are never deleted. Existing files are never overwritten unless you tick the box.")
                        .font(.caption).foregroundStyle(.secondary)
                    Toggle("Allow overwriting existing files (asks nothing further)", isOn: $allowOverwrite)
                        .font(.caption)
                    HStack {
                        Button("Choose files…") { showImporter = true }
                        Button("Paste from clipboard") { pasteBoard() }
                    }
                    .disabled(drive.mountPoint == nil)
                    DropZone(highlighted: $dropHighlighted) { urls in
                        state.startCopy(sources: urls, allowOverwrite: allowOverwrite)
                    }
                    .opacity(drive.mountPoint == nil ? 0.4 : 1)
                    .allowsHitTesting(drive.mountPoint != nil)
                }

                Divider()

                // File management (needs a writable mount).
                VStack(alignment: .leading, spacing: 8) {
                    Text("Manage files on this drive").font(.headline)
                    if !canManage {
                        Text("Enable write access first — file management is unavailable on read-only volumes.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    HStack {
                        TextField("New folder name", text: $newFolderName)
                            .textFieldStyle(.roundedBorder).frame(maxWidth: 220)
                        Button("Create folder") {
                            state.createFolder(name: newFolderName)
                            newFolderName = ""
                        }.disabled(!canManage || newFolderName.isEmpty)
                    }
                    HStack {
                        Button("Rename a file or folder…") { showRenameImporter = true }
                        Button("Delete files…") { showDeleteImporter = true }
                    }.disabled(!canManage)
                    if !deleteTargets.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Permanently delete \(deleteTargets.count) item(s)? There is no undo.")
                                .font(.callout).foregroundStyle(.red)
                            ForEach(deleteTargets, id: \.self) { url in
                                Text("• \(url.lastPathComponent)").font(.caption).foregroundStyle(.secondary)
                            }
                            HStack {
                                Button("Delete permanently") {
                                    state.deleteItems(deleteTargets, confirmed: true)
                                    deleteTargets = []
                                }.buttonStyle(.borderedProminent).tint(.red)
                                Button("Cancel") { deleteTargets = [] }
                            }
                        }
                        .padding(8)
                        .background(.red.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }
                .fileImporter(isPresented: $showRenameImporter, allowedContentTypes: [.item], allowsMultipleSelection: false) { result in
                    if let url = try? result.get().first {
                        renameTarget = url
                        renameName = url.lastPathComponent
                        showRenameSheet = true
                    }
                }
                .fileImporter(isPresented: $showDeleteImporter, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
                    if let urls = try? result.get(), !urls.isEmpty {
                        deleteTargets = urls
                    }
                }
                .sheet(isPresented: $showRenameSheet) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Rename “\(renameTarget?.lastPathComponent ?? "")”").font(.title3).bold()
                        TextField("New name", text: $renameName)
                            .textFieldStyle(.roundedBorder)
                        Text("Renaming never overwrites: an existing name stops the rename.")
                            .font(.caption).foregroundStyle(.secondary)
                        HStack {
                            Button("Cancel") { showRenameSheet = false }.keyboardShortcut(.cancelAction)
                            Spacer()
                            Button("Rename") {
                                if let target = renameTarget {
                                    state.renameItem(at: target, to: renameName)
                                }
                                showRenameSheet = false
                            }.buttonStyle(.borderedProminent)
                                .disabled(renameName.isEmpty || renameTarget == nil)
                        }
                    }
                    .padding()
                    .frame(width: 400)
                }

                Divider()

                // Transfers.
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Transfers").font(.headline)
                        Spacer()
                        if state.transfers.contains(where: { $0.status == .running }) {
                            Button("Cancel") { state.cancelCopy() }
                        }
                    }
                    if state.transfers.isEmpty {
                        Text("No transfers yet.").font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(state.transfers) { job in
                        TransferRow(job: job, onRetry: { state.retry(job: job, allowOverwrite: allowOverwrite) })
                    }
                }

                Divider()

                // Log.
                VStack(alignment: .leading, spacing: 8) {
                    Text("Activity log").font(.headline)
                    ForEach(Array(state.logLines.suffix(30).reversed()), id: \.date) { entry in
                        HStack(alignment: .top, spacing: 8) {
                            Text(Formatters.date(entry.date)).font(.caption2).foregroundStyle(.secondary)
                            Text(entry.message).font(.caption)
                        }
                    }
                }
            }
            .padding()
        }
        .navigationTitle(drive.volumeName)
    }

    private func pasteBoard() {
        let pb = NSPasteboard.general
        let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard !urls.isEmpty else {
            state.lastError = "Clipboard has no files to paste."
            return
        }
        state.startCopy(sources: urls, allowOverwrite: allowOverwrite)
    }
}

struct ReadWriteBadge: View {
    let drive: Drive
    var body: some View {
        if drive.mountPoint == nil {
            Label("Not mounted", systemImage: "cable.connector.slash")
                .font(.caption).foregroundStyle(.secondary)
                .padding(6).background(.quaternary).clipShape(RoundedRectangle(cornerRadius: 8))
        } else if !drive.isNTFS {
            Text(drive.filesystem).font(.caption).padding(6)
                .background(.quaternary).clipShape(RoundedRectangle(cornerRadius: 8))
        } else if drive.showsWritable {
            Label("Read & write", systemImage: "checkmark.seal.fill")
                .font(.caption).foregroundStyle(.green)
                .padding(6).background(.green.opacity(0.12)).clipShape(RoundedRectangle(cornerRadius: 8))
        } else {
            Label("Read-only", systemImage: "lock.fill")
                .font(.caption).foregroundStyle(.orange)
                .padding(6).background(.orange.opacity(0.12)).clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }
}

/// Lock-guarded box so concurrent drop callbacks stay data-race free.
final class URLBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [URL] = []
    func append(_ url: URL) { lock.lock(); storage.append(url); lock.unlock() }
    var urls: [URL] { lock.lock(); defer { lock.unlock() }; return storage }
}

struct DropZone: View {
    @Binding var highlighted: Bool
    var onDrop: ([URL]) -> Void

    var body: some View {
        RoundedRectangle(cornerRadius: 12)
            .strokeBorder(highlighted ? Color.accentColor : Color.secondary, style: StrokeStyle(lineWidth: 2, dash: [8]))
            .frame(height: 110)
            .overlay {
                VStack {
                    Image(systemName: "tray.and.arrow.down.fill").font(.title)
                    Text("Drop folders here to copy").font(.callout)
                }.foregroundStyle(highlighted ? .primary : .secondary)
            }
            .background(highlighted ? Color.accentColor.opacity(0.08) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .onDrop(of: [.fileURL], isTargeted: $highlighted) { providers in
                let box = URLBox()
                let group = DispatchGroup()
                for provider in providers {
                    group.enter()
                    _ = provider.loadObject(ofClass: URL.self) { url, _ in
                        if let url { box.append(url) }
                        group.leave()
                    }
                }
                group.wait()
                let urls = box.urls
                if !urls.isEmpty { onDrop(urls) }
                return !urls.isEmpty
            }
    }
}

struct TransferRow: View {
    let job: TransferJob
    var onRetry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(job.sources.map(\.lastPathComponent).joined(separator: ", "))
                    .font(.callout).lineLimit(1)
                Spacer()
                switch job.status {
                case .running: Text("Copying…").font(.caption).foregroundStyle(.secondary)
                case .done: Label("Done", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.green)
                case .failed: Label("Failed", systemImage: "xmark.circle.fill").font(.caption).foregroundStyle(.red)
                case .cancelled: Label("Cancelled", systemImage: "minus.circle.fill").font(.caption).foregroundStyle(.secondary)
                }
            }
            if let prog = job.progress {
                ProgressView(value: prog.fraction)
                HStack {
                    Text("\(Formatters.bytes(prog.completedBytes)) / \(Formatters.bytes(prog.totalBytes))")
                    Spacer()
                    Text(Formatters.speed(prog.bytesPerSecond))
                    Text("• \(Formatters.eta(prog.etaSeconds))")
                }.font(.caption2).foregroundStyle(.secondary)
                Text(prog.currentPath).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            if let report = job.report, job.status == .done {
                Text("\(report.filesCopied) file(s) • \(report.verified ? "checksum-verified" : "unverified") • \(String(format: "%.1f", report.durationSeconds))s")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            if let error = job.error {
                Text(error).font(.caption).foregroundStyle(.red)
                Button("Retry") { onRetry() }.font(.caption)
            }
        }
        .padding(8)
        .background(.quaternary.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

struct EnableWriteSheet: View {
    let drive: Drive
    let backend: BackendStatus
    @ObservedObject var state: AppState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Enable NTFS write").font(.title2).bold()
            Text("For “\(drive.volumeName)” (\(drive.id)). NTFS Bridge will check filesystem health first and never format or erase the drive.")
                .font(.callout)
            Text("Detected backend: \(backend.detail)").font(.callout).foregroundStyle(.secondary)
            switch backend.backend {
            case .none:
                Text("No write engine is available, so this volume stays read-only. Update NTFS Bridge — the write engine ships inside the app. Advanced options (system drivers such as NTFS4Mac/NTFSTool on macOS 26+, or a commercial driver) are still detected automatically.\n\nFull steps are in INSTALL.md.")
                    .font(.callout)
            case .ntfs3gFuse:
                Text("This will unmount the volume and remount it with NTFS-3G. macOS will ask for an administrator password. Nothing is formatted or erased.")
                    .font(.callout)
            case .fskit, .commercial:
                Text("Your installed driver handles mounting. Open the vendor app to mount read/write, approve its System Settings extension if asked, then press Refresh in NTFS Bridge.")
                    .font(.callout)
            }
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(backend.backend == .ntfs3gFuse ? "Check health & remount" : "Check health") {
                    state.enableWrite(drive)
                    dismiss()
                }.buttonStyle(.borderedProminent)
            }
        }
        .padding()
        .frame(width: 480)
    }
}
