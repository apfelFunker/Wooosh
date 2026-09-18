import AppKit
import SwiftUI

/// The one piece of UI Wooosh has.
///
/// It answers the only two questions a new user can have: is it working, and if
/// not, what do I do about it. Everything else the app does is invisible by
/// design.
struct SetupView: View {
    @ObservedObject var model: SetupModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if model.isBlocked {
                        instructions
                    } else {
                        runningSummary
                    }
                    footnote
                }
                .padding(24)
            }
        }
        .frame(width: 520, height: 580)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 16) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 64, height: 64)

            VStack(alignment: .leading, spacing: 4) {
                Text("Wooosh")
                    .font(.system(size: 22, weight: .semibold))
                Text(model.isBlocked
                     ? "One more step, then it runs on its own."
                     : "Running in the background.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            statusPill
        }
        .padding(24)
    }

    private var statusPill: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(model.isBlocked ? Color.orange : Color.green)
                .frame(width: 8, height: 8)
            Text(model.isBlocked ? "Waiting" : "Active")
                .font(.system(size: 12, weight: .medium))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Capsule().fill(Color(nsColor: .controlBackgroundColor)))
    }

    // MARK: - Blocked

    private var instructions: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Grant Full Disk Access")
                .font(.system(size: 15, weight: .semibold))

            Text("""
                macOS protects the folder where the iCloud cache piles up. \
                Without this permission, Wooosh sees an empty directory there \
                and clears nothing.
                """)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 12) {
                step(1, "Click \u{201C}Open System Settings\u{201D}.")
                step(2, "Under \u{201C}Full Disk Access\u{201D}, click \u{201C}+\u{201D}.")
                step(3, "Pick Wooosh \u{2014} \u{201C}Show in Finder\u{201D} leads you to the app.")
                step(4, "Turn on the switch next to Wooosh.")
                step(5, "If macOS asks, choose \u{201C}Quit & Reopen\u{201D}.")
            }

            calloutBox(
                title: "macOS quits Wooosh while you grant access",
                body: """
                    That is how it works \u{2014} an app picks up new permissions only \
                    on its next start. If Wooosh simply disappears, open it once more \
                    afterwards. From then on it runs on its own.
                    """)

            Text("If access is granted while this window is open, Wooosh notices within a few seconds and starts right away.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                Button("Open System Settings") { model.openPrivacySettings() }
                    .buttonStyle(.borderedProminent)
                Button("Show in Finder") { model.revealInFinder() }
            }

            if !model.isInApplicationsFolder {
                calloutBox(
                    title: "Wooosh is not in the Applications folder yet",
                    body: """
                        Move the app to Applications first. From there, the permission \
                        and the start at login both hold reliably.
                        """)
            }
        }
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(number)")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .frame(width: 18, height: 18)
                .background(Circle().fill(Color.accentColor))
            Text(text)
                .font(.system(size: 13))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Running

    private var runningSummary: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("All set")
                .font(.system(size: 15, weight: .semibold))

            Text("""
                From now on Wooosh watches along and clears the iCloud cache as \
                soon as it is no longer needed. It starts at login, and it has \
                no window and no menu bar icon.
                """)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 12) {
                metric("Freed", model.totalFreed)
                metric("Free now", model.freeSpace)
                metric("Sweeps", "\(model.sweepCount)")
            }

            if let last = model.lastSweepDescription {
                Text(last)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 10) {
                Button("Sweep now") { model.sweepNow() }
                Button("Open log") { model.openLog() }
            }

            Toggle("Open at login", isOn: Binding(
                get: { model.launchAtLogin },
                set: { model.setLaunchAtLogin($0) }))
                .toggleStyle(.switch)
                .font(.system(size: 13))
        }
    }

    private func metric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value)
                .font(.system(size: 17, weight: .semibold, design: .rounded))
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8)
            .fill(Color(nsColor: .controlBackgroundColor)))
    }

    // MARK: - Shared

    private func calloutBox(title: String, body: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 12, weight: .semibold))
            Text(body)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8)
            .fill(Color.orange.opacity(0.12)))
    }

    private var footnote: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider().padding(.vertical, 4)
            Text("What Wooosh deletes")
                .font(.system(size: 12, weight: .semibold))
            Text("""
                Only caches that belong to a system service \u{2014} above all the \
                transfer copies the iCloud Drive service makes and never clears \
                again. Caches and data of individual apps are left alone, and so \
                are your iCloud files themselves.
                """)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
