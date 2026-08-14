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
    /// Harde bovengrens, bijvoorbeeld een eindtijd of straks een schemavenster.
    var notLaterThan: Date? = nil
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
    /// Waarom de eindtijd staat waar hij staat, in gewone taal, voor de logregel bij het
    /// aflopen. Gezet op dezelfde plek als de eindtijd zelf.
    private var deadlineReason = "de ingestelde tijd was om"

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
    var menuBarIcon: NSImage { menuBarIcon() }

    func menuBarIcon(pointSize: CGFloat = 18) -> NSImage {
        AppIcon.menuBar(iconState, pointSize: pointSize)
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
        case .off: return "De Mac mag gewoon slapen"
        case .on: return "De Mac blijft wakker"
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
        if hours > 0 { return "stopt vanzelf over \(hours) u \(minutes) min" }
        if minutes > 0 { return "stopt vanzelf over \(minutes) min" }
        return "stopt vanzelf binnen een minuut"
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
    var safetyNetLine: String? {
        if let remaining = remainingText { return remaining }
        if kernelFlag == true && !intendedOn {
            return "de Mac wordt wakker gehouden zonder dat er iets loopt — niets stopt dat vanzelf"
        }
        if status.isOn { return nil }
        return "stopt straks vanzelf na \(configuredDurationText)"
    }

    static func durationText(_ total: Int) -> String {
        let h = total / 60, m = total % 60
        if h == 0 { return "\(m) min" }
        return m == 0 ? "\(h) uur" : "\(h) u \(m) min"
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
        return "stopt ook zodra \(binding.identity.label) klaar is"
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
    private func computeDeadline(start: Date, limitMinutes: Int?, notLaterThan: Date?) -> (date: Date, reason: String) {
        let byLimit = start.addingTimeInterval(Double(clampedMinutes(limitMinutes)) * 60)
        if let cap = notLaterThan, cap < byLimit {
            return (cap, "de sessie liep tot \(Self.clockText(cap))")
        }
        return (byLimit, "de ingestelde tijd was om")
    }

    private func applyDeadline(start: Date) {
        let planned = computeDeadline(start: start, limitMinutes: sessionLimitMinutes, notLaterThan: sessionNotLaterThan)
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

    /// One line in the menu saying what will actually happen, so the behaviour is legible
    /// without opening Settings.
    var behaviourSummary: String {
        var parts: [String] = []
        switch Prefs.lockMoment {
        case .lidClose: parts.append("gaat op slot bij klep dicht")
        case .activate: parts.append("gaat meteen op slot")
        case .never: parts.append("gaat niet op slot")
        }
        switch Prefs.displayOffMoment {
        case .lidClose: parts.append("scherm uit bij klep dicht")
        case .activate: parts.append("scherm meteen uit")
        case .never: parts.append("scherm blijft aan")
        }
        return parts.joined(separator: " · ")
    }

    var grantText: String {
        switch grantStatus {
        case .granted: return "Wachtwoordvrijstelling actief"
        case .missing: return "Wachtwoordvrijstelling ontbreekt"
        case .present(let why): return "Wachtwoordvrijstelling werkt niet: \(why)"
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
            status = .error("Kan niet uitlezen of de Mac mag slapen")
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
            lastMessage = "De Mac stond nog van een vorige keer wakker gehouden; dat is opgeruimd."
        default:
            status = .error("De Mac wordt nog wakker gehouden van een vorige keer")
            safetyNetsDisarmed = true
            lastMessage = "De Mac kan nu niet slapen. Installeer de wachtwoordvrijstelling bij "
                + "Instellingen → Diagnose, dan ruimt Dopamine Code dit vanzelf op."
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
            guard SleepFlag.read() != false else {
                RestartGuard.recordDeliberateExit(reason: "systeem gaat uit")
                return
            }
            EventLog.shared.warn("Systeem gaat uit met vlag aan — terugzetten naar 0.")
            let outcome = SleepFlag.set(false, allowPrompt: false)
            if case .verified = outcome {
                EventLog.shared.info("Vlag teruggezet vóór het uitschakelen.")
            } else {
                EventLog.shared.error("Vlag kon vóór het uitschakelen NIET teruggezet worden. "
                                      + "Herstel na de herstart: sudo pmset -a disablesleep 0")
            }
            RestartGuard.recordDeliberateExit(reason: "systeem gaat uit")
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

        guard let flag = read else {
            // Unreadable is not "all clear". If a session is running, the deadline, the
            // battery floor and the thermal cut-out must still be able to fire — failing
            // open here would silently disable all three for as long as the read fails.
            status = .error("Kan niet uitlezen of de Mac mag slapen")
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
                status = .error("Buiten Dopamine Code om uitgezet")
                EventLog.shared.warn("SleepDisabled werd van buitenaf op 0 gezet; sessie beëindigd.")
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
            return
        }

        // From here on the kernel flag is 1: the Mac will not sleep.
        if !intendedOn {
            // Say so FIRST. attemptRelease can return early — another write in flight, or
            // a backoff window — and leaving `status` on a calm `.off` while the kernel
            // flag is 1 is exactly the lie this app exists to prevent.
            if !status.isError {
                status = .error("Mac wordt wakker gehouden zonder dat er iets loopt")
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
        let context = flagWasUp
            ? "terwijl de slaapblokkade aan stond"
            : "terwijl het wakker houden aan stond, maar de slaapblokkade niet (meer)"
        let verdict = flagWasUp
            ? " De blokkade heeft het hier niet gehouden."
            : " De blokkade was buiten Dopamine Code om uitgezet, dus dit zegt niets over de blokkade zelf."
        let sentence = episode.describe().prefix(1).uppercased() + episode.describe().dropFirst()

        EventLog.shared.log(
            flagWasUp ? .error : .warn,
            (flagWasUp ? "BELOFTE NIET GEHAALD — " : "Mac sliep tijdens een sessie — ")
            + "\(episode.describe()), \(context)." + verdict
        )
        status = .error(flagWasUp ? "De Mac heeft tóch geslapen" : "Mac sliep — blokkade stond niet aan")
        lastMessage = "\(sentence), \(context)." + verdict
            + (flagWasUp ? " Vertrouw er dus niet blind op; controleer het met ./verify.sh --after." : "")
        sleepBrokeThePromise = flagWasUp
        Feedback.failed()
        Notify.post(.macSlept, "\(sentence), \(context)." + verdict)
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
        EventLog.shared.warn(
            "Het vangnet heeft \(hoelang) gekeken. Zolang dat zo blijft, blijft de Mac wakker als "
            + "Dopamine Code hard afgeschoten wordt. Kijk bij Systeeminstellingen → Algemeen → "
            + "Inloggen en extensies of Dopamine Code op de achtergrond mag draaien, of gebruik "
            + "'Vangnet herstellen' bij Instellingen → Diagnose."
        )
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
            return "er stond geen eindtijd ingesteld"
        }
        if let battery, !battery.onAC, battery.percent <= Prefs.batteryFloor {
            return "de accu stond op \(battery.percent)%, onder je grens van \(Prefs.batteryFloor)%"
        }
        if thermal == .critical {
            return "de Mac werd te warm"
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
                return "het proces \(binding.identity.label) is klaar"
                    + (hergebruikt ? " (die pid is inmiddels van iets anders)" : "")
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
            "De snelle procesmelding kwam niet; pas de guardian-tik merkte dat "
            + "\(current.identity.label) weg was. De koppeling werkt, maar reageert trager."
        )
    }

    private func forceRelease(reason: String) async {
        EventLog.shared.warn("Vangnet grijpt in: \(reason).")
        intendedOn = false
        await attemptRelease(reason: reason)
        if case .off = status {
            lastMessage = "Automatisch gestopt: \(reason). De Mac mag weer slapen."
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
            status = .error("Zit vast — de Mac kan niet gaan slapen")
            lastMessage = "Het stoppen lukte niet (\(reason)). Installeer de wachtwoordvrijstelling "
                + "bij Instellingen → Diagnose, of voer dit uit in Terminal: sudo pmset -a disablesleep 0"

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
        deadlineReason = "de ingestelde tijd was om"
        sessionTrigger = nil
        binding?.watcher?.cancel()
        binding = nil
        displayReassertTimer?.invalidate()
        displayReassertTimer = nil
        thermalWatch?.stop()
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
                                           notLaterThan: request.notLaterThan ?? sessionNotLaterThan)
            guard gevraagd.date <= huidige else {
                return .geweigerd(reden: "Een lopende sessie wordt niet verlengd — stop de sessie eerst. "
                                  + "Hij loopt nu tot \(Self.clockText(huidige)).")
            }
            nieuweEindtijd = gevraagd
        }

        if let identity = nieuweKoppeling {
            binding?.watcher?.cancel()
            binding = makeBinding(identity)
            EventLog.shared.info("Lopende sessie gekoppeld aan \(identity.label) "
                                 + "(\(request.trigger.logNaam)).")
        }
        if let eind = nieuweEindtijd {
            if let m = request.limitMinutes { sessionLimitMinutes = m }
            if let cap = request.notLaterThan { sessionNotLaterThan = cap }
            deadline = eind.date
            deadlineReason = eind.reason
            EventLog.shared.info("Lopende sessie ingekort tot \(Self.clockText(eind.date)) "
                                 + "(\(request.trigger.logNaam)).")
            Task { await guardianTick() }
        }
        return .liepAl(deadline: deadline)
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
                                 + "wordt alleen door de guardian-tik bewaakt, niet door een directe melding.")
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
                                 + "alleen de guardian-tik bewaakt deze koppeling.")
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
            status = .error("Accu \(battery.percent)% — onder je grens van \(Prefs.batteryFloor)%")
            lastMessage = "Sluit de lader aan, of verlaag de accugrens bij Instellingen → Vanzelf stoppen."
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
            status = .error("De Mac is te warm")
            lastMessage = "Wacht even tot hij is afgekoeld en probeer het dan opnieuw."
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
                status = .error("Niet gestart: dat proces bestaat niet")
                lastMessage = "Proces \(pid) draait niet (meer), dus er is niets om op te wachten."
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
            status = .error("Niet gestart: het stoppen zou later mislukken")
            lastMessage = "\(grantText). Installeer hem eerst bij Instellingen → Diagnose. Zonder "
                + "die regel kunnen de tijdslimiet, de accugrens en de temperatuurbewaking de Mac "
                + "later niet vanzelf weer laten slapen — en met de klep dicht kan niemand het "
                + "gevraagde wachtwoord invullen."
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
            status = .error("Geen toestemming om de Mac wakker te houden")
            lastMessage = "Installeer de wachtwoordvrijstelling bij Instellingen → Diagnose."
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
                status = .error("Mac wordt wakker gehouden zonder dat er iets loopt")
                lastMessage = "Geannuleerd, maar de Mac wordt mogelijk toch wakker gehouden. "
                    + "Dopamine Code zet dat terug."
                await attemptRelease(reason: "geannuleerd tijdens aanzetten")
            } else {
                status = .off
                lastMessage = "Geannuleerd."
            }
            return .geweigerd(reden: "Geannuleerd bij het vragen om toestemming.")
        case .commandSucceededButFlagWrong(let actual):
            status = .error("Het systeem meldt iets anders dan verwacht")
            lastMessage = "Het commando gaf geen fout, maar de slaapblokkade staat op "
                + "\(actual.map { $0 ? "1" : "0" } ?? "onleesbaar") in plaats van op 1."
            Feedback.failed()
            return .geweigerd(reden: "Het commando gaf geen fout, maar de slaapblokkade staat op "
                              + "\(actual.map { $0 ? "1" : "0" } ?? "onleesbaar") in plaats van op 1.")
        case .failed(let message):
            status = .error("Wakker houden is niet gelukt")
            lastMessage = message
            Feedback.failed()
            return .geweigerd(reden: "Wakker houden is niet gelukt: \(message)")
        }

        intendedOn = true
        sessionTrigger = request.trigger
        status = .on
        lastMessage = nil
        // Both halves of the backoff, not just the counter: a stale `nextReleaseAttempt`
        // left over from an earlier failure would otherwise gate this session's first
        // release for up to ten minutes.
        allowImmediateRetry()
        lastFailureAlarm = nil

        let start = Date()
        sessionStart = start
        sessionLimitMinutes = request.limitMinutes
        sessionNotLaterThan = request.notLaterThan
        applyDeadline(start: start)
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
        startRegel += " Gestart via de \(request.trigger.logNaam)."
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
            lastMessage = "Let op: zonder de wachtwoordvrijstelling kunnen de tijdslimiet, de "
                + "accugrens en de temperatuurbewaking de Mac straks niet zelf weer laten slapen."
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
            lastMessage = "Let op: op deze Mac staat ingesteld dat er ná vergrendelen géén "
                + "wachtwoord gevraagd wordt. Het scherm gaat dus wel op slot, maar iedereen "
                + "kan het weer openen."
            EventLog.shared.warn("SACScreenLockEnabled is false; vergrendelen levert geen wachtwoordprompt op.")
        }
        switch ScreenLock.lockNow() {
        case .locked:
            break
        case .fellBackToScreenSaver:
            lastMessage = "Scherm op slot gezet via de schermbeveiliging."
        case .unavailable:
            status = .error("Vergrendelen lukte niet")
            lastMessage = "Het scherm is NIET op slot gegaan — de Mac staat straks onbeheerd open. "
                + "Wakker houden loopt gewoon door."
            Feedback.failed()
        }
    }

    private func blankDisplayNow() async {
        // Give the lock a moment to take the screen before asking the panel to sleep.
        try? await Task.sleep(nanoseconds: 600_000_000)
        if await !DisplayControl.sleepDisplayNow() {
            lastMessage = "Het scherm ging niet uit. Onder een dichte klep brandt het dan onzichtbaar door en kost het accu."
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
            lastMessage = "Geannuleerd — de Mac wordt nog steeds wakker gehouden."
            await refreshGrantAsync()
            return false
        default:
            safetyNetsDisarmed = true
            status = .error("De Mac wordt nog steeds wakker gehouden")
            lastMessage = "Uitzetten lukte niet. Zet het zelf terug in Terminal met: "
                + "sudo pmset -a disablesleep 0"
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
                self.lastMessage = "De Mac wordt warm"
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
            EventLog.shared.info("Klep dicht met status \(intendedOn ? "AAN" : "uit").")

            evaluateLidSecurity()
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
        presentAlert(title: "De internetverbinding is weg geweest", body: report)
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
                    status = .error("Niet in slaap gezet")
                    lastMessage = "Het wakker houden kon niet gestopt worden, en zolang dat aan "
                        + "staat kan de Mac niet gaan slapen."
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
                status = .error("Niet in slaap gezet")
                EventLog.shared.error("Nu slapen afgebroken: vlag staat nog op 1 vlak voor de aanroep.")
                return
            }

            EventLog.shared.info("Nu slapen — vlag geverifieerd op 0.")
            let result = await Task.detached { Shell.run("/usr/bin/pmset", ["sleepnow"], timeout: 10) }.value
            if !result.ok {
                EventLog.shared.error("pmset sleepnow mislukt: \(result.combined)")
                lastMessage = "In slaap zetten mislukte: \(result.combined)"
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
                        lastMessage = "Wachtwoordvrijstelling geïnstalleerd; de Mac mag weer slapen."
                    }
                }
            case .cancelled:
                lastMessage = "Installatie geannuleerd."
            case .failed(let message):
                lastMessage = "Installatie mislukt: \(message)"
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
                    status = .error("De Mac wordt nog steeds wakker gehouden")
                    lastMessage = "De vrijstelling is niet verwijderd: het wakker houden moet "
                        + "eerst uit, anders kan niets het daarna nog stoppen."
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
                lastMessage = "Wachtwoordvrijstelling verwijderd."
            case .cancelled:
                lastMessage = "Verwijderen geannuleerd."
            case .failed(let message):
                lastMessage = "Verwijderen mislukt: \(message)"
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
                return controlResponse(gelukt: true, zin: "Er liep niets; de Mac mag gewoon slapen.", code: 0)
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
            return "Er loopt niets; de Mac mag gewoon slapen."
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
                lastMessage = "De Mac blijft wakker tot \(item.naam) klaar is, en hoe dan ook "
                    + "niet langer dan tot \(Self.clockText(eind))."
            case .liepAl:
                lastMessage = "De lopende sessie stopt nu ook zodra \(item.naam) klaar is."
            case .geweigerd(let reden):
                lastMessage = reden
            case .bezet:
                lastMessage = "Even bezig met de slaapblokkade; probeer het zo opnieuw."
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
            lastMessage = "Dopamine Code heeft toestemming nodig bij Systeeminstellingen → "
                + "Privacy → Toegankelijkheid om de helderheidstoetsen na te bootsen."
            _ = KeyboardBacklight.requestEventAccess()
        case .unavailable:
            lastMessage = "Toetsenbordverlichting kon niet geschakeld worden."
            EventLog.shared.error("Schakelen toetsenbordverlichting mislukt.")
        }
        refreshBacklight()
    }

    /// Undoes the automatic-brightness change this app made, on request.
    func restoreKeyboardAutoBrightness() {
        switch backlight.restoreAutoBrightness() {
        case .restored:
            lastMessage = "Automatische toetsenbordhelderheid staat weer zoals je hem had."
        case .nothingToRestore:
            lastMessage = "Er was niets terug te zetten."
        case .refused:
            // These two used to collapse into one message, so a refused restore was
            // reported as reassurance while auto-brightness stayed off — with the
            // preference still flagged as suppressed and nothing on screen saying so.
            lastMessage = "Het systeem weigerde het terugzetten. De automatische "
                + "toetsenbordverlichting staat nog uit; probeer het opnieuw of zet hem zelf aan "
                + "bij Systeeminstellingen → Toetsenbord."
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
                lastMessage = "Start bij inloggen mislukt: \(error.localizedDescription)"
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
            lastMessage = "Vangnet als de app wegvalt: \(zin)"
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
