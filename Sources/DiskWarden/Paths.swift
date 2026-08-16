import Foundation

enum Paths {
    /// `FileManager.homeDirectoryForCurrentUser` returns the sandbox container
    /// when sandboxed; DiskWarden never is, but read the passwd entry anyway so
    /// the value is identical whether launched by launchd or a shell.
    static let home: URL = {
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: dir), isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }()

    static var supportDirectory: URL {
        home.appendingPathComponent("Library/Application Support/DiskWarden", isDirectory: true)
    }

    static var configURL: URL {
        supportDirectory.appendingPathComponent("config.json")
    }

    static var stateURL: URL {
        supportDirectory.appendingPathComponent("state.json")
    }

    /// Expands a leading `~` against the real home directory.
    static func expand(_ path: String) -> String {
        guard path == "~" || path.hasPrefix("~/") else { return path }
        return home.path + String(path.dropFirst(1))
    }
}

enum Format {
    static func bytes(_ value: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
        return formatter.string(fromByteCount: value)
    }

    static func duration(_ seconds: TimeInterval) -> String {
        if seconds < 1 { return String(format: "%.0f ms", seconds * 1000) }
        if seconds < 60 { return String(format: "%.1f s", seconds) }
        return String(format: "%.1f min", seconds / 60)
    }

    static func hours(_ seconds: TimeInterval) -> String {
        let hours = seconds / 3600
        if hours < 1 { return String(format: "%.0f min", seconds / 60) }
        if hours < 48 { return String(format: "%.0f h", hours) }
        return String(format: "%.0f d", hours / 24)
    }
}
