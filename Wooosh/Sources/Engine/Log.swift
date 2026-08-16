import Foundation
import os

/// Append-only log with size-based rotation. Also mirrors to the unified log so
/// `log stream --predicate 'subsystem == "com.juliuspaetzke.wooosh"'` works.
final class Log {
    static let shared = Log()

    enum Level: String {
        case debug = "DEBUG"
        case info = "INFO"
        case warn = "WARN"
        case error = "ERROR"
    }

    private let osLog = OSLog(subsystem: "com.juliuspaetzke.wooosh", category: "sweep")
    private let queue = DispatchQueue(label: "com.juliuspaetzke.wooosh.log")
    private let stamp: DateFormatter
    private let maxBytes = 4 * 1024 * 1024
    private let keepRotations = 3

    /// Mirrors every line to stdout. The LaunchAgent redirects stdout to a file
    /// as well, so this stays quiet in daemon mode to avoid double-writing.
    var echoToStdout = false
    var verbose = false

    let fileURL: URL

    private init() {
        let dir = Paths.home
            .appendingPathComponent("Library/Logs/Wooosh", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("wooosh.log")

        stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd HH:mm:ss"
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.timeZone = .current
    }

    func debug(_ message: String) { write(.debug, message) }
    func info(_ message: String) { write(.info, message) }
    func warn(_ message: String) { write(.warn, message) }
    func error(_ message: String) { write(.error, message) }

    private func write(_ level: Level, _ message: String) {
        if level == .debug && !verbose { return }

        let line = "\(stamp.string(from: Date())) [\(level.rawValue)] \(message)\n"

        switch level {
        case .debug: os_log("%{public}@", log: osLog, type: .debug, message)
        case .info: os_log("%{public}@", log: osLog, type: .info, message)
        case .warn: os_log("%{public}@", log: osLog, type: .default, message)
        case .error: os_log("%{public}@", log: osLog, type: .error, message)
        }

        if echoToStdout {
            FileHandle.standardOutput.write(Data(line.utf8))
        }

        queue.async { [self] in
            rotateIfNeeded()
            guard let data = line.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: fileURL) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: fileURL)
            }
        }
    }

    /// Must be called on `queue`.
    private func rotateIfNeeded() {
        let fm = FileManager.default
        guard let size = try? fm.attributesOfItem(atPath: fileURL.path)[.size] as? Int,
              size > maxBytes else { return }

        // wooosh.log -> .1 -> .2 -> .3 -> dropped
        let oldest = fileURL.appendingPathExtension("\(keepRotations)")
        try? fm.removeItem(at: oldest)
        for index in stride(from: keepRotations - 1, through: 1, by: -1) {
            let from = fileURL.appendingPathExtension("\(index)")
            let to = fileURL.appendingPathExtension("\(index + 1)")
            if fm.fileExists(atPath: from.path) {
                try? fm.moveItem(at: from, to: to)
            }
        }
        try? fm.moveItem(at: fileURL, to: fileURL.appendingPathExtension("1"))
    }
}
