// Rendert de zinnen die de app uit meerdere sleutels samenstelt, in alle vier de talen.
//
// Draaien vanuit de hoofdmap van de repo:
//
//   swiftc -O tools/zinnen.swift -o /tmp/zinnen && /tmp/zinnen .
//
// Dit is een leesmiddel, geen test: er is geen goed of fout uit te rekenen, je moet de
// zinnen zelf lezen. Dat is precies waarom het bestaat. `verify.sh --talen` vergelijkt
// sleutels en invulwaarden en staat groen zolang die kloppen — maar het leest nooit de zin
// die er uiteindelijk komt te staan. Een fragment kan op zichzelf kloppen en in de gastzin
// toch onzin worden.
//
// Wat dat kostte om te ontdekken: "De wachter heeft %@ gekeken" met "nog nooit" leest goed,
// met "al 12 minuten" zegt het het omgekeerde van de waarschuwing. Het Engels en het Frans
// hadden de ontkenning naar de gastzin verplaatst en kregen daardoor "has not looked never
// yet". Vier talen fout, en --talen stond al die tijd groen.

import Foundation

let wortel = CommandLine.arguments[1]
let talen = ["nl", "en", "de", "fr"]

var tabel: [String: [String: String]] = [:]
for taal in talen {
    let pad = "\(wortel)/Resources/\(taal).lproj/Localizable.strings"
    guard let d = NSDictionary(contentsOfFile: pad) as? [String: String] else {
        print("kon \(pad) niet lezen"); exit(1)
    }
    tabel[taal] = d
}

func t(_ taal: String, _ sleutel: String, _ args: CVarArg...) -> String {
    guard let vorm = tabel[taal]?[sleutel] else { return "<<\(sleutel) ONTBREEKT>>" }
    return args.isEmpty ? vorm : String(format: vorm, arguments: args)
}

func toon(_ titel: String, _ maak: (String) -> String) {
    print("\u{1B}[1m\(titel)\u{1B}[0m")
    for taal in talen { print("  \(taal)  \(maak(taal))") }
    print()
}

// 1. De stille wachter. Twee takken, want "al 12 minuten" en "nog nooit" gaan door
//    dezelfde %@ heen.
toon("wachter.stil — na 12 minuten") { l in
    t(l, "wachter.stil", t(l, "wachter.hoelang.minuten", 12))
}
toon("wachter.stil — nog nooit gekeken") { l in
    t(l, "wachter.stil", t(l, "wachter.hoelang.nooit"))
}

// 2. Vanzelf aangezet: reden + eindtijd, allebei fragmenten.
for (naam, sleutel) in [("klep", "omdat.klep"), ("app", "omdat.app"), ("schema", "omdat.schema")] {
    toon("trigger.aangezet — \(naam)") { l in
        let reden = sleutel == "omdat.app" ? t(l, sleutel, "Safari")
                  : sleutel == "omdat.schema" ? t(l, sleutel, "werkdag 09:00–17:00")
                  : t(l, sleutel)
        return t(l, "trigger.aangezet", reden, t(l, "trigger.tot", "17:00", "8u"))
    }
}
toon("trigger.aangezet — vakantiestand") { l in
    t(l, "trigger.aangezet", t(l, "omdat.sneltoets"), t(l, "trigger.zondereindtijd"))
}

// 3. Dezelfde reden-fragmenten, maar nu tussen haakjes in plaats van na "omdat".
toon("melding.trigger.geweigerd.klok — reden tussen haakjes") { l in
    t(l, "melding.trigger.geweigerd.klok", "14:03", t(l, "omdat.app", "Safari"),
      t(l, "weiger.temperatuur"))
}

// 4. Vorige afsluiting: stond de blokkade toen aan of uit?
for (naam, sleutel) in [("aan", "wachter.stondtoen.aan"), ("uit", "wachter.stondtoen.uit")] {
    toon("wachter.vorigeafsluiting — blokkade \(naam)") { l in
        t(l, "wachter.vorigeafsluiting", "03:14", t(l, "reden.appafgesloten"), t(l, sleutel))
    }
}

// 5. Duur die tegen een grens aan loopt.
toon("duur.sessie.geklemd — langer dan 24 uur") { l in
    t(l, "duur.sessie.geklemd", t(l, "duur.klem.langer"), "08:00", "24u")
}
toon("duur.sessie.geklemd — korter dan 5 minuten") { l in
    t(l, "duur.sessie.geklemd", t(l, "duur.klem.korter"), "09:05", "5m")
}
toon("duur.tot") { l in t(l, "duur.tot", "17:00", t(l, "duur.sessie.stopt", "17:00", "8u")) }

// 6. De statuszin van de opdrachtregel, uit drie stukken.
toon("kanaal.status — aan, tot, met proceskoppeling") { l in
    t(l, "kanaal.status.aan") + t(l, "kanaal.status.tot", "17:00")
        + t(l, "kanaal.status.koppeling", "npm run build") + "."
}

// 7. Te warm: staart met of zonder snelheid.
toon("melding.warm — met snelheid") { l in
    t(l, "melding.titel.tewarm") + ", " + t(l, "melding.warm.snelheid", 60).trimmingCharacters(in: .whitespaces)
        + " " + t(l, "melding.warm.kritiek")
}

// 8. Het vangnet dat de app terughaalde.
toon("vangnet.terug.klok — blokkade opgeruimd") { l in
    t(l, "vangnet.terug.klok", "03:14", t(l, "vangnet.staart.opgeruimd"))
}
toon("vangnet.terug.klok — blokkade nog aan") { l in
    t(l, "vangnet.terug.klok", "03:14", t(l, "vangnet.staart.nogaan"))
}

// 9. Sessie afgelopen, met een reden die zelf uit een sleutel komt.
for sleutel in ["reden.vlagzondersessie", "reden.geannuleerd.aanzetten", "reden.appafgesloten"] {
    toon("melding.sessieafgelopen.klok — \(sleutel)") { l in
        t(l, "melding.sessieafgelopen.klok", "03:14", t(l, sleutel))
    }
}

// 10. Grant ontbreekt: de eerste %@ is zelf een zin.
toon("weiger.grant.ontbreekt") { l in
    t(l, "weiger.grant.ontbreekt", t(l, "grant.sudoweigert"))
}

// 11. Netwerkstoringen, enkelvoud en meervoud.
toon("storing.samenvatting — 1 minuut") { l in
    t(l, "storing.samenvatting.min.een", 3, 1, "02:11")
}
toon("storing.samenvatting — meer minuten") { l in
    t(l, "storing.samenvatting.min.meer", 12, 47, "02:11")
}

// 12. Klaarzetten voor de klep.
toon("arming.staatklaar") { l in t(l, "arming.staatklaar", "14:30") }
toon("arming.vervallen") { l in t(l, "arming.vervallen", 15) }
