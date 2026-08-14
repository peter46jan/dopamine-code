import AppKit
import SwiftUI
import UserNotifications

/// De ingang van het proces.
///
/// Waarom dit niet gewoon `@main` op `DopamineCodeApp` is: dezelfde binary is ook de wachter
/// uit `RestartGuard`. Die wordt elke 30 seconden door launchd gestart, kijkt naar de kernel
/// en verdwijnt weer — en mag daarbij géén `NSApplication` optuigen. Een tweede exemplaar van
/// deze app in de menubalk, twee keer per minuut, zou precies de dubbele guardian opleveren
/// die `terminateIfAlreadyRunning` hieronder moet voorkomen.
@main
enum DopamineCodeEntry {
    @MainActor static func main() {
        if RestartGuard.shouldRunAsWatchdog {
            RestartGuard.runWatchdogAndExit()
        }
        DopamineCodeApp.main()
    }
}

struct DopamineCodeApp: App {

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel.shared

    var body: some Scene {
        MenuBarExtra {
            MenuView(model: model)
                .onAppear { model.refreshGrant() }
        } label: {
            // The NSImage is marked isTemplate, which is what earns the same automatic
            // menu bar vibrancy and light/dark inversion an SF Symbol would get.
            Image(nsImage: model.menuBarIcon)
        }
        // Not .menu: menu style drops non-text views and does not re-render on open,
        // which rules out a live countdown.
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(model: model)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !terminateIfAlreadyRunning() else { return }

        // Menu bar only: no Dock icon.
        NSApp.setActivationPolicy(.accessory)
        // Without a delegate macOS suppresses banners whenever it considers the app to be
        // frontmost — which for an accessory app happens as soon as its panel is open. These
        // four notifications are the ones you must not miss, so ask for them regardless.
        UNUserNotificationCenter.current().delegate = self
        AppModel.shared.start()
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list])
    }

    /// Two copies of this app would mean two guardians racing each other over one global
    /// kernel flag. The concrete way that happens: enabling the login item falls back to a
    /// `~/Library/LaunchAgents` plist with `RunAtLoad`, and bootstrapping it launches a
    /// second instance immediately, while the first is still running.
    private func terminateIfAlreadyRunning() -> Bool {
        let me = NSRunningApplication.current
        let others = NSRunningApplication
            .runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .filter { $0.processIdentifier != me.processIdentifier }

        // Yield to whichever instance started first, so the running one keeps its state.
        let older = others.contains { other in
            guard let theirs = other.launchDate else { return false }
            guard let mine = me.launchDate else { return true }
            return theirs < mine
        }
        guard older else { return false }

        NSLog("Dopamine Code draait al; deze tweede instantie sluit zichzelf af.")
        isDuplicateInstance = true
        NSApp.terminate(nil)
        return true
    }

    private var isDuplicateInstance = false

    func applicationWillTerminate(_ notification: Notification) {
        // A duplicate instance never started a session and must not touch the flag: the
        // instance that owns it is still running, and clearing it here would let the Mac
        // sleep in the middle of the run this app exists to protect.
        guard !isDuplicateInstance else { return }
        AppModel.shared.shutdown()
    }

    /// Closing the Settings window must not quit a menu bar app.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
