import Foundation

/// Het vangnet voor de enige manier waarop de app nog kan verdwijnen zonder iets op te ruimen.
///
/// `SIGTERM`, `SIGINT`, `SIGHUP` en het uitschakelen van het systeem worden allemaal
/// afgevangen: die zetten de slaapblokkade terug vóórdat het proces weg is. `SIGKILL` niet —
/// dat kán niet afgevangen worden. Het proces is weg, de blokkade staat aan, en niets ruimt
/// hem op tot de app een keer opnieuw start. Klep dicht en weglopen betekent in die toestand:
/// wakker tot de accu leeg is, met de tijdslimiet, de accugrens én de temperatuurbewaking
/// dood.
///
/// **Wat hier staat.** Een LaunchAgent in `~/Library/LaunchAgents` die elke 30 seconden
/// dezelfde app-binary start met het argument `--vangnet`. Die wachter leest de kernel, kijkt
/// of er nog een app draait, en doet hooguit één ding: de app opnieuw starten. Hij ruimt zelf
/// niets op. Dat blijft het werk van `clearStaleFlagAtStartup()` en de guardian, want die twee
/// weten wat een lopende sessie is en deze wachter met opzet niet — hij houdt geen enkele
/// sessiestand bij en mag dat ook nooit gaan doen.
///
/// **Waarom geen `KeepAlive` op de app zelf.** `KeepAlive` werkt alleen voor processen die
/// launchd zélf gestart heeft. Deze app wordt gestart door `open` (build.sh), door de Finder,
/// of via `SMAppService`; in al die gevallen kent launchd het proces niet en herstart hij
/// niets. Een losse wachter werkt ongeacht hoe de app gestart is, en laat de LaunchAgent van
/// `LaunchAtLogin` met rust.
///
/// **Hoe "bewust afgesloten" van "weggevallen" onderscheiden wordt.** In de kern door de
/// kernel zelf: elke bewuste route zet de blokkade eerst terug, dus een nette afsluiting laat
/// een 0 achter en `kill -9` laat een 1 achter. Voor het enige dubbelzinnige geval — bewust
/// afsluiten waarbij het terugzetten mislukte — laat de app een markering achter met tijdstip,
/// reden en de stand van de blokkade. Die markering kan een herstart hooguit twee minuten
/// uitstellen, en alleen onderdrukken als de blokkade aantoonbaar uit stond. Meer niet: een
/// markering die een herstart onbeperkt tegenhoudt terwijl de Mac wakker blijft, zet het gat
/// waar dit hele bestand voor bestaat gewoon door een andere deur weer open.
enum RestartGuard {

    // MARK: - Namen, paden en getallen

    /// Komt in een plist die blijft staan; niet meer wijzigen zonder de oude uit te laden.
    static let label = "com.peter46jan.dopaminecode.watchdog"

    /// Draait deze binary als wachter in plaats van als app?
    static let watchdogArgument = "--vangnet"
    /// Meegegeven aan de app die door de wachter teruggehaald wordt, zodat hij hardop kan
    /// zeggen wat er gebeurd is in plaats van te doen alsof hij gewoon opstartte.
    static let restartedArgument = "--vangnet-herstart"

    /// Hoe vaak launchd de wachter wakker maakt. Twee bevestigingen van 30 seconden uit
    /// elkaar geven een venster van hooguit ~70 seconden; naar buiten beloven we "binnen twee
    /// minuten".
    private static let intervalSeconds = 30
    /// Eén ronde is niet genoeg. `build.sh --install` sluit de app af, vervangt de bundel en
    /// start hem opnieuw; wie na één waarneming al ingrijpt start precies daar middenin.
    private static let requiredConfirmations = 2
    /// Respijt na een bewuste afsluiting waarbij de blokkade nog aan stond.
    private static let deliberateExitGrace: TimeInterval = 120
    /// Eerste wachttijd tussen twee herstarts, daarna verdubbelend. Crasht de app meteen bij
    /// het starten terwijl de blokkade aan staat, dan zou een wachter zonder rem eindeloos
    /// processen spawnen — dezelfde vorm als de backoff in `attemptRelease`.
    private static let firstBackoff: TimeInterval = 600
    private static let maxBackoff: TimeInterval = 3600
    /// Na hoeveel seconden zonder resultaat de open-route opgegeven wordt. Twee rondes.
    private static let escalateAfter: TimeInterval = 55

    /// Dezelfde map als het besturingskanaal (0700, alleen van deze gebruiker). Eén plek waar
    /// de app zijn kleine bestanden neerzet, in plaats van twee die uit elkaar kunnen lopen.
    private static var supportDirectory: URL { ControlChannel.directoryURL }
    private static var exitMarkerURL: URL { supportDirectory.appendingPathComponent("afsluiting.json") }
    private static var stateURL: URL { supportDirectory.appendingPathComponent("vangnet-status.json") }

    private static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    /// Exact vergelijken, niet met `hasPrefix`: `--vangnet-herstart` begint met `--vangnet`,
    /// en een app die zichzelf voor een wachter aanziet start nooit zijn menubalk.
    static var shouldRunAsWatchdog: Bool { CommandLine.arguments.contains(watchdogArgument) }

    /// Of deze app door de wachter is teruggehaald. Eén keer bepaald: de argumenten van een
    /// proces veranderen niet meer.
    static let broughtBackByWatchdog = CommandLine.arguments.contains(restartedArgument)

    // MARK: - Wat er op schijf staat

    /// Wat de app achterlaat als hij bewust weggaat.
    private struct ExitMarker: Codable {
        var tijdstip: Date
        var reden: String
        /// De stand van de slaapblokkade op het moment van afsluiten. Dit is het enige veld
        /// dat een herstart kan tegenhouden, en alleen als het `false` is.
        var blokkadeStondAan: Bool
    }

    /// Wat de wachter zelf onthoudt.
    ///
    /// Met opzet geen enkel woord over sessies: geen begintijd, geen eindtijd, geen duur, geen
    /// gekoppeld proces. Een tweede boekhouding over "loopt er iets" is precies het defect
    /// waar dit ontwerp uit voortkomt. Wat hier staat gaat alleen over de wachter zelf.
    private struct WatchState: Codable {
        var laatsteRonde: Date?
        /// Wat hij de vorige keer concludeerde, in gewone taal, voor Diagnose en `verify.sh`.
        var laatsteMelding: String?
        var bevestigingen = 0
        var laatsteHerstart: Date?
        var herstartPogingen = 0
        var escalatieGedaan = false
        /// Het tijdstip van de markering waarover al gewaarschuwd is, zodat "dit is niet van
        /// ons" één regel oplevert en niet één elke 30 seconden.
        var nietVanOnsGemeld: Date?

        init() {}

        /// Met de hand geschreven omdat de standaardwaarden hierboven níet gebruikt worden
        /// door een gesynthetiseerde decoder: een statusbestand van een oudere versie zou dan
        /// onleesbaar zijn, en een onleesbaar bestand betekent een teller die elke ronde op
        /// nul begint en een vangnet dat nooit bij twee bevestigingen komt.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            laatsteRonde = try c.decodeIfPresent(Date.self, forKey: .laatsteRonde)
            laatsteMelding = try c.decodeIfPresent(String.self, forKey: .laatsteMelding)
            bevestigingen = try c.decodeIfPresent(Int.self, forKey: .bevestigingen) ?? 0
            laatsteHerstart = try c.decodeIfPresent(Date.self, forKey: .laatsteHerstart)
            herstartPogingen = try c.decodeIfPresent(Int.self, forKey: .herstartPogingen) ?? 0
            escalatieGedaan = try c.decodeIfPresent(Bool.self, forKey: .escalatieGedaan) ?? false
            nietVanOnsGemeld = try c.decodeIfPresent(Date.self, forKey: .nietVanOnsGemeld)
        }
    }

    /// ISO-8601, zodat `verify.sh` de tijdstempels met `date -j` kan lezen zonder dat er een
    /// tweede afspraak over het formaat bij komt.
    private static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }

    private static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    private static func klok(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: date)
    }

    // MARK: - De afsluitmarkering

    /// Legt vast dat de app bewust wegging. Synchroon, want hierna volgt een `exit`.
    ///
    /// De stand van de blokkade wordt hier vers gelezen en niet meegegeven: dan staat er per
    /// definitie wat de kernel op dát moment zei, en niet wat een aanroeper een paar regels
    /// eerder dacht. `!= false` zoals overal op de afsluitpaden — onleesbaar is geen "uit".
    static func recordDeliberateExit(reason: String) {
        let stondAan = SleepFlag.read() != false
        let marker = ExitMarker(tijdstip: Date(), reden: reason, blokkadeStondAan: stondAan)
        do {
            try FileManager.default.createDirectory(
                at: supportDirectory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try encoder.encode(marker).write(to: exitMarkerURL, options: .atomic)
        } catch {
            EventLog.shared.error(
                "De afsluitmarkering kon niet weggeschreven worden (\(error.localizedDescription)). "
                + "Het vangnet kan dit afsluiten straks niet van wegvallen onderscheiden en haalt "
                + "de app mogelijk terug."
            )
        }
    }

    /// Leest de markering, gooit hem weg en geeft terug wat erin stond.
    ///
    /// Weggooien hoort bij het starten: vanaf nu is "geen markering" weer wat het moet zijn,
    /// namelijk "deze app is niet netjes afgesloten".
    static func clearExitMarkerAtStartup() -> String? {
        guard let data = try? Data(contentsOf: exitMarkerURL) else { return nil }
        let marker = try? decoder.decode(ExitMarker.self, from: data)
        do {
            try FileManager.default.removeItem(at: exitMarkerURL)
        } catch {
            EventLog.shared.warn(
                "De afsluitmarkering kon niet weggehaald worden (\(error.localizedDescription)); "
                + "het vangnet kan daardoor een echte wegval voor een nette afsluiting aanzien."
            )
        }
        guard let marker else {
            EventLog.shared.warn("De afsluitmarkering was onleesbaar en is weggegooid.")
            return nil
        }
        return "Vorige afsluiting om \(klok(marker.tijdstip)) (\(marker.reden)); de slaapblokkade stond toen "
            + (marker.blokkadeStondAan ? "nog aan." : "uit.")
    }

    private static func readExitMarker() -> ExitMarker? {
        guard let data = try? Data(contentsOf: exitMarkerURL) else { return nil }
        return try? decoder.decode(ExitMarker.self, from: data)
    }

    // MARK: - De LaunchAgent installeren

    /// Zorgt dat de wachter geïnstalleerd en geladen is. Geeft één zin terug voor Diagnose.
    ///
    /// Wordt bij elke start aangeroepen en niet alleen de eerste keer: een plist die iemand
    /// weggooit of een bundel die verhuist, moet zichzelf herstellen. Een vangnet dat er stil
    /// niet meer is, is erger dan geen vangnet.
    @discardableResult
    static func ensureInstalled(force: Bool = false) -> String {
        let bundle = Bundle.main.bundleURL
        guard let executable = Bundle.main.infoDictionary?["CFBundleExecutable"] as? String else {
            EventLog.shared.error("Het vangnet kon niet ingesteld worden: CFBundleExecutable ontbreekt in de bundel.")
            return "niet ingesteld — de bundel mist CFBundleExecutable"
        }
        let binary = bundle.appendingPathComponent("Contents/MacOS/\(executable)").path

        // Een agent die naar ./build/Dopamine Code.app wijst verdwijnt bij de volgende
        // ./build.sh en laat een dood label achter dat elke 30 seconden een niet-bestaande
        // binary probeert te starten.
        if bundle.deletingLastPathComponent().lastPathComponent == "build" {
            EventLog.shared.info(
                "Deze kopie draait uit de bouwmap (\(bundle.path)); het vangnet wordt daar niet voor "
                + "ingesteld, want die bundel verdwijnt bij de volgende bouw."
            )
            return "niet ingesteld voor een kopie uit de bouwmap"
        }

        // De types doen ertoe, en dat is hier gemeten. Schrijf je deze plist met de hand in de
        // oude ASCII-vorm, dan worden `true` en `30` strings — die vorm kent geen booleans en
        // geen getallen — en negeert launchd `RunAtLoad` en `StartInterval` zonder één woord.
        // De agent staat er dan wel, is "enabled", en draait nooit. Aan `launchctl print` zie
        // je het: zonder de regel `run interval` is er geen tijdklok. Vandaar dat dit een
        // Swift-dictionary is die door `PropertyListSerialization` gaat, en geen tekstsjabloon.
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [binary, watchdogArgument],
            "RunAtLoad": true,
            "StartInterval": intervalSeconds,
            // Bewust GEEN KeepAlive: launchd zou dan de wachter zelf aan de praat houden, en
            // dat is niet wat er bewaakt moet worden.
            "ProcessType": "Background",
            "LimitLoadToSessionType": "Aqua",
            // Zonder dit ruimt launchd bij het einde van een ronde alles op wat de wachter
            // achterliet — en dat is in de terugvalroute juist de app die net gestart is.
            "AbandonProcessGroup": true,
        ]

        let bestaand = (try? Data(contentsOf: plistURL))
            .flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) } as? [String: Any]
        let gelijk = bestaand.map { NSDictionary(dictionary: $0).isEqual(to: plist) } ?? false

        if gelijk && !force && isLoaded() {
            return statusSentence()
        }

        do {
            try FileManager.default.createDirectory(
                at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try data.write(to: plistURL, options: .atomic)
        } catch {
            EventLog.shared.error("Het vangnet kon niet geschreven worden: \(error.localizedDescription)")
            return "niet ingesteld — \(error.localizedDescription)"
        }

        // Opnieuw bootstrappen van een geladen label geeft "Operation not permitted", dus
        // eerst uitladen — behalve als dit proces zelf uit die taak komt. Dat kan: de
        // terugvalroute start de app rechtstreeks vanuit de wachter, en die erft
        // XPC_SERVICE_NAME. `launchctl bootout` zou de app dan afsluiten om zijn eigen
        // vangnet te installeren. Dezelfde constructie als in `LaunchAtLogin`, om dezelfde
        // reden.
        if !startedByWatchdogJob {
            Shell.run("/bin/launchctl", ["bootout", "gui/\(getuid())/\(label)"])
        }
        let result = Shell.run("/bin/launchctl", ["bootstrap", "gui/\(getuid())", plistURL.path])
        guard result.ok else {
            // Eén geval waarin dit geen ramp is: de taak stond al geladen en kon niet uitgeladen
            // worden omdat dit proces er zelf uit voortkomt. Dan draait de oude versie van de
            // wachter gewoon door en pakt de nieuwe plist bij de volgende keer inloggen. Dat is
            // een waarschuwing, geen fout — een foutregel die zegt dat er geen vangnet meer is
            // terwijl het er wel is, is net zo misleidend als andersom.
            if isLoaded() {
                EventLog.shared.warn(
                    "De nieuwe instellingen van het vangnet konden niet meteen geladen worden "
                    + "(\(result.combined)); de wachter die al draait blijft voorlopig aan het werk."
                )
                return statusSentence()
            }
            EventLog.shared.error(
                "Het vangnet kon niet geladen worden (launchctl bootstrap: \(result.combined)). "
                + "Een kill -9 van deze app blijft dan onopgemerkt."
            )
            return "NIET geladen — launchctl weigerde: \(result.combined)"
        }
        EventLog.shared.info("Vangnet geladen: \(label), kijkt elke \(intervalSeconds) seconden.")
        return statusSentence()
    }

    /// `launchctl` zet XPC_SERVICE_NAME op het label van de taak die een proces startte.
    private static var startedByWatchdogJob: Bool {
        ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"]?.contains(label) == true
    }

    private static func isLoaded() -> Bool {
        Shell.run("/bin/launchctl", ["print", "gui/\(getuid())/\(label)"], timeout: 10).ok
    }

    /// Hoe lang geleden de wachter voor het laatst keek. `nil` betekent: nog nooit.
    ///
    /// Alleen een bestandslezing, geen `launchctl`: dit wordt vanuit de guardian aangeroepen en
    /// daar hoort geen subproces te staan.
    static func timeSinceLastRound() -> TimeInterval? {
        readState().laatsteRonde.map { Date().timeIntervalSince($0) }
    }

    /// Wat Diagnose en `verify.sh` laten zien: draait hij, en wanneer keek hij voor het laatst.
    static func statusSentence() -> String {
        let state = readState()
        let staat = isLoaded() ? "geladen" : "NIET geladen"
        guard let ronde = state.laatsteRonde else { return "\(staat), nog niet gekeken" }
        let seconden = max(Int(Date().timeIntervalSince(ronde)), 0)
        let ouderdom = seconden < 120 ? "\(seconden) s geleden" : "\(seconden / 60) min geleden"
        return "\(staat), keek \(ouderdom)" + (state.laatsteMelding.map { " — \($0)" } ?? "")
    }

    // MARK: - De ronde

    /// Eén ronde van de wachter, en daarna weg. Raakt AppKit niet aan en start geen app-object:
    /// dit proces is geen app, het is een controle van vier stappen.
    static func runWatchdogAndExit() -> Never {
        watchdogRound()
        // `EventLog.log` schrijft asynchroon en `exit` gooit de wachtrij weg. Juist de regels
        // van deze ronde verklaren waarom de app wel of niet teruggehaald is.
        EventLog.shared.flush()
        exit(0)
    }

    private static func watchdogRound() {
        var state = readState()
        state.laatsteRonde = Date()
        var melding = "onafgemaakte ronde"
        // Ook als er verder niets gebeurt wordt de tijdstempel weggeschreven: een wachter die
        // stilletjes niet meer draait moet zichtbaar zijn in Diagnose en in verify.sh.
        defer {
            state.laatsteMelding = melding
            writeState(state)
        }

        // Onleesbaar telt als "aan", net als op elk ander afsluitpad in deze app: van de twee
        // manieren om ernaast te zitten is "voor niets een keer kijken" de goedkope.
        guard SleepFlag.read() != false else {
            state.bevestigingen = 0
            melding = "de slaapblokkade stond uit"
            return
        }

        if appIsRunning() {
            state.bevestigingen = 0
            // Bleef de app na een herstart een hele backoff-periode overeind, dan werkte die
            // herstart en mag de ladder terug naar nul. Bewust hier en niet bij het starten van
            // de app: een app die meteen weer crasht zou de rem dan zelf opheffen, en dat is
            // precies het geval waarvoor die rem er is.
            if let laatste = state.laatsteHerstart, Date().timeIntervalSince(laatste) > firstBackoff {
                state.laatsteHerstart = nil
                state.herstartPogingen = 0
                state.escalatieGedaan = false
            }
            melding = "de app draait"
            return
        }

        let marker = readExitMarker()

        // Netjes afgesloten mét de blokkade uit, en tóch staat hij nu aan: dan heeft iets
        // anders hem gezet — Amphetamine's Power Protect schrijft naar dezelfde vlag. Die
        // opruimen door onze app te starten zou een andere app in de rug aanvallen.
        if let marker, !marker.blokkadeStondAan {
            if state.nietVanOnsGemeld != marker.tijdstip {
                state.nietVanOnsGemeld = marker.tijdstip
                EventLog.shared.warn(
                    "De Mac wordt wakker gehouden terwijl Dopamine Code om \(klok(marker.tijdstip)) netjes "
                    + "is afgesloten met de blokkade uit (\(marker.reden)). Iets anders houdt hem nu wakker; "
                    + "het vangnet blijft ervan af."
                )
            }
            state.bevestigingen = 0
            melding = "blokkade aan, maar niet van ons"
            return
        }

        state.bevestigingen += 1

        // Bewust afgesloten terwijl het terugzetten mislukte. Even wachten: de gebruiker is
        // waarschijnlijk nog bezig, en build.sh --install vervangt op dit moment de bundel.
        // Daarna komt de app tóch terug — de tijdslimiet, de accugrens en de temperatuur-
        // bewaking zijn er niet zolang er geen app is.
        if let marker, Date().timeIntervalSince(marker.tijdstip) < deliberateExitGrace {
            melding = "respijt na bewust afsluiten (\(state.bevestigingen)×)"
            return
        }

        guard state.bevestigingen >= requiredConfirmations else {
            melding = "blokkade aan zonder app (\(state.bevestigingen)×)"
            return
        }

        guard let executable = Bundle.main.infoDictionary?["CFBundleExecutable"] as? String else {
            EventLog.shared.error("De wachter kan de app niet starten: CFBundleExecutable ontbreekt.")
            melding = "kan de bundel niet lezen"
            return
        }
        let bundle = Bundle.main.bundleURL
        let binary = bundle.appendingPathComponent("Contents/MacOS/\(executable)").path

        // Draait de wachter zelf uit de bouwmap, dan wijst hij naar een bundel die bij de
        // volgende ./build.sh weg is. Zo'n kopie starten is geen vangnet maar een gok.
        guard bundle.deletingLastPathComponent().lastPathComponent != "build" else {
            EventLog.shared.info(
                "De Mac wordt wakker gehouden zonder app, maar deze wachter hoort bij een kopie in de "
                + "bouwmap (\(bundle.path)) en start die niet."
            )
            melding = "kopie uit de bouwmap, niets gestart"
            return
        }

        // Eerst beslissen wát er moet gebeuren, en dan pas de bundel controleren. Andersom zou
        // `codesign` elke 30 seconden een heel uur lang draaien voor een ronde die door de
        // backoff toch niets doet.
        let actie: Actie
        if let laatste = state.laatsteHerstart, !state.escalatieGedaan,
           Date().timeIntervalSince(laatste) >= escalateAfter {
            // Of `open` werkt vanuit een launchd-agent met een vergrendeld scherm en de klep
            // dicht is niet gemeten — en dat is nou net het geval waarvoor dit gebouwd is.
            // Levert het na twee rondes niets op, dan wordt de binary rechtstreeks gestart,
            // zoals de LaunchAgent van `LaunchAtLogin` aantoonbaar wel doet.
            actie = .rechtstreeks(seconden: Int(Date().timeIntervalSince(laatste)))
        } else if let laatste = state.laatsteHerstart,
                  Date().timeIntervalSince(laatste)
                    < min(firstBackoff * pow(2, Double(max(state.herstartPogingen - 1, 0))), maxBackoff) {
            melding = "wachten tot de volgende poging mag"
            return
        } else {
            actie = .open
        }

        // Een halfgekopieerde bundel starten is erger dan even niets doen: build.sh --install
        // doet rm -rf gevolgd door cp -R op /Applications, en daar zit een raampje tussen.
        let handtekening = Shell.run("/usr/bin/codesign", ["--verify", "--strict", bundle.path], timeout: 30)
        guard handtekening.ok else {
            // De regel om het met de hand terug te zetten staat bewust niet in deze zin: dit
            // bestand mag de woorden van het schrijfpad niet bevatten, zodat `verify.sh` met
            // één grep kan aantonen dat de wachter nooit zelf schrijft. Diagnose en de andere
            // foutregels noemen hem wel.
            EventLog.shared.error(
                "De Mac wordt wakker gehouden zonder app, maar de bundel op \(bundle.path) is nu niet "
                + "in orde (\(handtekening.combined)). Er wordt niets gestart. Zet de slaapblokkade zelf "
                + "uit met de regel die in Instellingen → Diagnose staat."
            )
            melding = "bundel niet in orde"
            return
        }

        switch actie {
        case .rechtstreeks(let seconden):
            state.escalatieGedaan = true
            EventLog.shared.warn(
                "De app is \(seconden) seconden na 'open' nog niet terug; de wachter start de binary nu "
                + "rechtstreeks."
            )
            EventLog.shared.flush()
            if spawnDirect(binary) {
                melding = "rechtstreeks gestart"
            } else {
                EventLog.shared.error("Rechtstreeks starten van \(binary) mislukte ook.")
                melding = "rechtstreeks starten mislukte"
            }

        case .open:
            EventLog.shared.error(
                "Dopamine Code is weggevallen terwijl de Mac wakker gehouden werd. Het vangnet haalt de "
                + "app terug; die ruimt de slaapblokkade bij het starten op."
            )
            EventLog.shared.flush()
            let start = Shell.run(
                "/usr/bin/open", ["-g", "-a", bundle.path, "--args", restartedArgument], timeout: 60
            )
            state.laatsteHerstart = Date()
            state.herstartPogingen += 1
            state.escalatieGedaan = false
            state.bevestigingen = 0
            if start.ok {
                melding = "app teruggehaald (poging \(state.herstartPogingen))"
            } else {
                EventLog.shared.error("Terughalen met 'open' mislukte: \(start.combined)")
                melding = "terughalen mislukte"
            }
        }
    }

    /// Wat er deze ronde te doen staat. Twee routes naar hetzelfde: de app terug.
    private enum Actie {
        case open
        case rechtstreeks(seconden: Int)
    }

    /// Draait er nog een échte app naast deze wachter?
    ///
    /// LET OP, dit is de stilste manier waarop dit hele vangnet nooit afgaat: de wachter is
    /// dezelfde binary als de app, dus `pgrep -x DopamineCode` vindt hem ook zelf. Zonder het
    /// eigen `getpid()` eruit te filteren luidt het antwoord altijd "de app draait" en gebeurt
    /// er nooit iets.
    ///
    /// En één laag dieper zit dezelfde val: een teruggehaalde app draait met
    /// `--vangnet-herstart` in zijn argumenten. Wie op de tékst "--vangnet" zoekt in plaats van
    /// op een heel argument, ziet die app aan voor nóg een wachter, concludeert opnieuw "geen
    /// app" en start er elke minuut een bij.
    private static func appIsRunning() -> Bool {
        let executable = Bundle.main.infoDictionary?["CFBundleExecutable"] as? String ?? "DopamineCode"
        let gevonden = Shell.run("/usr/bin/pgrep", ["-x", executable], timeout: 10)
        // pgrep geeft exitcode 1 als er niets matcht; dat is geen fout maar een antwoord.
        guard gevonden.status == 0 else { return false }

        let mij = getpid()
        let pids = gevonden.stdout
            .split(whereSeparator: \.isNewline)
            .compactMap { pid_t($0.trimmingCharacters(in: .whitespaces)) }

        for pid in pids where pid != mij {
            let args = Shell.run("/bin/ps", ["-o", "args=", "-p", "\(pid)"], timeout: 10)
            guard args.ok else {
                // Onzeker, en dan liever niets doen dan een app starten die er al is: er leeft
                // hoe dan ook een DopamineCode-proces, en dat heeft zijn eigen guardian. Wel
                // hardop, want een vangnet dat om deze reden nooit afgaat hoort zichtbaar te
                // zijn in plaats van stil.
                EventLog.shared.warn(
                    "De wachter kon de argumenten van proces \(pid) niet lezen (\(args.combined)) en "
                    + "beschouwt het daarom als de app."
                )
                return true
            }
            let argumenten = args.stdout.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init)
            if !argumenten.contains(watchdogArgument) { return true }
        }
        return false
    }

    /// De terugvalroute als `open` niets oplevert.
    ///
    /// `POSIX_SPAWN_SETSID` is geen sierletsel: zonder een eigen sessie blijft de app een
    /// proces van deze launchd-taak. Launchd ruimt zoiets op zodra de wachter klaar is, en zou
    /// de taak bovendien als "draait nog" blijven zien — waarmee elke volgende ronde van de
    /// wachter overgeslagen wordt en het vangnet zichzelf uitschakelt.
    private static func spawnDirect(_ binary: String) -> Bool {
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID))

        var argumenten: [UnsafeMutablePointer<CChar>?] = [strdup(binary), strdup(restartedArgument), nil]
        defer { for pointer in argumenten where pointer != nil { free(pointer) } }

        var pid: pid_t = 0
        let rc = posix_spawn(&pid, binary, nil, &attr, &argumenten, environ)
        guard rc == 0 else {
            EventLog.shared.error("posix_spawn van \(binary) gaf foutcode \(rc) (\(String(cString: strerror(rc)))).")
            return false
        }
        EventLog.shared.info("De wachter startte de app rechtstreeks als proces \(pid).")
        return true
    }

    // MARK: - Het statusbestand

    private static func readState() -> WatchState {
        guard let data = try? Data(contentsOf: stateURL),
              let state = try? decoder.decode(WatchState.self, from: data)
        else { return WatchState() }
        return state
    }

    private static func writeState(_ state: WatchState) {
        do {
            try FileManager.default.createDirectory(
                at: supportDirectory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try encoder.encode(state).write(to: stateURL, options: .atomic)
        } catch {
            EventLog.shared.error(
                "De wachter kon zijn tijdstempel niet wegschrijven (\(error.localizedDescription)). "
                + "Diagnose en verify.sh kunnen nu niet zien of hij nog kijkt."
            )
        }
    }
}
