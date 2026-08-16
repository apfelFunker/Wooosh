import Foundation

struct SweepResult {
    var bytesFreed: Int64 = 0
    var itemsRemoved: Int = 0
    var perTarget: [String: Int64] = [:]
    var skipped: [String: Int] = [:]
    var aborted: Bool = false
}

final class Sweeper {
    private let config: Config
    private let fm = FileManager.default

    init(config: Config) {
        self.config = config
    }

    /// Runs one full pass. `only` restricts the pass to a single target, which
    /// is what the filesystem watcher uses.
    @discardableResult
    func sweep(only targetID: String? = nil) -> SweepResult {
        var result = SweepResult()
        let started = Date()

        guard config.enabled else {
            Log.shared.info("Deaktiviert per config (enabled=false) — kein Sweep")
            return result
        }

        if let threshold = config.skipWhenFreeGigabytesAbove,
           let free = Volume.availableBytes() {
            let freeGB = Double(free) / 1_073_741_824
            if freeGB > threshold {
                Log.shared.info(
                    "\(Format.bytes(free)) frei (> \(threshold) GB Schwelle) — kein Sweep")
                return result
            }
        }

        let openFiles = OpenFileIndex.snapshot()
        guard openFiles.isUsable else {
            Log.shared.error("Offene-Dateien-Index nicht verfügbar — Sweep abgebrochen (fail closed)")
            result.aborted = true
            return result
        }
        Log.shared.debug("\(openFiles.count) offene Pfade erfasst")

        let deadline = started.addingTimeInterval(config.maxSweepSeconds)
        let now = Date()

        for (target, enabled) in config.resolvedTargets() {
            if let targetID, target.id != targetID { continue }
            guard enabled else { continue }

            if target.requiresRoot && getuid() != 0 {
                Log.shared.debug("\(target.id): übersprungen — benötigt root")
                result.skipped[target.id, default: 0] += 1
                continue
            }
            if Date() > deadline {
                Log.shared.warn("Zeitbudget \(Format.duration(config.maxSweepSeconds)) erreicht — Rest vertagt")
                break
            }

            let freed = sweep(target: target, openFiles: openFiles, now: now,
                              deadline: deadline, result: &result)
            if freed > 0 {
                result.perTarget[target.id] = freed
                Log.shared.info("\(target.displayName): \(Format.bytes(freed)) freigegeben")
            }
        }

        let elapsed = Date().timeIntervalSince(started)
        if result.bytesFreed > 0 {
            Log.shared.info(
                "Sweep fertig: \(Format.bytes(result.bytesFreed)) in \(result.itemsRemoved) Objekten, "
                + "\(Format.duration(elapsed))")
        } else {
            Log.shared.debug("Sweep fertig: nichts zu tun (\(Format.duration(elapsed)))")
        }
        return result
    }

    // MARK: - Per target

    private func sweep(
        target: CleanupTarget,
        openFiles: OpenFileIndex,
        now: Date,
        deadline: Date,
        result: inout SweepResult
    ) -> Int64 {
        var freedForTarget: Int64 = 0

        let pattern = Paths.expand(target.containerGlob)
        let containers = Glob.expand(pattern)

        // An empty expansion is ambiguous: the cache may simply not exist, or
        // this process may lack the rights to see it. Probing tells them apart
        // instead of silently reporting a clean sweep.
        if containers.isEmpty {
            let prefix = Glob.stablePrefix(of: pattern)
            Log.shared.warn("\(target.id): keine Treffer für \(target.containerGlob) — \(prefix): \(Glob.probe(prefix))")
            return 0
        }

        for container in containers {
            if let rejection = SafetyGate.validateContainer(container) {
                Log.shared.warn("\(target.id): Container \(container) abgelehnt — \(rejection)")
                continue
            }

            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: container, isDirectory: &isDirectory),
                  isDirectory.boolValue else { continue }

            let containerURL = URL(fileURLWithPath: container, isDirectory: true)
            let deviceID = (try? fm.attributesOfItem(atPath: container))?[.systemNumber] as? Int

            guard let children = try? fm.contentsOfDirectory(
                at: containerURL,
                includingPropertiesForKeys: nil,
                options: []
            ) else {
                Log.shared.warn("\(target.id): \(container) nicht lesbar")
                continue
            }

            for child in children {
                if Date() > deadline { return freedForTarget }

                if let rejection = SafetyGate.validateChild(
                    child,
                    minimumAge: target.minimumAge,
                    now: now,
                    openPaths: openFiles,
                    containerDeviceID: deviceID
                ) {
                    Log.shared.debug("\(target.id): \(child.lastPathComponent) behalten — \(rejection)")
                    result.skipped[target.id, default: 0] += 1
                    continue
                }

                let size = allocatedSize(of: child)

                if config.dryRun {
                    Log.shared.info("[dry-run] würde löschen: \(child.path) (\(Format.bytes(size)))")
                    freedForTarget += size
                    result.bytesFreed += size
                    result.itemsRemoved += 1
                    continue
                }

                do {
                    try fm.removeItem(at: child)
                    freedForTarget += size
                    result.bytesFreed += size
                    result.itemsRemoved += 1
                    Log.shared.debug("gelöscht: \(child.path) (\(Format.bytes(size)))")
                } catch {
                    Log.shared.warn(
                        "\(target.id): \(child.lastPathComponent) nicht löschbar — "
                        + error.localizedDescription)
                    result.skipped[target.id, default: 0] += 1
                }
            }
        }

        return freedForTarget
    }

    /// On-disk size, which is what actually comes back as free space. Sparse and
    /// compressed files report far less than their logical length.
    func allocatedSize(of url: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isDirectoryKey]

        guard let values = try? url.resourceValues(forKeys: keys) else { return 0 }

        if values.isDirectory != true {
            return Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
        }

        var total: Int64 = 0
        guard let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: Array(keys),
            options: []
        ) else { return 0 }

        for case let child as URL in enumerator {
            guard let childValues = try? child.resourceValues(forKeys: keys),
                  childValues.isDirectory != true else { continue }
            total += Int64(childValues.totalFileAllocatedSize ?? childValues.fileAllocatedSize ?? 0)
        }
        return total
    }
}

enum Volume {
    static func availableBytes() -> Int64? {
        let url = URL(fileURLWithPath: NSHomeDirectory())
        let values = try? url.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    static func totalBytes() -> Int64? {
        let url = URL(fileURLWithPath: NSHomeDirectory())
        let values = try? url.resourceValues(forKeys: [.volumeTotalCapacityKey])
        return values?.volumeTotalCapacity.map(Int64.init)
    }
}
