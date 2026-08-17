import Foundation

/// De waarschuwingen van het paneel, op ernst geordend.
///
/// Nu zijn het vier losse `if`-blokken in `MenuView` die niets van elkaar weten, zodat er in
/// het slechtste geval zes gekleurde vakken onder elkaar staan — allemaal even luid, dus
/// niets luid. Hier is het één lijst met een vaste rangorde.
///
/// Dit type kent de meldingen niet die het ordent: het krijgt een soort en een kant-en-klare
/// zin. Dat is met opzet. Zou het `SleepWatch.Episode` kennen, dan sleept het de halve app
/// zijn proef in en is de rangorde niet meer los te testen.
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
        // `AppModel.status` staat op `.error`. Twintig plekken zetten dat, en het paneel las
        // het nergens meer — de kaart zei dan "Slaapt normaal" terwijl de app wist dat er iets
        // mis was. De ergste: de kernelvlag is onleesbaar. De code faalt daar dicht ("failing
        // open here would silently disable all three"); de weergave deed dat niet.
        case foutstatus
        // De wachter heeft te lang niet gekeken. De stip werd hier al rood van, maar er kwam
        // geen melding bij — dus de rij klapte niet open en de telling zag hem niet. Bij een
        // grijze storing van gisteren als enige andere melding stond díe dan bovenaan terwijl
        // het enige vangnet dat een SIGKILL overleeft stil was.
        case wachterStil
        case belofteGebroken      // de Mac heeft geslapen terwijl wij hem vasthielden
        case laatsteMelding       // een handeling die mislukte — `status.isError`
        case geenToestemming      // zonder de sudoers-regel werkt er niets
        case wasGeslapen          // geslapen, maar de vlag stond niet aan: dat hoort te kunnen
        case storingen            // netwerkonderbrekingen, verslag achteraf
        // Dezelfde `lastMessage`, maar zonder foutstatus: "opgeruimd", "staat al aan". Een
        // aparte soort en niet dezelfde in een andere kleur, omdat `ernst` per soort vastligt
        // — en dat is met opzet: wat er bovenaan komt te staan mag niet per geval verschillen.
        case laatsteMededeling
        case updateBeschikbaar
        case updateMededeling

        var rangorde: Int {
            switch self {
            case .vangnettenUit:      return 1
            case .foutstatus:         return 2
            case .wachterStil:        return 3
            case .belofteGebroken:    return 4
            case .laatsteMelding:     return 5
            case .geenToestemming:    return 6
            case .wasGeslapen:        return 7
            case .storingen:          return 8
            case .laatsteMededeling:  return 9
            case .updateBeschikbaar:  return 10
            case .updateMededeling:   return 11
            }
        }

        var ernst: Ernst {
            switch self {
            case .vangnettenUit, .foutstatus, .wachterStil, .belofteGebroken:
                return .rood
            case .laatsteMelding, .geenToestemming, .wasGeslapen:
                return .oranje
            case .storingen, .laatsteMededeling, .updateBeschikbaar, .updateMededeling:
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
