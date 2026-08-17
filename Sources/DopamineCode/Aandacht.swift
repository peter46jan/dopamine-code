import Foundation

/// De waarschuwingen van het paneel, op ernst geordend.
///
/// Nu zijn het vier losse `if`-blokken in `MenuView` die niets van elkaar weten, zodat er in
/// het slechtste geval zes gekleurde vakken onder elkaar staan — allemaal even luid, dus
/// niets luid. Hier is het één lijst met een vaste rangorde.
///
/// Dit type kent de meldingen niet die het ordent: het krijgt een soort en een kant-en-klare
/// zin. Dat is met opzet. Zou het `ConflictWatch.Conflict` en `SleepWatch.Episode` kennen,
/// dan sleept het de halve app zijn proef in en is de rangorde niet meer los te testen.
struct Aandacht {

    enum Ernst {
        case rood      // er moet nu iets gebeuren
        case oranje    // het werkt niet zoals bedoeld
        case grijs     // verslag, geen probleem
    }

    /// De volgorde staat vast en is de volgorde uit het ontwerpdocument. Wie hier iets
    /// tussenvoegt, verandert wat er bovenaan het paneel komt te staan.
    enum Soort: CaseIterable {
        case vangnettenUit        // de vlag staat aan en er is niets meer dat hem terugzet
        case belofteGebroken      // de Mac heeft geslapen terwijl wij hem vasthielden
        case conflictDeeltVlag    // een andere app schrijft dezelfde vlag
        case laatsteMelding       // een handeling die mislukte of iets meldde
        case geenToestemming      // zonder de sudoers-regel werkt er niets
        case conflict             // een andere app houdt de Mac op zijn eigen manier wakker
        case wasGeslapen          // geslapen, maar de vlag stond niet aan: dat hoort te kunnen
        case storingen            // netwerkonderbrekingen, verslag achteraf
        case updateBeschikbaar
        case updateMededeling

        var rangorde: Int {
            switch self {
            case .vangnettenUit:     return 1
            case .belofteGebroken:   return 2
            case .conflictDeeltVlag: return 3
            case .laatsteMelding:    return 4
            case .geenToestemming:   return 5
            case .conflict:          return 6
            case .wasGeslapen:       return 7
            case .storingen:         return 8
            case .updateBeschikbaar: return 9
            case .updateMededeling:  return 10
            }
        }

        var ernst: Ernst {
            switch self {
            case .vangnettenUit, .belofteGebroken, .conflictDeeltVlag:
                return .rood
            case .laatsteMelding, .geenToestemming, .conflict, .wasGeslapen:
                return .oranje
            case .storingen, .updateBeschikbaar, .updateMededeling:
                return .grijs
            }
        }
    }

    struct Melding {
        let soort: Soort
        let tekst: String
    }

    let lijst: [Melding]

    init(meldingen: [Melding]) {
        lijst = meldingen.sorted { $0.soort.rangorde < $1.soort.rangorde }
    }

    /// De ernstigste melding — wat er in de ingeklapte rij komt te staan.
    var kop: Melding? { lijst.first }

    var telling: Int { lijst.count }

    /// Rood klapt altijd uit. Rood is de toestand waarin iemand iets moet doen, en die achter
    /// een driehoekje verstoppen is precies de fout die dit ontwerp moest oplossen.
    var moetOpen: Bool { lijst.contains { $0.soort.ernst == .rood } }
}
