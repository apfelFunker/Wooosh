import Foundation

/// Per-target override. Everything is optional so a config file only needs to
/// mention what it actually changes.
struct TargetOverride: Codable {
    var enabled: Bool?
    var minimumAgeHours: Double?
}

struct Config: Codable {
    /// Master kill switch. `false` makes the daemon idle without unloading it.
    var enabled: Bool = true
    /// Log what would be deleted, delete nothing.
    var dryRun: Bool = false
    /// Periodic sweep interval.
    var sweepIntervalMinutes: Double = 15
    /// Debounce after a filesystem event before sweeping the changed target.
    var watchDebounceSeconds: Double = 90
    /// Skip the sweep entirely while at least this much space is free.
    /// `nil` sweeps unconditionally.
    var skipWhenFreeGigabytesAbove: Double?
    /// Never spend longer than this on a single sweep.
    var maxSweepSeconds: Double = 600
    var verboseLogging: Bool = false
    var targets: [String: TargetOverride] = [:]

    static let `default` = Config()

    static func load() -> Config {
        let url = Paths.configURL
        guard let data = try? Data(contentsOf: url) else { return .default }
        do {
            return try JSONDecoder().decode(Config.self, from: data)
        } catch {
            Log.shared.warn("config.json unlesbar (\(error.localizedDescription)) — nutze Defaults")
            return .default
        }
    }

    func save() throws {
        try FileManager.default.createDirectory(
            at: Paths.supportDirectory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: Paths.configURL, options: .atomic)
    }

    /// Resolves the built-in catalogue against this config.
    func resolvedTargets() -> [(target: CleanupTarget, enabled: Bool)] {
        TargetCatalogue.all.map { target in
            let override = targets[target.id]
            let enabled = override?.enabled ?? target.enabledByDefault
            guard let hours = override?.minimumAgeHours else {
                return (target, enabled)
            }
            let adjusted = CleanupTarget(
                id: target.id,
                displayName: target.displayName,
                containerGlob: target.containerGlob,
                minimumAge: max(0, hours) * 3600,
                requiresRoot: target.requiresRoot,
                rationale: target.rationale
            )
            return (adjusted, enabled)
        }
    }
}

/// Cumulative counters, written after every sweep.
struct State: Codable {
    var totalBytesFreed: Int64 = 0
    var totalItemsRemoved: Int = 0
    var sweepCount: Int = 0
    var lastSweep: Date?
    var lastSweepBytesFreed: Int64 = 0
    var perTargetBytesFreed: [String: Int64] = [:]

    static func load() -> State {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: Paths.stateURL),
              let state = try? decoder.decode(State.self, from: data)
        else { return State() }
        return state
    }

    func save() {
        try? FileManager.default.createDirectory(
            at: Paths.supportDirectory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(self) {
            try? data.write(to: Paths.stateURL, options: .atomic)
        }
    }
}
