import Foundation

/// Vertaalde teksten opzoeken vanuit gewone Swift-code.
///
/// SwiftUI heeft dit niet nodig: `Text("menu.bijwerken.titel")` is een `LocalizedStringKey`
/// en zoekt zichzelf op. Maar alles wat een gewone `String` moet opleveren — `lastMessage`,
/// meldingtitels, waarden die in een `String(format:)` gaan — komt hier langs.
///
/// De sleutels zijn symbolisch en niet de Nederlandse zin zelf. Dat is een bewuste keuze met
/// een prijs: je ziet de tekst niet meer in de code staan. Wat het oplevert is dat het
/// bijschaven van een zin geen enkele vertaling raakt. Met de zin als sleutel zou één
/// verbeterde komma stilletjes drie talen laten terugvallen op het Nederlands, zonder
/// foutmelding en zonder dat iemand het merkt tot een Franse gebruiker het meldt.
///
/// Ontbreekt een sleutel, dan toont macOS de sleutel zelf. Lelijk, maar onmiddellijk
/// zichtbaar — en `verify.sh` vergelijkt de vier bestanden zodat het niet zover komt.
enum L10n {

    /// Een tekst zonder invulwaarden.
    static func t(_ key: String) -> String {
        NSLocalizedString(key, comment: "")
    }

    /// Een tekst met invulwaarden, in de volgorde van de opmaakaanduidingen.
    ///
    /// Let op de volgorde: die verschilt per taal. Een Duitse zin kan de waarden omdraaien
    /// ten opzichte van de Nederlandse. Gebruik daarom in de vertalingen genummerde
    /// aanduidingen (`%1$@`, `%2$@`) zodra er meer dan één waarde in een zin staat, want
    /// dan mag de vertaler ze verplaatsen zonder de betekenis om te gooien.
    static func t(_ key: String, _ args: CVarArg...) -> String {
        String(format: NSLocalizedString(key, comment: ""), arguments: args)
    }
}
