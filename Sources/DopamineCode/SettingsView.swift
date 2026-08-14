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
        d.clamshellCausesSleep = SleepFlag.clamshellCausesSleep().map { $0 ? "ja" : "nee" } ?? "onbekend"
        d.backlightRoute = (await model.backlight.hasDirectControl)
            ? "rechtstreeks (CoreBrightness)"
            : "nagebootste toetsaanslagen (CGEvent)"
        d.thermal = await model.thermal.label
        d.lockDelay = await ScreenLock.lockDelayDescription() ?? "onbekend"
        d.cpuLimit = await ThermalWatch.cpuSpeedLimit().map { "\($0)%" } ?? "onbekend"
        // Draait `launchctl print`, dus net als de regel hieronder naast de hoofdthread.
        d.restartGuard = await Task.detached { RestartGuard.statusSentence() }.value
        d.loginMechanism = await Task.detached {
            switch LaunchAtLogin.currentMechanism() {
            case .serviceManagement: return "macOS-inlogitem (SMAppService)"
            case .launchAgent: return "opstartbestand (LaunchAgent)"
            case .none: return "niet ingesteld"
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

    var body: some View {
        TabView {
            general.tabItem { Label("Algemeen", systemImage: "gearshape") }
            safety.tabItem { Label("Vanzelf stoppen", systemImage: "shield") }
            diagnosticsTab.tabItem { Label("Diagnose", systemImage: "stethoscope") }
            triggers.tabItem { Label("Zelf aanzetten", systemImage: "wand.and.stars") }
        }
        .frame(width: 480, height: 380)
        .overlay(alignment: .bottom) { messageBar }
        .onDisappear {
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
            Section("Wat er gebeurt als de Mac wakker blijft") {
                Picker("Mac vergrendelen", selection: $lockMoment) {
                    ForEach(Prefs.ActionMoment.allCases) { m in Text(m.label).tag(m) }
                }
                .onChange(of: lockMoment) { Prefs.lockMoment = $0 }
                Text("Vergrendelen betekent: terug naar het inlogscherm, zodat er een wachtwoord "
                     + "nodig is om verder te kunnen. Normaal doet macOS dat vanzelf zodra de Mac "
                     + "gaat slapen — maar zolang Dopamine Code hem wakker houdt slaapt hij nooit, "
                     + "dus gebeurt het ook nooit. Standaard wacht het tot je de klep dichtdoet, "
                     + "zodat je met de klep open gewoon door kunt werken.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Picker("Scherm uitzetten", selection: $displayOffMoment) {
                    ForEach(Prefs.ActionMoment.allCases) { m in Text(m.label).tag(m) }
                }
                .onChange(of: displayOffMoment) { Prefs.displayOffMoment = $0 }
                Text("Zet je dit op \"nooit\", dan brandt het ingebouwde scherm onder de dichte "
                     + "klep op volle helderheid door. Je ziet er niets van, maar het kost stroom.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Hoe de app zich meldt") {
                Toggle("Melding als er iets gebeurt terwijl je weg bent", isOn: $notifications)
                    .onChange(of: notifications) { Prefs.notifications = $0 }
                Text("Er komt een melding als het wakker houden vanzelf is gestopt, als dat "
                     + "stoppen niet lukte, als de Mac te warm werd, als de Mac tóch in slaap is "
                     + "gegaan, als het vangnet de app heeft moeten terughalen, en als iets "
                     + "vanzelf wilde aangaan maar dat niet kon. De melding wacht tot je scherm "
                     + "ontgrendeld is en blijft daarna staan — een geluidje om 03:12 hoort "
                     + "niemand. Er komt géén melding als het vanzelf aangaan wél lukte: dat "
                     + "staat in het paneel en in het logboek, en een dagelijkse melding om "
                     + "09:00 laat de zes hierboven verwateren.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Toggle("Geluidje bij aan- en uitzetten", isOn: $sound)
                    .onChange(of: sound) { Prefs.soundFeedback = $0 }
                Toggle("Geluidje als de internetverbinding wegvalt", isOn: $networkSound)
                    .onChange(of: networkSound) { Prefs.soundOnNetworkLoss = $0 }
                Toggle("Toetsenbordverlichting kort laten knipperen", isOn: $blink)
                    .onChange(of: blink) { Prefs.blinkBacklightOnToggle = $0 }
                Text("Geluid staat standaard aan: een knipperend toetsenbord zie je niet als de "
                     + "klep dicht is.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Opstarten") {
                Toggle("Dopamine Code starten zodra ik inlog", isOn: $launchAtLogin)
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
                Text("De app zit dan meteen klaar in de menubalk. Het wakker houden gaat niet "
                     + "vanzelf aan — dat blijft een klik van jou.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if LaunchAtLogin.requiresApproval {
                    HStack {
                        Text("macOS wacht nog op je goedkeuring hiervoor.")
                            .font(.caption).foregroundStyle(.orange)
                        Button("Openen") { LaunchAtLogin.openLoginItemsSettings() }
                            .controlSize(.small)
                    }
                }
            }
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

    // MARK: - Safety net

    private var safety: some View {
        Form {
            Section("Na een tijd") {
                // Bound to the model, not to local @State: the same value is editable from
                // the menu bar panel, and a private copy here would drift out of sync the
                // moment it was changed there.
                // The ceiling is 24, not 23. `Prefs` clamps the total to 24 h and the menu's
                // "+" reaches it, so 1440 is a perfectly ordinary value — and it rendered
                // into a 0...23 stepper as a value outside its own range, which left the
                // minutes stepper next to it a silent no-op with no explanation.
                LabeledContent("Automatisch uit na") {
                    HStack(spacing: 16) {
                        Stepper(value: hoursBinding, in: 0...24) {
                            Text("\(model.autoOffHoursPart) uur")
                                .monospacedDigit()
                                .frame(width: 56, alignment: .leading)
                        }
                        Stepper(value: minutesBinding, in: 0...59, step: 5) {
                            Text("\(model.autoOffMinutesPart) min")
                                .monospacedDigit()
                                .frame(width: 56, alignment: .leading)
                        }
                        // At the ceiling there are no minutes left to add. Visibly
                        // unavailable beats silently ignored.
                        .disabled(model.autoOffHoursPart >= 24)
                    }
                }

                HStack(spacing: 6) {
                    Text("Veelgebruikt:").font(.caption).foregroundStyle(.secondary)
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

            Section("Bij een bijna lege accu") {
                LabeledContent("Stoppen onder") {
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
                Text("Werk je zonder lader, dan mag de Mac weer slapen zodra de accu onder deze "
                     + "stand komt. Zonder die grens loopt de accu met de klep dicht gewoon "
                     + "helemaal leeg. Er wordt hierbij niet om je wachtwoord gevraagd.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Als de Mac te warm wordt") {
                Text("Dit gaat vanzelf en is niet uit te zetten. Wordt de Mac kritiek warm, dan "
                     + "stopt Dopamine Code onmiddellijk, zodat macOS zelf weer kan ingrijpen. "
                     + "Bij \"hoog\" krijg je alleen een waarschuwing.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Waarom je deze drie niet kunt uitzetten") {
                Text("Om de Mac wakker te houden met de klep dicht moet Dopamine Code één "
                     + "systeeminstelling omzetten: de slaapblokkade (SleepDisabled). Diezelfde "
                     + "instelling zet ook de noodrem van macOS uit — de automatische slaap bij "
                     + "een bijna lege accu en bij oververhitting. De tijdslimiet, de accugrens "
                     + "en de temperatuurbewaking hierboven nemen die taak over. Daarom horen ze "
                     + "er altijd bij.")
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
        var text = "Vergeet je het uit te zetten, dan mag de Mac na "
            + label(forMinutes: model.autoOffMinutes)
            + " vanzelf weer slapen. De teller loopt vanaf het moment dat je aanzette, niet "
            + "vanaf deze wijziging — korter zetten haalt het einde dus naar voren."
        if let deadline = model.deadline {
            let clock = DateFormatter()
            clock.dateFormat = "HH:mm"
            text += " Nu loopt hij tot " + clock.string(from: deadline) + "."
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
            Section("Op vaste tijden") {
                Toggle("Aanzetten volgens een schema", isOn: $scheduleEnabled)
                    .onChange(of: scheduleEnabled) { value in
                        Prefs.scheduleEnabled = value
                        model.scheduleSettingsChanged()
                    }

                LabeledContent("Dagen") {
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

                DatePicker("Van", selection: startBinding, displayedComponents: .hourAndMinute)
                    .disabled(!scheduleEnabled)
                DatePicker("Tot", selection: endBinding, displayedComponents: .hourAndMinute)
                    .disabled(!scheduleEnabled)

                Text(scheduleExplanation)
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Als een app gaat draaien") {
                if appTriggers.isEmpty {
                    Text("Nog geen apps gekozen.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(appTriggers, id: \.self) { bundleID in
                        HStack {
                            Text(Prefs.appTriggerName(bundleID))
                            Text(bundleID)
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Verwijderen") {
                                model.removeAppTrigger(bundleID: bundleID)
                                appTriggers = Prefs.appTriggerBundleIDs
                            }
                            .controlSize(.small)
                        }
                    }
                }

                Menu("App toevoegen…") {
                    if addableApps.isEmpty {
                        Text("Geen draaiende apps gevonden")
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

                Text("De lijst toont wat er nu draait; wat je kiest wordt op naam bewaard en "
                     + "geldt ook voor de volgende keer. Het wakker houden gaat aan zodra zo'n "
                     + "app start — draait hij al op het moment dat je hem kiest, dan gebeurt er "
                     + "niets tot hij opnieuw start. De sessie stopt weer zodra die app klaar "
                     + "is, langs precies dezelfde weg als \"dopamine on --until-exit\".")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Zodra je de klep dichtdoet") {
                Text("Dit staat in het menubalk-paneel en niet hier, want het geldt één keer: "
                     + "je klikt \"Aanzetten zodra ik de klep dichtdoe\", je klapt dicht, en het "
                     + "wakker houden gaat aan. Doe je het niet, dan vervalt het na vijf minuten "
                     + "vanzelf en zegt de app dat ook. Een gewapende stand die een herstart zou "
                     + "overleven gaat uren later af zonder dat iemand dat nog verwacht.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Wat er hoe dan ook omheen blijft zitten") {
                Text("Alles wat hier vanzelf aangaat loopt langs precies dezelfde weg als de "
                     + "schakelaar: dezelfde tijdslimiet, dezelfde accugrens en dezelfde "
                     + "temperatuurbewaking. Kan er op dat moment niet veilig aangezet worden — "
                     + "de accu is te leeg, de Mac is te warm, of de wachtwoordvrijstelling is "
                     + "weg — dan gebeurt er niets, en krijg je daar een melding van. Een schema "
                     + "loopt nooit langer dan de tijdslimiet: staat die op 4 uur en het venster "
                     + "tot 18:00, dan stopt het om 13:00 en niet om 18:00. En binnen één venster "
                     + "gaat het schema hooguit één keer aan, ook als er iets tussendoor stopte — "
                     + "anders zou het schema terugzetten wat een vangnet net had laten vallen.")
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
            return "Dit schema kan nooit afgaan: \(probleem). Zolang dat zo is gebeurt er niets."
        }
        var text = "Het wakker houden gaat dan vanzelf aan: \(venster.omschrijving)."
        if venster.loopOverMiddernacht {
            text += " Dit venster loopt over middernacht heen; de dag hoort bij het begin, dus "
                + "een venster dat vrijdagavond begint loopt zaterdagochtend af."
        }
        text += " Sliep de Mac toen het venster openging, dan gaat het alsnog aan zodra hij "
            + "wakker is. Zet je het handmatig uit binnen het venster, dan blijft het uit tot "
            + "het volgende venster."
        return text
    }

    // MARK: - Diagnostics

    private var diagnosticsTab: some View {
        Form {
            Section("Toestemming") {
                LabeledContent("Wachtwoordvrijstelling", value: model.grantText)
                Text("Met deze eenmalige regel mag Dopamine Code precies één commando uitvoeren "
                     + "zonder je wachtwoord: de slaapblokkade aan- en uitzetten. Zonder de regel "
                     + "vraagt macOS er elke keer om — en met de klep dicht kan niemand dat "
                     + "invullen, dus kan de Mac daarna niet vanzelf weer gaan slapen.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if model.safetyNetsDisarmed {
                    Label("Het vanzelf stoppen werkt nu niet: de app kan de Mac niet zelf weer laten slapen.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Button("Installeren…") { model.installGrant() }
                    Button("Verwijderen…") { model.removeGrant() }
                    Button("Controleren") { refresh() }
                }
                .controlSize(.small)
                .disabled(model.busy)
                Text("Dit is de regel die geïnstalleerd wordt (in /etc/sudoers.d):")
                    .font(.caption).foregroundStyle(.secondary)
                Text(SudoersGrant.ruleText)
                    .font(.system(.caption2, design: .monospaced))
                    .textSelection(.enabled)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Wat het systeem nu meldt") {
                // Live, from the model: the guardian refreshes it and every write updates it
                // at once. As a snapshot it sat there reading "0" while the user switched
                // keep-awake on in the menu bar next to it.
                LabeledContent("Slaapblokkade (SleepDisabled)",
                               value: model.kernelFlag.map {
                                   $0 ? "1 — de Mac mag niet slapen" : "0 — de Mac mag gewoon slapen"
                               } ?? "onleesbaar")
                LabeledContent("Klep dicht laat de Mac slapen", value: diagnostics.clamshellCausesSleep)
                Text("Die tweede regel staat er alleen ter informatie: hij verandert niet mee met "
                     + "de slaapblokkade, ook niet als het wakker houden aan staat.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                LabeledContent("Wachtwoord na vergrendelen", value: diagnostics.lockDelay)
                LabeledContent("Toetsenbordverlichting via", value: diagnostics.backlightRoute)
                LabeledContent("Start bij inloggen via", value: diagnostics.loginMechanism)
                LabeledContent("Temperatuur", value: diagnostics.thermal)
                LabeledContent("Rekensnelheid", value: diagnostics.cpuLimit)
                Text("100% betekent dat macOS de Mac niet afremt. Lager betekent: teruggeschroefd "
                     + "om af te koelen.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Opnieuw uitlezen") { refresh() }
                    .controlSize(.small)
            }

            Section("Vangnet als de app wegvalt") {
                LabeledContent("Wachter", value: diagnostics.restartGuard)
                Text("Wordt Dopamine Code hard afgeschoten — kill -9, of een crash — dan is er "
                     + "geen enkele kans meer om de slaapblokkade terug te zetten, en blijft de "
                     + "Mac wakker tot de accu leeg is. Daarom kijkt er elke 30 seconden een "
                     + "kleine wachter of de blokkade aan staat zonder dat de app nog draait; "
                     + "in dat geval start hij de app opnieuw, die het dan zelf opruimt. Hij "
                     + "schakelt zelf nooit iets, en na een gewone Stop komt hij niet terug.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Dit gaat vanzelf en is niet uit te zetten — net als de temperatuurbewaking.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Vangnet herstellen") { model.repairRestartGuard() }
                    .controlSize(.small)
            }

            Section("Toetsenbordverlichting") {
                Text("Een vaste helderheid blijft alleen staan als de automatische "
                     + "toetsenbordverlichting uit staat. Die zet Dopamine Code daarom uit zodra "
                     + "je de schuif gebruikt — met deze knop zet je hem weer terug zoals hij was.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Automatische helderheid terugzetten") {
                    model.restoreKeyboardAutoBrightness()
                }
                .controlSize(.small)
                .disabled(!Prefs.autoBrightnessWasSuppressed)
            }

            Section("Bedienen vanaf de opdrachtregel") {
                // Nooit stil: kon de socket niet aangemaakt worden, dan werkt `dopamine`
                // gewoon niet en zou je dat nergens zien staan.
                LabeledContent("Besturingskanaal", value: model.controlChannelText)
                Text("Hiermee kan een script het wakker houden aan- en uitzetten, bijvoorbeeld "
                     + "voor de duur van een build. Het schakelt niets zelf: het vraagt Dopamine "
                     + "Code om iets te doen, met dezelfde tijdslimiet, accugrens en "
                     + "temperatuurbewaking eromheen. Draait de app niet, dan doet het niets en "
                     + "zegt het dat ook.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("dopamine on --until-exit $$   ·   dopamine off   ·   dopamine status --json")
                    .font(.system(.caption2, design: .monospaced))
                    .textSelection(.enabled)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Om 'dopamine' te kunnen typen zonder het hele pad, plak je deze regel één "
                     + "keer in Terminal:")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(AppModel.cliLinkCommand)
                    .font(.system(.caption2, design: .monospaced))
                    .textSelection(.enabled)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Logboek") {
                Text("Alles wat de app doet komt in dit bestand te staan — daarin kun je "
                     + "achteraf teruglezen wat er 's nachts gebeurd is.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Toon logbestand in Finder") { model.openLog() }
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
}
