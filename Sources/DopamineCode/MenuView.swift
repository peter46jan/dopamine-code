import SwiftUI

/// The menu bar panel.
///
/// This uses `.window` style rather than `.menu`: menu style drops non-text views and
/// does not re-render its body when opened, which makes a live countdown impossible.
struct MenuView: View {
    @ObservedObject var model: AppModel

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
        if model.thermal != .nominal { parts.append("warmte \(model.thermal.label)") }
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
                Text("Blijf actief").fontWeight(.medium)
            }
            .toggleStyle(.switch)
            .disabled(model.busy)

            durationRow

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
        }
    }

    private var quickDurations: [Int] { [30, 2 * 60, 4 * 60, 6 * 60, 8 * 60] }

    /// The single most important thing this app can tell you: the Mac will not sleep, and
    /// nothing running unattended is able to change that.
    private var disarmedWarning: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Vangnetten staan uit", systemImage: "shield.slash.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.red)
            Text("De timer, de batterijgrens en de thermische beveiliging kunnen de vlag niet "
                 + "zelf terugzetten, omdat dat een wachtwoord vraagt dat met de klep dicht "
                 + "niemand kan invullen.")
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
        VStack(alignment: .leading, spacing: 6) {
            Label("De Mac heeft tóch geslapen", systemImage: "exclamationmark.octagon.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.red)
            Text(episode.describe().prefix(1).uppercased() + episode.describe().dropFirst()
                 + ". Dat hoort niet te kunnen met SleepDisabled op 1.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("./verify.sh --after")
                .font(.system(.caption2, design: .monospaced))
                .textSelection(.enabled)
        }
        .padding(8)
        .background(Color.red.opacity(0.15), in: RoundedRectangle(cornerRadius: 6))
    }

    private var grantWarning: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(model.grantText, systemImage: "lock.trianglebadge.exclamationmark")
                .font(.caption)
                .foregroundStyle(.orange)
            Text("Zonder deze regel vraagt elke schakeling om je wachtwoord — wat met de klep dicht niet werkt.")
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

    private func conflictWarning(_ conflict: ConflictWatch.Conflict) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("\(conflict.name) draait nog", systemImage: "exclamationmark.2")
                .font(.caption)
                .foregroundStyle(.orange)
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
        .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 6))
    }

    private var outageList: some View {
        VStack(alignment: .leading, spacing: 3) {
            // The list outlives its session on purpose — it is the after-the-fact report —
            // but the heading has to say which session it belongs to. "Netwerk deze sessie"
            // above last night's outages, at two in the afternoon with keep-awake off, is
            // simply a false statement.
            Text(model.outagesFromFinishedSession ? "Netwerk vorige sessie" : "Netwerk deze sessie")
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
                    Text("Het systeem onderdrukt de verlichting nu (scherm slaapt). Een wijziging is pas zichtbaar als het scherm weer aan is.")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else if !KeyboardBacklight.canPostEvents {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Toegankelijkheid is nodig om de verlichtingstoetsen te simuleren.")
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
