import Foundation
import Network

/// A recorded loss of connectivity during an active session.
struct Outage: Identifiable, Equatable {
    let id = UUID()
    let began: Date
    var ended: Date?
    var reason: String

    var duration: TimeInterval { (ended ?? Date()).timeIntervalSince(began) }
    var isOngoing: Bool { ended == nil }

    /// "internet was 12 minuten weg om 03:41"
    ///
    /// Vertaald, en dat was het niet. Deze zin werd hard in het Nederlands opgebouwd en kwam
    /// zo ook in een Engels, Duits of Frans paneel te staan: "internet was 1 seconden weg om
    /// 16:47" onder de kop NEEDS ATTENTION. Twee fouten in één regel, want dat enkelvoud
    /// klopte ook niet.
    ///
    /// Enkelvoud en meervoud zijn aparte sleutels. In het Nederlands is "1 seconde" een ander
    /// woord dan "2 seconden", en in de andere drie talen net zo goed; één sleutel met %d
    /// levert daar "1 seconds" op.
    func describe() -> String {
        let clock = DateFormatter()
        clock.dateFormat = "HH:mm"
        let tijdstip = clock.string(from: began)
        let minutes = Int((duration / 60).rounded())
        // Elke sleutel staat pal achter `L10n.t(` en niet achter een vraagteken. Dat is geen
        // stijl maar noodzaak: `verify.sh --talen` zoekt naar dat patroon om te controleren of
        // elke gebruikte sleutel bestaat, en een sleutel in een ternaire operator ziet hij niet
        // staan. Zo geschreven telt hij mee, en vangt hij een typefout.
        if isOngoing {
            if minutes < 1 { return L10n.t("storing.nogsteeds", tijdstip) }
            if minutes == 1 { return L10n.t("storing.al.min.een", minutes, tijdstip) }
            return L10n.t("storing.al.min.meer", minutes, tijdstip)
        }
        if minutes < 1 {
            let seconds = Int(duration.rounded())
            if seconds == 1 { return L10n.t("storing.was.sec.een", seconds, tijdstip) }
            return L10n.t("storing.was.sec.meer", seconds, tijdstip)
        }
        if minutes == 1 { return L10n.t("storing.was.min.een", minutes, tijdstip) }
        return L10n.t("storing.was.min.meer", minutes, tijdstip)
    }
}

/// Watches network reachability for the duration of a keep-awake session.
///
/// `.satisfied` means a viable path exists, not that the internet is reachable — behind
/// a captive portal it stays satisfied with no route out. So a satisfied path is
/// confirmed with a real request to Apple's own captive-portal endpoint before the
/// connection is called healthy.
///
/// One instance per session. `NWPathMonitor` cannot be restarted after `cancel()` — a
/// reused instance silently stops delivering path updates — so `AppModel` creates a fresh
/// monitor each time a session begins rather than keeping one around.
final class NetworkMonitor {

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.peter46jan.dopaminecode.network")
    private var probeTimer: Timer?
    private var started = false
    private var cancelled = false
    /// One failed captive-portal probe is not an outage. A hiccup at 4am should not ring
    /// an alarm and fabricate a two-minute gap in the log.
    private var consecutiveProbeFailures = 0

    private(set) var outages: [Outage] = []
    private(set) var isOnline = true

    /// Called on the main queue whenever connectivity flips.
    var onStateChange: ((Bool, Outage?) -> Void)?

    func start() {
        guard !started, !cancelled else { return }
        started = true
        outages.removeAll()
        isOnline = true
        consecutiveProbeFailures = 0

        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let reason = Self.describe(path)
            let reachable = path.status == .satisfied
            DispatchQueue.main.async {
                // `NWPathMonitor` delivers on its own queue, so this block can already be
                // in flight when `stop()` runs on the main thread — and it would then open
                // an outage on a dead monitor and pin the menu to "geen verbinding" for a
                // session that no longer exists. The probe path has always had this guard;
                // the path handler did not.
                guard self.started else { return }
                self.update(reachable: reachable, reason: reason)
            }
        }
        monitor.start(queue: queue)

        // A satisfied path can still be a dead end. Probe periodically while a session is
        // running, backed well off so this never becomes a beacon.
        let timer = Timer(timeInterval: 120, repeats: true) { [weak self] _ in
            self?.probeInternet()
        }
        RunLoop.main.add(timer, forMode: .common)
        probeTimer = timer
    }

    func stop() {
        guard started else { return }
        started = false
        cancelled = true
        monitor.pathUpdateHandler = nil
        monitor.cancel()
        probeTimer?.invalidate()
        probeTimer = nil
        // Close an outage that was still running when the session ended.
        if var last = outages.last, last.isOngoing {
            last.ended = Date()
            outages[outages.count - 1] = last
        }
    }

    private static func describe(_ path: NWPath) -> String {
        switch path.status {
        case .satisfied:
            if path.usesInterfaceType(.wifi) { return "wifi" }
            if path.usesInterfaceType(.wiredEthernet) { return "ethernet" }
            return "verbonden"
        case .unsatisfied:
            switch path.unsatisfiedReason {
            case .wifiDenied: return "wifi staat uit"
            case .cellularDenied: return "mobiele verbinding geblokkeerd"
            case .localNetworkDenied: return "lokaal netwerk geblokkeerd"
            case .notAvailable: return "geen netwerk beschikbaar"
            default: return "geen verbinding"
            }
        case .requiresConnection:
            return "verbinding moet nog opgebouwd worden"
        @unknown default:
            return "netwerkstatus onbekend"
        }
    }

    private func update(reachable: Bool, reason: String) {
        // Belt as well as braces: every caller is a queue hop away from `stop()`.
        guard started else { return }
        guard reachable != isOnline else { return }
        isOnline = reachable

        if reachable {
            if var last = outages.last, last.isOngoing {
                last.ended = Date()
                outages[outages.count - 1] = last
                EventLog.shared.info("Netwerk terug — \(last.describe()).")
                onStateChange?(true, last)
                return
            }
            EventLog.shared.info("Netwerk beschikbaar (\(reason)).")
            onStateChange?(true, nil)
        } else {
            let outage = Outage(began: Date(), ended: nil, reason: reason)
            outages.append(outage)
            EventLog.shared.warn("Netwerk weg (\(reason)).")
            onStateChange?(false, outage)
        }
    }

    /// Confirms real internet access. Apple's own captive-portal endpoint returns the
    /// literal body "Success"; a portal returns a login page instead.
    func probeInternet() {
        guard started else { return }
        var request = URLRequest(url: URL(string: "http://captive.apple.com/hotspot-detect.html")!)
        request.timeoutInterval = 10
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData

        URLSession.shared.dataTask(with: request) { [weak self] data, response, _ in
            guard let self else { return }
            let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let http = response as? HTTPURLResponse
            let healthy = http?.statusCode == 200 && body.contains("Success")

            DispatchQueue.main.async {
                guard self.started else { return }
                if healthy {
                    self.consecutiveProbeFailures = 0
                    self.update(reachable: true, reason: "internet bevestigd")
                    return
                }
                self.consecutiveProbeFailures += 1
                // One failed probe is not an outage — a single timeout is far more likely
                // to be a hiccup, and this runs unattended for hours. But waiting the full
                // two minutes for the next scheduled probe would hide a real loss for that
                // long, so confirm quickly instead.
                guard self.consecutiveProbeFailures >= 2 else {
                    EventLog.shared.info("Internetcontrole mislukte eenmalig; controle over 20 seconden.")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
                        self?.probeInternet()
                    }
                    return
                }
                self.update(reachable: false, reason: "wel netwerk, geen internet")
            }
        }.resume()
    }

    /// Outages worth reporting when the lid opens again.
    var summary: String? {
        let finished = outages.filter { !$0.isOngoing || $0.duration > 5 }
        guard !finished.isEmpty else { return nil }
        if finished.count == 1 { return finished[0].describe() }
        let total = Int((finished.reduce(0) { $0 + $1.duration } / 60).rounded())
        return "\(finished.count) keer geen internet, samen ongeveer \(total) minuten. De eerste keer: \(finished[0].describe())."
    }
}
