import Foundation
import os

public enum LogLevel: String {
    case debug, info, warn, error
}

public struct LogEvent: Identifiable {
    public let id: Int
    public let time: Date
    public let level: LogLevel
    public let type: String
    public let message: String
}

/// Append-only JSON Lines log with size-based rotation.
/// Files live in Documents/NetWatchLogs so they can be pulled with Finder / Apple Configurator.
/// Every event is also mirrored to the unified log (subsystem "NetWatch") so it shows up in sysdiagnose.
public final class EventLog {
    public static let shared = EventLog()

    public let directory: URL
    /// Called on the main queue for every event (drives the live UI).
    public var onEvent: ((LogEvent) -> Void)?

    private let queue = DispatchQueue(label: "netwatch.eventlog")
    private let osLog = Logger(subsystem: "NetWatch", category: "events")
    private let session = String(UUID().uuidString.prefix(8))
    private var deviceLabel = ""
    private var maxFileBytes = 2_000_000
    private var maxFiles = 30
    private var handle: FileHandle?
    private var currentURL: URL?
    private var currentSize = 0
    private var seq = 0
    private var fileCounter = 0

    static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private let fileStampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f
    }()

    private init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        directory = docs.appendingPathComponent("NetWatchLogs", isDirectory: true)
        // No file protection: keep logging even while the device is locked.
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.none])
    }

    func configure(deviceLabel: String, maxFileBytes: Int, maxFiles: Int) {
        queue.sync {
            self.deviceLabel = deviceLabel
            self.maxFileBytes = maxFileBytes
            self.maxFiles = maxFiles
        }
    }

    public func log(_ type: String, _ message: String, level: LogLevel = .info, data: [String: Any] = [:]) {
        let now = Date()
        queue.async {
            self.seq += 1
            var obj: [String: Any] = [
                "ts": Self.isoFormatter.string(from: now),
                "seq": self.seq,
                "session": self.session,
                "device": self.deviceLabel,
                "level": level.rawValue,
                "type": type,
                "msg": message,
            ]
            if !data.isEmpty { obj["data"] = Self.sanitize(data) }
            if JSONSerialization.isValidJSONObject(obj),
               var line = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]) {
                line.append(0x0A)
                self.write(line)
            }

            switch level {
            case .debug: self.osLog.debug("\(type, privacy: .public): \(message, privacy: .public)")
            case .info: self.osLog.info("\(type, privacy: .public): \(message, privacy: .public)")
            case .warn: self.osLog.notice("\(type, privacy: .public): \(message, privacy: .public)")
            case .error: self.osLog.error("\(type, privacy: .public): \(message, privacy: .public)")
            }

            let event = LogEvent(id: self.seq, time: now, level: level, type: type, message: message)
            DispatchQueue.main.async { self.onEvent?(event) }
        }
    }

    /// Log files, oldest first.
    public func logFiles() -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return urls.filter { $0.pathExtension == "jsonl" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Blocks until queued events are on disk.
    public func flush() {
        queue.sync { try? handle?.synchronize() }
    }

    // MARK: - File handling (queue only)

    private func write(_ line: Data) {
        if handle == nil || currentSize + line.count > maxFileBytes { rotate() }
        guard let handle else { return }
        do {
            try handle.write(contentsOf: line)
            currentSize += line.count
        } catch {
            try? handle.close()
            self.handle = nil
        }
    }

    private func rotate() {
        try? handle?.close()
        handle = nil
        fileCounter += 1
        let name = String(format: "netwatch-%@-%@-%04ld.jsonl", fileStampFormatter.string(from: Date()), session, fileCounter)
        let url = directory.appendingPathComponent(name)
        FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.protectionKey: FileProtectionType.none])
        handle = try? FileHandle(forWritingTo: url)
        currentURL = url
        currentSize = 0
        prune()
    }

    private func prune() {
        let files = logFiles()
        guard files.count > maxFiles else { return }
        for url in files.prefix(files.count - maxFiles) where url != currentURL {
            try? FileManager.default.removeItem(at: url)
        }
    }

    static func sanitize(_ value: Any) -> Any {
        switch value {
        case let d as [String: Any]: return d.mapValues { sanitize($0) }
        case let a as [Any]: return a.map { sanitize($0) }
        case let s as String: return s
        case let b as Bool: return b
        case let i as Int: return i
        case let d as Double: return d.isFinite ? d : String(d)
        case let n as NSNumber: return n
        case is NSNull: return NSNull()
        case let date as Date: return isoFormatter.string(from: date)
        case let url as URL: return url.absoluteString
        default: return String(describing: value)
        }
    }
}
