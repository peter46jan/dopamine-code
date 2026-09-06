import Foundation
import IOKit.pwr_mgt

/// Houdt het scherm aan zolang er een sessie loopt.
///
/// Dit is iets anders dan wat de rest van de app doet, en dat verschil is de hele reden dat dit
/// bestaat. `SleepDisabled` houdt het **systeem** wakker; het scherm dimt en gaat uit op het
/// eigen schema van macOS, en daarna vergrendelt hij. Op de opdrachtregel is dat het verschil
/// tussen `caffeinate -i` en `caffeinate -d`.
///
/// De keuzes "Vergrendelen" en "Scherm uit" in de instellingen gaan alleen over wat de app zélf
/// doet en wanneer. Op "nooit" bemoeit de app zich er niet mee — maar dan doet macOS het nog
/// steeds. Er was niets dat het scherm aan hield, en dat is wat dit toevoegt.
///
/// Openbare API, geen `dlsym`: `IOPMAssertionCreateWithName` staat gewoon in IOKit. Het is
/// dezelfde verklaring die een videospeler aanhoudt zolang hij afspeelt.
///
/// Let op wat dit **niet** is: geen vangnet en geen sessie. De accugrens, de warmtebewaking en
/// de wachter merken er niets van. Wel wordt de accu sneller leeg met een scherm dat aanblijft,
/// dus de accugrens komt eerder in beeld — en die blijft gewoon werken.
final class SchermWakker {

    static let shared = SchermWakker()

    private var verklaring: IOPMAssertionID = IOPMAssertionID(0)
    private(set) var actief = false

    private init() {}

    /// Zet de verklaring aan of uit. Idempotent: twee keer aanzetten is één verklaring.
    func stel(aan: Bool) {
        if aan { begin() } else { stop() }
    }

    private func begin() {
        guard !actief else { return }
        // `PreventUserIdleDisplaySleep` en niet `NoIdleSleep`: dat tweede houdt alleen het
        // systeem wakker, en dat doet de kernelvlag al. Dit gaat over het scherm.
        //
        // De naam komt in `pmset -g assertions` te staan. Dat is de plek waar iemand kijkt die
        // zich afvraagt waarom zijn scherm aanblijft, dus hij moet uitleggen wie het doet.
        let reden = "Dopamine Code houdt het scherm aan tijdens een sessie" as CFString
        let uitkomst = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reden,
            &verklaring)
        if uitkomst == kIOReturnSuccess {
            actief = true
            EventLog.shared.info("Scherm wordt aangehouden (IOPMAssertion).")
        } else {
            // Stil falen zou hier verkeerd zijn: de gebruiker heeft er om gevraagd en zou
            // anders denken dat het aanstaat terwijl zijn scherm straks toch uitgaat.
            EventLog.shared.warn("Scherm aanhouden lukte niet (IOPMAssertion gaf \(uitkomst)).")
        }
    }

    private func stop() {
        guard actief else { return }
        IOPMAssertionRelease(verklaring)
        verklaring = IOPMAssertionID(0)
        actief = false
        EventLog.shared.info("Scherm wordt niet meer aangehouden.")
    }
}
