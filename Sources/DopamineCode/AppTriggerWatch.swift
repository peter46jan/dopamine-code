import AppKit

/// Merkt op dat een gekozen app begint of stopt met draaien — meer niet.
///
/// Dit bestand houdt met opzet **geen enkele sessiestand** bij, en het heeft geen enkele
/// verwijzing naar `AppModel`. Het voor de hand liggende ontwerp — een bewaker die bij een
/// app-start zelf aanzet — is precies de tweede waarheid waar de guardian uit voortkomt:
/// dan beslist iets anders dan de guardian wanneer de blokkade aan mag, en die beslissing
/// kijkt naar de app in plaats van naar de kernel. Wat hier gebeurt is: de melding stoot de
/// guardian aan, en de guardian vraagt terug wat er nú draait.
///
/// **Er zit daarom geen Timer in.** Dat is geen bezuiniging maar de constructie zelf: de
/// guardian-tik van 20 seconden ís de poll, want die vraagt bij elke tik opnieuw aan
/// `NSWorkspace` wat er draait. De meldingen van `NSWorkspace` zijn alleen de snelheid — net
/// als bij `ProcessWatch.ExitWatcher`, en om dezelfde reden. Blijven ze uit, dan gaat er
/// niets stuk; het duurt hooguit één tik langer, en `draaiendeApps(_:)` zegt het in het
/// logboek zodra hij iets ziet dat de melding niet gemeld heeft.
///
/// **Stoppen gaat hier niet langs.** Een sessie die op een app hangt, hangt aan de pid van
/// die app via de proceskoppeling uit fase 1 — dus een app die afgesloten wordt eindigt de
/// sessie via dezelfde clausule in `releaseReason()` als `dopamine on --until-exit`, en niet
/// via een tweede route hiernaast. Dat is met opzet: twee stoproutes betekent twee plekken
/// waar de tijdslimiet, de accugrens of de warmtegrens overgeslagen kan worden.
final class AppTriggerWatch {

    /// Wat er van een draaiende app te weten valt voor een trigger.
    struct Draaiend: Equatable {
        let bundleID: String
        let naam: String
        let pid: pid_t
    }

    private let onChange: () -> Void
    private var observers: [NSObjectProtocol] = []

    /// Wat de meldingen van `NSWorkspace` beweren dat er draait. Alleen om te kunnen
    /// betrappen dat die meldingen iets gemist hebben — dit gaat over `NSWorkspace`, niet
    /// over ons.
    private var gemeldDraaiend: Set<String> = []
    /// Voor welke bundle-id's er al eens gekeken is. De állereerste waarneming verschilt per
    /// definitie van wat de meldingen zeiden (er is er nog geen langsgekomen), en dat is geen
    /// gemiste melding.
    private var eerderGezien: Set<String> = []
    /// Zodat de klacht hierover één keer per verandering komt en niet elke twintig seconden.
    private var geklaagdOver: Set<String> = []

    init(onChange: @escaping () -> Void) {
        self.onChange = onChange
    }

    func start() {
        let centrum = NSWorkspace.shared.notificationCenter
        for naam in [NSWorkspace.didLaunchApplicationNotification,
                     NSWorkspace.didTerminateApplicationNotification] {
            let starten = (naam == NSWorkspace.didLaunchApplicationNotification)
            let observer = centrum.addObserver(forName: naam, object: nil, queue: .main) { [weak self] melding in
                guard let self else { return }
                let app = melding.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                if let bundleID = app?.bundleIdentifier {
                    if starten {
                        self.gemeldDraaiend.insert(bundleID)
                        self.geklaagdOver.remove(bundleID)
                    } else {
                        self.gemeldDraaiend.remove(bundleID)
                    }
                }
                // Het enige wat deze melding doet. Of er iets moet gebeuren beslist de
                // guardian, en die kijkt naar de kernelvlag — niet naar deze melding.
                self.onChange()
            }
            observers.append(observer)
        }
    }

    func stop() {
        let centrum = NSWorkspace.shared.notificationCenter
        for observer in observers { centrum.removeObserver(observer) }
        observers.removeAll()
    }

    deinit { stop() }

    /// Welke van de gekozen apps er op dit moment draaien. Vers uitgelezen, elke keer.
    ///
    /// Draait er meer dan één exemplaar van dezelfde app, dan wint het oudste: dat is degene
    /// waar "zolang hij draait" over gaat, en een tweede exemplaar dat een seconde later weer
    /// weg is mag geen sessie in gang zetten die aan dat exemplaar hangt.
    func draaiendeApps(_ bundleIDs: Set<String>) -> [String: Draaiend] {
        var resultaat: [String: Draaiend] = [:]
        for bundleID in bundleIDs {
            let exemplaren = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
                .filter { !$0.isTerminated && $0.processIdentifier > 0
                    // Onszelf niet, ook niet als iemand de instelling met de hand bewerkt
                    // heeft: een sessie die eindigt zodra Dopamine Code klaar is, is geen
                    // sessie — bij het afsluiten wordt de blokkade toch al teruggezet.
                    && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
                .sorted { ($0.launchDate ?? .distantFuture) < ($1.launchDate ?? .distantFuture) }
            guard let app = exemplaren.first else { continue }
            resultaat[bundleID] = Draaiend(
                bundleID: bundleID,
                naam: app.localizedName ?? bundleID,
                pid: app.processIdentifier
            )
        }
        meldGemisteMeldingen(gezien: Set(resultaat.keys), gevraagd: bundleIDs)
        return resultaat
    }

    /// Stille degradatie van de snelle route is nog steeds degradatie.
    ///
    /// Merkt de guardian-tik een verandering die de melding nooit doorgaf, dan werkt die
    /// melding op deze machine niet zoals verwacht. Er gaat niets kapot — de tik geeft het
    /// antwoord toch al — maar het hoort opgeschreven te worden, want anders lijkt het jaren
    /// later of alles in orde was.
    private func meldGemisteMeldingen(gezien: Set<String>, gevraagd: Set<String>) {
        for bundleID in gevraagd {
            let draait = gezien.contains(bundleID)
            let eerder = eerderGezien.contains(bundleID)
            eerderGezien.insert(bundleID)

            guard draait != gemeldDraaiend.contains(bundleID) else {
                geklaagdOver.remove(bundleID)
                continue
            }
            if draait { gemeldDraaiend.insert(bundleID) } else { gemeldDraaiend.remove(bundleID) }

            // De eerste waarneming, en herhalingen van dezelfde klacht, blijven stil.
            guard eerder, !geklaagdOver.contains(bundleID) else { continue }
            geklaagdOver.insert(bundleID)
            EventLog.shared.warn(
                "De melding van macOS gaf niet door dat \(bundleID) "
                + (draait ? "gestart" : "gestopt") + " is; pas de guardian-tik zag het. "
                + "De trigger werkt, maar reageert trager."
            )
        }
        // Bundle-id's die niet meer gevraagd worden vergeten, zodat ze bij opnieuw kiezen
        // weer als een eerste waarneming tellen in plaats van als een gemiste melding.
        eerderGezien.formIntersection(gevraagd)
        gemeldDraaiend.formIntersection(gevraagd)
        geklaagdOver.formIntersection(gevraagd)
    }
}
