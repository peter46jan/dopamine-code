import AppKit
import Foundation
import ServiceManagement

/// Start at login, via `SMAppService` with a plain LaunchAgent as fallback.
///
/// `SMAppService` evaluates the app's code signature. A properly signed bundle registers
/// cleanly; anything it rejects falls through to `~/Library/LaunchAgents`, which is
/// verified to work on macOS 26 even for ad-hoc-signed executables and still shows up in
/// System Settings → General → Login Items.
enum LaunchAtLogin {

    private static let agentLabel = "com.peter46jan.dopaminecode.agent"

    private static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(agentLabel).plist")
    }

    enum Mechanism: String {
        case serviceManagement = "SMAppService"
        case launchAgent = "LaunchAgent"
        case none = "geen"
    }

    /// What is actually in effect right now, read from the system rather than from a
    /// preference we wrote earlier.
    static func currentMechanism() -> Mechanism {
        // requiresApproval means "registered, waiting for the user" — enabled-pending, not
        // off. Reporting it as off made Settings show the toggle unticked and then
        // unregister the item the moment the window opened.
        let status = SMAppService.mainApp.status
        if status == .enabled || status == .requiresApproval { return .serviceManagement }
        if FileManager.default.fileExists(atPath: plistURL.path) { return .launchAgent }
        return .none
    }

    static var isEnabled: Bool { currentMechanism() != .none }

    /// True when macOS accepted the registration but the user still has to flip it on
    /// in System Settings.
    static var requiresApproval: Bool { SMAppService.mainApp.status == .requiresApproval }

    /// Error codes from `SMAppService.h`. Not every failure means "try something else":
    /// two of them mean the opposite.
    private enum SMError {
        static let alreadyRegistered = 134  // kSMErrorAlreadyRegistered
        static let launchDeniedByUser = 137 // kSMErrorLaunchDeniedByUser
        static let invalidSignature = 138   // kSMErrorInvalidSignature
    }

    @discardableResult
    static func enable() -> Result<Mechanism, Error> {
        do {
            try SMAppService.mainApp.register()
            let status = SMAppService.mainApp.status
            EventLog.shared.info("SMAppService geregistreerd, status \(status.rawValue).")
            if status == .enabled || status == .requiresApproval {
                return .success(.serviceManagement)
            }
            EventLog.shared.warn("SMAppService status \(status.rawValue) na registratie; val terug op LaunchAgent.")
        } catch {
            let ns = error as NSError
            switch ns.code {
            case SMError.alreadyRegistered:
                // Not a failure. Writing a LaunchAgent on top of this would start the app
                // twice at every login.
                EventLog.shared.info("SMAppService was al geregistreerd.")
                return .success(.serviceManagement)
            case SMError.launchDeniedByUser:
                // The user switched it off in System Settings. Routing around that with a
                // raw LaunchAgent would be overriding an explicit refusal.
                EventLog.shared.warn("Start bij inloggen is door de gebruiker geweigerd in Systeeminstellingen.")
                return .failure(NSError(domain: "Dopamine Code", code: ns.code, userInfo: [
                    NSLocalizedDescriptionKey:
                        "Je hebt Dopamine Code uitgezet bij Systeeminstellingen → Algemeen → Inloggen. Zet hem daar weer aan."
                ]))
            case SMError.invalidSignature:
                EventLog.shared.warn("SMAppService weigert de handtekening; val terug op LaunchAgent.")
            default:
                EventLog.shared.warn("SMAppService.register mislukte (\(ns.domain) \(ns.code)); val terug op LaunchAgent.")
            }
        }

        do {
            try installLaunchAgent()
            EventLog.shared.info("LaunchAgent geïnstalleerd op \(plistURL.path).")
            return .success(.launchAgent)
        } catch {
            EventLog.shared.error("LaunchAgent installeren mislukt: \(error.localizedDescription)")
            return .failure(error)
        }
    }

    static func disable() {
        try? SMAppService.mainApp.unregister()
        guard FileManager.default.fileExists(atPath: plistURL.path) else {
            EventLog.shared.info("Start bij inloggen uitgeschakeld.")
            return
        }

        // Removing the plist is safe; booting the label out is not. If this process WAS
        // started by that agent, launchctl sends it a SIGTERM — which lands in the
        // flag-clearing signal handler and takes the app down in the middle of a running
        // session, just because the user unticked a checkbox.
        try? FileManager.default.removeItem(at: plistURL)

        if startedByLaunchAgent {
            EventLog.shared.info("Start bij inloggen uitgeschakeld; de LaunchAgent is verwijderd "
                                 + "maar niet uitgeladen, omdat dit proces er zelf door gestart is.")
        } else {
            Shell.run("/bin/launchctl", ["bootout", "gui/\(getuid())/\(agentLabel)"])
            EventLog.shared.info("Start bij inloggen uitgeschakeld.")
        }
    }

    /// Whether this process was launched by our own LaunchAgent. `launchctl` sets
    /// XPC_SERVICE_NAME to the job label for jobs it starts.
    private static var startedByLaunchAgent: Bool {
        ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"]?.contains(agentLabel) == true
    }

    private static func installLaunchAgent() throws {
        guard let executable = Bundle.main.infoDictionary?["CFBundleExecutable"] as? String else {
            throw NSError(domain: "Dopamine Code", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "CFBundleExecutable ontbreekt"])
        }
        let binary = Bundle.main.bundleURL
            .appendingPathComponent("Contents/MacOS/\(executable)").path

        let plist: [String: Any] = [
            "Label": agentLabel,
            "ProgramArguments": [binary],
            "RunAtLoad": true,
            // A menu bar app the user quit on purpose should stay quit.
            "KeepAlive": false,
            "ProcessType": "Interactive",
            "LimitLoadToSessionType": "Aqua",
        ]

        try FileManager.default.createDirectory(
            at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: plistURL, options: .atomic)

        // Re-bootstrapping an already-loaded label is a documented source of
        // "Operation not permitted", so bootout first — unless this very process was
        // started by that label, in which case launchctl would SIGTERM us mid-session
        // just because the user ticked a checkbox.
        if !startedByLaunchAgent {
            Shell.run("/bin/launchctl", ["bootout", "gui/\(getuid())/\(agentLabel)"])
        }
        let result = Shell.run("/bin/launchctl", ["bootstrap", "gui/\(getuid())", plistURL.path])
        guard result.ok else {
            throw NSError(domain: "Dopamine Code", code: Int(result.status),
                          userInfo: [NSLocalizedDescriptionKey: "launchctl bootstrap: \(result.combined)"])
        }
    }

    static func openLoginItemsSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }
}
