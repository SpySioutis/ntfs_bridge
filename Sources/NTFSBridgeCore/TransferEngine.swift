import Foundation

public struct TransferReport: Equatable, Sendable {
    public var filesCopied: Int
    public var bytesCopied: Int64
    public var verified: Bool
    public var durationSeconds: Double

    public init(filesCopied: Int, bytesCopied: Int64, verified: Bool, durationSeconds: Double) {
        self.filesCopied = filesCopied
        self.bytesCopied = bytesCopied
        self.verified = verified
        self.durationSeconds = durationSeconds
    }
}

public struct TransferProgress: Equatable, Sendable {
    public var completedBytes: Int64
    public var totalBytes: Int64
    public var completedFiles: Int
    public var totalFiles: Int
    public var currentPath: String
    public var bytesPerSecond: Double
    public var etaSeconds: Double?

    public var fraction: Double {
        guard totalBytes > 0 else { return 0 }
        return min(1, Double(completedBytes) / Double(totalBytes))
    }
}

public enum TransferError: Error, Equatable {
    case cancelled
    case destinationExistsWithoutConsent(String)
    case verificationFailed(String)
    case ioFailed(String)
}

/// Copies files/folders into an NTFS (or any) destination with progress,
/// cancellation, retry, temp-file atomicity and optional checksum verification.
///
/// Guarantees:
/// - Source files are never deleted or modified.
/// - Existing destination files are never overwritten unless
///   `allowOverwrite == true` (the UI must obtain explicit consent first).
/// - Each file is streamed to `<name>.ntfsbridge-partial-<uuid>` in the same
///   directory, then atomically moved to its final name, so interrupted
///   transfers never leave a half-written file at the final path.
public final class TransferEngine: @unchecked Sendable {
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public func copy(
        sources: [URL],
        to destinationDir: URL,
        allowOverwrite: Bool = false,
        verifyChecksum: Bool = true,
        maxRetries: Int = 2,
        progress: @escaping @Sendable (TransferProgress) -> Void = { _ in }
    ) async throws -> TransferReport {
        // Validate everything before writing a single byte.
        for source in sources {
            let target = destinationDir.appendingPathComponent(source.lastPathComponent)
            try SafetyGuard.validateCopy(source: source, destination: target, allowOverwrite: allowOverwrite)
        }
        try fileManager.createDirectory(at: destinationDir, withIntermediateDirectories: true)

        // Build the file plan (recursive for directories).
        var files: [(source: URL, relative: String, size: Int64, isDirectory: Bool, isSymlink: Bool)] = []
        for source in sources {
            try appendPlan(for: source, base: source.deletingLastPathComponent(), into: &files)
        }
        let totalBytes = files.filter { !$0.isDirectory && !$0.isSymlink }.map(\.size).reduce(0, +)
        let totalFiles = files.filter { !$0.isDirectory && !$0.isSymlink }.count

        let started = Date()
        var completedBytes: Int64 = 0
        var completedFiles = 0

        func emit(current: String) {
            let elapsed = max(Date().timeIntervalSince(started), 0.001)
            let rate = Double(completedBytes) / elapsed
            let remaining = totalBytes - completedBytes
            let eta: Double? = rate > 1 ? Double(remaining) / rate : nil
            progress(TransferProgress(
                completedBytes: completedBytes,
                totalBytes: totalBytes,
                completedFiles: completedFiles,
                totalFiles: totalFiles,
                currentPath: current,
                bytesPerSecond: rate,
                etaSeconds: eta
            ))
        }

        for item in files {
            try Task.checkCancellation()
            let dest = destinationDir.appendingPathComponent(item.relative)
            if item.isDirectory {
                try fileManager.createDirectory(at: dest, withIntermediateDirectories: true)
                continue
            }
            if item.isSymlink {
                let linkTarget = try fileManager.destinationOfSymbolicLink(atPath: item.source.path)
                if fileManager.fileExists(atPath: dest.path) {
                    if !allowOverwrite { throw TransferError.destinationExistsWithoutConsent(dest.path) }
                    try fileManager.removeItem(at: dest)
                }
                try fileManager.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fileManager.createSymbolicLink(atPath: dest.path, withDestinationPath: linkTarget)
                continue
            }
            if fileManager.fileExists(atPath: dest.path), !allowOverwrite {
                throw TransferError.destinationExistsWithoutConsent(dest.path)
            }
            var lastError: Error?
            var ok = false
            for attempt in 0...maxRetries {
                try Task.checkCancellation()
                do {
                    try await copyFileChunked(from: item.source, to: dest, allowOverwrite: allowOverwrite) { chunk in
                        completedBytes += Int64(chunk)
                        emit(current: item.relative)
                    }
                    if verifyChecksum {
                        guard try Checksum.verify(source: item.source, destination: dest) else {
                            throw TransferError.verificationFailed(dest.path)
                        }
                    }
                    ok = true
                    break
                } catch is CancellationError {
                    try? fileManager.removeItem(at: dest)
                    cleanupPartials(in: dest.deletingLastPathComponent())
                    throw TransferError.cancelled
                } catch {
                    lastError = error
                    cleanupPartials(in: dest.deletingLastPathComponent())
                    if attempt == maxRetries { break }
                    try await Task.sleep(nanoseconds: 200_000_000)
                }
            }
            if !ok {
                cleanupPartials(in: dest.deletingLastPathComponent())
                throw lastError ?? TransferError.ioFailed(dest.path)
            }
            completedBytes = min(completedBytes, totalBytes)
            completedFiles += 1
            emit(current: item.relative)
        }
        emit(current: "")
        return TransferReport(
            filesCopied: totalFiles,
            bytesCopied: totalBytes,
            verified: verifyChecksum,
            durationSeconds: Date().timeIntervalSince(started)
        )
    }

    // MARK: - Internals

    private func appendPlan(
        for url: URL,
        base: URL,
        into files: inout [(source: URL, relative: String, size: Int64, isDirectory: Bool, isSymlink: Bool)]
    ) throws {
        let basePath = base.standardizedFileURL.path
        func relative(of u: URL) -> String {
            let p = u.standardizedFileURL.path
            if p.hasPrefix(basePath + "/") { return String(p.dropFirst(basePath.count + 1)) }
            return u.lastPathComponent
        }
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDir) else { return }
        if (try? fileManager.destinationOfSymbolicLink(atPath: url.path)) != nil {
            files.append((url, relative(of: url), 0, false, true))
            return
        }
        if isDir.boolValue {
            files.append((url, relative(of: url), 0, true, false))
            guard let enumerator = fileManager.enumerator(at: url, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .isSymbolicLinkKey]) else { return }
            for case let child as URL in enumerator {
                let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .isSymbolicLinkKey])
                if values?.isSymbolicLink == true {
                    files.append((child, relative(of: child), 0, false, true))
                } else if values?.isDirectory == true {
                    files.append((child, relative(of: child), 0, true, false))
                } else {
                    let size = Int64(values?.fileSize ?? 0)
                    files.append((child, relative(of: child), size, false, false))
                }
            }
        } else {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize.map(Int64.init) ?? 0
            files.append((url, relative(of: url), size, false, false))
        }
    }

    private func copyFileChunked(
        from source: URL,
        to destination: URL,
        allowOverwrite: Bool,
        onChunk: (Int) -> Void
    ) async throws {
        try Task.checkCancellation()
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temp = destination.deletingLastPathComponent()
            .appendingPathComponent(destination.lastPathComponent + ".ntfsbridge-partial-\(UUID().uuidString)")
        try? fileManager.removeItem(at: temp)
        fileManager.createFile(atPath: temp.path, contents: nil)
        let reader = try FileHandle(forReadingFrom: source)
        defer { try? reader.close() }
        let writer = try FileHandle(forWritingTo: temp)
        defer { try? writer.close() }
        while true {
            try Task.checkCancellation()
            let chunk = try reader.read(upToCount: 1_048_576) ?? Data()
            if chunk.isEmpty { break }
            try writer.write(contentsOf: chunk)
            onChunk(chunk.count)
        }
        try writer.close()
        try reader.close()
        if fileManager.fileExists(atPath: destination.path) {
            guard allowOverwrite else {
                try? fileManager.removeItem(at: temp)
                throw TransferError.destinationExistsWithoutConsent(destination.path)
            }
            try fileManager.removeItem(at: destination)
        }
        try fileManager.moveItem(at: temp, to: destination)
    }

    private func cleanupPartials(in directory: URL) {
        guard let items = try? fileManager.contentsOfDirectory(atPath: directory.path) else { return }
        for item in items where item.contains(".ntfsbridge-partial-") {
            try? fileManager.removeItem(at: directory.appendingPathComponent(item))
        }
    }
}
