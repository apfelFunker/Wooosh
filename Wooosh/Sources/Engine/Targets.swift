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
            displayName: "iCloud Drive transfer staging (bird)",
            containerGlob: "~/Library/Caches/CloudKit/com.apple.bird/*/Assets",
            minimumAge: 2 * 3600,
            requiresRoot: false,
            rationale: """
                While syncing iCloud Drive, bird stages a copy of every file it \
                transfers and does not reliably clear them afterwards. The originals live \
                in ~/Library/Mobile Documents and in iCloud; the staged copies are made \
                again when needed. A known cause of hundreds of GB of "System Data". \
                Owned by the system daemon, not by an app.
                """
        ),

        CleanupTarget(
            id: "iconservices",
            displayName: "Icon services store (system-wide)",
            containerGlob: "/Library/Caches/com.apple.iconservices.store",
            minimumAge: 7 * 24 * 3600,
            requiresRoot: true,
            rationale: """
                System-wide icon cache; it builds itself again on the next access. Owned \
                by root, so the user agent cannot delete it and skips it.
                """
        ),
    ]

    /// Measured, never touched.
    ///
    /// Caches and stores that belong to an app live here, because they are the
    /// app's own: rebuilding them costs downloads, processing time, or plain
    /// waiting at the next start. They stay visible all the same, so that
    /// `--report` shows the whole picture.
    static let observed: [ObservedPath] = [
        ObservedPath(
            displayName: "Claude VM bundles",
            glob: "~/Library/Application Support/Claude/vm_bundles",
            note: "the app's own store"),
        ObservedPath(
            displayName: "Claude cache",
            glob: "~/Library/Application Support/Claude/Cache",
            note: "the app's own cache"),
        ObservedPath(
            displayName: "Codex cache",
            glob: "~/Library/Caches/com.openai.codex",
            note: "the app's own cache"),
        ObservedPath(
            displayName: "Codex cache (legacy)",
            glob: "~/Library/Caches/Codex",
            note: "the app's own cache"),
        ObservedPath(
            displayName: "WhatsApp media cache",
            glob: "~/Library/Caches/net.whatsapp.WhatsApp",
            note: "the app's own cache"),
        ObservedPath(
            displayName: "ShipIt updater leftovers",
            glob: "~/Library/Caches/*.ShipIt",
            note: "sits in the cache folders of individual apps"),
        ObservedPath(
            displayName: "Xcode",
            glob: "~/Library/Developer/Xcode",
            note: "developer toolchain"),
        ObservedPath(
            displayName: "CoreSimulator devices",
            glob: "~/Library/Developer/CoreSimulator/Devices",
            note: "developer toolchain"),
        ObservedPath(
            displayName: "CoreSimulator runtime cache",
            glob: "/Library/Developer/CoreSimulator/Caches",
            note: "developer toolchain, belongs to Xcode"),
        ObservedPath(
            displayName: "Playwright browser builds",
            glob: "~/Library/Caches/ms-playwright",
            note: "a dedicated store"),
        ObservedPath(
            displayName: "Homebrew download cache",
            glob: "~/Library/Caches/Homebrew",
            note: "a dedicated store, see `brew cleanup`"),
        ObservedPath(
            displayName: "node-gyp headers",
            glob: "~/Library/Caches/node-gyp",
            note: "a dedicated store"),
        ObservedPath(
            displayName: "pip wheel cache",
            glob: "~/Library/Caches/pip",
            note: "a dedicated store"),
        ObservedPath(
            displayName: "Adobe Camera Raw cache",
            glob: "~/Library/Caches/Adobe Camera Raw 2",
            note: "the app's own cache"),
        ObservedPath(
            displayName: "Steam",
            glob: "~/Library/Caches/Steam",
            note: "the app's own cache"),
        ObservedPath(
            displayName: "iCloud Drive (real data)",
            glob: "~/Library/Mobile Documents/com~apple~CloudDocs",
            note: "not caches \u{2014} real files"),
    ]

    static func target(id: String) -> CleanupTarget? {
        all.first { $0.id == id }
    }
}
