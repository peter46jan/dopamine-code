# Ontwerp — het menubalkpaneel opnieuw

**Datum:** 17 augustus 2026 · **Status:** goedgekeurd, nog niet gebouwd

Het paneel wordt heringedeeld rond één vraag, en krijgt Liquid Glass. Dit document legt vast
wát er komt te staan en waaróm, zodat het implementatieplan er los van geschreven kan worden.

---

## Waarom

Het paneel is meegegroeid met de app en nooit opnieuw ingedeeld. Geteld in `MenuView.swift`:

| Wat | Nu |
|---|---|
| Bedieningen voor de sessieduur | **drie** — `adjustAutoOff(byMinutes:)`, vijf snelknoppen, `setAutoOffUntil` |
| Waarschuwingsvakken die kunnen stapelen | **zes** — gebroken belofte, vangnetten uit, toestemming, conflict, updatemededeling, update |
| Regels tekst in de kop | **vier** — `statusText`, `safetyNetLine`, `bindingLine`, `subtitle` |
| Tekstformaten | vrijwel alles `.caption` of `.caption2` in grijs |

Het gevolg is dat er geen rangorde is: de hoofdschakelaar en een voetnoot over de
toetsenbordverlichting wegen visueel even zwaar. Dat is op zichzelf al een reden, maar er is
een tweede die zwaarder telt.

**De wachter staat nergens in de interface.** Dat is precies het ding dat geen enkele
concurrent heeft — StayAwake ruimt alleen op bij de vólgende start, Sleepless en LidAwake
hebben niets. Het is het sterkste argument van deze app en het is onzichtbaar.

---

## Het uitgangspunt

Het paneel beantwoordt **één** vraag:

> Slaapt mijn Mac niet, en tot wanneer?

Alles wat die vraag beantwoordt staat groot. Alles wat hem niet beantwoordt is ondergeschikt of
verdwijnt naar Instellingen. Een tweede eis loopt daar doorheen: wat er staat moet ook
kloppen als iemand er een schermafdruk van maakt en die naast de concurrentie legt.

---

## Het paneel, van boven naar beneden

Breedte blijft **320 pt**. Alles hieronder zit in één `VStack`.

### 1. De statuskaart

Een glazen tegel, oplichtend in accentkleur zolang er een sessie loopt.

| Element | Inhoud | Bron |
|---|---|---|
| Boog | verstreken deel van de sessie, 0–100% | `sessionStart`, `deadline`, `now` |
| Icoon in de boog | zon (aan) of maan (uit) | `AppModel.status` |
| Aftelling | `3 u 12` — groot, `tabular-nums` | bestaand, uit `remainingText` |
| Onderregel | `wakker tot 21:40 · klep dicht` | `deadlineText`, `ClamshellMonitor` |
| Schakelaar | rechts, hangt aan `intendedOn` | ongewijzigd |

De schakelaar blijft aan `intendedOn` hangen en niet aan `status`. Die keuze staat al in de
code met de reden erbij en verandert hier niet.

#### De drie toestanden van de kaart

De kaart is de enige plek waar de toestand staat, dus hij moet ze alle drie kunnen tonen.

| Toestand | Boog | Grote regel | Onderregel |
|---|---|---|---|
| **Uit** | leeg, maan in het midden | `Slaapt normaal` | `Aanzetten zodra ik de klep dichtdoe ›` |
| **Gearmd** (`lidArm` staat) | pulseert, klep-icoon | `Wacht op de klep` | `nog 4 m 30 · intrekken` |
| **Aan** | verstreken deel, zon | `3 u 12` | `wakker tot 21:40 · klep dicht` |

Het armen uit `LidArm` verhuist hiermee de kaart in. Nu is het een losse tekstlink boven de
duurkiezer die er alleen staat als de app uit is — een regel die soms verschijnt en soms niet,
op een plek waar niets anders over de toestand gaat. In de uit-toestand is het juist het enige
zinnige aanbod, dus daar hoort het.

De uit-toestand is meteen de toestand die in de README-schermafdruk terechtkomt als er geen
sessie loopt. `Slaapt normaal` zegt in twee woorden dat de app niets stiekem aan heeft staan.

### 2. De duur — één bediening in plaats van drie

Een segmentkiezer met de vijf waarden die er nu al zijn: **30 m · 2 u · 4 u · 6 u · 8 u**
(`quickDurations`, ongewijzigd).

Daaronder één regel:

```
Eindigt om 21:40          stopt ook met Xcode ⌄
```

`21:40` is aanklikbaar en opent de tijdkiezer ter plekke. Dat vervangt zowel de plus/min-knoppen
als de aparte `Tot`-rij met zijn `zetten`-knop. Er blijft één ingang naar `Prefs.autoOffMinutes`.

Een waarde die niet in de vijf zit — via de tijdkiezer of via `dopamine on --for` — toont als
extra, geselecteerd segment. De kiezer liegt dus nooit over wat er staat.

### 3. De vangnetten — drie meters

Kop links `VANGNETTEN`, rechts `nu · stopt bij`. Die tweede helft is de hele reden dat deze
sectie er anders uit gaat zien: nu staat er `15%` naast een Mac op 84%, en dat leest als een
meting terwijl het een grens is.

| | Meter | Waarde | Bron |
|---|---|---|---|
| 🔋 | balk, rode zone links tot de grens, streep op de huidige stand | `84% · 15%` | `PowerSource`, `Prefs.batteryFloor` |
| 🌡 | **vier blokjes**, het vierde rood en leeg | `normaal · 4/4` | `ThermalWatch.Pressure` |
| 🛡 | kloppende stip | `vlag gelezen, 6 s geleden` · `elke 30 s` | `RestartGuard` `laatsteRonde` |

**De temperatuurmeter is gestapeld en de accumeter vloeiend, en dat is geen stijlkeuze.**
macOS geeft geen graden. Gemeten op 17 augustus 2026:

```
ProcessInfo.thermalState  →  nominal          vier namen, geen getal
pmset -g therm            →  "No thermal warning level has been recorded"
powermetrics              →  heeft graden, vereist root
SMC / IOHIDEventSystem    →  heeft graden, ongedocumenteerd, per chip anders
```

De schaal is dus vierstaps en niet continu, en de vorm van de meter hoort dat te zeggen. Vier
blokjes suggereren geen precisie die er niet is.

Zakt `CPU_Speed_Limit` onder 100, dan verschijnt er een regel onder de meters:

> 🌡 Je Mac draait op 62% door de warmte

Dat getal komt uit `ThermalWatch.cpuSpeedLimit()`, dat al bestaat. Het is bruikbaarder dan
graden: 85 °C zegt niets als je niet weet welke chip erin zit.

**Waarom drie meters en geen vier.** De tijdslimiet ís de sessieduur — `Prefs.autoOffMinutes`,
standaard 7 uur, hooguit 24 — en die staat al als aftelling én als boog in de statuskaart. Er
nog een balk voor maken is dezelfde informatie twee keer.

**Waarom 30 seconden en niet 20.** Er zijn er twee. De guardian-tik in `AppModel` draait elke
20 seconden en sterft mét de app. De `RestartGuard`-LaunchAgent draait elke 30 seconden en
overleeft een `SIGKILL` — dát is het vangnet, en dus staat dat getal er.

### 4. De aandachtsrij

Alle waarschuwingen worden één rij:

```
[2]  Vangnetten staan uit                                    ›
```

Uitklappen toont ze onder elkaar, elk met zijn eigen knoppen zoals nu. De rij toont de tekst
van de **ernstigste** melding en een telling van de rest. De volgorde ligt vast:

| # | Melding | Kleur | Waarom hier |
|---|---|---|---|
| 1 | `safetyNetsDisarmed` | rood | de vlag staat aan en er is niets meer dat hem terugzet |
| 2 | `sleepDuringSession` mét `sleepBrokeThePromise` | rood | de enige belofte van de app is niet gehouden |
| 3 | `conflict.sharesTheFlag` | rood | een andere app kan ons midden in een sessie ongedaan maken |
| 4 | `grantStatus != .granted` | oranje | zonder de regel werkt er niets |
| 5 | `conflict` zonder gedeelde vlag | oranje | maakt een meting waardeloos, niet gevaarlijk |
| 6 | `sleepDuringSession` zonder gebroken belofte | oranje | de Mac deed het goed, wij melden het |
| 7 | `outages` | grijs | verslag achteraf |
| 8 | update beschikbaar | grijs | geen probleem |
| 9 | eenmalige updatemededeling | grijs | eenmalig |

Rood klapt **altijd** uit en is nooit ingeklapt. Rood is de toestand waarin iemand iets moet
doen; die achter een driehoekje verstoppen is precies de fout die dit ontwerp moest oplossen.

### 5. De voet

```
☾ Nu slapen   ⌨          ⚙   Stop
```

`⌨` **schakelt de toetsenbordverlichting**, precies zoals de huidige `Toggle` dat doet — hij
opent geen venster. Aan is hij opgelicht, uit is hij gedempt, en op een Mac zonder directe
besturing (`hasDirectControl == false`, geen `canPostEvents`) is hij afwezig in plaats van
dood.

Teruggebracht van een sectie met schuifregelaar tot één knop, omdat het een gemak is naast het
doel van de app terwijl het nu een eigen sectie met een eigen scheidingslijn heeft — even zwaar
als wakker houden zelf. De schuifregelaar en de uitleg over Toegankelijkheid verhuizen naar
Instellingen.

---

## Wat er uit het paneel verdwijnt

| Wat | Waarheen | Waarom |
|---|---|---|
| Schuifregelaar toetsenbordverlichting | Instellingen | niet het doel van de app |
| `behaviourSummary` (scherm/vergrendelen/verlichting) | Instellingen | staat er nu bij elke opening, verandert bijna nooit |
| Accu, klep en netwerk als vaste regel | verschijnen alleen bij een probleem | 84 % op de lader is geen nieuws |
| `triggerLine` als vaste regel | in de aandachtsrij bij afwijking | idem |

Niets verdwijnt uit de app; alles blijft ergens bereikbaar.

---

## Glas

`.glassEffect()`, `GlassEffectContainer` en `.buttonStyle(.glass)` bestaan **vanaf macOS 26**.
`build.sh` staat op `DEPLOYMENT_TARGET="14.0"`.

**Besluit: 14.0 blijft.** Eén `ViewModifier` op één plek:

```swift
struct Glas: ViewModifier {
    var vorm: RoundedRectangle
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: vorm)
        } else {
            content.background(.ultraThinMaterial, in: vorm)
        }
    }
}
```

Niemand wordt weggestuurd in de maand dat de app onder de aandacht wordt gebracht. Op 14 en 15
ziet het er soberder uit; de indeling is dezelfde.

---

## Wat dit van de code vraagt

Dit is de opruiming die als tweede op de lijst stond. Hij volgt uit het ontwerp in plaats van
ernaast te staan.

1. **Eén ingang voor de duur.** De drie bestaande paden gaan door één functie.
2. **Vangnetten leveren paren.** Per vangnet een huidige waarde én een grens. De grenzen staan
   in `Prefs`, de waarden in `AppModel`; ze zijn alleen nog nooit naast elkaar gezet.
   `safetyNetLine` — één zin die drie gevallen moet dekken — vervalt.
3. **De wachter levert zijn laatste ronde.** `RestartGuard.laatsteRonde` bestaat al en wordt
   niet uitgelezen door het paneel.
4. **Waarschuwingen worden één gesorteerde lijst** met ernst en telling, in plaats van vier
   losse `if`-blokken die niets van elkaar weten.
5. **Alle zinnen op één plek.** `statusText`, `grantText`, `behaviourSummary`, `bindingLine`,
   `triggerLine` en `safetyNetLine` zitten nu verspreid door 2789 regels `AppModel.swift`.

---

## Testen

Vier van de vijf zijn met de hand, want ze gaan over wat je ziet.

| Wat | Hoe |
|---|---|
| Vier talen blijven gelijk | `./verify.sh --talen` — nieuwe sleutels in alle vier, zelfde invulwaarden |
| Meters kloppen met de werkelijkheid | accugrens tijdelijk op 80 zetten en kijken of de rode zone meebeweegt |
| Rood klapt nooit in | `./verify.sh --killtest` tijdens een sessie; de vlag blijft staan, de rij moet open zijn |
| Terugval op oudere macOS | bouwen met `-target arm64-apple-macosx14.0` en in een VM openen |
| Geen enkele zin verdwenen | elke tekst uit de oude `MenuView` staat in de nieuwe of in Instellingen |

Voor elke nieuwe controle in `verify.sh` geldt de bestaande regel: omgekeerd verifiëren door
hem expres te laten falen.

---

## Wat er niet in komt

- **Graden.** Alleen via privé-API's die per chip verschillen en tussen macOS-versies breken.
  Vier stappen, en we stoppen bij de vierde — dat is wat er gemeten kan worden.
- **Een onbeperkte duur.** `autoOffMinutes` loopt tot 24 uur en dat blijft zo. Een sessie
  zonder einde is een sessie zonder tijdslimiet.
- **Muisbeweging simuleren, scherm áán houden.** Stonden al onder "bewust niet" in
  `ROADMAP.md` en blijven daar.
