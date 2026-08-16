import CoreServices
import Foundation

enum Version {
    static let current = "2.1.0"
}

/// Runs the sweeps. Two triggers:
///
///  * a periodic timer, so nothing is missed;
///  * an FSEvents stream on the watched containers, so a cache that suddenly
///    balloons is collected within the throttle window rather than at the next
///    tick.
///
/// Owned by the app delegate and kept alive for the whole process lifetime.
final class SweepEngine {

    /// Called on the main queue after every sweep and whenever access changes.
    var onChange: (() -> Void)?

    private(set) var state: State
    private(set) var access: AccessProbe.Result = .init(blocked: [], reachable: [])

    private var config: Config
    private var sweeper: Sweeper

    private let queue = DispatchQueue(label: "com.juliuspaetzke.wooosh.engine")
    private var timer: DispatchSourceTimer?
    private var stream: FSEventStreamRef?
    private var pendingWork: DispatchWorkItem?

    init() {
        self.config = Config.load()
        self.sweeper = Sweeper(config: config)
        self.state = State.load()
        Log.shared.verbose = config.verboseLogging
    }

    func start() {
        Log.shared.info("Wooosh \(Version.current) gestartet (pid \(getpid()))")
        if let free = Volume.availableBytes() {
            Log.shared.info("Freier Speicher beim Start: \(Format.bytes(free))")
        }
        refreshAccess()
        startWatching()
        startTimer()
    }

    /// Re-reads config and permissions. Called when the setup window is open so
    /// granting Full Disk Access takes effect without a relaunch.
    func refreshAccess() {
        let result = AccessProbe.evaluate(config: config)
        let changed = result.blocked.map(\.id) != access.blocked.map(\.id)
        access = result

        if changed {
            if result.blocked.isEmpty {
                Log.shared.info("Zugriff vollständig — alle aktiven Ziele erreichbar")
                // Permission just arrived: do the work now instead of waiting
                // out the rest of the interval.
                queue.async { [weak self] in self?.performSweep(reason: "Zugriff erteilt") }
            } else {
                Log.shared.warn("Zugriff fehlt für: \(result.blocked.map(\.id).joined(separator: ", "))")
            }
            DispatchQueue.main.async { [weak self] in self?.onChange?() }
        }
    }

    func sweepNow() {
        queue.async { [weak self] in self?.performSweep(reason: "manuell") }
    }

    // MARK: - Triggers

    private func startTimer() {
        let interval = max(60, config.sweepIntervalMinutes * 60)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 5, repeating: interval, leeway: .seconds(30))
        timer.setEventHandler { [weak self] in
            self?.performSweep(reason: "Intervall")
        }
        timer.resume()
        self.timer = timer
    }

    private func startWatching() {
        // Watch the deepest wildcard-free ancestor of each glob. Walking further
        // up (to ~/Library, say) would pull in the write traffic of every app on
        // the machine for no extra coverage.
        var candidates = Set<String>()
        for (target, enabled) in config.resolvedTargets() where enabled && !target.requiresRoot {
            let prefix = Glob.stablePrefix(of: Paths.expand(target.containerGlob))
            if !prefix.isEmpty, FileManager.default.fileExists(atPath: prefix) {
                candidates.insert(SafetyGate.standardize(prefix))
            }
        }
        // FSEvents watches recursively, so a path covered by an ancestor in the
        // set is redundant.
        let watched = candidates.filter { path in
            !candidates.contains { $0 != path && path.hasPrefix($0 + "/") }
        }
        guard !watched.isEmpty else {
            Log.shared.warn("Keine überwachbaren Pfade gefunden — nur Intervall-Sweeps")
            return
        }

        let context = UnsafeMutablePointer<FSEventStreamContext>.allocate(capacity: 1)
        context.initialize(to: FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil))

        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<SweepEngine>.fromOpaque(info).takeUnretainedValue().scheduleThrottledSweep()
        }

        let paths = Array(watched).sorted()
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault, callback, context, paths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 5.0,
            FSEventStreamCreateFlags(
                kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagWatchRoot)
        ) else {
            Log.shared.warn("FSEvents-Stream nicht erstellbar — nur Intervall-Sweeps")
            context.deinitialize(count: 1)
            context.deallocate()
            return
        }

        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            Log.shared.warn("FSEvents-Stream nicht startbar — nur Intervall-Sweeps")
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            return
        }
        self.stream = stream
        Log.shared.info("Überwache \(paths.count) Pfade: \(paths.joined(separator: ", "))")
    }

    /// Trailing-edge throttle, deliberately not a resetting debounce: the first
    /// event of a burst starts the clock and later events fold into it. A
    /// resetting debounce would be starved outright on a busy cache directory,
    /// since the next write always lands before the timer expires. Protecting an
    /// in-flight transfer is the safety gate's job, not the scheduler's.
    private func scheduleThrottledSweep() {
        guard pendingWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingWork = nil
            self.performSweep(reason: "Dateisystem-Änderung")
        }
        pendingWork = work
        queue.asyncAfter(deadline: .now() + max(10, config.watchDebounceSeconds), execute: work)
    }

    // MARK: - Sweep

    private func performSweep(reason: String) {
        Log.shared.debug("Sweep ausgelöst: \(reason)")
        let before = Volume.availableBytes()
        let result = sweeper.sweep()
        guard !result.aborted else { return }

        state.sweepCount += 1
        state.lastSweep = Date()
        state.lastSweepBytesFreed = result.bytesFreed
        if !config.dryRun {
            state.totalBytesFreed += result.bytesFreed
            state.totalItemsRemoved += result.itemsRemoved
            for (id, bytes) in result.perTarget {
                state.perTargetBytesFreed[id, default: 0] += bytes
            }
        }
        state.save()

        if result.bytesFreed > 0, let before, let after = Volume.availableBytes() {
            Log.shared.info("Frei: \(Format.bytes(before)) -> \(Format.bytes(after))")
        }
        DispatchQueue.main.async { [weak self] in self?.onChange?() }
    }
}
