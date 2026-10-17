import AppKit
import Combine
import Foundation

/// View model for `SetupView`. Owns no logic of its own beyond formatting —
/// everything it reports comes from the engine.
final class SetupModel: ObservableObject {

    @Published private(set) var isBlocked: Bool = false
    @Published private(set) var totalFreed: String = "—"
    @Published private(set) var freeSpace: String = "—"
    @Published private(set) var sweepCount: Int = 0
    @Published private(set) var lastSweepDescription: String?
    @Published private(set) var launchAtLogin: Bool = false
    @Published private(set) var isInApplicationsFolder: Bool = true

    /// Share of the disk in use, 0...1.
    @Published private(set) var diskUsedFraction: Double = 0
    @Published private(set) var diskTotal: String = "—"
    @Published private(set) var breakdown: [BreakdownRow] = []

    @Published private(set) var temporarySize: String?
    @Published private(set) var temporaryAction: ActionState = .idle
    @Published private(set) var sweepAction: ActionState = .idle

    enum ActionState: Equatable {
        case idle
        case running
        case done(String)
    }

    struct BreakdownRow: Identifiable {
        let id: String
        let name: String
        let symbol: String
        let rule: String
        let freed: String
    }

    /// The automatic targets, in the order the window lists them.
    private static let rows: [(id: String, name: String, symbol: String, rule: String)] = [
        ("cloudkit.bird", "iCloud Drive transfer copies", "icloud",
         "Copies older than 2 hours"),
        ("pasteboard.handoff", "Universal Clipboard archives", "doc.on.clipboard",
         "Archives older than 1 hour"),
        ("xcode.devicesupport", "Xcode device support", "hammer",
         "OS versions unused for 60 days"),
        (SimulatorCleanup.id, "Orphaned simulators", "iphone",
         "Simulators whose iOS version is gone"),
    ]

    private let engine: SweepEngine
    private var pollTimer: Timer?

    init(engine: SweepEngine) {
        self.engine = engine
        refresh()
    }

    func refresh() {
        isBlocked = !engine.access.isFullyReachable
        totalFreed = Format.bytes(engine.state.totalBytesFreed)
        let free = Volume.availableBytes()
        let total = Volume.totalBytes()
        freeSpace = free.map(Format.bytes) ?? "—"
        diskTotal = total.map(Format.bytes) ?? "—"
        if let free, let total, total > 0 {
            diskUsedFraction = min(1, max(0, 1 - Double(free) / Double(total)))
        }
        breakdown = Self.rows.map { row in
            let bytes = engine.state.perTargetBytesFreed[row.id] ?? 0
            return BreakdownRow(id: row.id, name: row.name, symbol: row.symbol,
                                rule: row.rule, freed: bytes > 0 ? Format.bytes(bytes) : "—")
        }
        sweepCount = engine.state.sweepCount
        launchAtLogin = LoginItem.isRegistered
        isInApplicationsFolder = LoginItem.isInApplicationsFolder

        if let last = engine.state.lastSweep {
            let formatter = RelativeDateTimeFormatter()
            formatter.locale = Locale(identifier: "en_US")
            formatter.unitsStyle = .full
            let when = formatter.localizedString(for: last, relativeTo: Date())
            let freed = Format.bytes(engine.state.lastSweepBytesFreed)
            lastSweepDescription = engine.state.lastSweepBytesFreed > 0
                ? "Last sweep \(when): \(freed) freed."
                : "Last sweep \(when): nothing to clear."
        } else {
            lastSweepDescription = nil
        }
    }

    /// While the window is visible, re-check permissions on a short cycle. The
    /// user is expected to leave for System Settings and come back, and the app
    /// gets no callback when Full Disk Access is granted.
    func startPolling() {
        stopPolling()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.engine.refreshAccess()
            self.refresh()
        }
    }

    func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    // MARK: - Actions

    func openPrivacySettings() {
        // Deep link straight to the Full Disk Access list.
        let url = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
        NSWorkspace.shared.open(url)
    }

    func revealInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
    }

    func openLog() {
        NSWorkspace.shared.open(Log.shared.fileURL)
    }

    func sweepNow() {
        guard sweepAction != .running else { return }
        sweepAction = .running
        engine.sweepNow { [weak self] result in
            guard let self else { return }
            self.sweepAction = .done(result.aborted
                ? "Stopped \u{2014} see the log"
                : result.bytesFreed > 0 ? "\(Format.bytes(result.bytesFreed)) freed" : "Nothing to clear")
            self.refresh()
        }
    }

    func measureTemporaryFiles() {
        engine.measureTemporaryFiles { [weak self] size in
            self?.temporarySize = Format.bytes(size)
        }
    }

    func clearTemporaryFiles() {
        guard temporaryAction != .running else { return }
        temporaryAction = .running
        engine.clearTemporaryFiles { [weak self] result in
            guard let self else { return }
            let kept = result.skipped[TargetCatalogue.temporaryFiles.id] ?? 0
            if result.aborted {
                self.temporaryAction = .done("Stopped \u{2014} open files could not be checked")
            } else {
                let freed = result.bytesFreed > 0 ? "\(Format.bytes(result.bytesFreed)) freed" : "Nothing to clear"
                self.temporaryAction = .done(kept > 0 ? "\(freed) \u{00B7} \(kept) in use, kept" : freed)
            }
            self.refresh()
            self.measureTemporaryFiles()
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        if enabled {
            LoginItem.register()
        } else {
            LoginItem.unregister()
        }
        launchAtLogin = LoginItem.isRegistered
    }
}
