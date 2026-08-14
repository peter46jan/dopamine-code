import Foundation

/// Feiten over een proces, en een snelle prikkel als het verdwijnt.
///
/// Dit bestand houdt met opzet **geen enkele sessiestand** bij. Het voor de hand liggende
/// ontwerp — een bewaker die bij een exit zelf de sessie beëindigt — is precies de tweede
/// waarheid waar de guardian uit voortkomt: dan beslist iets anders dan `releaseReason()`
/// wanneer de vlag eraf mag, en die beslissing kijkt dan naar de app in plaats van naar de
/// kernel. De exit-melding hieronder doet daarom één ding: de guardian aanstoten.
///
/// De poll is de garantie, de melding alleen de snelheid. Hier gemeten: een
/// `DispatchSource`-procesbron werkt op een niet-eigen kindproces van dezelfde gebruiker en
/// vuurt direct bij exit, maar hij vuurt óók meteen voor een pid die niet bestaat en hij
/// vuurt nooit voor een proces van een andere gebruiker. Op zichzelf is hij dus niet
/// betrouwbaar genoeg; `identify()` in de guardian-tik geeft het echte antwoord. Dezelfde
/// constructie als in `ClamshellMonitor` (regel 73-77), om dezelfde reden.
enum ProcessWatch {

    /// Genoeg om een proces later te herkennen. De starttijd staat erbij omdat een pid
    /// hergebruikt wordt: zonder dat zou een sessie gekoppeld blijven aan een pid die
    /// inmiddels van een heel ander programma is.
    struct Identity: Equatable {
        let pid: pid_t
        let startSec: Int64
        let startUsec: Int32
        let naam: String
        let uid: uid_t

        /// Dezelfde pid met een andere starttijd is een ánder proces, dus verdwenen.
        func isSameProcess(as other: Identity) -> Bool {
            pid == other.pid && startSec == other.startSec && startUsec == other.startUsec
        }

        var label: String { "'\(naam)' (\(pid))" }
    }

    /// Leest pid, starttijd, naam en eigenaar uit de kerneltabel. `nil` betekent: dit proces
    /// bestaat niet (meer).
    ///
    /// LET OP bij de foutafhandeling, hier gemeten: voor een dode pid geeft `sysctl` gewoon
    /// **0** terug met `size == 0`. Alleen op `rc == 0` controleren levert dan een genulde
    /// struct op — pid 0, starttijd 0, lege naam — die als een levend proces gelezen wordt,
    /// en dan stopt een sessie nooit meer omdat de starttijd altijd "klopt".
    static func identify(_ pid: pid_t) -> Identity? {
        guard pid > 0 else { return nil }
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        let rc = sysctl(&mib, u_int(mib.count), &info, &size, nil, 0)
        guard rc == 0, size >= MemoryLayout<kinfo_proc>.size else { return nil }
        guard info.kp_proc.p_pid == pid else { return nil }

        // `p_comm` is 16 tekens plus nul en dus afgekapt, maar hij werkt ook voor processen
        // van root — wat `proc_pidpath` niet garandeert, en de bedoeling is juist dat je aan
        // een willekeurige pid kunt koppelen.
        var comm = info.kp_proc.p_comm
        let commLengte = MemoryLayout.size(ofValue: comm)
        let naam = withUnsafePointer(to: &comm) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: commLengte) {
                String(cString: $0)
            }
        }

        return Identity(
            pid: pid,
            startSec: Int64(info.kp_proc.p_starttime.tv_sec),
            startUsec: Int32(info.kp_proc.p_starttime.tv_usec),
            naam: naam.isEmpty ? "onbekend" : naam,
            uid: info.kp_eproc.e_ucred.cr_uid
        )
    }

    /// De snelle route. Meldt dat een proces geëindigd is; wat dat betekent beslist de
    /// guardian, niet dit object.
    ///
    /// `@unchecked Sendable`: de bron levert af op de hoofdqueue en de handler doet daar
    /// niets anders dan een `Task { @MainActor }` starten, dus er is geen gedeelde staat om
    /// te beschermen.
    final class ExitWatcher: @unchecked Sendable {
        private let source: DispatchSourceProcess

        /// Geeft `nil` als er geen bron gemaakt kon worden. Dan blijft alleen de poll over,
        /// en dat is geen ramp — het is de route die het antwoord toch al geeft.
        init?(pid: pid_t, onExit: @escaping @Sendable () -> Void) {
            guard pid > 0 else { return nil }
            let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
            source.setEventHandler { onExit() }
            self.source = source
            source.resume()
        }

        func cancel() {
            source.setEventHandler(handler: nil)
            source.cancel()
        }

        deinit { source.cancel() }
    }
}
