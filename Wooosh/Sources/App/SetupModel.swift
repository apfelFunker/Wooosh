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

    private let engine: SweepEngine
    private var pollTimer: Timer?

    init(engine: SweepEngine) {
        self.engine = engine
        refresh()
    }

    func refresh() {
        isBlocked = !engine.access.isFullyReachable
        totalFreed = Format.bytes(engine.state.totalBytesFreed)
        freeSpace = Volume.availableBytes().map(Format.bytes) ?? "—"
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
        engine.sweepNow()
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
