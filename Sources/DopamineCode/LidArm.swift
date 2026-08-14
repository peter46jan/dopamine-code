import Foundation

/// "Ga aan zodra ik de klep dichtdoe", eenmalig.
///
/// Dit is fase 3.1, en het is bewust *niet* het Option-klep-gebaar van Clamshell geworden.
/// Twee redenen, allebei gemeten of zwart-op-wit in deze codebase:
///
/// * Toetsen aflezen op het moment dat de klep dichtgaat vraagt Toegankelijkheid, en die
///   staat op deze Mac uit — `KeyboardBacklight.canPostEvents` is `false`.
/// * De klepmelding kan tot tien seconden te laat komen (`ClamshellMonitor` heeft naast de
///   IOKit-melding een poll van 10 s, omdat die melding op deze hardware niet betrouwbaar
///   bleek). Tegen die tijd is "hield je Option ingedrukt?" niet meer te beantwoorden.
///
/// Vooraf zeggen wat je wilt kan nooit per ongeluk afgaan, kost geen enkele toestemming, en
/// is in het paneel te laten zien met een aftellende geldigheid.
///
/// **Staat met opzet niet in `Prefs`.** Een gewapende toestand die een herstart overleeft
/// gaat uren later af zonder dat iemand dat nog verwacht — precies het soort verrassing dat
/// deze app nooit mag geven. Vijf minuten, en daarna vervalt hij vanzelf mét een regel in het
/// logboek, zodat "hij deed niets" nooit stil is.
struct LidArm: Equatable {

    /// Hoe lang een arming geldig blijft. Kort met opzet: dit hoort te gaan over het
    /// dichtklappen dat je nú van plan bent, niet over dat van vanavond.
    static let geldigheid: TimeInterval = 5 * 60

    let gewapendOp: Date
    let verlooptOp: Date

    init(nu: Date = Date()) {
        gewapendOp = nu
        verlooptOp = nu.addingTimeInterval(Self.geldigheid)
    }

    func isVerlopen(op nu: Date) -> Bool { nu >= verlooptOp }

    /// Hoeveel er nog over is, voor de regel in het paneel. Naar boven afgerond, want
    /// "nog 0 minuten" terwijl er nog veertig seconden staan leest als "te laat".
    func resterendeTekst(op nu: Date) -> String {
        let seconden = Int(verlooptOp.timeIntervalSince(nu).rounded(.up))
        if seconden <= 0 { return "verlopen" }
        if seconden < 60 { return "nog \(seconden) s" }
        return "nog \((seconden + 59) / 60) min"
    }
}
