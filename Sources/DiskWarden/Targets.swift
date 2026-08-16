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

enum TargetCatalogue {

    static let all: [CleanupTarget] = [

        // ── The main offender ────────────────────────────────────────────────
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
                neu erzeugt. Bekannt als Ursache von hunderten GB "Systemdaten".
                """
        ),

        // ── Squirrel/ShipIt updater leftovers ────────────────────────────────
        CleanupTarget(
            id: "shipit",
            displayName: "ShipIt-Updater-Reste (Squirrel)",
            containerGlob: "~/Library/Caches/*.ShipIt",
            minimumAge: 24 * 3600,
            requiresRoot: false,
            rationale: """
                Squirrel entpackt App-Updates hierhin und lässt die entpackte Vorgängerversion \
                stehen. Nach einem abgeschlossenen Update sind das reine Leichen.
                """
        ),

        // ── Developer tooling caches ─────────────────────────────────────────
        CleanupTarget(
            id: "codex.cache",
            displayName: "OpenAI Codex Cache",
            containerGlob: "~/Library/Caches/com.openai.codex",
            minimumAge: 7 * 24 * 3600,
            requiresRoot: false,
            rationale: "Reiner Response-/Asset-Cache der Codex-CLI, wird bei Bedarf neu aufgebaut."
        ),
        CleanupTarget(
            id: "codex.cache.legacy",
            displayName: "Codex Cache (legacy)",
            containerGlob: "~/Library/Caches/Codex",
            minimumAge: 7 * 24 * 3600,
            requiresRoot: false,
            rationale: "Älterer Codex-Cache-Pfad, gleiche Semantik."
        ),
        CleanupTarget(
            id: "homebrew",
            displayName: "Homebrew Download-Cache",
            containerGlob: "~/Library/Caches/Homebrew",
            minimumAge: 14 * 24 * 3600,
            requiresRoot: false,
            rationale: """
                Heruntergeladene Bottles und Quell-Tarballs. Homebrew lädt sie bei Bedarf neu; \
                entspricht `brew cleanup`.
                """
        ),
        CleanupTarget(
            id: "playwright",
            displayName: "Playwright Browser-Binaries",
            containerGlob: "~/Library/Caches/ms-playwright",
            minimumAge: 30 * 24 * 3600,
            requiresRoot: false,
            rationale: """
                Heruntergeladene Chromium-/Firefox-/WebKit-Builds. Regenerierbar über \
                `playwright install`, aber das ist ein großer Download — daher 30 Tage Karenz.
                """
        ),
        CleanupTarget(
            id: "node-gyp",
            displayName: "node-gyp Header-Cache",
            containerGlob: "~/Library/Caches/node-gyp",
            minimumAge: 30 * 24 * 3600,
            requiresRoot: false,
            rationale: "Node-Header pro Version, werden beim nächsten nativen Build neu geholt."
        ),
        CleanupTarget(
            id: "pip",
            displayName: "pip Wheel-Cache",
            containerGlob: "~/Library/Caches/pip",
            minimumAge: 30 * 24 * 3600,
            requiresRoot: false,
            rationale: "Gecachte Wheels, werden bei Bedarf neu geladen bzw. gebaut."
        ),

        // ── App caches ───────────────────────────────────────────────────────
        CleanupTarget(
            id: "whatsapp",
            displayName: "WhatsApp Media-Cache",
            containerGlob: "~/Library/Caches/net.whatsapp.WhatsApp",
            minimumAge: 14 * 24 * 3600,
            requiresRoot: false,
            rationale: """
                Vorschau- und Medien-Cache. Die Chats selbst liegen im Container unter \
                ~/Library/Group Containers und werden nicht angefasst.
                """
        ),
        CleanupTarget(
            id: "adobe.camera-raw",
            displayName: "Adobe Camera Raw Cache",
            containerGlob: "~/Library/Caches/Adobe Camera Raw 2",
            minimumAge: 30 * 24 * 3600,
            requiresRoot: false,
            rationale: """
                Vorgerenderte RAW-Vorschauen. Löschen kostet nur Rechenzeit beim nächsten \
                Öffnen derselben Datei.
                """
        ),
        CleanupTarget(
            id: "steam.cache",
            displayName: "Steam HTTP-Cache",
            containerGlob: "~/Library/Caches/Steam",
            minimumAge: 30 * 24 * 3600,
            requiresRoot: false,
            rationale: "Storefront-/Bild-Cache. Enthält keine Spieldaten."
        ),

        // ── Root-owned: declared, but a LaunchAgent cannot touch these ───────
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
        CleanupTarget(
            id: "coresimulator.caches",
            displayName: "CoreSimulator Runtime-Download-Cache",
            containerGlob: "/Library/Developer/CoreSimulator/Caches",
            minimumAge: 7 * 24 * 3600,
            requiresRoot: true,
            rationale: """
                Zwischenspeicher heruntergeladener Simulator-Runtimes. Die installierten \
                Runtimes unter Volumes/ bleiben unangetastet. Gehört root.
                """
        ),
    ]

    static func target(id: String) -> CleanupTarget? {
        all.first { $0.id == id }
    }
}
