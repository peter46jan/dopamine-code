import Foundation
import UserNotifications

/// Notifications for the six things that happen while nobody is looking.
///
/// Zes is het eindaantal van de vier fases; niet alle cases hoeven al te bestaan terwijl er
/// aan gebouwd wordt. Er komt er bewust géén bij voor een geslaagde automatische start of een
/// geweigerde sneltoets: vier nachtelijke meldingen die ertoe doen verwateren als er zes
/// bijkomen die dat niet doen. Daar zijn het logboek en het paneel voor.
///
/// Until now the only channel for these was `NSSound`, and the entire premise of this app is
/// a shut lid in an empty room — so at 03:12 a safety net would fire and the app would play
/// "Basso" to nobody. A notification does what a sound cannot: it waits until the screen is
/// unlocked and then stays in Notification Centre. That is exactly the shape of "tell the
/// person who comes back in six hours".
///
/// **Deliberately no action buttons.** The obvious one would be "+1 uur", and that would let
/// a locked screen push the safety net out — a net that exists precisely for the case where
/// nobody is present to make that judgement. A notification here reports; it never acts.
///
/// Every call is fire-and-forget. Three of the call sites are inside `attemptRelease` and
/// `forceRelease`, the most delicate path in the app; nothing there may ever wait on a
/// notification being delivered.
enum Notify {

    enum Kind {
        /// A safety net released the flag on its own.
        case sessionEnded
        /// The flag could not be put back. The Mac is not sleeping and cannot be made to.
        case releaseFailed
        /// Thermal pressure critical — the emergency sleep the flag switched off.
        case thermalCritical
        /// The Mac slept while we were holding it awake. The promise did not hold.
        case macSlept
        /// De app was weggevallen (kill -9, een crash) terwijl de Mac wakker gehouden werd,
        /// en het vangnet heeft hem teruggehaald.
        case restartedAfterLoss
        /// Een trigger wilde zelf aanzetten en dat mocht niet — een lege accu, te veel
        /// warmte, of de wachtwoordvrijstelling die weg is. Dit is de enige van de zes die
        /// over iets gaat dat *niet* gebeurd is, en juist daarom moet hij er zijn: een schema
        /// dat drie weken lang stil niet afgaat is erger dan een schema dat niet bestaat.
        case triggerRefused

        var title: String {
            switch self {
            case .sessionEnded: return "Het wakker houden is vanzelf gestopt"
            case .releaseFailed: return "De Mac kan niet gaan slapen"
            case .thermalCritical: return "De Mac is te warm geworden"
            case .macSlept: return "De Mac heeft tóch geslapen"
            case .restartedAfterLoss: return "Dopamine Code was weggevallen"
            case .triggerRefused: return "Vanzelf aanzetten is niet gelukt"
            }
        }

        /// Same identifier for the same kind, so a repeat replaces its predecessor rather
        /// than stacking six copies of one problem in Notification Centre.
        var identifier: String { "dopamine-code.\(self)" }
    }

    /// Asked once at launch. macOS only ever shows the system prompt the first time; after
    /// the user has decided, this is a no-op that just reports the standing answer.
    static func requestAuthorisation() {
        guard available else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { granted, error in
            if let error {
                EventLog.shared.warn("Toestemming voor meldingen mislukte: \(error.localizedDescription)")
            } else if !granted {
                EventLog.shared.warn(
                    "Meldingen zijn niet toegestaan. Wat 's nachts gebeurt komt dan alleen in "
                    + "het logboek en in het menu, niet in het Berichtencentrum."
                )
            }
        }
    }

    static func post(_ kind: Kind, _ body: String) {
        guard available, Prefs.notifications else { return }
        let content = UNMutableNotificationContent()
        content.title = kind.title
        content.body = body
        // No sound here: Feedback already plays one, and two at once is worse than either.
        content.sound = nil
        let request = UNNotificationRequest(identifier: kind.identifier, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                EventLog.shared.warn("Melding '\(kind.title)' kon niet geplaatst worden: \(error.localizedDescription)")
            }
        }
    }

    /// `UNUserNotificationCenter.current()` raises rather than returns nil when the process
    /// has no bundle identifier — which is the case for the test harnesses that compile these
    /// files directly. Guarding here keeps those runnable.
    private static var available: Bool { Bundle.main.bundleIdentifier != nil }
}
