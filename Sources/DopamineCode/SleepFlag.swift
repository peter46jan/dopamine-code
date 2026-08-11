import Foundation
import IOKit

/// Reads and writes the kernel `SleepDisabled` flag on `IOPMrootDomain`.
///
/// Reading and writing deliberately use different mechanisms:
///
/// * **Read** goes straight to the IORegistry. `pmset -g` is *not* usable here: its
///   print statement is guarded by `if (key exists in prefs dict)`, so on a machine
///   where `disablesleep` has never been set it prints nothing at all — indistinguishable
///   from "0". The IORegistry property is always published, always a CFBoolean, and
///   readable by an unprivileged, unentitled process.
/// * **Write** shells out to `pmset`, because setting the flag needs root.
enum SleepFlag {

    // MARK: - Reading

    /// The live kernel value. `nil` means the property could not be read at all,
    /// which is a different situation from "sleep is allowed" and must not be
    /// collapsed into `false`.
    static func read() -> Bool? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }

        guard let raw = IORegistryEntryCreateCFProperty(
            service, "SleepDisabled" as CFString, kCFAllocatorDefault, 0
        )?.takeRetainedValue() else { return nil }

        if CFGetTypeID(raw) == CFBooleanGetTypeID() {
            return CFBooleanGetValue((raw as! CFBoolean))
        }
        if let n = raw as? NSNumber { return n.boolValue }
        return nil
    }

    /// Whether the lid sensor currently reports the lid as closed.
    static func clamshellClosed() -> Bool? {
        boolProperty("AppleClamshellState")
    }

    /// Whether the kernel would sleep on lid close right now. With the flag set this
    /// should read false — it is the single best confirmation that the flag is doing
    /// the job it was set for.
    static func clamshellCausesSleep() -> Bool? {
        boolProperty("AppleClamshellCausesSleep")
    }

    private static func boolProperty(_ name: String) -> Bool? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard let raw = IORegistryEntryCreateCFProperty(
            service, name as CFString, kCFAllocatorDefault, 0
        )?.takeRetainedValue() else { return nil }
        if CFGetTypeID(raw) == CFBooleanGetTypeID() { return CFBooleanGetValue((raw as! CFBoolean)) }
        if let n = raw as? NSNumber { return n.boolValue }
        return nil
    }

    // MARK: - Writing

    enum WriteOutcome {
        /// The flag was written and read back at the requested value.
        case verified
        /// The command reported success but the kernel disagrees. Never show this as green.
        case commandSucceededButFlagWrong(actual: Bool?)
        /// The passwordless grant is missing or no longer applies.
        case needsAuthorisation
        /// The user dismissed the authorisation sheet.
        case cancelled
        /// Anything else.
        case failed(String)
    }

    /// Sets the flag, then verifies it against the kernel.
    ///
    /// Tries the passwordless sudoers grant first; if that is refused, falls back to a
    /// one-off admin prompt. It never silently does nothing.
    /// `pmset` reports a failed write on **stdout** and then exits 0 anyway, so a zero
    /// exit status proves nothing on its own.
    private static func pmsetReportedFailure(_ result: ShellResult) -> Bool {
        let text = result.combined.lowercased()
        return text.contains("must be run as root")
            || text.contains("failed to set the value")
            || text.contains("not privileged")
    }

    static func set(_ on: Bool, allowPrompt: Bool) -> WriteOutcome {
        let value = on ? "1" : "0"
        let result = Shell.run("/usr/bin/sudo", ["-n", "/usr/bin/pmset", "-a", "disablesleep", value])

        if result.ok && !pmsetReportedFailure(result) {
            return verify(expecting: on, after: "sudo -n pmset -a disablesleep \(value)")
        }

        let stderr = result.stderr.lowercased()
        let looksLikeMissingGrant =
            pmsetReportedFailure(result)
            || stderr.contains("a password is required")
            || stderr.contains("a terminal is required")
            || stderr.contains("not allowed")
            || stderr.contains("may not run")
            || stderr.contains("no tty")

        guard allowPrompt else {
            EventLog.shared.warn("sudo -n geweigerd en prompt niet toegestaan: \(result.combined)")
            return looksLikeMissingGrant ? .needsAuthorisation : .failed(result.combined)
        }

        EventLog.shared.warn("sudo -n geweigerd (\(result.combined)) — val terug op beheerdersprompt")

        let admin = Shell.runAsAdmin(
            "/usr/bin/pmset -a disablesleep \(value)",
            prompt: on
                ? "Dopamine Code wil systeemslaap uitschakelen."
                : "Dopamine Code wil systeemslaap weer toestaan."
        )

        if Shell.wasCancelled(admin) {
            EventLog.shared.warn("Beheerdersprompt geannuleerd; vlag ongewijzigd.")
            return .cancelled
        }
        guard admin.ok, !pmsetReportedFailure(admin) else {
            EventLog.shared.error("Beheerdersprompt mislukt: \(admin.combined)")
            return .failed(admin.combined.isEmpty ? "pmset meldde een fout" : admin.combined)
        }
        return verify(expecting: on, after: "osascript admin pmset -a disablesleep \(value)")
    }

    private static func verify(expecting on: Bool, after command: String) -> WriteOutcome {
        // `pmset` does not write the IORegistry itself: it stores a preference and posts a
        // notification, after which powerd applies it and the kernel queues yet another
        // async power event. A read taken straight after the command returns the OLD
        // value, so this has to be a retry ladder rather than a single check. Roughly
        // 5.5 seconds total, which is far longer than the transition has ever taken but
        // still short enough that a genuinely failed write is reported promptly.
        for delay in [0.05, 0.10, 0.20, 0.40, 0.75, 1.0, 1.5, 1.5] {
            if let actual = read(), actual == on {
                EventLog.shared.info("SleepDisabled = \(on ? 1 : 0), geverifieerd via IOPMrootDomain.")
                return .verified
            }
            Thread.sleep(forTimeInterval: delay)
        }
        let actual = read()
        EventLog.shared.error(
            "\(command) gaf exitcode 0, maar IOPMrootDomain meldt SleepDisabled = "
            + (actual.map { $0 ? "1" : "0" } ?? "onleesbaar")
            + " terwijl \(on ? "1" : "0") verwacht werd."
        )
        return .commandSucceededButFlagWrong(actual: actual)
    }
}
