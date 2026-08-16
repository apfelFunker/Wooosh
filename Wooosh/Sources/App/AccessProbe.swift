import Foundation

/// Decides whether Wooosh can actually reach the caches it is supposed to clean.
///
/// This exists because a TCC denial is invisible through the normal file APIs:
/// `~/Library/Caches/CloudKit` simply reports as empty when access is refused,
/// so a blocked app looks exactly like one that found nothing to do. Only a raw
/// `opendir` returns the real `EPERM`.
enum AccessProbe {

    struct Entry {
        let id: String
        let displayName: String
        let path: String
        let detail: String
    }

    struct Result {
        let blocked: [Entry]
        let reachable: [Entry]

        var isFullyReachable: Bool { blocked.isEmpty }
    }

    static func evaluate(config: Config) -> Result {
        var blocked: [Entry] = []
        var reachable: [Entry] = []

        for (target, enabled) in config.resolvedTargets() where enabled && !target.requiresRoot {
            let path = Glob.stablePrefix(of: Paths.expand(target.containerGlob))
            let verdict = Glob.probe(path)

            let entry = Entry(
                id: target.id,
                displayName: target.displayName,
                path: path,
                detail: verdict)

            // A path that does not exist is not a permission problem — the cache
            // simply has not been created on this machine.
            if verdict.contains("Full Disk Access") {
                blocked.append(entry)
            } else {
                reachable.append(entry)
            }
        }
        return Result(blocked: blocked, reachable: reachable)
    }
}
