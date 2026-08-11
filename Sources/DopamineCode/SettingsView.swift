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

    static func collect(model: AppModel) async -> Diagnostics {
        var d = Diagnostics()
        d.clamshellCausesSleep = SleepFlag.clamshellCausesSleep().map { $0 ? "ja" : "nee" } ?? "onbekend"
        d.backlightRoute = (await model.backlight.hasDirectControl) ? "CoreBrightness" : "CGEvent"
        d.thermal = await model.thermal.label
        d.lockDelay = await ScreenLock.lockDelayDescription() ?? "onbekend"
        d.cpuLimit = await ThermalWatch.cpuSpeedLimit().map { "\($0)%" } ?? "onbekend"
        d.loginMechanism = await Task.detached { LaunchAtLogin.currentMechanism().rawValue }.value
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

    var body: some View {
        TabView {
            general.tabItem { Label("Algemeen", systemImage: "gearshape") }
            safety.tabItem { Label("Vangnet", systemImage: "shield") }
            diagnosticsTab.tabItem { Label("Diagnose", systemImage: "stethoscope") }
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
            Section {
                Picker("Vergrendelen", selection: $lockMoment) {
                    ForEach(Prefs.ActionMoment.allCases) { m in Text(m.label).tag(m) }
                }
                .onChange(of: lockMoment) { Prefs.lockMoment = $0 }
                Text("Zonder systeemslaap komt de Mac nooit vanzelf op het inlogscherm. "
                     + "Standaard gebeurt dit bij het dichtklappen, zodat je gewoon door kunt werken "
                     + "terwijl \"Blijf actief\" aan staat.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Picker("Scherm uit", selection: $displayOffMoment) {
                    ForEach(Prefs.ActionMoment.allCases) { m in Text(m.label).tag(m) }
                }
                .onChange(of: displayOffMoment) { Prefs.displayOffMoment = $0 }
                Text("Zonder dit blijft het interne scherm onder de gesloten klep op volle helderheid branden.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                Toggle("Meldingen bij wat onbeheerd gebeurt", isOn: $notifications)
                    .onChange(of: notifications) { Prefs.notifications = $0 }
                Text("Vier gebeurtenissen: het vangnet greep in, de vlag kon niet terug, de "
                     + "Mac werd te warm, of de Mac heeft tóch geslapen. Een melding wacht tot "
                     + "je scherm ontgrendeld is en blijft daarna staan — een geluid om 03:12 "
                     + "hoort niemand.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Toggle("Geluid bij aan- en uitzetten", isOn: $sound)
                    .onChange(of: sound) { Prefs.soundFeedback = $0 }
                Toggle("Geluid bij verlies van verbinding", isOn: $networkSound)
                    .onChange(of: networkSound) { Prefs.soundOnNetworkLoss = $0 }
                Toggle("Toetsenbordverlichting kort laten knipperen", isOn: $blink)
                    .onChange(of: blink) { Prefs.blinkBacklightOnToggle = $0 }
                Text("Geluid staat standaard aan omdat knipperen onder een dichte klep onzichtbaar is.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Toggle("Start bij inloggen", isOn: $launchAtLogin)
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
                if LaunchAtLogin.requiresApproval {
                    HStack {
                        Text("macOS wacht op je goedkeuring.").font(.caption).foregroundStyle(.orange)
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
            Section {
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
                    Text("Snel:").font(.caption).foregroundStyle(.secondary)
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

            Section {
                LabeledContent("Batterijgrens") {
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
                Text("Onder deze stand op accu wordt slapen automatisch weer toegestaan, zonder wachtwoordprompt.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Waarom dit niet optioneel is") {
                Text("De vlag die systeemslaap blokkeert, schakelt in de kernel dezelfde controle uit "
                     + "die de noodslaap bij een lege batterij én bij oververhitting regelt. "
                     + "Deze twee grenzen en de thermische bewaking zijn de softwarevervanging daarvan.")
                    .font(.caption).foregroundStyle(.secondary)
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
        var text = "Ook als je vergeet uit te zetten, mag de Mac na "
            + label(forMinutes: model.autoOffMinutes)
            + " weer slapen. De teller loopt vanaf het begin van de sessie, niet vanaf deze wijziging."
        if let deadline = model.deadline {
            let clock = DateFormatter()
            clock.dateFormat = "HH:mm"
            text += " De huidige sessie eindigt om " + clock.string(from: deadline) + "."
        }
        return text
    }

    // MARK: - Diagnostics

    private var diagnosticsTab: some View {
        Form {
            Section("Rechten") {
                LabeledContent("Sudoers-regel", value: model.grantText)
                if model.safetyNetsDisarmed {
                    Label("Vangnetten kunnen de vlag nu niet zelf terugzetten.", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                }
                HStack {
                    Button("Installeren…") { model.installGrant() }
                    Button("Verwijderen…") { model.removeGrant() }
                    Button("Controleren") { refresh() }
                }
                .controlSize(.small)
                .disabled(model.busy)
                Text(SudoersGrant.ruleText)
                    .font(.system(.caption2, design: .monospaced))
                    .textSelection(.enabled)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Systeem") {
                // Live, from the model: the guardian refreshes it and every write updates it
                // at once. As a snapshot it sat there reading "0" while the user switched
                // keep-awake on in the menu bar next to it.
                LabeledContent("SleepDisabled",
                               value: model.kernelFlag.map { $0 ? "1 (slaap geblokkeerd)" : "0" } ?? "onleesbaar")
                LabeledContent("Klep→slaap-beleid", value: diagnostics.clamshellCausesSleep + " (volgt de vlag niet)")
                LabeledContent("Vergrendeling", value: diagnostics.lockDelay)
                LabeledContent("Verlichting via", value: diagnostics.backlightRoute)
                LabeledContent("Start bij inloggen", value: diagnostics.loginMechanism)
                LabeledContent("Thermische druk", value: diagnostics.thermal)
                LabeledContent("CPU-limiet", value: diagnostics.cpuLimit)
                Button("Opnieuw uitlezen") { refresh() }
                    .controlSize(.small)
            }

            Section("Toetsenbordverlichting") {
                Text("Een niveau instellen blijft alleen staan met automatische helderheid uit, "
                     + "dus die zet Dopamine Code uit zodra je de schuif gebruikt.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Automatische helderheid terugzetten") {
                    model.restoreKeyboardAutoBrightness()
                }
                .controlSize(.small)
                .disabled(!Prefs.autoBrightnessWasSuppressed)
            }

            Section("Logboek") {
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
