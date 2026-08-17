# Paneel-herontwerp — implementatieplan

> **Voor agentische uitvoerders:** VEREISTE SUB-SKILL: gebruik superpowers:subagent-driven-development
> (aanbevolen) of superpowers:executing-plans om dit plan taak voor taak uit te voeren. Stappen
> gebruiken `- [ ]` zodat je ze kunt afvinken.

**Doel:** het menubalkpaneel opnieuw indelen rond één vraag — slaapt mijn Mac niet, en tot
wanneer — met de vangnetten als drie meters die tonen waar je bent én waar het stopt.

**Aanpak:** de logica die stil fout kan gaan wordt eerst uit de weergave getrokken in drie
zuivere typen zonder SwiftUI (`Meter`, `KaartToestand`, `Aandacht`). Die zijn met een
`swiftc`-proef te testen zoals `Version.swift` dat al is. Pas daarna komen de views, en
`MenuView` wordt een dunne compositie.

**Gereedschap:** Swift 6.3 / SwiftUI, kale `swiftc` via `build.sh`, controles via `verify.sh`.
Geen testframework en geen pakketbeheerder — proeven zijn losse Swift-programma's die tegen de
échte bronbestanden gecompileerd worden.

**Spec:** [`2026-08-17-paneel-herontwerp.md`](2026-08-17-paneel-herontwerp.md)

---

## Bestandsindeling

`build.sh` pakt bronbestanden met een glob (`"$SRC_DIR"/*.swift`), dus nieuwe bestanden hoeven
nergens aangemeld te worden.

| Bestand | Verantwoordelijkheid | Mag importeren |
|---|---|---|
| `Sources/DopamineCode/Meter.swift` | **nieuw** — één vangnet als paar: nu én grens | alleen `Foundation` |
| `Sources/DopamineCode/KaartToestand.swift` | **nieuw** — uit / gearmd / aan | alleen `Foundation` |
| `Sources/DopamineCode/Aandacht.swift` | **nieuw** — waarschuwingen op ernst sorteren | alleen `Foundation` |
| `Sources/DopamineCode/Glas.swift` | **nieuw** — `.glassEffect()` met terugval | SwiftUI |
| `Sources/DopamineCode/PaneelOnderdelen.swift` | **nieuw** — de losse views van het paneel | SwiftUI |
| `Sources/DopamineCode/MenuView.swift` | herschreven tot dunne compositie | SwiftUI |
| `Sources/DopamineCode/SettingsView.swift` | krijgt de schuifregelaar en `behaviourSummary` | SwiftUI |
| `Resources/*.lproj/Localizable.strings` | nieuwe sleutels, vier talen | — |
| `verify.sh` | drie proeven erbij | — |

**De eerste drie mogen géén SwiftUI importeren.** Dat is niet netjesheid maar de voorwaarde
waaronder ze te testen zijn: de proef compileert het bronbestand rechtstreeks mee, en met
SwiftUI erin sleep je de hele weergavelaag de proef in.

---

## Taak 1: `Meter` — één vangnet als paar

**Bestanden:**
- Aanmaken: `Sources/DopamineCode/Meter.swift`
- Wijzigen: `verify.sh` (nieuwe functie `test_paneel_meters`)

- [ ] **Stap 1: schrijf de falende proef**

Zet dit in `verify.sh`, direct vóór `test_tap()`:

```bash
test_paneel_meters() {
  section "13. Paneel: de meters rekenen goed"

  local src="$PROJECT_DIR/Sources/DopamineCode/Meter.swift"
  if [ ! -f "$src" ]; then
    fail "Meter.swift ontbreekt."
    return
  fi

  local dir; dir="$(mktemp -d)"
  cat > "$dir/main.swift" <<'SWIFT'
import Foundation

var fouten = 0
func eis(_ voorwaarde: Bool, _ wat: String) {
    if !voorwaarde { print("FOUT: \(wat)"); fouten += 1 }
}

// --- de accumeter -------------------------------------------------------------
// De vulling is de stand, de zone is de grens. Ze mogen nooit hetzelfde getal zijn.
let vol = AccuMeter(percent: 84, grens: 15, aanDeLader: false)
eis(vol.vulling == 0.84, "84% vult 0,84, werd \(vol.vulling)")
eis(vol.zone == 0.15, "grens 15% geeft zone 0,15, werd \(vol.zone)")
eis(!vol.grijptIn, "84% boven een grens van 15% grijpt niet in")

// De grens is `<=`, precies zoals AppModel hem toepast. Op de grens zelf grijpt hij dus in.
eis(AccuMeter(percent: 15, grens: 15, aanDeLader: false).grijptIn, "15 <= 15 grijpt in")
eis(!AccuMeter(percent: 16, grens: 15, aanDeLader: false).grijptIn, "16 > 15 grijpt niet in")

// Aan de lader kan dit vangnet niet afgaan — AppModel eist `!battery.onAC`. Een meter die
// hem dan als scherp tekent, belooft iets wat niet gebeurt.
eis(!AccuMeter(percent: 5, grens: 15, aanDeLader: true).grijptIn, "aan de lader grijpt hij niet in")
eis(AccuMeter(percent: 5, grens: 15, aanDeLader: true).slaapt, "aan de lader slaapt het vangnet")
eis(!AccuMeter(percent: 84, grens: 15, aanDeLader: false).slaapt, "op accu slaapt het niet")

// Rommel van buiten mag niet buiten de balk tekenen.
eis(AccuMeter(percent: 140, grens: 15, aanDeLader: false).vulling == 1.0, "boven 100 klemt op 1")
eis(AccuMeter(percent: -8, grens: 15, aanDeLader: false).vulling == 0.0, "onder 0 klemt op 0")

// --- de warmtemeter -----------------------------------------------------------
// Vier stappen, want macOS geeft er vier. De laatste is waar de sessie stopt.
let koel = WarmteMeter(stap: 1)
eis(koel.aantal == 4, "vier stappen, werd \(koel.aantal)")
eis(koel.stopBij == 4, "stopt bij de vierde")
eis(koel.brandt(1) && !koel.brandt(2), "bij stap 1 brandt alleen het eerste blokje")
eis(!koel.grijptIn, "stap 1 grijpt niet in")

let heet = WarmteMeter(stap: 4)
eis(heet.grijptIn, "stap 4 grijpt in")
eis(heet.brandt(1) && heet.brandt(4), "bij stap 4 branden ze allemaal")

// Een stap buiten 1…4 mag niet stil doorglippen naar "alles in orde".
eis(WarmteMeter(stap: 9).stap == 4, "boven het aantal klemt op het aantal")
eis(WarmteMeter(stap: 0).stap == 1, "onder 1 klemt op 1")

print(fouten == 0 ? "OK" : "FOUTEN=\(fouten)")
exit(fouten == 0 ? 0 : 1)
SWIFT

  local build
  if ! command -v swiftc >/dev/null 2>&1; then
    skip "swiftc niet gevonden; de meters zijn niet getest."
  elif ! build="$(swiftc -O -o "$dir/probe" "$src" "$dir/main.swift" 2>&1)"; then
    fail "De meterproef compileert niet: $(printf '%s' "$build" | grep error: | head -2 | tr '\n' ' ')"
  else
    local uit
    if uit="$("$dir/probe" 2>&1)"; then
      pass "Accumeter en warmtemeter rekenen goed, inclusief de lader-uitzondering."
    else
      fail "Meters deugen niet: $(printf '%s' "$uit" | tr '\n' ' ')"
    fi
  fi
  rm -rf "$dir"
}
```

- [ ] **Stap 2: draai hem en zie hem falen**

Draai: `./verify.sh --report 2>&1 | grep -A 2 'Paneel: de meters'`
Verwacht: `Meter.swift ontbreekt.` — de proef bestaat, het onderwerp nog niet.

> Hij moet hier vallen op het ontbrekende bestand, niet op een ontbrekende functie in
> `verify.sh`. Zie je in plaats daarvan niets in de uitvoer, dan is `test_paneel_meters`
> nog nergens aangeroepen — dat gebeurt pas in taak 9. Roep hem voor nu met de hand aan
> onderaan het script om te zien dat hij valt, en haal die regel daarna weer weg.

- [ ] **Stap 3: schrijf de minimale implementatie**

Maak `Sources/DopamineCode/Meter.swift`:

```swift
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
```

- [ ] **Stap 4: draai de proef en zie hem slagen**

Draai: `./verify.sh --report 2>&1 | grep -A 2 'Paneel: de meters'`
Verwacht: `✓ Accumeter en warmtemeter rekenen goed, inclusief de lader-uitzondering.`

- [ ] **Stap 5: verifieer de proef omgekeerd**

De huisregel uit `CLAUDE.md`: een test die maar één uitkomst kent, test niets. Zet in
`Meter.swift` tijdelijk `grijptIn` om naar `percent < grens`, draai opnieuw, en eis dat je
`FOUT: 15 <= 15 grijpt in` ziet. Zet hem daarna terug.

- [ ] **Stap 6: commit**

```bash
git add Sources/DopamineCode/Meter.swift verify.sh
git commit -m "Trek de vangnetmeters uit de weergave

Een meter die "15%" toont naast een Mac op 84% is niet fout in de code maar
in de betekenis. Door `percent` en `grens` als twee velden vast te leggen kan
dat verschil niet meer verdwijnen in een opgemaakte zin.

`grijptIn` kopieert de voorwaarde die AppModel al gebruikt, `<=` en alleen
zonder lader. Wijkt de meter daarvan af, dan tekent hij iets anders dan er
gebeurt — erger dan geen meter.

De warmtemeter is gestapeld en niet vloeiend omdat macOS geen graden geeft:
thermalState kent vier namen, pmset -g therm zwijgt zonder druk, powermetrics
wil root. Vier blokjes suggereren geen precisie die er niet is.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

## Taak 2: `KaartToestand` — uit, gearmd, aan

**Bestanden:**
- Aanmaken: `Sources/DopamineCode/KaartToestand.swift`
- Wijzigen: `verify.sh` (uitbreiding van `test_paneel_meters` → hernoemen naar `test_paneel`)

- [ ] **Stap 1: hernoem de proeffunctie en voeg de falende gevallen toe**

Hernoem in `verify.sh` `test_paneel_meters()` naar `test_paneel()` en verander de sectiekop
naar `"13. Paneel: meters, kaarttoestand en de rangorde van waarschuwingen"`.

Voeg ná het meterblok een tweede blok toe:

```bash
  # --- 2. De kaarttoestand ------------------------------------------------------------
  local src2="$PROJECT_DIR/Sources/DopamineCode/KaartToestand.swift"
  if [ ! -f "$src2" ]; then
    fail "KaartToestand.swift ontbreekt."
  else
    local dir2; dir2="$(mktemp -d)"
    cat > "$dir2/main.swift" <<'SWIFT'
import Foundation

var fouten = 0
func eis(_ voorwaarde: Bool, _ wat: String) {
    if !voorwaarde { print("FOUT: \(wat)"); fouten += 1 }
}

let nu = Date(timeIntervalSince1970: 1_000_000)

// Niets aan: de kaart biedt het armen aan, want dat is het enige zinnige aanbod.
let uit = KaartToestand(intendedOn: false, armTot: nil, sessieStart: nil, deadline: nil, nu: nu)
eis(uit.isUit, "niets aan is .uit")
eis(uit.voortgang == 0, "uit heeft geen voortgang")
eis(uit.resterend == nil, "uit telt niets af")

// Gearmd wint van uit, ook al is intendedOn nog vals: er staat iets te gebeuren.
let arm = KaartToestand(intendedOn: false, armTot: nu.addingTimeInterval(270),
                        sessieStart: nil, deadline: nil, nu: nu)
eis(arm.isGearmd, "armTot in de toekomst is .gearmd")
eis(arm.resterend == 270, "gearmd telt af naar armTot, werd \(String(describing: arm.resterend))")

// Een arming die verlopen is telt niet meer mee.
let armVoorbij = KaartToestand(intendedOn: false, armTot: nu.addingTimeInterval(-1),
                               sessieStart: nil, deadline: nil, nu: nu)
eis(armVoorbij.isUit, "een verlopen arming valt terug naar .uit")

// Aan: de boog toont het verstreken deel.
let aan = KaartToestand(intendedOn: true,
                        armTot: nil,
                        sessieStart: nu.addingTimeInterval(-3600),
                        deadline: nu.addingTimeInterval(3600),
                        nu: nu)
eis(aan.isAan, "intendedOn met deadline is .aan")
eis(aan.resterend == 3600, "resterend is deadline - nu")
eis(abs(aan.voortgang - 0.5) < 0.001, "halverwege is 0,5, werd \(aan.voortgang)")

// Aan zonder deadline mag niet als 100% vol tekenen — dat zou "bijna klaar" zeggen.
let aanZonder = KaartToestand(intendedOn: true, armTot: nil, sessieStart: nu,
                              deadline: nil, nu: nu)
eis(aanZonder.isAan, "intendedOn zonder deadline is nog steeds .aan")
eis(aanZonder.voortgang == 0, "zonder deadline is de boog leeg, werd \(aanZonder.voortgang)")
eis(aanZonder.resterend == nil, "zonder deadline valt er niets af te tellen")

// Een deadline die voorbij is: nul, niet negatief, en de boog blijft binnen de rand.
let over = KaartToestand(intendedOn: true, armTot: nil,
                         sessieStart: nu.addingTimeInterval(-7200),
                         deadline: nu.addingTimeInterval(-60), nu: nu)
eis(over.resterend == 0, "een verstreken deadline telt 0 en niet negatief")
eis(over.voortgang == 1.0, "voortgang klemt op 1")

// Aan wint van gearmd: staat de sessie al te lopen, dan is de arming niet meer het nieuws.
let allebei = KaartToestand(intendedOn: true, armTot: nu.addingTimeInterval(270),
                            sessieStart: nu, deadline: nu.addingTimeInterval(60), nu: nu)
eis(allebei.isAan, "een lopende sessie wint van een arming")

print(fouten == 0 ? "OK" : "FOUTEN=\(fouten)")
exit(fouten == 0 ? 0 : 1)
SWIFT
    local build2
    if ! command -v swiftc >/dev/null 2>&1; then
      skip "swiftc niet gevonden; de kaarttoestand is niet getest."
    elif ! build2="$(swiftc -O -o "$dir2/probe" "$src2" "$dir2/main.swift" 2>&1)"; then
      fail "De kaartproef compileert niet: $(printf '%s' "$build2" | grep error: | head -2 | tr '\n' ' ')"
    else
      local uit2
      if uit2="$("$dir2/probe" 2>&1)"; then
        pass "Kaarttoestand klopt in alle drie de toestanden en op de randen."
      else
        fail "Kaarttoestand deugt niet: $(printf '%s' "$uit2" | tr '\n' ' ')"
      fi
    fi
    rm -rf "$dir2"
  fi
```

- [ ] **Stap 2: draai hem en zie hem falen**

Draai: `./verify.sh --report 2>&1 | grep -A 4 'Paneel: meters'`
Verwacht: `KaartToestand.swift ontbreekt.`

- [ ] **Stap 3: schrijf de implementatie**

Maak `Sources/DopamineCode/KaartToestand.swift`:

```swift
import Foundation

/// De drie toestanden van de statuskaart, in één type.
///
/// Nu leidt het paneel dit af uit vier losse eigenschappen verspreid over de body, en het
/// armen staat als losse tekstlink bóven de duurkiezer — een regel die soms verschijnt en
/// soms niet, op een plek waar niets anders over de toestand gaat. Hier is het één vraag met
/// één antwoord, en de rangorde ligt vast in plaats van in de vololgorde van een paar `if`s.
struct KaartToestand {

    enum Wat {
        case uit
        case gearmd
        case aan
    }

    let wat: Wat

    /// Waar de boog staat, 0…1. Nul als er niets af te tellen valt.
    let voortgang: Double

    /// Seconden tot het einde: tot de arming afloopt, of tot de deadline. `nil` als er geen
    /// einde bekend is — dan telt de kaart niets af in plaats van nul te tonen.
    let resterend: TimeInterval?

    var isUit: Bool { wat == .uit }
    var isGearmd: Bool { wat == .gearmd }
    var isAan: Bool { wat == .aan }

    init(intendedOn: Bool, armTot: Date?, sessieStart: Date?, deadline: Date?, nu: Date) {

        // Een lopende sessie wint altijd. Staat er ook nog een arming open, dan is die niet
        // meer het nieuws — de Mac is al wakker.
        if intendedOn {
            wat = .aan
            if let deadline {
                resterend = max(0, deadline.timeIntervalSince(nu))
                if let sessieStart, deadline > sessieStart {
                    let totaal = deadline.timeIntervalSince(sessieStart)
                    let verstreken = nu.timeIntervalSince(sessieStart)
                    voortgang = min(max(verstreken / totaal, 0), 1)
                } else {
                    voortgang = 0
                }
            } else {
                // Geen deadline betekent niet "bijna klaar". Een volle boog zou dat zeggen.
                resterend = nil
                voortgang = 0
            }
            return
        }

        // Een arming die al verlopen is, is geen arming meer. Zonder deze controle bleef de
        // kaart "wacht op de klep" tonen bij iets wat nooit meer afgaat.
        if let armTot, armTot > nu {
            wat = .gearmd
            resterend = armTot.timeIntervalSince(nu)
            voortgang = 0
            return
        }

        wat = .uit
        resterend = nil
        voortgang = 0
    }
}
```

- [ ] **Stap 4: draai de proef en zie hem slagen**

Draai: `./verify.sh --report 2>&1 | grep -A 4 'Paneel: meters'`
Verwacht: `✓ Kaarttoestand klopt in alle drie de toestanden en op de randen.`

- [ ] **Stap 5: verifieer omgekeerd**

Haal in `KaartToestand.swift` de `armTot > nu`-vergelijking weg (maak er `armTot != nil` van),
draai opnieuw, en eis `FOUT: een verlopen arming valt terug naar .uit`. Zet terug.

- [ ] **Stap 6: commit**

```bash
git add Sources/DopamineCode/KaartToestand.swift verify.sh
git commit -m "Maak van de drie paneeltoestanden één type

Het paneel leidde uit, gearmd en aan af uit vier losse eigenschappen verspreid
over de body, en het armen stond als tekstlink boven de duurkiezer — een regel
die soms verschijnt en soms niet, op een plek waar niets anders over de
toestand gaat.

Twee randen die nu vastliggen in plaats van in de volgorde van een paar ifs:
een arming die al verlopen is valt terug naar uit, en een sessie zonder
deadline tekent een lege boog in plaats van een volle. Dat laatste zou
"bijna klaar" zeggen over iets zonder einde.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

## Taak 3: `Aandacht` — waarschuwingen op ernst

**Bestanden:**
- Aanmaken: `Sources/DopamineCode/Aandacht.swift`
- Wijzigen: `verify.sh` (derde blok in `test_paneel`)

- [ ] **Stap 1: voeg het derde blok aan de proef toe**

Direct ná het kaartblok in `test_paneel()`:

```bash
  # --- 3. De rangorde van waarschuwingen ----------------------------------------------
  local src3="$PROJECT_DIR/Sources/DopamineCode/Aandacht.swift"
  if [ ! -f "$src3" ]; then
    fail "Aandacht.swift ontbreekt."
  else
    local dir3; dir3="$(mktemp -d)"
    cat > "$dir3/main.swift" <<'SWIFT'
import Foundation

var fouten = 0
func eis(_ voorwaarde: Bool, _ wat: String) {
    if !voorwaarde { print("FOUT: \(wat)"); fouten += 1 }
}

func m(_ s: Aandacht.Soort) -> Aandacht.Melding { Aandacht.Melding(soort: s, tekst: "\(s)") }

// Door elkaar erin, op ernst eruit — ongeacht de volgorde waarin het paneel ze aanbiedt.
let door = Aandacht(meldingen: [m(.updateBeschikbaar), m(.geenToestemming), m(.vangnettenUit)])
eis(door.lijst.first?.soort == .vangnettenUit, "vangnettenUit staat vooraan")
eis(door.lijst.last?.soort == .updateBeschikbaar, "updateBeschikbaar staat achteraan")
eis(door.lijst.count == 3, "er raakt niets kwijt")

// De kop toont de ernstigste, de telling de rest.
eis(door.kop?.soort == .vangnettenUit, "de kop is de ernstigste melding")
eis(door.telling == 3, "de telling is het totaal, werd \(door.telling)")

// Rood klapt altijd uit. Dat is het hele punt: rood is waar iemand iets moet doen, en dat
// achter een driehoekje verstoppen is precies de fout die dit ontwerp oploste.
eis(door.moetOpen, "een rode melding dwingt open")
eis(Aandacht(meldingen: [m(.vangnettenUit)]).moetOpen, "vangnettenUit is rood")
eis(Aandacht(meldingen: [m(.belofteGebroken)]).moetOpen, "belofteGebroken is rood")
eis(Aandacht(meldingen: [m(.conflictDeeltVlag)]).moetOpen, "conflictDeeltVlag is rood")

// Oranje en grijs niet — daar mag de rij ingeklapt blijven.
eis(!Aandacht(meldingen: [m(.geenToestemming)]).moetOpen, "geenToestemming is oranje, niet rood")
eis(!Aandacht(meldingen: [m(.conflict)]).moetOpen, "een conflict zonder gedeelde vlag is oranje")
eis(!Aandacht(meldingen: [m(.storingen)]).moetOpen, "storingen zijn grijs")
eis(!Aandacht(meldingen: [m(.updateBeschikbaar)]).moetOpen, "een update is grijs")

// Leeg is leeg: geen rij, geen telling, geen lege balk in het paneel.
let niets = Aandacht(meldingen: [])
eis(niets.lijst.isEmpty && niets.kop == nil && !niets.moetOpen, "leeg levert geen rij op")
eis(niets.telling == 0, "leeg telt nul")

// Elke soort heeft precies één ernst, en elke ernst is toegekend. Zonder deze controle kan
// een nieuwe soort er stil bij komen zonder rangorde en dan valt hij overal buiten.
for soort in Aandacht.Soort.allCases {
    eis([.rood, .oranje, .grijs].contains(soort.ernst), "\(soort) heeft geen ernst")
}
// En de rangorde is een echte ordening: geen twee soorten op dezelfde plek.
let volgordes = Aandacht.Soort.allCases.map(\.rangorde)
eis(Set(volgordes).count == volgordes.count, "twee soorten delen een rangorde")

print(fouten == 0 ? "OK" : "FOUTEN=\(fouten)")
exit(fouten == 0 ? 0 : 1)
SWIFT
    local build3
    if ! command -v swiftc >/dev/null 2>&1; then
      skip "swiftc niet gevonden; de rangorde is niet getest."
    elif ! build3="$(swiftc -O -o "$dir3/probe" "$src3" "$dir3/main.swift" 2>&1)"; then
      fail "De rangordeproef compileert niet: $(printf '%s' "$build3" | grep error: | head -2 | tr '\n' ' ')"
    else
      local uit3
      if uit3="$("$dir3/probe" 2>&1)"; then
        pass "Waarschuwingen sorteren op ernst; rood dwingt de rij open."
      else
        fail "De rangorde deugt niet: $(printf '%s' "$uit3" | tr '\n' ' ')"
      fi
    fi
    rm -rf "$dir3"
  fi
```

- [ ] **Stap 2: draai hem en zie hem falen**

Draai: `./verify.sh --report 2>&1 | grep -A 6 'Paneel: meters'`
Verwacht: `Aandacht.swift ontbreekt.`

- [ ] **Stap 3: schrijf de implementatie**

Maak `Sources/DopamineCode/Aandacht.swift`:

```swift
import Foundation

/// De waarschuwingen van het paneel, op ernst geordend.
///
/// Nu zijn het vier losse `if`-blokken in `MenuView` die niets van elkaar weten, zodat er in
/// het slechtste geval zes gekleurde vakken onder elkaar staan — allemaal even luid, dus
/// niets luid. Hier is het één lijst met een vaste rangorde.
///
/// Dit type kent de meldingen niet die het ordent: het krijgt een soort en een kant-en-klare
/// zin. Dat is met opzet. Zou het `ConflictWatch.Conflict` en `SleepWatch.Episode` kennen,
/// dan sleept het de halve app zijn proef in en is de rangorde niet meer los te testen.
struct Aandacht {

    enum Ernst {
        case rood      // er moet nu iets gebeuren
        case oranje    // het werkt niet zoals bedoeld
        case grijs     // verslag, geen probleem
    }

    /// De volgorde staat vast en is de volgorde uit het ontwerpdocument. Wie hier iets
    /// tussenvoegt, verandert wat er bovenaan het paneel komt te staan.
    enum Soort: CaseIterable {
        case vangnettenUit        // de vlag staat aan en er is niets meer dat hem terugzet
        case belofteGebroken      // de Mac heeft geslapen terwijl wij hem vasthielden
        case conflictDeeltVlag    // een andere app schrijft dezelfde vlag
        case geenToestemming      // zonder de sudoers-regel werkt er niets
        case conflict             // een andere app houdt de Mac op zijn eigen manier wakker
        case wasGeslapen          // geslapen, maar de vlag stond niet aan: dat hoort te kunnen
        case storingen            // netwerkonderbrekingen, verslag achteraf
        case updateBeschikbaar
        case updateMededeling

        var rangorde: Int {
            switch self {
            case .vangnettenUit:     return 1
            case .belofteGebroken:   return 2
            case .conflictDeeltVlag: return 3
            case .geenToestemming:   return 4
            case .conflict:          return 5
            case .wasGeslapen:       return 6
            case .storingen:         return 7
            case .updateBeschikbaar: return 8
            case .updateMededeling:  return 9
            }
        }

        var ernst: Ernst {
            switch self {
            case .vangnettenUit, .belofteGebroken, .conflictDeeltVlag:
                return .rood
            case .geenToestemming, .conflict, .wasGeslapen:
                return .oranje
            case .storingen, .updateBeschikbaar, .updateMededeling:
                return .grijs
            }
        }
    }

    struct Melding {
        let soort: Soort
        let tekst: String
    }

    let lijst: [Melding]

    init(meldingen: [Melding]) {
        lijst = meldingen.sorted { $0.soort.rangorde < $1.soort.rangorde }
    }

    /// De ernstigste melding — wat er in de ingeklapte rij komt te staan.
    var kop: Melding? { lijst.first }

    var telling: Int { lijst.count }

    /// Rood klapt altijd uit. Rood is de toestand waarin iemand iets moet doen, en die achter
    /// een driehoekje verstoppen is precies de fout die dit ontwerp moest oplossen.
    var moetOpen: Bool { lijst.contains { $0.soort.ernst == .rood } }
}
```

- [ ] **Stap 4: draai de proef en zie hem slagen**

Draai: `./verify.sh --report 2>&1 | grep -A 6 'Paneel: meters'`
Verwacht: `✓ Waarschuwingen sorteren op ernst; rood dwingt de rij open.`

- [ ] **Stap 5: verifieer omgekeerd**

Geef `.geenToestemming` tijdelijk `return .rood`, draai opnieuw, en eis
`FOUT: geenToestemming is oranje, niet rood`. Zet terug.

- [ ] **Stap 6: commit**

```bash
git add Sources/DopamineCode/Aandacht.swift verify.sh
git commit -m "Geef de waarschuwingen een rangorde

Het waren vier losse if-blokken in MenuView die niets van elkaar wisten, zodat
er in het slechtste geval zes gekleurde vakken onder elkaar stonden: allemaal
even luid, dus niets luid.

Rood klapt altijd uit en kan nooit ingeklapt blijven. Rood is de toestand
waarin iemand iets moet doen; die achter een driehoekje verstoppen is de fout
die dit ontwerp moest oplossen.

Het type kent de meldingen niet die het ordent — het krijgt een soort en een
kant-en-klare zin. Zou het ConflictWatch.Conflict en SleepWatch.Episode
kennen, dan sleept het de halve app zijn proef in en is de rangorde niet meer
los te testen.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

## Taak 4: `Glas` — glas met terugval

**Bestanden:**
- Aanmaken: `Sources/DopamineCode/Glas.swift`

Hier is geen proef voor: dit is puur weergave en `#available` is niet uit te lokken in een
programma dat op één macOS-versie draait. De controle is dat het op beide doelversies
compileert, en dat staat in stap 3.

- [ ] **Stap 1: schrijf de modifier**

Maak `Sources/DopamineCode/Glas.swift`:

```swift
import SwiftUI

/// Liquid Glass, met een terugval voor macOS 14 en 15.
///
/// `.glassEffect()` bestaat pas vanaf macOS 26 en `build.sh` bouwt voor 14.0. Dat blijft zo:
/// de terugval is één aftakking op één plek, en niemand wegsturen weegt zwaarder dan een
/// schonere aanroep. Op 14 en 15 ziet het er soberder uit; de indeling is dezelfde.
///
/// `.ultraThinMaterial` en niet een egale kleur, omdat het paneel dan op beide versies
/// doorschijnend blijft — de indeling rekent op een achtergrond die meebeweegt.
struct Glas: ViewModifier {
    var straal: CGFloat = 12
    var oplichtend = false

    func body(content: Content) -> some View {
        let vorm = RoundedRectangle(cornerRadius: straal, style: .continuous)
        if #available(macOS 26.0, *) {
            content.glassEffect(oplichtend ? .regular.tint(.accentColor) : .regular, in: vorm)
        } else {
            content
                .background(.ultraThinMaterial, in: vorm)
                .overlay(vorm.strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
        }
    }
}

extension View {
    /// Zet dit onderdeel op glas. `oplichtend` is voor de statuskaart tijdens een sessie.
    func glas(straal: CGFloat = 12, oplichtend: Bool = false) -> some View {
        modifier(Glas(straal: straal, oplichtend: oplichtend))
    }
}
```

- [ ] **Stap 2: bouw voor de huidige doelversie**

Draai: `./build.sh`
Verwacht: bouwt door zonder fouten.

- [ ] **Stap 3: bouw voor macOS 26 en controleer dat de andere tak óók compileert**

De `#available`-tak die je niet draait, wordt wél gecompileerd — maar alleen als de SDK hem
kent. Controleer beide kanten:

```bash
DEPLOYMENT_TARGET_OVERRIDE=26.0 ./build.sh 2>&1 | tail -3   # de glastak
./build.sh 2>&1 | tail -3                                   # de terugvaltak
```

Kent `build.sh` die variabele niet, wijzig dan regel 30 tijdelijk naar `DEPLOYMENT_TARGET="26.0"`,
bouw, en zet hem terug. Beide moeten slagen. Faalt de eerste, dan is de Xcode-SDK ouder dan 26
en moet je die eerst bijwerken.

- [ ] **Stap 4: commit**

```bash
git add Sources/DopamineCode/Glas.swift
git commit -m "Voeg Liquid Glass toe met een terugval voor macOS 14 en 15

.glassEffect() bestaat pas vanaf macOS 26 en build.sh bouwt voor 14.0. Dat
blijft zo: de terugval is één aftakking op één plek, en niemand wegsturen
weegt zwaarder dan een schonere aanroep — zeker in de maand dat de app onder
de aandacht wordt gebracht.

De terugval is .ultraThinMaterial en geen egale kleur, zodat het paneel op
beide versies doorschijnend blijft. De indeling rekent op een achtergrond die
meebeweegt.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

## Taak 5: de views

**Bestanden:**
- Aanmaken: `Sources/DopamineCode/PaneelOnderdelen.swift`

Geen proef: dit is weergave. De controle is dat het bouwt en dat je het ziet.

- [ ] **Stap 1: schrijf de meterviews**

Maak `Sources/DopamineCode/PaneelOnderdelen.swift`:

```swift
import SwiftUI

// MARK: - De meters

/// Een vloeiende meter: een balk met de rode zone erin en een streepje op de stand.
///
/// De zone ligt óver de vulling en niet ernaast: waar je staat en waar het stopt horen op
/// dezelfde as te liggen, anders moet de lezer twee schalen bij elkaar optellen.
struct AccuMeterView: View {
    let meter: AccuMeter

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.12))
                Capsule()
                    .fill(meter.slaapt ? Color.secondary : Color.accentColor)
                    .frame(width: geo.size.width * meter.vulling)
                Capsule()
                    .fill(Color.red.opacity(meter.slaapt ? 0.18 : 0.40))
                    .frame(width: geo.size.width * meter.zone)
                Rectangle()
                    .fill(Color.primary)
                    .frame(width: 1.5, height: 9)
                    .offset(x: max(0, geo.size.width * meter.vulling - 0.75))
            }
        }
        .frame(height: 4)
    }
}

/// Een gestapelde meter: vier blokjes, het laatste rood en leeg.
///
/// Gestapeld en niet vloeiend omdat het gegeven zelf gestapeld is — macOS geeft vier namen
/// en geen graden. De vorm hoort te zeggen wat voor gegeven het is.
struct WarmteMeterView: View {
    let meter: WarmteMeter

    var body: some View {
        HStack(spacing: 3) {
            ForEach(1...meter.aantal, id: \.self) { index in
                Capsule()
                    .fill(kleur(index))
                    .frame(height: 4)
            }
        }
    }

    private func kleur(_ index: Int) -> Color {
        if index == meter.stopBij && !meter.brandt(index) { return Color.red.opacity(0.30) }
        if meter.brandt(index) { return index >= meter.stopBij ? .red : .accentColor }
        return Color.primary.opacity(0.12)
    }
}

/// De wachter: een kloppende stip.
///
/// Geen balk, want er valt niets te vullen. Wat er te zeggen valt is dat hij nog leeft, en
/// dat zegt een hartslag beter dan een getal.
struct WachterStip: View {
    @State private var groot = false

    var body: some View {
        Circle()
            .fill(Color.green)
            .frame(width: 5, height: 5)
            .overlay(
                Circle()
                    .stroke(Color.green.opacity(groot ? 0 : 0.55), lineWidth: 3)
                    .scaleEffect(groot ? 2.6 : 1)
            )
            .onAppear {
                withAnimation(.easeOut(duration: 2.4).repeatForever(autoreverses: false)) {
                    groot = true
                }
            }
            .accessibilityHidden(true)
    }
}

/// Eén regel in het vangnettenblok: icoon, meter, waarde.
struct MeterRij<Meter: View>: View {
    let symbool: String
    let meter: Meter
    let waarde: String
    let grens: String?
    var gedempt = false

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: symbool)
                .font(.system(size: 9))
                .frame(width: 13)
                .foregroundStyle(.secondary)
            meter
            HStack(spacing: 3) {
                Text(waarde)
                    .foregroundStyle(gedempt ? Color.secondary : Color.primary)
                if let grens {
                    Text("· " + grens).foregroundStyle(.tertiary)
                }
            }
            .font(.system(size: 10.5))
            .monospacedDigit()
            .frame(width: 74, alignment: .trailing)
        }
    }
}
```

- [ ] **Stap 2: bouw**

Draai: `./build.sh`
Verwacht: bouwt door zonder fouten.

- [ ] **Stap 3: commit**

```bash
git add Sources/DopamineCode/PaneelOnderdelen.swift
git commit -m "Teken de vangnetten als meters

De zone ligt over de vulling en niet ernaast: waar je staat en waar het stopt
horen op dezelfde as, anders moet de lezer twee schalen bij elkaar optellen.

De warmtemeter is gestapeld en de accumeter vloeiend, omdat het gegeven zelf
dat verschil heeft. De wachter krijgt een hartslag in plaats van een balk —
er valt niets te vullen, alleen te laten zien dat hij nog leeft.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

## Taak 6: `MenuView` herschrijven

**Bestanden:**
- Wijzigen: `Sources/DopamineCode/MenuView.swift` (volledige herschrijving van de body)
- Wijzigen: `Sources/DopamineCode/AppModel.swift` (drie afgeleide eigenschappen erbij)

- [ ] **Stap 1: voeg de drie afgeleide eigenschappen aan `AppModel` toe**

Zet dit in `AppModel.swift`, direct ná `safetyNetLine` (regel ~335):

```swift
    // MARK: - Wat het paneel nodig heeft

    /// De toestand van de statuskaart. Eén vraag, één antwoord — zie `KaartToestand`.
    var kaart: KaartToestand {
        KaartToestand(intendedOn: intendedOn,
                      armTot: lidArm?.tot,
                      sessieStart: sessionStart,
                      deadline: deadline,
                      nu: now)
    }

    var accuMeter: AccuMeter {
        AccuMeter(percent: battery?.percent ?? 0,
                  grens: Prefs.batteryFloor,
                  aanDeLader: battery?.onAC ?? false)
    }

    var warmteMeter: WarmteMeter {
        switch thermal {
        case .nominal:  return WarmteMeter(stap: 1)
        case .fair:     return WarmteMeter(stap: 2)
        case .serious:  return WarmteMeter(stap: 3)
        case .critical: return WarmteMeter(stap: 4)
        }
    }

    /// Alle waarschuwingen in één gesorteerde lijst.
    ///
    /// Bewust hier en niet in de view: de rangorde is een beslissing over wat er bovenaan
    /// komt te staan, en die hoort niet in de opmaak te zitten.
    var aandacht: Aandacht {
        var meldingen: [Aandacht.Melding] = []
        if safetyNetsDisarmed {
            meldingen.append(.init(soort: .vangnettenUit, tekst: L10n.t("menu.ontwapend.titel")))
        }
        if let slept = sleepDuringSession {
            meldingen.append(.init(soort: sleepBrokeThePromise ? .belofteGebroken : .wasGeslapen,
                                   tekst: slept.describe()))
        }
        if let conflict {
            meldingen.append(.init(soort: conflict.sharesTheFlag ? .conflictDeeltVlag : .conflict,
                                   tekst: L10n.t(conflict.sharesTheFlag ? "menu.conflict.deelt"
                                                                        : "menu.conflict.draait",
                                                 conflict.name)))
        }
        if grantStatus != .granted {
            meldingen.append(.init(soort: .geenToestemming, tekst: grantText))
        }
        if !outages.isEmpty {
            meldingen.append(.init(soort: .storingen,
                                   tekst: L10n.t(outagesFromFinishedSession ? "menu.storing.vorige"
                                                                            : "menu.storing.nu")))
        }
        return Aandacht(meldingen: meldingen)
    }
```

> Kent `LidArm` geen veld `tot`, kijk dan hoe `arm.resterendeTekst(op:)` aan zijn eindtijd
> komt en gebruik dát veld. De naam is het enige dat hier kan afwijken.

- [ ] **Stap 2: bouw en controleer dat het compileert**

Draai: `./build.sh`
Verwacht: bouwt door. Faalt hij op `lidArm?.tot`, pas de veldnaam aan zoals hierboven.

- [ ] **Stap 3: vervang de body van `MenuView`**

Vervang in `MenuView.swift` alles van `var body: some View {` tot en met de sluitende `}` van
`keepAwakeSection`, `backlightSection` en `footer` door:

```swift
    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            statuskaart
            duurkiezer
            vangnetten
            aandachtsrij
            Divider()
            voet
        }
        .padding(13)
        .frame(width: 320)
        .onAppear {
            runningApps = RunningApps.list()
            showUpdateNotice = !Prefs.updateNoticeShown
        }
    }

    // MARK: - De statuskaart

    private var statuskaart: some View {
        HStack(spacing: 13) {
            BoogIcoon(toestand: model.kaart)
            VStack(alignment: .leading, spacing: 2) {
                grote
                onderregel
            }
            Spacer(minLength: 0)
            Toggle("", isOn: Binding(get: { model.intendedOn },
                                     set: { model.setKeepAwake($0) }))
                .toggleStyle(.switch)
                .labelsHidden()
                .disabled(model.busy)
        }
        .padding(11)
        .glas(oplichtend: model.kaart.isAan)
    }

    @ViewBuilder private var grote: some View {
        switch model.kaart.wat {
        case .uit:
            Text("kaart.uit").font(.headline)
        case .gearmd:
            Text("kaart.gearmd").font(.headline)
        case .aan:
            Text(model.remainingText ?? "—")
                .font(.system(size: 30, weight: .light))
                .monospacedDigit()
        }
    }

    @ViewBuilder private var onderregel: some View {
        switch model.kaart.wat {
        case .uit:
            Button("menu.arm.aanzetten") { model.armForLidClose() }
                .buttonStyle(.link).font(.caption).disabled(model.busy)
        case .gearmd:
            HStack(spacing: 6) {
                if let arm = model.lidArm {
                    Text(arm.resterendeTekst(op: model.now))
                        .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                }
                Button("menu.arm.intrekken") { model.cancelArming() }
                    .buttonStyle(.link).font(.caption)
            }
        case .aan:
            Text(onderregelAan).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var onderregelAan: String {
        var delen: [String] = []
        if let tot = model.deadlineText { delen.append(L10n.t("kaart.tot", tot)) }
        delen.append(L10n.t(model.lidClosed ? "sub.klepdicht" : "sub.klepopen"))
        return delen.joined(separator: " · ")
    }

    // MARK: - De duur

    private var duurkiezer: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("", selection: Binding(get: { model.autoOffMinutes },
                                          set: { model.setAutoOff(minutes: $0) })) {
                ForEach(quickDurations, id: \.self) { totaal in
                    Text(AppModel.durationText(totaal)).tag(totaal)
                }
                // Een waarde die niet in de vijf zit — via de tijdkiezer of via
                // `dopamine on --for` — krijgt een eigen segment. Zonder dit zou de kiezer
                // leeg staan bij een waarde die er wél is, en dat leest als "geen duur".
                if !quickDurations.contains(model.autoOffMinutes) {
                    Text(AppModel.durationText(model.autoOffMinutes)).tag(model.autoOffMinutes)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(model.busy)

            HStack(spacing: 8) {
                Text("kaart.eindigt").font(.caption).foregroundStyle(.secondary)
                DatePicker("", selection: $untilTime, displayedComponents: .hourAndMinute)
                    .labelsHidden().datePickerStyle(.field).controlSize(.mini)
                    .onChange(of: untilTime) { _, nieuw in
                        untilExplanation = model.setAutoOffUntil(nieuw)
                    }
                Spacer()
                procesKiezer
            }

            if let untilExplanation {
                Text(untilExplanation).font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var procesKiezer: some View {
        Menu {
            if runningApps.isEmpty {
                Text("menu.stoppenals.geenapps")
            } else {
                ForEach(runningApps) { item in
                    Button("\(item.naam) (\(item.pid))") { model.keepAwakeUntilQuit(of: item) }
                }
            }
        } label: {
            Text(model.binding.map { L10n.t("menu.stoppenals.klaar", $0.identity.naam) }
                 ?? L10n.t("menu.stoppenals.placeholder"))
                .font(.caption)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(model.busy)
    }

    // MARK: - De vangnetten

    private var vangnetten: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("vangnet.kop").font(.system(size: 10)).textCase(.uppercase)
                    .foregroundStyle(.tertiary)
                Spacer()
                Text("vangnet.legenda").font(.system(size: 10)).foregroundStyle(.tertiary)
            }

            MeterRij(symbool: "battery.50",
                     meter: AccuMeterView(meter: model.accuMeter),
                     waarde: "\(model.battery?.percent ?? 0)%",
                     grens: "\(Prefs.batteryFloor)%",
                     gedempt: model.accuMeter.slaapt)

            MeterRij(symbool: "thermometer.medium",
                     meter: WarmteMeterView(meter: model.warmteMeter),
                     waarde: model.thermal.label,
                     grens: "4/4")

            MeterRij(symbool: "shield",
                     meter: HStack(spacing: 6) {
                         WachterStip()
                         Text(model.wachterZin).font(.system(size: 10))
                             .foregroundStyle(.secondary).lineLimit(1)
                         Spacer(minLength: 0)
                     },
                     waarde: "",
                     grens: L10n.t("vangnet.wachter.interval"))

            if let limiet = model.cpuSpeedLimit, limiet < 100 {
                Text(L10n.t("vangnet.afgeknepen", limiet))
                    .font(.caption2).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - De aandachtsrij

    @ViewBuilder private var aandachtsrij: some View {
        let aandacht = model.aandacht
        if let kop = aandacht.kop {
            DisclosureGroup(isExpanded: Binding(
                get: { aandacht.moetOpen || aandachtOpen },
                set: { aandachtOpen = $0 }
            )) {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(aandacht.lijst.enumerated()), id: \.offset) { _, melding in
                        meldingVak(melding)
                    }
                }
                .padding(.top, 6)
            } label: {
                HStack(spacing: 7) {
                    if aandacht.telling > 1 {
                        Text("\(aandacht.telling)")
                            .font(.system(size: 10, weight: .bold))
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(kleur(kop.soort.ernst), in: Capsule())
                            .foregroundStyle(.white)
                    }
                    Text(kop.tekst).font(.caption)
                        .foregroundStyle(kleur(kop.soort.ernst))
                        .lineLimit(2)
                }
            }
            .disclosureGroupStyle(.automatic)
            .padding(9)
            .glas(straal: 10)
        }
    }

    private func kleur(_ ernst: Aandacht.Ernst) -> Color {
        switch ernst {
        case .rood:   return .red
        case .oranje: return .orange
        case .grijs:  return .secondary
        }
    }

    // MARK: - De voet

    private var voet: some View {
        HStack(spacing: 6) {
            Button { model.sleepNow() } label: {
                Label("menu.nuslapen", systemImage: "powersleep")
            }
            .disabled(model.busy)

            if model.backlight.hasDirectControl || KeyboardBacklight.canPostEvents {
                Button { model.toggleBacklight() } label: {
                    Image(systemName: "keyboard")
                }
                .foregroundStyle(model.backlightOn == true ? Color.accentColor : Color.secondary)
                .help(Text("menu.verlichting.titel"))
            }

            Spacer()

            Button {
                NSApp.setActivationPolicy(.regular)
                NSApp.activate(ignoringOtherApps: true)
                openSettings()
            } label: {
                Image(systemName: "gearshape")
            }
            Button("menu.voet.stop") { NSApp.terminate(nil) }
        }
        .controlSize(.small)
    }
```

Voeg boven in de struct twee `@State`-velden toe naast de bestaande:

```swift
    @State private var aandachtOpen = false
```

En verwijder de nu ongebruikte `header`, `subtitle`, `armingRow`, `durationRow`, `untilRow`,
`processRow`, `disarmedWarning`, `brokenPromiseWarning`, `grantWarning`, `conflictWarning`,
`outageList`, `backlightSection`, `footerButtons` — maar **niet** `updateNotice` en
`updateRow`: die worden in de volgende stap door `meldingVak` gebruikt.

- [ ] **Stap 4: schrijf `meldingVak` en `BoogIcoon`**

Zet `meldingVak` onderaan `MenuView` — het is de oude inhoud van de vier waarschuwingsvakken,
nu per soort in plaats van per `if`:

```swift
    @ViewBuilder private func meldingVak(_ melding: Aandacht.Melding) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(melding.tekst).font(.caption).foregroundStyle(kleur(melding.soort.ernst))
                .fixedSize(horizontal: false, vertical: true)
            switch melding.soort {
            case .vangnettenUit:
                Text("menu.ontwapend.uitleg").font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("sudo pmset -a disablesleep 0")
                    .font(.system(.caption2, design: .monospaced)).textSelection(.enabled)
            case .geenToestemming:
                HStack {
                    Button("menu.grant.installeren") { model.installGrant() }.disabled(model.busy)
                    Button("menu.grant.opnieuw") { model.refreshGrant() }
                }
                .controlSize(.small)
            case .conflict, .conflictDeeltVlag:
                if let conflict = model.conflict {
                    HStack {
                        Button(L10n.t("menu.conflict.afsluiten", conflict.name)) {
                            model.quitAmphetamine()
                        }
                        Button("menu.conflict.nietmelden") { model.dismissConflictWarning() }
                    }
                    .controlSize(.small)
                }
            case .storingen:
                ForEach(model.outages.suffix(3)) { storing in
                    Text("• " + storing.describe()).font(.caption2)
                        .foregroundStyle(storing.isOngoing ? Color.orange : Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            case .belofteGebroken:
                Text("./verify.sh --after")
                    .font(.system(.caption2, design: .monospaced)).textSelection(.enabled)
            case .wasGeslapen, .updateBeschikbaar, .updateMededeling:
                EmptyView()
            }
        }
    }
```

En zet `BoogIcoon` onderaan `PaneelOnderdelen.swift`:

```swift
/// De boog om het icoon: het verstreken deel van de sessie.
struct BoogIcoon: View {
    let toestand: KaartToestand

    var body: some View {
        ZStack {
            Circle().stroke(Color.primary.opacity(0.14), lineWidth: 4)
            Circle()
                .trim(from: 0, to: toestand.voortgang)
                .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Image(systemName: symbool)
                .font(.system(size: 17))
                .foregroundStyle(toestand.isAan ? Color.accentColor : Color.secondary)
        }
        .frame(width: 52, height: 52)
        .accessibilityHidden(true)
    }

    private var symbool: String {
        switch toestand.wat {
        case .uit:    return "moon.fill"
        case .gearmd: return "laptopcomputer.and.arrow.down"
        case .aan:    return "sun.max.fill"
        }
    }
}
```

- [ ] **Stap 5: voeg `wachterZin` en `cpuSpeedLimit` aan `AppModel` toe**

```swift
    /// Wanneer de wachter voor het laatst keek. Dat is het bewijs dat hij leeft, en het is
    /// het enige dat geen enkele concurrent heeft — StayAwake ruimt alleen op bij de vólgende
    /// start. `nil` als hij nog nooit gedraaid heeft.
    var wachterZin: String {
        guard let ronde = RestartGuard.shared.laatsteRonde else {
            return L10n.t("vangnet.wachter.nognietgekeken")
        }
        let seconden = max(0, Int(now.timeIntervalSince(ronde)))
        return L10n.t("vangnet.wachter.gekeken", seconden)
    }

    /// Onder 100 wordt de Mac door de warmte afgeknepen. Bijgewerkt door de guardian-tik,
    /// niet in de body uitgelezen: `pmset -g therm` kost tot acht seconden.
    @Published private(set) var cpuSpeedLimit: Int?
```

Werk `cpuSpeedLimit` bij in `guardianTick()`, in de tak die al op thermische druk let:

```swift
        if thermal != .nominal {
            Task { @MainActor in self.cpuSpeedLimit = await ThermalWatch.cpuSpeedLimit() }
        } else {
            cpuSpeedLimit = nil
        }
```

> Heeft `RestartGuard` geen `shared` of geen publieke `laatsteRonde`, voeg dan een
> `static func laatsteRonde() -> Date?` toe die de bestaande toestand uitleest — de
> `ExitMarker`-structuur op regel ~100 heeft het veld al.

- [ ] **Stap 6: bouw en installeer**

Draai: `./build.sh --install`
Verwacht: bouwt en installeert. Open het paneel en controleer met het oog:

1. Uit → maan, `Slaapt normaal`, en de armlink eronder.
2. Zet aan → zon, aftelling, boog vult zichtbaar, kaart licht op.
3. Trek de lader eruit → de accumeter verliest zijn gedempte kleur.
4. Zet de accugrens tijdelijk op 80 in Instellingen → de rode zone wordt breed.
5. `sudo pmset -a disablesleep 1` in een terminal, wacht 30 s → de aandachtsrij staat
   **open** en rood.

- [ ] **Stap 7: commit**

```bash
git add Sources/DopamineCode/MenuView.swift Sources/DopamineCode/PaneelOnderdelen.swift Sources/DopamineCode/AppModel.swift
git commit -m "Deel het paneel opnieuw in rond één vraag

Het paneel beantwoordt nu één vraag — slaapt mijn Mac niet, en tot wanneer —
in plaats van vierentwintig elementen even luid naast elkaar te zetten.

Drie bedieningen voor de duur zijn er één geworden. De plus/min-knoppen en de
aparte Tot-rij met zijn zetten-knop schreven alle drie naar dezelfde
Prefs.autoOffMinutes; er is nu één ingang, en een waarde buiten de vijf krijgt
een eigen segment zodat de kiezer nooit leeg staat bij een duur die er wél is.

De wachter staat voor het eerst in de interface, met wanneer hij voor het
laatst keek. Dat is het enige dat geen enkele concurrent heeft en het stond
nergens.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

## Taak 7: wat naar Instellingen verhuist

**Bestanden:**
- Wijzigen: `Sources/DopamineCode/SettingsView.swift`

- [ ] **Stap 1: voeg de sectie toe aan het tabblad Algemeen**

Zet in `SettingsView.swift`, direct vóór `taalSection` (regel ~201):

```swift
            Section("alg.verlichting.titel") {
                if model.backlight.hasDirectControl {
                    if let niveau = model.backlightLevel {
                        Slider(value: Binding(get: { Double(niveau) },
                                              set: { model.setBacklightLevel(Float($0)) }),
                               in: 0...1) {
                            Text("alg.verlichting.sterkte")
                        }
                    }
                    if model.backlightSuppressed {
                        Text("menu.verlichting.schermuit").font(.caption).foregroundStyle(.orange)
                    }
                } else if !KeyboardBacklight.canPostEvents {
                    Text("menu.verlichting.geendirect").font(.caption).foregroundStyle(.secondary)
                    Button("menu.verlichting.instellingen") {
                        KeyboardBacklight.openAccessibilitySettings()
                    }
                }
            }

            Section("alg.gedrag.titel") {
                Text(model.behaviourSummary).font(.caption).foregroundStyle(.secondary)
            }
```

- [ ] **Stap 2: bouw en controleer met het oog**

Draai: `./build.sh --install`
Open Instellingen → Algemeen. Verwacht: de schuifregelaar staat er, en `behaviourSummary`
(de zin over scherm, vergrendelen en verlichting) ook.

- [ ] **Stap 3: controleer dat er geen zin verdwenen is**

```bash
git show HEAD~1:Sources/DopamineCode/MenuView.swift | grep -oE '"[a-z]+\.[a-z.]+"' | sort -u > /tmp/oud.txt
grep -rhoE '"[a-z]+\.[a-z.]+"' Sources/DopamineCode/MenuView.swift Sources/DopamineCode/SettingsView.swift | sort -u > /tmp/nieuw.txt
comm -23 /tmp/oud.txt /tmp/nieuw.txt
```

Verwacht: leeg, of alleen sleutels waarvan je wéét dat ze bewust vervallen zijn
(`menu.kop.titel`, `menu.duur.titel`, `menu.tot.titel`, `menu.tot.zetten`).

- [ ] **Stap 4: commit**

```bash
git add Sources/DopamineCode/SettingsView.swift
git commit -m "Verhuis de verlichtingsregelaar en de gedragszin naar Instellingen

Ze stonden in het paneel als eigen sectie met eigen scheidingslijn, dus even
zwaar als wakker houden zelf. De schuifregelaar verandert bijna nooit en de
gedragszin al helemaal niet, terwijl ze bij elke opening ruimte kostten boven
de dingen die wél per sessie verschillen.

De schakelaar zelf blijft in het paneel, als knop in de voet.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

## Taak 8: de vier talen

**Bestanden:**
- Wijzigen: `Resources/nl.lproj/Localizable.strings` (bron)
- Wijzigen: `Resources/{en,de,fr}.lproj/Localizable.strings`

- [ ] **Stap 1: voeg de nieuwe sleutels aan `nl` toe**

Onderaan `Resources/nl.lproj/Localizable.strings`:

```
/* --- Paneel: de statuskaart en de vangnetten --- */
"kaart.uit" = "Slaapt normaal";
"kaart.gearmd" = "Wacht op de klep";
"kaart.tot" = "wakker tot %@";
"kaart.eindigt" = "Eindigt om";
"vangnet.kop" = "Vangnetten";
"vangnet.legenda" = "nu · stopt bij";
"vangnet.wachter.interval" = "elke 30 s";
"vangnet.wachter.gekeken" = "vlag gelezen, %d s geleden";
"vangnet.wachter.nognietgekeken" = "nog niet gekeken";
"vangnet.afgeknepen" = "Je Mac draait op %d%% door de warmte";

/* --- Instellingen: wat uit het paneel verhuisd is --- */
"alg.verlichting.titel" = "Toetsenbordverlichting";
"alg.verlichting.sterkte" = "Sterkte";
"alg.gedrag.titel" = "Tijdens een sessie";
```

> Let op `%%` in `vangnet.afgeknepen`. Eén `%` gevolgd door een spatie is geen
> opmaakaanduiding maar het is wél waar `String(format:)` op struikelt zodra iemand de zin
> herschrijft. `verify.sh --talen` vergelijkt de aanduidingen tussen de talen, niet de
> geldigheid ervan.

- [ ] **Stap 2: voeg dezelfde sleutels aan `en`, `de` en `fr` toe**

`Resources/en.lproj/Localizable.strings`:

```
"kaart.uit" = "Sleeping normally";
"kaart.gearmd" = "Waiting for the lid";
"kaart.tot" = "awake until %@";
"kaart.eindigt" = "Ends at";
"vangnet.kop" = "Safety nets";
"vangnet.legenda" = "now · stops at";
"vangnet.wachter.interval" = "every 30 s";
"vangnet.wachter.gekeken" = "flag read, %d s ago";
"vangnet.wachter.nognietgekeken" = "has not looked yet";
"vangnet.afgeknepen" = "Your Mac is running at %d%% because of the heat";
"alg.verlichting.titel" = "Keyboard backlight";
"alg.verlichting.sterkte" = "Brightness";
"alg.gedrag.titel" = "During a session";
```

`Resources/de.lproj/Localizable.strings`:

```
"kaart.uit" = "Schläft normal";
"kaart.gearmd" = "Wartet auf den Deckel";
"kaart.tot" = "wach bis %@";
"kaart.eindigt" = "Endet um";
"vangnet.kop" = "Sicherungen";
"vangnet.legenda" = "jetzt · stoppt bei";
"vangnet.wachter.interval" = "alle 30 s";
"vangnet.wachter.gekeken" = "Flag gelesen, vor %d s";
"vangnet.wachter.nognietgekeken" = "hat noch nicht nachgesehen";
"vangnet.afgeknepen" = "Dein Mac läuft wegen der Wärme mit %d%%";
"alg.verlichting.titel" = "Tastaturbeleuchtung";
"alg.verlichting.sterkte" = "Helligkeit";
"alg.gedrag.titel" = "Während einer Sitzung";
```

`Resources/fr.lproj/Localizable.strings`:

```
"kaart.uit" = "Veille normale";
"kaart.gearmd" = "En attente de l'écran rabattu";
"kaart.tot" = "éveillé jusqu'à %@";
"kaart.eindigt" = "Se termine à";
"vangnet.kop" = "Filets de sécurité";
"vangnet.legenda" = "maintenant · s'arrête à";
"vangnet.wachter.interval" = "toutes les 30 s";
"vangnet.wachter.gekeken" = "drapeau lu, il y a %d s";
"vangnet.wachter.nognietgekeken" = "n'a pas encore regardé";
"vangnet.afgeknepen" = "Votre Mac tourne à %d%% à cause de la chaleur";
"alg.verlichting.titel" = "Rétroéclairage du clavier";
"alg.verlichting.sterkte" = "Intensité";
"alg.gedrag.titel" = "Pendant une session";
```

- [ ] **Stap 3: controleer de vier talen**

Draai: `./verify.sh --talen`
Verwacht: `✓ en: compleet.` / `✓ de: compleet.` / `✓ fr: compleet.` en geen enkele melding
over afwijkende invulwaarden.

- [ ] **Stap 4: verifieer de controle omgekeerd**

Haal `"kaart.uit"` uit `fr` weg, draai `./verify.sh --talen` opnieuw, en eis
`fr mist: kaart.uit`. Zet hem terug.

- [ ] **Stap 5: commit**

```bash
git add Resources
git commit -m "Vertaal de nieuwe paneelteksten naar vier talen

Alle sleutels symbolisch, en dezelfde invulwaarden in elke taal — String(format:)
leest die uit de vertáálde zin, dus één %d te weinig laat een waarde stil
verdwijnen en één te veel is een crash bij iemand die jouw taal niet spreekt.
./verify.sh --talen vergelijkt ze.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

## Taak 9: de proef in de vaste ronde

**Bestanden:**
- Wijzigen: `verify.sh`

- [ ] **Stap 1: roep `test_paneel` aan in de volledige ronde**

Zoek de plek waar `test_translations` en `test_tap` worden aangeroepen en zet `test_paneel`
ertussen — dezelfde plek in beide takken (de volledige ronde én `--report`).

```bash
grep -n 'test_translations\|test_tap\|test_update_check' verify.sh | grep -v '^[0-9]*:test_'
```

Voeg op elke gevonden regel `test_paneel` toe, in dezelfde volgorde als de sectienummers.

- [ ] **Stap 2: geef `--paneel` een eigen vlag**

Zoek het `case`-blok dat `--talen` en `--tap` afhandelt en voeg toe:

```bash
    --paneel) test_paneel; samenvatting; exit $? ;;
```

> Kijk hoe `--talen` het precies doet en volg dát patroon — de functienaam voor de
> samenvatting kan afwijken van `samenvatting`.

- [ ] **Stap 3: draai de hele ronde**

Draai: `./verify.sh --report`
Verwacht: sectie 13 verschijnt met drie groene regels, en de eindregel meldt geen fouten.

- [ ] **Stap 4: draai de losse vlag**

Draai: `./verify.sh --paneel`
Verwacht: alleen sectie 13, drie groene regels, exitcode 0.

- [ ] **Stap 5: commit**

```bash
git add verify.sh
git commit -m "Neem de paneelproeven op in de vaste ronde

Drie proeven die tegen de echte bronbestanden compileren, zoals de
versievergelijking dat al deed: de meters, de kaarttoestand en de rangorde van
waarschuwingen. Alle drie zijn omgekeerd geverifieerd door ze expres te laten
falen — de huisregel is dat een test met één uitkomst niets test.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

## Taak 10: de documentatie rechttrekken

**Bestanden:**
- Wijzigen: `CLAUDE.md`
- Wijzigen: `README.md`

- [ ] **Stap 1: corrigeer de twee tikken in `CLAUDE.md`**

Regel 40 zegt nu dat de guardian elke 20 seconden kijkt, in een alinea die over de vangnetten
gaat. Er zijn er twee en alleen de tweede is een vangnet. Vervang de zin door:

```markdown
**Vangnetten kijken naar de kernelvlag, niet naar de status van de app.** Er zijn twee tikken
en ze doen niet hetzelfde. De guardian in `AppModel` leest elke 20 seconden `SleepDisabled` en
beslist daarop, maar sterft mét de app. De `RestartGuard`-LaunchAgent draait elke 30 seconden
in `gui/$(getuid())` en overleeft een `SIGKILL` — dát is het vangnet. Elke controle op
`status == .on` stopt met kijken op het moment dat het ertoe doet.
```

- [ ] **Stap 2: voeg de schermafdruk aan `README.md` toe**

Maak de map en zet de afbeelding erin:

```bash
mkdir -p docs/afbeeldingen
```

Open het paneel met een lopende sessie en maak de afdruk met `⇧⌘4`, spatie, dan klikken op het
paneel. Sla op als `docs/afbeeldingen/paneel.png`.

Zet direct ónder de titel van `README.md`:

```markdown
<img src="docs/afbeeldingen/paneel.png" width="340" alt="Het paneel tijdens een sessie: de resterende tijd, en de drie vangnetten met hun grens ernaast.">
```

> Doe dit ná taak 6, niet ervoor — anders staat het oude paneel in je README en is dat het
> eerste wat iemand van de app ziet.

- [ ] **Stap 3: controleer dat de afbeelding meekomt in de tarball**

```bash
git add docs/afbeeldingen/paneel.png README.md CLAUDE.md
git status --short
```

Verwacht: alle drie staan er. `.gitignore` mag `docs/afbeeldingen` niet uitsluiten —
controleer met `git check-ignore -v docs/afbeeldingen/paneel.png` (verwacht: geen uitvoer).

- [ ] **Stap 4: commit**

```bash
git commit -m "Zet het paneel bovenaan de README en corrigeer de twee tikken

CLAUDE.md noemde één guardian van 20 seconden in een alinea over de
vangnetten. Er zijn er twee: de tik in AppModel (20 s) sterft mét de app, de
RestartGuard-LaunchAgent (30 s) overleeft een SIGKILL. Alleen de tweede is een
vangnet, en dat verschil is precies waar het om gaat.

De README had geen enkele afbeelding terwijl elke concurrent er een heeft. Wat
er nu staat is de aftelling naast drie vangnetten met hun grens ernaast — de
twee dingen die geen van de zes anderen kan tonen.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

## Zelfcontrole van dit plan

Nagelopen tegen de spec:

| Spec-onderdeel | Taak |
|---|---|
| Statuskaart, drie toestanden, boog | 2, 6 |
| Eén duurbediening | 6 |
| Drie meters met nu én grens | 1, 5, 6 |
| Warmte gestapeld, `CPU_Speed_Limit`-regel | 1, 5, 6 |
| Wachter met laatste ronde, 30 s | 6, 8 |
| Aandachtsrij, rangorde, rood klapt open | 3, 6 |
| Voet met verlichtingsknop | 6 |
| Wat naar Instellingen verhuist | 7 |
| Glas met terugval op 14 | 4 |
| Vier talen | 8 |
| Testen | 1, 2, 3, 8, 9 |

Drie dingen die tijdens het schrijven zijn rechtgezet en die de uitvoerder moet weten:

1. **`AccuMeter.grijptIn` moet `!aanDeLader` bevatten.** `AppModel` past de accugrens alleen
   toe achter `!battery.onAC` (regel 1422 en 1826). Zonder die voorwaarde tekent de meter een
   vangnet als scherp dat aan de lader niet kan afgaan.
2. **De grens is `<=` en niet `<`.** Op precies 15% grijpt hij in. De proef test die rand.
3. **Er zijn twee tikken.** 20 seconden in de app, 30 seconden in de LaunchAgent. Alleen de
   tweede hoort in het vangnettenblok, want alleen die overleeft het afschieten van de app.
