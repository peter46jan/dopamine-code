import SwiftUI

/// Diagnostics read once, on demand.
///
/// These were previously computed inside the view body, which spawned `sysadminctl` and
/// issued ServiceManagement XPC calls on the main thread — re-evaluated every second,
/// because the model publishes a clock tick at 1 Hz. Pulling them out of the body only
/// removed the repetition; `collect` still ran two subprocesses inline on the main actor,
/// which is up to sixteen seconds of stalled guardian for a pane nobody is waiting on.
/// So it is async now, and the two slow readings happen off the main thread.
///
/// `SleepDisabled` is deliberately *not* in here: it is the one row that must not be a
/// snapshot in a window whose every other row updates once a second. It comes from
/// `AppModel.kernelFlag`, which the guardian refreshes.
struct Diagnostics {
    var clamshellCausesSleep = "—"
    var lockDelay = "—"
    var backlightRoute = "—"
    var loginMechanism = "—"
    var thermal = "—"
    var cpuLimit = "—"
    var restartGuard = "—"

    static func collect(model: AppModel) async -> Diagnostics {
        var d = Diagnostics()
        d.clamshellCausesSleep = SleepFlag.clamshellCausesSleep()
            .map { L10n.t($0 ? "diag.ja" : "diag.nee") } ?? L10n.t("diag.onbekend")
        d.backlightRoute = L10n.t((await model.backlight.hasDirectControl)
            ? "diag.route.direct" : "diag.route.toetsen")
        d.thermal = await model.thermal.label
        d.lockDelay = await ScreenLock.lockDelayDescription() ?? L10n.t("diag.onbekend")
        d.cpuLimit = await ThermalWatch.cpuSpeedLimit().map { "\($0)%" } ?? L10n.t("diag.onbekend")
        // Draait `launchctl print`, dus net als de regel hieronder naast de hoofdthread.
        d.restartGuard = await Task.detached { RestartGuard.statusSentence() }.value
        d.loginMechanism = await Task.detached {
            switch LaunchAtLogin.currentMechanism() {
            case .serviceManagement: return L10n.t("diag.login.sm")
            case .launchAgent: return L10n.t("diag.login.agent")
            case .none: return L10n.t("diag.login.geen")
            }
        }.value
        return d
    }
}

struct SettingsView: View {
    @ObservedObject var model: AppModel

    @State private var batteryFloor = Prefs.batteryFloor
    @State private var lockMoment = Prefs.lockMoment
    @State private var displayOffMoment = Prefs.displayOffMoment
    @State private var sound = Prefs.soundFeedback
    @State private var networkSound = Prefs.soundOnNetworkLoss
    @State private var notifications = Prefs.notifications
    @State private var blink = Prefs.blinkBacklightOnToggle
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var syncingLaunchAtLogin = false
    @State private var diagnostics = Diagnostics()
    @State private var updateCheckEnabled = Prefs.updateCheckEnabled
    /// De gekozen taal, niet de actieve. Die twee lopen na een wijziging uiteen tot de
    /// volgende start, en juist dat verschil moet de sectie laten zien.
    @State private var taal = Taal.gekozen
    /// Wat de keuze was toen dit venster openging. Alleen om te kunnen zien of je hem in deze
    /// zitting verzet hebt — zie de melding in `taalSection`.
    @State private var taalBijOpenen = Taal.gekozen

    @ObservedObject private var updates = UpdateCheck.shared

    // Zelf aanzetten (fase 3). Lokale kopieën, net als de andere instellingen hierboven:
    // `Prefs` is geen `ObservableObject`, dus een weergave die er rechtstreeks uit leest
    // ververst niet als je er iets in verandert.
    @State private var scheduleEnabled = Prefs.scheduleEnabled
    @State private var scheduleDays = Prefs.scheduleDays
    @State private var scheduleStartMinute = Prefs.scheduleStartMinute
    @State private var scheduleEndMinute = Prefs.scheduleEndMinute
    @State private var appTriggers = Prefs.appTriggerBundleIDs
    /// Eén keer opgehaald bij het openen van het tabblad, niet in de body: die wordt door de
    /// kloktik van het model elke seconde opnieuw geëvalueerd.
    @State private var pickableApps: [RunningApps.Item] = []

    // Ergonomie (fase 4).
    @State private var countdown = Prefs.showCountdownInMenuBar
    /// Loopt er een opname van een sneltoets? Zolang die loopt slikt dit venster elke
    /// toetsaanslag op — daarom hoort er altijd een zichtbaar einde aan te zitten.
    @State private var recording = false
    @State private var recordingMonitor: Any?
    /// De sessiegeschiedenis, één keer gelezen bij het openen van het tabblad. `nil` betekent
    /// "nog niet gelezen"; een leeg lijstje betekent iets heel anders en mag daar niet op lijken.
    @State private var history: SessionHistory?

    var body: some View {
        TabView {
            general.tabItem { Label("tab.algemeen", systemImage: "gearshape") }
            safety.tabItem { Label("tab.stoppen", systemImage: "shield") }
            diagnosticsTab.tabItem { Label("tab.diagnose", systemImage: "stethoscope") }
            triggers.tabItem { Label("tab.aanzetten", systemImage: "wand.and.stars") }
            historyTab.tabItem { Label("tab.geschiedenis", systemImage: "clock.arrow.circlepath") }
        }
        .frame(width: 480, height: 380)
        .overlay(alignment: .bottom) { messageBar }
        .onDisappear {
            // Een opname die blijft hangen zou elke toetsaanslag in dit venster opeten zodra het
            // opnieuw geopend wordt.
            stopRecording()
            // Coming back from the settings window must not leave a Dock icon behind.
            NSApp.setActivationPolicy(.accessory)
        }
    }

    /// Actions started from this window (installing the rule, enabling the login item)
    /// report through the model. Without this they would fail silently here.
    @ViewBuilder private var messageBar: some View {
        if let message = model.lastMessage {
            Text(message)
                .font(.caption)
                .foregroundStyle(model.status.isError ? Color.orange : Color.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.thinMaterial)
        }
    }

    // MARK: - General

    private var general: some View {
        Form {
            Section("alg.wakker.titel") {
                Picker("alg.vergrendelen", selection: $lockMoment) {
                    ForEach(Prefs.ActionMoment.allCases) { m in Text(m.label).tag(m) }
                }
                .onChange(of: lockMoment) { Prefs.lockMoment = $0 }
                Text("alg.vergrendelen.uitleg")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Picker("alg.schermuit", selection: $displayOffMoment) {
                    ForEach(Prefs.ActionMoment.allCases) { m in Text(m.label).tag(m) }
                }
                .onChange(of: displayOffMoment) { Prefs.displayOffMoment = $0 }
                Text("alg.schermuit.uitleg")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("alg.meldt.titel") {
                Toggle("alg.melding", isOn: $notifications)
                    .onChange(of: notifications) { Prefs.notifications = $0 }
                Text("alg.melding.uitleg")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Toggle("alg.geluid", isOn: $sound)
                    .onChange(of: sound) { Prefs.soundFeedback = $0 }
                Toggle("alg.geluid.netwerk", isOn: $networkSound)
                    .onChange(of: networkSound) { Prefs.soundOnNetworkLoss = $0 }
                Toggle("alg.knipper", isOn: $blink)
                    .onChange(of: blink) { Prefs.blinkBacklightOnToggle = $0 }
                Text("alg.geluid.uitleg")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Toggle("alg.aftellen", isOn: $countdown)
                    .onChange(of: countdown) { Prefs.showCountdownInMenuBar = $0 }
                Text("alg.aftellen.uitleg")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            shortcutSection

            Section("alg.opstarten.titel") {
                Toggle("alg.opstarten.toggle", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { value in
                        if syncingLaunchAtLogin { syncingLaunchAtLogin = false; return }
                        model.applyLaunchAtLogin(value)
                        // Put the switch back if the system refused. Registration can fail
                        // outright — the user having switched the app off in System Settings
                        // returns kSMErrorLaunchDeniedByUser — and the toggle then stayed on,
                        // showing a login item that does not exist, with only a caption at the
                        // bottom of the window saying otherwise.
                        let actual = LaunchAtLogin.isEnabled
                        if actual != value {
                            syncingLaunchAtLogin = true
                            launchAtLogin = actual
                        }
                    }
                Text("alg.opstarten.uitleg")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if LaunchAtLogin.requiresApproval {
                    HStack {
                        Text("alg.opstarten.wacht")
                            .font(.caption).foregroundStyle(.orange)
                        Button("alg.opstarten.openen") { LaunchAtLogin.openLoginItemsSettings() }
                            .controlSize(.small)
                    }
                }
            }

            taalSection

            updateSection
        }
        .formStyle(.grouped)
        .onAppear {
            // Assigning here fires onChange, which would call applyLaunchAtLogin and
            // unregister a login item the user never touched. Only correct a genuine
            // mismatch, and mark it so the handler can tell a sync from a click.
            let actual = LaunchAtLogin.isEnabled
            if actual != launchAtLogin {
                syncingLaunchAtLogin = true
                launchAtLogin = actual
            }
        }
    }

    // MARK: - Taal

    /// De taalkiezer. Zie `Taal` voor waarom er geen herstartknop bij zit.
    ///
    /// De regel "nog niet actief" verschijnt alleen als de keuze en de werkelijkheid uiteen
    /// lopen. Hem altijd tonen zou hem tot behang maken, precies op het moment dat hij ertoe
    /// doet; hem nooit tonen laat je denken dat er niets gebeurd is toen je koos.
    private var taalSection: some View {
        Section("taal.titel") {
            Picker("taal.kiezer", selection: $taal) {
                ForEach(Taal.allCases) { t in Text(t.naam).tag(t) }
            }
            .onChange(of: taal) { Taal.kies($0) }

            Text("taal.uitleg")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            // Twee gevallen, want er valt niet één regel van te maken.
            //
            // Bij een vaste taal is wat er na de herstart draait precies die taal, dus dan is
            // vergelijken met wat er nú draait genoeg — ook als je de keuze vorige week maakte
            // en sindsdien niet herstart hebt.
            //
            // Bij "systeemtaal volgen" is dat niet te zeggen zonder te herstarten: de bundel
            // onderhandelt dan met de systeemvolgorde en valt bij geen enkele treffer terug op
            // het Nederlands, en die uitkomst is van buitenaf niet betrouwbaar na te rekenen
            // (zie `Taal`). Dus dan alleen melden wat zeker is: dat je hem zojuist verzet hebt.
            if taal == .systeem ? (taal != taalBijOpenen) : (taal != Taal.actief) {
                Label(L10n.t("taal.pasnavolgende"), systemImage: "arrow.clockwise")
                    .font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                Text(L10n.t("taal.nuactief", Taal.actief.naam))
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Bijwerken

    /// Wat de app over versies weet, en de schakelaar om te stoppen met kijken.
    ///
    /// Het versienummer staat er niet als opsmuk: zonder dat kun je niet nagaan of het
    /// bijwerken gelukt is. `DCSourceVersion` staat erbij omdat "1.2.0" niet genoeg zegt
    /// zodra je zelf commits bovenop een tag hebt staan — dan wil je weten wélke.
    private var updateSection: some View {
        Section("bij.titel") {
            LabeledContent("bij.versie") {
                Text(updates.huidige.map(String.init(describing:)) ?? L10n.t("bij.onbekend"))
                    .foregroundStyle(updates.huidige == nil ? .secondary : .primary)
            }
            LabeledContent("bij.bron") {
                Text(updates.bron)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            Toggle("bij.toggle", isOn: $updateCheckEnabled)
                .onChange(of: updateCheckEnabled) { value in
                    Prefs.updateCheckEnabled = value
                }
            Text("bij.uitleg")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button("bij.nukijken") { updates.controleerNu() }
                    .disabled(updates.bezig)
                if updates.bezig {
                    ProgressView().controlSize(.small)
                }
                Spacer()
                Text(updateStatusText)
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var updateStatusText: String {
        switch updates.toestand {
        case .beschikbaar(let versie, _): return L10n.t("bij.status.beschikbaar", versie.description)
        case .actueel: return L10n.t("bij.status.actueel")
        case .onbekend:
            guard let laatst = Prefs.updateLastCheck else { return L10n.t("bij.status.nooit") }
            let f = RelativeDateTimeFormatter()
            // Stond hard op nl_NL, wat "3 uur geleden" opleverde midden in een Franse zin.
            // De taal van de app is `Bundle.main.preferredLocalizations.first`, en niet
            // `Locale.current`: die volgt de regio-instelling en kan een andere taal zijn dan
            // waarin de app draait.
            f.locale = Locale(identifier: Bundle.main.preferredLocalizations.first ?? "nl")
            return L10n.t("bij.status.laatst", f.localizedString(for: laatst, relativeTo: Date()))
        }
    }

    // MARK: - Sneltoets

    /// Aan en uit zonder de menubalk aan te klikken.
    ///
    /// Er wordt geen combinatie meegeleverd: die kan bij de eerste start botsen met iets dat je
    /// al gebruikt, en zo'n botsing merk je pas als dát andere ding niet meer werkt. Opnemen
    /// gebeurt met een lokale toetsbewaking — die ziet alleen wat er in dít venster gebeurt en
    /// vraagt daarom geen enkel recht. De sneltoets zelf loopt via Carbon; zie `GlobalShortcut`.
    private var shortcutSection: some View {
        Section("snel.titel") {
            LabeledContent("snel.aanuit") {
                HStack(spacing: 8) {
                    Text(recording ? L10n.t("snel.druk")
                                   : (model.shortcutOmschrijving ?? L10n.t("snel.geen")))
                        .foregroundStyle(recording || model.shortcutOmschrijving == nil
                                         ? Color.secondary : Color.primary)
                        .frame(minWidth: 100, alignment: .leading)
                    Button(recording ? "snel.afbreken" : "snel.opnemen") {
                        if recording { stopRecording() } else { startRecording() }
                    }
                    .controlSize(.small)
                    Button("snel.wissen") {
                        model.setShortcut(keyCode: nil, modifierFlags: 0)
                    }
                    .controlSize(.small)
                    .disabled(model.shortcutOmschrijving == nil && model.shortcutProbleem == nil)
                }
            }

            if let probleem = model.shortcutProbleem {
                Label(probleem, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text("snel.uitleg")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("snel.uitleg.combinatie")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Vangt één toetsaanslag op, alleen in dit venster.
    ///
    /// `addLocalMonitorForEvents` ziet uitsluitend gebeurtenissen die voor deze app bestemd
    /// zijn en heeft daarom geen Toegankelijkheid nodig — in tegenstelling tot de globale
    /// variant, die dat wél vraagt en waarvoor de toestemming op deze Mac uit staat.
    private func startRecording() {
        stopRecording()
        recording = true
        recordingMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if Int(event.keyCode) == GlobalShortcut.escapeKeyCode {
                stopRecording()
                return nil
            }
            model.setShortcut(keyCode: Int(event.keyCode),
                              modifierFlags: GlobalShortcut.schoon(event.modifierFlags).rawValue)
            stopRecording()
            // `nil` teruggeven: anders komt de toetsaanslag óók nog in het venster terecht en
            // springt de knop waar de focus net op stond mee.
            return nil
        }
    }

    private func stopRecording() {
        if let recordingMonitor { NSEvent.removeMonitor(recordingMonitor) }
        recordingMonitor = nil
        recording = false
    }

    // MARK: - Safety net

    private var safety: some View {
        Form {
            Section("stop.natijd.titel") {
                // Bound to the model, not to local @State: the same value is editable from
                // the menu bar panel, and a private copy here would drift out of sync the
                // moment it was changed there.
                // The ceiling is 24, not 23. `Prefs` clamps the total to 24 h and the menu's
                // "+" reaches it, so 1440 is a perfectly ordinary value — and it rendered
                // into a 0...23 stepper as a value outside its own range, which left the
                // minutes stepper next to it a silent no-op with no explanation.
                LabeledContent("stop.uitna") {
                    HStack(spacing: 16) {
                        Stepper(value: hoursBinding, in: 0...24) {
                            Text(L10n.t("stop.uren", model.autoOffHoursPart))
                                .monospacedDigit()
                                .frame(width: 56, alignment: .leading)
                        }
                        Stepper(value: minutesBinding, in: 0...59, step: 5) {
                            Text(L10n.t("stop.minuten", model.autoOffMinutesPart))
                                .monospacedDigit()
                                .frame(width: 56, alignment: .leading)
                        }
                        // At the ceiling there are no minutes left to add. Visibly
                        // unavailable beats silently ignored.
                        .disabled(model.autoOffHoursPart >= 24)
                    }
                }

                HStack(spacing: 6) {
                    Text("stop.veelgebruikt").font(.caption).foregroundStyle(.secondary)
                    ForEach(presets, id: \.self) { total in
                        Button(label(forMinutes: total)) { model.setAutoOff(minutes: total) }
                            .controlSize(.small)
                            .disabled(model.autoOffMinutes == total)
                    }
                }

                Text(durationExplanation)
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("stop.accu.titel") {
                LabeledContent("stop.accu.onder") {
                    HStack {
                        Slider(
                            value: Binding(
                                get: { Double(batteryFloor) },
                                set: { batteryFloor = Int($0); Prefs.batteryFloor = Int($0) }
                            ),
                            in: 5...50, step: 1
                        )
                        Text("\(batteryFloor)%").monospacedDigit().frame(width: 50, alignment: .trailing)
                    }
                }
                Text("stop.accu.uitleg")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("stop.warm.titel") {
                Text("stop.warm.uitleg")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("stop.waarom.titel") {
                Text("stop.waarom.uitleg")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
    }

    private let presets = [30, 2 * 60, 4 * 60, 6 * 60, 8 * 60]

    /// Both steppers write one combined value. They are allowed to pass through zero on
    /// the way to a real setting; `Prefs` clamps the total to at least five minutes so a
    /// momentary "0 uur 0 min" can never arm a timer that fires on the next tick.
    private var hoursBinding: Binding<Int> {
        Binding(
            get: { model.autoOffHoursPart },
            set: { model.setAutoOff(minutes: $0 * 60 + model.autoOffMinutesPart) }
        )
    }

    private var minutesBinding: Binding<Int> {
        Binding(
            get: { model.autoOffMinutesPart },
            set: { model.setAutoOff(minutes: model.autoOffHoursPart * 60 + $0) }
        )
    }

    private func label(forMinutes total: Int) -> String {
        let h = total / 60, m = total % 60
        if h == 0 { return "\(m) m" }
        return m == 0 ? "\(h) u" : "\(h) u \(m) m"
    }

    private var durationExplanation: String {
        var text = L10n.t("stop.uitleg.duur", label(forMinutes: model.autoOffMinutes))
        if let deadline = model.deadline {
            let clock = DateFormatter()
            clock.dateFormat = "HH:mm"
            text += L10n.t("stop.uitleg.tot", clock.string(from: deadline))
        }
        return text
    }

    // MARK: - Zelf aanzetten

    /// De drie manieren waarop een sessie kan beginnen zonder dat je de schakelaar aanraakt.
    ///
    /// De klep-arming staat hier alleen uitgelegd en niet ingesteld: hij is per keer, en een
    /// gewapende toestand die het venster Instellingen overleeft zou uren later afgaan zonder
    /// dat iemand dat nog verwacht. De knop zit daarom in het menubalk-paneel.
    private var triggers: some View {
        Form {
            Section("aan.schema.titel") {
                Toggle("aan.schema.toggle", isOn: $scheduleEnabled)
                    .onChange(of: scheduleEnabled) { value in
                        Prefs.scheduleEnabled = value
                        model.scheduleSettingsChanged()
                    }

                LabeledContent("aan.schema.dagen") {
                    HStack(spacing: 3) {
                        // Op maandag beginnen, niet op zondag: zo lezen we hier een week.
                        ForEach([2, 3, 4, 5, 6, 7, 1], id: \.self) { dag in
                            Toggle(ScheduleWindow.korteDagnaam(dag), isOn: dayBinding(dag))
                                .toggleStyle(.button)
                                .controlSize(.small)
                        }
                    }
                }
                .disabled(!scheduleEnabled)

                DatePicker("aan.schema.van", selection: startBinding, displayedComponents: .hourAndMinute)
                    .disabled(!scheduleEnabled)
                DatePicker("aan.schema.tot", selection: endBinding, displayedComponents: .hourAndMinute)
                    .disabled(!scheduleEnabled)

                Text(scheduleExplanation)
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("aan.app.titel") {
                if appTriggers.isEmpty {
                    Text("aan.app.geen")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(appTriggers, id: \.self) { bundleID in
                        HStack {
                            Text(Prefs.appTriggerName(bundleID))
                            Text(bundleID)
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("aan.app.verwijderen") {
                                model.removeAppTrigger(bundleID: bundleID)
                                appTriggers = Prefs.appTriggerBundleIDs
                            }
                            .controlSize(.small)
                        }
                    }
                }

                Menu("App toevoegen…") {
                    if addableApps.isEmpty {
                        Text("aan.app.geendraaiend")
                    } else {
                        ForEach(addableApps) { item in
                            Button(item.naam) {
                                guard let bundleID = item.bundleID else { return }
                                model.addAppTrigger(bundleID: bundleID, naam: item.naam)
                                appTriggers = Prefs.appTriggerBundleIDs
                            }
                        }
                    }
                }
                .frame(width: 200)

                Text("aan.app.uitleg")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("aan.klep.titel") {
                Text("aan.klep.uitleg")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("aan.omheen.titel") {
                Text("aan.omheen.uitleg")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            pickableApps = RunningApps.list()
            appTriggers = Prefs.appTriggerBundleIDs
        }
    }

    private var addableApps: [RunningApps.Item] {
        pickableApps.filter { item in
            guard let bundleID = item.bundleID else { return false }
            return !appTriggers.contains(bundleID)
        }
    }

    private func dayBinding(_ dag: Int) -> Binding<Bool> {
        Binding(
            get: { scheduleDays.contains(dag) },
            set: { aan in
                if aan { scheduleDays.insert(dag) } else { scheduleDays.remove(dag) }
                Prefs.scheduleDays = scheduleDays
                model.scheduleSettingsChanged()
            }
        )
    }

    private var startBinding: Binding<Date> {
        Binding(
            get: { Self.date(fromMinute: scheduleStartMinute) },
            set: {
                scheduleStartMinute = Self.minute(from: $0)
                Prefs.scheduleStartMinute = scheduleStartMinute
                model.scheduleSettingsChanged()
            }
        )
    }

    private var endBinding: Binding<Date> {
        Binding(
            get: { Self.date(fromMinute: scheduleEndMinute) },
            set: {
                scheduleEndMinute = Self.minute(from: $0)
                Prefs.scheduleEndMinute = scheduleEndMinute
                model.scheduleSettingsChanged()
            }
        )
    }

    /// De tijdkiezer werkt met een `Date`, de instelling met minuten na middernacht. De datum
    /// eromheen doet niet mee; alleen de kloktijd wordt bewaard.
    private static func date(fromMinute minute: Int) -> Date {
        Calendar.current.date(from: DateComponents(
            year: 2000, month: 1, day: 1, hour: minute / 60, minute: minute % 60
        )) ?? Date()
    }

    private static func minute(from date: Date) -> Int {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
        return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
    }

    private var scheduleExplanation: String {
        let venster = ScheduleWindow(dagen: scheduleDays,
                                     startMinuut: scheduleStartMinute,
                                     eindMinuut: scheduleEndMinute)
        if let probleem = venster.probleem {
            return L10n.t("aan.schema.kannooit", probleem)
        }
        var text = L10n.t("aan.schema.gaataan", venster.omschrijving)
        if venster.loopOverMiddernacht {
            text += L10n.t("aan.schema.middernacht")
        }
        text += L10n.t("aan.schema.staart")
        return text
    }

    // MARK: - Diagnostics

    private var diagnosticsTab: some View {
        Form {
            Section("diag.toestemming.titel") {
                LabeledContent("diag.vrijstelling", value: model.grantText)
                Text("diag.vrijstelling.uitleg")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if model.safetyNetsDisarmed {
                    Label("diag.vrijstelling.kapot",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Button("diag.installeren") { model.installGrant() }
                    Button("diag.verwijderen") { model.removeGrant() }
                    Button("diag.controleren") { refresh() }
                }
                .controlSize(.small)
                .disabled(model.busy)
                Text("diag.regeltekst")
                    .font(.caption).foregroundStyle(.secondary)
                Text(SudoersGrant.ruleText)
                    .font(.system(.caption2, design: .monospaced))
                    .textSelection(.enabled)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("diag.systeem.titel") {
                // Live, from the model: the guardian refreshes it and every write updates it
                // at once. As a snapshot it sat there reading "0" while the user switched
                // keep-awake on in the menu bar next to it.
                LabeledContent("diag.slaapblokkade",
                               value: model.kernelFlag.map {
                                   $0 ? "1 — de Mac mag niet slapen" : "0 — de Mac mag slapen"
                               } ?? "onleesbaar")
                LabeledContent("diag.klepslaap", value: diagnostics.clamshellCausesSleep)
                Text("diag.klepslaap.uitleg")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                LabeledContent("diag.wachtwoordna", value: diagnostics.lockDelay)
                LabeledContent("diag.verlichtingvia", value: diagnostics.backlightRoute)
                LabeledContent("diag.loginvia", value: diagnostics.loginMechanism)
                LabeledContent("diag.temperatuur", value: diagnostics.thermal)
                LabeledContent("diag.rekensnelheid", value: diagnostics.cpuLimit)
                Text("diag.rekensnelheid.uitleg")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("diag.opnieuwuitlezen") { refresh() }
                    .controlSize(.small)
            }

            Section("diag.wachter.titel") {
                LabeledContent("diag.wachter", value: diagnostics.restartGuard)
                Text("diag.wachter.uitleg")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("diag.wachter.vanzelf")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("diag.wachter.herstellen") { model.repairRestartGuard() }
                    .controlSize(.small)
            }

            Section("diag.verlichting.titel") {
                Text("diag.verlichting.uitleg")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("diag.verlichting.terug") {
                    model.restoreKeyboardAutoBrightness()
                }
                .controlSize(.small)
                .disabled(!Prefs.autoBrightnessWasSuppressed)
            }

            Section("diag.cli.titel") {
                // Nooit stil: kon de socket niet aangemaakt worden, dan werkt `dopamine`
                // gewoon niet en zou je dat nergens zien staan.
                LabeledContent("diag.cli.kanaal", value: model.controlChannelText)
                Text("diag.cli.uitleg")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("dopamine on --until-exit $$   ·   dopamine off   ·   dopamine status --json")
                    .font(.system(.caption2, design: .monospaced))
                    .textSelection(.enabled)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("diag.cli.padregel")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(AppModel.cliLinkCommand)
                    .font(.system(.caption2, design: .monospaced))
                    .textSelection(.enabled)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("diag.logboek.titel") {
                Text("diag.logboek.uitleg")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("diag.logboek.toon") { model.openLog() }
                    .controlSize(.small)
                Text(EventLog.shared.logPath)
                    .font(.system(.caption2, design: .monospaced))
                    .textSelection(.enabled)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { refresh() }
    }

    private func refresh() {
        model.refreshGrant()
        Task { diagnostics = await Diagnostics.collect(model: model) }
    }

    // MARK: - Geschiedenis

    /// Wat er is geweest, gelezen uit het logboek.
    ///
    /// Bewust een apart tabblad naast Diagnose: Diagnose gaat over de toestand van nú,
    /// geschiedenis over wat er achter je ligt. En bewust zónder één knop die iets aan- of
    /// uitzet: dit is een verslag, geen bediening.
    private var historyTab: some View {
        Form {
            Section("gesch.laatste.titel") {
                if let history {
                    if history.sessies.isEmpty {
                        Text("gesch.geen")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        ForEach(history.sessies) { sessie in historyRow(sessie) }
                    }
                } else {
                    Text("gesch.bezig")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("gesch.herkomst.titel") {
                if let history {
                    // Het aantal gelezen regels staat er zodat een leeg lijstje niet hetzelfde
                    // lijkt als "je hebt de app nog nooit aangezet". Nul regels betekent dat er
                    // niets te lezen viel; vierduizend regels zonder sessies betekent iets anders.
                    LabeledContent("gesch.gelezenregels", value: "\(history.gelezenRegels)")
                    if history.zonderAfsluitregel > 0 {
                        LabeledContent("gesch.zonderafsluiting", value: "\(history.zonderAfsluitregel)")
                        Text("gesch.zonderafsluiting.uitleg")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if history.zonderBegin > 0 {
                        LabeledContent("gesch.zonderbegin", value: "\(history.zonderBegin)")
                        Text("gesch.zonderbegin.uitleg")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let leesfout = history.leesfout {
                        Label(leesfout, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption).foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Text("gesch.uitleg")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("gesch.opnieuwlezen") { loadHistory() }
                    .controlSize(.small)
            }
        }
        .formStyle(.grouped)
        .onAppear { loadHistory() }
    }

    private func historyRow(_ sessie: SessionHistory.Sessie) -> some View {
        // Of dit de sessie is die nú loopt komt uit het model en niet uit de tekst in het
        // logboek: een sessie zonder afsluitregel kan net zo goed een app zijn die is
        // weggevallen, en dat verschil is nou juist het punt. De marge is er omdat het logboek
        // op hele seconden schrijft.
        let loopt = model.intendedOn && sessie.eind == nil
            && (model.sessionStartedAt.map { abs($0.timeIntervalSince(sessie.begin)) < 5 } ?? false)
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(Self.dagTijd.string(from: sessie.begin))
                    .font(.callout.weight(.medium)).monospacedDigit()
                Text("→").foregroundStyle(.secondary)
                if let eind = sessie.eind {
                    Text(Self.tijd.string(from: eind)).font(.callout).monospacedDigit()
                } else if loopt {
                    Text("gesch.looptnog").font(.callout).foregroundStyle(Color.accentColor)
                } else {
                    Text("gesch.onbekend").font(.callout).foregroundStyle(.orange)
                }
                if let gedraaid = sessie.gedraaid {
                    Text("· \(gedraaid)").font(.callout).foregroundStyle(.secondary).monospacedDigit()
                }
                Spacer()
            }
            if let zin = historyDetail(sessie, loopt: loopt) {
                Text(zin)
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if sessie.beloofdeNietGehaald {
                Label("gesch.tochgeslapen",
                      systemImage: "exclamationmark.octagon.fill")
                    .font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 2)
    }

    private func historyDetail(_ sessie: SessionHistory.Sessie, loopt: Bool) -> String? {
        var delen: [String] = []
        if let trigger = sessie.trigger { delen.append("gestart via \(trigger)") }
        if let vangnet = sessie.vangnet {
            delen.append("een vangnet greep in: \(vangnet)")
        } else if let reden = sessie.reden {
            delen.append("gestopt: \(reden)")
        }
        delen.append(contentsOf: sessie.bijzonderheden)
        if sessie.eind == nil && !loopt {
            // Dit is het gat waar het vangnet uit fase 2 voor bestaat, en het hoort met zoveel
            // woorden in beeld te staan in plaats van als een lege regel.
            delen.append("geen afsluitregel — de app is weggevallen of vervangen, dus het einde "
                         + "staat niet in het logboek")
        }
        return delen.isEmpty ? nil : delen.joined(separator: " · ")
    }

    /// Naast de hoofdthread lezen, net als `Diagnostics.collect`: dit opent twee bestanden en
    /// loopt er regel voor regel doorheen, en op de hoofdthread staat ondertussen de guardian stil.
    private func loadHistory() {
        let pad = EventLog.shared.logPath
        Task {
            history = await Task.detached(priority: .utility) {
                SessionHistory.lees(logboek: URL(fileURLWithPath: pad))
            }.value
        }
    }

    private static let dagTijd: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("d MMM HH:mm")
        return f
    }()

    private static let tijd: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()
}
