import CryptoKit
import Foundation

/// SHA256 helpers used to verify copied files.
public enum Checksum {
    /// SHA256 hex digest of a file, streamed in 1 MiB chunks.
    public static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = try handle.read(upToCount: 1_048_576)
            guard let chunk, !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// SHA256 hex digest of in-memory data (convenience for tests).
    public static func sha256(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func verify(source: URL, destination: URL) throws -> Bool {
        try sha256(of: source) == sha256(of: destination)
    }
}
