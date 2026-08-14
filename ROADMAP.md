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

## Fase 1 — Sessies die zelf weten wanneer ze klaar zijn · ✅ gedaan 14 augustus 2026

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

**Gedaan.** Er is precies één ding bij gekomen dat iets nieuws beslist: een clausule
onderaan `releaseReason()`. Alles wat daarna volgt — `forceRelease`, `attemptRelease`, de
schrijf naar de vlag, `endSession` — is ongewijzigd, dus een proces dat verdwijnt neemt exact
dezelfde weg naar buiten als een verlopen timer. `ProcessWatch` houdt daarom géén sessiestand
bij: hij kent een pid, een starttijd en een naam, en zijn exit-melding stoot alleen de
guardian aan.

Die clausule staat *onder* de tijdslimiet, de accugrens en de warmtegrens. Een gekoppeld
proces dat vastloopt kan de timer dus niet uitstellen — dat is de reden dat de volgorde in
die functie niet vrijblijvend is.

PID-hergebruik gaat via de starttijd (seconden én microseconden) uit de kerneltabel. Twee
dingen bleken daarbij te kloppen en zijn gemeten: `sysctl` geeft voor een **dode** pid netto
`0` terug met `size == 0`, dus alleen op de exitcode controleren levert een genulde struct op
die als een levend proces leest — er wordt daarom ook op de grootte gecontroleerd. En de
snelle exit-melding vuurt óók meteen voor een pid die niet bestaat, waardoor een
niet-bestaande pid bij het starten geweigerd wordt in plaats van een sessie op te leveren die
één tik later alweer stopt.

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

**Gedaan.** Het werd een unix domain socket op
`~/Library/Application Support/Dopamine Code/beheer.sock`. XPC viel af omdat een
Mach-servicenaam een launchd-job vraagt, en die heeft deze app niet gegarandeerd — dan zou de
CLI een LaunchAgent verplicht maken en daarmee de keuze uit fase 2 vooruit beslissen. Een
bestand als postbus viel af omdat er geen antwoordkanaal is: `dopamine on` zou niet kunnen
melden dát de kernelschrijf mislukte, en een commando dat blijft liggen wordt later
uitgevoerd zonder de context waarin het gevraagd werd. Een socket bestaat alleen zolang de
app draait, dus "de app draait niet" is een gewone `connect()`-fout (exitcode 4) in plaats
van een gok. De uitleg met de gemeten cijfers staat in de README.

De CLI is een tweede binary in dezelfde bundel die alleen Foundation linkt. `verify.sh`
controleert nu met `otool -L` dat hij het IOKit-framework niet linkt, dat geen enkel bestand
van de opdrachtregel `pmset`, `IOKit` of de vlag aanraakt, en dat er in de hele codebase
precies één plek is die de slaapblokkade aanzet. Die drie controles zijn er niet voor deze
fase maar voor de volgende drie.

`status --json` leest de kernelvlag vers bij elk verzoek en zet hem naast het beeld van de
app als twee losse velden. Onenigheid daartussen is precies waar deze app voor bestaat;
samenvatten tot één "aan/uit" zou de enige interessante toestand onzichtbaar maken.
`verify.sh --report` toont beide onder elkaar, en de log-grep in `--after` blijft staan als
terugval — na een sessie is de app vaak herstart en weet hij niets meer.

---

## Fase 2 — Het gat dat er nu nog in zit · ✅ gedaan 14 augustus 2026

Dit staat vóór de triggers omdat het klein is en omdat het de enige manier is waarop deze
app nog steeds de fout kan maken die hij nooit mag maken.

`SIGTERM`, `SIGINT`, `SIGHUP` en het uitschakelen van het systeem zijn allemaal afgevangen;
die zetten de vlag terug. `SIGKILL` niet — dat kán niet afgevangen worden. Het proces is
weg, de vlag staat op 1, en niets ruimt hem op tot de app weer start. Zet je in die
toestand de klep dicht en loop je weg, dan blijft de Mac wakker tot de accu leeg is, met
alle drie de vangnetten dood.

Twee routes stonden tegenover elkaar:

| | Voordeel | Nadeel |
|---|---|---|
| **LaunchAgent die de app herstart** | Alles blijft in één proces; de app ruimt de vlag bij het starten al op | Herstart een app die de gebruiker misschien bewust gekilld heeft |
| **LaunchDaemon die alleen de vlag opruimt** | Doet precies één ding, kan niets anders kapotmaken | Tweede privileged component erbij, en die moet weten wanneer "geen app" normaal is |

**Klaar als:** `kill -9` op de app tijdens een lopende sessie leidt binnen een afgesproken
venster tot `SleepDisabled = 0`, aantoonbaar met `verify.sh`, zonder dat een normale
afsluiting via Stop een herstart uitlokt.

**Gedaan — het is de LaunchAgent geworden.** De doorslag gaf niet het aantal regels code maar
wie er mag beslissen. Een daemon die zelf de vlag opruimt is een tweede schrijver zonder enige
kennis van wat er loopt: hij zou een gewilde sessie kunnen beëindigen omdat de app net even
niet reageerde, en hij zou als root moeten draaien. De agent hergebruikt in plaats daarvan het
bestaande, bewezen pad — de app terugbrengen en `clearStaleFlagAtStartup()` zijn werk laten
doen — en er blijft precies één schrijver. `RestartGuard.swift` bevat dan ook geen enkele
aanroep die de vlag zet; `verify.sh` grept daar sinds fase 1 op.

Het is uitdrukkelijk géén `KeepAlive` op de app zelf. `KeepAlive` werkt alleen voor processen
die launchd zélf gestart heeft, en deze app wordt gestart door `open` (build.sh), door de
Finder of via `SMAppService`. Gemeten op deze Mac: de draaiende app zit in launchd als
`application.com.peter46jan.dopaminecode.…`, een LaunchServices-taak, dus `KeepAlive` had
niets herstart. De wachter is daarom een aparte taak die elke 30 seconden dezelfde app-binary
start met het argument `--vangnet`, kijkt, en weer verdwijnt.

**Het onderscheid tussen bewust afsluiten en wegvallen maakt de kernel zelf.** Elke bewuste
route — Stop, de signaalafhandeling, `willPowerOff` — zet de blokkade eerst terug. Een nette
afsluiting laat dus een 0 achter en `kill -9` een 1, en de wachter beslist op precies die
waarde plus de vraag of er nog een app draait. Voor het enige dubbelzinnige geval — bewust
afsluiten waarbij het terugzetten mislukte — laat de app een markering achter met tijdstip,
reden en de stand van de blokkade. Stond die netjes uit, dan komt de app nooit terug. Stond hij
nog aan, dan komt hij na twee minuten tóch terug: zonder app is er geen tijdslimiet, geen
accugrens en geen temperatuurbewaking, en dan staat het gat van deze fase gewoon door een
andere deur weer open.

Dat launchd zo'n agent met de klep dicht, het scherm vergrendeld en de Mac op accu ook echt
elke 30 seconden draait, is gemeten met precies de plist die de app schrijft: `run interval =
30 seconds`, drie runs in 75 seconden. Daarbij kwam één valkuil boven water die in de README
staat: in de oude ASCII-plistvorm bestaan geen booleans, dus `RunAtLoad` en `StartInterval`
worden strings en negeert launchd ze zonder één woord.

**Het beloofde venster is twee minuten.** Twee bevestigingen van 30 seconden uit elkaar zijn
nodig voordat er iets gebeurt — één waarneming zou middenin `build.sh --install` kunnen vallen,
dat de app afsluit, de bundel vervangt en hem opnieuw start. Daarmee is het venster ten hoogste
ongeveer 70 seconden plus de opruiming bij het starten.

**Aantoonbaar met `./verify.sh --killtest`.** Die staat bewust niet in de standaardronde: de kop
van dat script belooft dat het niets kapotmaakt, en deze test schiet een lopende sessie af. Hij
vraagt eerst om toestemming, weigert als de blokkade niet aan staat, en meet hoe lang het duurt
voor de kernel weer op 0 staat en de app terug is. De echte proef is dezelfde test met de klep
dicht en het scherm vergrendeld — of `open` daar werkt is nog niet gemeten en staat zolang in
de README onder "Wat nog niet bewezen is", mét de terugvalroute die er voor dat geval in zit.

---

## Fase 3 — Zelf weten wanneer het aan moet · ✅ gedaan 14 augustus 2026

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

**Gedaan.** De hele fase draaide om één keuze: **een trigger is een uitspraak, geen actor.**
`ScheduleWindow`, `AppTriggerWatch` en `LidArm` hebben geen eigen klok, geen kennis van
sessies en geen enkele aanraking met de vlag; ze leveren feiten. Er is precies één plek die
vanzelf aanzet — `AppModel.evaluateTriggers()`, aangeroepen vanuit de guardian-tik in de tak
waarin de kernelvlag aantoonbaar op 0 staat — en die gaat langs dezelfde `startSession` als
de schakelaar. De stopkant kreeg er níets bij: fase 3 voegde geen enkele clausule toe aan
`releaseReason()`.

De doorslaggevende afweging zit in de flankbewaking. Een trigger die *niveaugestuurd* is
("het is werkdag, het is 15:29, er loopt niets") zet twintig seconden later terug wat de
accugrens om 15:29 net had laten vallen — en dan zijn alle drie de vangnetten binnen één tik
waardeloos. Alle drie de triggers zijn daarom een flank. Het schema onthoudt persistent welk
venster het gehad heeft (`Prefs.scheduleLastArmedWindowStart`), en élke sessiestart binnen
dat venster vinkt het af, ook een handmatige — anders zou het schema een sessie die je om
10:05 zelf uitzette meteen terugzetten. De accu- en warmteweigering in `activate()` blijft
daarbij een tweede laag, geen vervanging.

**3.2 werd geen eigen mechanisme.** De app-trigger start een sessie mét de pid van de app als
proceskoppeling, dus het stoppen loopt door dezelfde clausule uit fase 1 als
`dopamine on --until-exit`. Daarmee is er geen respijt bij het verdwijnen van de app, en is
er geen tweede stoproute die de tijdslimiet kan missen. Een app die al draaide bij het
starten van Dopamine Code telt als gezien: inloggen met Xcode nog open levert geen sessie op
die niemand vroeg.

**3.1 werd expliciete arming, niet het Option-gebaar van Clamshell.** Een toetsstand aflezen
op het moment dat de klep dichtgaat vraagt Toegankelijkheid (staat op deze Mac uit,
`gebeurtenissen posten toegestaan: false`) en hangt af van een klepmelding die tot tien
seconden te laat kan komen — dan is "hield je Option ingedrukt?" niet meer te beantwoorden.
Vooraf zeggen wat je wilt kan nooit per ongeluk afgaan en kost geen enkel recht. Prijs
daarvan: het is een race met de slaap die begint zodra de klep dichtgaat, en of die gewonnen
wordt is op deze hardware niet te meten zonder één keer echt dicht te klappen. Dat staat in
de README onder "Wat nog niet bewezen is", mét de logregels om het aan af te lezen. De arming
staat bewust niet in `Prefs`: een gewapende stand die een herstart overleeft gaat uren later
af zonder dat iemand het nog verwacht.

**3.3 werd één venster met een dagenselectie**, standaard uit, standaard ma–vr 09:00–18:00,
en over middernacht heen toegestaan met de weekdag gekoppeld aan de begindag. De tijdslimiet
wint altijd van het venster: het venstereinde gaat als bovengrens mee in de eindtijd, en
`min(start + limiet, venstereinde)` is dus wat er staat. Loopt de timer af vóór 18:00, dan
begint het schema in dat venster niet opnieuw — anders zou "vanzelf stoppen na 4 uur" in de
praktijk niets betekenen. Een schema dat nooit open kan gaan (geen dag aangevinkt, begin en
eind gelijk) krijgt een WARN-regel in plaats van stil niets te doen, en
`verify.sh --report` drukt de schema-instelling af zodat "waarom deed hij vanochtend niks"
te beantwoorden is zonder de app te openen.

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
