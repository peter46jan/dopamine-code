import Foundation
import IOKit.ps

struct PowerSnapshot: Equatable {
    let percent: Int
    let onAC: Bool
    let charging: Bool
}

/// Battery level and AC state, straight from IOKit. No helper, no polling.
final class PowerSourceMonitor {

    private var runLoopSource: CFRunLoopSource?
    private let onChange: (PowerSnapshot) -> Void

    init(onChange: @escaping (PowerSnapshot) -> Void) {
        self.onChange = onChange
    }

    func start() {
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let source = IOPSNotificationCreateRunLoopSource({ ctx in
            guard let ctx else { return }
            let monitor = Unmanaged<PowerSourceMonitor>.fromOpaque(ctx).takeUnretainedValue()
            monitor.emit()
        }, context)?.takeRetainedValue() else {
            EventLog.shared.warn("Kon geen meldingen voor energiebron registreren.")
            return
        }
        runLoopSource = source
        // commonModes, not defaultMode: with defaultMode the battery floor stops being
        // watched the moment any modal panel or menu tracking loop is up.
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        emit()
    }

    func stop() {
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            runLoopSource = nil
        }
    }

    private func emit() {
        guard let snapshot = Self.read() else { return }
        DispatchQueue.main.async { [weak self] in
            self?.onChange(snapshot)
        }
    }

    /// Memory rule from the IOKit headers: `Copy…` returns retained, `Get…` unretained.
    /// Getting that backwards is a crash or a leak.
    static func read() -> PowerSnapshot? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef]
        else { return nil }

        for source in list {
            guard let desc = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue()
                    as? [String: Any] else { continue }
            guard (desc[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType else { continue }

            let current = desc[kIOPSCurrentCapacityKey] as? Int ?? 0
            let maximum = desc[kIOPSMaxCapacityKey] as? Int ?? 0
            guard maximum > 0 else { continue }
            let state = desc[kIOPSPowerSourceStateKey] as? String ?? ""

            return PowerSnapshot(
                percent: Int((Double(current) / Double(maximum) * 100).rounded()),
                onAC: state == kIOPSACPowerValue,
                charging: desc[kIOPSIsChargingKey] as? Bool ?? false
            )
        }
        return nil
    }
}
