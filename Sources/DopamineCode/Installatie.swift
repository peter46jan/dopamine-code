import Foundation

/// Hoe deze app geïnstalleerd is, en wat je dus moet draaien om hem bij te werken.
///
/// De app werkt zichzelf met opzet niet bij: hij downloadt en installeert nooit iets. Een app
/// die zichzelf kan vervangen terwijl er een sudoers-regel op zijn naam staat is een veel
/// groter doelwit — dan is de vraag niet meer "vertrouw ik deze code" maar "vertrouw ik elke
/// toekomstige versie die deze app zichzelf toestuurt".
///
/// Wat hij wél kan is het júiste commando tonen in plaats van een gok.
enum Installatie: Equatable {
    case homebrew
    case bron(pad: String)
    case onbekend

    /// Eén keer berekend, uit de echte bundel en de echte schijf.
    static let huidige: Installatie = {
        let bundelPad = Bundle.main.bundleURL.resolvingSymlinksInPath().path
        let gestempeldPad = Bundle.main.object(forInfoDictionaryKey: "DCSourcePath") as? String
        return bepaal(bundelPad: bundelPad, gestempeldPad: gestempeldPad,
                      bestaatKloon: gestempeldPad.map(Self.isEchteKloon) ?? false)
    }()

    /// Zit een `.git` en een `build.sh` in de gestempelde map? Alle drie apart, want een
    /// gestempeld pad dat inmiddels verplaatst of verwijderd is mag geen commando opleveren
    /// dat in de verkeerde (of niet-bestaande) map iets doet.
    private static func isEchteKloon(_ pad: String) -> Bool {
        let fm = FileManager.default
        var isMap: ObjCBool = false
        guard fm.fileExists(atPath: pad, isDirectory: &isMap), isMap.boolValue else { return false }
        return fm.fileExists(atPath: (pad as NSString).appendingPathComponent(".git"))
            && fm.fileExists(atPath: (pad as NSString).appendingPathComponent("build.sh"))
    }

    /// De zuivere beslislogica, los van `Bundle.main` en de schijf — zodat `verify.sh` haar
    /// kan beproeven zonder een echte geïnstalleerde bundel of kloon nodig te hebben.
    /// `huidige` roept dit aan met de echte waarden.
    ///
    /// Volgorde: Homebrew eerst. Homebrew installeert in de Cellar en zet daar een symlink
    /// vanuit `/opt/homebrew/` (of `/usr/local/` op Intel) naartoe — het opgeloste pad van de
    /// bundel verraadt dat, ongeacht wat er verder in `Info.plist` staat.
    static func bepaal(bundelPad: String, gestempeldPad: String?, bestaatKloon: Bool) -> Installatie {
        if bundelPad.split(separator: "/").contains("Cellar")
            || bundelPad.hasPrefix("/opt/homebrew/")
            || bundelPad.hasPrefix("/usr/local/") {
            return .homebrew
        }
        if let pad = gestempeldPad, !pad.isEmpty, bestaatKloon {
            return .bron(pad: pad)
        }
        return .onbekend
    }

    /// Het commando dat je zelf draait om bij te werken. De app voert het nooit uit — zie de
    /// uitleg bovenaan dit bestand.
    var bijwerkCommando: String {
        switch self {
        case .homebrew:
            return "brew upgrade dopamine-code"
        case .bron(let pad):
            // Tussen aanhalingstekens: deze kloon heet letterlijk "Sleep macos", en een pad
            // met een spatie erin breekt `cd` zonder die aanhalingstekens in twee argumenten.
            return "cd \"\(pad)\" && git pull && ./build.sh --install"
        case .onbekend:
            return "git pull && ./build.sh --install"
        }
    }
}
