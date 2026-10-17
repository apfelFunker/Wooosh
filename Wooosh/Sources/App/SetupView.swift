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
                .padding(20)
            }
        }
        .frame(width: 560, height: 700)
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
                     : "Keeps System Data in check, in the background.")
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
        VStack(alignment: .leading, spacing: 16) {
            diskCard
            automaticCard
            temporaryCard
            controls
        }
        .onAppear { model.measureTemporaryFiles() }
    }

    private var diskCard: some View {
        card {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text(model.freeSpace)
                        .font(.system(size: 28, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    Text("free of \(model.diskTotal)")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                    Spacer()
                }

                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.08))
                        Capsule()
                            .fill(usageTint.gradient)
                            .frame(width: max(8, proxy.size.width * model.diskUsedFraction))
                    }
                }
                .frame(height: 8)
                .animation(.easeOut(duration: 0.4), value: model.diskUsedFraction)

                Text("Wooosh has freed \(model.totalFreed) so far, over \(model.sweepCount) sweeps.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Calm until the disk gets tight.
    private var usageTint: Color {
        switch model.diskUsedFraction {
        case ..<0.75: return .accentColor
        case ..<0.9: return .orange
        default: return .red
        }
    }

    private var automaticCard: some View {
        card {
            VStack(alignment: .leading, spacing: 0) {
                sectionTitle("Cleared automatically", trailing: "Freed so far")
                    .padding(.bottom, 8)
                ForEach(Array(model.breakdown.enumerated()), id: \.element.id) { index, row in
                    if index > 0 { Divider().padding(.leading, 34) }
                    HStack(spacing: 12) {
                        Image(systemName: row.symbol)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Color.accentColor)
                            .frame(width: 22)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(row.name).font(.system(size: 13))
                            Text(row.rule)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(row.freed)
                            .font(.system(size: 13, weight: .medium))
                            .monospacedDigit()
                            .foregroundStyle(row.freed == "—" ? .tertiary : .primary)
                    }
                    .padding(.vertical, 7)
                }
            }
        }
    }

    private var temporaryCard: some View {
        card {
            VStack(alignment: .leading, spacing: 10) {
                sectionTitle("Temporary files", trailing: model.temporarySize.map { "\($0) now" })

                Text("""
                    Apps leave scratch files behind, and a restart is what normally \
                    clears them. This does the same without restarting. Anything an \
                    app has open, or touched in the last hour, stays.
                    """)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 10) {
                    Button {
                        model.clearTemporaryFiles()
                    } label: {
                        Label("Clear Temporary Files", systemImage: "sparkles")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.temporaryAction == .running)

                    actionStatus(model.temporaryAction, running: "Clearing\u{2026}")
                }
            }
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Button("Sweep Now") { model.sweepNow() }
                    .disabled(model.sweepAction == .running)
                Button("Open Log") { model.openLog() }
                actionStatus(model.sweepAction, running: "Sweeping\u{2026}")
                Spacer()
                Toggle("Open at login", isOn: Binding(
                    get: { model.launchAtLogin },
                    set: { model.setLaunchAtLogin($0) }))
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .font(.system(size: 12))
            }
            if let last = model.lastSweepDescription {
                Text(last)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 4)
    }

    @ViewBuilder
    private func actionStatus(_ state: SetupModel.ActionState, running: String) -> some View {
        switch state {
        case .idle:
            EmptyView()
        case .running:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(running).font(.system(size: 12)).foregroundStyle(.secondary)
            }
        case .done(let message):
            Label(message, systemImage: "checkmark.circle.fill")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .transition(.opacity)
        }
    }

    private func sectionTitle(_ title: String, trailing: String? = nil) -> some View {
        HStack {
            Text(title).font(.system(size: 13, weight: .semibold))
            Spacer()
            if let trailing {
                Text(trailing)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color(nsColor: .separatorColor).opacity(0.6), lineWidth: 0.5))
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
                Only what macOS and Xcode make again by themselves: the transfer \
                copies iCloud Drive never clears, leftover Universal Clipboard archives, Xcode\u{2019}s symbols for old OS \
                versions, simulators that can no longer start, and \u{2014} when you \
                ask \u{2014} temporary files. Files in use are never touched, and \
                neither are the data of your apps or your iCloud files.
                """)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
