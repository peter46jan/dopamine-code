import AppKit

/// Notices other tools that are also holding the Mac awake.
///
/// Amphetamine's `PreventUserIdleSystemSleep` assertion does not survive a closed lid —
/// that is precisely why this app exists — but while both are running it is impossible
/// to tell which one is keeping the machine up, which makes any test of this app
/// meaningless.
enum ConflictWatch {

    struct Conflict {
        let name: String
        let detail: String
    }

    private static let amphetamineBundleID = "com.if.Amphetamine"

    static func amphetamineRunning() -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: amphetamineBundleID).isEmpty
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
        var detail = "Amphetamine doet ongeveer hetzelfde, maar alleen zolang de klep open is — "
            + "dichtklappen overleeft het niet. Draaien ze allebei, dan is niet te zien welke van "
            + "de twee de Mac wakker houdt."
        let holders = await sleepAssertionHolders()
        if !holders.isEmpty {
            detail += "\n\nDeze programma's houden de Mac nu wakker: " + holders.joined(separator: ", ") + "."
        }
        return Conflict(name: "Amphetamine", detail: detail)
    }

    static func quitAmphetamine() {
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: amphetamineBundleID) {
            app.terminate()
        }
        EventLog.shared.info("Amphetamine afsluiten aangevraagd.")
    }
}
