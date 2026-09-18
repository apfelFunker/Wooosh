import Foundation

/// Every deletion passes through here. The gate fails *closed*: any check that
/// cannot be evaluated rejects the candidate rather than waving it through.
enum SafetyGate {

    enum Rejection: CustomStringConvertible {
        case notUnderAllowedRoot(String)
        case protectedPath
        case tooShallow(Int)
        case relativeComponent
        case escapesViaSymlink(String)
        case tooYoung(age: TimeInterval, required: TimeInterval)
        case openByProcess
        case separateVolume
        case unreadableMetadata(String)

        var description: String {
            switch self {
            case .notUnderAllowedRoot(let root):
                return "not below the allowed root \(root)"
            case .protectedPath:
                return "protected path"
            case .tooShallow(let depth):
                return "Pfadtiefe \(depth) unter Minimum"
            case .relativeComponent:
                return "contains a relative component"
            case .escapesViaSymlink(let resolved):
                return "symlink leaves the allowed area -> \(resolved)"
            case .tooYoung(let age, let required):
                return "zu jung (\(Format.hours(age)) < \(Format.hours(required)))"
            case .openByProcess:
                return "open in a process"
            case .separateVolume:
                return "liegt auf einem anderen Volume"
            case .unreadableMetadata(let reason):
                return "Metadaten unlesbar: \(reason)"
            }
        }
    }

    /// Paths that may never be deleted, and whose *ancestors* may never be
    /// deleted either. Compared after symlink resolution.
    private static let protected: Set<String> = {
        let home = Paths.home.path
        return Set([
            "/", "/System", "/Library", "/Applications", "/Users", "/usr", "/bin",
            "/sbin", "/etc", "/var", "/private", "/opt", "/Volumes",
            home,
            home + "/Library",
            home + "/Library/Caches",
            home + "/Library/Application Support",
            home + "/Library/Containers",
            home + "/Library/Group Containers",
            home + "/Library/Mobile Documents",
            home + "/Library/Preferences",
            home + "/Library/Keychains",
            home + "/Documents",
            home + "/Desktop",
            home + "/Downloads",
            home + "/Pictures",
            home + "/Movies",
            home + "/Music",
            home + "/Developer",
            "/Library/Caches",
            "/Library/Developer",
            "/Library/Developer/CoreSimulator",
        ].map { standardize($0) })
    }()

    /// Backstop against a glob collapsing to something near the root. The real
    /// guarantee is `allowedRoots` + `protected`; this only catches the absurd.
    /// `/Library/Caches/store/child` is depth 4.
    private static let minimumDepth = 4

    private static let allowedRoots: [String] = [
        standardize(Paths.home.path + "/Library/Caches"),
        standardize(Paths.home.path + "/Library/Application Support"),
        standardize("/Library/Caches"),
        standardize("/Library/Developer/CoreSimulator/Caches"),
    ]

    static func standardize(_ path: String) -> String {
        var result = (path as NSString).standardizingPath
        if result.count > 1 && result.hasSuffix("/") { result.removeLast() }
        // `standardizingPath` maps /private/var -> /var; normalise the other way
        // so comparisons against real resolved paths line up.
        if result == "/tmp" || result.hasPrefix("/tmp/") { result = "/private" + result }
        if result == "/var" || result.hasPrefix("/var/") { result = "/private" + result }
        return result
    }

    /// Validates the *container* a target's glob resolved to. Runs once per
    /// container, before any child is considered.
    static func validateContainer(_ path: String) -> Rejection? {
        let clean = standardize(path)

        if clean.contains("/../") || clean.hasSuffix("/..") {
            return .relativeComponent
        }
        if protected.contains(clean) {
            return .protectedPath
        }
        // Refuse anything that is an ancestor of a protected path — deleting its
        // children would take the protected path with it.
        for guarded in protected where guarded.hasPrefix(clean + "/") {
            return .notUnderAllowedRoot(guarded)
        }

        let resolved = standardize(URL(fileURLWithPath: clean).resolvingSymlinksInPath().path)
        if resolved != clean, !isUnderAllowedRoot(resolved) {
            return .escapesViaSymlink(resolved)
        }
        guard isUnderAllowedRoot(clean) else {
            return .notUnderAllowedRoot(allowedRoots.joined(separator: ", "))
        }
        return nil
    }

    /// Validates one direct child of an already-validated container.
    static func validateChild(
        _ url: URL,
        minimumAge: TimeInterval,
        now: Date,
        openPaths: OpenFileIndex,
        containerDeviceID: Int?
    ) -> Rejection? {
        let clean = standardize(url.path)

        if clean.contains("/../") || clean.hasSuffix("/..") { return .relativeComponent }
        if protected.contains(clean) { return .protectedPath }

        let depth = clean.split(separator: "/").count
        if depth < minimumDepth { return .tooShallow(depth) }

        guard isUnderAllowedRoot(clean) else {
            return .notUnderAllowedRoot(allowedRoots.joined(separator: ", "))
        }

        let attributes: [FileAttributeKey: Any]
        do {
            // Does not follow symlinks — a dangling or outbound link is described
            // by its own metadata, which is what we want.
            attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        } catch {
            return .unreadableMetadata(error.localizedDescription)
        }

        let isSymlink = (attributes[.type] as? FileAttributeType) == .typeSymbolicLink
        if !isSymlink {
            let resolved = standardize(url.resolvingSymlinksInPath().path)
            if !isUnderAllowedRoot(resolved) { return .escapesViaSymlink(resolved) }

            // A different device number means this child is a mount point.
            if let containerDeviceID,
               let deviceID = attributes[.systemNumber] as? Int,
               deviceID != containerDeviceID {
                return .separateVolume
            }
        }

        if let age = youngestAge(of: url, attributes: attributes, isSymlink: isSymlink, now: now) {
            if age < minimumAge { return .tooYoung(age: age, required: minimumAge) }
        } else {
            return .unreadableMetadata("no timestamps")
        }

        if openPaths.isOpen(prefix: url.path) { return .openByProcess }

        return nil
    }

    private static func isUnderAllowedRoot(_ path: String) -> Bool {
        allowedRoots.contains { path == $0 || path.hasPrefix($0 + "/") }
    }

    /// Age of the most recently touched thing at or under `url`.
    ///
    /// A directory's own mtime does not move when a grandchild changes, so the
    /// whole subtree is walked. The walk is bounded; exhausting the budget
    /// reports age 0, which rejects — an unmeasurably large tree is not
    /// something to delete on a timer.
    private static func youngestAge(
        of url: URL,
        attributes: [FileAttributeKey: Any],
        isSymlink: Bool,
        now: Date
    ) -> TimeInterval? {
        guard var youngest = newestDate(in: attributes) else { return nil }

        let isDirectory = (attributes[.type] as? FileAttributeType) == .typeDirectory
        if isDirectory && !isSymlink {
            guard let enumerator = FileManager.default.enumerator(
                at: url,
                includingPropertiesForKeys: [.contentModificationDateKey, .creationDateKey],
                options: [.skipsHiddenFiles]
            ) else { return nil }

            var budget = 20_000
            for case let child as URL in enumerator {
                if budget <= 0 { return 0 }
                budget -= 1
                guard let values = try? child.resourceValues(
                    forKeys: [.contentModificationDateKey, .creationDateKey]
                ) else { continue }
                for date in [values.contentModificationDate, values.creationDate] {
                    if let date, date > youngest { youngest = date }
                }
            }
        }

        return max(0, now.timeIntervalSince(youngest))
    }

    private static func newestDate(in attributes: [FileAttributeKey: Any]) -> Date? {
        [
            attributes[.modificationDate] as? Date,
            attributes[.creationDate] as? Date,
        ].compactMap { $0 }.max()
    }
}
