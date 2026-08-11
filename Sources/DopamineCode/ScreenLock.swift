import Foundation

/// Locks the screen to the real login window.
///
/// With system sleep disabled the Mac never reaches the login window on its own, so an
/// unattended machine with a closed lid would stay unlocked with every session open.
/// This closes that hole explicitly.
///
/// `SACLockScreenImmediate` is a private symbol in `login.framework`, reached by
/// `dlopen`/`dlsym` so there is no link-time dependency on a private framework: if Apple
/// ever removes it, the lookup returns nil and we degrade instead of failing to launch.
///
/// The old `CGSession -suspend` trick is dead — `User.menu` was removed in Big Sur and
/// is still absent on macOS 26. Simulating ⌘⌃Q was rejected too: it needs Accessibility
/// approval and breaks if the shortcut is remapped.
enum ScreenLock {

    private typealias VoidFn = @convention(c) () -> Void
    private typealias BoolFn = @convention(c) () -> Bool

    private static let handle: UnsafeMutableRawPointer? = {
        dlopen("/System/Library/PrivateFrameworks/login.framework/Versions/A/login", RTLD_LAZY)
    }()

    private static func symbol<T>(_ name: String, as type: T.Type) -> T? {
        guard let h = handle, let sym = dlsym(h, name) else { return nil }
        return unsafeBitCast(sym, to: type)
    }

    /// Whether the system is configured to actually require a password. If this is false
    /// the lock call still runs but buys nothing, and the user deserves to be told.
    static var lockingEnabled: Bool? {
        guard let fn = symbol("SACScreenLockEnabled", as: BoolFn.self) else { return nil }
        return fn()
    }

    enum Outcome {
        case locked
        case fellBackToScreenSaver
        case unavailable
    }

    @discardableResult
    static func lockNow() -> Outcome {
        if let lock = symbol("SACLockScreenImmediate", as: VoidFn.self) {
            lock()
            EventLog.shared.info("Scherm vergrendeld (SACLockScreenImmediate).")
            return .locked
        }
        if let saver = symbol("SACScreenSaverStartNow", as: VoidFn.self) {
            saver()
            EventLog.shared.warn("SACLockScreenImmediate niet gevonden; schermbeveiliging gestart als terugval.")
            return .fellBackToScreenSaver
        }
        EventLog.shared.error("Geen vergrendelmechanisme beschikbaar in login.framework.")
        return .unavailable
    }

    /// Reads the system lock delay. "immediate" means a locked screen asks for a
    /// password or Touch ID straight away.
    ///
    /// Async: `sysadminctl` is slow enough to be noticeable and this is only ever read for
    /// the diagnostics pane, which has no business blocking the guardian.
    static func lockDelayDescription() async -> String? {
        let r = await Shell.runAsync("/usr/sbin/sysadminctl", ["-screenLock", "status"], timeout: 8)
        let text = r.combined
        guard !text.isEmpty else { return nil }
        // sysadminctl writes to stderr; the useful part is the last line.
        return text.split(separator: "\n").last.map(String.init)
    }
}
