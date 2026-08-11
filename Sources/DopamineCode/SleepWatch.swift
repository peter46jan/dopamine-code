import AppKit
import Foundation

/// Notices that the Mac slept — the one observation that can falsify this app's only promise.
///
/// Everything else in here checks the *flag* that is supposed to prevent sleep. Nothing
/// checked whether sleep actually stayed away. If the veto ever fails — a macOS update, an
/// edge case in `checkSystemSleepAllowed()`, a machine this was never tested on — the menu
/// would calmly report "Blijft actief · nog 1 u 20 min" over a Mac that had been asleep
/// since 02:14, and the log would show a gap indistinguishable from a quiet night.
///
/// Two mechanisms, and the second is the one that carries the weight:
///
/// 1. `NSWorkspace.willSleepNotification` and `didWakeNotification`. Immediate and free.
///    `ClamshellMonitor` notes that `willSleepNotification` is useless here by construction,
///    and that is exactly backwards as a reason to ignore it: it can only fire when the
///    promise is already broken, so every delivery is the alarm.
///
/// 2. The gap between the two mach clocks. `mach_absolute_time()` freezes while the system
///    sleeps; `mach_continuous_time()` does not. Their difference is therefore the total
///    time slept since boot. Measured on this machine twelve days after boot:
///
///        mach_absolute_time    162 u 42 m
///        mach_continuous_time  288 u 04 m
///        verschil              125 u 22 m
///        KERN_BOOTTIME         288 u 04 m   ← wakker + geslapen, tot op de minuut
///
///    That makes it a detector that cannot be missed. It needs no notification to have been
///    delivered and no code of ours to have been running at the time; the kernel keeps the
///    books whether we are awake or not.
final class SleepWatch {

    /// One episode of the machine having been asleep.
    struct Episode {
        /// When we noticed. The sleep itself ended a moment before this.
        let detectedAt: Date
        let seconds: Double

        var began: Date { detectedAt.addingTimeInterval(-seconds) }

        func describe() -> String {
            let clock = DateFormatter()
            clock.dateFormat = "HH:mm:ss"
            return "de Mac heeft \(Self.length(seconds)) geslapen, vanaf ongeveer \(clock.string(from: began))"
        }

        /// Bucket on the seconds, not on the rounded minutes. Rounding first made 45 seconds
        /// come out as "1 minuten" — wrong bucket and wrong grammar, in a sentence that goes
        /// straight into a red panel in the menu.
        private static func length(_ seconds: Double) -> String {
            if seconds < 60 { return "\(Int(seconds.rounded())) seconden" }
            let minutes = Int((seconds / 60).rounded())
            if minutes < 60 { return minutes == 1 ? "1 minuut" : "\(minutes) minuten" }
            let h = minutes / 60, m = minutes % 60
            if m == 0 { return h == 1 ? "1 uur" : "\(h) uur" }
            return "\(h) u \(m) m"
        }
    }

    /// Anything shorter than this is transition noise rather than a night's sleep.
    ///
    /// The detector itself does not drift: both clocks share one timebase, so their
    /// difference is exact however long the machine has been up. (Measured against the RTC
    /// there is drift — 7.1 seconds over twelve days — but that is between the mach timebase
    /// and `KERN_BOOTTIME`, and never enters this subtraction.) Two seconds is therefore
    /// pure margin against transition noise, not against measurement error.
    private static let floorSeconds: Double = 2.0

    private static var timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    /// Total seconds the system has slept since boot, from the kernel's own two clocks.
    ///
    /// **The order of these two reads is load-bearing.** Swift evaluates the left operand of
    /// an infix operator first, so `continuous - absolute` samples the continuous clock at
    /// T1 and the awake clock at T2 > T1, which yields `offset - (T2 - T1)`. On a Mac that
    /// has not slept since boot the offset is exactly zero, so that underflows and `&-`
    /// wraps it to about 7.7 × 10¹¹ seconds.
    ///
    /// Measured over two million paired reads on this machine: reading continuous first
    /// lands below the true offset in 8.6% of samples; reading the awake clock first did so
    /// in 0 of 2,000,000. So this is a deterministic consequence of the read order, not
    /// noise — and reading `awake` first makes the difference `offset + (T2 - T1)`, which
    /// cannot be negative.
    ///
    /// It never showed up in testing here because this Mac had twelve days of accumulated
    /// sleep, which swamps a one-tick skew. A freshly rebooted machine has an offset of zero
    /// and hits it within minutes.
    static func sleptSinceBoot() -> Double {
        let awake = mach_absolute_time()
        let total = mach_continuous_time()
        let tb = timebase
        return Double(total &- awake) * Double(tb.numer) / Double(tb.denom) / 1_000_000_000
    }

    private var lastReading: Double
    /// Wall clock at the previous sample, for the plausibility bound below.
    private var lastSampleAt = Date()
    private var observers: [NSObjectProtocol] = []
    private let onNotification: (String) -> Void

    /// - Parameter onNotification: called on the main queue when macOS announces a sleep or
    ///   a wake. Purely informational; `sample()` is what decides.
    init(onNotification: @escaping (String) -> Void) {
        self.onNotification = onNotification
        self.lastReading = Self.sleptSinceBoot()
    }

    /// Starts listening. Deliberately runs for the whole life of the app rather than per
    /// session: the reading has to stay current between sessions, or the first sample after
    /// an activation would report every minute the Mac slept while the app sat idle.
    func start() {
        stop()
        lastReading = Self.sleptSinceBoot()
        lastSampleAt = Date()
        let centre = NSWorkspace.shared.notificationCenter
        observers.append(centre.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.onNotification("macOS meldt: systeem gaat slapen.")
        })
        observers.append(centre.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.onNotification("macOS meldt: systeem is wakker geworden.")
        })
    }

    func stop() {
        let centre = NSWorkspace.shared.notificationCenter
        for observer in observers { centre.removeObserver(observer) }
        observers.removeAll()
    }

    /// Returns an episode if the machine slept since the previous call.
    ///
    /// Called from the guardian tick, so the resolution is the tick interval — the duration
    /// is exact, only the moment of noticing is rounded.
    func sample() -> Episode? {
        let now = Self.sleptSinceBoot()
        let wallGap = Date().timeIntervalSince(lastSampleAt)
        defer { lastReading = now; lastSampleAt = Date() }

        let delta = now - lastReading
        guard delta >= Self.floorSeconds else { return nil }

        // The machine cannot have slept longer than the wall clock has advanced since the
        // previous sample. Anything past that is a measurement fault, and this alarm is far
        // too loud — red panel, sticky error status, notification, sound — to be raised on
        // a number that is impossible on its face. Defence in depth behind the read-order
        // fix above, and a net under whatever the next surprise turns out to be.
        guard delta <= wallGap + 5 else {
            EventLog.shared.warn(
                "Slaapmeting genegeerd: \(Int(delta)) s geslapen gemeld binnen een venster van "
                + "\(Int(wallGap)) s, wat niet kan."
            )
            return nil
        }
        return Episode(detectedAt: Date(), seconds: delta)
    }
}
