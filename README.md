# Dopamine Code

*Heette tot 11 augustus 2026 "Wakker". Bundle-ID, sudoers-regel, logboek en instellingen
zijn meeverhuisd; de app migreert een oude installatie zelf bij de eerste start.*

Menubalk-app voor één Mac. Twee dingen: de Mac actief houden met de klep dicht en zonder
extern scherm, en de toetsenbordverlichting schakelen. Persoonlijk gereedschap, geen
distributie.

```
./build.sh --install     bouwen, ondertekenen, in /Applications zetten en starten
./verify.sh --report     status lezen, zonder wachtwoord en zonder bijwerkingen
./verify.sh              alle controles, inclusief de twee die je wachtwoord nodig hebben
./verify.sh --after      na een echte sessie: heeft de Mac tóch geslapen?
```

---

## Stap 0: de haalbaarheidscontrole, en wat die opleverde

De sudoers-route is veilig op deze Mac. Gemeten, niet aangenomen:

| Controle | Uitkomst |
|---|---|
| `profiles status -type enrollment` | `Enrolled via DEP: No` · `MDM enrollment: No` |
| `/Library/Managed Preferences/` | bestaat niet |
| `/var/db/ConfigurationProfiles/Settings` | alleen `com.apple.mdm.depnag.plist` (geen profiel) |
| Jamf / Intune agent | afwezig — Company Portal.app staat er los, zonder inschrijving |
| `/etc/sudoers.d/` | bestaat, leeg, `root:wheel 0755`, niet beheerd |
| Account | lid van `admin` |

Niets draait een sudoers-regel terug. De AppleScript-terugval uit de spec is daarom
terugval gebleven, geen hoofdroute — maar hij zit er wel in en wordt echt gebruikt zodra
`sudo -n` weigert.

---

## Wat er anders is dan in de spec, en waarom

Vijf punten. Alle vijf omdat meten iets anders opleverde dan de spec aannam.

### 1. Verificatie gaat via IOKit, niet via `pmset -g`

De spec schrijft: verifieer na elke schakeling met `pmset -g`. Op deze Mac drukt
`pmset -g` de regel `SleepDisabled` **helemaal niet af**:

```
pmset -g | grep -ci sleepdisabled   →  0
```

Dat is geen macOS 26-regressie. In Apple's `pmset.m` staat de printregel achter een
`if (key exists in dict)`, en de sleutel ontstaat pas nadat `disablesleep` één keer gezet
is. Op een verse Mac is de uitvoer dus stil — niet te onderscheiden van "0". Een app die
daarop vertrouwt, meldt eeuwig "uit". Precies die fout zit in het Sleepless-project
waar de spec naar verwijst.

De kernelwaarde zelf is er altijd wel:

```swift
IORegistryEntryCreateCFProperty(IOPMrootDomain, "SleepDisabled", …)   // CFBoolean
```

Geen root, geen entitlement, geen handtekening nodig. Dat is nu de bron van waarheid.

### 2. `pmset` geeft exitcode 0 terwijl het schrijven mislukte

Dit is de gevaarlijkste van de vijf, want hij faalt stil. `pmset` schrijft bij een
mislukte schrijfactie `'pmset' must be run as root...` of `failed to set the value` naar
**stdout** en geeft daarna alsnog exitcode 0 terug. Op exitcode alleen afgaan levert dus
een groen icoon bij een Mac die gewoon in slaap valt.

De app controleert daarom drie dingen: exitcode, de tekstuitvoer, én de kernelvlag.

### 3. De kernel neemt de waarde asynchroon over

`pmset` schrijft de vlag niet zelf. Het zet een preference en post een notificatie;
`powerd` pikt dat op en zet pas dán de IORegistry-eigenschap. Een `read()` direct na het
commando geeft de **oude** waarde terug. De verificatie is daarom een retry-ladder van
ruim vijf seconden, geen enkele controle.

### 4. De toggle-keycode voor de toetsenbordverlichting is dood

De spec noemt `CGEvent` met de illuminatie-keycodes. Gemeten op deze M5:

| | |
|---|---|
| Fysieke illuminatietoetsen op de functierij | **weg** (F1–F12 zijn helderheid, Mission Control, Spotlight, dictaat, DND, media) |
| `NX_KEYTYPE_ILLUMINATION_UP` (21) / `DOWN` (22) | **werken**, in stappen van exact 1/16 |
| `NX_KEYTYPE_ILLUMINATION_TOGGLE` (23) | **doet niets** — twee keer gepost, nul verandering |

De OS-handler leeft dus nog en staat los van de hardware, maar precies de keycode waar
een "toggle" op zou rusten is een no-op.

Daarom is de hoofdroute `CoreBrightness.KeyboardBrightnessClient`, dynamisch geladen. Dat
is nog steeds geen SMC-write — het is Apple's eigen helderheidsclient. Voordelen die het
meten opleverde: absolute waarden in plaats van stapjes, een echte uitlezing zodat aan/uit
een werkelijke toggle kan zijn, en **nul TCC-toestemming**. De CGEvent-route zit er als
terugval in en vraagt dan wel Toegankelijkheid.

Twee dingen die daarbij mis kunnen gaan en die de app afvangt:
- De omgevingslichtsensor trekt een handmatig gezette waarde binnen een minuut terug.
  Elke schrijfactie zet daarom eerst `enableAutoBrightness:false`.
- Zodra het scherm slaapt onderdrukt het systeem de verlichting. Schrijven lukt dan, lezen
  klopt, en er brandt niets. De app leest `isBacklightSuppressedOnKeyboard:` en zegt dat.

### 5. `disablesleep` schakelt óók de thermische noodslaap uit

Dit stond niet in de spec en is de belangrijkste toevoeging. `SleepDisabled` gaat in
`IOPMrootDomain` naar `userDisabledAllSleep`, wat `checkSystemSleepAllowed()` afkeurt —
dezelfde controle waar de **lege-batterij-** en **oververhittingsnoodslaap** van de kernel
doorheen gaan.

De vlag stopt dus niet alleen de klep. Hij zet het laatste vangnet van de kernel tegen
oververhitting uit. Jouw eigen regel ("klep dicht in een tas met een zware run eronder
niet") beschrijft precies het scenario waarin dat telt.

De batterijkant dekte de spec al af met de ondergrens. De thermische kant is nu de
software-vervanging van wat de vlag weghaalde: `ProcessInfo.thermalState` wordt bewaakt,
bij `serious` volgt een waarschuwing met geluid, bij `critical` gaat de vlag er
onmiddellijk af — zonder wachtwoordprompt, want die zou met de klep dicht achter het
inlogscherm blijven hangen.

---

## Hoe het in elkaar zit

| Bestand | Verantwoordelijkheid |
|---|---|
| `DopamineCodeApp.swift` | `MenuBarExtra` in `.window`-stijl, app-delegate, opstarten en afsluiten |
| `AppModel.swift` | de enige bron van waarheid; alles wordt door gebeurtenissen gedreven, niets wordt gepold |
| `SleepFlag.swift` | de kernelvlag lezen (IOKit) en schrijven (pmset), met verificatie |
| `SudoersGrant.swift` | de regel installeren, controleren, verwijderen |
| `DisplayControl.swift` | `pmset displaysleepnow` |
| `ScreenLock.swift` | `SACLockScreenImmediate` via `dlopen` |
| `KeyboardBacklight.swift` | CoreBrightness als hoofdroute, CGEvent als terugval |
| `ThermalWatch.swift` | vervangt de noodslaap die de vlag uitschakelt |
| `PowerSource.swift` | batterij en netstroom via IOKit-meldingen |
| `ClamshellMonitor.swift` | klepstand via `kIOPMMessageClamshellStateChange` |
| `NetworkMonitor.swift` | `NWPathMonitor` plus een captive-portal-controle |
| `LaunchAtLogin.swift` | `SMAppService`, met LaunchAgent als terugval |
| `EventLog.swift` | het logboek waarmee een sessie van vannacht morgen nog te beoordelen is |
| `ConflictWatch.swift` | merkt op dat Amphetamine meedraait |
| `ScreenState.swift` | of het inlogvenster voor staat, zodat er nooit een dialoog achter blijft hangen |
| `ProcessWatch.swift` | feiten over een proces: bestaat het nog, en is het nog hetzelfde proces |
| `RunningApps.swift` | de lijst draaiende apps voor de proceskiezer in het menu |
| `SessionTrigger.swift` | wie de lopende sessie gestart heeft |
| `ControlServer.swift` | luistert op de socket waar de `dopamine`-opdrachtregel mee praat |
| `Sources/Shared/ControlProtocol.swift` | het berichtformaat, meegecompileerd in de app én in de CLI |
| `Sources/dopamine/main.swift` | de opdrachtregel; schakelt zelf niets, vraagt de app om iets te doen |

### De centrale regel: vangnetten kijken naar de kernel, niet naar de app

Dit is de belangrijkste ontwerpbeslissing, en hij kwam uit een review die er drie
blockers omheen vond.

De eerste opzet liet de timer, de batterijgrens en de thermische beveiliging afgaan op de
eigen status van de app. Dat is precies verkeerd om. Als de app denkt dat hij uit staat
maar `SleepDisabled` staat nog op 1, dan slaapt de Mac nog steeds niet — en dát is het
moment waarop die vangnetten moeten werken. Elke controle op `status == .on` stopt met
kijken op het moment dat het ertoe doet.

Nu is er één guardian die elke twintig seconden de kernelvlag leest en daarop beslist:

- Vlag staat op 0 → alles rustig, status gelijktrekken.
- Vlag staat op 1 zonder actieve sessie → terugzetten, blijven proberen.
- Vlag staat op 1 met sessie → controleer deadline, batterij en warmte; grijp in als één
  van de drie dat vraagt.

Daaromheen hangen gebeurtenisbronnen (batterijmelding, thermische melding, klepmelding)
die de guardian meteen aanstoten in plaats van te wachten op de volgende tik.

Twee gevolgen daarvan zijn zichtbaar in de app:

- **Alles wat rechten nodig heeft, draait van de hoofdthread af.** De beheerdersprompt
  wacht op een mens en kan minuten duren; op de hoofdthread zou dat elke timer in de app
  bevriezen, inclusief de guardian zelf.
- **Nooit een dialoog achter het inlogscherm.** Meldingen wachten tot het scherm
  daadwerkelijk ontgrendeld is. Een modaal venster dat niemand kan wegklikken blokkeert
  de hoofdthread, en daarmee precies de code die de vlag moet terugzetten.

En als de vangnetten niets kúnnen: zonder de sudoers-regel is de vlag alleen met een
wachtwoord terug te zetten, en met de klep dicht kan niemand dat invullen. De app zegt dat
dan met zoveel woorden ("Vanzelf stoppen werkt nu niet") in plaats van te doen alsof alles
in orde is.

Een paar keuzes die verder niet vanzelf spreken:

- **`.window` en niet `.menu`.** Menustijl laat niet-tekstweergaven vallen en tekent zijn
  body niet opnieuw bij openen (FB13683957), waardoor een lopende teller onmogelijk is.
- **Klepdetectie via IOKit.** `NSWorkspace.willSleepNotification` kán niet vuren: het hele
  punt is dat het systeem niet slaapt. `screensDidSleepNotification` kan klep-dicht niet
  onderscheiden van scherm-uit door inactiviteit. `kIOPMMessageClamshellStateChange` vuurt
  op de sensor zelf. Er loopt een trage poll naast, omdat een gemiste melding tijdens een
  nachtelijke run het hele doel onderuithaalt.
- **Vergrendelen vóór scherm-uit.** Andersom licht het paneel weer op terwijl het
  inlogvenster wordt opgebouwd.
- **Scherm-uit wordt herhaald.** `displaysleepnow` is een verzoek, geen grendel. Met
  systeemslaap uit staat de Mac op vol vermogen en kan van alles het paneel weer aanzetten
  — onzichtbaar, urenlang. Zolang de klep dicht is wordt het verzoek elke 30 seconden
  herhaald.
- **Geluid, niet knipperen, als bevestiging.** De spec bood beide aan. Met de klep dicht
  is knipperende toetsenbordverlichting per definitie onzichtbaar; geluid niet.

---

## De opdrachtregel (`dopamine`)

Een build of een agent weet zelf precies wanneer hij begint en klaar is. Vooraf gokken hoe
lang je bezig bent is daarom het grofste vangnet dat er is, en de opdrachtregel vervangt dat
gokwerk door het echte antwoord:

```
dopamine on --until-exit $$      # blijf wakker zolang dit script draait
dopamine on --for 2h             # of gewoon een duur
dopamine on --until 18:00        # of een eindtijd
dopamine off
dopamine status --json
```

De binary staat in de bundel (`Contents/MacOS/dopamine`) en komt nooit vanzelf op je PATH.
`build.sh` en Instellingen → Diagnose tonen een `ln -sfn`-regel om te plakken — een app die
zelf iets in een systeemmap zet doet iets wat niemand gevraagd heeft.

**Hij schakelt niets zelf.** Hij linkt geen IOKit, kent `pmset` niet en start de app niet
op: hij opent een socket, stelt een vraag en drukt het antwoord af. Twee processen die
allebei de kernelvlag beheren is exact het conflict dat dit project Amphetamine verwijt, en
dat mag hier niet via een achterdeur alsnog ontstaan. `verify.sh` controleert dat met
`otool -L` en met een grep over de bronnen; loopt daar ooit iets in, dan valt de test om.

Elk verzoek loopt door dezelfde `startSession`/`stopSession` als de schakelaar in de
menubalk, en dus langs dezelfde weigeringen: een lege accu, een te warme Mac en een
ontbrekende wachtwoordvrijstelling. Een duur wordt geklemd op 5 minuten tot 24 uur, en het
antwoord meldt wat je écht kreeg. Een lopende sessie wordt nooit verlengd — een buildscript
dat in een lus `dopamine on` roept zou de tijdslimiet anders eindeloos vooruitschuiven en
het vangnet stilzwijgend uitzetten. Korter mag wel, en een koppeling zetten ook.

Exitcodes: `0` gelukt, `1` geweigerd door een vangnet, `2` verkeerd gebruik, `4` de app
draait niet. Met `--json` is de uitvoer altijd geldige JSON, ook bij een fout.

### Waarom een unix socket, en niet XPC of een bestand

- **XPC** vraagt een Mach-servicenaam, en die kun je alleen registreren via een launchd-job.
  Deze app heeft die niet gegarandeerd — `LaunchAtLogin` schrijft er hooguit één als
  terugval — dus XPC zou een LaunchAgent verplicht maken en daarmee een keuze vooruit
  beslissen die nog open moet blijven.
- **Een bestand als postbus** heeft geen antwoordkanaal. Dan kan `dopamine on` niet melden
  dát de kernelschrijf mislukte, en blijft een commando liggen dat later wordt uitgevoerd in
  een situatie waarin niemand erom vroeg.
- **Een socket** bestaat alleen zolang de app draait. "De app draait niet" is daarmee een
  gewone `connect()`-fout die eerlijk gemeld kan worden (exitcode 4) in plaats van gegokt.

De socket staat op `~/Library/Application Support/Dopamine Code/beheer.sock` — gemeten 74
bytes tegen een limiet van 103 in `sun_path`, en de app weigert netjes met een logregel als
het pad ooit langer wordt. De map is `0700`, de socket `0600`, en elke verbinding wordt via
`LOCAL_PEERCRED` gecontroleerd op je eigen uid.

Eén verrassing die de proefopstelling opleverde en die het vermelden waard is: op BSD — en
dus op macOS — **erft een geaccepteerde socket de `O_NONBLOCK` van de luisteraar**. Zonder
die vlag terug te zetten geeft de eerste `read()` meteen EAGAIN, meldt de app "verbinding
zonder leesbaar verzoek" en ziet de CLI een EPIPE: alles lijkt kapot terwijl er niets mis is.

### Stoppen als een proces klaar is

`--until-exit 4711` koppelt de sessie aan een procesnummer, en in het menubalk-paneel kun je
hetzelfde doen voor een draaiende app. Naast de pid wordt de **starttijd** van het proces
bewaard: een pid wordt hergebruikt, en zonder die starttijd zou een sessie blijven hangen aan
een pid die inmiddels van een heel ander programma is.

De koppeling is een extra reden om te stoppen, nooit een reden om door te gaan. De
tijdslimiet, de accugrens en de temperatuurbewaking staan er in `releaseReason()` bóven: een
proces dat vastloopt mag de timer niet uitstellen. Een proces-gebonden sessie eindigt dus bij
het proces óf bij de timer, wat het eerst komt.

Twee routes merken dat het proces weg is, en dat is met opzet: een `DispatchSource` op de
exit meldt het meteen, en de guardian-tik van 20 seconden kijkt zelf in de kerneltabel. De
poll is de garantie, de melding alleen de snelheid — precies de constructie die
`ClamshellMonitor` al gebruikt. Gemeten: die melding vuurt ook meteen voor een pid die niet
bestaat (daarom wordt een niet-bestaande pid bij het starten geweigerd) en nooit voor een
proces van een andere gebruiker (daarom staat er dan een regel in het logboek dat alleen de
poll bewaakt). Merkt de poll een exit die de melding niet gaf, dan komt daar een WARN-regel
bij: stille degradatie is nog steeds degradatie.

De koppeling overleeft geen herstart van de app en staat níet in de instellingen. Een sessie
die herleeft zonder de accu-, warmte- en toestemmingscontrole die hem gestart hebben, is
precies wat deze app niet moet doen.

---

## De sudoers-regel

Pad `/etc/sudoers.d/dopamine-code-disablesleep`, `root:wheel`, `0440`. Inhoud:

```
<gebruiker> ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 1, /usr/bin/pmset -a disablesleep 0
```

Dat de argumenten erbij staan, is het hele punt. `man sudoers` op deze Mac:

> *If no command line arguments are specified, the user may run the command with any
> arguments they choose. … If a Cmnd has associated command line arguments, the arguments
> in the Cmnd must match those given by the user on the command line.*

Zonder die argumenten zou de regel wachtwoordloos `pmset restoredefaults`,
`pmset -a hibernatemode 0` en `pmset schedule wake` toestaan — feitelijk het hele
energiebeheer als root. `verify.sh` test dat expliciet: het probeert vier andere
pmset-commando's en faalt als er ook maar één doorheen komt.

Bewust weggelaten:
- **Geen `sha256:`-digest.** `/usr/bin/pmset` staat op het verzegelde systeemvolume en kan
  niet vervangen worden; een digest zou alleen bij elke macOS-update breken.
- **Geen wildcard** (`disablesleep [01]`). Twee letterlijke commando's zijn strikt smaller.
- **Geen helper-script als sudo-doelwit.** Een door de gebruiker schrijfbaar script als
  root draaien is de klassieke sudoers-valkuil. De regel wijst rechtstreeks naar `pmset`.
- **`displaysleepnow` staat er niet in.** Dat heeft geen root nodig; het toevoegen zou het
  rechtenoppervlak vergroten zonder iets op te lossen.

### Twee dingen die de review hier vond

**De controle op de regel was te goedgelovig.** De app vroeg `sudo -n -l <commando>` en las
exitcode 0 als "regel actief". Dat is fout: `man sudo` zegt dat exitcode 0 betekent *dat het
commando is toegestaan*, niet dat het zonder wachtwoord mag. En `man sudoers` zegt dat één
enkele NOPASSWD-regel de `sudo -l`-opdracht zelf al wachtwoordloos maakt. Samen met de
standaard `%admin ALL=(ALL) ALL` van macOS betekent dat: zodra er ergens één NOPASSWD-regel
bestaat, slaagt de controle voor élk pmset-commando — ook als de Dopamine Code-regel er niet is.

Gevolg zou zijn: groen icoon, "regel actief", en dan grijpt geen enkel vangnet in als de
batterij leegloopt. Nu gebruikt de app `sudo -n -l -l`, wat volgens `man sudo` "de matchende
regel in uitgebreide vorm" toont, en eist hij expliciet `!authenticate` of `NOPASSWD` in de
uitvoer. Herkent hij het formaat niet, dan meldt hij "werkt niet" — fout gaan richting een
overbodige waarschuwing is oneindig veel beter dan fout gaan richting een Mac die nooit meer
slaapt.

**Het script draaide als root vanaf een pad dat jij kunt overschrijven.** `grant.sh` stond in
`Contents/Resources`, en die bundel staat in `/Applications` op jouw naam. Elk proces dat als
jij draait kon dat bestand aanpassen; jij typt vervolgens je beheerderswachtwoord voor een
dialoog die zegt "een sudoers-regel voor precies twee pmset-commando's", en er draait iets
heel anders als root. De handtekening vooraf controleren lost het niet op — root opent het
pad daarna opnieuw, dus het bestand kan er tussenin verwisseld worden.

Nu bakt `build.sh` de scripttekst in de binary en pipet de app die naar de root-shell. Er is
geen pad meer om te vervangen. De leesbare kopie blijft in de bundel staan, want die kun je
inzien en met de hand draaien — hij wordt alleen niet meer als root uitgevoerd.

De bestandsnaam heeft geen punt en eindigt niet op `~`. Dat is geen smaakkwestie: sudo
slaat zulke bestanden **stil** over — geen fout, geen logregel, alleen een regel die nooit
werkt. `grant.sh` weigert daarom te installeren als de naam dat patroon zou schenden,
controleert dat `/etc/sudoers` de map überhaupt inleest, valideert met `visudo -cf` vóór
installatie, en draait de regel terug als `visudo -c` daarna niet meer schoon parst.

Verwijderen:
```
sudo /Applications/Dopamine Code.app/Contents/Resources/grant.sh --remove
```

---

## Ondertekening

De app wordt ondertekend met de `Apple Development`-identiteit die al in je sleutelhanger
stond (geldig tot 27 december 2026). Dat is geen kosmetiek: TCC koppelt de
Toegankelijkheid-toestemming aan de designated requirement.

```
designated => identifier "com.peter46jan.dopaminecode" and anchor apple generic
              and certificate leaf[subject.CN] = "Apple Development: <naam> (<team-id>)"
```

Geen `cdhash`. Dat betekent dat de toestemming een herbouw overleeft — bij ad-hoc
ondertekenen verandert de cdhash bij elke build en moet je na elke herbouw opnieuw
toestemming geven. `build.sh` controleert dit en waarschuwt als het ooit terugvalt.

Verloopt het certificaat, dan blijft de handtekening geldig dankzij `--timestamp`. Een
vernieuwing levert dezelfde CN op, dus de requirement verandert niet en de toestemming
blijft staan.

**Dit wijkt bewust af van je spec**, die "geen code signing, geen Apple Developer-account"
zei. De reden: het certificaat stond er al, kost niets, en zonder handtekening zou je na
elke herbouw opnieuw Toegankelijkheid moeten toestaan. Wil je het toch zonder:

```
DOPAMINE_SIGN_IDENTITY=none ./build.sh --install
```

Dan valt `build.sh` terug op ad-hoc en waarschuwt hij dat de toestemming een herbouw niet
overleeft. Functioneel maakt het voor de hoofdfunctie niets uit — de sudoers-route en
CoreBrightness hebben geen handtekening nodig.

Gatekeeper speelt geen rol: een lokaal gebouwde app krijgt nooit een
`com.apple.quarantine`-attribuut. Het rechtsklik-Open-ritueel uit de spec is niet nodig.

---

## Testen

`./verify.sh` doet alles wat automatisch kan. Twee stappen vragen iets van je: je
wachtwoord voor de `disablesleep`-heen-en-terug, en toestemming voor de scherm-uit-test
(die vergrendelt je scherm, want je systeem staat op `immediate`).

Wat het script controleert:

1. Leest `/etc/sudoers` de map `sudoers.d` überhaupt in?
2. Zet `sudo pmset -a disablesleep 1` de kernelvlag écht op 1 op deze M5, en gaat
   `AppleClamshellCausesSleep` daarmee naar `false`? Daarna netjes terug naar 0.
3. Staat de regel op `root:wheel 0440`, parst `visudo -c` schoon, zijn precies de twee
   toegestane commando's wachtwoordloos en géén enkel ander pmset-commando?
4. Werkt `pmset displaysleepnow` zonder root?
5. Is `CoreBrightness.KeyboardBrightnessClient` bereikbaar?
6. Bestaat `SACLockScreenImmediate`, en staat de vergrendeling op `immediate`?

### De scenario's uit je spec die alleen met de hand kunnen

| Scenario | Hoe je het controleert |
|---|---|
| Klep dicht, geen extern scherm, uren wakker | Zet "Mac wakker houden" aan, klap dicht, laat een run draaien. Daarna `./verify.sh --after`: elke `Clamshell Sleep` in het pmset-log is een falen |
| Scherm was echt uit, batterij niet abnormaal weg | Batterijstand voor en na noteren; het logboek bevat het tijdstip van elke `displaysleepnow` |
| Wachtwoord bij openklappen | Klep openen, er moet om wachtwoord of Touch ID gevraagd worden |
| Wifi uit tijdens een sessie | Wifi uitzetten, even wachten, weer aan. Bij het openklappen verschijnt "verbinding was X minuten weg om HH:MM" |
| Vergeten uit te zetten | Zet de timer in de instellingen op 5 of 30 minuten, wacht die af, controleer met `./verify.sh --report` dat `SleepDisabled false` is |
| Batterij onder de grens | Grens tijdelijk op bijvoorbeeld 60% zetten, stekker eruit, wachten |
| Sudoers ontbreekt of is geblokkeerd | `sudo rm /etc/sudoers.d/dopamine-code-disablesleep`, dan schakelen: er hoort een beheerdersprompt te komen, geen stilte |
| App geforceerd afsluiten met de vlag aan | `kill -9 $(pgrep -x Dopamine Code)` terwijl "Mac wakker houden" aan staat, dan de app starten: de vlag hoort opgeruimd te worden |
| macOS-update | `./verify.sh` opnieuw draaien. Sudoers-regel en toestemming overleven een update meestal, maar de private symbolen uit `CoreBrightness` en `login.framework` zijn precies wat Apple ongemerkt kan wijzigen |

---

## Wat nog niet bewezen is

Eerlijk, want dit is precies de categorie die de spec noemt.

**Het zetten van de vlag is inmiddels wél bewezen op deze hardware.** Gemeten heen en
terug met de geïnstalleerde sudoers-regel:

```
vooraf:  SleepDisabled=false
→ sudo -n /usr/bin/pmset -a disablesleep 1   exitcode 0
   kernel volgde na 0,25 s
daarna:  SleepDisabled=true
pmset -g toont nu:  SleepDisabled  1      ← precies zoals de bronanalyse voorspelde
→ sudo -n /usr/bin/pmset -a disablesleep 0
hersteld: SleepDisabled=false
```

En bij dezelfde test kwam er ongepland bewijs dat twee vangnetten werken. Uit het logboek:

```
07:36:00 [WARN] Signaal 15 ontvangen met vlag aan — terugzetten naar 0.
07:37:43 [INFO] Blijf actief UIT (vlag stond aan zonder actieve sessie).
```

De eerste regel is de SIGTERM-afhandeling die de vlag opruimde toen `build.sh --install`
de app afsloot. De tweede is de guardian die mijn buiten de app om gezette vlag betrapte
en terugzette. Geen van beide was onderdeel van de test.

**De klep-dicht-run is inmiddels wél gedaan.** 2026-08-11, 17:58:26 → 19:43:44: één uur en
45 minuten met de klep dicht en geen extern scherm. De Mac heeft niet geslapen. Drie
onafhankelijke controles, omdat het filter in `verify.sh --after` diezelfde dag geschreven
is en zichzelf niet mag beoordelen:

```
sysctl kern.waketime  →  17:53:33   laatste kernel-wake, vóór de sessie begon
pmset -g log          →  laatste Sleep/Wake van de dag is 17:53:34, daarna niets
                         (831 Assertions-regels in het venster, nul slaapgebeurtenissen)
negatieve controle    →  dezelfde zoekopdracht vindt eerder op de dag wél vier
                         Clamshell Sleeps: 14:03:47, 14:22:59, 15:21:41, 17:03:55
```

De derde regel is de belangrijkste: de methode ziet aantoonbaar precies de faalmodus waarop
getest wordt, en ziet hem tijdens de sessie niet.

De broncode-keten die dit voorspelde klopt dus: `SleepDisabled` → `userDisabledAllSleep` →
`checkSystemSleepAllowed()` blokkeert de `privateSleepSystem(kIOPMSleepReasonClamshell)`
die in het pmset-log van deze Mac aantoonbaar gebruikt wordt. Langer dan 1 u 45 is niet
gemeten; het veto slijt niet, maar bewezen is bewezen tot daar.

**`AppleClamshellCausesSleep` is géén graadmeter.** Ik gebruikte hem eerst als bevestiging
dat de vlag werkte. Gemeten: hij stond `Yes` vóór het zetten, `Yes` erna, en `Yes` na het
terugzetten. Hij volgt het klep-/desktopmodusbeleid, niet het slaapveto — dat zit verderop
in `checkSystemSleepAllowed()`. Zowel de app als `verify.sh` zouden op die aanname een
werkend mechanisme als kapot hebben gerapporteerd.

**`pmset displaysleepnow` als gewone gebruiker werkt.** Uitgevoerd door de app zelf, die
als de ingelogde gebruiker draait zonder root en zonder entitlement — logboek 17:58:27 en
16:40:01, beide `Displayslaap geforceerd`, wat alleen gelogd wordt als zowel de exitcode
als de tekstuitvoer schoon zijn. Het privilege zit inderdaad als entitlement op de binary
van `pmset`, niet op de aanroeper. De sudoers-regel hoeft er niet voor verbreed te worden.

**Van de klepmelding is nog steeds niet vast te stellen óf hij vuurde.** De app reageerde
op 17:58:26 binnen dezelfde seconde op het dichtklappen, wat past bij de melding — maar de
poll van tien seconden kan toevallig samengevallen zijn, en `ClamshellMonitor.handle()`
logt niet wélke van de twee de verandering zag. Zolang dat zo is, is elke uitspraak
hierover een gok. (De code-notitie in `ClamshellMonitor.swift` zegt "nooit zien vuren"; een
werkdocument beweerde een tijd het tegenovergestelde. Geen van beide is onderbouwd.) Wil je
het weten: laat `handle()` de bron meelogboeken en klap één keer dicht.
Praktisch maakt het niets uit — de poll vangt het hoe dan ook op, met hooguit tien seconden
vertraging.

**`SMAppService` op een dev-cert-ondertekende, niet-genotariseerde bundel** is niet
uitgevoerd, want dat schrijft naar de background-task-database. De foutafhandeling maakt
nu wel onderscheid tussen "al geregistreerd" (geen fout), "door de gebruiker geweigerd"
(niet omheen werken) en een echte weigering (dan pas de LaunchAgent). Controleren kan met
`sfltool dumpbtm | grep -A12 dopamine`, zonder sudo.

**Amphetamine draait nog.** Zolang dat zo is, is niet vast te stellen welke van de twee de
Mac wakker houdt. De app merkt het op en biedt aan Amphetamine af te sluiten. Doe dat vóór
de eerste echte test, anders bewijst die niets.

---

## Als er iets vastloopt

De vlag is systeembreed en overleeft het afsluiten van de app en een herstart. Blijft hij
ooit hangen:

```
sudo pmset -a disablesleep 0
ioreg -r -d 1 -c IOPMrootDomain | grep SleepDisabled     # moet "No" zijn
```

De app ruimt dit bij elke start zelf op, vangt `SIGTERM`, `SIGINT` en `SIGHUP` af, en
reageert op `willPowerOffNotification`. Alleen `SIGKILL` is niet af te vangen — daarvoor
is de opruiming bij het starten er.

Het logboek staat in `~/Library/Logs/Dopamine Code/dopamine-code.log` en roteert vanzelf boven een
megabyte.
