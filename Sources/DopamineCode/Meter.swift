import Foundation

/// Eén vangnet, als een paar: waar je nu bent, en waar het ingrijpt.
///
/// Dit staat los van de weergave omdat het het enige deel is dat fout kan zijn zónder dat je
/// het ziet. "15%" naast een Mac op 84% is niet fout in de code maar in de betekenis, en dat
/// verschil ligt hier vast: `percent` en `grens` zijn twee velden en worden nooit één.
struct AccuMeter {
    let percent: Int
    let grens: Int
    let aanDeLader: Bool

    /// Hoe vol de balk staat, 0…1. Geklemd, want dit getal komt van buiten.
    var vulling: Double { Double(min(max(percent, 0), 100)) / 100 }

    /// Waar de rode zone eindigt, 0…1. Begint altijd links bij nul.
    var zone: Double { Double(min(max(grens, 0), 100)) / 100 }

    /// Grijpt dit vangnet nu in?
    ///
    /// `<=` en niet `<`, en met `!aanDeLader` ervoor — precies de voorwaarde die `AppModel`
    /// zelf gebruikt (`battery.percent <= Prefs.batteryFloor` achter `!battery.onAC`). Wijkt
    /// deze regel daarvan af, dan tekent de meter iets anders dan er gebeurt, en dat is erger
    /// dan geen meter.
    var grijptIn: Bool { !aanDeLader && percent <= grens }

    /// Aan de lader kán dit vangnet niet afgaan. Dat is geen storing maar het hoort wel
    /// zichtbaar te zijn: een gedempte meter in plaats van een scherpe.
    var slaapt: Bool { aanDeLader }
}

/// De warmte, in vier stappen.
///
/// Vier en niet een percentage, omdat macOS geen graden geeft: `ProcessInfo.thermalState`
/// kent `nominal`, `fair`, `serious` en `critical` en verder niets. `pmset -g therm` zwijgt
/// zolang er geen druk is, `powermetrics` wil root, en de SMC-route is ongedocumenteerd en
/// per chip anders. De meter is daarom gestapeld: vier blokjes suggereren geen precisie die
/// er niet is.
struct WarmteMeter {
    let aantal = 4
    let stap: Int

    init(stap: Int) {
        // Klemmen en niet vertrouwen: een stap van 0 zou "alles in orde" tekenen bij een
        // waarde die we niet begrijpen, en dat is de verkeerde kant om op te falen.
        self.stap = min(max(stap, 1), 4)
    }

    /// Bij welke stap de sessie stopt. Altijd de laatste — dat is `.critical`.
    var stopBij: Int { aantal }

    var grijptIn: Bool { stap >= stopBij }

    func brandt(_ index: Int) -> Bool { index <= stap }
}
