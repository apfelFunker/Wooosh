import CoreServices
import Foundation

/// Long-running mode. Two triggers:
///
///  * a periodic timer, so nothing is missed;
///  * an FSEvents stream on the watched containers, so a cache that suddenly
///    balloons is collected within the debounce window rather than at the next
///    tick. That is what makes the CloudKit case feel immediate — bird finishes
///    a sync, the staging files go quiet, and the next debounce collects them.
final class Daemon {
    private let config: Config
    private let sweeper: Sweeper
    private var state: State

    private let queue = DispatchQueue(label: "com.juliuspaetzke.diskwarden.daemon")
    private var timer: DispatchSourceTimer?
    private var stream: FSEventStreamRef?
    private var pendingWork: DispatchWorkItem?

    init(config: Config) {
        self.config = config
        self.sweeper = Sweeper(config: config)
        self.state = State.load()
    }

    func run() -> Never {
        Log.shared.info("DiskWarden \(Version.current) gestartet (pid \(getpid()))")
        Log.shared.info(
            "Intervall \(config.sweepIntervalMinutes) min, Debounce \(config.watchDebounceSeconds) s, "
            + "dryRun=\(config.dryRun)")
        if let free = Volume.availableBytes() {
            Log.shared.info("Freier Speicher beim Start: \(Format.bytes(free))")
        }

        installSignalHandlers()
        startWatching()
        startTimer()

        dispatchMain()
    }

    // MARK: - Triggers

    private func startTimer() {
        let interval = max(60, config.sweepIntervalMinutes * 60)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        // Fire once shortly after launch — the login sweep — then on interval.
        timer.schedule(deadline: .now() + 5, repeating: interval, leeway: .seconds(30))
        timer.setEventHandler { [weak self] in
            self?.performSweep(reason: "Intervall", only: nil)
        }
        timer.resume()
        self.timer = timer
    }

    private func startWatching() {
        // Watch the deepest wildcard-free ancestor of each glob — the container
        // itself where the path is literal. Walking up any further (to
        // ~/Library, say) would pull in the write traffic of every app on the
        // machine for no extra coverage.
        var candidates = Set<String>()
        for (target, enabled) in config.resolvedTargets() where enabled && !target.requiresRoot {
            let prefix = Glob.stablePrefix(of: Paths.expand(target.containerGlob))
            if !prefix.isEmpty, FileManager.default.fileExists(atPath: prefix) {
                candidates.insert(SafetyGate.standardize(prefix))
            }
        }

        // FSEvents watches recursively, so a path already covered by an ancestor
        // in the set is redundant.
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
            retain: nil,
            release: nil,
            copyDescription: nil
        ))

        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let daemon = Unmanaged<Daemon>.fromOpaque(info).takeUnretainedValue()
            daemon.scheduleDebouncedSweep()
        }

        let paths = Array(watched).sorted()
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            context,
            paths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            5.0, // coalesce bursts inside CoreServices before we even see them
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

    /// Collapses a burst of filesystem events into a single sweep.
    ///
    /// Trailing-edge throttle, deliberately not a resetting debounce: the first
    /// event of a burst starts the clock and later events are folded into it. A
    /// resetting debounce would be starved outright on a busy cache directory,
    /// since the next write always lands before the timer expires. Protecting an
    /// in-flight transfer is the safety gate's job — it checks open handles and
    /// mtime per file — not the scheduler's.
    private func scheduleDebouncedSweep() {
        guard pendingWork == nil else { return }

        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingWork = nil
            self.performSweep(reason: "Dateisystem-Änderung", only: nil)
        }
        pendingWork = work
        queue.asyncAfter(
            deadline: .now() + max(10, config.watchDebounceSeconds), execute: work)
    }

    // MARK: - Sweep

    private func performSweep(reason: String, only targetID: String?) {
        Log.shared.debug("Sweep ausgelöst: \(reason)")
        let before = Volume.availableBytes()
        let result = sweeper.sweep(only: targetID)
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
            Log.shared.info(
                "Frei: \(Format.bytes(before)) -> \(Format.bytes(after))")
        }
    }

    // MARK: - Lifecycle

    private func installSignalHandlers() {
        for signalNumber in [SIGTERM, SIGINT] {
            signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: queue)
            source.setEventHandler {
                Log.shared.info("Signal \(signalNumber) empfangen — beende")
                exit(0)
            }
            source.resume()
            signalSources.append(source)
        }
    }

    private var signalSources: [DispatchSourceSignal] = []
}

enum Version {
    static let current = "1.1.0"
}
