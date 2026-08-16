import Foundation

enum Glob {
    /// The portion of a pattern before the first wildcard — the deepest path
    /// that is guaranteed to exist if the pattern can match anything at all.
    static func stablePrefix(of pattern: String) -> String {
        guard let wildcard = pattern.firstIndex(where: { $0 == "*" || $0 == "?" || $0 == "[" })
        else { return pattern }

        let head = String(pattern[pattern.startIndex..<wildcard])

        // `/a/b/*/c` — the wildcard opens a new component, so /a/b is already the
        // containing directory. Dropping a component here would climb one level
        // too far and, for a watcher, pull in a whole unrelated subtree.
        if head.hasSuffix("/") {
            var trimmed = head
            trimmed.removeLast()
            return trimmed
        }
        // `/a/b/foo*bar` — the wildcard is inside a component, so drop it.
        return (head as NSString).deletingLastPathComponent
    }

    /// Distinguishes "this path genuinely has no children" from "this process is
    /// not allowed to look". TCC denials surface as EPERM/EACCES from `opendir`
    /// while every higher-level API just returns an empty result, which would
    /// otherwise make a permission problem look like a clean sweep.
    static func probe(_ path: String) -> String {
        guard let handle = opendir(path) else {
            let code = errno
            let reason = String(cString: strerror(code))
            switch code {
            case EPERM, EACCES:
                return "nicht lesbar (\(reason)) — vermutlich fehlt Full Disk Access"
            case ENOENT:
                return "existiert nicht"
            default:
                return "nicht lesbar (\(reason))"
            }
        }
        defer { closedir(handle) }

        var count = 0
        while readdir(handle) != nil { count += 1 }
        return "lesbar, \(count) Einträge"
    }

    /// Expands a shell glob to existing paths. `GLOB_NOSORT` is off so results
    /// are stable across runs, which keeps the logs diffable.
    static func expand(_ pattern: String) -> [String] {
        guard pattern.contains("*") || pattern.contains("?") || pattern.contains("[") else {
            return FileManager.default.fileExists(atPath: pattern) ? [pattern] : []
        }

        var globResult = glob_t()
        defer { globfree(&globResult) }

        let flags = GLOB_TILDE | GLOB_MARK
        guard glob(pattern, flags, nil, &globResult) == 0 else { return [] }

        var paths: [String] = []
        for index in 0..<Int(globResult.gl_pathc) {
            guard let raw = globResult.gl_pathv[index] else { continue }
            var path = String(cString: raw)
            // GLOB_MARK appends "/" to directories; strip it for consistency.
            if path.count > 1 && path.hasSuffix("/") { path.removeLast() }
            paths.append(path)
        }
        return paths
    }
}
