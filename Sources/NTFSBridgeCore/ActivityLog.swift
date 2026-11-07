import Foundation

/// Entry in the persistent activity log.
public struct ActivityLogEntry: Codable, Equatable, Sendable {
    public var date: Date
    public var message: String

    public init(date: Date = Date(), message: String) {
        self.date = date
        self.message = message
    }
}

/// Thread-safe, file-backed activity log.
///
/// The store keeps entries in memory and appends them to a JSONL file
/// under Application Support so unexpected interruptions stay diagnosable.
public final class ActivityLogStore: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [ActivityLogEntry] = []
    private let fileURL: URL?

    public init(persistTo fileURL: URL? = nil) {
        self.fileURL = fileURL
        if let fileURL {
            try? FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if let data = try? Data(contentsOf: fileURL),
               !data.isEmpty
            {
                let lines = data.split(separator: UInt8(ascii: "\n"))
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                for line in lines {
                    if let entry = try? decoder.decode(ActivityLogEntry.self, from: Data(line)) {
                        entries.append(entry)
                    }
                }
            }
        }
    }

    public func append(_ message: String) {
        append(ActivityLogEntry(message: message))
    }

    public func append(_ entry: ActivityLogEntry) {
        lock.lock()
        entries.append(entry)
        let line: Data? = {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = .withoutEscapingSlashes
            guard let payload = try? encoder.encode(entry) else { return nil }
            return payload + Data([UInt8(ascii: "\n")])
        }()
        lock.unlock()
        if let line, let fileURL {
            if FileManager.default.fileExists(atPath: fileURL.path) {
                if let handle = try? FileHandle(forWritingTo: fileURL) {
                    try? handle.seekToEnd()
                    try? handle.write(contentsOf: line)
                    try? handle.close()
                }
            } else {
                try? line.write(to: fileURL)
            }
        }
    }

    public var allEntries: [ActivityLogEntry] {
        lock.lock()
        defer { lock.unlock() }
        return entries
    }

    public static func defaultFileURL() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NTFSBridge/activity.log.jsonl")
    }
}
