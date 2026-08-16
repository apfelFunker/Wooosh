import Foundation

/// One cleanup target.
///
/// Every target resolves a glob to a set of *container directories*, then
/// deletes the direct children of each container. The container itself is never
/// removed — that keeps the owning app from tripping over a missing directory
/// and means a misconfigured glob can at worst empty a cache, never unlink a
/// tree the app expects to own.
struct CleanupTarget {
    let id: String
    let displayName: String
    /// Glob over container directories. May contain `~` and `*`.
    let containerGlob: String
    /// A child is only eligible once nothing has touched it for this long.
    let minimumAge: TimeInterval
    /// True for paths outside the user's home that a LaunchAgent cannot write.
    let requiresRoot: Bool
    /// Why this is safe to delete — surfaced in `--explain` and the log.
    let rationale: String

    var enabledByDefault: Bool { !requiresRoot }
}

/// A directory that is measured and reported but never touched.
///
/// These exist so `--report` can still show the full storage picture. They are
/// not reachable from the sweeper at all — no config flag turns them into
/// cleanup targets, because they are not in the list the sweeper reads.
struct ObservedPath {
    let displayName: String
    let glob: String
    let note: String
}

enum TargetCatalogue {

    /// Everything the sweeper is allowed to delete.
    ///
    /// Deliberately limited to caches owned by system daemons. Anything that
    /// belongs to a specific application — its cache, its store, its downloaded
    /// assets — is out of scope by policy and lives in `observed` instead.
    static let all: [CleanupTarget] = [

        CleanupTarget(
            id: "cloudkit.bird",
            displayName: "iCloud Drive Transfer-Staging (bird)",
            containerGlob: "~/Library/Caches/CloudKit/com.apple.bird/*/Assets",
            minimumAge: 2 * 3600,
            requiresRoot: false,
            rationale: """
                bird legt beim iCloud-Drive-Sync Staging-Kopien jeder übertragenen Datei an \
                und räumt sie nach Abschluss nicht zuverlässig ab. Die Originale liegen in \
                ~/Library/Mobile Documents und in iCloud; die Staging-Kopien werden bei Bedarf \
                neu erzeugt. Bekannt als Ursache von hunderten GB "Systemdaten". Gehört dem \
                Systemdaemon, keiner App.
                """
        ),

        CleanupTarget(
            id: "iconservices",
            displayName: "Icon-Services-Store (systemweit)",
            containerGlob: "/Library/Caches/com.apple.iconservices.store",
            minimumAge: 7 * 24 * 3600,
            requiresRoot: true,
            rationale: """
                Systemweiter Icon-Cache, baut sich beim nächsten Zugriff neu auf. Gehört root — \
                der User-Agent kann ihn nicht löschen und überspringt ihn.
                """
        ),
    ]

    /// Gemessen, aber niemals angefasst.
    ///
    /// App-eigene Caches und Stores stehen hier, weil sie der jeweiligen
    /// Anwendung gehören: sie wieder aufzubauen kostet Downloads, Rechenzeit
    /// oder schlicht Wartezeit beim nächsten Start. Sichtbar bleiben sie
    /// trotzdem, damit `--report` das vollständige Bild zeigt.
    static let observed: [ObservedPath] = [
        ObservedPath(
            displayName: "Claude VM-Bundles",
            glob: "~/Library/Application Support/Claude/vm_bundles",
            note: "App-eigener Store"),
        ObservedPath(
            displayName: "Claude Cache",
            glob: "~/Library/Application Support/Claude/Cache",
            note: "App-eigener Cache"),
        ObservedPath(
            displayName: "Codex Cache",
            glob: "~/Library/Caches/com.openai.codex",
            note: "App-eigener Cache"),
        ObservedPath(
            displayName: "Codex Cache (legacy)",
            glob: "~/Library/Caches/Codex",
            note: "App-eigener Cache"),
        ObservedPath(
            displayName: "WhatsApp Media-Cache",
            glob: "~/Library/Caches/net.whatsapp.WhatsApp",
            note: "App-eigener Cache"),
        ObservedPath(
            displayName: "ShipIt-Updater-Reste",
            glob: "~/Library/Caches/*.ShipIt",
            note: "liegt in den Cache-Ordnern einzelner Apps"),
        ObservedPath(
            displayName: "Xcode",
            glob: "~/Library/Developer/Xcode",
            note: "Entwickler-Toolchain"),
        ObservedPath(
            displayName: "CoreSimulator Geräte",
            glob: "~/Library/Developer/CoreSimulator/Devices",
            note: "Entwickler-Toolchain"),
        ObservedPath(
            displayName: "CoreSimulator Runtime-Cache",
            glob: "/Library/Developer/CoreSimulator/Caches",
            note: "Entwickler-Toolchain, gehört zu Xcode"),
        ObservedPath(
            displayName: "Playwright Browser-Builds",
            glob: "~/Library/Caches/ms-playwright",
            note: "dedizierter Store"),
        ObservedPath(
            displayName: "Homebrew Download-Cache",
            glob: "~/Library/Caches/Homebrew",
            note: "dedizierter Store, siehe `brew cleanup`"),
        ObservedPath(
            displayName: "node-gyp Header",
            glob: "~/Library/Caches/node-gyp",
            note: "dedizierter Store"),
        ObservedPath(
            displayName: "pip Wheel-Cache",
            glob: "~/Library/Caches/pip",
            note: "dedizierter Store"),
        ObservedPath(
            displayName: "Adobe Camera Raw Cache",
            glob: "~/Library/Caches/Adobe Camera Raw 2",
            note: "App-eigener Cache"),
        ObservedPath(
            displayName: "Steam",
            glob: "~/Library/Caches/Steam",
            note: "App-eigener Cache"),
        ObservedPath(
            displayName: "iCloud Drive (echte Daten)",
            glob: "~/Library/Mobile Documents/com~apple~CloudDocs",
            note: "keine Caches — echte Dateien"),
    ]

    static func target(id: String) -> CleanupTarget? {
        all.first { $0.id == id }
    }
}
