import AppKit
import Combine
import SwiftUI

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
        case .off: return "Slapen toegestaan"
        case .on: return "Blijft actief"
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
        if hours > 0 { return "nog \(hours) u \(minutes) min" }
        if minutes > 0 { return "nog \(minutes) min" }
        return "nog minder dan een minuut"
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
        if kernelFlag == true && !intendedOn { return "geen vangnet — vlag staat aan zonder sessie" }
        if status.isOn { return nil }
        return "vangnet na \(configuredDurationText)"
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

    /// Sets the duration and, if a session is running, moves its deadline with it.
    func setAutoOff(minutes: Int) {
        Prefs.autoOffMinutes = minutes
        autoOffMinutes = Prefs.autoOffMinutes   // read back, so clamping is visible in the UI
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
        case .lidClose: parts.append("vergrendelt bij klep dicht")
        case .activate: parts.append("vergrendelt meteen")
        case .never: parts.append("vergrendelt niet")
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
        case .granted: return "Sudoers-regel actief"
        case .missing: return "Sudoers-regel ontbreekt"
        case .present(let why): return "Sudoers-regel werkt niet: \(why)"
        }
    }

    // MARK: - Lifecycle

    func start() {
        autoOffMinutes = Prefs.autoOffMinutes
        EventLog.shared.rotateIfNeeded()
        EventLog.shared.info("Dopamine Code gestart (\(Bundle.main.bundleURL.path)).")

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

        installSignalHandlers()
        startTicking()
        startGuardian()

        Task { await self.refreshGrantAsync() }
        Task { await self.clearStaleFlagAtStartup() }
        logEnvironment()
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
            status = .error("Kernelvlag onleesbaar")
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
            lastMessage = "Vastgelopen vlag van een vorige sessie is opgeruimd."
        default:
            status = .error("Vlag van vorige sessie staat nog aan")
            safetyNetsDisarmed = true
            lastMessage = "De Mac slaapt niet. Installeer de sudoers-regel, dan ruimt Dopamine Code dit vanzelf op."
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

        guard let flag = read else {
            // Unreadable is not "all clear". If a session is running, the deadline, the
            // battery floor and the thermal cut-out must still be able to fire — failing
            // open here would silently disable all three for as long as the read fails.
            status = .error("Kernelvlag onleesbaar")
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
                status = .error("De vlag is buiten Dopamine Code om uitgezet")
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
                status = .error("Vlag staat aan zonder sessie")
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
            ? "terwijl de vlag op 1 stond"
            : "terwijl de sessie liep, maar de vlag stond niet (meer) op 1"
        let verdict = flagWasUp
            ? " Het kernelveto heeft het hier niet gehouden."
            : " De vlag was buiten Dopamine Code om uitgezet, dus dit zegt niets over het kernelveto."
        let sentence = episode.describe().prefix(1).uppercased() + episode.describe().dropFirst()

        EventLog.shared.log(
            flagWasUp ? .error : .warn,
            (flagWasUp ? "BELOFTE NIET GEHAALD — " : "Mac sliep tijdens een sessie — ")
            + "\(episode.describe()), \(context)." + verdict
        )
        status = .error(flagWasUp ? "De Mac heeft tóch geslapen" : "Mac sliep — vlag stond niet aan")
        lastMessage = "\(sentence), \(context)." + verdict
            + (flagWasUp ? " Controleer het met ./verify.sh --after voordat je hierop vertrouwt." : "")
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
    }

    /// Whether any safety net says the flag should come off right now.
    private func releaseReason() -> String? {
        if let deadline {
            if Date() >= deadline { return "vangnet-timer verlopen" }
        } else if intendedOn {
            // A running session with no deadline has no timer at all. Rather than let it
            // run forever, treat the missing deadline as the fault it is.
            return "sessie zonder einddatum"
        }
        if let battery, !battery.onAC, battery.percent <= Prefs.batteryFloor {
            return "batterij \(battery.percent)% onder de grens van \(Prefs.batteryFloor)%"
        }
        if thermal == .critical {
            return "thermische druk kritiek"
        }
        return nil
    }

    private func forceRelease(reason: String) async {
        EventLog.shared.warn("Vangnet grijpt in: \(reason).")
        intendedOn = false
        await attemptRelease(reason: reason)
        if case .off = status {
            lastMessage = "Automatisch uitgezet: \(reason)."
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
            EventLog.shared.info("Blijf actief UIT (\(reason)).")
            Feedback.deactivated()
        default:
            releaseAttempts += 1
            safetyNetsDisarmed = true
            status = .error("Vlag zit vast — Mac slaapt niet")
            lastMessage = "Kon de vlag niet terugzetten (\(reason)). "
                + "Installeer de sudoers-regel, of voer uit: sudo pmset -a disablesleep 0"

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
                            "Poging \(releaseAttempts) mislukte (\(reason)). Herstel handmatig met: "
                            + "sudo pmset -a disablesleep 0")
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
        Task { on ? await activate() : await deactivateManually() }
    }

    private func activate() async {
        // Refuse to start a session that the battery rule would immediately end.
        if let battery, !battery.onAC, battery.percent <= Prefs.batteryFloor {
            status = .error("Batterij \(battery.percent)% — onder de grens van \(Prefs.batteryFloor)%")
            lastMessage = "Sluit de lader aan of verlaag de batterijgrens."
            Feedback.failed()
            EventLog.shared.warn("Activeren geweigerd: batterij \(battery.percent)%.")
            return
        }
        // Read the live state, not the cached one: `thermal` is only fed by ThermalWatch,
        // which is started inside a session and reset to .nominal when one ends — so the
        // cached value is ALWAYS .nominal here and this guard could never fire.
        thermal = ThermalWatch.Pressure(ProcessInfo.processInfo.thermalState)
        if thermal == .critical {
            status = .error("Thermische druk is kritiek")
            lastMessage = "De Mac is te warm. Wachten tot hij is afgekoeld."
            Feedback.failed()
            return
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
            status = .error("Vangnetten zouden niet kunnen ingrijpen")
            lastMessage = "\(grantText). Installeer eerst de sudoers-regel — zonder die regel kunnen "
                + "de timer, de batterijgrens en de thermische beveiliging de vlag niet terugzetten "
                + "met de klep dicht."
            Feedback.failed()
            EventLog.shared.warn("Activeren geweigerd: \(grantText).")
            return
        }

        let outcome = await write(true, allowPrompt: true)
        switch outcome {
        case .verified:
            break
        case .needsAuthorisation:
            status = .error("Geen toestemming om de vlag te zetten")
            lastMessage = "Installeer de sudoers-regel via het menu."
            await refreshGrantAsync()
            Feedback.failed()
            return
        case .cancelled:
            // Never claim "off" on the strength of a dialog the user dismissed. The write
            // may already have gone through before the sheet was cancelled, and the sheet
            // itself proves nothing about the kernel. Ask, and let the guardian clean up.
            intendedOn = false
            // `!= false`: `read()` has three outcomes and `nil` used to fall into the calm
            // branch — the exact collapse the comment above forbids. An unreadable flag
            // after a cancelled prompt is the case where it matters most.
            if SleepFlag.read() != false {
                status = .error("Vlag staat aan zonder sessie")
                lastMessage = "Geannuleerd, maar de vlag staat mogelijk aan. Dopamine Code zet hem terug."
                await attemptRelease(reason: "geannuleerd tijdens activeren")
            } else {
                status = .off
                lastMessage = "Geannuleerd."
            }
            return
        case .commandSucceededButFlagWrong(let actual):
            status = .error("Kernel meldt SleepDisabled = \(actual.map { $0 ? "1" : "0" } ?? "onleesbaar")")
            lastMessage = "Het commando gaf geen fout, maar de vlag staat niet zoals verwacht."
            Feedback.failed()
            return
        case .failed(let message):
            status = .error("Zetten van de vlag mislukt")
            lastMessage = message
            Feedback.failed()
            return
        }

        intendedOn = true
        status = .on
        lastMessage = nil
        // Both halves of the backoff, not just the counter: a stale `nextReleaseAttempt`
        // left over from an earlier failure would otherwise gate this session's first
        // release for up to ten minutes.
        allowImmediateRetry()
        lastFailureAlarm = nil

        let start = Date()
        sessionStart = start
        deadline = start.addingTimeInterval(Prefs.autoOffHours * 3600)
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

        EventLog.shared.info(String(
            format: "Blijf actief AAN. Vangnet na %.2f u, batterijgrens %d%%, thermisch %@.",
            Prefs.autoOffHours, Prefs.batteryFloor, thermal.label
        ))

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
            return
        }

        if grantStatus != .granted {
            safetyNetsDisarmed = true
            lastMessage = "Let op: zonder de sudoers-regel kunnen de timer, de batterijgrens en "
                + "de thermische beveiliging de vlag niet zelf terugzetten."
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
            lastMessage = "Let op: het systeem vraagt geen wachtwoord na vergrendelen."
            EventLog.shared.warn("SACScreenLockEnabled is false; vergrendelen levert geen wachtwoordprompt op.")
        }
        switch ScreenLock.lockNow() {
        case .locked:
            break
        case .fellBackToScreenSaver:
            lastMessage = "Scherm vergrendeld via de schermbeveiliging."
        case .unavailable:
            status = .error("Vergrendelen lukte niet")
            lastMessage = "Het scherm is NIET vergrendeld. De sessie loopt wel."
            Feedback.failed()
        }
    }

    private func blankDisplayNow() async {
        // Give the lock a moment to take the screen before asking the panel to sleep.
        try? await Task.sleep(nanoseconds: 600_000_000)
        if await !DisplayControl.sleepDisplayNow() {
            lastMessage = "Het scherm ging niet uit. Onder een dichte klep kost dat batterij."
            Feedback.failed()
        }
    }

    private func deactivateManually() async {
        intendedOn = false
        // The user is at the keyboard, so a prompt here can actually be answered.
        let outcome = await write(false, allowPrompt: true)
        switch outcome {
        case .verified:
            endSession()
            status = .off
            lastMessage = nil
            safetyNetsDisarmed = false
            allowImmediateRetry()
            EventLog.shared.info("Blijf actief UIT (handmatig).")
            Feedback.deactivated()
            if Prefs.blinkBacklightOnToggle { backlight.blink() }
        case .cancelled:
            // The flag is still set and the user knows it; the guardian keeps trying.
            intendedOn = true
            status = .on
            lastMessage = "Geannuleerd — de Mac blijft actief."
        default:
            safetyNetsDisarmed = true
            status = .error("Vlag staat nog aan")
            lastMessage = "Uitzetten mislukte. Handmatig herstellen: sudo pmset -a disablesleep 0"
            Feedback.failed()
        }
        await refreshGrantAsync()
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
                self.lastMessage = "Thermische druk is hoog"
                    + (limit.map { $0 < 100 ? ", CPU teruggeschroefd naar \($0)%." : "." } ?? ".")
            }
        case .critical:
            EventLog.shared.error("Thermische druk KRITIEK — slaap onmiddellijk weer toestaan.")
            Notify.post(.thermalCritical,
                        "De Mac is te warm. Blijf actief wordt uitgezet zodat de kernel weer "
                        + "kan ingrijpen — die noodslaap staat uit zolang de vlag op 1 staat.")
            Task { await forceRelease(reason: "thermische druk kritiek") }
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
        presentAlert(title: "Verbinding was weg", body: report)
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
                    status = .error("Vlag staat nog aan — niet in slaap gezet")
                    lastMessage = "De Mac wordt niet in slaap gezet zolang SleepDisabled op 1 staat."
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
                status = .error("Vlag staat nog aan — niet in slaap gezet")
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
                    ? "Sudoers-regel geïnstalleerd."
                    : "Regel geschreven, maar sudo bevestigt hem nog niet."
                // A stuck flag can now be cleared, so drop the backoff and try at once.
                allowImmediateRetry()
                if SleepFlag.read() == true && !intendedOn {
                    await attemptRelease(reason: "opruimen na installatie van de regel")
                    // A successful release clears `lastMessage` — it has to, or a stale
                    // failure line survives the repair. Restate the outcome here, or the
                    // one click that fixed everything would report nothing at all.
                    if case .off = status {
                        lastMessage = "Sudoers-regel geïnstalleerd en de vastgelopen vlag is opgeruimd."
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
                    status = .error("Vlag staat nog aan")
                    lastMessage = "De regel is niet verwijderd: eerst moet de vlag terug naar 0, "
                        + "anders kan niets hem daarna nog terugzetten."
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
                lastMessage = "Sudoers-regel verwijderd."
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
            lastMessage = "Toegankelijkheid is nodig om toetsaanslagen te simuleren."
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
            lastMessage = "Terugzetten werd geweigerd door CoreBrightness. Automatische "
                + "helderheid staat nog uit; probeer het opnieuw of zet hem aan bij "
                + "Systeeminstellingen → Toetsenbord."
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
                    ? "Zet Dopamine Code nog aan bij Systeeminstellingen → Inloggen."
                    : "Start bij inloggen via \(mechanism.rawValue)."
            case .failure(let error):
                Prefs.launchAtLogin = false
                lastMessage = "Start bij inloggen mislukt: \(error.localizedDescription)"
            }
        } else {
            LaunchAtLogin.disable()
            lastMessage = nil
        }
    }

    /// Applies a changed timer duration to a session that is already running.
    ///
    /// Anchored on when the session started, not on now — otherwise shortening the limit
    /// mid-session would *extend* the deadline instead of bringing it forward.
    func rescheduleIfRunning() {
        guard intendedOn, let start = sessionStart else { return }
        deadline = start.addingTimeInterval(Prefs.autoOffHours * 3600)
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
                alert.messageText = "De Mac slaapt nog steeds niet"
                alert.informativeText =
                    "Dopamine Code kon SleepDisabled niet terugzetten bij het afsluiten. "
                    + "Voer dit uit in Terminal:\n\nsudo pmset -a disablesleep 0"
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
        clamshell?.stop()
        powerMonitor?.stop()
        sleepWatch?.stop()
        guardianTimer?.invalidate()
        tickTimer?.invalidate()
        EventLog.shared.info("Dopamine Code afgesloten.")
    }
}
