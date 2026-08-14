import AppKit

/// Notices other tools that are also holding the Mac awake.
///
/// This used to say that Amphetamine's `PreventUserIdleSystemSleep` assertion cannot
/// survive a closed lid, and that the difference was the reason this app exists. That is
/// no longer true, and stating it in the UI was worse than saying nothing: Amphetamine
/// does closed-display mode without an external display, and since version 5.3 it ships
/// "Power Protect" to survive power-source transitions on Apple Silicon. Power Protect
/// installs `/etc/sudoers.d/amphetamine_powerProtect` — the same architecture as our own
/// rule, reaching the same global kernel flag.
///
/// So there are two different conflicts, and they are not equally bad:
///
/// * **An assertion.** Both hold the Mac up by different means. Nothing breaks, but while
///   both run it cannot be told which one is doing it, which makes any test of this app
///   meaningless.
/// * **The same flag.** With Power Protect installed, Amphetamine writes the one global
///   value this whole app is built around. Neither side knows about the other, so either
///   can clear it while the other still needs it — and `SleepDisabled` has no owner, no
///   reference count and no second opinion.
enum ConflictWatch {

    struct Conflict {
        let name: String
        let detail: String
        /// Both tools write the same kernel flag. Not a cosmetic overlap: one can undo the
        /// other at any moment, in either direction.
        let sharesTheFlag: Bool
    }

    private static let amphetamineBundleID = "com.if.Amphetamine"

    /// Amphetamine's own sudoers rule, from its Power Protect installer.
    private static let amphetamineGrantPath = "/etc/sudoers.d/amphetamine_powerProtect"

    static func amphetamineRunning() -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: amphetamineBundleID).isEmpty
    }

    /// Whether Amphetamine has a passwordless route to the same flag.
    ///
    /// Only the file's existence is read, never its contents: `/etc/sudoers.d` is 0755 so
    /// the entry is visible to anyone, while the rule itself is root-only — which is
    /// exactly as much as this needs to know, and it costs no privilege to find out.
    static func amphetaminePowerProtectInstalled() -> Bool {
        FileManager.default.fileExists(atPath: amphetamineGrantPath)
    }

    /// Everything currently asserting against sleep, as reported by the power manager.
    ///
    /// Async because both callers sit on the main actor: this ran at launch and again on
    /// every menu open, each time putting an eight-second-timeout process spawn in front of
    /// the run loop that drives the guardian.
    static func sleepAssertionHolders() async -> [String] {
        let result = await Shell.runAsync("/usr/bin/pmset", ["-g"], timeout: 8)
        guard result.ok else { return [] }
        // The line reads: ` sleep  1 (sleep prevented by caffeinate, Amphetamine, powerd)`
        guard let line = result.stdout
            .split(separator: "\n")
            .first(where: { $0.contains("sleep prevented by") }) else { return [] }
        guard let open = line.firstIndex(of: "("), let close = line.lastIndex(of: ")") else { return [] }
        let inner = line[line.index(after: open)..<close]
            .replacingOccurrences(of: "sleep prevented by", with: "")
        return inner
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .reduce(into: [String]()) { acc, name in if !acc.contains(name) { acc.append(name) } }
    }

    @MainActor
    static func current() async -> Conflict? {
        guard Prefs.warnAboutAmphetamine, amphetamineRunning() else { return nil }

        let sharesTheFlag = amphetaminePowerProtectInstalled()
        var detail = sharesTheFlag
            ? "Amphetamine heeft Power Protect geïnstalleerd en zet daarmee dezelfde "
              + "systeeminstelling om als Dopamine Code. Geen van beide weet van de ander, "
              + "dus wie het laatst schakelt wint: Amphetamine kan de Mac laten slapen "
              + "midden in jouw sessie, en Dopamine Code kan dat andersom net zo goed. "
              + "Gebruik er één tegelijk."
            : "Amphetamine houdt de Mac op zijn eigen manier wakker. Er gaat niets kapot, "
              + "maar zolang ze allebei draaien is niet te zien welke van de twee het doet — "
              + "en dan zegt een test van Dopamine Code niets."

        let holders = await sleepAssertionHolders()
        if !holders.isEmpty {
            detail += "\n\nDeze programma's houden de Mac nu wakker: " + holders.joined(separator: ", ") + "."
        }
        return Conflict(name: "Amphetamine", detail: detail, sharesTheFlag: sharesTheFlag)
    }

    static func quitAmphetamine() {
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: amphetamineBundleID) {
            app.terminate()
        }
        EventLog.shared.info("Amphetamine afsluiten aangevraagd.")
    }
}
