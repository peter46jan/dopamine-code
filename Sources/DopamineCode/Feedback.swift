import AppKit

/// Audible confirmation, because the whole point is that the menu bar is not visible
/// at the moment you most want to know whether it worked.
enum Feedback {

    private static func play(_ name: String) {
        guard Prefs.soundFeedback else { return }
        NSSound(named: NSSound.Name(name))?.play()
    }

    /// Rising, distinctly different from the off sound.
    static func activated() { play("Hero") }

    /// Falling, clearly not the same tone as activation.
    static func deactivated() { play("Bottle") }

    /// Something went wrong — never pair this with a green icon.
    static func failed() { play("Basso") }

    /// Connection lost mid-session. Separate setting, since this can fire at 4am.
    static func networkLost() {
        guard Prefs.soundOnNetworkLoss else { return }
        NSSound(named: NSSound.Name("Sosumi"))?.play()
    }

    static func networkRestored() {
        guard Prefs.soundOnNetworkLoss else { return }
        NSSound(named: NSSound.Name("Tink"))?.play()
    }
}
