import AppKit

/// De lijst met draaiende apps voor de proceskiezer in het menu.
///
/// Bewust alleen `NSWorkspace`: dat kost geen enkel recht, geeft een naam en een icoon, en
/// levert precies de processen waar iemand "wacht tot dit klaar is" over zegt. Een
/// willekeurige pid koppelen blijft werk voor de opdrachtregel (`dopamine on --until-exit`);
/// het volledige procesoverzicht via `KERN_PROC_ALL` is een andere, veel grotere keuze —
/// honderden regels systeemprocessen waar je niets aan hebt.
enum RunningApps {

    struct Item: Identifiable, Equatable {
        let pid: pid_t
        let naam: String
        var id: pid_t { pid }
    }

    static func list() -> [Item] {
        NSWorkspace.shared.runningApplications
            .filter { app in
                // Alleen apps met een venster en een naam; achtergrondagenten zeggen niemand iets.
                app.activationPolicy == .regular
                    && app.processIdentifier > 0
                    // Onszelf niet: een sessie die stopt zodra Dopamine Code klaar is, is geen
                    // sessie — bij het afsluiten wordt de vlag toch al teruggezet.
                    && app.processIdentifier != ProcessInfo.processInfo.processIdentifier
            }
            .map { Item(pid: $0.processIdentifier, naam: $0.localizedName ?? "onbekend") }
            .sorted { $0.naam.localizedCaseInsensitiveCompare($1.naam) == .orderedAscending }
    }

    static func icon(for pid: pid_t) -> NSImage? {
        NSRunningApplication(processIdentifier: pid)?.icon
    }
}
