import Foundation

/// Watches thermal pressure while a keep-awake session is running.
///
/// This is not a nice-to-have. Setting `SleepDisabled` routes to `userDisabledAllSleep`
/// in `IOPMrootDomain`, which gates `checkSystemSleepAllowed()` — the same check that
/// the kernel's **thermal-emergency** and **low-battery** sleep paths go through. So the
/// flag does not only stop the lid from putting the Mac to sleep; it also switches off
/// the kernel's own last-resort protection against cooking itself.
///
/// The battery half of that is covered by the battery floor. This is the thermal half.
/// It is the software replacement for a safety net the flag removed.
final class ThermalWatch {

    enum Pressure {
        case nominal
        case fair
        case serious
        case critical

        init(_ state: ProcessInfo.ThermalState) {
            switch state {
            case .nominal: self = .nominal
            case .fair: self = .fair
            case .serious: self = .serious
            case .critical: self = .critical
            @unknown default: self = .serious
            }
        }

        var label: String {
            switch self {
            case .nominal: return "normaal"
            case .fair: return "licht verhoogd"
            case .serious: return "hoog"
            case .critical: return "kritiek"
            }
        }
    }

    private var pollTimer: Timer?
    private var observer: NSObjectProtocol?
    private let onChange: (Pressure) -> Void
    private(set) var pressure: Pressure = .nominal

    init(onChange: @escaping (Pressure) -> Void) {
        self.onChange = onChange
    }

    func start() {
        // Idempotent: `start()` runs on every activation, and without this a second one
        // would stack another observer and another timer on top of the first.
        stop()
        pressure = Pressure(ProcessInfo.processInfo.thermalState)

        observer = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.sample()
        }

        // The notification is the real mechanism; the poll is there because a missed
        // notification during a multi-hour lid-closed run would defeat the whole point.
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            self?.sample()
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
        if let observer {
            NotificationCenter.default.removeObserver(observer)
            self.observer = nil
        }
        pressure = .nominal
    }

    private func sample() {
        let next = Pressure(ProcessInfo.processInfo.thermalState)
        guard next != pressure else { return }
        pressure = next
        EventLog.shared.log(
            next == .critical ? .error : (next == .serious ? .warn : .info),
            "Thermische druk: \(next.label)."
        )
        onChange(next)
    }

    /// Secondary signal: whether the scheduler is currently limiting CPU speed. Useful in
    /// the log after the fact, to tell "it got warm" from "it was throttled for an hour".
    ///
    /// Async on purpose. Both callers are on the main actor, and this is read at exactly
    /// the moment the machine is throttled and slowest — blocking the main queue there
    /// would stall the guardian, the lid handling and the signal handler for up to eight
    /// seconds, which is the worst possible time to lose all three.
    static func cpuSpeedLimit() async -> Int? {
        parseSpeedLimit(await Shell.runAsync("/usr/bin/pmset", ["-g", "therm"], timeout: 8))
    }

    private static func parseSpeedLimit(_ result: ShellResult) -> Int? {
        guard result.ok else { return nil }
        for line in result.stdout.split(separator: "\n") where line.contains("CPU_Speed_Limit") {
            if let value = line.split(separator: "=").last?.trimmingCharacters(in: .whitespaces) {
                return Int(value)
            }
        }
        return nil
    }
}

extension ThermalWatch.Pressure: Equatable {}
