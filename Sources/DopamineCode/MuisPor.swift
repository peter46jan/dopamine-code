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

    /// Vraag de toestemming, en ververs het antwoord.
    ///
    /// `CGPreflightPostEventAccess()` onthoudt zijn antwoord voor de duur van het proces. Wie
    /// de toestemming geeft terwijl de app draait, blijft daarom "werkt niet" zien tot hij hem
    /// herstart — precies wat er gebeurde toen dit voor het eerst gebruikt werd. Deze aanroep
    /// is de API die er wél voor bedoeld is: hij vraagt het opnieuw, en toont het systeemvenster
    /// als er nog nooit een antwoord gegeven is.
    @discardableResult
    static func vraagToestemming() -> Bool { CGRequestPostEventAccess() }

    /// Por de muis, als het nodig is.
    ///
    /// Alleen porren als het werkelijk stil is. Anders vecht hij met je hand: je beweegt de
    /// muis, en een halve seconde later trekt de app hem een punt opzij.
    ///
    /// Geeft terug of er werkelijk gepord is, zodat de aanroeper het kan loggen zonder zelf
    /// de voorwaarde te hoeven kennen.
    /// Hoe ver de cursor gaat, en hoe lang hij daar blijft.
    ///
    /// Onzichtbaar is één punt en veertig milliseconde: netto nul en niet te zien. Zichtbaar is
    /// honderdtwintig punten en een halve seconde, in een boog van vier stappen — dan zie je
    /// hem gaan en weer terugkomen.
    ///
    /// Een grote sprong is hier ongevaarlijk, en dat is geen toeval: er wordt alleen gepord als
    /// het al minuten stil is. Hij kan dus per constructie niet met je hand vechten.
    private struct Sprong {
        let afstand: CGFloat
        let stappen: Int
        let pauze: UInt32

        static let onzichtbaar = Sprong(afstand: 1, stappen: 1, pauze: 40_000)
        static let zichtbaar = Sprong(afstand: 120, stappen: 4, pauze: 60_000)
    }

    @discardableResult
    static func porAlsHetStilIs(naSeconden: Double, zichtbaar: Bool = false) -> Bool {
        guard stilteSeconden >= naSeconden, magPosten else { return false }
        guard let bron = CGEventSource(stateID: .combinedSessionState),
              let hier = CGEvent(source: nil)?.location else { return false }
        let sprong = zichtbaar ? Sprong.zichtbaar : .onzichtbaar

        func ga(naar punt: CGPoint) {
            CGEvent(mouseEventSource: bron, mouseType: .mouseMoved,
                    mouseCursorPosition: punt, mouseButton: .left)?.post(tap: .cgSessionEventTap)
            // Even wachten, anders voegt het venstersysteem de bewegingen samen tot niets.
            usleep(sprong.pauze)
        }

        // Heen en weer terug, zodat de cursor eindigt waar hij begon. Bij een zichtbare sprong
        // in stapjes: één sprong van honderdtwintig punten leest als een glitch, een boog als
        // een beweging.
        for i in 1...sprong.stappen {
            let deel = sprong.afstand * CGFloat(i) / CGFloat(sprong.stappen)
            ga(naar: CGPoint(x: hier.x + deel, y: hier.y))
        }
        for i in stride(from: sprong.stappen - 1, through: 0, by: -1) {
            let deel = sprong.afstand * CGFloat(i) / CGFloat(sprong.stappen)
            ga(naar: CGPoint(x: hier.x + deel, y: hier.y))
        }
        return true
    }
}
