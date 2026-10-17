import Foundation

/// Removes simulator devices whose runtime is no longer installed.
///
/// Such a device can never boot again, yet its data directory stays behind under
/// `~/Library/Developer/CoreSimulator/Devices`. The deletion is left to
/// `simctl delete unavailable`, Apple's own tool for exactly this, rather than to
/// the sweeper: devices that still have a runtime are never touched.
enum SimulatorCleanup {
    static let id = "simulators.unavailable"
    static let displayName = "Simulators without an installed runtime"

    static func run(config: Config, result: inout SweepResult) {
        guard config.targets[id]?.enabled ?? true else { return }
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/xcrun"),
              let listing = simctl(["list", "devices", "unavailable", "-j"]),
              let udids = unavailableUDIDs(in: listing)
        else { return }
        guard !udids.isEmpty else { return }

        let devices = Paths.expand("~/Library/Developer/CoreSimulator/Devices")
        let sweeper = Sweeper(config: config)
        let size = udids.reduce(Int64(0)) { total, udid in
            total + sweeper.allocatedSize(of: URL(fileURLWithPath: devices).appendingPathComponent(udid))
        }

        if config.dryRun {
            Log.shared.info("[dry-run] would delete \(udids.count) unavailable simulators (\(Format.bytes(size)))")
        } else {
            guard simctl(["delete", "unavailable"]) != nil else {
                Log.shared.warn("\(id): simctl delete unavailable failed")
                return
            }
        }

        result.bytesFreed += size
        result.itemsRemoved += udids.count
        result.perTarget[id] = size
        Log.shared.info("\(displayName): \(Format.bytes(size)) freed")
    }

    /// `simctl list -j` groups devices by runtime; every device in this listing
    /// is unavailable, but the flag is checked anyway.
    private static func unavailableUDIDs(in data: Data) -> [String]? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let byRuntime = root["devices"] as? [String: [[String: Any]]]
        else { return nil }
        return byRuntime.values.flatMap { $0 }.compactMap { device in
            guard device["isAvailable"] as? Bool == false else { return nil }
            return device["udid"] as? String
        }
    }

    /// Runs `xcrun simctl` and returns its output, or nil on failure or after
    /// two minutes.
    private static func simctl(_ arguments: [String]) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["simctl"] + arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }

        var data = Data()
        let finishedReading = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            data = pipe.fileHandleForReading.readDataToEndOfFile()
            finishedReading.signal()
        }
        let deadline = SweepClock.now + 120
        while process.isRunning && SweepClock.now < deadline { usleep(100_000) }
        if process.isRunning {
            process.terminate()
            return nil
        }
        _ = finishedReading.wait(timeout: .now() + 5)
        return process.terminationStatus == 0 ? data : nil
    }
}
