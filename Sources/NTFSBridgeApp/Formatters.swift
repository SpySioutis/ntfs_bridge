import Foundation

public enum Formatters {
    private static func makeBytes() -> ByteCountFormatter {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f
    }

    public static func bytes(_ n: Int64) -> String { makeBytes().string(fromByteCount: n) }

    public static func speed(_ bytesPerSecond: Double) -> String {
        makeBytes().string(fromByteCount: Int64(bytesPerSecond)) + "/s"
    }

    public static func eta(_ seconds: Double?) -> String {
        guard let seconds, seconds.isFinite, seconds >= 0 else { return "—" }
        let total = Int(seconds.rounded())
        if total < 60 { return "\(total)s left" }
        return "\(total / 60)m \(total % 60)s left"
    }

    public static func date(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .medium
        return f.string(from: date)
    }
}
