import Foundation
import IOKit

/// Watches the lid sensor.
///
/// `NSWorkspace.willSleepNotification` is useless here by construction: with sleep
/// disabled there is no sleep transition to observe. `screensDidSleepNotification`
/// cannot tell a closed lid from an idle dim. `IOPMrootDomain` posts a general-interest
/// message on the actual hardware transition, regardless of whether sleep is disabled,
/// which is the only signal that means what we need it to mean.
final class ClamshellMonitor {

    /// kIOPMMessageClamshellStateChange, from IOPM.h.
    private static let clamshellStateChange: UInt32 = 0xe003_4100
    private static let clamshellStateBit: UInt = 1 << 0
    private static let clamshellSleepBit: UInt = 1 << 1

    private var notificationPort: IONotificationPortRef?
    private var notifier: io_object_t = 0
    private var service: io_service_t = 0
    private var pollTimer: Timer?

    private let onChange: (Bool) -> Void
    private(set) var isClosed: Bool = false

    init(onChange: @escaping (Bool) -> Void) {
        self.onChange = onChange
    }

    func start() {
        isClosed = SleepFlag.clamshellClosed() ?? false

        service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != 0 else {
            EventLog.shared.warn("IOPMrootDomain niet gevonden; klepdetectie valt terug op pollen.")
            startPolling()
            return
        }

        guard let port = IONotificationPortCreate(kIOMainPortDefault) else {
            EventLog.shared.warn("Kon geen notificatiepoort maken; klepdetectie valt terug op pollen.")
            startPolling()
            return
        }
        notificationPort = port
        // commonModes so lid events keep arriving while a menu or panel is up.
        CFRunLoopAddSource(
            CFRunLoopGetMain(),
            IONotificationPortGetRunLoopSource(port).takeUnretainedValue(),
            .commonModes
        )

        let context = Unmanaged.passUnretained(self).toOpaque()
        let callback: IOServiceInterestCallback = { ctx, _, messageType, messageArgument in
            guard let ctx, messageType == ClamshellMonitor.clamshellStateChange else { return }
            let monitor = Unmanaged<ClamshellMonitor>.fromOpaque(ctx).takeUnretainedValue()
            let bits = UInt(bitPattern: messageArgument)
            monitor.handle(
                closed: bits & ClamshellMonitor.clamshellStateBit != 0,
                wouldSleep: bits & ClamshellMonitor.clamshellSleepBit != 0
            )
        }

        let kr = IOServiceAddInterestNotification(
            port, service, kIOGeneralInterest, callback, context, &notifier
        )
        if kr != KERN_SUCCESS {
            EventLog.shared.warn("IOServiceAddInterestNotification gaf \(kr); klepdetectie valt terug op pollen.")
            startPolling()
            return
        }

        // The interest notification is the real mechanism, but it has never been
        // observed to fire on this hardware under a disabled-sleep flag, so a slow poll
        // runs alongside it as a safety net. Whichever notices first wins; handle() is
        // idempotent.
        startPolling(interval: 10)
    }

    private func startPolling(interval: TimeInterval = 3) {
        pollTimer?.invalidate()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            guard let self, let closed = SleepFlag.clamshellClosed() else { return }
            self.handle(closed: closed, wouldSleep: nil)
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    private func handle(closed: Bool, wouldSleep: Bool?) {
        DispatchQueue.main.async { [weak self] in
            guard let self, closed != self.isClosed else { return }
            self.isClosed = closed
            var message = closed ? "Klep dicht." : "Klep open."
            if let wouldSleep {
                message += wouldSleep
                    ? " Kernel meldt dat de klep slaap zou veroorzaken."
                    : " Kernel meldt dat de klep géén slaap veroorzaakt."
            }
            EventLog.shared.info(message)
            self.onChange(closed)
        }
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
        if notifier != 0 { IOObjectRelease(notifier); notifier = 0 }
        if service != 0 { IOObjectRelease(service); service = 0 }
        if let port = notificationPort {
            CFRunLoopRemoveSource(
                CFRunLoopGetMain(),
                IONotificationPortGetRunLoopSource(port).takeUnretainedValue(),
                .commonModes
            )
            IONotificationPortDestroy(port)
            notificationPort = nil
        }
    }

    deinit { stop() }
}
