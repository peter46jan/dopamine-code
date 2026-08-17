import AppKit
import Combine
import SwiftUI

/// Eén verzoek om een sessie, wie het ook doet.
///
/// Eén waardetype in plaats van vier startfuncties: een volgende fase voegt hier een veld
/// toe in plaats van een tweede weg naar binnen — en een tweede weg naar binnen is een
/// tweede plek waar de accugrens, de warmtegrens of de wachtwoordvrijstelling vergeten kan
/// worden.
struct SessionRequest {
    var trigger: SessionTrigger
    /// `nil` = de duur die in het paneel staat (`Prefs.autoOffMinutes`).
    var limitMinutes: Int? = nil
    /// De sessie stopt zodra dit proces weg is — of eerder, als de timer eerder is.
    var bindToPID: pid_t? = nil
    /// Harde bovengrens, bijvoorbeeld een eindtijd of een schemavenster.
    var notLaterThan: Date? = nil
    /// Waarom die bovengrens er is, in gewone taal, voor de logregel bij het aflopen.
    /// `nil` = de neutrale zin. Fase 3 vult hem met "het schema liep tot 18:00", want
    /// "de sessie liep tot 18:00" laat in het logboek in het midden wíe dat besloot.
    var notLaterThanReason: String? = nil
}

/// Wat er van een verzoek terechtkwam. De weigerzin moet woordelijk doorgegeven kunnen
/// worden aan de opdrachtregel, en een script moet kunnen zien wat het écht kreeg in plaats
/// van te denken dat het meer kreeg.
enum SessionStartResult {
    case gestart(deadline: Date, minuten: Int)
    case liepAl(deadline: Date?)
    case geweigerd(reden: String)
    /// Er was net iets anders bezig met de vlag. Geen fout: probeer het zo weer.
    case bezet
}

/// Single source of truth.
///
/// The central design rule, learned the hard way: **the safety nets key off the kernel
/// flag, never off the app's own status.** If the app thinks it is off but `SleepDisabled`
/// is still 1, the Mac is still refusing to sleep — and that is precisely the situation in
/// which the timers, the battery floor and the thermal cut-out matter most. Anything that
/// keys off `status.isOn` stops watching at the exact moment it is needed.
///
/// So there is one guardian tick that reads the kernel and decides, plus event sources
/// that nudge it. Everything privileged runs off the main thread.
///
/// Alles wat een sessie kan starten — de schakelaar, de opdrachtregel, straks een trigger of
/// een sneltoets — gaat via `startSession(_:)` naar binnen en via `stopSession(reason:)` of
/// `releaseReason()` weer naar buiten. Vier ingangen die elk hun eigen controles nabouwen is
/// vier keer de kans dat er eentje vergeten wordt.
@MainActor
final class AppModel: ObservableObject {

    /// One instance for the whole process. The app delegate needs to reach it at launch
    /// — before any menu has been opened — so that a flag left set by a crashed previous
    /// session is cleared immediately rather than whenever the user first clicks.
    static let shared = AppModel()

    private init() {
        Prefs.registerDefaults()
    }

    // MARK: - Published state

    enum Status: Equatable {
        case off
        case on
        /// The kernel disagrees with what we asked for, or could not be read. Deliberately
        /// distinct from `off` so it can never render as a calm, everything-is-fine icon.
        case error(String)

        var isOn: Bool { if case .on = self { return true }; return false }
        var isError: Bool { if case .error = self { return true }; return false }
    }

    @Published private(set) var status: Status = .off
    /// The kernel's own answer, refreshed by every guardian tick. `nil` means the property
    /// could not be read. The UI reads this rather than calling into IOKit from a view body
    /// that re-evaluates once a second — and it is the honest source for anything that
    /// claims the Mac is or is not allowed to sleep.
    @Published private(set) var kernelFlag: Bool?
    @Published private(set) var grantStatus: SudoersGrant.Status = .missing
    @Published private(set) var battery: PowerSnapshot?
    @Published private(set) var lidClosed = false
    /// Only meaningful while a session is running: nothing watches the network otherwise.
    @Published private(set) var online = true
    @Published private(set) var networkWatched = false
    @Published private(set) var outages: [Outage] = []
    /// Whether `outages` describes the session that is running or the one that ended.
    @Published private(set) var outagesFromFinishedSession = false
    @Published private(set) var deadline: Date?
    @Published private(set) var now = Date()
    @Published private(set) var backlightOn: Bool?
    /// Cached, not read per render. `MenuView`'s body re-evaluates every second because of
    /// the clock tick, and reading these straight from CoreBrightness in the body meant two
    /// IPC round trips per second for as long as the menu stayed open.
    @Published private(set) var backlightLevel: Float?
    @Published private(set) var backlightSuppressed = false
    @Published private(set) var conflict: ConflictWatch.Conflict?
    @Published private(set) var lastMessage: String?
    @Published private(set) var thermal: ThermalWatch.Pressure = .nominal
    /// Onder 100 wordt de Mac door de warmte afgeknepen. Bijgewerkt door de guardian-tik en
    /// niet in de body uitgelezen: `pmset -g therm` kost tot acht seconden, en de body draait
    /// elke seconde door de kloktik.
    @Published private(set) var cpuSpeedLimit: Int?
    /// Hoe lang geleden de wachter voor het laatst keek. Bijgewerkt door de guardian-tik en
    /// niet in de body uitgelezen: `RestartGuard.timeSinceLastRound()` leest en decodeert een
    /// bestand, en de body draait elke seconde door de kloktik.
    @Published private(set) var wachterSinds: TimeInterval?
    @Published private(set) var busy = false

    /// True when the flag is set but the app has no passwordless way to clear it. In that
    /// state no safety net can fire unattended, which the user has to know.
    @Published private(set) var safetyNetsDisarmed = false

    /// Set when the Mac was caught sleeping while we were holding it awake. Survives the end
    /// of the session on purpose: it is the one finding that must still be on screen hours
    /// later, because it means the app's promise does not hold on this machine.
    @Published private(set) var sleepDuringSession: SleepWatch.Episode?
    /// Whether that sleep actually broke the promise — the flag was up — or merely happened
    /// during a session whose flag someone had already cleared from outside. The second is
    /// correct behaviour by the kernel and must not be reported as a failure of the veto.
    @Published private(set) var sleepBrokeThePromise = false

    // MARK: - Collaborators

    let backlight = KeyboardBacklight()
    private var powerMonitor: PowerSourceMonitor?
    private var clamshell: ClamshellMonitor?
    private var network: NetworkMonitor?
    private var thermalWatch: ThermalWatch?
    /// Runs for the whole life of the app, not per session — see the note in SleepWatch.
    private var sleepWatch: SleepWatch?

    // MARK: - Session bookkeeping

    /// What the user asked for. The kernel flag is what actually is; these two disagreeing
    /// is the whole reason the guardian exists.
    ///
    /// Published because the main switch is bound to it. Binding the switch to `status.isOn`
    /// instead meant any error during a live session — an unreadable IOKit read, a lock that
    /// did not take — rendered the switch as OFF while the session was running, and clicking
    /// it then started a *second* session and pushed the deadline out by the full duration.
    @Published private(set) var intendedOn = false
    private var sessionStart: Date?

    /// De duur die voor déze sessie gevraagd is, in minuten. `nil` betekent: de duur die in
    /// het paneel staat. Staat los van `Prefs.autoOffMinutes` omdat een CLI-aanroep met
    /// `--for 2h` de opgeslagen instelling niet mag overschrijven — dan zou het paneel na
    /// afloop iets anders zeggen dan de gebruiker er ooit in gezet heeft.
    private var sessionLimitMinutes: Int?
    /// Een harde bovengrens voor déze sessie (`--until`, en straks een schemavenster). De
    /// tijdslimiet gaat er altijd overheen: wat het eerst komt wint.
    private var sessionNotLaterThan: Date?
    /// Waarom die bovengrens er is, in gewone taal. Hoort bij `sessionNotLaterThan` en wordt
    /// met hem samen gewist.
    private var sessionCapReason: String?
    /// Waarom de eindtijd staat waar hij staat, in gewone taal, voor de logregel bij het
    /// aflopen. Gezet op dezelfde plek als de eindtijd zelf.
    private var deadlineReason = L10n.t("reden.tijdom")

    /// Waar de lopende sessie aan hangt. `nil` = alleen de timer.
    ///
    /// Dit is géén tweede waarheid over "loopt er een sessie": het is een feit over een
    /// proces. Of de sessie daardoor stopt, beslist `releaseReason()` en niets anders.
    struct SessionBinding {
        let identity: ProcessWatch.Identity
        var watcher: ProcessWatch.ExitWatcher?
        /// Of de snelle route (de procesbron) de exit gemeld heeft. Merkt de poll het als
        /// eerste, dan werkt die route op deze machine niet en dat hoort in het logboek.
        var fastRouteReported = false
        /// Zodat die waarschuwing één keer komt en niet elke twintig seconden.
        var loggedSlowDetection = false
    }
    @Published private(set) var binding: SessionBinding?

    /// Wie de sessie gestart heeft. Gezet in hetzelfde blok als `intendedOn = true`.
    @Published private(set) var sessionTrigger: SessionTrigger?

    // MARK: - Triggers (fase 3)
    //
    // Drie manieren om een sessie te laten beginnen zonder de schakelaar aan te raken. Ze
    // hebben één ding gemeen dat belangrijker is dan hun onderlinge verschillen: **het zijn
    // uitspraken, geen actoren.** Geen van de drie heeft een eigen timer die aanzet, geen van
    // de drie weet of er een sessie loopt, en geen van de drie raakt de kernelvlag aan. Ze
    // leveren feiten; `evaluateTriggers()` leest die feiten uit één plek in de guardian-tik,
    // en starten gaat dan langs precies dezelfde `startSession` als de schakelaar.
    //
    // En alle drie zijn ze een **flank**, nooit een stand. Dat is geen stijlkeuze: een schema
    // dat zegt "het is werkdag, het is 15:29, er loopt niets" zou twintig seconden na een
    // accugrens die om 15:29 net ingreep de Mac weer wakker zetten — en dan zijn de
    // tijdslimiet, de accugrens en de warmtegrens binnen één tik alle drie waardeloos.

    /// De eenmalige "ga aan zodra ik de klep dichtdoe". Bewust niet in `Prefs`; zie `LidArm`.
    @Published private(set) var lidArm: LidArm?
    private var appTrigger: AppTriggerWatch?
    /// Welke gekozen apps er bij de vorige waarneming draaiden. Dit gaat over díe apps, niet
    /// over ons: alleen de overgang niet-draaiend → draaiend is een trigger. Wordt bij
    /// `start()` op de huidige toestand gezet, zodat inloggen met Xcode al open geen sessie
    /// oplevert die niemand gevraagd heeft.
    private var appsDieDraaiden: Set<String> = []
    /// Zodat een schema dat nooit open kan gaan één keer opvalt en niet elke twintig seconden.
    private var loggedScheduleProblem: String?
    /// Zodat "even bezig, volgende tik opnieuw" één regel oplevert per episode.
    private var loggedTriggersSkipped = false

    /// `guard !busy` dekt niet wat het lijkt te dekken: `activate` heeft twee
    /// onderbrekingspunten (de grantcontrole en de privileged schrijf) waarop `busy` nog
    /// vals staat, en met de CLI erbij kunnen twee aanroepen daar tegelijk doorheen. Deze
    /// vlag sluit de hele functie af, met een `defer` zodat hij ook bij elke vroege
    /// terugkeer weer opengaat.
    private var activationInFlight = false

    private var controlServer: ControlServer?
    private var guardianTimer: Timer?
    private var tickTimer: Timer?
    private var displayReassertTimer: Timer?
    private var signalSources: [DispatchSourceSignal] = []
    private var pendingOutageReport: String?
    /// The last summary actually shown. `NetworkMonitor.summary` is derived from the
    /// session's outage list, so it keeps returning the same sentence — without this the
    /// same alert reappears on every single lid-open for the rest of the session.
    private var reportedOutageSummary: String?
    private var lastFailureAlarm: Date?
    private var releaseAttempts = 0
    /// When the next release may be tried. A failing release is usually a missing sudoers
    /// grant, which will not fix itself — retrying every 20 seconds for eight hours would
    /// spawn tens of thousands of processes and fill the log, on battery, for nothing.
    private var nextReleaseAttempt: Date?

    // MARK: - Derived

    /// The menu bar glyph, drawn from the app's own artwork rather than an SF Symbol.
    ///
    /// Alleen het merk, zonder aftelling: dit is de versie voor het paneel, waar de resterende
    /// tijd al voluit in een zin staat.
    func menuBarIcon(pointSize: CGFloat = 18) -> NSImage {
        AppIcon.menuBar(iconState, pointSize: pointSize)
    }

    /// Wat er écht in de menubalk komt te staan: het merk, en ernaast de aftelling.
    ///
    /// Gebufferd op (staat, tekst). De scene wordt door de kloktik van `startTicking` elke
    /// seconde opnieuw geëvalueerd, en zonder deze buffer zou er dus elke seconde een nieuw
    /// beeld getekend worden terwijl er hooguit één keer per minuut iets aan verandert.
    private var gebufferdIcoon: (staat: AppIcon.State, aftelling: String?, beeld: NSImage)?

    var menuBarLabel: NSImage {
        let staat = iconState
        let aftelling = menuBarCountdown
        if let gebufferd = gebufferdIcoon, gebufferd.staat == staat, gebufferd.aftelling == aftelling {
            return gebufferd.beeld
        }
        let beeld = AppIcon.menuBar(staat, countdown: aftelling)
        gebufferdIcoon = (staat, aftelling, beeld)
        return beeld
    }

    /// De resterende tijd voor in de menubalk, als "3:15", of `nil`.
    ///
    /// Rekent uitsluitend met `deadline` en `now` — de klok die de guardian al bijhoudt. Geen
    /// eigen timer en geen eigen anker: de duur is midden in een sessie te wijzigen
    /// (`rescheduleIfRunning`), en een aftelling met een eigen beginpunt zou daar stilletjes
    /// van wegdrijven.
    ///
    /// Alleen bij een echte sessie. Staat de vlag aan zónder sessie, dan is er geen eindtijd en
    /// loopt er dus ook niets af; een aftelling zou daar precies de leugen zijn die
    /// `safetyNetLine` in zijn derde tak expres vermijdt. Er staat dan alleen het bliksem-icoon.
    var menuBarCountdown: String? {
        guard Prefs.showCountdownInMenuBar, intendedOn, let deadline else { return nil }
        // Naar boven afronden, net als bij de arming: "0:00" terwijl er nog veertig seconden
        // staan leest als "voorbij".
        let minuten = max(0, Int((deadline.timeIntervalSince(now) / 60).rounded(.up)))
        return "\(minuten / 60):" + String(format: "%02d", minuten % 60)
    }

    private var iconState: AppIcon.State {
        switch status {
        case .error: return .error
        case .on: return .on
        case .off: return .off
        }
    }

    var statusText: String {
        switch status {
        case .off: return L10n.t("kop.uit")
        case .on: return L10n.t("kop.aan")
        case .error(let message): return message
        }
    }

    var remainingText: String? {
        // Keyed off the session, not off `status`: a session that has drifted into an
        // error state is exactly when you want to see how long the flag has left to run.
        guard let deadline, intendedOn else { return nil }
        let seconds = max(0, Int(deadline.timeIntervalSince(now)))
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        if hours > 0 { return L10n.t("kop.resterend.uren", hours, minutes) }
        if minutes > 0 { return L10n.t("kop.resterend.minuten", minutes) }
        return L10n.t("kop.resterend.bijna")
    }

    /// The configured duration, in minutes.
    ///
    /// Published rather than read straight from `Prefs` at each use, so the menu and the
    /// Settings window are two views of one value: changing it in either place updates the
    /// other immediately instead of leaving a stale `@State` copy behind.
    /// Filled in by `start()`, not at property-initialisation time: stored properties are
    /// initialised before `init()` runs `Prefs.registerDefaults()`, so reading Prefs here
    /// returned the clamped floor rather than the real default and the UI advertised a
    /// five-minute timer for a session that would actually run for seven hours.
    @Published private(set) var autoOffMinutes: Int = 5

    var autoOffHoursPart: Int { autoOffMinutes / 60 }
    var autoOffMinutesPart: Int { autoOffMinutes % 60 }

    /// The configured duration, shown before a session starts so the setting is visible at
    /// the moment you flip the switch rather than only inside Settings.
    var configuredDurationText: String {
        Self.durationText(autoOffMinutes)
    }

    /// The line under the status text in the menu header.
    ///
    /// The subtlety is the third case. With the flag stuck at 1 and no session there is no
    /// scheduled release at all — no deadline, nothing armed — and printing the *configured*
    /// duration there rendered "vangnet na 7 uur" directly above the red "vangnetten staan
    /// uit" panel: a promise that the Mac would be allowed to sleep in seven hours, made at
    /// the one moment nothing was going to release it.
    ///
    /// The off case returns nil. It used to preview "stopt straks vanzelf na 4 u 30 min", but
    /// under the header "Wakker houden staat uit" that reads as a running countdown while
    /// nothing is running — and the duration is already on the Duur row right below, so the
    /// line was both contradictory and redundant.
    var safetyNetLine: String? {
        if let remaining = remainingText { return remaining }
        if kernelFlag == true && !intendedOn {
            return L10n.t("kop.zondersessie")
        }
        return nil
    }

    // MARK: - Wat het paneel nodig heeft

    /// De toestand van de statuskaart. Eén vraag, één antwoord — zie `KaartToestand`.
    var kaart: KaartToestand {
        KaartToestand(intendedOn: intendedOn,
                      armTot: lidArm?.verlooptOp,
                      sessieStart: sessionStart,
                      deadline: deadline,
                      nu: now)
    }

    /// `nil` als er geen accumeting is — een Mac zonder accu, of vóór de eerste snapshot.
    /// Nul tonen zou een lege balk zijn voor iets wat nooit gemeten is.
    var accuMeter: AccuMeter? {
        guard let battery else { return nil }
        return AccuMeter(percent: battery.percent,
                         grens: Prefs.batteryFloor,
                         aanDeLader: battery.onAC)
    }

    /// De warmtestand, en buiten een sessie rechtstreeks gemeten.
    ///
    /// `ThermalWatch` draait alléén tijdens een sessie: `startSession` doet `start()`,
    /// `endSession` doet `stop()` en zet `thermal = .nominal`. Buiten een sessie is `thermal`
    /// dus altijd `.nominal`, ongeacht wat de Mac werkelijk doet — en het paneel tekende dan
    /// "Normaal · 4/4" op een machine die op dat moment ernstig onder druk kon staan.
    ///
    /// `activate()` kende dit probleem al en leest daar met zoveel woorden de líve waarde:
    /// "the cached value is ALWAYS .nominal here". Dezelfde reden geldt hier. De lezing is
    /// een goedkope synchrone property, geen systeemaanroep.
    ///
    /// Dit is dezelfde regel die `accuMeter` al volgt: liever niets tonen of echt meten dan
    /// een waarde tekenen die nooit gemeten is.
    var warmteStand: ThermalWatch.Pressure {
        intendedOn ? thermal : ThermalWatch.Pressure(ProcessInfo.processInfo.thermalState)
    }

    /// Het woord naast de warmtemeter. Uit dezelfde bron als de meter zelf, want anders kan er
    /// "normaal" staan naast drie van de vier blokjes aan.
    var warmteLabel: String { warmteStand.label }

    var warmteMeter: WarmteMeter {
        switch warmteStand {
        case .nominal:  return WarmteMeter(stap: 1)
        case .fair:     return WarmteMeter(stap: 2)
        case .serious:  return WarmteMeter(stap: 3)
        case .critical: return WarmteMeter(stap: 4)
        }
    }

    /// Alle waarschuwingen in één gesorteerde lijst.
    ///
    /// Bewust hier en niet in de view: de rangorde is een beslissing over wat er bovenaan
    /// komt te staan, en die hoort niet in de opmaak te zitten.
    var aandacht: Aandacht {
        var meldingen: [Aandacht.Melding] = []
        if safetyNetsDisarmed {
            meldingen.append(.init(soort: .vangnettenUit, tekst: L10n.t("menu.ontwapend.titel")))
        }
        // De foutstatus zelf. Twintig plekken zetten `status = .error(...)` en het paneel las
        // dat nergens meer: bij een onleesbare kernelvlag stond er "Slaapt normaal" met een
        // groen kloppende wachterstip eronder, terwijl de guardian juist niet wist óf de Mac
        // mocht slapen. Rood, dus de rij klapt altijd open — een fout kan niet meer achter een
        // driehoekje verdwijnen.
        if case .error(let melding) = status {
            meldingen.append(.init(soort: .foutstatus, tekst: melding))
        }
        // Een stille wachter is rood, en rood klapt de rij open. De stip werd hier al rood
        // van, maar zonder melding bleef de rij dicht en telde hij niet mee.
        if !wachterLeeft {
            meldingen.append(.init(soort: .wachterStil, tekst: L10n.t("vangnet.wachter.stil")))
        }
        if let slept = sleepDuringSession {
            meldingen.append(.init(soort: sleepBrokeThePromise ? .belofteGebroken : .wasGeslapen,
                                   tekst: slept.describe()))
        }
        if let conflict {
            meldingen.append(.init(soort: conflict.sharesTheFlag ? .conflictDeeltVlag : .conflict,
                                   tekst: L10n.t(conflict.sharesTheFlag ? "menu.conflict.deelt"
                                                                        : "menu.conflict.draait",
                                                 conflict.name)))
        }
        // Alleen oranje als er werkelijk iets mislukte. `lastMessage` draagt ook
        // geruststellingen — "opgeruimd", "staat al aan" — en die als waarschuwing bovenaan
        // zetten is precies het te-luid-zijn dat deze herindeling moest wegnemen. De oude
        // code maakte dat onderscheid met `status.isError`; hier gebeurt dat weer.
        // Niet twee keer dezelfde zin: verschillende paden zetten `status` en `lastMessage` op
        // dezelfde tekst, en die dan als rood én als oranje tonen maakt één probleem twee.
        if let lastMessage, !meldingen.contains(where: { $0.tekst == lastMessage }) {
            meldingen.append(.init(soort: status.isError ? .laatsteMelding : .laatsteMededeling,
                                   tekst: lastMessage))
        }
        if grantStatus != .granted {
            meldingen.append(.init(soort: .geenToestemming, tekst: grantText))
        }
        if !outages.isEmpty {
            meldingen.append(.init(soort: .storingen,
                                   tekst: L10n.t(outagesFromFinishedSession ? "menu.storing.vorige"
                                                                            : "menu.storing.nu")))
        }
        return Aandacht(meldingen: meldingen)
    }

    /// Wanneer de wachter voor het laatst keek. Dat is het bewijs dat hij leeft, en het is
    /// het enige vangnet dat een `SIGKILL` van de app overleeft — het stond tot nu toe
    /// nergens in de interface. `nil` als hij nog nooit gedraaid heeft.
    ///
    /// Leest via `RestartGuard.timeSinceLastRound()`, dat er al was voor de guardian en
    /// uitsluitend het statusbestand inleest. Geen tweede ingang naar diezelfde toestand:
    /// de wachter mag niets uitvoeren en niets schrijven, en één leesweg is één ding om
    /// zuiver te houden.
    var wachterZin: String {
        guard let sinds = wachterSinds else {
            return L10n.t("vangnet.wachter.nognietgekeken")
        }
        // Boven de twee minuten in minuten, net als `RestartGuard.statusSentence()`. Rauwe
        // seconden gaven "vlag gelezen, 4211 s geleden" — een getal dat je moet omrekenen om
        // te merken dat er ruim een uur niemand gekeken heeft.
        let seconden = max(0, Int(sinds))
        let ouderdom = seconden < 120 ? L10n.t("wachter.secondengeleden", seconden)
                                      : L10n.t("wachter.minutengeleden", seconden / 60)
        return L10n.t("vangnet.wachter.gelezen", ouderdom)
    }

    /// Kijkt de wachter nog? Dezelfde grens van 300 seconden die `checkRestartGuardIsAwake()`
    /// hanteert, en net als daar telt "nog nooit gekeken" als niet levend.
    ///
    /// Het paneel had dit niet: `WachterStip` was hard groen en klopte altijd door, ook als de
    /// LaunchAgent uitgezet was bij Systeeminstellingen → Inloggen en extensies. Een indicator
    /// die per constructie geen storing kan melden, is erger dan geen indicator — zeker voor
    /// het enige vangnet dat een `SIGKILL` van de app overleeft.
    var wachterLeeft: Bool {
        guard let sinds = wachterSinds else { return false }
        return sinds <= 300
    }

    static func durationText(_ total: Int) -> String {
        let h = total / 60, m = total % 60
        if h == 0 { return L10n.t("duur.minuten", m) }
        // Enkelvoud apart: "1 uur" is in het Nederlands hetzelfde woord als "2 uur", maar in
        // het Engels, Duits en Frans niet. Eén sleutel met %d zou daar "1 hours" opleveren.
        if m == 0 { return h == 1 ? L10n.t("duur.uur.een") : L10n.t("duur.uur.meer", h) }
        return L10n.t("duur.uurmin", h, m)
    }

    /// De aftelling voor de statuskaart: alleen het getal.
    ///
    /// `remainingText` is een hele zin — "stopt vanzelf over 3 u 18 min" — en die past niet in
    /// dertig punten; hij werd afgekapt tot "stopt vanze…". Die zin blijft staan voor de
    /// plekken waar hij wél past. De kaart heeft de zin niet nodig: eronder staat al
    /// "wakker tot 21:56".
    ///
    /// Naar boven afgerond, net als `menuBarCountdown`, zodat de twee niet een minuut uit
    /// elkaar kunnen lopen terwijl ze tegelijk zichtbaar zijn.
    var kaartAftelling: String? {
        guard let deadline, intendedOn else { return nil }
        let minuten = max(0, Int((deadline.timeIntervalSince(now) / 60).rounded(.up)))
        return AppModel.durationTextKort(minuten)
    }

    /// Compacte vorm voor de segmentkiezer: `30m`, `2u`, `10u30`.
    ///
    /// De lange vorm past daar niet in. Met vijf vaste duren plus een eigen segment voor een
    /// afwijkende waarde staan er zes naast elkaar, en "10 u 30 min" maakte er een die het
    /// paneel links en rechts uitliep.
    ///
    /// Eigen sleutels en geen `replacingOccurrences` op de lange vorm: dat laatste werkt
    /// alleen in het Nederlands en zou in de drie andere talen stil niets doen.
    static func durationTextKort(_ total: Int) -> String {
        let h = total / 60, m = total % 60
        if h == 0 { return "\(m)" + L10n.t("duur.kort.min") }
        if m == 0 { return "\(h)" + L10n.t("duur.kort.uur") }
        return "\(h)" + L10n.t("duur.kort.uur") + String(format: "%02d", m)
    }

    /// The wall-clock time the current session would end, for the menu.
    var deadlineText: String? {
        guard let deadline else { return nil }
        let clock = DateFormatter()
        clock.dateFormat = "HH:mm"
        return clock.string(from: deadline)
    }

    /// Waar de lopende sessie aan hangt, voor het paneel. `nil` = alleen de timer.
    ///
    /// Bewust naast `safetyNetLine` en niet erin: die zin gaat over wat de Mac straks weer
    /// laat slapen, en zijn derde tak (vlag aan zonder sessie) mag niet verwateren.
    var bindingLine: String? {
        guard intendedOn, let binding else { return nil }
        return L10n.t("kop.gebonden", binding.identity.label)
    }

    /// Hoe de lopende sessie begonnen is, voor het paneel.
    ///
    /// Altijd zichtbaar zolang er een sessie loopt, ook bij de schakelaar. Een regel die er
    /// soms wel en soms niet staat maakt zijn afwezigheid dubbelzinnig, en dan is "welke
    /// trigger heeft dit gestart?" niet met zekerheid te beantwoorden — precies de vraag die
    /// fase 3 moest beantwoorden. Staat de vlag aan zónder sessie, dan is er ook geen trigger
    /// en zegt deze regel niets: dat is dezelfde eerlijkheid als in `safetyNetLine`.
    var triggerLine: String? {
        guard intendedOn, let sessionTrigger else { return nil }
        let zin = sessionTrigger.zin
        return zin.prefix(1).uppercased() + zin.dropFirst() + "."
    }

    /// Het ingestelde schemavenster, zoals het nú in de instellingen staat.
    var scheduleWindow: ScheduleWindow {
        ScheduleWindow(dagen: Prefs.scheduleDays,
                       startMinuut: Prefs.scheduleStartMinute,
                       eindMinuut: Prefs.scheduleEndMinute)
    }

    /// Dezelfde klem als `Prefs.autoOffMinutes` (5 minuten tot 24 uur), zodat een verzoek van
    /// buiten de tijdslimiet niet kan oprekken. `nil` = de duur die in het paneel staat.
    private func clampedMinutes(_ minutes: Int?) -> Int {
        min(max(minutes ?? Prefs.autoOffMinutes, 5), 24 * 60)
    }

    /// De duur die voor de lopende (of eerstvolgende) sessie geldt.
    var effectiveLimitMinutes: Int { clampedMinutes(sessionLimitMinutes) }

    /// De enige plek die uitrekent wanneer een sessie afloopt.
    ///
    /// Twee plekken die dit uitrekenen is twee planners, en dan is de vraag "wanneer stopt
    /// hij" niet meer te beantwoorden. `activate` en `rescheduleIfRunning` gebruiken allebei
    /// deze functie; nergens anders wordt `deadline` geschreven, behalve in `endSession`.
    /// De waarden staan erin als parameters zodat een verzoek van buiten eerst uitgerekend
    /// kan worden en pas daarna toegepast — de tijdslimiet wint altijd van de bovengrens.
    private func computeDeadline(start: Date, limitMinutes: Int?, notLaterThan: Date?,
                                 capReason: String? = nil) -> (date: Date, reason: String) {
        let byLimit = start.addingTimeInterval(Double(clampedMinutes(limitMinutes)) * 60)
        if let cap = notLaterThan, cap < byLimit {
            return (cap, capReason ?? L10n.t("reden.liepot", Self.clockText(cap)))
        }
        return (byLimit, "de ingestelde tijd was om")
    }

    private func applyDeadline(start: Date) {
        let planned = computeDeadline(start: start, limitMinutes: sessionLimitMinutes,
                                      notLaterThan: sessionNotLaterThan, capReason: sessionCapReason)
        deadline = planned.date
        deadlineReason = planned.reason
    }

    static func clockText(_ date: Date) -> String {
        let clock = DateFormatter()
        clock.dateFormat = "HH:mm"
        return clock.string(from: date)
    }

    /// Sets the duration and, if a session is running, moves its deadline with it.
    func setAutoOff(minutes: Int) {
        Prefs.autoOffMinutes = minutes
        autoOffMinutes = Prefs.autoOffMinutes   // read back, so clamping is visible in the UI
        // De schuif wint van een duur die van buiten kwam. Zonder dit blijft een sessie die
        // met `dopamine on --for 2h` begon op twee uur staan terwijl het paneel iets anders
        // laat zien — en dan liegt het paneel over de enige instelling die ertoe doet.
        sessionLimitMinutes = nil
        rescheduleIfRunning()
    }

    /// Nudges the duration by a delta, for the menu's +/- buttons.
    func adjustAutoOff(byMinutes delta: Int) {
        setAutoOff(minutes: autoOffMinutes + delta)
    }

    /// "Tot 18:00" in plaats van "voor 4,5 uur" — dezelfde instelling, anders gezegd.
    ///
    /// Uitdrukkelijk géén tweede manier om een eindtijd te bewaren: de gevraagde kloktijd wordt
    /// omgerekend naar minuten en gaat door `setAutoOff(minutes:)` heen, zodat
    /// `Prefs.autoOffMinutes` en `rescheduleIfRunning` de enige eigenaars van de eindtijd
    /// blijven. Een opgeslagen absolute eindtijd zou een tweede planner naast de bestaande zijn,
    /// en dan is "wanneer stopt hij" niet meer met zekerheid te beantwoorden.
    ///
    /// Het anker is `sessionStart`, niet nu. `deadline` is start + duur, dus vanaf nu rekenen
    /// tijdens een lopende sessie levert een eindtijd die precies zo veel te vroeg valt als de
    /// sessie al gelopen heeft: begonnen om 14:00, om 15:00 "tot 18:00" gekozen, en hij stopt
    /// om 17:00.
    ///
    /// Geeft de zin terug die het paneel laat zien — inclusief wat de klem van 5 minuten tot
    /// 24 uur ervan gemaakt heeft, want een andere eindtijd tonen dan de gevraagde zonder dat
    /// te zeggen is precies het soort stilte dat deze app niet hoort te hebben.
    @discardableResult
    func setAutoOffUntil(_ tijdstip: Date) -> String {
        let nu = Date()
        let anker = sessionStart ?? nu
        let doel = Self.eerstvolgende(kloktijdVan: tijdstip, na: nu)
        let gevraagdeMinuten = Int((doel.timeIntervalSince(anker) / 60).rounded())
        setAutoOff(minutes: gevraagdeMinuten)

        // Teruglezen in plaats van aannemen: `setAutoOff` schrijft via `Prefs.autoOffMinutes`,
        // en die klemt. Dat is dezelfde reden waarom `setAutoOff` zelf ook terugleest.
        let werkelijkeMinuten = autoOffMinutes
        let geklemd = werkelijkeMinuten != gevraagdeMinuten
        let klemZin = gevraagdeMinuten > werkelijkeMinuten
            ? "Langer dan 24 uur kan niet."
            : "Korter dan 5 minuten kan niet."
        let gevraagdeKlok = Self.clockText(doel)

        // Loopt er een sessie, dan is `deadline` het enige eerlijke antwoord — en niet de som
        // hierboven. Er kan een bovengrens overheen liggen (het einde van een schemavenster) die
        // eerder valt dan de duur, en dan zou "stopt om 18:00" een uur te laat zijn.
        if intendedOn, let echteEinde = deadline {
            let echteKlok = Self.clockText(echteEinde)
            if geklemd {
                return "\(klemZin) Deze sessie stopt om \(echteKlok), "
                    + "\(Self.durationText(werkelijkeMinuten)) na het aanzetten."
            }
            // Een minuut speling: de eindtijd is op de seconde nauwkeurig, de kiezer niet.
            if abs(echteEinde.timeIntervalSince(doel)) >= 60 {
                return "Deze sessie stopt al eerder, om \(echteKlok): daar ligt een grens "
                    + "overheen die hiermee niet op te schuiven is."
            }
            return "Deze sessie stopt om \(echteKlok) — \(Self.durationText(werkelijkeMinuten)) "
                + "na het aanzetten."
        }

        // Zonder lopende sessie is er nog geen anker, dus wordt het een duur en geen tijdstip.
        // Dat hardop zeggen: zet je hem een half uur later aan, dan schuift het einde mee.
        let staart = "De duur staat nu op \(Self.durationText(werkelijkeMinuten)). Zet je het "
            + "wakker houden nú aan, dan stopt het om "
            + "\(Self.clockText(nu.addingTimeInterval(Double(werkelijkeMinuten) * 60)))"
            + "; zet je het later aan, dan schuift het einde mee."
        return geklemd ? "\(klemZin) \(staart)" : "Tot \(gevraagdeKlok). \(staart)"
    }

    /// Het eerstvolgende moment ná nu met dit uur en deze minuut.
    ///
    /// "Tot 02:00" om 23:00 rolt dus door naar morgen — dezelfde regel die de opdrachtregel bij
    /// `--until` aanhoudt, want een tijdstip in het verleden weigeren is alleen maar verwarrend.
    private static func eerstvolgende(kloktijdVan tijdstip: Date, na nu: Date) -> Date {
        let kalender = Calendar.current
        let onderdelen = kalender.dateComponents([.hour, .minute], from: tijdstip)
        // `nextDate` slaat het moment over dat exact gelijk is aan `nu`, en dat klopt: "tot
        // 15:00" om precies 15:00 gaat over morgen, niet over nul minuten.
        return kalender.nextDate(after: nu, matching: onderdelen, matchingPolicy: .nextTime)
            ?? nu.addingTimeInterval(60)
    }

    /// One line in the menu saying what will actually happen, so the behaviour is legible
    /// without opening Settings.
    var behaviourSummary: String {
        var parts: [String] = []
        switch Prefs.lockMoment {
        case .lidClose: parts.append(L10n.t("gedrag.slot.klep"))
        case .activate: parts.append(L10n.t("gedrag.slot.meteen"))
        case .never: parts.append(L10n.t("gedrag.slot.nooit"))
        }
        switch Prefs.displayOffMoment {
        case .lidClose: parts.append(L10n.t("gedrag.scherm.klep"))
        case .activate: parts.append(L10n.t("gedrag.scherm.meteen"))
        case .never: parts.append(L10n.t("gedrag.scherm.aan"))
        }
        return parts.joined(separator: " · ")
    }

    var grantText: String {
        switch grantStatus {
        case .granted: return L10n.t("grant.actief")
        case .missing: return L10n.t("grant.ontbreekt")
        case .present(let why): return L10n.t("grant.kapot", why)
        }
    }

    // MARK: - Lifecycle

    func start() {
        autoOffMinutes = Prefs.autoOffMinutes
        EventLog.shared.rotateIfNeeded()
        EventLog.shared.info("Dopamine Code gestart (\(Bundle.main.bundleURL.path)).")

        // Wat de vorige afsluiting achterliet, meteen lezen en meteen weggooien: vanaf nu
        // betekent "geen markering" weer wat het moet betekenen, namelijk dat deze app niet
        // netjes is afgesloten. Zonder die regel zou het vangnet na een kill -9 denken dat het
        // afsluiten van gisteravond nog liep.
        if let vorige = RestartGuard.clearExitMarkerAtStartup() {
            EventLog.shared.info(vorige)
        }
        if RestartGuard.broughtBackByWatchdog {
            EventLog.shared.error(
                "Deze start komt van het vangnet: de app was weggevallen terwijl de Mac wakker "
                + "gehouden werd."
            )
        }

        refreshBacklight()
        Task { conflict = await ConflictWatch.current() }

        powerMonitor = PowerSourceMonitor { [weak self] snapshot in
            self?.handlePower(snapshot)
        }
        powerMonitor?.start()

        clamshell = ClamshellMonitor { [weak self] closed in
            self?.handleLid(closed: closed)
        }
        clamshell?.start()
        lidClosed = clamshell?.isClosed ?? false

        thermalWatch = ThermalWatch { [weak self] pressure in
            self?.handleThermal(pressure)
        }

        // De app-trigger uit 3.2. Zijn meldingen doen precies één ding — de guardian
        // aanstoten — net als de klepmelding en de exit-melding van een gekoppeld proces.
        // Wat er dan gebeurt beslist `evaluateTriggers()`, en die kijkt naar de kernelvlag.
        let apps = AppTriggerWatch { [weak self] in
            Task { @MainActor in await self?.guardianTick() }
        }
        apps.start()
        appTrigger = apps
        // De begintoestand telt als "al gezien". Inloggen 's ochtends terwijl Xcode nog open
        // staat van gisteren hoort geen sessie op te leveren die niemand gevraagd heeft; een
        // trigger gaat over de overgang niet-draaiend → draaiend en niet over de stand.
        appsDieDraaiden = Set(apps.draaiendeApps(Set(Prefs.appTriggerBundleIDs)).keys)
        if !appsDieDraaiden.isEmpty {
            EventLog.shared.info(
                "Deze app-triggers draaiden al bij het starten en tellen als gezien: "
                + appsDieDraaiden.sorted().map { Prefs.appTriggerName($0) }.joined(separator: ", ") + "."
            )
        }

        // Started here rather than per session: the reading has to stay current while the
        // app is idle, or the first sample after an activation would report every minute
        // the Mac slept beforehand as a broken promise.
        sleepWatch = SleepWatch { [weak self] message in
            guard let self else { return }
            EventLog.shared.log(self.intendedOn ? .error : .info, message)
        }
        sleepWatch?.start()

        Notify.requestAuthorisation()

        // Het besturingskanaal voor de `dopamine`-opdrachtregel. Hij vraagt de app om iets
        // te doen en drukt het antwoord af; de vlag blijft van deze app alleen.
        let server = ControlServer { [weak self] verzoek in
            guard let self else {
                return .lokaal(zin: "Dopamine Code is aan het afsluiten.", code: 4)
            }
            return await self.handleControl(verzoek)
        }
        server.start()
        controlServer = server

        // De sneltoets. Standaard is er geen, dus dit is meestal een lege registratie; lukt het
        // wél niet, dan staat dat meteen in het logboek en in Instellingen.
        applyShortcut()

        installSignalHandlers()
        startTicking()
        startGuardian()

        Task { await self.refreshGrantAsync() }
        Task {
            await self.clearStaleFlagAtStartup()
            // Ná het opruimen, want de zin moet kunnen zeggen óf het opruimen gelukt is.
            self.announceWatchdogRestartIfNeeded()
        }
        // Bewust bij elke start, niet alleen de eerste keer: een plist die iemand weggooit of
        // een bundel die verhuist moet zichzelf herstellen. `launchctl` erbij, dus naast de
        // hoofdthread — die draait de guardian.
        Task.detached(priority: .utility) { RestartGuard.ensureInstalled() }
        logEnvironment()
    }

    /// Zegt hardop dat de app was weggevallen en door het vangnet is teruggehaald.
    ///
    /// Nooit stil terugkomen alsof er niets was: de app is met `kill -9` of door een crash
    /// verdwenen terwijl de Mac wakker gehouden werd, en dat is precies het soort gebeurtenis
    /// dat 's nachts gebeurt en waar de gebruiker de volgende ochtend van moet weten.
    private func announceWatchdogRestartIfNeeded() {
        guard RestartGuard.broughtBackByWatchdog else { return }
        let opgeruimd = kernelFlag == false
        let staart = opgeruimd
            ? "De slaapblokkade is opgeruimd; de Mac mag weer slapen."
            : "De slaapblokkade staat nog aan — de Mac kan nu niet slapen."
        let zin = "Dopamine Code was weggevallen terwijl de Mac wakker gehouden werd. " + staart
        EventLog.shared.error(zin)
        lastMessage = zin
        // Met de klok erin, net als bij `sessionEnded`: dit gebeurt 's nachts en "zojuist" zegt
        // 's ochtends niets meer.
        let clock = DateFormatter()
        clock.dateFormat = "HH:mm"
        Notify.post(.restartedAfterLoss,
                    "Om \(clock.string(from: Date())) teruggehaald door het vangnet. " + staart)
    }

    /// Recorded once per launch so that a failure after a macOS update can be traced to
    /// the thing that changed, rather than guessed at.
    private func logEnvironment() {
        let version = ProcessInfo.processInfo.operatingSystemVersionString
        let lock = ScreenLock.lockingEnabled.map { $0 ? "aan" : "UIT" } ?? "onbekend"
        let backlightRoute = backlight.hasDirectControl ? "CoreBrightness" : "CGEvent"
        EventLog.shared.info(
            "Omgeving: \(version), vergrendeling \(lock), verlichting via \(backlightRoute), "
            + "gebeurtenissen posten toegestaan: \(KeyboardBacklight.canPostEvents)."
        )
        if !backlight.hasDirectControl {
            EventLog.shared.warn("CoreBrightness niet bereikbaar — mogelijk gewijzigd door een macOS-update.")
        }
    }

    /// Requirement 9: a flag left set by a crashed or force-quit previous session must be
    /// cleaned up, not inherited. The app always begins with "blijf actief" off.
    private func clearStaleFlagAtStartup() async {
        kernelFlag = SleepFlag.read()
        guard let flag = kernelFlag else {
            status = .error(L10n.t("fout.vlag.onleesbaar"))
            EventLog.shared.error("SleepDisabled kon bij het starten niet gelezen worden.")
            return
        }
        guard flag else {
            status = .off
            intendedOn = false
            return
        }

        EventLog.shared.warn("SleepDisabled stond nog op 1 bij het starten — opruimen.")
        intendedOn = false
        // Never raise a password sheet at login. If the grant is gone the user gets a
        // visible warning and a button instead of a surprise prompt; the guardian keeps
        // retrying in the background.
        let outcome = await write(false, allowPrompt: false)
        switch outcome {
        case .verified:
            status = .off
            lastMessage = L10n.t("melding.opgeruimd")
        default:
            status = .error(L10n.t("fout.vorigekeer"))
            safetyNetsDisarmed = true
            lastMessage = L10n.t("melding.kanniet.slapen")
        }
    }

    private func startTicking() {
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.now = Date() }
        }
        RunLoop.main.add(timer, forMode: .common)
        tickTimer = timer
    }

    /// `applicationWillTerminate` does not run for a SIGTERM, which is what a logout,
    /// a restart or `killall` sends. Leaving the flag set because the app was told to
    /// go away is the one failure this app must never cause.
    private func installSignalHandlers() {
        for signalNumber in [SIGTERM, SIGINT, SIGHUP] {
            signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
            source.setEventHandler {
                // A privileged write may be in flight. Reading the flag right now would
                // see 0 — powerd has not applied it yet — conclude there is nothing to
                // release, and exit; root would then set the flag with no app left to ever
                // clear it. Wait briefly for the write to land first.
                let deadline = Date().addingTimeInterval(6)
                while AppModel.shared.busy && Date() < deadline {
                    RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.1))
                }
                // Anything other than a definite `false` gets a clearing attempt: an
                // unreadable property, or a write that has not been applied yet, must not
                // be mistaken for "already off" on the one code path that runs at logout.
                if SleepFlag.read() != false {
                    EventLog.shared.warn("Signaal \(signalNumber) ontvangen, vlag niet zeker op 0 — terugzetten.")
                    let outcome = SleepFlag.set(false, allowPrompt: false)
                    if case .verified = outcome {} else {
                        EventLog.shared.error("Vlag kon bij signaal \(signalNumber) NIET teruggezet worden. "
                                              + "Herstel handmatig: sudo pmset -a disablesleep 0")
                    }
                }
                // Geen dood socketbestand achterlaten. Een verweesde socket geeft de
                // volgende `dopamine`-aanroep ECONNREFUSED — dat wordt netjes gemeld als
                // "de app draait niet", maar het bestand hoort hier weg te zijn.
                ControlServer.removeSocketFile()
                // Ná de poging hierboven, zodat de markering de échte stand van de blokkade
                // bevat. Hierop besluit het vangnet of dit afsluiten was of wegvallen; een
                // markering die vóór het terugzetten geschreven wordt, liegt in het enige
                // geval dat ertoe doet.
                RestartGuard.recordDeliberateExit(reason: "signaal \(signalNumber)")
                // Wachten tot het logboek echt geschreven is: `exit(0)` gooit weg wat er nog
                // in de wachtrij staat, en dat zijn juist de regels die vertellen waarom de
                // app wegging.
                EventLog.shared.flush()
                exit(0)
            }
            source.resume()
            signalSources.append(source)
        }

        // Workspace notifications live on their own centre, not the default one.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willPowerOffNotification,
            object: nil, queue: .main
        ) { _ in
            // `!= false`, matching the signal handler and `shutdown()`. `== true` treated
            // both an unreadable property and a write powerd had not applied yet (measured
            // 250 ms) as "nothing to do" — on the one path that runs as the machine powers
            // off, where nothing runs after it to notice.
            // Bewust GEEN `RestartGuard.recordDeliberateExit` hier, anders dan in de
            // signaalhandler hierboven en in `finishShutdown()`. Die twee eindigen allebei in
            // `exit()`; deze notificatie is geen belofte dat het proces weggaat. Een uitlogpoging
            // die een andere app afbreekt — een niet-opgeslagen document, een geannuleerd
            // bewaarblad — laat Dopamine Code gewoon doordraaien, en de markering bleef dan op
            // schijf staan met "de blokkade stond uit". Werd de app daarna afgeschoten met
            // `kill -9`, dan las de wachter die markering, concludeerde "dit is niet van ons"
            // en haalde de app nooit meer terug: blokkade aan, geen app, dus geen tijdslimiet,
            // geen accugrens en geen temperatuurbewaking. Precies het gat waarvoor de wachter
            // gebouwd is.
            //
            // Gaat het systeem écht uit, dan volgt hierna een SIGTERM, en die handler schrijft
            // de markering wél — op een pad dat daadwerkelijk eindigt.
            guard SleepFlag.read() != false else { return }
            EventLog.shared.warn("Systeem gaat uit met vlag aan — terugzetten naar 0.")
            let outcome = SleepFlag.set(false, allowPrompt: false)
            if case .verified = outcome {
                EventLog.shared.info("Vlag teruggezet vóór het uitschakelen.")
            } else {
                EventLog.shared.error("Vlag kon vóór het uitschakelen NIET teruggezet worden. "
                                      + "Herstel na de herstart: sudo pmset -a disablesleep 0")
            }
        }
    }

    // MARK: - Privileged writes, off the main thread

    /// Nesting depth of privileged writes.
    ///
    /// A plain boolean was wrong: `attemptRelease` is reachable from the battery and
    /// thermal notifications, which fire whenever the hardware says so — including while
    /// the guardian's own write is already in flight. Two overlapping writes each set the
    /// flag true, and then the first one's `defer` cleared it while the second was still
    /// running, which let a third start. A counter makes `busy` mean what it says.
    private var writeDepth = 0

    /// Runs the privileged write on a background thread. `sudo` is quick, but the
    /// AppleScript authorisation path waits for a human and can block for minutes —
    /// long enough to freeze every timer in the app if it ran here.
    private func write(_ on: Bool, allowPrompt: Bool) async -> SleepFlag.WriteOutcome {
        writeDepth += 1
        busy = true
        defer {
            writeDepth -= 1
            if writeDepth <= 0 {
                writeDepth = 0
                busy = false
            }
        }
        let outcome = await Task.detached(priority: .userInitiated) {
            SleepFlag.set(on, allowPrompt: allowPrompt)
        }.value
        // Keep the published mirror in step immediately. Otherwise anything reading
        // `kernelFlag` shows the pre-write value until the next guardian tick, up to twenty
        // seconds later — and the diagnostics pane in particular sat there insisting the
        // flag was 0 while the menu next to it said the session was running.
        switch outcome {
        case .verified: kernelFlag = on
        case .commandSucceededButFlagWrong(let actual): kernelFlag = actual
        default: kernelFlag = SleepFlag.read()
        }
        return outcome
    }

    private func refreshGrantAsync() async {
        let result = await Task.detached(priority: .utility) { SudoersGrant.check() }.value
        grantStatus = result
    }

    // MARK: - The guardian

    /// The one place that decides whether the flag should still be set.
    ///
    /// It reads the kernel rather than trusting `status`, so a desynchronised or errored
    /// app still releases the flag when the battery runs down, the Mac gets hot or the
    /// timer expires.
    private func startGuardian() {
        guardianTimer?.invalidate()
        let timer = Timer(timeInterval: 20, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.guardianTick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        guardianTimer = timer
    }

    /// Counts guardian ticks, for the things that should happen every N of them rather than
    /// every one: the heartbeat line and the log rotation.
    private var tickCount = 0

    private func guardianTick() async {
        guard !busy else { return }

        let read = SleepFlag.read()
        kernelFlag = read

        // Before anything else: did the machine sleep? That is the only observation that can
        // falsify the one thing this app promises, and it has to be checked whether or not
        // the flag reads cleanly — an unreadable flag is no reason to stop watching.
        checkForSleep(flag: read)

        tickCount += 1
        if (intendedOn || read == true) && tickCount % 15 == 0 {
            logHeartbeat(flag: read)
        }
        // Hourly. Rotation used to run only at launch, so an app that starts at login and
        // runs for weeks never rotated until the one time it did.
        if tickCount % 180 == 0 { EventLog.shared.rotateIfNeeded() }


        wachterSinds = RestartGuard.timeSinceLastRound()

        // Kijken hoort bij élke tik, ook met een lopende sessie. Handelen niet — dat gebeurt
        // verderop, alleen in de tak waar de vlag aantoonbaar op 0 staat.
        //
        // Dit stond eerst één functie verder, samen met het starten, en daardoor bevroor de
        // waarneming zodra er iets liep. Twee gevallen kwamen daaruit voort, allebei met
        // hetzelfde gevolg: een trigger die afging op iets van uren geleden, meteen nadat een
        // vangnet de sessie had beëindigd, en zo de tijdslimiet in de praktijk verdubbelde.
        observeTriggers(flag: read)

        guard let flag = read else {
            // Unreadable is not "all clear". If a session is running, the deadline, the
            // battery floor and the thermal cut-out must still be able to fire — failing
            // open here would silently disable all three for as long as the read fails.
            status = .error(L10n.t("fout.vlag.onleesbaar"))
            if intendedOn, let reason = releaseReason() {
                await forceRelease(reason: reason + " (vlag onleesbaar)")
            }
            return
        }

        // Reconcile. The flag is global; anything on the system could have changed it.
        if !flag {
            safetyNetsDisarmed = false
            // Clear the backoff window too, not just the counter. Leaving
            // `nextReleaseAttempt` armed here meant a failure from a previous episode kept
            // gating an unrelated release minutes later, for up to ten minutes.
            allowImmediateRetry()
            if intendedOn {
                intendedOn = false
                endSession()
                status = .error(L10n.t("fout.buitenuitgezet"))
                EventLog.shared.warn("SleepDisabled werd van buitenaf op 0 gezet; sessie beëindigd.")
                // Uitdrukkelijk géén trigger-evaluatie in deze tik. De vlag viel zojuist van
                // buitenaf weg, en een schema dat daar meteen overheen gaat maakt precies
                // ongedaan wat er net gebeurd is. De volgende tik kijkt opnieuw, met een
                // rustige toestand.
                return
            } else if status.isOn {
                status = .off
                lastMessage = nil
            } else if status.isError {
                // Keep refusals and lock failures on screen. Clearing them here made a
                // rejected activation look like nothing had happened at all.
                if !intendedOn && !safetyNetsDisarmed && lastMessage == nil {
                    status = .off
                }
            }

            // Hier, en nergens anders, mag een trigger een sessie beginnen: de vlag staat
            // aantoonbaar op 0 en er loopt niets. De stópkant zit met opzet ergens anders —
            // in `releaseReason()`, dat alleen loopt als de vlag op 1 staat. Die splitsing is
            // de kern van fase 3: starten is een beslissing over een rustige machine, stoppen
            // is een beslissing over een lopende sessie, en één functie die allebei doet is
            // een functie die de vangnetten kan omzeilen.
            await evaluateTriggers()
            return
        }

        // From here on the kernel flag is 1: the Mac will not sleep.
        if !intendedOn {
            // Say so FIRST. attemptRelease can return early — another write in flight, or
            // a backoff window — and leaving `status` on a calm `.off` while the kernel
            // flag is 1 is exactly the lie this app exists to prevent.
            if !status.isError {
                status = .error(L10n.t("fout.zondersessie"))
            }
            await attemptRelease(reason: "vlag stond aan zonder actieve sessie")
            return
        }

        // Reconcile up to `.on` only from a calm state. Promoting an error would bury a
        // real failure — a lock that did not take, say — under "Blijft actief".
        if case .off = status { status = .on }

        // Re-derive rather than trusting the value set at activation: the grant can be
        // removed, or repaired, while a session is running.
        safetyNetsDisarmed = grantStatus != .granted

        // The lid may have been shut for hours while a dock came and went. This is the
        // only thing that notices.
        evaluateLidSecurity()

        if let reason = releaseReason() {
            await forceRelease(reason: reason)
        }
    }

    // MARK: - Triggers: de enige plek die vanzelf aanzet

    /// Wat er van een trigger-poging terechtkwam, voor de flankbewaking van de aanroeper.
    private enum TriggerUitkomst {
        case gestart
        /// Geweigerd, of er liep al iets. De flank is op: binnen deze episode niet opnieuw
        /// proberen, want een weigering die elke twintig seconden terugkomt is geen melding
        /// meer maar ruis — en een accugrens die net ingreep zou er alsnog door omzeild worden.
        case nietGestart
        /// Er was net iets anders met de vlag bezig. Géén beslissing, dus de flank blijft
        /// staan en de volgende tik probeert het gewoon opnieuw.
        case probeerStraksOpnieuw
    }

    /// Houdt bij wat de triggers zien, zónder er iets mee te doen.
    ///
    /// Draait bij élke guardian-tik, ook met een lopende sessie en ook met een onleesbare
    /// vlag. Alleen kijken: deze functie start niets en stopt niets, en dat is precies wat
    /// hem ongevaarlijk maakt.
    ///
    /// Nodig omdat waarnemen en handelen eerst in één functie zaten, die alleen liep als de
    /// vlag op 0 stond. Tijdens een sessie stond de waarneming dus stil, met twee gevolgen
    /// die allebei op hetzelfde neerkwamen — een vangnet dat afging, en twintig seconden
    /// later een trigger die opnieuw aanzette op iets van uren geleden:
    ///
    /// * Ging een gekozen app om 09:30 draaien terwijl er al een sessie liep, dan bleef dat
    ///   een "nieuwe" app tot de sessie voorbij was. Om 13:00 liet de tijdslimiet los, en om
    ///   13:00:20 zette de app-trigger een tweede sessie van vier uur op. De ingestelde
    ///   limiet werd zo in de praktijk het dubbele — precies het vangnet dat net had gewerkt.
    /// * Ging het schemavenster om 09:00 open terwijl er al een sessie liep, dan werd dat
    ///   venster nooit afgevinkt. Zette je om 10:05 zelf uit, dan stond het schema hem twintig
    ///   seconden later weer aan — woordelijk het gedrag dat het ontwerp wilde uitsluiten.
    ///
    /// Staat de vlag op 0 en loopt er niets, dan doet deze functie niets: dan is `evaluate`
    /// aan de beurt, en die moet de flank zelf nog kunnen zien.
    private func observeTriggers(flag: Bool?) {
        guard flag != false || intendedOn else { return }
        refreshAppTriggerSnapshot()
        // Alleen bij een échte sessie, niet bij een vlag die blijft hangen zonder sessie: dan
        // is de app juist bezig op te ruimen, en hoort het schema zijn venster gewoon nog te
        // krijgen zodra dat gelukt is.
        if intendedOn {
            markSchemaWindowHandled(reason: "er liep al een sessie toen het venster openging.")
        }
    }

    /// Zet de momentopname van draaiende trigger-apps gelijk aan wat er nu draait.
    ///
    /// Zonder edge-detectie met opzet: dit is de "kijken"-helft. Wie de flank wil weten, moet
    /// hem uitrekenen vóórdat dit draait — en dat doet `evaluateAppTriggers`, in de tak waar
    /// er ook iets met die flank gedaan mag worden.
    private func refreshAppTriggerSnapshot() {
        let gekozen = Set(Prefs.appTriggerBundleIDs)
        guard !gekozen.isEmpty, let watch = appTrigger else {
            appsDieDraaiden = []
            return
        }
        appsDieDraaiden = Set(watch.draaiendeApps(gekozen).keys)
    }

    /// Leest de drie triggers uit en start er hooguit één sessie op.
    ///
    /// Wordt uitsluitend aangeroepen vanuit `guardianTick()`, in de tak waarin de kernelvlag
    /// aantoonbaar op 0 staat en er niets loopt. Hij beslist zelf niets over veiligheid:
    /// starten gaat langs `startSession` → `activate`, dus langs dezelfde accugrens, dezelfde
    /// warmtegrens, dezelfde controle op de wachtwoordvrijstelling en dezelfde tijdslimiet
    /// als de schakelaar. Een trigger die zijn eigen `write(true, …)` zou doen, zou alle vier
    /// overslaan; die bestaat hier dan ook niet.
    private func evaluateTriggers() async {
        // Bij bezet niet weigeren maar overslaan: er verandert niets aan de feiten, dus de
        // volgende tik komt er vanzelf op terug. Weigeren zou een flank verbranden voor een
        // toestand die twintig seconden later voorbij is.
        guard !busy, !activationInFlight else {
            if !loggedTriggersSkipped {
                loggedTriggersSkipped = true
                EventLog.shared.info("Trigger-controle overgeslagen: Dopamine Code was net met de "
                                     + "slaapblokkade bezig. De volgende tik kijkt opnieuw.")
            }
            return
        }
        loggedTriggersSkipped = false

        verlopenArmingOpruimen()

        var gestart = false

        // 1. De klep-arming (3.1). Wapenen kan alleen met de klep open, dus "de klep is nu
        //    dicht" ís hier de flank; het consumeren gebeurt vóór de poging, zodat een
        //    mislukte start geen arming achterlaat die twintig seconden later weer afgaat.
        if let arm = lidArm, !arm.isVerlopen(op: Date()),
           SleepFlag.clamshellClosed() ?? lidClosed {
            let uitkomst = await startTrigger(
                SessionRequest(trigger: .klepArming),
                aanleiding: "je had gevraagd om aan te gaan zodra de klep dichtging"
            )
            if uitkomst != .probeerStraksOpnieuw { lidArm = nil }
            gestart = uitkomst == .gestart
        }

        // 2. Apps (3.2). De flank is de overgang niet-draaiend → draaiend. Stoppen loopt
        //    hierna nergens langs deze functie: de sessie krijgt de pid als koppeling mee, en
        //    een app die afgesloten wordt eindigt de sessie via dezelfde clausule onderaan
        //    `releaseReason()` als `dopamine on --until-exit`. Eén stoproute, niet twee.
        gestart = await evaluateAppTriggers(alGestart: gestart)

        // 3. Het schema (3.3).
        await evaluateSchedule(alGestart: gestart)
    }

    /// Een arming die vanzelf verlopen is. Nooit stil: je hebt hem aangezet en erop gerekend.
    private func verlopenArmingOpruimen() {
        guard let arm = lidArm, arm.isVerlopen(op: Date()) else { return }
        lidArm = nil
        let zin = "Het klaarzetten is vervallen: je hebt de klep binnen "
            + "\(Int(LidArm.geldigheid / 60)) minuten niet dichtgedaan. Het wakker houden staat uit."
        EventLog.shared.info(zin)
        lastMessage = zin
    }

    private func evaluateAppTriggers(alGestart: Bool) async -> Bool {
        let gekozen = Set(Prefs.appTriggerBundleIDs)
        guard !gekozen.isEmpty, let watch = appTrigger else {
            appsDieDraaiden = []
            return alGestart
        }

        let draaiendNu = watch.draaiendeApps(gekozen)
        let nuSet = Set(draaiendNu.keys)
        let nieuw = nuSet.subtracting(appsDieDraaiden)
        // De waarneming meteen vastleggen, ook als er hierna niets gestart wordt. Dit is de
        // flank: zonder deze regel zou een geweigerde start elke twintig seconden opnieuw
        // geprobeerd worden zolang Xcode draait, en dat is niet "start zodra hij begint" maar
        // "blijf het proberen zolang hij aanstaat" — precies het niveaugestuurde gedrag dat
        // een vangnet ongedaan kan maken.
        appsDieDraaiden = nuSet

        guard let bundleID = nieuw.sorted().first, let info = draaiendNu[bundleID] else {
            return alGestart
        }
        guard !alGestart else {
            EventLog.shared.info("\(info.naam) ging draaien, maar er is in deze tik al een sessie "
                                 + "gestart; de app-trigger doet niets.")
            return alGestart
        }

        let uitkomst = await startTrigger(
            SessionRequest(trigger: .app(bundleID: bundleID, naam: info.naam),
                           bindToPID: info.pid),
            aanleiding: "\(info.naam) ging draaien"
        )
        // Alleen bij "even bezig" blijft de flank staan; alles anders is een beslissing.
        if uitkomst == .probeerStraksOpnieuw { appsDieDraaiden.remove(bundleID) }
        return uitkomst == .gestart
    }

    private func evaluateSchedule(alGestart: Bool) async {
        guard Prefs.scheduleEnabled else {
            loggedScheduleProblem = nil
            return
        }
        let venster = scheduleWindow

        // Een schema dat aanstaat maar nooit open kan gaan is erger dan geen schema: je
        // rekent erop en er gebeurt niets. Eén regel, en niet elke twintig seconden dezelfde.
        if let probleem = venster.probleem {
            if loggedScheduleProblem != probleem {
                loggedScheduleProblem = probleem
                EventLog.shared.warn("Het schema staat aan, maar \(probleem) — er gaat dus nooit "
                                     + "iets vanzelf aan. Pas het aan bij Instellingen → Zelf aanzetten.")
            }
            return
        }
        loggedScheduleProblem = nil

        guard let begin = venster.begin(op: Date()),
              begin != Prefs.scheduleLastArmedWindowStart
        else { return }

        // In de praktijk heeft `activate` het venster dan al afgevinkt, maar dat mag geen
        // stilzwijgende afspraak tussen twee functies zijn: hier staat het met zoveel woorden.
        guard !alGestart else {
            markSchemaWindowHandled(reason: "er is in deze tik al een sessie gestart.")
            return
        }

        guard let einde = venster.einde(vanBegin: begin) else {
            EventLog.shared.warn("Het einde van het schemavenster was niet uit te rekenen; "
                                 + "er wordt niets gestart.")
            return
        }

        let uitkomst = await startTrigger(
            SessionRequest(trigger: .schema(omschrijving: venster.omschrijving),
                           notLaterThan: einde,
                           notLaterThanReason: "het schema liep tot \(Self.clockText(einde))"),
            aanleiding: "het schema-venster \(venster.omschrijving) ging open"
        )
        switch uitkomst {
        case .gestart:
            markSchemaWindowHandled(reason: "het schema heeft aangezet.")
        case .nietGestart:
            markSchemaWindowHandled(reason: "aanzetten lukte niet; het schema probeert het in "
                                    + "dit venster niet nog eens.")
        case .probeerStraksOpnieuw:
            EventLog.shared.info("Het schemavenster \(venster.omschrijving) is open, maar Dopamine "
                                 + "Code was net bezig; de volgende tik probeert het opnieuw.")
        }
    }

    /// Vinkt het schemavenster af waarin dit moment valt.
    ///
    /// Aangeroepen vanuit `activate` (bij élke sessiestart, ook een handmatige) en vanuit
    /// `evaluateSchedule` als er níet gestart is. Dat het ook bij een handmatige start gebeurt
    /// is met opzet: begon je om 10:00 zelf een sessie binnen het venster en zet je hem om
    /// 10:05 weer uit, dan hoort het schema hem niet twintig seconden later terug te zetten.
    /// Binnen één venster gebeurt er dus hooguit één keer iets, wat er ook tussen zit.
    ///
    /// Schrijft niets als het venster al afgevinkt is, zodat de logregel er precies één is
    /// per vensterovergang — ook als er niet gestart wordt, mét de reden waarom niet. Zonder
    /// die regel is "waarom deed hij vanochtend niks" achteraf onbeantwoordbaar.
    private func markSchemaWindowHandled(reason: String) {
        guard Prefs.scheduleEnabled else { return }
        let venster = scheduleWindow
        guard venster.probleem == nil,
              let begin = venster.begin(op: Date()),
              begin != Prefs.scheduleLastArmedWindowStart
        else { return }
        Prefs.scheduleLastArmedWindowStart = begin
        EventLog.shared.info("Schema-venster \(venster.omschrijving) is open sinds "
                             + "\(Self.clockText(begin)); \(reason)")
    }

    /// Eén trigger-poging, met de melding eromheen die bij een trigger hoort.
    ///
    /// Harde regel 3 weegt hier zwaarder dan bij de schakelaar, want dit gaat af terwijl je er
    /// niet bent. `activate` zet bij een weigering alleen `status` en `lastMessage`, en dat
    /// ziet niemand met de klep dicht. Elke geweigerde poging krijgt daarom een regel in het
    /// logboek mét de naam van de trigger, plus een melding die blijft staan tot je hem leest.
    /// Een gelukte start krijgt geen melding: die zou elke werkdag om 09:00 komen en de vijf
    /// meldingen die er wél toe doen laten verwateren.
    private func startTrigger(_ request: SessionRequest, aanleiding: String) async -> TriggerUitkomst {
        switch await startSession(request) {
        case .gestart(let eind, let minuten):
            let zin = "Vanzelf aangezet omdat \(aanleiding). De Mac blijft wakker tot "
                + "\(Self.clockText(eind)) (\(Self.durationText(minuten)))."
            EventLog.shared.info(zin)
            lastMessage = zin
            return .gestart

        case .liepAl(let eind):
            EventLog.shared.info("\(aanleiding.prefix(1).uppercased() + aanleiding.dropFirst()), "
                                 + "maar er liep al een sessie"
                                 + (eind.map { " tot \(Self.clockText($0))" } ?? "") + ".")
            return .nietGestart

        case .geweigerd(let reden):
            EventLog.shared.warn("Vanzelf aanzetten geweigerd (\(request.trigger.logNaam)): \(reden)")
            lastMessage = L10n.t("melding.trigger.mislukt", aanleiding, reden)
            if request.trigger.isAutomatisch {
                let klok = DateFormatter()
                klok.dateFormat = "HH:mm"
                Notify.post(.triggerRefused,
                            "Om \(klok.string(from: Date())) wilde Dopamine Code vanzelf aanzetten "
                            + "(\(aanleiding)), maar dat kon niet: \(reden)")
            }
            return .nietGestart

        case .bezet:
            EventLog.shared.info("Vanzelf aanzetten (\(request.trigger.logNaam)) uitgesteld: er was "
                                 + "net iets anders met de slaapblokkade bezig.")
            return .probeerStraksOpnieuw
        }
    }

    // MARK: - De klep-arming, van buitenaf bediend

    /// "Zet het wakker houden aan zodra ik de klep dichtdoe", eenmalig.
    ///
    /// Zet alleen een vlag; het aanzetten zelf gebeurt in `evaluateTriggers()`, langs dezelfde
    /// weg als alle andere routes. Deze functie start dus nooit iets.
    func armForLidClose() {
        guard !intendedOn else {
            lastMessage = L10n.t("melding.staat.al.aan")
            return
        }
        // Het gebaar gaat over de vólgende keer dichtklappen. Wapenen met de klep al dicht zou
        // betekenen dat hij meteen afgaat, en dat is iets anders dan waar de knop om vraagt.
        if SleepFlag.clamshellClosed() ?? lidClosed {
            let zin = "De klep is al dicht. Dit gaat over de vólgende keer dat je hem dichtdoet — "
                + "doe hem eerst open. Wil je nu aanzetten, gebruik dan de schakelaar."
            lastMessage = zin
            EventLog.shared.info("Klaarzetten geweigerd: de klep is al dicht.")
            Feedback.failed()
            return
        }
        let arm = LidArm()
        lidArm = arm
        let zin = "Staat klaar: het wakker houden gaat aan zodra je de klep dichtdoet. "
            + "Vervalt vanzelf om \(Self.clockText(arm.verlooptOp))."
        lastMessage = zin
        EventLog.shared.info(zin)
    }

    func cancelArming() {
        guard lidArm != nil else { return }
        lidArm = nil
        lastMessage = L10n.t("melding.nietmeerklaar")
        EventLog.shared.info("Klaarzetten ingetrokken.")
    }

    // MARK: - App-triggers, van buitenaf bediend

    /// Voegt een app toe als trigger.
    ///
    /// Draait hij op dit moment al, dan telt dat meteen als "gezien": een trigger die afgaat
    /// op het moment dat je hem instelt is niet wat "start zodra deze app begint" betekent.
    func addAppTrigger(bundleID: String, naam: String) {
        guard !bundleID.isEmpty else { return }
        var lijst = Prefs.appTriggerBundleIDs
        guard !lijst.contains(bundleID) else { return }
        lijst.append(bundleID)
        Prefs.appTriggerBundleIDs = lijst
        var namen = Prefs.appTriggerNames
        namen[bundleID] = naam
        Prefs.appTriggerNames = namen
        if appTrigger?.draaiendeApps([bundleID])[bundleID] != nil {
            appsDieDraaiden.insert(bundleID)
            lastMessage = L10n.t("melding.trigger.draaital", naam)
        } else {
            lastMessage = L10n.t("melding.trigger.ingesteld", naam)
        }
        EventLog.shared.info("App-trigger toegevoegd: \(naam) (\(bundleID)).")
        objectWillChange.send()
    }

    func removeAppTrigger(bundleID: String) {
        let naam = Prefs.appTriggerName(bundleID)
        Prefs.appTriggerBundleIDs = Prefs.appTriggerBundleIDs.filter { $0 != bundleID }
        var namen = Prefs.appTriggerNames
        namen[bundleID] = nil
        Prefs.appTriggerNames = namen
        appsDieDraaiden.remove(bundleID)
        EventLog.shared.info("App-trigger verwijderd: \(naam) (\(bundleID)).")
        objectWillChange.send()
    }

    /// Het schema opnieuw instellen vanuit het venster Instellingen.
    ///
    /// Wist de flankbewaking, want anders zou een schema dat je zojuist op "nu" zet pas morgen
    /// afgaan omdat het venster van vandaag toevallig al afgevinkt was. Een wijziging door een
    /// mens is een nieuw schema, niet hetzelfde schema opnieuw.
    func scheduleSettingsChanged() {
        Prefs.scheduleLastArmedWindowStart = nil
        loggedScheduleProblem = nil
        objectWillChange.send()
        Task { await guardianTick() }
    }

    /// The Mac slept. If that happened while we were holding it awake, the app's single
    /// promise was not kept and nothing else in here would ever have noticed.
    private func checkForSleep(flag: Bool?) {
        guard let episode = sleepWatch?.sample() else { return }

        // Sleeping with the flag down is ordinary and says nothing about the mechanism.
        guard intendedOn || flag == true else {
            EventLog.shared.info("Buiten een sessie: \(episode.describe()).")
            return
        }

        sleepDuringSession = episode

        // Say which of the two situations this was, everywhere — not just in the log line.
        //
        // This branch also runs when a session is live but the flag has already been cleared
        // from outside the app (`sudo pmset -a disablesleep 0`, the very command the README
        // and every error message here hand out). The Mac then sleeps entirely correctly,
        // and blaming the kernel veto for it would be a false accusation on all four
        // channels at once: log, status, panel and notification.
        let flagWasUp = flag == true
        let context = L10n.t(flagWasUp ? "slaap.context.aan" : "slaap.context.uit")
        let verdict = L10n.t(flagWasUp ? "slaap.oordeel.aan" : "slaap.oordeel.uit")
        let sentence = episode.describe().prefix(1).uppercased() + episode.describe().dropFirst()

        EventLog.shared.log(
            flagWasUp ? .error : .warn,
            (flagWasUp ? "BELOFTE NIET GEHAALD — " : "Mac sliep tijdens een sessie — ")
            + "\(episode.describe()), \(context)." + verdict
        )
        status = .error(L10n.t(flagWasUp ? "menu.gebroken.wel" : "menu.gebroken.niet"))
        lastMessage = L10n.t("slaap.zin", sentence, context) + verdict
            + (flagWasUp ? L10n.t("slaap.verifytip") : "")
        sleepBrokeThePromise = flagWasUp
        Feedback.failed()
        Notify.post(.macSlept, L10n.t("slaap.zin", sentence, context) + verdict)
    }

    /// One line every five minutes while the flag is up.
    ///
    /// Without this a quiet night and a process that died at 23:12 leave exactly the same
    /// trace: nothing at all. The real session of 11 August ran from 17:58 to 19:43 and
    /// produced zero log lines in between. Everything here is either already in hand or a
    /// cheap read; nothing spawns a process.
    private func logHeartbeat(flag: Bool?) {
        var parts: [String] = ["vlag \(flag.map { $0 ? "1" : "0" } ?? "onleesbaar")"]
        if let battery {
            parts.append("accu \(battery.percent)%\(battery.onAC ? " (lader)" : " (accu)")")
        }
        let closed = SleepFlag.clamshellClosed() ?? lidClosed
        parts.append(closed ? "klep dicht" : "klep open")
        if DisplayControl.externalDisplayActive { parts.append("extern scherm") }
        parts.append(DisplayControl.mainDisplayAsleep ? "scherm uit" : "scherm AAN")
        parts.append("warmte \(thermal.label)")
        if let remaining = remainingText { parts.append(remaining) }
        EventLog.shared.info("Hartslag: " + parts.joined(separator: ", ") + ".")
        checkRestartGuardIsAwake()
    }

    /// Zodat deze waarschuwing één keer per keer dat de app draait komt, en niet elk kwartier.
    private var warnedAboutStaleGuard = false

    /// Kijkt of het vangnet nog kijkt.
    ///
    /// Het vangnet is een LaunchAgent, en die kan uitgezet worden bij Systeeminstellingen →
    /// Algemeen → Inloggen en extensies, of hij kan nooit geladen zijn. Dan is hij er stil niet
    /// meer, en dat is erger dan geen vangnet: iedereen denkt dan dat het gat van fase 2 dicht
    /// is. Deze regel hangt bewust aan de hartslag, dus hij komt alleen langs terwijl de Mac
    /// daadwerkelijk wakker gehouden wordt — precies wanneer het uitmaakt.
    private func checkRestartGuardIsAwake() {
        guard !warnedAboutStaleGuard else { return }
        let leeftijd = RestartGuard.timeSinceLastRound()
        guard leeftijd.map({ $0 > 300 }) ?? true else { return }
        warnedAboutStaleGuard = true
        let hoelang = leeftijd.map { "al \(Int($0 / 60)) minuten" } ?? "nog nooit"
        let zin = "De wachter heeft \(hoelang) gekeken. Zolang dat zo blijft, blijft de Mac "
            + "wakker als Dopamine Code hard afgeschoten wordt. Kijk bij Systeeminstellingen → "
            + "Algemeen → Inloggen en extensies of Dopamine Code op de achtergrond mag draaien, "
            + "of gebruik 'Wachter herstellen' bij Instellingen → Diagnose."
        EventLog.shared.warn(zin)
        // Ook in het paneel, niet alleen in het logboek. Dit gaat over een vangnet dat er stil
        // niet meer is — precies het geval waarin niemand uit zichzelf het logboek opslaat, en
        // waarvoor lichtere gebeurtenissen (een geweigerde trigger) wél een regel krijgen.
        // Géén melding: die zou aankomen terwijl er niets aan de hand lijkt, en de vier
        // gebeurtenissen die 's nachts echt tellen laten verwateren.
        lastMessage = zin
    }

    /// Whether any safety net says the flag should come off right now.
    ///
    /// De volgorde is niet vrijblijvend. De tijdslimiet, de accugrens en de warmtegrens
    /// staan bovenaan en de proceskoppeling eronder: een gekoppeld proces dat vastloopt mag
    /// de timer niet uitstellen. Er komt hier nooit een vroege `return nil` bij.
    private func releaseReason() -> String? {
        if let deadline {
            if Date() >= deadline { return deadlineReason }
        } else if intendedOn {
            // A running session with no deadline has no timer at all. Rather than let it
            // run forever, treat the missing deadline as the fault it is.
            return L10n.t("reden.geeneindtijd")
        }
        if let battery, !battery.onAC, battery.percent <= Prefs.batteryFloor {
            return L10n.t("reden.accu", battery.percent, Prefs.batteryFloor)
        }
        if thermal == .critical {
            return L10n.t("reden.warm")
        }
        // Onderaan, na de drie vangnetten: de enige nieuwe beslissing van fase 1. De
        // procesbewaking meldt alleen een feit; dat een sessie daardoor eindigt staat hier,
        // en het beëindigen zelf loopt langs precies dezelfde weg als een verlopen timer.
        if let binding {
            let nu = ProcessWatch.identify(binding.identity.pid)
            if nu == nil || !(nu!.isSameProcess(as: binding.identity)) {
                notePollDetectedExit()
                // Een hergebruikte pid telt als verdwenen: het is een ander programma.
                let hergebruikt = nu != nil
                return L10n.t("reden.procesklaar", binding.identity.label)
                    + (hergebruikt ? L10n.t("reden.pidhergebruikt") : "")
            }
        }
        return nil
    }

    /// De poll merkte de exit. Was de snelle route erbij, dan hoort die dat als eerste te
    /// hebben gemeld; deed hij dat niet, dan is hij op deze machine niet te vertrouwen en
    /// dat is stille degradatie — precies het soort ding dat je pas maanden later ontdekt.
    private func notePollDetectedExit() {
        guard var current = binding else { return }
        guard current.watcher != nil, !current.fastRouteReported, !current.loggedSlowDetection else { return }
        current.loggedSlowDetection = true
        binding = current
        EventLog.shared.warn(
            "De snelle procesmelding kwam niet; pas de controle van twintig seconden merkte dat "
            + "\(current.identity.label) weg was. De koppeling werkt, maar reageert trager."
        )
    }

    private func forceRelease(reason: String) async {
        EventLog.shared.warn("Vangnet grijpt in: \(reason).")
        intendedOn = false
        await attemptRelease(reason: reason)
        if case .off = status {
            lastMessage = L10n.t("melding.autogestopt", reason)
            // This is the message that most needs to survive until someone reads it: it
            // fires unattended, hours in, and the sound it used to make played to an empty
            // room. The clock is in the body because "just now" is meaningless by morning.
            let clock = DateFormatter()
            clock.dateFormat = "HH:mm"
            Notify.post(.sessionEnded, "Om \(clock.string(from: Date())): \(reason). De Mac mag weer slapen.")
        }
    }

    /// Tries to clear the flag without a prompt, and keeps trying. A prompt is deliberately
    /// not raised here: this runs with the lid shut and the screen locked, where an
    /// authorisation sheet would be stranded behind the login window and nothing at all
    /// would happen.
    private func attemptRelease(reason: String) async {
        // Snapshot the session this release belongs to. `write` suspends, and a new session
        // can be armed while it is suspended; tearing that one down would gut a session
        // nobody asked to end.
        let sessionAtEntry = sessionStart
        // Reachable from the battery notification, the thermal notification and the
        // guardian tick, any of which can fire while another write is already running.
        // Let the one in flight finish; whatever it does not fix, the next tick will.
        guard !busy else { return }
        // Respect the backoff unless the user just did something that could have fixed it.
        if let next = nextReleaseAttempt, Date() < next { return }

        let outcome = await write(false, allowPrompt: false)
        switch outcome {
        case .verified:
            allowImmediateRetry()
            safetyNetsDisarmed = false
            // A retry that finally lands must take the failure text with it. Otherwise the
            // "kon de vlag niet terugzetten" line from the first attempt stayed on screen
            // under a calm moon icon indefinitely: the flag-is-0 branch of the guardian only
            // clears `lastMessage` when the status is on or errored, and by then it is `.off`.
            lastMessage = nil
            guard sessionStart == sessionAtEntry else {
                EventLog.shared.warn("Release voltooid terwijl er al een nieuwe sessie liep; die blijft staan.")
                return
            }
            endSession()
            status = .off
            EventLog.shared.info("Wakker houden UIT (\(reason)).")
            Feedback.deactivated()
        default:
            releaseAttempts += 1
            safetyNetsDisarmed = true
            status = .error(L10n.t("fout.vastzit"))
            lastMessage = L10n.t("melding.stoppen.mislukt", reason)

            // 20s, 40s, 80s … capped at 10 minutes. Still persistent enough to recover the
            // moment the grant appears, without hammering for hours.
            let backoff = min(20.0 * pow(2, Double(releaseAttempts - 1)), 600)
            nextReleaseAttempt = Date().addingTimeInterval(backoff)

            // Loud, but not once every twenty seconds all night.
            if lastFailureAlarm == nil || Date().timeIntervalSince(lastFailureAlarm!) > 300 {
                lastFailureAlarm = Date()
                Feedback.failed()
                EventLog.shared.error(
                    "Poging \(releaseAttempts) om de vlag terug te zetten mislukte (\(reason)). "
                    + "Volgende poging over \(Int(backoff))s."
                )
                // Inside the throttle on purpose. Outside it this would post every twenty
                // seconds all night for one unchanging problem.
                Notify.post(.releaseFailed,
                            "Poging \(releaseAttempts) om te stoppen mislukte (\(reason)). Zet het "
                            + "zelf terug in Terminal met: sudo pmset -a disablesleep 0")
                // Re-checking the grant costs two more processes, so only do it alongside
                // the throttled alarm rather than on every failed attempt.
                await refreshGrantAsync()
            }
        }
    }

    /// Clears the backoff so a retry happens on the next tick. Called when the user has
    /// done something that plausibly fixed the cause.
    private func allowImmediateRetry() {
        nextReleaseAttempt = nil
        releaseAttempts = 0
    }

    /// Tears down everything that belongs to a running session. Deliberately does *not*
    /// touch the flag: the caller does that first, and only on success does this run.
    private func endSession() {
        // One closing line, so the log has a boundary rather than just stopping. Written
        // before the teardown wipes the fields it reports on.
        if let start = sessionStart {
            let minutes = Int(Date().timeIntervalSince(start) / 60)
            var parts = [String(format: "gedraaid %d u %02d m", minutes / 60, minutes % 60)]
            if let battery { parts.append("accu nu \(battery.percent)%") }
            if displayRelitCount > 0 { parts.append("scherm \(displayRelitCount)× opnieuw uitgezet") }
            if let network, !network.outages.isEmpty { parts.append("\(network.outages.count) netwerkstoring(en)") }
            if let sleepDuringSession { parts.append("LET OP: \(sleepDuringSession.describe())") }
            EventLog.shared.info("Sessie afgesloten — " + parts.joined(separator: ", ") + ".")
        }
        displayRelitCount = 0
        EventLog.shared.rotateIfNeeded()
        securedForCurrentLidClose = false
        // Outage reports belong to the session that observed them. Leaving one pending let
        // a seven-second blip from 12:15 be announced at 12:57 — after the session had
        // ended — as though the connection were down right then. Seen in the real log.
        pendingOutageReport = nil
        reportedOutageSummary = nil
        // Connectivity is a property of a running session. Leaving it on `false` after a
        // session that ended offline made the menu report "geen verbinding" indefinitely,
        // long after the network was back.
        online = true
        deadline = nil
        sessionStart = nil
        // Alle drie de sessie-instellingen weg, niet alleen de eindtijd: anders lekt een
        // sessie zijn duur, zijn bovengrens of zijn proceskoppeling de volgende in — en dan
        // stopt een sessie die niemand koppelde alsnog op een proces van een uur geleden.
        sessionLimitMinutes = nil
        sessionNotLaterThan = nil
        sessionCapReason = nil
        deadlineReason = "de ingestelde tijd was om"
        sessionTrigger = nil
        clearBinding()
        displayReassertTimer?.invalidate()
        displayReassertTimer = nil
        thermalWatch?.stop()
        cpuSpeedLimit = nil
        thermal = .nominal
        if let network {
            network.stop()
            outages = network.outages
        }
        network = nil
        networkWatched = false
        // The list is kept — it is the after-the-fact report the whole feature exists for —
        // but it stops calling itself "deze sessie". At 14:00 with keep-awake off, a heading
        // saying "this session" above two outages from last night's run is simply false.
        outagesFromFinishedSession = !outages.isEmpty
    }

    // MARK: - The main toggle

    func setKeepAwake(_ on: Bool) {
        guard !busy else { return }
        Task {
            if on {
                _ = await startSession(SessionRequest(trigger: .schakelaar))
            } else {
                _ = await stopSession(reason: "handmatig", allowPrompt: true)
            }
        }
    }

    // MARK: - De sneltoets

    private var shortcut: GlobalShortcut?

    /// De sneltoets zoals hij nu staat, of `nil` als er geen opgenomen is.
    @Published private(set) var shortcutOmschrijving: String?
    /// Wat er mis is met de sneltoets. Nooit stil: een combinatie die niet geregistreerd kon
    /// worden doet niets, en dat is van buitenaf niet te onderscheiden van een combinatie die
    /// je verkeerd onthouden hebt.
    @Published private(set) var shortcutProbleem: String?

    /// Zet de sneltoets zoals hij in de instellingen staat. Bij het starten en na elke wijziging.
    func applyShortcut() {
        let toets = shortcut ?? GlobalShortcut()
        shortcut = toets
        // `max(0, …)` omdat dit uit UserDefaults komt: een met de hand bewerkte of beschadigde
        // waarde mag geen crash opleveren in een functie die bij elke start draait.
        let uitkomst = toets.apply(keyCode: Prefs.shortcutKeyCode,
                                   modifierFlags: UInt(max(0, Prefs.shortcutModifiers))) { [weak self] in
            // De Carbon-handler draait op de hoofdthread, maar dat weet de compiler niet.
            Task { @MainActor in self?.toggleFromShortcut() }
        }
        switch uitkomst {
        case .gezet(let combinatie):
            shortcutOmschrijving = combinatie
            shortcutProbleem = nil
            EventLog.shared.info("Sneltoets \(combinatie) staat klaar.")
        case .geen:
            shortcutOmschrijving = nil
            shortcutProbleem = nil
        case .mislukt(let waarom):
            shortcutOmschrijving = nil
            shortcutProbleem = waarom
            EventLog.shared.error("Sneltoets werkt niet: \(waarom)")
        }
    }

    /// Neemt een nieuwe combinatie op, of wist hem als `keyCode` nil is.
    func setShortcut(keyCode: Int?, modifierFlags: UInt) {
        Prefs.shortcutKeyCode = keyCode
        Prefs.shortcutModifiers = Int(modifierFlags)
        applyShortcut()
    }

    /// De sneltoets doet precies hetzelfde als de schakelaar, langs precies dezelfde weg.
    ///
    /// Geen eigen aan/uit-stand: hij leest `intendedOn` op het moment van indrukken. Een
    /// sneltoets die zelf onthoudt of hij "aan" staat loopt uit de pas met de kernel zodra een
    /// vangnet een sessie beëindigt — en dan zet de eerste druk daarna niets aan, maar iets uit
    /// dat al uit was. Om dezelfde reden staat hier geen `SleepFlag` en geen eigen controle:
    /// de accugrens, de temperatuurbewaking en de wachtwoordvrijstelling zitten in `activate`,
    /// en daar hoort deze ingang net zo goed langs als alle andere.
    func toggleFromShortcut() {
        // `setKeepAwake` keert hier stil terug. Bij de schakelaar mag dat — die staat dan
        // zichtbaar uitgeschakeld in het paneel waar je net op klikte. Bij een sneltoets met
        // het paneel dicht ziet niemand iets, en dan is stilte precies de verkeerde uitkomst.
        guard !busy else {
            EventLog.shared.info("Sneltoets genegeerd: er was net iets anders met de slaapblokkade bezig.")
            Feedback.failed()
            return
        }
        let aanzetten = !intendedOn
        Task {
            guard aanzetten else {
                _ = await stopSession(reason: "sneltoets", allowPrompt: true)
                return
            }
            switch await startSession(SessionRequest(trigger: .sneltoets)) {
            case .gestart:
                break
            case .liepAl:
                EventLog.shared.info("Sneltoets: er liep al een sessie; er is niets veranderd.")
                Feedback.failed()
            case .geweigerd(let reden):
                // Bewust géén melding: meldingen gaan over wat er gebeurt terwijl je wég bent,
                // en er zijn er al zes. Je staat hier aan het toetsenbord. Het geluid komt van
                // `activate` zelf — elke weigering daar speelt `Feedback.failed()` — dus hier
                // alleen de logregel, met de ingang erbij zodat achteraf te zien is dat het de
                // sneltoets was en niet de schakelaar.
                EventLog.shared.warn("Sneltoets: aanzetten geweigerd — \(reden)")
            case .bezet:
                EventLog.shared.info("Sneltoets: er was net iets anders met de slaapblokkade bezig.")
                Feedback.failed()
            }
        }
    }

    /// Hoe laat de lopende sessie begon.
    ///
    /// Alleen om in de geschiedenis de sessie die nú loopt te herkennen: die staat in het
    /// logboek ook zonder afsluitregel, en zonder dit zou hij daar als "de app is weggevallen"
    /// verschijnen terwijl hij gewoon draait. De geschiedenis leest het logboek; of er iets
    /// loopt komt hiervandaan.
    var sessionStartedAt: Date? { sessionStart }

    /// De enige publieke manier om een sessie te starten — voor de schakelaar, de
    /// opdrachtregel en alles wat er nog bij komt.
    ///
    /// Vier ingangen die elk hun eigen controles nabouwen is vier keer de kans dat er eentje
    /// de accugrens, de warmtegrens of de wachtwoordvrijstelling vergeet.
    func startSession(_ request: SessionRequest) async -> SessionStartResult {
        guard !busy, !activationInFlight else { return .bezet }
        if intendedOn { return adjustRunningSession(request) }
        return await activate(request)
    }

    /// Wat er gebeurt als er al een sessie loopt.
    ///
    /// Nooit een tweede sessie en nooit een stilzwijgende verlenging: een buildscript dat in
    /// een lus `dopamine on` roept zou de tijdslimiet anders eindeloos vooruitschuiven, en
    /// dan is het vangnet weg zonder dat iemand iets ziet. Dezelfde val staat al beschreven
    /// bij de schakelaar in MenuView (regel 64-71). Korter mag wel, en een koppeling zetten
    /// of vervangen ook — dat maakt een sessie alleen maar strakker begrensd.
    private func adjustRunningSession(_ request: SessionRequest) -> SessionStartResult {
        // Eerst alles controleren, dan pas iets veranderen: een verzoek dat half doorgaat
        // laat een sessie achter die niemand zo gevraagd heeft.
        var nieuweKoppeling: ProcessWatch.Identity?
        if let pid = request.bindToPID {
            guard let identity = ProcessWatch.identify(pid) else {
                EventLog.shared.warn("Koppelen van de lopende sessie aan pid \(pid) geweigerd: "
                                     + "dat proces bestaat niet (meer).")
                return .geweigerd(reden: "Proces \(pid) bestaat niet (meer). De sessie loopt gewoon door.")
            }
            nieuweKoppeling = identity
        }

        var nieuweEindtijd: (date: Date, reason: String)?
        if request.limitMinutes != nil || request.notLaterThan != nil {
            guard let start = sessionStart, let huidige = deadline else {
                return .geweigerd(reden: "Er loopt een sessie zonder eindtijd; die wordt vanzelf gestopt. "
                                  + "Probeer het zo opnieuw.")
            }
            let gevraagd = computeDeadline(start: start,
                                           limitMinutes: request.limitMinutes ?? sessionLimitMinutes,
                                           notLaterThan: request.notLaterThan ?? sessionNotLaterThan,
                                           capReason: request.notLaterThan != nil
                                               ? request.notLaterThanReason : sessionCapReason)
            guard gevraagd.date <= huidige else {
                return .geweigerd(reden: "Een lopende sessie wordt niet verlengd — stop de sessie eerst. "
                                  + "Hij loopt nu tot \(Self.clockText(huidige)).")
            }
            nieuweEindtijd = gevraagd
        }

        if let identity = nieuweKoppeling {
            clearBinding()
            binding = makeBinding(identity)
            EventLog.shared.info("Lopende sessie gekoppeld aan \(identity.label) "
                                 + "(\(request.trigger.logNaam)).")
        }
        if let eind = nieuweEindtijd {
            if let m = request.limitMinutes { sessionLimitMinutes = m }
            if let cap = request.notLaterThan {
                sessionNotLaterThan = cap
                sessionCapReason = request.notLaterThanReason
            }
            deadline = eind.date
            deadlineReason = eind.reason
            EventLog.shared.info("Lopende sessie ingekort tot \(Self.clockText(eind.date)) "
                                 + "(\(request.trigger.logNaam)).")
            Task { await guardianTick() }
        }
        return .liepAl(deadline: deadline)
    }

    /// Haalt de proceskoppeling weg én zet de bewaker stil.
    ///
    /// Die twee horen bij elkaar: een `ExitWatcher` die blijft leven nadat de koppeling weg
    /// is, meldt straks het einde van een proces waar niets meer aan hangt. Er waren drie
    /// plekken die dit paarsgewijs deden en één die het vergat, dus staat het nu op één plek.
    private func clearBinding() {
        binding?.watcher?.cancel()
        binding = nil
    }

    /// Maakt de koppeling en zet de snelle melding erop.
    ///
    /// Die melding doet precies één ding: de guardian aanstoten. Of de sessie hierdoor stopt
    /// beslist `releaseReason()`, en die kijkt naar de kerneltabel — niet naar deze melding.
    private func makeBinding(_ identity: ProcessWatch.Identity) -> SessionBinding {
        var fresh = SessionBinding(identity: identity)
        guard identity.uid == getuid() else {
            // Hier gemeten: een procesbron vuurt nooit voor een proces van een andere
            // gebruiker. Dan blijft de poll over — die geeft het antwoord toch al, alleen
            // een tik later. Wel opschrijven, anders lijkt het of de snelle route stuk is.
            EventLog.shared.info("\(identity.label) is van een andere gebruiker; deze koppeling "
                                 + "wordt alleen door de controle van twintig seconden bewaakt, niet door een directe melding.")
            return fresh
        }
        fresh.watcher = ProcessWatch.ExitWatcher(pid: identity.pid) { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                // Alleen als de koppeling nog van dit proces is: een sessie kan inmiddels aan
                // iets anders hangen, en dan zegt deze melding niets meer.
                if self.binding?.identity.isSameProcess(as: identity) == true {
                    self.binding?.fastRouteReported = true
                }
                await self.guardianTick()
            }
        }
        if fresh.watcher == nil {
            EventLog.shared.warn("Voor \(identity.label) kon geen directe exit-melding gezet worden; "
                                 + "alleen de controle van twintig seconden bewaakt deze koppeling.")
        }
        return fresh
    }

    private func activate(_ request: SessionRequest) async -> SessionStartResult {
        // `guard !busy` dekt de twee onderbrekingspunten hieronder niet — de grantcontrole en
        // de privileged schrijf — en met de opdrachtregel erbij kunnen daar twee aanroepen
        // tegelijk doorheen. `defer` zodat elke vroege terugkeer hem ook weer opent.
        activationInFlight = true
        defer { activationInFlight = false }

        // Refuse to start a session that the battery rule would immediately end.
        if let battery, !battery.onAC, battery.percent <= Prefs.batteryFloor {
            status = .error(L10n.t("fout.accu", battery.percent, Prefs.batteryFloor))
            lastMessage = L10n.t("melding.lader")
            Feedback.failed()
            EventLog.shared.warn("Activeren geweigerd: batterij \(battery.percent)%.")
            return .geweigerd(reden: "Accu \(battery.percent)%, onder je grens van \(Prefs.batteryFloor)%. "
                              + "Sluit de lader aan, of verlaag de accugrens.")
        }
        // Read the live state, not the cached one: `thermal` is only fed by ThermalWatch,
        // which is started inside a session and reset to .nominal when one ends — so the
        // cached value is ALWAYS .nominal here and this guard could never fire.
        thermal = ThermalWatch.Pressure(ProcessInfo.processInfo.thermalState)
        if thermal == .critical {
            status = .error(L10n.t("fout.temperatuur"))
            lastMessage = L10n.t("melding.afkoelen")
            Feedback.failed()
            EventLog.shared.warn("Activeren geweigerd: temperatuur kritiek.")
            return .geweigerd(reden: "De Mac is te warm. Wacht tot hij is afgekoeld en probeer het opnieuw.")
        }

        // Bestaat het proces waaraan gekoppeld moet worden? Vóór de schrijfactie, want een
        // procesbron op een dode pid vuurt meteen (hier gemeten) — dat zou een sessie
        // opleveren die één tik later alweer stopt, met een schrijf naar de kernelvlag heen
        // en terug voor niets.
        var koppeling: ProcessWatch.Identity?
        if let pid = request.bindToPID {
            guard let identity = ProcessWatch.identify(pid) else {
                status = .error(L10n.t("fout.procesbestaatniet"))
                lastMessage = L10n.t("melding.procesweg", pid)
                Feedback.failed()
                EventLog.shared.warn("Activeren geweigerd: pid \(pid) bestaat niet (meer).")
                return .geweigerd(reden: "Proces \(pid) bestaat niet (meer); er is niets gestart.")
            }
            koppeling = identity
        }

        // A session that cannot be ended without a password must never be started.
        //
        // Every unattended release — the deadline, the battery floor, the thermal cut-out —
        // goes through `write(false, allowPrompt: false)`, under a shut lid and a locked
        // screen where no prompt can ever be answered. Without the grant, the one-off admin
        // prompt below would still succeed in setting the flag, and then nothing could ever
        // clear it: the Mac would run at full wake until the battery was flat, and because
        // `disablesleep` is a persisted preference the flag would survive the power-off and
        // the next boot could not clear it either.
        //
        // Checking after the write is too late — that is when the screen gets locked and
        // takes the warning with it.
        await refreshGrantAsync()
        guard grantStatus == .granted else {
            status = .error(L10n.t("fout.stopzoumislukken"))
            lastMessage = L10n.t("melding.grant.eerst", grantText)
            Feedback.failed()
            EventLog.shared.warn("Activeren geweigerd: \(grantText).")
            return .geweigerd(reden: "\(grantText). Zonder die regel kunnen de tijdslimiet, de "
                              + "accugrens en de temperatuurbewaking de Mac later niet vanzelf weer "
                              + "laten slapen. Installeer hem bij Instellingen → Diagnose.")
        }

        // De enige `write(true, ...)` in de hele codebase. Elke ingang komt hier langs, dus
        // langs alle drie de weigeringen hierboven.
        let outcome = await write(true, allowPrompt: request.trigger.mayPrompt)
        switch outcome {
        case .verified:
            break
        case .needsAuthorisation:
            status = .error(L10n.t("fout.geentoestemming"))
            lastMessage = L10n.t("melding.grant.installeer")
            await refreshGrantAsync()
            Feedback.failed()
            return .geweigerd(reden: "Geen toestemming om de slaapblokkade aan te zetten. "
                              + "Installeer de wachtwoordvrijstelling bij Instellingen → Diagnose.")
        case .cancelled:
            // Never claim "off" on the strength of a dialog the user dismissed. The write
            // may already have gone through before the sheet was cancelled, and the sheet
            // itself proves nothing about the kernel. Ask, and let the guardian clean up.
            intendedOn = false
            // `!= false`: `read()` has three outcomes and `nil` used to fall into the calm
            // branch — the exact collapse the comment above forbids. An unreadable flag
            // after a cancelled prompt is the case where it matters most.
            if SleepFlag.read() != false {
                status = .error(L10n.t("fout.zondersessie"))
                lastMessage = L10n.t("melding.geannuleerd.mogelijkaan")
                await attemptRelease(reason: "geannuleerd tijdens aanzetten")
            } else {
                status = .off
                lastMessage = L10n.t("melding.geannuleerd")
            }
            return .geweigerd(reden: "Geannuleerd bij het vragen om toestemming.")
        case .commandSucceededButFlagWrong(let actual):
            status = .error(L10n.t("fout.onverwacht"))
            lastMessage = L10n.t("melding.vlag.anders",
                                 actual.map { $0 ? "1" : "0" } ?? L10n.t("melding.onleesbaar"))
            Feedback.failed()
            return .geweigerd(reden: "Het commando gaf geen fout, maar de slaapblokkade staat op "
                              + "\(actual.map { $0 ? "1" : "0" } ?? "onleesbaar") in plaats van op 1.")
        case .failed(let message):
            status = .error(L10n.t("fout.nietgelukt"))
            lastMessage = message
            Feedback.failed()
            return .geweigerd(reden: "Wakker houden is niet gelukt: \(message)")
        }

        intendedOn = true
        sessionTrigger = request.trigger
        status = .on
        lastMessage = nil
        // Een arming die nog stond is niet meer aan de orde: er loopt al iets. Hier en niet in
        // `endSession`, zodat dit voor élke route geldt — de schakelaar, de opdrachtregel en de
        // triggers — in plaats van alleen voor de weg waarlangs de arming zelf afgaat.
        if lidArm != nil {
            lidArm = nil
            EventLog.shared.info("Het klaarzetten is vervallen: er loopt nu een sessie.")
        }
        // Binnen een schemavenster telt elke sessiestart als "dit venster is gehad". Zonder
        // dat zou het schema een sessie die je om 10:05 zelf uitzette twintig seconden later
        // terugzetten, en zou een vangnet dat om 15:29 ingreep in een handmatige sessie alsnog
        // door het schema ongedaan gemaakt worden. Bij het schema zelf doet `evaluateSchedule`
        // het afvinken, met een zin die zegt dat hij het was.
        if case .schema = request.trigger {} else {
            markSchemaWindowHandled(reason: "er loopt sinds \(Self.clockText(Date())) een sessie, "
                                    + "dus het schema doet in dit venster niets meer.")
        }
        // Both halves of the backoff, not just the counter: a stale `nextReleaseAttempt`
        // left over from an earlier failure would otherwise gate this session's first
        // release for up to ten minutes.
        allowImmediateRetry()
        lastFailureAlarm = nil

        let start = Date()
        sessionStart = start
        sessionLimitMinutes = request.limitMinutes
        sessionNotLaterThan = request.notLaterThan
        sessionCapReason = request.notLaterThanReason
        applyDeadline(start: start)
        // Onvoorwaardelijk wissen, niet alleen overschrijven als er een nieuwe koppeling is.
        // Elk ander sessieveld hierboven wordt hoe dan ook gezet; `binding` stond achter de
        // `if let` en bleef dus staan als deze sessie er geen had. `endSession()` ruimt hem
        // óók op, maar draait niet als het terugzetten van de vlag mislukte — en juist dan
        // begint er even later een nieuwe sessie die de koppeling van de vorige erft en
        // binnen twintig seconden stopt op een proces dat niemand aan haar koppelde.
        clearBinding()
        if let identity = koppeling { binding = makeBinding(identity) }
        displayRelitCount = 0
        // A finding from a previous session must not haunt this one; it has been logged.
        sleepDuringSession = nil

        // Stop any previous monitor before replacing it: an abandoned NWPathMonitor keeps
        // delivering path updates into a callback whose session no longer exists.
        network?.stop()
        let session = NetworkMonitor()
        session.onStateChange = { [weak self] online, outage in
            self?.handleNetwork(online: online, outage: outage)
        }
        session.start()
        network = session
        networkWatched = true
        outages = []
        outagesFromFinishedSession = false
        pendingOutageReport = nil
        reportedOutageSummary = nil

        thermalWatch?.start()
        thermal = thermalWatch?.pressure ?? .nominal

        // Context for the log, NOT a health check. Measured on this Mac: with
        // SleepDisabled flipped from 0 to 1, AppleClamshellCausesSleep stayed Yes —
        // it tracks clamshell/desktop-mode policy, not the sleep veto. The veto happens
        // later, in checkSystemSleepAllowed(). Treating Yes as a failure signal here
        // produced a scary warning on every single activation that meant nothing.
        EventLog.shared.info(
            "Klep-context bij starten: AppleClamshellCausesSleep = "
            + (SleepFlag.clamshellCausesSleep().map { $0 ? "Yes" : "No" } ?? "onbekend")
            + " (informatief; het slaapveto zit niet in deze eigenschap)."
        )

        // De aanhef "Wakker houden AAN." staat vast: `verify.sh` zoekt hierop om het venster
        // van een sessie te bepalen. Er mag alleen achteraan iets bij.
        var startRegel = String(
            format: "Wakker houden AAN. Stopt vanzelf na %@, accugrens %d%%, temperatuur %@.",
            Self.durationText(effectiveLimitMinutes), Prefs.batteryFloor, thermal.label
        )
        startRegel += " Gestart via \(request.trigger.metLidwoord)."
        if let deadline { startRegel += " Loopt tot \(Self.clockText(deadline))." }
        if let binding { startRegel += " Stopt ook als \(binding.identity.label) klaar is." }
        EventLog.shared.info(startRegel)

        // Without the passwordless grant, none of the safety nets can release the flag
        // unattended — they run with the lid shut, where a prompt goes nowhere. The user
        // has to know that before walking away.
        await refreshGrantAsync()

        // The switch went live again the moment the privileged write returned, so keep-awake
        // can have been switched back off across this suspension point. Everything below
        // belongs to the session: locking the screen and blanking the display for a session
        // the user has already ended is exactly the surprise this app must never produce.
        guard intendedOn, sessionStart == start else {
            EventLog.shared.info("Activering afgebroken: de sessie was al beëindigd.")
            return .geweigerd(reden: "De sessie was alweer beëindigd voordat hij goed en wel liep.")
        }

        if grantStatus != .granted {
            safetyNetsDisarmed = true
            lastMessage = L10n.t("melding.letop.zondergrant")
            EventLog.shared.warn("Sessie gestart zonder sudoers-regel; vangnetten kunnen niet ingrijpen.")
        } else {
            safetyNetsDisarmed = false
        }

        Feedback.activated()
        if Prefs.blinkBacklightOnToggle { backlight.blink() }

        // The normal case: switch it on, carry on working, and let the machine secure
        // itself when the lid shuts. Locking and blanking therefore wait for the lid —
        // unless you asked for them straight away, or the lid is already closed.
        if Prefs.lockMoment == .activate { lockScreenNow() }
        if Prefs.displayOffMoment == .activate { await blankDisplayNow() }

        // Covers starting a session with the lid already shut; the same call is what the
        // lid event and every guardian tick use, so there is one decision point.
        securedForCurrentLidClose = false
        evaluateLidSecurity()
        startDisplayReassert()

        // De eindtijd die er écht staat, niet de gevraagde: een script hoort te zien wat het
        // gekregen heeft in plaats van te denken dat het meer kreeg.
        return .gestart(deadline: deadline ?? start, minuten: effectiveLimitMinutes)
    }

    /// Whether the machine has already been secured for the lid close currently in effect.
    /// Reset when the lid opens or a session ends, so one closed lid produces one lock.
    private var securedForCurrentLidClose = false
    /// Keeps the "docked, leaving it alone" note to once per episode instead of once every
    /// twenty seconds for as long as the lid stays shut.
    private var loggedDockedThisLidClose = false
    /// How often the panel had to be put back to sleep during this session. A number worth
    /// knowing afterwards: it is the difference between "the screen was off" and "the screen
    /// kept coming back on under a closed lid all night".
    private var displayRelitCount = 0

    /// Decides whether the machine should be locked and blanked *right now*.
    ///
    /// This is deliberately a condition that gets re-evaluated — by the lid event and by
    /// every guardian tick — rather than a one-shot reaction to closing the lid. Three
    /// separate failures came from doing it once, at the event, on cached state:
    ///
    /// * Undocking after closing the lid left the Mac closed, unlit and **unlocked**
    ///   forever, because the lid state never changed again and nothing re-checked.
    /// * The cached `lidClosed` lags a lid *open* by up to ten seconds (the poll interval),
    ///   which let the blank fire into a password prompt the user was already typing.
    /// * A docked monitor that had simply gone to sleep read as "no external display".
    ///
    /// So: read the lid live, read the displays live, and latch only the action.
    private func evaluateLidSecurity() {
        // Not gated on `intendedOn`: a flag stuck at 1 with no session is precisely when an
        // unattended, unlocked Mac matters. What decides is whether the machine will sleep,
        // and that is the kernel's answer, not ours.
        guard intendedOn || SleepFlag.read() == true else {
            securedForCurrentLidClose = false
            loggedDockedThisLidClose = false
            return
        }
        guard SleepFlag.clamshellClosed() ?? lidClosed else {
            securedForCurrentLidClose = false
            loggedDockedThisLidClose = false
            return
        }
        // Docked and still working: leave the session alone. The latch stays down, so if
        // the dock disappears later the next tick secures the machine.
        guard !DisplayControl.externalDisplayActive else {
            // Docking is a return to use, so the latch drops: unplugging again later has to
            // secure the machine again. Without this, the second undock of a
            // dock/undock/re-dock/undock cycle left it closed and unlocked.
            if !loggedDockedThisLidClose {
                EventLog.shared.info("Klep dicht met extern scherm aangesloten — niet vergrendeld, scherm niet uitgezet.")
                loggedDockedThisLidClose = true
            }
            securedForCurrentLidClose = false
            return
        }
        loggedDockedThisLidClose = false
        guard !securedForCurrentLidClose else { return }
        securedForCurrentLidClose = true

        // Lock before blanking: the other way round risks the panel lighting back up as
        // the login window composites.
        if Prefs.lockMoment == .lidClose { lockScreenNow() }
        if Prefs.displayOffMoment == .lidClose { Task { await blankDisplayNow() } }
    }

    /// Locks to the real login window, and reports honestly when it could not.
    private func lockScreenNow() {
        if ScreenLock.lockingEnabled == false {
            lastMessage = L10n.t("melding.letop.geenwachtwoord")
            EventLog.shared.warn("SACScreenLockEnabled is false; vergrendelen levert geen wachtwoordprompt op.")
        }
        switch ScreenLock.lockNow() {
        case .locked:
            break
        case .fellBackToScreenSaver:
            lastMessage = L10n.t("melding.slot.viascreensaver")
        case .unavailable:
            status = .error(L10n.t("fout.vergrendelenmislukt"))
            lastMessage = L10n.t("melding.slot.mislukt")
            Feedback.failed()
        }
    }

    private func blankDisplayNow() async {
        // Give the lock a moment to take the screen before asking the panel to sleep.
        try? await Task.sleep(nanoseconds: 600_000_000)
        if await !DisplayControl.sleepDisplayNow() {
            lastMessage = L10n.t("melding.scherm.nietuit")
            Feedback.failed()
        }
    }

    /// De enige publieke manier om een lopende sessie te beëindigen.
    ///
    /// `allowPrompt` staat alleen aan als er aantoonbaar iemand aan het toetsenbord zit. De
    /// schakelaar mag dus vragen; de opdrachtregel niet, want een buildscript kan geen
    /// wachtwoord invullen en `Shell.runAsAdmin` wacht tot 180 seconden.
    ///
    /// Geeft terug of de vlag ook echt op 0 stond. Alleen `true` betekent dat de Mac weer
    /// mag slapen; al het andere is een probleem dat gemeld moet worden.
    @discardableResult
    func stopSession(reason: String, allowPrompt: Bool) async -> Bool {
        intendedOn = false
        let outcome = await write(false, allowPrompt: allowPrompt)
        switch outcome {
        case .verified:
            endSession()
            status = .off
            lastMessage = nil
            safetyNetsDisarmed = false
            allowImmediateRetry()
            EventLog.shared.info("Wakker houden UIT (\(reason)).")
            Feedback.deactivated()
            if Prefs.blinkBacklightOnToggle { backlight.blink() }
            await refreshGrantAsync()
            return true
        case .cancelled:
            // The flag is still set and the user knows it; the guardian keeps trying.
            intendedOn = true
            status = .on
            lastMessage = L10n.t("melding.geannuleerd.nogwakker")
            await refreshGrantAsync()
            return false
        default:
            safetyNetsDisarmed = true
            status = .error(L10n.t("fout.nogwakker"))
            lastMessage = L10n.t("melding.uitzetten.mislukt")
            Feedback.failed()
            EventLog.shared.error("Stoppen (\(reason)) mislukte; de vlag staat nog aan.")
            await refreshGrantAsync()
            return false
        }
    }

    /// `displaysleepnow` is a request, not a latch. With system sleep disabled the machine
    /// is pegged at full wake, and any subsystem that reports user activity can relight
    /// the panel — under a closed lid, invisibly, for hours. So while the lid is shut the
    /// request is re-issued periodically rather than assumed to have stuck.
    private func startDisplayReassert() {
        displayReassertTimer?.invalidate()
        let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in
                // Read the lid live. The cached value lags a lid OPEN by up to ten
                // seconds, which is long enough to blank the screen while the user is
                // already typing their password into it.
                // Keyed off the kernel, not off `intendedOn` — design rule 1, which this
                // timer was quietly breaking. `forceRelease` clears `intendedOn` *before*
                // the write; if that write fails, `endSession()` never runs, so the timer is
                // never invalidated and keeps firing with a guard that is now permanently
                // false. The panel would then burn under a shut lid for the rest of the
                // night, in exactly the state — flag stuck at 1 — where it matters most.
                guard let self, Prefs.displayOffMoment != .never,
                      self.intendedOn || self.kernelFlag == true,
                      SleepFlag.clamshellClosed() ?? self.lidClosed,
                      !DisplayControl.externalDisplayActive else { return }

                // Ask the panel before telling it. `displaysleepnow` is a request that was
                // re-issued blind every thirty seconds for hours; nothing ever established
                // whether it was granted, so the exact failure this timer exists to prevent
                // — a screen burning under a shut lid — was the one it could not see.
                guard !DisplayControl.mainDisplayAsleep else { return }

                self.displayRelitCount += 1
                EventLog.shared.warn(
                    "Scherm stond weer aan onder een dichte klep (\(self.displayRelitCount)e keer deze sessie) — opnieuw uitzetten."
                )
                // Off the main thread: a process spawn in front of the run loop is a process
                // spawn in front of the guardian.
                await DisplayControl.sleepDisplayNow(quiet: true)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        displayReassertTimer = timer
    }

    // MARK: - Event sources

    private func handlePower(_ snapshot: PowerSnapshot) {
        battery = snapshot
        guard SleepFlag.read() == true, let reason = releaseReason() else { return }
        Task { await forceRelease(reason: reason) }
    }

    /// The flag switched off the kernel's thermal-emergency sleep, so this has to take
    /// its place. Serious pressure is a warning; critical releases the flag outright.
    private func handleThermal(_ pressure: ThermalWatch.Pressure) {
        thermal = pressure
        // Zakt de druk, dan is de meting van daarnet niet meer waar. Zonder dit bleef
        // "je Mac draait op 62%" staan nadat de Mac allang was afgekoeld.
        if pressure == .nominal || pressure == .fair { cpuSpeedLimit = nil }
        guard intendedOn else { return }

        switch pressure {
        case .nominal, .fair:
            return
        case .serious:
            Feedback.failed()
            EventLog.shared.warn("Thermische druk hoog tijdens actieve sessie; nog niet ingegrepen.")
            // The CPU limit is a nicety for the message; reading it must not stall the main
            // queue for up to eight seconds at the exact moment the machine is throttled and
            // slowest — that queue is what drives the guardian and the signal handler.
            Task { [weak self] in
                let limit = await ThermalWatch.cpuSpeedLimit()
                guard let self, self.thermal == .serious else { return }
                // Ook het paneel voeden. Dit is de énige plek die `pmset -g therm` draait:
                // één keer per overgang naar `.serious`, want `ThermalWatch.sample()` roept
                // `onChange` alleen aan als de stand werkelijk verandert. Het stond even in
                // de guardian-tik, en dat was een terugval op een fix uit BACKLOG.md §1 —
                // de tik is gebeurtenisgedreven, dus elke app die start of stopt gaf er een
                // extra subproces bij, urenlang, met de klep dicht.
                self.cpuSpeedLimit = limit
                self.lastMessage = L10n.t("melding.warm")
                    + (limit.map { $0 < 100 ? " en draait nu op \($0)% snelheid." : "." } ?? ".")
                    + " Wordt het kritiek, dan stopt Dopamine Code vanzelf."
            }
        case .critical:
            EventLog.shared.error("Thermische druk KRITIEK — slaap onmiddellijk weer toestaan.")
            Notify.post(.thermalCritical,
                        "Het wakker houden is gestopt zodat macOS zelf weer kan ingrijpen: die "
                        + "automatische noodslaap staat uit zolang de Mac wakker gehouden wordt.")
            Task { await forceRelease(reason: "de Mac werd te warm") }
        }
    }

    private func handleLid(closed: Bool) {
        lidClosed = closed

        if closed {
            EventLog.shared.info("Klep dicht met status \(intendedOn ? "AAN" : "uit")"
                                 + (lidArm != nil ? ", staat klaar voor de klep" : "") + ".")

            evaluateLidSecurity()
            // De guardian meteen aanstoten in plaats van tot de volgende tik te wachten.
            //
            // Bij een gewapende klep-arming is dit geen gemak maar de kern: staat de
            // slaapblokkade nog uit, dan begint de Mac binnen enkele seconden na het
            // dichtklappen aan zijn slaap, en twintig seconden later is er niets meer om aan
            // te zetten. De tik zelf doet niets nieuws — hij leest de kernel en laat
            // `evaluateTriggers()` beslissen — hij komt alleen eerder langs.
            if lidArm != nil {
                Task { await guardianTick() }
            }
            return
        }

        securedForCurrentLidClose = false

        // Lid opened: the moment to report what happened while the screen was invisible.
        if let network { outages = network.outages }
        guard let report = network?.summary ?? pendingOutageReport else { return }
        pendingOutageReport = nil

        // Only announce a summary that has actually changed since the last time.
        guard report != reportedOutageSummary else { return }
        reportedOutageSummary = report

        lastMessage = report
        EventLog.shared.warn("Melding bij openklappen: \(report)")
        presentAlert(title: L10n.t("melding.internet.titel"), body: report)
    }

    private func handleNetwork(online: Bool, outage: Outage?) {
        self.online = online
        if let network { outages = network.outages }
        if let outage { pendingOutageReport = outage.describe() }
        online ? Feedback.networkRestored() : Feedback.networkLost()
    }

    /// Never runs a modal while the screen is locked: that blocks the main thread with
    /// nobody able to dismiss it, which would stall the guardian.
    private func presentAlert(title: String, body: String) {
        ScreenState.whenUnlocked {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = title
            alert.informativeText = body
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }

    // MARK: - Menu actions

    /// Requirement 6: never call sleep while the flag is still set.
    func sleepNow() {
        guard !busy else { return }
        Task {
            // `!= false`: an unreadable flag must not be taken for "already off" on the one
            // path whose next step is to ask the Mac to sleep.
            if SleepFlag.read() != false {
                intendedOn = false
                let outcome = await write(false, allowPrompt: true)
                guard case .verified = outcome else {
                    status = .error(L10n.t("fout.nietinslaap"))
                    lastMessage = L10n.t("melding.nietgestopt")
                    EventLog.shared.error("Nu slapen geweigerd: SleepDisabled kon niet op 0 gezet worden.")
                    Feedback.failed()
                    return
                }
            }

            intendedOn = false
            endSession()
            status = .off

            // Re-read immediately before the call rather than trusting the write outcome.
            guard SleepFlag.read() == false else {
                status = .error(L10n.t("fout.nietinslaap"))
                EventLog.shared.error("Nu slapen afgebroken: vlag staat nog op 1 vlak voor de aanroep.")
                return
            }

            EventLog.shared.info("Nu slapen — vlag geverifieerd op 0.")
            let result = await Task.detached { Shell.run("/usr/bin/pmset", ["sleepnow"], timeout: 10) }.value
            if !result.ok {
                EventLog.shared.error("pmset sleepnow mislukt: \(result.combined)")
                lastMessage = L10n.t("melding.slaap.mislukt", result.combined)
            }
        }
    }

    func installGrant() {
        guard !busy else { return }
        Task {
            busy = true
            let outcome = await Task.detached { SudoersGrant.install() }.value
            busy = false
            switch outcome {
            case .installed:
                await refreshGrantAsync()
                lastMessage = grantStatus == .granted
                    ? "Wachtwoordvrijstelling geïnstalleerd."
                    : "De regel is geschreven, maar het systeem bevestigt hem nog niet."
                // A stuck flag can now be cleared, so drop the backoff and try at once.
                allowImmediateRetry()
                if SleepFlag.read() == true && !intendedOn {
                    await attemptRelease(reason: "opruimen na installatie van de vrijstelling")
                    // A successful release clears `lastMessage` — it has to, or a stale
                    // failure line survives the repair. Restate the outcome here, or the
                    // one click that fixed everything would report nothing at all.
                    if case .off = status {
                        lastMessage = L10n.t("melding.grant.geinstalleerd")
                    }
                }
            case .cancelled:
                lastMessage = L10n.t("melding.installatie.geannuleerd")
            case .failed(let message):
                lastMessage = L10n.t("melding.installatie.mislukt", message)
            }
        }
    }

    func removeGrant() {
        guard !busy else { return }
        Task {
            // Revoking the grant while the flag is set would disarm the deadline, the
            // battery floor and the thermal cut-out in a single click, with the Mac already
            // unable to sleep. Put the flag back first, and refuse if that does not work.
            if SleepFlag.read() != false {
                intendedOn = false
                let outcome = await write(false, allowPrompt: true)
                guard case .verified = outcome else {
                    status = .error(L10n.t("fout.nogwakker"))
                    lastMessage = L10n.t("melding.grant.nietverwijderd")
                    Feedback.failed()
                    return
                }
                endSession()
                status = .off
            }
            busy = true
            let outcome = await Task.detached { SudoersGrant.remove() }.value
            busy = false
            switch outcome {
            case .installed:
                await refreshGrantAsync()
                lastMessage = L10n.t("melding.grant.verwijderd")
            case .cancelled:
                lastMessage = L10n.t("melding.verwijderen.geannuleerd")
            case .failed(let message):
                lastMessage = L10n.t("melding.verwijderen.mislukt", message)
            }
        }
    }

    func refreshGrant() {
        refreshBacklight()
        Task {
            conflict = await ConflictWatch.current()
            await refreshGrantAsync()
            // Opening the menu is a deliberate act; do not make the user wait out a
            // ten-minute backoff to see whether the flag can be released now.
            if grantStatus == .granted { allowImmediateRetry() }
            await guardianTick()
        }
    }

    // MARK: - Het besturingskanaal (de `dopamine`-opdrachtregel)

    /// Wat Instellingen → Diagnose over het besturingskanaal laat zien.
    var controlChannelText: String {
        controlServer?.toestandsTekst ?? "niet gestart"
    }

    /// De kopieerbare regel om `dopamine` op je PATH te zetten. Nooit automatisch: een app
    /// die zelf iets in een systeemmap zet is een app die iets doet wat niemand gevraagd
    /// heeft. Zelfde vorm als `SudoersGrant.manualCommand`.
    static var cliLinkCommand: String {
        let binary = Bundle.main.bundleURL
            .appendingPathComponent("Contents/MacOS/dopamine").path
        return "ln -sfn '\(binary)' /opt/homebrew/bin/dopamine"
    }

    /// Eén verzoek van de opdrachtregel. Loopt langs precies dezelfde `startSession` en
    /// `stopSession` als de schakelaar; er wordt hier niets nagebouwd.
    func handleControl(_ verzoek: ControlChannel.Request) async -> ControlChannel.Response {
        switch verzoek.soort {
        case .status:
            return controlResponse(gelukt: true, zin: controlStatusSentence(), code: 0)

        case .aan:
            var gevraagd: [String] = []
            if let m = verzoek.minuten { gevraagd.append("duur \(Self.durationText(m))") }
            if let cap = verzoek.nietLaterDan { gevraagd.append("tot \(Self.clockText(cap))") }
            if let pid = verzoek.pid { gevraagd.append("gekoppeld aan pid \(pid)") }
            let toelichting = gevraagd.isEmpty ? "" : " (" + gevraagd.joined(separator: ", ") + ")"
            EventLog.shared.info("Opdrachtregel vraagt aanzetten\(toelichting).")

            let request = SessionRequest(
                trigger: .cli,
                limitMinutes: verzoek.minuten,
                bindToPID: verzoek.pid.map { pid_t($0) },
                notLaterThan: verzoek.nietLaterDan
            )
            switch await startSession(request) {
            case .gestart(let eind, let minuten):
                var zin = "De Mac blijft wakker tot \(Self.clockText(eind)) (\(Self.durationText(minuten)))."
                if let binding { zin += " Stopt eerder als \(binding.identity.label) klaar is." }
                if let cap = verzoek.nietLaterDan, cap > eind {
                    // Eerlijk zeggen dat de tijdslimiet vóór het gevraagde tijdstip ligt,
                    // in plaats van een eindtijd te beloven die niet gehaald wordt.
                    zin += " Je vroeg tot \(Self.clockText(cap)), maar de tijdslimiet van "
                        + "\(Self.durationText(minuten)) ligt daarvóór."
                }
                return controlResponse(gelukt: true, zin: zin, code: 0)

            case .liepAl(let eind):
                var zin = "Er liep al een sessie; er is geen tweede gestart."
                if let eind { zin += " Die loopt tot \(Self.clockText(eind))." }
                if let binding { zin += " Hij stopt ook als \(binding.identity.label) klaar is." }
                return controlResponse(gelukt: true, zin: zin, code: 0)

            case .geweigerd(let reden):
                return controlResponse(gelukt: false, zin: reden, code: 1)

            case .bezet:
                return controlResponse(
                    gelukt: false,
                    zin: "Dopamine Code is net met de slaapblokkade bezig. Probeer het zo opnieuw.",
                    code: 1
                )
            }

        case .uit:
            EventLog.shared.info("Opdrachtregel vraagt uitzetten.")
            // Ook zonder sessie doorgaan als de vlag aan staat: dan is er juist iets op te
            // ruimen. Alleen als er aantoonbaar niets aan staat is dit een lege handeling.
            if !intendedOn && SleepFlag.read() == false {
                return controlResponse(gelukt: true, zin: "Er liep niets; het wakker houden stond al uit.", code: 0)
            }
            // Zonder wachtwoordvenster: een buildscript kan er geen invullen.
            let gelukt = await stopSession(reason: "via de opdrachtregel", allowPrompt: false)
            if gelukt {
                return controlResponse(gelukt: true, zin: "Het wakker houden staat uit; de Mac mag weer slapen.", code: 0)
            }
            return controlResponse(
                gelukt: false,
                zin: (lastMessage ?? "Uitzetten lukte niet.")
                    + " Zet het zo nodig zelf terug: sudo pmset -a disablesleep 0",
                code: 1
            )
        }
    }

    private func controlStatusSentence() -> String {
        if intendedOn {
            var zin = "De Mac wordt wakker gehouden"
            if let deadline { zin += " tot \(Self.clockText(deadline))" }
            if let remainingText { zin += " (\(remainingText))" }
            if let binding { zin += ", en stopt zodra \(binding.identity.label) klaar is" }
            if let sessionTrigger { zin += " — \(sessionTrigger.zin)" }
            return zin + "."
        }
        switch SleepFlag.read() {
        case true:
            return "De slaapblokkade staat aan zonder dat er een sessie loopt. "
                + "Dopamine Code probeert dat terug te zetten."
        case false:
            return "Er loopt niets; het wakker houden staat uit."
        default:
            return "De slaapblokkade is niet uit te lezen."
        }
    }

    /// Elk antwoord leest de kernelvlag opnieuw en zet hem náást het beeld van de app.
    /// Onenigheid tussen die twee is precies waar deze app voor bestaat; die wegpoetsen tot
    /// één "aan/uit" zou de enige interessante toestand onzichtbaar maken.
    private func controlResponse(gelukt: Bool, zin: String, code: Int32) -> ControlChannel.Response {
        ControlChannel.Response(
            gelukt: gelukt,
            zin: zin,
            code: code,
            kernelvlag: SleepFlag.read(),
            sessieLoopt: intendedOn,
            appStatus: statusText,
            vangnettenUitgeschakeld: safetyNetsDisarmed,
            gestartOp: sessionStart,
            eindtijd: deadline,
            duurMinuten: intendedOn ? effectiveLimitMinutes : nil,
            trigger: sessionTrigger?.logNaam,
            procesPid: binding.map { Int32($0.identity.pid) },
            procesNaam: binding?.identity.naam,
            accuProcent: battery?.percent,
            opLader: battery?.onAC,
            klepDicht: SleepFlag.clamshellClosed() ?? lidClosed
        )
    }

    /// Uit het menu: houd de Mac wakker tot deze app klaar is. Loopt langs dezelfde
    /// `startSession` als de schakelaar, dus langs dezelfde weigeringen.
    func keepAwakeUntilQuit(of item: RunningApps.Item) {
        guard !busy else { return }
        Task {
            switch await startSession(SessionRequest(trigger: .schakelaar, bindToPID: item.pid)) {
            case .gestart(let eind, _):
                lastMessage = L10n.t("melding.tot.app.eneind", item.naam, Self.clockText(eind))
            case .liepAl:
                lastMessage = L10n.t("melding.sessie.ookapp", item.naam)
            case .geweigerd(let reden):
                lastMessage = reden
            case .bezet:
                lastMessage = L10n.t("melding.bezig")
            }
        }
    }

    // MARK: - Keyboard backlight

    func refreshBacklight() {
        backlightLevel = backlight.level
        if let level = backlightLevel {
            backlightOn = level > 0.001
        } else if !backlight.hasDirectControl {
            // On the CGEvent fallback there is no read-back at all, so deriving the switch
            // from a nil level pinned it to off forever — including immediately after the
            // user had just switched it on, because `toggleBacklight` calls straight into
            // here and overwrote its own result. Fall back to what the fallback believes.
            backlightOn = backlight.assumedOn
        } else {
            backlightOn = nil
        }
        backlightSuppressed = backlight.isSuppressed ?? false
    }

    func toggleBacklight() {
        switch backlight.toggle() {
        case .turnedOn(let level):
            backlightOn = true
            EventLog.shared.info(String(format: "Toetsenbordverlichting aan (%.2f).", level))
        case .turnedOff:
            backlightOn = false
            EventLog.shared.info("Toetsenbordverlichting uit.")
        case .needsAccessibility:
            lastMessage = L10n.t("melding.toegankelijkheid")
            _ = KeyboardBacklight.requestEventAccess()
        case .unavailable:
            lastMessage = L10n.t("melding.verlichting.mislukt")
            EventLog.shared.error("Schakelen toetsenbordverlichting mislukt.")
        }
        refreshBacklight()
    }

    /// Undoes the automatic-brightness change this app made, on request.
    func restoreKeyboardAutoBrightness() {
        switch backlight.restoreAutoBrightness() {
        case .restored:
            lastMessage = L10n.t("melding.helderheid.terug")
        case .nothingToRestore:
            lastMessage = L10n.t("melding.nietsterug")
        case .refused:
            // These two used to collapse into one message, so a refused restore was
            // reported as reassurance while auto-brightness stayed off — with the
            // preference still flagged as suppressed and nothing on screen saying so.
            lastMessage = L10n.t("melding.terugzetten.geweigerd")
        }
        refreshBacklight()
    }

    func setBacklightLevel(_ level: Float) {
        guard backlight.hasDirectControl else { return }
        backlight.setLevel(level)
        if level > 0.001 { Prefs.backlightRestoreLevel = level }
        refreshBacklight()
    }

    // MARK: - Settings side effects

    func applyLaunchAtLogin(_ enabled: Bool) {
        Prefs.launchAtLogin = enabled
        if enabled {
            switch LaunchAtLogin.enable() {
            case .success(let mechanism):
                lastMessage = LaunchAtLogin.requiresApproval
                    ? "Zet Dopamine Code nu nog aan bij Systeeminstellingen → Algemeen → "
                      + "Inloggen en extensies."
                    : "Dopamine Code start voortaan mee bij het inloggen (via \(mechanism.rawValue))."
            case .failure(let error):
                Prefs.launchAtLogin = false
                lastMessage = L10n.t("melding.login.mislukt", error.localizedDescription)
            }
        } else {
            LaunchAtLogin.disable()
            lastMessage = nil
        }
    }

    /// De knop in Diagnose. Schrijft de plist opnieuw en laadt hem opnieuw, ook als de inhoud
    /// klopt — want "de plist staat er" en "launchd kijkt ook echt" zijn twee dingen.
    func repairRestartGuard() {
        Task {
            let zin = await Task.detached(priority: .userInitiated) {
                RestartGuard.ensureInstalled(force: true)
            }.value
            lastMessage = L10n.t("melding.wachter", zin)
        }
    }

    /// Applies a changed timer duration to a session that is already running.
    ///
    /// Anchored on when the session started, not on now — otherwise shortening the limit
    /// mid-session would *extend* the deadline instead of bringing it forward.
    func rescheduleIfRunning() {
        guard intendedOn, let start = sessionStart else { return }
        applyDeadline(start: start)
        Task { await guardianTick() }
    }

    func quitAmphetamine() {
        ConflictWatch.quitAmphetamine()
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            self?.conflict = await ConflictWatch.current()
        }
    }

    func dismissConflictWarning() {
        Prefs.warnAboutAmphetamine = false
        conflict = nil
    }

    func openLog() {
        NSWorkspace.shared.selectFile(EventLog.shared.logPath, inFileViewerRootedAtPath: "")
    }

    /// Called on quit. Leaving the machine unable to sleep because the app went away is
    /// the one failure this app must never cause, so the result is checked rather than
    /// discarded — and the user is told loudly if it could not be undone.
    func shutdown() {
        // A privileged write may still be waiting on the authorisation sheet. Quitting now
        // would orphan that prompt: the user types the password afterwards, root sets the
        // flag, and no app is left to ever clear it again. Give it a moment to land, then
        // read the kernel rather than guessing.
        if busy {
            EventLog.shared.warn("Afsluiten terwijl een rechtenaanvraag loopt — even wachten.")
            let deadline = Date().addingTimeInterval(20)
            while busy && Date() < deadline {
                RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.2))
            }
            if busy {
                EventLog.shared.error("Rechtenaanvraag liep nog bij afsluiten; vlagstand onzeker.")
            }
        }

        // `false` is the only value that means "nothing to release". `nil` means the
        // property could not be read, and the write may also simply not have landed yet —
        // treating either as "all clear" is how a set flag survives a quit.
        guard SleepFlag.read() != false else {
            finishShutdown()
            return
        }

        EventLog.shared.info("Afsluiten met vlag aan — terugzetten naar 0.")
        var outcome = SleepFlag.set(false, allowPrompt: false)

        if case .verified = outcome {} else if !ScreenState.isLocked && !(SleepFlag.clamshellClosed() ?? lidClosed) {
            // The user chose Quit, so they are present and can answer a prompt. Only ask
            // when the screen is actually unlocked.
            EventLog.shared.warn("Wachtwoordloos terugzetten mislukte; vraag om toestemming.")
            outcome = SleepFlag.set(false, allowPrompt: true)
        }

        if case .verified = outcome {
            EventLog.shared.info("Vlag teruggezet bij afsluiten.")
        } else {
            EventLog.shared.error("Vlag kon bij afsluiten NIET teruggezet worden — de Mac slaapt niet.")
            if !ScreenState.isLocked && !(SleepFlag.clamshellClosed() ?? lidClosed) {
                let alert = NSAlert()
                alert.messageText = "De Mac kan nog steeds niet gaan slapen"
                alert.informativeText =
                    "Dopamine Code kon het wakker houden bij het afsluiten niet uitzetten. "
                    + "Zet het zelf terug: open Terminal en voer deze regel uit."
                    + "\n\nsudo pmset -a disablesleep 0"
                alert.alertStyle = .critical
                alert.addButton(withTitle: "OK")
                alert.runModal()
            }
        }
        finishShutdown()
    }

    private func finishShutdown() {
        // Put the system setting we changed back the way we found it.
        backlight.restoreAutoBrightness()
        endSession()
        // Het socketbestand mee opruimen. Een achtergebleven socket geeft de volgende
        // `dopamine`-aanroep ECONNREFUSED; dat wordt eerlijk gemeld als "de app draait niet",
        // maar een dood bestand laten liggen hoort niet.
        controlServer?.stop()
        controlServer = nil
        appTrigger?.stop()
        appTrigger = nil
        shortcut?.stop()
        shortcut = nil
        clamshell?.stop()
        powerMonitor?.stop()
        sleepWatch?.stop()
        guardianTimer?.invalidate()
        tickTimer?.invalidate()
        // Als allerlaatste feit vóór de logregel: `shutdown()` heeft zijn pogingen gehad, dus
        // pas hier staat er in de markering wat de kernel écht zegt. Stond de blokkade netjes
        // uit, dan haalt het vangnet deze app nooit meer terug; stond hij nog aan, dan komt hij
        // na twee minuten tóch — want zonder app is er geen tijdslimiet, geen accugrens en geen
        // temperatuurbewaking meer.
        RestartGuard.recordDeliberateExit(reason: "afgesloten")
        EventLog.shared.info("Dopamine Code afgesloten.")
        EventLog.shared.flush()
    }
}
