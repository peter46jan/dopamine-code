# Fase 1 — de kaart

*Feiten, geen oordeel. Vastgesteld 14 augustus 2026 op <machine>,
macOS 26.5.2, Mac17,2 / M5, tegen commit `f06f768`. Eén gebruiker: `<gebruiker>`,
lid van `admin`.*

**Uitgangssituatie zonder de app:** de gebruiker is beheerder en heeft `(ALL) ALL` in
sudoers. Hij kan met zijn wachtwoord alles al. Dat is geen delta.

---

## 1. De sudo-regel zonder wachtwoord

```
Sudoers entry: /private/etc/sudoers.d/dopamine-code-disablesleep
    RunAsUsers: root
    Options: !authenticate
    Commands:
        /usr/bin/pmset -a disablesleep 1
        /usr/bin/pmset -a disablesleep 0
```

| Vraag | Antwoord |
|---|---|
| Wildcard in de regel | **Nee.** Beide commando's volledig gespecificeerd, mét argumenten |
| Geldt voor | Eén user (`<gebruiker>`), niet een groep, niet `ALL` |
| Bestandsrechten | `-r--r----- root:wheel` (0440) |
| Map `/etc/sudoers.d` | `drwxr-xr-x root:wheel` — niet schrijfbaar voor de gebruiker |
| `/etc` | Symlink naar `private/etc`, `lrwxr-xr-x root:wheel` |
| Het toegestane binary | `/usr/bin/pmset`, `-rwxr-xr-x root:wheel`, **`restricted`** |
| SIP | **Enabled** — `pmset` is niet vervangbaar, ook niet door root |
| Omgeving | `env_reset` actief. `env_keep` bevat **geen** `PATH` en **geen** `DYLD_*` |

`env_keep` volledig: `BLOCKSIZE`, `COLORFGBG`, `COLORTERM`, `__CF_USER_TEXT_ENCODING`,
`CHARSET`, `LANG`, `LANGUAGE`, `LC_*`, `LINES`, `COLUMNS`, `LSCOLORS`, `SSH_AUTH_SOCK`,
`TZ`, `DISPLAY`, `XAUTHORIZATION`, `XAUTHORITY`, `EDITOR`, `VISUAL`, `HOME`, `MAIL`.

## 2. Het script dat als root draait

Twee routes, en dat onderscheid is het belangrijkste feit van deze audit.

### 2a. De hoofdroute — geen bestand op schijf

`SudoersGrant.runScriptAsRoot`, `SudoersGrant.swift:95-123`. De scripttekst zit als
base64 in de binary (`GrantScript.base64`, gegenereerd door `build.sh`) en gaat via een
pipe naar `bash -s`:

```swift
let command = "/bin/echo \(payload) | /usr/bin/base64 -d | "
    + "DOPAMINE_USER='\(user)' /bin/bash -s -- \(arguments)"
let result = Shell.runAsAdmin(command, prompt: prompt)
```

Er is dus geen pad op schijf dat tussen schrijven en uitvoeren verwisseld kan worden.
Twee invoercontroles vóór de interpolatie: payload op `^[A-Za-z0-9+/=]+$` (regel 100),
gebruikersnaam op `^[A-Za-z0-9._-]+$` (regel 105). Root wordt bereikt via
`Shell.runAsAdmin` → AppleScript `do shell script … with administrator privileges`,
dus mét wachtwoordvenster.

### 2b. De terugvalroute — wél een bestand op schijf

`SudoersGrant.manualCommand`, `SudoersGrant.swift:162-165`:

```swift
return "sudo /usr/bin/env DOPAMINE_USER=\(NSUserName()) /bin/bash '\(p)'"
```

waarbij `p` = `/Applications/Dopamine Code.app/Contents/Resources/grant.sh`.

Deze string wordt in het menubalk-paneel getoond, met de tekst "Of in Terminal:", en
staat ook in `README.md` en in de kop van `grant.sh` zelf.

### Rechten op dat pad

```
drwxrwxr-x root:admin          /Applications
drwxr-xr-x <gebruiker>:admin /Applications/Dopamine Code.app
drwxr-xr-x <gebruiker>:admin /Applications/Dopamine Code.app/Contents
drwxr-xr-x <gebruiker>:admin /Applications/Dopamine Code.app/Contents/Resources
-rwxr-xr-x <gebruiker>:admin /Applications/Dopamine Code.app/Contents/Resources/grant.sh
-rwxr-xr-x <gebruiker>:admin /Applications/Dopamine Code.app/Contents/MacOS/DopamineCode
-rwxr-xr-x <gebruiker>:admin /Applications/Dopamine Code.app/Contents/MacOS/dopamine
```

De hele bundel is eigendom van de gebruiker, niet van root. `build.sh --install` doet
`cp -R` als de gebruiker.

## 3. De socket

```
drwxr-x--- <gebruiker>:staff  /Users/<gebruiker>
drwx------ <gebruiker>:staff  /Users/<gebruiker>/Library
drwx------ <gebruiker>:staff  /Users/<gebruiker>/Library/Application Support
drwx------ <gebruiker>:staff  .../Application Support/Dopamine Code
srw------- <gebruiker>:staff  .../Application Support/Dopamine Code/beheer.sock
-rw-r--r-- <gebruiker>:staff  .../Application Support/Dopamine Code/vangnet-status.json
```

Geen Mach-service. Unix socket, in de homedir, niet in `/tmp` of `/var/run`.

Drie lagen op de toegang:
1. Map `0o700` (`ControlServer.swift:60`)
2. Socket `0o600` via `chmod` (regel 104)
3. `LOCAL_PEERCRED` met `cred.cr_uid == getuid()` (regels 205-221)

Protocol: `on` (met `--for`, `--until`, `--until-exit <pid>`), `off`, `status`.
Gedefinieerd in `Sources/Shared/ControlProtocol.swift`.

Netwerk: **nul** verbindingen, nul luisterende poorten (`lsof -i -P -a -p <pid>`).

## 4. launchd

```
-rw-r--r-- <gebruiker>:staff  ~/Library/LaunchAgents/com.peter46jan.dopaminecode.watchdog.plist
```

```
path    = /Users/<gebruiker>/Library/LaunchAgents/com.peter46jan.dopaminecode.watchdog.plist
program = /Applications/Dopamine Code.app/Contents/MacOS/DopamineCode
runs    = 465
```

- **Het is een Agent, geen Daemon.** Geladen in `gui/501`, draait als `<gebruiker>`.
- `/Library/LaunchDaemons/` bevat **niets** van dit project. Er is geen root-daemon.
- `StartInterval` 30 s, `RunAtLoad` true, `LimitLoadToSessionType` Aqua.
- Vóór het starten draait de wachter `codesign --verify --strict` op de bundel
  (`RestartGuard.swift:451`) — zonder `-R`, dus zonder requirement.
- Beslist mede op `afsluiting.json` in de 0700-map (nu afwezig; wordt alleen bij een
  nette afsluiting geschreven).

## 5. Het macOS-omhulsel

```
Identifier      = com.peter46jan.dopaminecode
TeamIdentifier  = <team-id>
Authority       = Apple Development: <naam> (<team-id>)
flags           = 0x10000(runtime)          ← hardened runtime aan
Timestamp       = 14 Aug 2026 at 16:21:21
Sealed Resources rules=13 files=3
```

- **Entitlements: geen.** `codesign --entitlements -` geeft geen plist terug.
- **Sandbox: uit** (volgt uit het ontbreken van `com.apple.security.app-sandbox`).
- **Library validation:** niet uitgezet — er is geen
  `com.apple.security.cs.disable-library-validation`, en hardened runtime staat aan.
- **Gatekeeper: `rejected`** — Development-certificaat, niet genotariseerd. In de
  praktijk wordt de app nooit beoordeeld omdat een lokaal gebouwde bundel geen
  `com.apple.quarantine` draagt.
- `dlopen` op privéframework `CoreBrightness` (`KeyboardBacklight.swift`) — pad te
  bepalen in fase 2.

## Wat ik niet kan zien

| | Waar het antwoord wél staat |
|---|---|
| Of de keychain-sleutel van het certificaat met een wachtwoord beschermd is | Keychain Access, met de hand |
| FileVault-status | `fdesetup status`, vereist beheerder |
| Branch protection op de repo | GitHub → Settings → Branches |
| Gedrag op een andere Mac of macOS-versie | Buiten bereik: één machine |
