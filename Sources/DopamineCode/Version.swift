import Foundation

/// Een versienummer, en de vergelijking ertussen.
///
/// Staat bewust los van `UpdateCheck` en heeft geen enkele afhankelijkheid buiten
/// Foundation. Twee redenen. De vergelijking is de enige plek in de updatecontrole waar
/// een denkfout stil verkeerd gedrag oplevert in plaats van een zichtbare storing — "1.9.0
/// is nieuwer dan 1.10.0" klopt als je strings vergelijkt en is onzin als je versies
/// bedoelt. En omdat dit bestand alleen staat, kan `verify.sh` er een probe tegenaan
/// compileren zonder AppKit, zonder bundel en zonder netwerk.
struct Version: Equatable, Comparable, CustomStringConvertible {

    /// Major, minor, patch. Ontbrekende delen zijn nul: `1.2` is `1.2.0`.
    let onderdelen: [Int]

    var description: String { onderdelen.map(String.init).joined(separator: ".") }

    /// Ontleedt `1.2.3`, `v1.2.3`, `1.2` of `1`.
    ///
    /// Streng met opzet. Dit ontleedt een string die van GitHub komt, en de rest van de app
    /// gaat ervan uit dat wat hier uitkomt een versie ís. Alles wat niet exact aan het
    /// patroon voldoet — een tag als `release-final`, een leeg veld, `1.2.3-beta`, een
    /// getal dat niet in een Int past — levert `nil` op in plaats van een gok. Een `nil`
    /// betekent verderop "onbekend", en bij onbekend beweert de app niets.
    init?(_ tekst: String) {
        var s = tekst.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("v") || s.hasPrefix("V") { s.removeFirst() }

        guard !s.isEmpty else { return nil }
        let stukken = s.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(stukken.count) else { return nil }

        var uit: [Int] = []
        for stuk in stukken {
            // `Int(...)` accepteert een voorloopteken, dus "1.-2.0" zou er anders doorheen
            // komen. Alleen cijfers, en niet meer dan er in een Int passen.
            guard !stuk.isEmpty, stuk.count <= 9, stuk.allSatisfy(\.isNumber),
                  let n = Int(stuk)
            else { return nil }
            uit.append(n)
        }
        while uit.count < 3 { uit.append(0) }
        onderdelen = uit
    }

    static func < (a: Version, b: Version) -> Bool {
        for (l, r) in zip(a.onderdelen, b.onderdelen) where l != r { return l < r }
        return false
    }
}
