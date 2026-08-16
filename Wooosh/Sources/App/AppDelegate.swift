import AppKit
import SwiftUI
import UserNotifications

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {

    private let engine = SweepEngine()
    private var model: SetupModel!
    private var window: NSWindow?

    private let hasCompletedSetupKey = "wooosh.hasSeenSetup"

    func applicationDidFinishLaunching(_ notification: Notification) {
        model = SetupModel(engine: engine)

        UNUserNotificationCenter.current().delegate = self
        Notifier.requestAuthorization()

        engine.onChange = { [weak self] in
            self?.model.refresh()
            self?.syncNotification()
        }
        engine.start()
        model.refresh()

        LoginItem.register()

        // Show the window when there is something for the user to do, or the
        // very first time so a fresh install is never a silent no-op.
        let firstRun = !UserDefaults.standard.bool(forKey: hasCompletedSetupKey)
        if !engine.access.isFullyReachable || firstRun {
            showWindow()
        }
        if engine.access.isFullyReachable {
            UserDefaults.standard.set(true, forKey: hasCompletedSetupKey)
        }
        syncNotification()
    }

    /// Reopening from Finder or the Dock is the only way back into the window
    /// for a background app, so it must always surface something.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow()
        return true
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        engine.refreshAccess()
        model?.refresh()
    }

    /// A background app has no windows to keep it alive; without this it would
    /// quit the moment the setup window is closed.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    // MARK: - Window

    /// An `.accessory` app is not allowed to pull focus, so simply ordering the
    /// window front leaves it buried behind whatever the user was doing — on a
    /// fresh install that looks like double-clicking the app did nothing at all.
    /// Switching to `.regular` for as long as a window is on screen makes Wooosh
    /// a normal foreground app, and `windowWillClose` puts it back.
    private func becomeForeground() {
        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    private func resignForeground() {
        NSApp.setActivationPolicy(.accessory)
    }

    private func showWindow() {
        if let window {
            becomeForeground()
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
            model.startPolling()
            return
        }

        let hosting = NSHostingController(rootView: SetupView(model: model))
        let window = NSWindow(contentViewController: hosting)
        window.title = "Wooosh"
        window.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.center()
        window.delegate = self

        self.window = window
        becomeForeground()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        model.startPolling()
    }

    private func syncNotification() {
        if engine.access.isFullyReachable {
            Notifier.clearAccessBlocked()
            UserDefaults.standard.set(true, forKey: hasCompletedSetupKey)
        } else {
            Notifier.notifyAccessBlocked()
        }
    }

    // MARK: - Notifications

    /// Show the alert even while Wooosh is frontmost — it launches at login with
    /// no window, so "frontmost" says nothing about whether the user saw it.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        showWindow()
        completionHandler()
    }
}

extension AppDelegate: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        model.stopPolling()
        // Back to a background service. Deferred because the policy change has
        // to land after the window is actually gone, or the Dock icon lingers.
        DispatchQueue.main.async { [weak self] in self?.resignForeground() }
    }
}
