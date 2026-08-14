import SwiftUI

/// The menu bar panel.
///
/// This uses `.window` style rather than `.menu`: menu style drops non-text views and
/// does not re-render its body when opened, which makes a live countdown impossible.
struct MenuView: View {
    @ObservedObject var model: AppModel

    /// Eén keer opgehaald bij het openen, niet in de body. De body wordt elke seconde
    /// opnieuw geëvalueerd door de kloktik, en `NSWorkspace.runningApplications` daarin
    /// zetten is een systeemaanroep per seconde zolang het paneel openstaat.
    @State private var runningApps: [RunningApps.Item] = []

    /// De gekozen eindtijd bij "Tot", en wat daaruit volgde. Lokaal, want dit is een vraag die
    /// je stelt en geen instelling die bewaard wordt — wat er van de vraag terechtkwam staat
    /// daarna in `Prefs.autoOffMinutes`, op de enige plek waar een duur hoort te staan.
    @State private var untilTime = Date()
    @State private var untilExplanation: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().padding(.vertical, 8)
            keepAwakeSection
            Divider().padding(.vertical, 8)
            backlightSection
            Divider().padding(.vertical, 8)
            footer
        }
        .padding(14)
        .frame(width: 320)
        .onAppear { runningApps = RunningApps.list() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(nsImage: model.menuBarIcon(pointSize: 26))
                .foregroundStyle(model.status.isError ? Color.orange : (model.status.isOn ? Color.accentColor : Color.secondary))
            VStack(alignment: .leading, spacing: 2) {
                Text(model.statusText)
                    .font(.headline)
                if let line = model.safetyNetLine {
                    Text(line)
                        .font(.subheadline)
                        .foregroundStyle(model.safetyNetsDisarmed ? Color.orange : Color.secondary)
                }
                // Waar de sessie aan hangt, naast hoe lang hij nog loopt. Bewust een aparte
                // regel: `safetyNetLine` gaat over wat de Mac straks weer laat slapen, en
                // zijn derde tak (vlag aan zonder sessie) mag daar niet in verwateren.
                if let line = model.bindingLine {
                    Text(line)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var subtitle: String {
        var parts: [String] = []
        if let battery = model.battery {
            parts.append("\(battery.percent)%\(battery.onAC ? " · lader" : "")")
        }
        parts.append(model.lidClosed ? "klep dicht" : "klep open")
        // Only while a session is running. Outside one nothing observes the network at all,
        // and `online` simply holds its last value — so this line cheerfully reported
        // "verbonden" with the wifi switched off, which is worse than saying nothing.
        if model.networkWatched {
            parts.append(model.online ? "verbonden" : "geen verbinding")
        }
        if model.thermal != .nominal { parts.append("temperatuur \(model.thermal.label)") }
        return parts.joined(separator: " · ")
    }

    // MARK: - Keep awake

    private var keepAwakeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Bound to what the user asked for, not to `status`. An error during a live
            // session — an unreadable IOKit read, a lock that did not take — rendered the
            // switch as OFF while the session was running, and the guardian only repaired
            // it on the next twenty-second tick. Clicking it inside that window silently
            // started a second session and pushed the deadline out by the full duration.
            Toggle(isOn: Binding(
                get: { model.intendedOn },
                set: { model.setKeepAwake($0) }
            )) {
                Text("Mac wakker houden").fontWeight(.medium)
            }
            .toggleStyle(.switch)
            .disabled(model.busy)

            // Hoe deze sessie begonnen is. Altijd zichtbaar zolang er iets loopt, ook bij de
            // schakelaar: een regel die er soms wel en soms niet staat maakt zijn afwezigheid
            // dubbelzinnig, en dan is "welke trigger heeft dit gestart?" niet te beantwoorden.
            // Bewust hier en niet in `safetyNetLine`: die zin is rond drie gevallen opgebouwd
            // en zijn derde tak — vlag aan zonder sessie — mag niet verwateren.
            if let line = model.triggerLine {
                Text(line)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            armingRow

            durationRow

            processRow

            Text(model.behaviourSummary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let message = model.lastMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(model.status.isError ? Color.orange : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let slept = model.sleepDuringSession {
                brokenPromiseWarning(slept)
            }

            if model.safetyNetsDisarmed {
                disarmedWarning
            }

            if model.grantStatus != .granted {
                grantWarning
            }

            if let conflict = model.conflict {
                conflictWarning(conflict)
            }

            if !model.outages.isEmpty {
                outageList
            }

            Button {
                model.sleepNow()
            } label: {
                Label("Nu slapen", systemImage: "powersleep")
            }
            .buttonStyle(.link)
            .disabled(model.busy)
        }
    }

    /// "Ga aan zodra ik de klep dichtdoe" — fase 3.1.
    ///
    /// Vooraf zeggen wat je wilt, in plaats van een gebaar meten op het moment dat de klep
    /// dichtgaat. Dat gebaar zou Toegankelijkheid vragen (staat op deze Mac uit) en het zou
    /// afhangen van een klepmelding die tot tien seconden te laat kan komen — dan is de
    /// toetsstand niets meer waard. Zo kan het nooit per ongeluk afgaan.
    ///
    /// De aftelling rekent met `model.now`, de kloktik die het hele paneel al gebruikt. Geen
    /// eigen timer: dat zou een tweede klok naast de guardian zijn.
    @ViewBuilder private var armingRow: some View {
        if let arm = model.lidArm {
            HStack(spacing: 6) {
                Label("Gaat aan zodra je de klep dichtdoet", systemImage: "laptopcomputer.and.arrow.down")
                    .font(.caption)
                    .foregroundStyle(Color.accentColor)
                    .fixedSize(horizontal: false, vertical: true)
                Text("· \(arm.resterendeTekst(op: model.now))")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Intrekken") { model.cancelArming() }
                    .buttonStyle(.link)
                    .font(.caption)
            }
        } else if !model.intendedOn {
            Button {
                model.armForLidClose()
            } label: {
                Label("Aanzetten zodra ik de klep dichtdoe", systemImage: "laptopcomputer.and.arrow.down")
                    .font(.caption)
            }
            .buttonStyle(.link)
            .disabled(model.busy)
        }
    }

    /// Duration control, right here rather than only in Settings.
    ///
    /// This is the number you most often want to change at the moment you flip the switch,
    /// so making it a trip to a separate window would be the wrong place for it. Adjusting
    /// it during a running session moves the deadline immediately — anchored to when the
    /// session started, so shortening it brings the end forward instead of pushing it back.
    private var durationRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("Duur")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                Spacer()

                Button {
                    model.adjustAutoOff(byMinutes: -15)
                } label: {
                    Image(systemName: "minus")
                }
                .buttonStyle(.borderless)
                .disabled(model.autoOffMinutes <= 5)

                Text(model.configuredDurationText)
                    .font(.callout.weight(.medium))
                    .monospacedDigit()
                    .frame(width: 82)
                    .multilineTextAlignment(.center)

                Button {
                    model.adjustAutoOff(byMinutes: 15)
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .disabled(model.autoOffMinutes >= 24 * 60)
            }

            HStack(spacing: 4) {
                ForEach(quickDurations, id: \.self) { total in
                    Button(AppModel.durationText(total).replacingOccurrences(of: " uur", with: " u")) {
                        model.setAutoOff(minutes: total)
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .foregroundStyle(model.autoOffMinutes == total ? Color.accentColor : Color.secondary)
                }
                Spacer()
                if let ends = model.deadlineText {
                    Text("tot \(ends)")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }

            untilRow
        }
    }

    /// "Tot 18:00" naast "voor 4,5 uur".
    ///
    /// Je denkt vaker in een eindtijd dan in een duur, maar het blijft dezelfde ene instelling:
    /// de kloktijd wordt door `setAutoOffUntil` omgerekend naar minuten en gaat door dezelfde
    /// `setAutoOff` heen als de knoppen hierboven. Er wordt dus nergens een tweede eindtijd
    /// bewaard, en de tijdslimiet blijft precies één planner houden.
    ///
    /// Met een knop en niet bij elke wijziging van de kiezer: elke keer zetten schrijft ook de
    /// standaardduur voor de vólgende sessie, en dat hoort te gebeuren op het moment dat je het
    /// vraagt — niet terwijl je nog aan het typen bent.
    private var untilRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text("Tot")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                DatePicker("", selection: $untilTime, displayedComponents: .hourAndMinute)
                    .labelsHidden()
                    .datePickerStyle(.field)
                    .controlSize(.small)
                Button("Zetten") { untilExplanation = model.setAutoOffUntil(untilTime) }
                    .buttonStyle(.link)
                    .font(.caption)
                Spacer()
            }
            if let untilExplanation {
                Text(untilExplanation)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear {
            // Begin bij de eindtijd die er nu staat, zodat de kiezer nooit op een willekeurig
            // moment in het verleden opent.
            untilTime = model.deadline
                ?? Date().addingTimeInterval(Double(model.autoOffMinutes) * 60)
            // En begin zonder de uitleg van de vorige keer: die ging over een sessie en een
            // tijdstip die er nu misschien niet meer zijn.
            untilExplanation = nil
        }
    }

    private var quickDurations: [Int] { [30, 2 * 60, 4 * 60, 6 * 60, 8 * 60] }

    /// Koppel de sessie aan een draaiende app: hij stopt dan zodra die app klaar is.
    ///
    /// Dit maakt een sessie alleen korter, nooit langer — de tijdslimiet blijft er als
    /// plafond overheen gaan, precies zoals bij `dopamine on --until-exit`. Willekeurige
    /// procesnummers blijven werk voor de opdrachtregel; een lijst van álle processen is
    /// honderden regels systeemwerk waar niemand iets aan heeft.
    private var processRow: some View {
        HStack(spacing: 8) {
            Text("Stoppen als")
                .font(.callout)
                .foregroundStyle(.secondary)
            Menu {
                if runningApps.isEmpty {
                    Text("Geen apps gevonden")
                } else {
                    ForEach(runningApps) { item in
                        Button("\(item.naam) (\(item.pid))") { model.keepAwakeUntilQuit(of: item) }
                    }
                }
            } label: {
                Text(model.binding.map { "\($0.identity.naam) klaar is" } ?? "een app klaar is…")
                    .font(.callout)
            }
            .menuStyle(.borderlessButton)
            .disabled(model.busy)
            Spacer()
        }
    }

    /// The single most important thing this app can tell you: the Mac will not sleep, and
    /// nothing running unattended is able to change that.
    private var disarmedWarning: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Vanzelf stoppen werkt nu niet", systemImage: "shield.slash.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.red)
            Text("De tijdslimiet, de accugrens en de temperatuurbewaking kunnen de Mac niet zelf "
                 + "weer laten slapen: daar is een wachtwoord voor nodig dat met de klep dicht "
                 + "niemand kan invullen. Zet het zo nodig zelf terug — plak deze regel in "
                 + "Terminal:")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("sudo pmset -a disablesleep 0")
                .font(.system(.caption2, design: .monospaced))
                .textSelection(.enabled)
        }
        .padding(8)
        .background(Color.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
    }

    /// The one finding that outranks everything else in this panel: the Mac slept while we
    /// were holding it awake, so the app's single promise does not hold on this machine.
    /// Deliberately stays visible after the session ends — it is not news that expires.
    private func brokenPromiseWarning(_ episode: SleepWatch.Episode) -> some View {
        // Only the flag-was-up case is an accusation against the kernel. The other case —
        // the flag was cleared from outside while a session was still running — is the Mac
        // behaving correctly, and saying "dat hoort niet te kunnen" about it would be a
        // false alarm dressed in red.
        let broke = model.sleepBrokeThePromise
        return VStack(alignment: .leading, spacing: 6) {
            Label(broke ? "De Mac heeft tóch geslapen" : "Mac sliep — de blokkade stond niet aan",
                  systemImage: broke ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(broke ? .red : .orange)
            Text(episode.describe().prefix(1).uppercased() + episode.describe().dropFirst() + ". "
                 + (broke
                    ? "Dat hoort niet te kunnen terwijl de slaapblokkade aan stond: op deze Mac houdt de belofte dus niet."
                    : "De slaapblokkade was buiten Dopamine Code om uitgezet, dus dit zegt niets over de blokkade zelf."))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if broke {
                Text("./verify.sh --after")
                    .font(.system(.caption2, design: .monospaced))
                    .textSelection(.enabled)
            }
        }
        .padding(8)
        .background((broke ? Color.red : Color.orange).opacity(0.15), in: RoundedRectangle(cornerRadius: 6))
    }

    private var grantWarning: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(model.grantText, systemImage: "lock.trianglebadge.exclamationmark")
                .font(.caption)
                .foregroundStyle(.orange)
            Text("Zonder deze eenmalige regel vraagt macOS bij elke schakeling om je wachtwoord. "
                 + "Met de klep dicht kan niemand dat invullen, dus kan de Mac daarna niet "
                 + "vanzelf weer gaan slapen.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Regel installeren…") { model.installGrant() }
                    .disabled(model.busy)
                Button("Opnieuw controleren") { model.refreshGrant() }
            }
            .controlSize(.small)

            // The Terminal route, for when the authorisation sheet misbehaves. It is also
            // the honest one: you get to read the script before running it as root.
            if !SudoersGrant.manualCommand.isEmpty {
                Text("Of in Terminal:")
                    .font(.caption2).foregroundStyle(.secondary)
                Text(SudoersGrant.manualCommand)
                    .font(.system(.caption2, design: .monospaced))
                    .textSelection(.enabled)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(8)
        .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 6))
    }

    /// Two different problems, deliberately drawn differently. Two tools each holding the
    /// Mac up their own way only makes a test meaningless; two tools writing the same
    /// global flag means either can undo the other mid-session. Painting both the same
    /// calm orange said the second was as harmless as the first.
    private func conflictWarning(_ conflict: ConflictWatch.Conflict) -> some View {
        let tint: Color = conflict.sharesTheFlag ? .red : .orange
        return VStack(alignment: .leading, spacing: 6) {
            Label(conflict.sharesTheFlag
                  ? "\(conflict.name) schakelt dezelfde instelling"
                  : "\(conflict.name) draait ook",
                  systemImage: conflict.sharesTheFlag ? "exclamationmark.octagon.fill" : "exclamationmark.2")
                .font(.caption.weight(conflict.sharesTheFlag ? .semibold : .regular))
                .foregroundStyle(tint)
                .fixedSize(horizontal: false, vertical: true)
            Text(conflict.detail)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("\(conflict.name) afsluiten") { model.quitAmphetamine() }
                Button("Niet meer melden") { model.dismissConflictWarning() }
            }
            .controlSize(.small)
        }
        .padding(8)
        .background(tint.opacity(conflict.sharesTheFlag ? 0.15 : 0.10), in: RoundedRectangle(cornerRadius: 6))
    }

    private var outageList: some View {
        VStack(alignment: .leading, spacing: 3) {
            // The list outlives its session on purpose — it is the after-the-fact report —
            // but the heading has to say which session it belongs to. "Netwerk deze sessie"
            // above last night's outages, at two in the afternoon with keep-awake off, is
            // simply a false statement.
            Text(model.outagesFromFinishedSession ? "Internet — vorige keer" : "Internet — nu actief")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(model.outages.suffix(3)) { outage in
                Text("• " + outage.describe())
                    .font(.caption2)
                    .foregroundStyle(outage.isOngoing ? Color.orange : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Backlight

    private var backlightSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: Binding(
                get: { model.backlightOn ?? false },
                set: { _ in model.toggleBacklight() }
            )) {
                Text("Toetsenbordverlichting").fontWeight(.medium)
            }
            .toggleStyle(.switch)

            if model.backlight.hasDirectControl {
                if let level = model.backlightLevel {
                    Slider(
                        value: Binding(
                            get: { Double(level) },
                            set: { model.setBacklightLevel(Float($0)) }
                        ),
                        in: 0...1
                    )
                    .controlSize(.small)
                }
                if model.backlightSuppressed {
                    Text("Het toetsenbord blijft nu donker omdat het scherm uit staat. Wat je hier instelt zie je pas als het scherm weer aan gaat.")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else if !KeyboardBacklight.canPostEvents {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Deze Mac laat de verlichting niet rechtstreeks instellen. Dopamine Code "
                         + "kan hem alleen schakelen door de helderheidstoetsen na te bootsen, en "
                         + "daarvoor is toestemming nodig bij Privacy → Toegankelijkheid.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Systeeminstellingen openen") {
                        KeyboardBacklight.openAccessibilitySettings()
                    }
                    .controlSize(.small)
                }
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Button("Instellingen…") { SettingsWindow.show() }
            Spacer()
            Button("Stop") {
                NSApp.terminate(nil)
            }
        }
        .controlSize(.small)
    }
}
