# Roadmap — Dopamine Code

*Opgesteld 14 augustus 2026, na een vergelijking met Clamshell, Amphetamine en Coca — de
drie apps die hetzelfde doen: klep dicht, geen extern scherm, Apple Silicon.*

---

## Het doel

**Van een schakelaar die je zelf omzet naar gereedschap dat zelf weet wanneer het aan moet
staan — zonder één gram van de veiligheid op te geven die er nu in zit.**

De app is nu veilig en eerlijk, maar volledig handmatig en volledig gesloten. Je moet eraan
denken hem aan te zetten, je moet vooraf gokken hoe lang je bezig bent, en niets buiten de
menubalk kan hem bedienen — terwijl je hem juist gebruikt voor builds en agents, die zelf
precies weten wanneer ze beginnen en klaar zijn.

De drie eigenschappen die niet mogen sneuvelen, ongeacht wat er bij komt:

1. **De vangnetten kijken naar de kernel, niet naar de app.** Elke nieuwe manier om een
   sessie te starten moet door dezelfde guardian heen. Een trigger die zijn eigen
   levensduur bijhoudt is een tweede waarheid, en dat is precies het defect waar dit
   ontwerp uit voortkwam.
2. **Geen enkele nieuwe route mag de tijdslimiet, de accugrens of de temperatuurbewaking
   omzeilen.** Ze vervangen de noodslaap die `SleepDisabled` uitzet; zonder hen is de app
   gevaarlijk, niet onhandig.
3. **Als het misgaat, hoor je het.** Wat er ook bij komt, het moet zichzelf kunnen betrappen
   en dat melden — dat is wat deze app onderscheidt van de drie concurrenten.

---

## Fase 0 — een bewering in de app klopte niet meer · ✅ gedaan 14 augustus 2026

`ConflictWatch.swift` zegt dat Amphetamine's assertie "dichtklappen niet overleeft". Dat is
achterhaald. Amphetamine doet closed-display mode wél zonder extern scherm, toetsenbord of
lader, en installeert daarvoor sinds 5.3 **Power Protect**:

```
/private/etc/sudoers.d/amphetamine_powerProtect
```

Dezelfde architectuur als onze eigen `/etc/sudoers.d/dopamine-code-disablesleep`.
Amphetamine is op precies dezelfde truc uitgekomen.

Dat maakt de conflictwaarschuwing *belangrijker*, niet minder belangrijk: twee apps met een
sudoers-regel die om dezelfde globale kernelvlag vechten is een echt probleem, en geen van
beide merkt het van de ander. Maar de tekst eronder moet kloppen.

**Klaar als:** de waarschuwing beschrijft het echte conflict (twee schrijvers op één
globale vlag) in plaats van een verschil dat niet meer bestaat, en `verify.sh --report`
noemt het als het bestand van Amphetamine in `/etc/sudoers.d/` staat.

**Gedaan.** `ConflictWatch` kijkt nu of `/etc/sudoers.d/amphetamine_powerProtect` bestaat
en onderscheidt twee gevallen. Draait Amphetamine zonder die regel, dan is het een
oranje melding: er gaat niets kapot, maar je kunt niet zien welke van de twee de Mac
wakker houdt, en dan zegt een test niets. Staat de regel er wél, dan is het rood — dan
schrijven ze naar dezelfde vlag en kan elk van de twee de ander ongedaan maken.

Alleen het bestáán van het bestand wordt gelezen, nooit de inhoud: `sudoers.d` is 0755
dus de namen zijn voor iedereen zichtbaar, terwijl de regels zelf root-only zijn. Dat is
precies genoeg, en het kost geen enkel recht. `verify.sh --report` somt op dezelfde manier
elke vreemde regel in `sudoers.d` op.

---

## Fase 1 — Sessies die zelf weten wanneer ze klaar zijn

De timer is nu het grofste vangnet dat er is: je gokt vooraf hoe lang je bezig bent en zit
er per definitie naast. Te kort en de Mac valt in slaap midden in je werk; te lang en hij
staat uren wakker voor niets. Voor het gebruik waar deze app voor bestaat — een build, een
render, een agent die een tijd loopt — is de exacte einddatum bekend: het moment dat het
proces stopt.

### 1.1 Stoppen als een proces klaar is

Een sessie kan aan een PID gekoppeld worden. Verdwijnt het proces, dan stopt de sessie.

- Koppelen kan vanuit de CLI (`--until-exit`) en vanuit het menu, waar de draaiende
  processen met een naam te kiezen zijn.
- Het menubalk-paneel toont waaraan de sessie hangt, niet alleen hoe lang hij nog loopt.
- **De tijdslimiet blijft het plafond.** Een proces-gebonden sessie eindigt bij het proces
  óf bij de timer, wat het eerst komt. Een proces dat vastloopt mag geen sessie zonder eind
  worden. `releaseReason()` behandelt een lopende sessie zonder eindtijd nu al als een
  fout en grijpt in; die regel moet blijven gelden.
- PID-hergebruik afvangen: bewaar naast de PID ook de starttijd van het proces, en
  beschouw een PID met een andere starttijd als verdwenen.

**Klaar als:** een sessie gekoppeld aan `sleep 60` stopt binnen één guardian-tick nadat dat
proces eindigt; een sessie gekoppeld aan een proces dat blijft hangen stopt alsnog op de
timer; en `kill -9` van het gekoppelde proces geeft hetzelfde resultaat als een nette exit.

### 1.2 Een CLI die dat aanstuurt

Zonder een manier om dit vanuit een script te doen is 1.1 een handmatige handeling met
extra stappen. Het punt is juist dat je buildscript het zelf regelt.

```
dopamine on --for 2h              # zoals de menubalk, maar vanaf de terminal
dopamine on --until 18:00
dopamine on --until-exit 4711     # of --until-exit $$ vanuit het script zelf
dopamine off
dopamine status --json            # voor scripts en voor verify.sh
```

- Eén binary in de bundel, met een symlink of een `brew`-loze installatiestap.
- Praat met de draaiende app (XPC of een unix socket), start hem niet zelf op. Twee
  processen die allebei de vlag beheren is exact het conflict dat we bij Amphetamine
  aanwijzen.
- `status --json` wordt de bron voor `verify.sh`, dat nu nog het logboek grept.

**Klaar als:** een buildscript zichzelf wakker kan houden met twee regels, `dopamine off`
tijdens een lopende sessie hetzelfde doet als de schakelaar, en `status --json` de
kernelvlag rapporteert en niet wat de app dénkt.

---

## Fase 2 — Het gat dat er nu nog in zit

Dit staat vóór de triggers omdat het klein is en omdat het de enige manier is waarop deze
app nog steeds de fout kan maken die hij nooit mag maken.

`SIGTERM`, `SIGINT`, `SIGHUP` en het uitschakelen van het systeem zijn allemaal afgevangen;
die zetten de vlag terug. `SIGKILL` niet — dat kán niet afgevangen worden. Het proces is
weg, de vlag staat op 1, en niets ruimt hem op tot de app weer start. Zet je in die
toestand de klep dicht en loop je weg, dan blijft de Mac wakker tot de accu leeg is, met
alle drie de vangnetten dood.

Twee routes, en de keuze is nog niet gemaakt:

| | Voordeel | Nadeel |
|---|---|---|
| **LaunchAgent die de app herstart** | Alles blijft in één proces; de app ruimt de vlag bij het starten al op | Herstart een app die de gebruiker misschien bewust gekilld heeft |
| **LaunchDaemon die alleen de vlag opruimt** | Doet precies één ding, kan niets anders kapotmaken | Tweede privileged component erbij, en die moet weten wanneer "geen app" normaal is |

De tweede is eerlijker tegenover het ontwerp — één ding doen en verder niets — maar vraagt
een regel die onderscheidt tussen "de app is net afgesloten" en "de app is weggevallen".

**Klaar als:** `kill -9` op de app tijdens een lopende sessie leidt binnen een afgesproken
venster tot `SleepDisabled = 0`, aantoonbaar met `verify.sh`, zonder dat een normale
afsluiting via Stop een herstart uitlokt.

---

## Fase 3 — Zelf weten wanneer het aan moet

Dit is de grootste functionele afstand tot Amphetamine, dat sessies kan starten op een
draaiende app, een schema, een actieve download, een wifi-netwerk, een aangesloten
USB- of Bluetooth-apparaat, de CPU-belasting en de accustand.

Niet alles daarvan is hier zinnig. Wat wél past bij het gebruik:

### 3.1 Arming bij het dichtklappen

Clamshell lost "vergeten aan te zetten" op met een Option-klep-gebaar: houd Option ingedrukt
terwijl je dichtklapt en de sessie begint. Nu slaapt de Mac gewoon als je het vergat, en dat
is de meest voorkomende manier waarop deze app je in de steek laat.

Aandachtspunt: het gebaar moet niet per ongeluk af kunnen gaan, en het moet zonder
Toegankelijkheid-toestemming kunnen — die staat op deze Mac uit (`gebeurtenissen posten
toegestaan: false`).

### 3.2 Aan zolang een app draait

Hetzelfde mechanisme als 1.1, maar omgekeerd: niet "stop als dit proces klaar is" maar
"start zodra deze app begint". Bouwt op de PID-bewaking uit fase 1.

### 3.3 Schema

Een venster waarin de app zichzelf aan mag zetten. Het simpelste geval — "elke werkdag van
09:00 tot 18:00" — dekt de meeste behoefte.

**Klaar als:** elke trigger een sessie start via dezelfde weg als de schakelaar, met
dezelfde timer, accugrens en temperatuurbewaking eromheen, en het menubalk-paneel zegt
wélke trigger de lopende sessie gestart heeft.

---

## Fase 4 — Ergonomie

Klein, los van elkaar te doen, en pas de moeite waard als de rest staat.

| | Wie heeft het | Wat het is |
|---|---|---|
| **Globale sneltoets** | Amphetamine, KeepingYouAwake | Aan/uit zonder de menubalk aan te klikken |
| **"Tot 18:00" naast "voor 4,5 uur"** | Amphetamine | Je denkt vaker in eindtijd dan in duur. De CLI krijgt dit in 1.2 al; de UI loopt dan achter |
| **Aftelling in de menubalk** | Amphetamine | Resterende tijd zonder het paneel te openen |
| **Sessiegeschiedenis in de app** | Amphetamine (statistieken) | Het logboek heeft alles al; dit is er een leesbare weergave van |
| **Focus Filters** | Coca | Sessie volgt een macOS-focus |

---

## Wat er bewust niet in komt

- **Muisbeweging simuleren.** Een andere app met een andere bedoeling: idle-detectie van
  bedrijfssoftware om de tuin leiden. Deze app houdt de Mac wakker; hij doet niet alsof je
  er bent.
- **Het scherm áán houden tijdens een sessie.** Amphetamine kan dat voor presentaties en
  mediaservers. Hier is het tegenovergestelde het punt: het interne scherm moet uit onder
  een dichte klep, en `startDisplayReassert` bestaat om dat af te dwingen.
- **Meerdere Macs, licenties, distributie.** Persoonlijk gereedschap. Zodra er een tweede
  machine bij komt gelden er andere aannames — de haalbaarheidscontrole uit stap 0 van de
  README geldt voor déze Mac.

---

## Volgorde en waarom

1. **Fase 1** eerst: het vervangt het grofste vangnet door iets exacts en het is de reden
   dat je de app gebruikt.
2. **Fase 2** daarna omdat het klein is en het laatste echte gat dicht. Het mag naar voren
   als je hem ooit hebt moeten `kill -9`'en.
3. **Fase 3** is het meeste werk en levert het meeste gemak.
4. **Fase 4** wanneer het uitkomt.

Elke fase is een eindpunt op zich. Na fase 1 is de app af zonder fase 2; na fase 2 zonder
fase 3. Er blijft nooit iets half staan.

## Wat we niet moeten weggeven

De vergelijking maakte duidelijk waar deze app als enige iets doet. Bij alles hierboven
geldt: als een functie hiermee in conflict komt, wint deze lijst.

- **Merken dat de Mac tóch geslapen heeft.** `SleepWatch` vergelijkt de kloktijd en meldt
  dat de belofte niet gehouden is. Geen van de drie concurrenten adverteert iets in die
  richting — ze beweren dat het werkt en laten het daarbij.
- **De thermische vervanging.** Clamshell noemt alleen een accudrempel. Wij zijn de enige
  die benoemt dat `disablesleep` óók de noodslaap bij oververhitting uitzet, en die
  teruglegt.
- **De guardian die naar de kernel kijkt en niet naar de eigen status.**
- **Instellingen die een herstart overleven.** Clamshell zegt met zoveel woorden dat die
  van hen dat niet doen.
