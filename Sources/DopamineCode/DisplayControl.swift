import CoreGraphics
import Foundation

/// Puts the internal panel to sleep while the system stays awake.
///
/// `SleepDisabled` blocks *system* sleep only; display sleep runs through a separate
/// path in the kernel and is unaffected. Without this the internal screen keeps burning
/// at full brightness under a closed lid — invisible, and expensive in both battery and
/// heat.
enum DisplayControl {

    /// `/usr/bin/pmset displaysleepnow` needs no root: the privilege rides on the
    /// binary's `com.apple.private.SkyLight.displaycontrol` entitlement, not on the
    /// calling uid. Note it is deliberately *not* part of the sudoers grant — adding it
    /// would widen the privileged surface for no reason.
    /// Whether an external display is currently active.
    ///
    /// This decides whether a closed lid means "put away" or "docked and still working".
    /// In clamshell mode with an external monitor the lid is shut but the Mac is in use —
    /// locking the session and blanking the screen every thirty seconds would be actively
    /// hostile. The target scenario for this app is a closed lid with *no* external
    /// display, so that is the only case where the lid should trigger anything.
    /// Uses the ONLINE list, not the active one. "Active" means awake and drawable, so a
    /// docked monitor that has merely gone to sleep on its idle timer drops out of it —
    /// and the dock exemption would evaporate at exactly the wrong moment, locking the
    /// session and blanking a monitor the user is about to come back to. Online means
    /// connected, asleep or not, which is what "is a monitor attached" actually asks.
    static var externalDisplayActive: Bool {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return false }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return false }
        return ids.prefix(Int(count)).contains { CGDisplayIsBuiltin($0) == 0 }
    }

    /// Whether the panel is actually dark right now.
    ///
    /// `displaysleepnow` is a request, and until this existed nothing ever checked whether
    /// it was granted. The re-assert fired every thirty seconds for hours into the dark
    /// without knowing — and the failure it exists to prevent, a panel burning at full
    /// brightness under a shut lid, was exactly the thing it could not observe.
    static var mainDisplayAsleep: Bool {
        CGDisplayIsAsleep(CGMainDisplayID()) != 0
    }

    /// - Parameter quiet: suppresses the success log line. Used by the periodic re-assert,
    ///   which would otherwise write a line every 30 seconds for hours.
    ///
    /// Async because every caller is on the main actor and `pmset` is a process spawn. The
    /// re-assert alone ran it every thirty seconds for the whole lid-closed session, each
    /// time with the guardian queued behind it.
    @discardableResult
    static func sleepDisplayNow(quiet: Bool = false) async -> Bool {
        evaluate(await Shell.runAsync("/usr/bin/pmset", ["displaysleepnow"], timeout: 10), quiet: quiet)
    }

    private static func evaluate(_ r: ShellResult, quiet: Bool) -> Bool {
        // pmset can report a failure on stdout and still exit 0.
        let complained = r.combined.lowercased().contains("failed")
            || r.combined.lowercased().contains("must be run as root")
        if r.ok && !complained {
            if !quiet { EventLog.shared.info("Displayslaap geforceerd (pmset displaysleepnow).") }
            return true
        }
        EventLog.shared.error("pmset displaysleepnow mislukt: \(r.combined)")
        return false
    }
}
