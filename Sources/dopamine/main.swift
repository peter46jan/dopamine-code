import Foundation

// De opdrachtregel van Dopamine Code.
//
// Deze binary schakelt NIETS zelf. Hij kent `pmset` niet, hij importeert IOKit niet en hij
// start de app niet op: hij opent een socket, stelt een vraag en drukt het antwoord af. Twee
// processen die allebei de kernelvlag beheren is exact het conflict dat we Amphetamine
// verwijten, en dat mag hier niet via een omweg alsnog ontstaan.
//
// Draait de app niet, dan is dat een gewone `connect()`-fout en zegt hij dat gewoon —
// exitcode 4, geen gok, en zeker geen poging om de app zelf te starten.

/// De hulptekst staat in de vier `.strings`-bestanden en niet hier.
///
/// Deze binary heeft geen eigen bundel: hij staat in `Contents/MacOS` van de app, dus
/// `Bundle.main` is dezelfde bundel met dezelfde `.lproj`-mappen. `NSLocalizedString` vindt
/// ze daarmee ook vanuit de opdrachtregel, zonder dat er iets meegekopieerd hoeft te worden.
let uitgebreideHulp = L10n.t("cli.hulp")

/// Één plek die afdrukt en stopt, zodat `--json` ook op elk foutpad geldige JSON oplevert.
func klaar(_ antwoord: ControlChannel.Response, json: Bool) -> Never {
    if json {
        let encoder = ControlChannel.encoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(antwoord), let tekst = String(data: data, encoding: .utf8) {
            print(tekst)
        } else {
            // Nooit stil falen, en nooit halve JSON: dit blijft leesbaar voor `jq`.
            //
            // De zin komt sinds de omzetting naar `.strings` uit een vertaling, en die mag een
            // aanhalingsteken of backslash bevatten — in het Frans is een apostrof gewoon. Met
            // de zin in een handgeschreven JSON-string zou dat precies hier ongeldige JSON
            // opleveren, op het ene pad dat bestaat om dat te voorkomen. Dus laat
            // `JSONSerialization` het escapen doen.
            let noodgeval: [String: Any] = [
                "gelukt": false,
                "code": 2,
                "zin": L10n.t("cli.antwoordnietweertegeven"),
            ]
            if let data = try? JSONSerialization.data(withJSONObject: noodgeval, options: [.sortedKeys]),
               let tekst = String(data: data, encoding: .utf8) {
                print(tekst)
            } else {
                // Het laatste vangnet kan zelf niet van een vertaling afhangen.
                print("{\"code\":2,\"gelukt\":false,\"zin\":\"The reply could not be rendered.\"}")
            }
            exit(2)
        }
    } else {
        if antwoord.gelukt {
            print(antwoord.zin)
        } else {
            FileHandle.standardError.write(Data((antwoord.zin + "\n").utf8))
        }
    }
    exit(Int32(antwoord.code))
}

/// "2h", "90m", "1h30m" of gewoon "45" (minuten). Geeft `nil` bij onzin — nooit stilzwijgend
/// een getal verzinnen voor iets wat de gebruiker verkeerd typte.
func minutenUit(_ tekst: String) -> Int? {
    let s = tekst.lowercased().trimmingCharacters(in: .whitespaces)
    guard !s.isEmpty else { return nil }
    if let kaal = Int(s) { return kaal > 0 ? kaal : nil }

    var totaal = 0
    var getal = ""
    var gezien = false
    for teken in s {
        if teken.isNumber {
            getal.append(teken)
        } else if teken == "h" || teken == "u" {
            guard let n = Int(getal) else { return nil }
            totaal += n * 60
            getal = ""
            gezien = true
        } else if teken == "m" {
            guard let n = Int(getal) else { return nil }
            totaal += n
            getal = ""
            gezien = true
        } else {
            return nil
        }
    }
    guard getal.isEmpty, gezien, totaal > 0 else { return nil }
    return totaal
}

/// "18:00" wordt het eerstvolgende moment waarop het 18:00 is. Een tijdstip dat vandaag al
/// geweest is telt dus als morgen: voor een script is "geweigerd, dat is verleden tijd" om
/// 23:00 alleen maar verwarrend, en de tijdslimiet van 24 uur gaat er toch overheen.
func tijdstipUit(_ tekst: String) -> Date? {
    let delen = tekst.split(separator: ":")
    guard delen.count == 2, let uur = Int(delen[0]), let minuut = Int(delen[1]),
          (0...23).contains(uur), (0...59).contains(minuut) else { return nil }
    let kalender = Calendar.current
    let nu = Date()
    guard let vandaag = kalender.date(bySettingHour: uur, minute: minuut, second: 0, of: nu) else { return nil }
    if vandaag > nu { return vandaag }
    return kalender.date(byAdding: .day, value: 1, to: vandaag)
}

// --- argumenten ---------------------------------------------------------------

var argumenten = Array(CommandLine.arguments.dropFirst())
let jsonGevraagd = argumenten.contains("--json")
argumenten.removeAll { $0 == "--json" }

func verkeerdGebruik(_ zin: String) -> Never {
    if !jsonGevraagd { FileHandle.standardError.write(Data((uitgebreideHulp + "\n\n").utf8)) }
    klaar(.lokaal(zin: zin, code: 2), json: jsonGevraagd)
}

/// Leest het commando en zijn opties. Alles wat niet begrepen wordt is exitcode 2 met een
/// zin die zegt wát er niet begrepen werd — een script dat een typefout maakt hoort dat te
/// horen, niet stilzwijgend een sessie met de standaardduur te krijgen.
func leesVerzoek(_ woorden: [String]) -> ControlChannel.Request {
    guard let commando = woorden.first else {
        verkeerdGebruik(L10n.t("cli.geenopdracht"))
    }
    let rest = Array(woorden.dropFirst())

    switch commando {
    case "help", "--help", "-h":
        print(uitgebreideHulp)
        exit(0)

    case "off", "uit":
        guard rest.isEmpty else { verkeerdGebruik(L10n.t("cli.onbekendeoptie", rest[0])) }
        return ControlChannel.Request(soort: .uit)

    case "status":
        guard rest.isEmpty else { verkeerdGebruik(L10n.t("cli.onbekendeoptie", rest[0])) }
        return ControlChannel.Request(soort: .status)

    case "on", "aan":
        var verzoek = ControlChannel.Request(soort: .aan)
        var index = 0
        while index < rest.count {
            let vlag = rest[index]
            guard index + 1 < rest.count else { verkeerdGebruik(L10n.t("cli.mistwaarde", vlag)) }
            let tekst = rest[index + 1]
            switch vlag {
            case "--for", "--voor":
                guard let minuten = minutenUit(tekst) else {
                    verkeerdGebruik(L10n.t("cli.geenduur", tekst))
                }
                verzoek.minuten = minuten
            case "--until", "--tot":
                guard let tijdstip = tijdstipUit(tekst) else {
                    verkeerdGebruik(L10n.t("cli.geentijdstip", tekst))
                }
                verzoek.nietLaterDan = tijdstip
            case "--until-exit", "--tot-einde":
                guard let pid = Int32(tekst), pid > 0 else {
                    verkeerdGebruik(L10n.t("cli.geenprocesnummer", tekst))
                }
                verzoek.pid = pid
            default:
                verkeerdGebruik(L10n.t("cli.onbekendeoptie", vlag))
            }
            index += 2
        }
        return verzoek

    default:
        verkeerdGebruik(L10n.t("cli.onbekendeopdracht", commando))
    }
}

let verzoek = leesVerzoek(argumenten)

// --- vragen en antwoorden -----------------------------------------------------

let verbinding = ControlChannel.connect()
let fd: Int32
switch verbinding {
case .verbonden(let socket):
    fd = socket
case .appDraaitNiet:
    klaar(.lokaal(zin: L10n.t("cli.appdraaitniet"), code: 4), json: jsonGevraagd)
case .fout(let melding):
    klaar(.lokaal(zin: L10n.t("cli.verbindenmislukt", melding), code: 4), json: jsonGevraagd)
}

guard let regel = try? ControlChannel.line(verzoek), ControlChannel.write(regel, to: fd) else {
    close(fd)
    klaar(.lokaal(zin: L10n.t("cli.vraagnietverstuurd"), code: 4), json: jsonGevraagd)
}

guard let antwoordData = ControlChannel.readLine(from: fd) else {
    close(fd)
    klaar(.lokaal(zin: L10n.t("cli.geenantwoord"), code: 4), json: jsonGevraagd)
}
close(fd)

guard let antwoord = try? ControlChannel.decoder().decode(ControlChannel.Response.self, from: antwoordData) else {
    klaar(.lokaal(zin: L10n.t("cli.antwoordonleesbaar"), code: 4), json: jsonGevraagd)
}

klaar(antwoord, json: jsonGevraagd)
