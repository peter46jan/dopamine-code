# Dopamine Code — werkafspraken

macOS-menubalk-app die de Mac wakker houdt met de klep dicht. Swift, gebouwd met kale
`swiftc` uit `build.sh`. Geen Xcode-project, geen package manager, geen externe
afhankelijkheden.

## Twee repo's, en ze horen bij elkaar

| Repo | Wat | Zichtbaarheid |
|---|---|---|
| `peter46jan/dopamine-code` | de app | publiek, MIT |
| `peter46jan/homebrew-dopamine` | de Homebrew-tap, één formule | publiek — **moet**, want `brew tap` kloont anoniem |

De formule verwijst naar een tarball van een tag mét checksum. Lopen die uit de pas, dan
installeert `brew install` stilletjes een oude versie. `release.sh` werkt de formule
automatisch bij; `./verify.sh --tap` controleert het.

## Uitbrengen

```bash
./release.sh 1.1.0     # tagt, pusht, maakt een CONCEPT-release, werkt de tap bij
```

Publiceren is daarna een handmatige stap op GitHub, met opzet: een gepubliceerde release
stuurt meldingen en `releases/latest` gaat er meteen op wijzen. Een concept is onzichtbaar
voor de updatecontrole in de app.

Voor bouwen zonder git (Homebrew krijgt een tarball zonder `.git`): `DOPAMINE_VERSION=1.1.0
./build.sh`. Zonder dat noemt de app zichzelf `0.0.0`.

## Wat je nooit stuk moet maken

**De drie vangnetten zijn niet optioneel en niet uit te zetten.** `SleepDisabled` schakelt óók
de lege-accu- en oververhittingsnoodslaap van de kernel uit, via `userDisabledAllSleep` →
`checkSystemSleepAllowed()`. De tijdslimiet (7 u), de accugrens (15%) en de temperatuurbewaking
(`thermalState == .critical`) vervángen die. Een wijziging die er één van omzeilbaar maakt,
maakt de app gevaarlijk.

**Vangnetten kijken naar de kernelvlag, niet naar de status van de app.** Eén guardian leest
elke 20 seconden `SleepDisabled` en beslist daarop. Elke controle op `status == .on` stopt met
kijken op het moment dat het ertoe doet.

**De sudoers-regel is smal en dat is het hele punt.** Twee letterlijke commando's mét
argumenten. Zonder die argumenten geeft dezelfde regel het complete energiebeheer als root weg
(`man sudoers`). `verify.sh` probeert vier andere `pmset`-commando's en faalt als er één
doorheen komt.

**Niets anders draait als root.** De wachter is een LaunchAgent in `gui/$(getuid())` die
uitsluitend leest. De opdrachtregel linkt geen IOKit en kent `pmset` niet. `UpdateCheck` voert
niets uit en schrijft niets weg. Er staan controles op alle drie in `verify.sh`.

## Talen

Vier: `nl` (bron), `en`, `de`, `fr`. Symbolische sleutels (`menu.duur.titel`), niet de zin
zelf — een zin bijschaven mag geen vertaling breken. SwiftUI zoekt `Text("sleutel")` zelf op;
alles wat een gewone `String` moet zijn gaat via `L10n.t(...)`.

**Het logboek blijft Nederlands.** Dat is diagnostisch gereedschap; `verify.sh` en de audit
lezen die regels woordelijk terug.

Let op bij het toevoegen van teksten: veel zichtbare zinnen staan níet in de weergave maar
worden elders samengesteld — `AppModel.statusText`, `grantText`, `SessionTrigger`,
`ScheduleWindow.omschrijving`, `Diagnostics`, `RestartGuard.statusSentence`.

## Controleren

```bash
./verify.sh            # alles; twee stappen vragen je wachtwoord
./verify.sh --report   # alleen lezen, geen bijwerkingen
./verify.sh --talen    # vier talen: zelfde sleutels én zelfde invulwaarden
./verify.sh --tap      # wijst de Homebrew-formule naar de nieuwste tag?
./verify.sh --login    # klopt de voorkeur "start bij inloggen" met het systeem?
./verify.sh --killtest # schiet de app af tijdens een sessie; beëindigt je sessie
```

**Een test die maar één uitkomst kent, test niets.** Elke controle die hier is toegevoegd, is
omgekeerd geverifieerd door hem expres te laten falen. Doe dat ook bij nieuwe.

## Valkuilen die geld hebben gekost

- **BSD is geen GNU.** `sed -E` kent geen luie kwantor (`+?`); `sed -i` wil een leeg argument.
  Dit draait op macOS.
- **`grep -q` in een pijp onder `set -o pipefail`.** `grep -q` sluit de pijp bij de eerste
  match, de schrijver krijgt SIGPIPE en eindigt op 141, en dát is de uitkomst van de pijp. Haal
  de uitvoer één keer op en doorzoek hem met `case`.
- **`UserDefaults.standard` doorzoekt ook NSGlobalDomain.** Voor een voorkeur die alleen van
  deze app is (zoals `AppleLanguages`), lees het eigen domein met `persistentDomain(forName:)`.
- **`Bundle.preferredLocalizations(from:forPreferences:)` beschrijft niet wat de bundel doet.**
  Bij geen enkele treffer geeft die functie `en`; de echte bundel valt terug op
  `CFBundleDevelopmentRegion`. Gemeten, niet aangenomen.
- **`.strings`: dezelfde invulwaarden in elke taal.** `String(format:)` leest ze uit de
  vertáálde zin. Eén `%d` te weinig laat een waarde verdwijnen, één te veel is een crash bij
  iemand die jouw taal niet spreekt. `verify.sh --talen` vergelijkt ze.
- **Guards testen is niet het pad testen.** De eerste echte run van `release.sh` strandde op
  een regel die nooit was uitgevoerd, omdat de wachtposten altijd eerder afsloegen.

## Toon

Commit-berichten en documentatie leggen uit *waarom*, met wat er gemeten is. Claims in de
README worden nagetrokken voordat ze erin gaan — het is de tekst die een kritische lezer
natrekt, en een claim die niet houdt is erger dan geen claim. Wat niet bewezen is, staat onder
"Wat nog niet bewezen is" en niet weggelaten.

**Geen `Co-Authored-By` onder commits.** Geen enkele. GitHub maakt daar op de voorpagina
"peter46jan and claude" van, en dat is niet hoe deze repo eruit hoort te zien. De standaardregel
van Claude Code schrijft die regel voor; die geldt hier niet.
