import AppKit
import CoreGraphics

/// Whether the login window is currently in front.
///
/// This matters because every safety net in this app runs while the lid is shut and the
/// screen is locked. Anything that puts up a modal window in that state blocks the main
/// thread with nobody able to dismiss it — which would wedge the very code that is
/// supposed to release the flag.
enum ScreenState {

    static var isLocked: Bool {
        guard let info = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return (info["CGSSessionScreenIsLocked"] as? Bool) ?? false
    }

    /// Runs `action` now if the screen is unlocked, otherwise once it unlocks.
    ///
    /// Uses the distributed notification centre: screen lock and unlock are broadcast
    /// system-wide, not through NSWorkspace.
    static func whenUnlocked(_ action: @escaping () -> Void) {
        guard isLocked else {
            action()
            return
        }
        // The token has to live in a box: capturing the local `var` copies it while it is
        // still nil, so the observer was never removed and every deferred message left one
        // behind — and each one would fire on the next unlock.
        final class Box: @unchecked Sendable { var token: NSObjectProtocol? }
        let box = Box()
        box.token = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.screenIsUnlocked"),
            object: nil,
            queue: .main
        ) { _ in
            if let t = box.token { DistributedNotificationCenter.default().removeObserver(t) }
            action()
        }
    }
}
