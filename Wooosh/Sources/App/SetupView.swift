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
                     ? "Noch ein Schritt, dann läuft es von allein."
                     : "Läuft im Hintergrund.")
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
            Text(model.isBlocked ? "Wartet" : "Aktiv")
                .font(.system(size: 12, weight: .medium))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Capsule().fill(Color(nsColor: .controlBackgroundColor)))
    }

    // MARK: - Blocked

    private var instructions: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Festplattenvollzugriff erteilen")
                .font(.system(size: 15, weight: .semibold))

            Text("""
                macOS schützt den Ordner, in dem sich der iCloud-Zwischenspeicher \
                ansammelt. Ohne diese Freigabe sieht Wooosh dort ein leeres \
                Verzeichnis und räumt nichts auf.
                """)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 12) {
                step(1, "Auf „Systemeinstellungen öffnen“ klicken.")
                step(2, "Unter „Festplattenvollzugriff“ auf „+“ klicken.")
                step(3, "Wooosh auswählen — mit „Im Finder zeigen“ findest du die App.")
                step(4, "Den Schalter neben Wooosh aktivieren.")
                step(5, "Falls macOS fragt: „Beenden & neu öffnen“ wählen.")
            }

            calloutBox(
                title: "macOS beendet Wooosh bei der Freigabe",
                body: """
                    Das gehört so — eine App übernimmt neue Berechtigungen erst beim \
                    nächsten Start. Sollte Wooosh dabei einfach verschwinden, öffne es \
                    danach noch einmal. Ab dann läuft es von allein.
                    """)

            Text("Steht die Freigabe, während dieses Fenster offen ist, erkennt Wooosh das innerhalb weniger Sekunden und legt sofort los.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                Button("Systemeinstellungen öffnen") { model.openPrivacySettings() }
                    .buttonStyle(.borderedProminent)
                Button("Im Finder zeigen") { model.revealInFinder() }
            }

            if !model.isInApplicationsFolder {
                calloutBox(
                    title: "Wooosh liegt noch nicht im Programme-Ordner",
                    body: """
                        Zieh die App zuerst nach „Programme“. Von dort aus bleibt die \
                        Freigabe und der Start bei der Anmeldung zuverlässig erhalten.
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
            Text("Alles erledigt")
                .font(.system(size: 15, weight: .semibold))

            Text("""
                Wooosh prüft ab jetzt automatisch mit und räumt den \
                iCloud-Zwischenspeicher ab, sobald er nicht mehr gebraucht wird. \
                Es startet bei der Anmeldung und hat kein Fenster und kein \
                Menüleistensymbol.
                """)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 12) {
                metric("Freigegeben", model.totalFreed)
                metric("Jetzt frei", model.freeSpace)
                metric("Durchläufe", "\(model.sweepCount)")
            }

            if let last = model.lastSweepDescription {
                Text(last)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 10) {
                Button("Jetzt aufräumen") { model.sweepNow() }
                Button("Protokoll öffnen") { model.openLog() }
            }

            Toggle("Bei der Anmeldung starten", isOn: Binding(
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
            Text("Was Wooosh löscht")
                .font(.system(size: 12, weight: .semibold))
            Text("""
                Ausschließlich Zwischenspeicher, die einem Systemdienst gehören — \
                allen voran die Übertragungskopien, die der iCloud-Drive-Dienst \
                anlegt und nicht wieder abräumt. Caches und Daten einzelner Apps \
                bleiben unangetastet, ebenso deine iCloud-Dateien selbst.
                """)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
