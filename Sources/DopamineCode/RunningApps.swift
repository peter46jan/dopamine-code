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
        /// Voor fase 3: een trigger wordt op de bundle-id opgeslagen en niet op de pid, want
        /// een pid is morgen van iets anders. Kan `nil` zijn — een app zonder bundle-id is
        /// wel te koppelen (dat gaat over dít proces) maar niet als trigger te bewaren.
        let bundleID: String?
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
            .map { Item(pid: $0.processIdentifier,
                        naam: $0.localizedName ?? "onbekend",
                        bundleID: $0.bundleIdentifier) }
            .sorted { $0.naam.localizedCaseInsensitiveCompare($1.naam) == .orderedAscending }
    }

    static func icon(for pid: pid_t) -> NSImage? {
        NSRunningApplication(processIdentifier: pid)?.icon
    }
}
