import Foundation

/// Kijkt of er een nieuwere versie op GitHub staat. En verder niets.
///
/// Dat "verder niets" is hier geen bescheidenheid maar een ontwerpeis. Deze app heeft een
/// wachtwoordloze root-route — de sudoers-regel voor `pmset` — en daarmee is elk kanaal
/// waarlangs iets van buiten binnenkomt de moeite van het aanvallen waard. Dit bestand
/// houdt zich daarom aan één regel: uit het antwoord van GitHub komen twee dingen, een
/// versienummer en een URL, en die worden alleen getóónd. Er wordt niets gedownload,
/// niets weggeschreven, niets uitgevoerd. Er is geen pad van een HTTP-antwoord naar code
/// die draait.
///
/// `verify.sh` controleert dat met een grep op `Process`, `pmset`, `SleepFlag` en
/// schrijvende bestandsaanroepen in dit bestand, zodat de regel afdwingbaar is en niet
/// alleen opgeschreven.
@MainActor
final class UpdateCheck: ObservableObject {

    static let shared = UpdateCheck()

    enum Toestand: Equatable {
        /// Nog niet gekeken, of niet te zeggen — bijvoorbeeld omdat deze build geen
        /// versienummer draagt (uit een ZIP gebouwd, zonder git).
        case onbekend
        case actueel
        case beschikbaar(versie: Version, notities: URL?)
    }

    @Published private(set) var toestand: Toestand = .onbekend
    @Published private(set) var bezig = false

    /// De versie van deze build, uit de Info.plist die `build.sh` stempelt.
    ///
    /// `nil` als daar `0.0.0` staat: dat is wat `build.sh` invult wanneer er geen git-tag
    /// te vinden was. Zonder eigen versie is vergelijken zinloos, en dan zegt de app dat
    /// ook in plaats van te doen alsof.
    let huidige: Version?

    /// De volledige `git describe` van deze build, puur om te tonen. `onbekend` als de
    /// bron geen git-gegevens had.
    let bron: String

    private static let endpoint = URL(string:
        "https://api.github.com/repos/peter46jan/dopamine-code/releases/latest")!

    /// Hooguit één keer per etmaal. Anoniem mag je 60 verzoeken per uur per IP doen, dus
    /// dit zit ruim binnen de marge — ook als je de app tien keer per dag herstart.
    private static let interval: TimeInterval = 24 * 60 * 60

    private var timer: Timer?

    private init() {
        let kort = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let ruw = Version(kort ?? "")
        huidige = (ruw?.onderdelen == [0, 0, 0]) ? nil : ruw
        bron = Bundle.main.object(forInfoDictionaryKey: "DCSourceVersion") as? String ?? "onbekend"
    }

    // MARK: - Aansturing

    /// Bij het starten van de app. Kijkt meteen als er lang genoeg niet gekeken is, en
    /// daarna elke zes uur opnieuw — waarbij het etmaal-slot het echte werk doet.
    func start() {
        controleerIndienNodig()
        timer = Timer.scheduledTimer(withTimeInterval: 6 * 60 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.controleerIndienNodig() }
        }
    }

    func controleerIndienNodig() {
        guard Prefs.updateCheckEnabled else { return }
        if let laatst = Prefs.updateLastCheck, Date().timeIntervalSince(laatst) < Self.interval {
            return
        }
        haalOp(handmatig: false)
    }

    /// De knop in Instellingen. Negeert het etmaal-slot, maar niet de schakelaar: staat de
    /// controle uit, dan is één druk op de knop een expliciete vraag en dus toegestaan.
    func controleerNu() {
        haalOp(handmatig: true)
    }

    // MARK: - Het verzoek

    private func haalOp(handmatig: Bool) {
        guard !bezig else { return }
        bezig = true

        var verzoek = URLRequest(url: Self.endpoint)
        verzoek.timeoutInterval = 15
        verzoek.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        verzoek.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        // GitHub weigert verzoeken zonder User-Agent. Alleen de app en zijn versie; geen
        // machinenaam, geen gebruikersnaam, niets wat naar één Mac te herleiden is.
        verzoek.setValue("DopamineCode/\(huidige.map(String.init(describing:)) ?? "onbekend")",
                         forHTTPHeaderField: "User-Agent")

        URLSession.shared.dataTask(with: verzoek) { [weak self] data, antwoord, fout in
            Task { @MainActor in
                self?.verwerk(data: data, antwoord: antwoord, fout: fout, handmatig: handmatig)
            }
        }.resume()
    }

    private func verwerk(data: Data?, antwoord: URLResponse?, fout: Error?, handmatig: Bool) {
        bezig = false
        Prefs.updateLastCheck = Date()

        // Een mislukte updatecontrole is geen probleem van de gebruiker. Het gaat naar het
        // logboek en verder gebeurt er niets: geen melding, geen rode tekst in het menu,
        // geen herhaalpoging die het netwerk bezig houdt. Over zes uur is er een nieuwe kans.
        if let fout {
            EventLog.shared.info("Updatecontrole mislukte: \(fout.localizedDescription)")
            return
        }
        guard let http = antwoord as? HTTPURLResponse else { return }
        guard http.statusCode == 200 else {
            EventLog.shared.info("Updatecontrole gaf status \(http.statusCode).")
            return
        }
        guard let data,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            EventLog.shared.info("Updatecontrole gaf een antwoord dat geen JSON-object was.")
            return
        }

        guard let tag = json["tag_name"] as? String, let laatste = Version(tag) else {
            EventLog.shared.info("Updatecontrole: tag_name is geen versienummer.")
            return
        }

        let notities = veiligeNotitieURL(json["html_url"])

        guard let huidige else {
            // Deze build weet niet welke versie hij is. Dan is "er is 1.3.0" het enige
            // eerlijke antwoord — of dat nieuwer is dan wat hier draait, valt niet te zeggen.
            toestand = .beschikbaar(versie: laatste, notities: notities)
            return
        }

        if laatste > huidige {
            toestand = .beschikbaar(versie: laatste, notities: notities)
            if handmatig || Prefs.updateLastSeenVersion != laatste.description {
                EventLog.shared.info("Versie \(laatste) beschikbaar; deze build is \(huidige).")
            }
            Prefs.updateLastSeenVersion = laatste.description
        } else {
            toestand = .actueel
        }
    }

    /// Laat alleen een `https`-URL op github.com door.
    ///
    /// De URL komt uit een HTTP-antwoord en eindigt in `NSWorkspace.open`. Zonder deze
    /// controle zou een vervalst of gekaapt antwoord de app een willekeurige pagina laten
    /// openen — en "mijn wakkerhoud-app opende uit zichzelf een site" is precies het begin
    /// van een geloofwaardige phishing-stap. Voldoet de URL niet, dan verdwijnt alleen de
    /// knop; het versienummer blijft gewoon zichtbaar.
    private func veiligeNotitieURL(_ ruw: Any?) -> URL? {
        guard let tekst = ruw as? String,
              let url = URL(string: tekst),
              url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased(),
              host == "github.com" || host == "www.github.com"
        else { return nil }
        return url
    }
}
