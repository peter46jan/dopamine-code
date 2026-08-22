import Foundation

/// Graden, en in welke eenheid ze op het scherm komen.
///
/// Los bestand zonder afhankelijkheden, zodat `verify.sh --paneel` het kan compileren en
/// natrekken. Het uitlezen zelf staat in `Warmtesensor`; dat raakt een privé-API en is niet
/// te testen. Wat hier staat is het deel dat fout kan zijn zonder dat je het ziet: een
/// omrekening die er net naast zit ziet niemand aan het getal.
enum Temperatuur {

    enum Eenheid: String, CaseIterable {
        /// Volg wat macOS doet. Dit is de standaard.
        case systeem
        case celsius
        case fahrenheit
    }

    /// Welke eenheid er werkelijk geldt.
    ///
    /// `systeemGebruiktFahrenheit` komt van buiten zodat deze beslissing te testen is zonder
    /// een Mac met een Amerikaanse regio-instelling.
    static func geldend(voorkeur: Eenheid, systeemGebruiktFahrenheit: Bool) -> Eenheid {
        switch voorkeur {
        case .celsius:    return .celsius
        case .fahrenheit: return .fahrenheit
        case .systeem:    return systeemGebruiktFahrenheit ? .fahrenheit : .celsius
        }
    }

    /// Wat macOS zelf doet: eerst de expliciete voorkeur, anders de regio.
    ///
    /// `AppleTemperatureUnit` staat alleen in NSGlobalDomain als iemand hem ooit heeft gezet.
    /// Staat hij er niet, dan volgt macOS de regio, en alleen het Amerikaanse maatsysteem
    /// gebruikt Fahrenheit.
    static var systeemGebruiktFahrenheit: Bool {
        if let gezet = UserDefaults.standard.string(forKey: "AppleTemperatureUnit") {
            return gezet == "Fahrenheit"
        }
        if #available(macOS 13.0, *) {
            return Locale.current.measurementSystem == .us
        }
        return false
    }

    /// Celsius naar Fahrenheit. Eén regel, en juist daarom hier: een omgekeerde formule ziet
    /// er net zo geloofwaardig uit op het scherm.
    static func naarFahrenheit(_ celsius: Double) -> Double { celsius * 9 / 5 + 32 }

    /// "52 °C" of "125 °F".
    ///
    /// Hele graden. De sensoren geven tienden, maar die dansen van seconde tot seconde en dit
    /// is een tegel die je een halve seconde bekijkt — een cijfer achter de komma dat blijft
    /// wisselen leest als onrust, niet als precisie.
    ///
    /// Een spatie tussen getal en teken, want dat is de schrijfwijze in het SI en in alle vier
    /// de talen van deze app.
    static func tekst(_ celsius: Double, in eenheid: Eenheid,
                      systeemGebruiktFahrenheit: Bool = false) -> String {
        let echte = geldend(voorkeur: eenheid, systeemGebruiktFahrenheit: systeemGebruiktFahrenheit)
        switch echte {
        case .fahrenheit:
            return "\(Int(naarFahrenheit(celsius).rounded())) °F"
        case .celsius, .systeem:
            return "\(Int(celsius.rounded())) °C"
        }
    }
}
