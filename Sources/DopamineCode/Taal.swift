import Foundation

/// In welke taal de app draait, en hoe je dat verandert.
///
/// Schrijft `AppleLanguages` in het eigen voorkeurendomein. Dat is geen eigen uitvinding maar
/// exact wat Systeeminstellingen → Taal en regio → Apps doet: Foundation leest die sleutel uit
/// het domein van de app en laat hem voorgaan op de systeemvolgorde. Deze kiezer is dus een
/// tweede knop op dezelfde schakelaar, niet een parallel mechanisme dat ermee kan botsen.
///
/// De taal wisselt pas bij de volgende start. De bundel kiest zijn `.lproj` één keer, bij het
/// opstarten, en alle `Text("sleutel")` in SwiftUI zoeken rechtstreeks in `Bundle.main`. Dat
/// halverwege omgooien zou betekenen dat élke tekst in de app langs een eigen laag moet — een
/// paar honderd aanroepen, om iets te repareren wat één herstart ook oplost.
///
/// Er zit met opzet geen herstartknop bij. Afsluiten roept `AppModel.shutdown()` aan en die
/// zet de slaapblokkade terug: een herstart midden in een sessie zou het wakker houden
/// beëindigen, precies waar de app voor bestaat. En zichzelf terugstarten kan alleen met een
/// los proces dat op het afsluiten wacht — een nieuw uitvoerpad in een app die er een
/// security-audit over heeft liggen. Een keuze die pas bij de volgende start ingaat is dat
/// niet waard.
enum Taal: String, CaseIterable, Identifiable {
    /// Geen eigen voorkeur: volg de taalvolgorde van macOS.
    case systeem
    case nl
    case en
    case de
    case fr

    var id: String { rawValue }

    /// De naam in de taal zelf. Bewust niet vertaald: een Franse gebruiker die deze lijst
    /// opent zoekt "Nederlands", niet "néerlandais" — zo staat het ook in Systeeminstellingen.
    var naam: String {
        switch self {
        case .systeem: return L10n.t("taal.systeem")
        case .nl: return "Nederlands"
        case .en: return "English"
        case .de: return "Deutsch"
        case .fr: return "Français"
        }
    }

    /// Wat er nu in de voorkeuren staat — niet wat de app op dit moment tóónt.
    ///
    /// Die twee lopen na een wijziging uiteen tot de volgende start, en dat is precies wat de
    /// kiezer moet laten zien: je keuze, met de mededeling dat hij nog niet actief is.
    static var gekozen: Taal {
        // Alleen het eigen domein, niet `UserDefaults.standard.array(forKey:)`. Die zoekt óók
        // NSGlobalDomain af, en daar staat `AppleLanguages` altijd — de taalvolgorde van het
        // systeem. Zonder eigen keuze zou de kiezer dan de systeemtaal aanwijzen in plaats van
        // "systeemtaal volgen", en één klik ergens anders in de lijst zou die taal vastzetten
        // zonder dat iemand daarom vroeg.
        guard let id = Bundle.main.bundleIdentifier,
              let domein = UserDefaults.standard.persistentDomain(forName: id),
              let lijst = domein["AppleLanguages"] as? [String],
              let eerste = lijst.first
        else { return .systeem }
        return Taal(code: eerste) ?? .systeem
    }

    /// De taal waarin de app op dít moment draait, zoals de bundel hem gekozen heeft.
    static var actief: Taal {
        Taal(code: Bundle.main.preferredLocalizations.first ?? "nl") ?? .nl
    }

    // Hier stond een `naHerstart` die moest voorspellen welke taal er na een herstart zou
    // draaien, zodat de kiezer kon zeggen "je keuze is nog niet actief". Weggehaald, want de
    // voorspelling klopte niet.
    //
    // Hij gebruikte `Bundle.preferredLocalizations(from:forPreferences:)`. Die geeft bij een
    // systeemtaal die niet in de bundel zit "en" terug — gemeten met een tabel proefgevallen.
    // De echte bundel doet iets anders: die valt terug op `CFBundleDevelopmentRegion`, dus op
    // Nederlands. Ook gemeten, door de app met AppleLanguages op es-ES en op ja te starten en
    // te kijken wat er uit kwam. Twee verschillende antwoorden op dezelfde vraag, en het
    // antwoord dat telt is dat van de bundel.
    //
    // De kiezer bepaalt nu op een andere manier of er een melding hoort te staan; zie
    // `SettingsView.taalSection`. Voorspellen wat een herstart oplevert hoeft daar niet voor.

    /// Een taalcode kan een regio bevatten ("en-GB", "fr-CA"); alleen het deel ervoor telt.
    private init?(code: String) {
        let kaal = code.split(separator: "-").first.map(String.init) ?? code
        self.init(rawValue: kaal)
    }

    /// Legt de keuze vast. Gaat in bij de volgende start.
    static func kies(_ taal: Taal) {
        let d = UserDefaults.standard
        switch taal {
        case .systeem:
            // Verwijderen en niet leegmaken: een lege array is een geldige voorkeur die
            // "geen enkele taal" betekent, en daar valt Foundation op terug in plaats van
            // op het systeem.
            d.removeObject(forKey: "AppleLanguages")
        default:
            d.set([taal.rawValue], forKey: "AppleLanguages")
        }
        EventLog.shared.info("Taalkeuze gezet op \(taal.rawValue); gaat in bij de volgende start.")
    }
}
