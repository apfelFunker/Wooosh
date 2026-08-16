import Foundation

/// Snapshot of every file currently held open by a process of this user.
///
/// This is the check that separates "stale cache" from "transfer in flight".
/// Built once per sweep from a single `lsof` call; if `lsof` fails or times out
/// the index is marked unusable and the whole sweep is abandoned rather than
/// run blind.
struct OpenFileIndex {
    private let paths: Set<String>
    /// Sorted copy, so a directory candidate can be tested against the files
    /// beneath it with a binary search instead of a full scan.
    private let sorted: [String]
    let isUsable: Bool

    static let unusable = OpenFileIndex(paths: [], usable: false)

    private init(paths: Set<String>, usable: Bool) {
        self.paths = paths
        self.sorted = paths.sorted()
        self.isUsable = usable
    }

    var count: Int { paths.count }

    /// True if `prefix` is itself open, or if anything beneath it is.
    func isOpen(prefix: String) -> Bool {
        if paths.contains(prefix) { return true }

        let needle = prefix.hasSuffix("/") ? prefix : prefix + "/"
        var low = 0
        var high = sorted.count
        while low < high {
            let mid = (low + high) / 2
            if sorted[mid] < needle { low = mid + 1 } else { high = mid }
        }
        return low < sorted.count && sorted[low].hasPrefix(needle)
    }

    /// `lsof -w -n -F n` lists open files for the invoking user's processes in a
    /// machine-readable form: `p<pid>` and `n<path>` records, one per line.
    static func snapshot(timeout: TimeInterval = 60) -> OpenFileIndex {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-w", "-n", "-F", "n"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            Log.shared.error("lsof nicht startbar: \(error.localizedDescription)")
            return .unusable
        }

        // Read concurrently with the wait — lsof produces far more than a pipe
        // buffer holds, and reading only after termination would deadlock.
        var data = Data()
        let readQueue = DispatchQueue(label: "com.juliuspaetzke.wooosh.lsof")
        let finishedReading = DispatchSemaphore(value: 0)
        readQueue.async {
            data = pipe.fileHandleForReading.readDataToEndOfFile()
            finishedReading.signal()
        }

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            usleep(50_000)
        }
        if process.isRunning {
            process.terminate()
            Log.shared.error("lsof-Timeout nach \(Format.duration(timeout)) — Sweep wird übersprungen")
            _ = finishedReading.wait(timeout: .now() + 5)
            return .unusable
        }
        process.waitUntilExit()

        guard finishedReading.wait(timeout: .now() + 10) == .success else {
            Log.shared.error("lsof-Ausgabe nicht vollständig lesbar — Sweep wird übersprungen")
            return .unusable
        }

        // lsof exits 1 when some paths were unreadable, which is normal for a
        // non-root user. Only a missing/blank result is disqualifying.
        guard let text = String(data: data, encoding: .utf8), !text.isEmpty else {
            Log.shared.error("lsof lieferte keine Ausgabe — Sweep wird übersprungen")
            return .unusable
        }

        var paths = Set<String>()
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard line.first == "n" else { continue }
            let path = String(line.dropFirst())
            guard path.hasPrefix("/") else { continue }
            paths.insert(SafetyGate.standardize(path))
        }

        guard !paths.isEmpty else {
            Log.shared.error("lsof lieferte keine Pfade — Sweep wird übersprungen")
            return .unusable
        }

        return OpenFileIndex(paths: paths, usable: true)
    }
}
