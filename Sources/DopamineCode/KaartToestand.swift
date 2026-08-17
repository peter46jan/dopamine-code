import Foundation

/// De drie toestanden van de statuskaart, in één type.
///
/// Nu leidt het paneel dit af uit vier losse eigenschappen verspreid over de body, en het
/// armen staat als losse tekstlink bóven de duurkiezer — een regel die soms verschijnt en
/// soms niet, op een plek waar niets anders over de toestand gaat. Hier is het één vraag met
/// één antwoord, en de rangorde ligt vast in plaats van in de volgorde van een paar `if`s.
struct KaartToestand {

    enum Fase {
        case uit
        case gearmd
        case aan
    }

    let fase: Fase

    /// Waar de boog staat, 0…1. Nul als er niets af te tellen valt.
    let voortgang: Double

    var isUit: Bool { fase == .uit }
    var isGearmd: Bool { fase == .gearmd }
    var isAan: Bool { fase == .aan }

    init(intendedOn: Bool, armTot: Date?, sessieStart: Date?, deadline: Date?, nu: Date) {

        // Een lopende sessie wint altijd. Staat er ook nog een arming open, dan is die niet
        // meer het nieuws — de Mac is al wakker.
        if intendedOn {
            fase = .aan
            if let deadline {
                if let sessieStart, deadline > sessieStart {
                    let totaal = deadline.timeIntervalSince(sessieStart)
                    let verstreken = nu.timeIntervalSince(sessieStart)
                    voortgang = min(max(verstreken / totaal, 0), 1)
                } else {
                    voortgang = 0
                }
            } else {
                // Geen deadline betekent niet "bijna klaar". Een volle boog zou dat zeggen.
                voortgang = 0
            }
            return
        }

        // Een arming die al verlopen is, is geen arming meer. Zonder deze controle bleef de
        // kaart "wacht op de klep" tonen bij iets wat nooit meer afgaat.
        if let armTot, armTot > nu {
            fase = .gearmd
            voortgang = 0
            return
        }

        fase = .uit
        voortgang = 0
    }
}
