import Foundation

/// In-memory, copyable Equil-only debug log (priming, BLE, resistance, connect).
public final class EquilLogBuffer {
    public static let shared = EquilLogBuffer()

    public enum Level: String {
        case debug = "DEBUG"
        case info = "INFO"
        case warning = "WARNING"
        case error = "ERROR"
    }

    private let lock = NSLock()
    private var lines: [String] = []
    private let maxLines = 800

    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZ"
        return formatter
    }()

    private init() {}

    public func append(_ message: String, category: String = "Equil", level: Level = .info) {
        let sanitized = Self.sanitize(message)
        guard !sanitized.isEmpty else { return }

        let timestamp = dateFormatter.string(from: Date())
        let entry = "[\(timestamp) \(level.rawValue) \(category)] \(sanitized)"

        lock.lock()
        lines.append(entry)
        if lines.count > maxLines {
            lines.removeFirst(lines.count - maxLines)
        }
        lock.unlock()
    }

    public func exportText() -> String {
        lock.lock()
        defer { lock.unlock() }
        if lines.isEmpty {
            return "Equil napló üres."
        }
        return lines.joined(separator: "\n")
    }

    public func previewText(lineCount: Int = 20) -> String {
        lock.lock()
        defer { lock.unlock() }
        if lines.isEmpty {
            return "Nincs naplóbejegyzés."
        }
        return lines.suffix(max(1, lineCount)).joined(separator: "\n")
    }

    public func clear() {
        lock.lock()
        lines.removeAll(keepingCapacity: true)
        lock.unlock()
    }

    /// Redacts credentials and other sensitive values from user-visible logs.
    private static func sanitize(_ message: String) -> String {
        var result = message

        let redactedPatterns = [
            #"(?i)(password\s*[:=]\s*)\S+"#,
            #"(?i)(equilPassword\s*[:=]\s*)\S+"#,
            #"(?i)(sharedSecret\s*[:=]\s*)\S+"#,
            #"(?i)(sessionToken\s*[:=]\s*)\S+"#,
            #"(?i)(devicePassword\s*[:=]\s*)\S+"#,
            #"(?i)(pairPwd\s*[:=]\s*)\S+"#,
        ]

        for pattern in redactedPatterns {
            result = result.replacingOccurrences(
                of: pattern,
                with: "$1[REDACTED]",
                options: .regularExpression
            )
        }

        return result
    }
}
