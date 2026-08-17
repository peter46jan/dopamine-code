import SwiftUI

/// De kleuren van het paneel, op één plek.
///
/// Het paneel schildert zijn eigen achtergrond — een donker paarsblauw verloop van rand tot
/// rand. Dat is geen versiering maar de kern van het ontwerp: een `MenuBarExtra` heeft een
/// egale systeemachtergrond, en glas over grijs is grijs. Er valt niets te breken. Met een
/// eigen verloop erachter heeft het glas eindelijk iets om zich van te onderscheiden.
///
/// De prijs staat hier ook: **licht en donker gaat eraan.** Eén vaste look, zoals CleanMyMac
/// dat doet. Dat betekent dat `Color.primary` en `Color.secondary` in dit paneel niet meer
/// bruikbaar zijn — in lichte systeemmodus zijn die zwart, en zwart op donkerpaars is niet te
/// lezen. Alles wat het paneel zelf tekent haalt zijn kleur hier vandaan.
///
/// Voor de onderdelen die het paneel *niet* zelf tekent — de segmentkiezer, de tijdkiezer, de
/// schakelaar, de knoppen — helpt geen palet: dat zijn AppKit-besturingselementen die hun
/// uiterlijk uit de omgeving halen. `MenuView` zet daarom `\.colorScheme` op `.dark` over het
/// hele paneel. Zie de opmerking daar.
enum Palet {

    // MARK: - De ondergrond

    /// Het verloop achter alles. Hex uit het ontwerp: #3B1E6E → #2A1652 → #1B1038.
    static let achtergrond = LinearGradient(
        stops: [
            .init(color: Color(red: 0.231, green: 0.118, blue: 0.431), location: 0.00),
            .init(color: Color(red: 0.165, green: 0.086, blue: 0.322), location: 0.42),
            .init(color: Color(red: 0.106, green: 0.063, blue: 0.220), location: 1.00),
        ],
        startPoint: UnitPoint(x: 0.12, y: 0),
        endPoint: UnitPoint(x: 0.88, y: 1))

    // MARK: - De inkt

    /// #EDEAF7 — gewone tekst.
    static let inkt = Color(red: 0.929, green: 0.918, blue: 0.969)
    /// Bijschrift: dezelfde inkt, gedempt.
    static let inktZacht = inkt.opacity(0.62)
    /// Labels en grenzen: nog zachter. Nooit voor iets dat je moet lezen om te handelen.
    static let inktFlauw = inkt.opacity(0.42)
    /// Koppen en aftelling — vol wit, want dat is wat het paneel eerst laat zien.
    static let inktFel = Color.white

    // MARK: - De accenten

    /// #C9A3FF — het paars van een lopende sessie: gevulde boog, meters, zon.
    static let accent = Color(red: 0.788, green: 0.639, blue: 1.000)
    /// #4ADE80 — de wachter klopt.
    static let leeft = Color(red: 0.290, green: 0.871, blue: 0.502)
    /// #FF6369 — de rode zone van een meter, en alles wat rood is.
    static let alarm = Color(red: 1.000, green: 0.388, blue: 0.412)
    /// #FFC48A — oranje: het werkt niet zoals bedoeld, maar er brandt niets.
    static let let_op = Color(red: 1.000, green: 0.769, blue: 0.541)

    // MARK: - De tegels

    /// De lege baan van een meter, en de rand van de boog.
    static let baan = Color.white.opacity(0.14)

    /// Bij welke ernst welke kleur. Eén plek, zodat de rangorde uit `Aandacht` en de kleur op
    /// het scherm niet uit elkaar kunnen lopen.
    static func kleur(_ ernst: Aandacht.Ernst) -> Color {
        switch ernst {
        case .rood:   return alarm
        case .oranje: return let_op
        case .grijs:  return inktZacht
        }
    }
}
