import AppKit

/// Opens the `Settings` scene from a menu bar app.
///
/// `LSUIElement` apps are `.accessory`, and an accessory app cannot reliably front a
/// window. The activation policy is therefore raised to `.regular` just long enough to
/// show the window, and dropped again when it closes — otherwise a Dock icon lingers.
///
/// `@Environment(\.openSettings)` would be the tidy way to do this, but it needs
/// macOS 14, and the deployment target here is 13. The selector below is the documented
/// fallback, with the pre-Ventura spelling kept as a second attempt.
enum SettingsWindow {

    static func show() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        let ventura = Selector(("showSettingsWindow:"))
        let legacy = Selector(("showPreferencesWindow:"))

        if !NSApp.sendAction(ventura, to: nil, from: nil) {
            _ = NSApp.sendAction(legacy, to: nil, from: nil)
        }

        // Bring the settings window itself to the front; sendAction alone sometimes
        // leaves it behind other applications.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            NSApp.windows
                .first { $0.title.localizedCaseInsensitiveContains("instelling")
                      || $0.title.localizedCaseInsensitiveContains("setting")
                      || $0.title.localizedCaseInsensitiveContains("voorkeur") }?
                .makeKeyAndOrderFront(nil)
        }
    }
}
