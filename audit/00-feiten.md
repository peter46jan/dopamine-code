# Feiten — Dopamine Code

*Fase 0 van de diepgaande security-audit. Vastgesteld 14 augustus 2026 tegen commit
`f06f768`. Elke subagent leest dit eerst.*

---

## Vooraf: de opdracht past niet op dit project, en dat is belangrijk

De auditopdracht is geschreven voor een webapplicatie met een database: RLS, `SECURITY
DEFINER`-functies, views met `security_invoker`, storage-buckets, CORS, edge-cache, tenants,
JWT-rollen, RPC's vanaf de client.

**Niets daarvan bestaat hier.** Dit is een macOS-menubalkapp: 37 Swift-bestanden, 9.418
regels, gebouwd met een kale `swiftc`-aanroep. Geen database, geen server, geen netwerk-API,
geen gebruikersaccounts, geen sessies in de webzin, geen package manager.

Agent B (database/RLS) heeft in deze vorm geen onderwerp. De categorieën van agent C
(autorisatie), D (auth-levenscyclus) en G (rand/cache/headers) moeten opnieuw ingevuld
worden of vervallen. Zie `00-doelen.md` voor de herschaalde inzet.

**Er is wél een serieus aanvalsoppervlak, en het is van een ander soort:** een wachtwoordloze
sudoers-regel, een script dat als root draait, een unix socket die commando's aanneemt, en
een LaunchAgent die de app automatisch herstart. Het dreigingsmodel is lokale
rechtenescalatie, niet web.

---

## Vorm

| | |
|---|---|
| Soort | macOS-menubalkapp (`LSUIElement`), plus een tweede binary voor de opdrachtregel |
| Taal | Swift 5, `-parse-as-library`, doel `arm64-apple-macosx13.0` |
| Bouw | `./build.sh`, kale `swiftc`. Geen Xcode-project, geen SwiftPM-manifest |
| Afhankelijkheden | **Nul externe.** Alleen systeemframeworks: AppKit, SwiftUI, Foundation, Combine, IOKit, IOKit.ps, Network, ServiceManagement, CoreGraphics, UserNotifications, Carbon.HIToolbox, Darwin, Cocoa |
| Package manager | Geen. Geen `package.json`, geen `Package.swift`, geen lockfile |
| Ondertekening | Ad-hoc; de identiteit is de cdhash. Ten tijde van de audit was dit een `Apple Development`-certificaat met hardened runtime — zie de noot hieronder |
| Distributie | Geen binaire distributie. Iedereen bouwt zelf uit de bron, op zijn eigen Mac |
| Repo | `peter46jan/dopamine-code`, publiek, GitHub |

Het ontbreken van externe afhankelijkheden haalt de hele categorie toeleveringsketen
grotendeels weg: er is geen `npm audit`-oppervlak, geen postinstall-script, geen
transitieve afhankelijkheid. Wat overblijft is de bouwketen zelf (§ Toeleveringsketen).

## Het aanvalsoppervlak, in volgorde van gewicht

### 1. De wachtwoordloze sudoers-regel

```
/etc/sudoers.d/dopamine-code-disablesleep      -r--r----- root:wheel
```

Inhoud (`SudoersGrant.ruleText`, `SudoersGrant.swift:150`):

```
<gebruiker> ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 1, /usr/bin/pmset -a disablesleep 0
```

De twee commando's staan **volledig gespecificeerd, mét argumenten**. sudo eist dan een
exacte match op de hele commandoregel. Een kale `/usr/bin/pmset` zou wachtwoordloos
`pmset restoredefaults`, `pmset schedule wake …` en de rest van power management als root
hebben weggegeven; dat is expliciet vermeden en in `grant.sh` gedocumenteerd.

De regel is gekoppeld aan de **gebruiker**, niet aan een binary. Elk proces dat als deze
gebruiker draait kan hem gebruiken; sudo weet niet welke app hem aanroept.

### 2. Het script dat als root draait

`Resources/grant.sh`, 124 regels. Bereikt root via `Shell.runAsAdmin` (AppleScript
`do shell script … with administrator privileges`), aangeroepen uit
`SudoersGrant.runScriptAsRoot` (`SudoersGrant.swift:95`).

De aanroep, letterlijk (`SudoersGrant.swift:109`):

```swift
let command = "/bin/echo \(payload) | /usr/bin/base64 -d | "
    + "DOPAMINE_USER='\(user)' /bin/bash -s -- \(arguments)"
```

Twee dingen die hier bewust goed staan en die de agents moeten bevestigen, niet aannemen:

- **Geen tijdelijk bestand.** De scripttekst zit als base64 in de binary (`GrantScript.base64`,
  gegenereerd door `build.sh`) en gaat via een pipe naar `bash -s`. Er is dus geen pad op
  schijf dat tussen schrijven en uitvoeren verwisseld kan worden. Dit is de klassieke
  TOCTOU-route naar root en die lijkt hier afwezig — **te bevestigen door agent A**.
- **Invoercontrole vóór interpolatie.** De payload moet aan `^[A-Za-z0-9+/=]+$` voldoen
  (regel 100) en de gebruikersnaam aan `^[A-Za-z0-9._-]+$` (regel 105). Beide worden in een
  shellstring geïnterpoleerd, dus dit is de enige barrière tegen shell-injectie.

Er staat óók een leesbare kopie in de bundel op
`/Applications/Dopamine Code.app/Contents/Resources/grant.sh` (`-rwxr-xr-x`), bedoeld om te
kunnen lezen vóór autorisatie. **Vraag voor agent A:** wordt die kopie ooit uitgevoerd, of
alleen de ingebouwde? `/Applications` is `drwxrwxr-x root:admin` en dus schrijfbaar voor elke
beheerder zonder wachtwoord.

### 3. Het besturingskanaal (unix socket) — nieuw sinds vandaag

```
~/Library/Application Support/Dopamine Code/beheer.sock   srw------- <gebruiker>:staff
~/Library/Application Support/Dopamine Code/              drwx------ <gebruiker>:staff
```

`ControlServer.swift`. Neemt commando's aan van de `dopamine`-binary: `on` (met `--for`,
`--until`, `--until-exit`), `off`, `status`. Dit is de enige externe ingang van de app.

Drie lagen die er nu op zitten:

1. Map op `0o700` (`ControlServer.swift:60`)
2. Socket op `0o600` (`chmod`, regel 104)
3. `LOCAL_PEERCRED` met een uid-vergelijking tegen `getuid()` (regel 205–221)

Dit is **de minst gereviewde code in het project**: geschreven door een subagent, vandaag,
en de review van vanmiddag vond er geen bevindingen in — wat ook kan betekenen dat er niet
hard genoeg gekeken is.

### 4. De wachter (LaunchAgent)

```
~/Library/LaunchAgents/com.peter46jan.dopaminecode.watchdog.plist
```

Draait elke 30 seconden `"/Applications/Dopamine Code.app/Contents/MacOS/DopamineCode"
--vangnet`. Beslist of de app teruggehaald moet worden. Twee gegevens sturen die beslissing:

- `afsluiting.json` — de afsluitmarkering. Staat `blokkadeStondAan: false`, dan concludeert
  de wachter "iets anders houdt de Mac wakker" en doet **niets meer**, zonder tijdslimiet.
- `vangnet-status.json` (`-rw-r--r--`) — de eigen boekhouding van de wachter.

Beide staan in de 0700-map, dus alleen bereikbaar voor de gebruiker zelf — maar wél
schrijfbaar door **elk** proces dat als die gebruiker draait.

Vóór het starten draait de wachter `codesign --verify --strict` op de bundel
(`RestartGuard.swift:451`). **Let op:** dat controleert of het zegel intact is, niet wíe
getekend heeft. Een bundel met een geldige ad-hoc handtekening komt daar doorheen. Voor
identiteit is `-R` met een designated requirement nodig. Te beoordelen door agent A en R.

### 5. Overig

- **`Shell.run` / `Shell.runAsync`** — spawnt `/usr/bin/pmset`, `/usr/bin/codesign`,
  `/bin/launchctl`, `/usr/sbin/sysadminctl`. Argumenten als array, geen shell — behalve
  `runAsAdmin`, die wél een shellstring bouwt (zie punt 2).
- **`GlobalShortcut.swift`** — Carbon hotkey, registreert een systeembrede toetsencombinatie.
- **`KeyboardBacklight`** — laadt privésymbolen uit `CoreBrightness` via `dlopen`, en heeft
  een terugval die `CGEvent`-toetsaanslagen post (vraagt Toegankelijkheid; staat hier uit).
- **`NetworkMonitor`** — enige uitgaande verkeer: `http://captive.apple.com/hotspot-detect.html`,
  onversleuteld, vast pad, geen gebruikersinvoer. Bewust HTTP: het is de captive-portal-test.
- **`EventLog`** — `~/Library/Logs/Dopamine Code/`. Bevat accupercentages, klepstanden,
  tijdstippen, procesnamen en pid's van gekoppelde processen.

## Rechten en toestemmingen

| Toestemming | Status |
|---|---|
| Toegankelijkheid | **Uit** (`gebeurtenissen posten toegestaan: false`) |
| Meldingen | Gevraagd bij starten |
| Volledige schijftoegang | Niet gevraagd |
| Sandbox | **Geen.** Geen entitlements-bestand in de bundel |
| Hardened runtime | Aan |
| Login item | `SMAppService`, met LaunchAgent als terugval |

## Toeleveringsketen

Geen pakketten, dus de keten is: broncode → `swiftc` → `codesign` → `/Applications`.

- `build.sh` genereert `GrantScript.generated.swift` uit `Resources/grant.sh` en bakt die
  base64 in de binary. Wie `Resources/grant.sh` kan wijzigen vóór een build, bepaalt wat
  root uitvoert bij de volgende installatie.
- Ondertekening met een echte Developer-identiteit, niet ad-hoc. Bij terugval op ad-hoc
  waarschuwt `build.sh`.
- Geen CI. Geen branch protection gecontroleerd. Deploy is `./build.sh --install` met de hand.
- Repo is publiek sinds 15 augustus 2026; push gaat via SSH als `peter46jan`. Ten tijde van
  de audit was hij privé. Voor de bevindingen maakt dat niets uit — het dreigingsmodel is een
  lokaal proces en geen lezer van de broncode — maar wie de audit overdoet moet weten dat de
  aanvaller de bron nu gewoon kan lezen.
- **De ondertekening is sinds de audit veranderd van een `Apple Development`-certificaat naar
  ad-hoc.** Dat raakt één bevinding rechtstreeks: de identiteitscontrole van de wachter
  (`RestartGuard.bundleIdentityProblem`) toetst de bundel op schijf aan de designated
  requirement van de dráaiende binary. Bij een certificaat is dat een identiteitseis die een
  herbouw overleeft; bij ad-hoc is het een cdhash-eis die dat niet doet. De controle blijft
  even streng — een vreemde bundel wordt nog steeds geweigerd — maar hij weigert voortaan ook
  een nieuwere build van de app zelf, tot die build ook draait. `build.sh --install` bouwt en
  herstart in één handeling, dus die twee blijven in de pas.

## Wat ik niet kan zien

| | Waar het antwoord wél staat |
|---|---|
| Branch protection en wie naar `main` kan pushen | GitHub → Settings → Branches van `peter46jan/dopamine-code` |
| Of `Resources/grant.sh` ooit door iets anders dan `build.sh` gelezen wordt in de bundel | Statisch te bepalen door agent A |
| Of de Developer-certificaatsleutel met een wachtwoord in de keychain zit | Keychain Access, lokaal, met de hand |
| FileVault-status | `fdesetup status` — vereist beheerder |
| Of er ooit een build met ad-hoc handtekening geïnstalleerd is geweest | Logboek `Omgeving:`-regels van eerdere runs |
| Gedrag van de app op een andere Mac of andere macOS-versie | Buiten bereik: één machine, macOS 26.5.2, Mac17,2 / M5 |

## Beperkingen van deze run

- **`gitleaks`, `trufflehog` en `semgrep` zijn niet geïnstalleerd.** Vervangen door een
  handmatige patroonzoektocht over alle 200 objecten in de git-history
  (`audit/tools/secrets-handmatig.txt`). Dat is zwakker: vaste patronen, geen
  entropie-analyse, geen regelset. Geen enkele bevinding uit die scan mag daarom de status
  `IN ORDE` met klasse hoger dan `AFWEZIGHEID` krijgen.
- **Geen testomgeving.** Zie hieronder.

## Testomgeving

**Niet opgezet, en niet zinnig in de vorm die de opdracht beschrijft.** Er is geen database
om te seeden en geen rollensysteem om accounts voor aan te maken.

Wat er wél is en wat empirisch bewijs mogelijk maakt:

- Een tweede kopie van de app in `build/`, los van de geïnstalleerde
- `./verify.sh` met acht controles, waarvan twee een wachtwoord vragen
- `./verify.sh --killtest` — al gedraaid, en de wachter haalde de app in 61 s terug
- De `dopamine`-binary voor het aansturen van de draaiende app
- Een schrijfbare scratchmap buiten het project

**Gevolg:** empirisch bewijs is hier mogelijk, maar altijd tegen de **echte machine van de
gebruiker**. Elke agent die iets wil aantonen dat de vlag zet, de wachter beïnvloedt of de
sudoers-regel raakt, moet dat eerst in het rapport melden als voorgesteld experiment. Geen
enkele agent voert een test uit die de sudoers-regel wijzigt of `/Applications` aanraakt.
