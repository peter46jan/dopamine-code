import Foundation
import CoreGraphics

/// Een onzichtbare muisbeweging, zodat je "beschikbaar" blijft in apps die naar invoer kijken.
///
/// Wat dit wél en niet doet is gemeten, want de vanzelfsprekende aanpak werkt niet:
///
///     gepost via              HIDIdleTime      teller die apps lezen
///     cghidEventTap           onveranderd      onveranderd
///     cgSessionEventTap       onveranderd      36 s -> 1 s
///
/// `HIDIdleTime` uit `IOHIDSystem` telt alleen échte hardware-invoer en is met een gepost
/// gebeurtenis niet te beïnvloeden. Daar hangt de schermbeveiliging van macOS aan, dus die
/// houd je hiermee niet tegen — daarvoor is `SchermWakker`, en dat is ook de nette weg.
///
/// Wat wél terugloopt is `CGEventSource.secondsSinceLastEventType`, en dat is de teller die
/// Electron-apps als Teams en Slack gebruiken om je op "afwezig" te zetten. Alleen op de
/// sessie-tap; op de hid-tap gebeurt er niets.
///
/// De cursor blijft staan waar hij stond: één punt heen en meteen terug, netto nul. Gemeten
/// verschuiving na een por: 0 px.
enum MuisPor {

    /// Hoe lang geleden er voor het laatst iets gebeurde, volgens de teller die apps lezen.
    static var stilteSeconden: Double {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .mouseMoved)
    }

    /// Mag deze app gebeurtenissen posten? Zonder Toegankelijkheid doet een por niets.
    ///
    /// Let op: die toestemming hangt aan de handtekening. Bij een ad-hoc ondertekende bouw is
    /// dat de cdhash, en die verandert bij elke herbouw — dan moet je hem opnieuw geven.
    static var magPosten: Bool { CGPreflightPostEventAccess() }

    /// Por de muis, als het nodig is.
    ///
    /// Alleen porren als het werkelijk stil is. Anders vecht hij met je hand: je beweegt de
    /// muis, en een halve seconde later trekt de app hem een punt opzij.
    ///
    /// Geeft terug of er werkelijk gepord is, zodat de aanroeper het kan loggen zonder zelf
    /// de voorwaarde te hoeven kennen.
    @discardableResult
    static func porAlsHetStilIs(naSeconden: Double) -> Bool {
        guard stilteSeconden >= naSeconden, magPosten else { return false }
        guard let bron = CGEventSource(stateID: .combinedSessionState),
              let hier = CGEvent(source: nil)?.location else { return false }
        let opzij = CGPoint(x: hier.x + 1, y: hier.y)
        CGEvent(mouseEventSource: bron, mouseType: .mouseMoved,
                mouseCursorPosition: opzij, mouseButton: .left)?.post(tap: .cgSessionEventTap)
        // Even wachten, anders voegt het venstersysteem de twee samen tot niets.
        usleep(40_000)
        CGEvent(mouseEventSource: bron, mouseType: .mouseMoved,
                mouseCursorPosition: hier, mouseButton: .left)?.post(tap: .cgSessionEventTap)
        return true
    }
}
