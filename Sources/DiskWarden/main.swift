import Foundation

let usage = """
DiskWarden \(Version.current) — räumt im Hintergrund die Caches auf, die macOS
als "Systemdaten" ausweist.

  diskwarden --daemon        Dauerbetrieb (so startet der LaunchAgent)
  diskwarden --once          Einen Sweep ausführen und beenden
  diskwarden --dry-run       Wie --once, löscht aber nichts
  diskwarden --status        Bisher freigegebener Speicher, Konfiguration
  diskwarden --report        Aktuelle Größe jedes Ziels, ohne etwas zu ändern
  diskwarden --explain       Jedes Ziel mit Begründung, warum es löschbar ist
  diskwarden --check-access  Prüfen, welche Ziele lesbar sind
  diskwarden --write-config  Standard-config.json anlegen
  diskwarden --version
  diskwarden --help

Konfiguration: ~/Library/Application Support/DiskWarden/config.json
Log:           ~/Library/Logs/DiskWarden/diskwarden.log
"""

let arguments = Array(CommandLine.arguments.dropFirst())
let mode = arguments.first ?? "--help"
let isVerbose = arguments.contains("--verbose")

var config = Config.load()
if isVerbose { config.verboseLogging = true }
Log.shared.verbose = config.verboseLogging

switch mode {

case "--daemon":
    Daemon(config: config).run()

case "--once", "--dry-run":
    Log.shared.echoToStdout = true
    if mode == "--dry-run" { config.dryRun = true }
    let sweeper = Sweeper(config: config)
    let result = sweeper.sweep()

    if result.aborted {
        print("Sweep abgebrochen — siehe Log.")
        exit(1)
    }
    if config.dryRun {
        print("\n[dry-run] \(Format.bytes(result.bytesFreed)) in \(result.itemsRemoved) Objekten wären freigeworden.")
    } else {
        var state = State.load()
        state.sweepCount += 1
        state.lastSweep = Date()
        state.lastSweepBytesFreed = result.bytesFreed
        state.totalBytesFreed += result.bytesFreed
        state.totalItemsRemoved += result.itemsRemoved
        for (id, bytes) in result.perTarget {
            state.perTargetBytesFreed[id, default: 0] += bytes
        }
        state.save()
        print("\n\(Format.bytes(result.bytesFreed)) in \(result.itemsRemoved) Objekten freigegeben.")
    }

case "--status":
    let state = State.load()
    print("DiskWarden \(Version.current)")
    print("")
    print("Aktiv:              \(config.enabled ? "ja" : "nein (enabled=false)")")
    print("Modus:              \(config.dryRun ? "dry-run" : "löschend")")
    print("Intervall:          \(config.sweepIntervalMinutes) min")
    if let free = Volume.availableBytes(), let total = Volume.totalBytes() {
        print("Speicher:           \(Format.bytes(free)) frei von \(Format.bytes(total))")
    }
    print("")
    print("Sweeps gesamt:      \(state.sweepCount)")
    print("Freigegeben gesamt: \(Format.bytes(state.totalBytesFreed)) in \(state.totalItemsRemoved) Objekten")
    if let last = state.lastSweep {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        print("Letzter Sweep:      \(formatter.string(from: last)) (\(Format.bytes(state.lastSweepBytesFreed)))")
    } else {
        print("Letzter Sweep:      noch keiner")
    }
    if !state.perTargetBytesFreed.isEmpty {
        print("")
        print("Nach Ziel:")
        for (id, bytes) in state.perTargetBytesFreed.sorted(by: { $0.value > $1.value }) {
            let name = TargetCatalogue.target(id: id)?.displayName ?? id
            print("  \(Format.bytes(bytes).padded(to: 10))  \(name)")
        }
    }

case "--report":
    let sweeper = Sweeper(config: config)

    func measure(_ globPattern: String) -> Int64? {
        let matches = Glob.expand(Paths.expand(globPattern))
        guard !matches.isEmpty else { return nil }
        return matches.reduce(into: Int64(0)) {
            $0 += sweeper.allocatedSize(of: URL(fileURLWithPath: $1))
        }
    }

    var total: Int64 = 0
    print("WIRD ABGERÄUMT\n")
    for (target, enabled) in config.resolvedTargets() {
        guard let size = measure(target.containerGlob) else { continue }
        total += size

        var flags: [String] = []
        if !enabled { flags.append("deaktiviert") }
        if target.requiresRoot { flags.append("braucht root") }
        let suffix = flags.isEmpty ? "" : "  [\(flags.joined(separator: ", "))]"
        print("  \(Format.bytes(size).padded(to: 10))  \(target.displayName)\(suffix)")
        print("  \(String(repeating: " ", count: 10))  \(target.containerGlob)")
        print("")
    }
    print("  Summe: \(Format.bytes(total))")

    print("\n\nWIRD NIE ANGEFASST\n")
    var observedTotal: Int64 = 0
    for entry in TargetCatalogue.observed {
        guard let size = measure(entry.glob) else { continue }
        observedTotal += size
        print("  \(Format.bytes(size).padded(to: 10))  \(entry.displayName) — \(entry.note)")
    }
    print("")
    print("  Summe: \(Format.bytes(observedTotal))")

case "--explain":
    for (target, enabled) in config.resolvedTargets() {
        print("── \(target.displayName) [\(target.id)]")
        print("   Pfad:      \(target.containerGlob)")
        print("   Karenz:    \(Format.hours(target.minimumAge)) ohne Zugriff")
        print("   Status:    \(enabled ? "aktiv" : "deaktiviert")\(target.requiresRoot ? ", braucht root" : "")")
        print("   Warum sicher:")
        for line in target.rationale.split(separator: "\n") {
            print("     \(line.trimmingCharacters(in: .whitespaces))")
        }
        print("")
    }
    print("Ausgenommen — app-eigene Caches und Stores, per Richtlinie tabu:")
    for entry in TargetCatalogue.observed {
        print("   \(entry.displayName) (\(entry.note))")
    }
    print("")
    print("Diese Pfade stehen in keiner Liste, die der Sweeper liest. Es gibt")
    print("keinen Konfigurationsschalter, der sie zu Löschzielen macht.")

case "--check-access":
    // Reports what *this* process can see. Run from a terminal that already has
    // Full Disk Access it will look fine even when the agent is blocked, so the
    // authoritative check is the agent's own log — see install.sh.
    var blocked = 0
    for (target, enabled) in config.resolvedTargets() where enabled {
        let prefix = Glob.stablePrefix(of: Paths.expand(target.containerGlob))
        let verdict = Glob.probe(prefix)
        if verdict.contains("Full Disk Access") { blocked += 1 }
        print("  \(verdict.contains("Full Disk Access") ? "✗" : "·") \(target.id): \(verdict)")
    }
    print("")
    if blocked > 0 {
        print("\(blocked) Ziel(e) gesperrt. Full Disk Access fehlt für diesen Prozess.")
        exit(1)
    }
    print("Alle aktiven Ziele erreichbar (im Kontext dieses Prozesses).")

case "--write-config":
    do {
        try config.save()
        print("Geschrieben: \(Paths.configURL.path)")
    } catch {
        print("Fehlgeschlagen: \(error.localizedDescription)")
        exit(1)
    }

case "--version":
    print(Version.current)

default:
    print(usage)
    if mode != "--help" { exit(2) }
}

extension String {
    func padded(to width: Int) -> String {
        count >= width ? self : String(repeating: " ", count: width - count) + self
    }
}
