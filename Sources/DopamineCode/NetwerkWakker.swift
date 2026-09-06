import Foundation
import IOKit.pwr_mgt

/// Houdt het netwerk bereikbaar zolang er een sessie loopt.
///
/// Waarom dit er is, staat in het logboek van de Mac waar deze app voor gemaakt is. Daar
/// stonden 55 netwerkstoringen. Uitgesplitst over 34 met een meetbare duur:
///
///     klep open / dicht        19 / 15   — dus niet de klep
///     scherm uit / aan         25 /  9
///     korter dan 5 seconden        19    — ruis, wifi die van kanaal wisselt
///     langer dan een minuut         6
///
/// En de langste drie waren 47, 20 en 17 minuten, alle drie met de klep dicht en het scherm
/// uit. Dat is precies de toestand waar deze app voor bestaat: je loopt weg en stuurt hem
/// vanaf je telefoon. Een sessie die doorloopt terwijl je hem niet kunt bereiken, doet niet
/// waar hij voor bedoeld is.
///
/// `SleepDisabled` houdt het systeem wakker, maar zegt niets over de radio. macOS mag de wifi
/// in een spaarstand zetten terwijl het systeem draait, en doet dat kennelijk vooral als het
/// scherm uit is. `NetworkClientActive` is de verklaring die servers daarvoor gebruiken:
/// "houd mij bereikbaar". Openbare API, geen root, zichtbaar in `pmset -g assertions`.
///
/// Wat dit **niet** is: geen vangnet en geen belofte. De accugrens, de warmtebewaking en de
/// wachter merken er niets van, en een wifi die uitvalt omdat je router herstart valt hiermee
/// niet te redden. Het haalt één oorzaak weg, en het logboek zal laten zien of het genoeg was.
final class NetwerkWakker {

    static let shared = NetwerkWakker()

    private var verklaring: IOPMAssertionID = IOPMAssertionID(0)
    private(set) var actief = false

    private init() {}

    /// Zet de verklaring aan of uit. Idempotent.
    func stel(aan: Bool) {
        if aan { begin() } else { stop() }
    }

    private func begin() {
        guard !actief else { return }
        // De naam komt in `pmset -g assertions` te staan. Wie zich afvraagt wie zijn Mac
        // bereikbaar houdt, hoort daar een antwoord te vinden en geen raadsel.
        let reden = "Dopamine Code houdt het netwerk bereikbaar tijdens een sessie" as CFString
        let uitkomst = IOPMAssertionCreateWithName(
            kIOPMAssertNetworkClientActive as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reden,
            &verklaring)
        if uitkomst == kIOReturnSuccess {
            actief = true
            EventLog.shared.info("Netwerk wordt bereikbaar gehouden (IOPMAssertion).")
        } else {
            EventLog.shared.warn("Netwerk bereikbaar houden lukte niet (IOPMAssertion gaf \(uitkomst)).")
        }
    }

    private func stop() {
        guard actief else { return }
        IOPMAssertionRelease(verklaring)
        verklaring = IOPMAssertionID(0)
        actief = false
        EventLog.shared.info("Netwerk wordt niet meer bereikbaar gehouden.")
    }
}
