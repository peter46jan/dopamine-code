# Security-audit — Dopamine Code

> **Opgelost 14 augustus 2026 (commit `9f349de`).** De twee KWETSBAAR-bevindingen
> (`f855c2d2` en `a03b4a9e`, met hun ketens) zijn gerepareerd en geïnstalleerd. Beide probes
> in `audit/tests/` slaan nu om van rood naar groen; de wachter haalde de echte app na een
> `kill -9` gewoon terug (61 s), dus de identiteitscontrole weigert wél een nepbundel maar
> niet de legitieme app. De losse bevindingen hieronder staan in hun oorspronkelijke staat
> beschreven; deze banner is de resolutie.

*Lokale rechtenescalatie-audit, macOS. Uitgevoerd 14 augustus 2026 tegen commit `f06f768`
op <machine> (macOS 26.5.2, M5). Dreigingsmodel: wat kan iets dat al als de
gebruiker draait — een gedownloade app, een script — via deze app bereiken dat het zonder
de app niet kon. Zeven subagents, waarvan één falsificatie en één ketening. Read-only op de
app; niets aan de applicatie, de sudoers-regel, de bundel of de installer gewijzigd.*

---

## 1. Samenvatting

| Status | Aantal |
|---|---|
| KWETSBAAR | 4 (2 losse, 2 ketens) |
| IN ORDE | 20 |
| NIET VAN TOEPASSING | 2 |
| NIET TE BEPALEN | 0 |

Bewijsklasse: 24 × `EMPIRISCH`, 2 × `STATISCH`, 0 × `AFWEZIGHEID`. Er is dus geen enkele
bevinding die alleen op "een grep gaf niets" rust — de kernvragen zijn tegen de draaiende
machine getoetst.

**De drie dingen die ertoe doen:**

1. **De wachtwoordloze root-route is dicht.** De enige nieuwe capaciteit die de app zonder
   wachtwoord aan een lokaal proces geeft, is `pmset -a disablesleep 0/1` — de slaapblokkade
   aan of uit, en niets anders. Empirisch: elke afwijkende `pmset`-aanroep wordt geweigerd,
   `pmset` zelf is onvervangbaar (SIP), en omgevingsmanipulatie (`PATH`, `DYLD_*`) heeft geen
   effect. Doel A, B, D langs deze weg: **niet bereikt.**

2. **Er is één echte bevinding, en die vraagt jouw wachtwoord.** De app zet een door jou
   schrijfbaar script (`grant.sh`) in de bundel én instrueert je op drie plekken om het als
   root te draaien. Een achtergrondproces kan de inhoud vooraf herschrijven. De escalatie
   voltooit pas als jíj het commando plakt en je wachtwoord typt — maar je doet dat in de
   veronderstelling dat je "een regel voor twee pmset-commando's" autoriseert.

3. **De handtekeningcontrole van de wachter controleert het zegel, niet de ondertekenaar.**
   `codesign --verify --strict` zonder `-R` laat een zelf ad-hoc getekende bundel door. De
   privilege-delta is nul (alles blijft als jou draaien), maar de controle bewaakt niet wat
   hij lijkt te bewaken — en dat is precies het soort controle waarop een latere fase gaat
   vertrouwen.

**Kernoordeel:** geen enkele route geeft *willekeurige* root zonder wachtwoord. De twee
ketens die de agents wél sluitend kregen, eindigen allebei bij een menselijke handeling
(jij typt je wachtwoord) of blijven binnen jouw eigen rechten (code als uid 501, die je zelf
al kon draaien). Dat is een wezenlijk andere klasse dan "malware wordt root terwijl je weg
bent".

## 2. Aanvalsdoelen

| Doel | Bereikt? | Door wie | Route |
|---|---|---|---|
| **A. Root-code-executie** | **Nee**, zonder wachtwoord. **Ja**, mét jouw wachtwoord via een misleide prompt | elk-lokaal-proces (schrijft), gebruiker (autoriseert) | De schrijfbare `grant.sh` + de door de app gedocumenteerde `sudo`-instructie. Keten 1 |
| **B. Root-bestandsschrijf** | **Nee** langs een automatisme. Ja als gevolg van A | idem | Volgt uit A; geen zelfstandige route |
| **C. Root-persistentie** | **Nee** | — | De wachter is een LaunchAgent (uid 501), geen Daemon. `NIET VAN TOEPASSING` |
| **D. Bredere sudo-rechten** | **Nee** | — | De NOPASSWD-regel dwingt exacte argumentmatch af; empirisch bevestigd |
| **E. Confused deputy via de socket** | **Nee** | — | De socket laat een same-uid proces alleen de blokkade zetten — precies wat het via `sudo -n` al kon. Delta nul |

De enige "ja" is doel A, en alleen via een menselijke stap. Geen enkel doel is bereikt door
code alleen, zonder jouw wachtwoord.

## 3. Ketens

**Keten 1 — schrijfbare `grant.sh` + gedocumenteerde root-uitvoer = code als root** ·
risico **midden** · `EMPIRISCH` · schakels: `f855c2d2`

1. Elk uid-501-proces schrijft ongehinderd in
   `/Applications/Dopamine Code.app/Contents/Resources/grant.sh` (`test -w` → writable,
   `-rwxr-xr-x <gebruiker>:admin`). Het vervangt de inhoud door een payload die als root
   alles mag: een bredere sudoers-drop-in, een root-LaunchDaemon, een setuid-shell.
2. De app toont op drie plekken de opdracht om precies dat bestand als root te draaien
   (`MenuView.swift:402`, `README.md:434`, de kop van `grant.sh` zelf). Die opdracht
   verschijnt juist wanneer er iets stuk is met de autorisatie — het moment dat je geneigd
   bent hem te gebruiken.
3. Jij plakt het commando en typt je wachtwoord, in de veronderstelling dat je twee
   pmset-commando's autoriseert. Root voert nu de payload uit.

De keten is niet-destructief getoetst op een kopie; de echte bundel is niet aangeraakt. De
menselijke stap is essentieel — dit is social engineering met een technische hefboom, geen
autonome exploit.

**Keten 2 — herlevende malware met de app-identiteit** · risico **midden** · `EMPIRISCH` ·
schakels: `a03b4a9e` + socket + wachter

Een uid-501-proces vervangt de app-binary door ad-hoc getekende malware, die de
wachter-handtekeningcontrole passeert (`a03b4a9e`), en laat de wachter die elke 30 seconden
herstarten. Elke schakel blijft uid 501 — **nul root-delta**. De som is vervelender dan de
delen (persistente, herlevende code die zich voordoet als de app), maar het overschrijdt
nooit jouw eigen rechten: je kon zelf al een LaunchAgent plaatsen.

**Keten 3 — willekeurige root zonder wachtwoord** · `NIET VAN TOEPASSING` · `EMPIRISCH`

Expliciet getoetst en **niet sluitend te krijgen.** Geen combinatie van de bevindingen
produceert willekeurige root zonder dat jij een wachtwoord typt. De redenen staan in het
record: de NOPASSWD-regel eist exacte argumentmatch, en geen enkel automatisme draait
`grant.sh` van schijf als root — de GUI-route pipet de ingebouwde base64, de wachter draait
de app-binary als uid 501.

## 4. De twee losse KWETSBAAR-bevindingen

### `f855c2d2` — de app stuurt je naar een schrijfbaar script, als root · risico midden

**Delta:** na installatie bestaat er een door jou schrijfbaar uitvoerbaar bestand op een vast
pad, plus een door de app op drie plekken gedocumenteerd "sudo-dit-bestand"-ritueel. Zonder
de app bestaat geen van beide.

**Bewijs:** `test -w '.../Resources/grant.sh'` als uid 501 → schrijfbaar. Instructie gelezen
op `MenuView.swift:402-405` (→ `manualCommand`, `SudoersGrant.swift:162`), `README.md:434`
en de kop van `grant.sh`. De agent vond bovendien dat `README.md:424-425` beweert dat de
leesbare kopie "alleen niet meer als root uitgevoerd" wordt — die claim is onjuist zolang
`manualCommand` en de README je naar `sudo <dat bestand>` sturen.

**Advies (kies één):** (a) verwijder de `manualCommand`-route en de README-`--remove`-regel
en verwijs alleen naar de base64-route; (b) laat ook de handmatige route de ingebouwde
payload naar de root-shell pipen; (c) installeer de kopie als `root:wheel 0555`. Corrigeer
in alle gevallen `README.md:424-425`.

### `a03b4a9e` — handtekeningcontrole zonder `-R` · risico laag

**Delta:** de door de app geleverde identiteitscontrole is te omzeilen — hij bewaakt niet de
identiteit die hij lijkt te bewaken. Privilege-delta nul (alles blijft uid 501).

**Bewijs:** de verificatie-agent reproduceerde de bypass op een kopie in de scratchmap:
`Fake.app` met `CFBundleExecutable=DopamineCode` en een bash-payload, ad-hoc getekend
(`codesign -s - --force --deep`, `TeamIdentifier=not set`). De exacte wachter-check
`codesign --verify --strict Fake.app` → **rc=0, komt erdoor.** Ter contrast:
`codesign --verify -R='anchor apple generic and certificate leaf[subject.OU]=<team-id>'`
→ rc=3, geweigerd.

**Advies:** vervang `RestartGuard.swift:451` door een `-R`-requirement op de eigen Team-ID
(`<team-id>`), zodat de wachter alleen een door de eigen identiteit getekende bundel start.

## 5. Correcties door de verificatie-agent

- **`grant.sh`-injectie via `DOPAMINE_USER`:** de oppervlak-agent schreef de verdediging toe
  aan de regex. De verificatie-agent toonde dat een newline-heredoc-injectie in werkelijkheid
  wordt geblokkeerd door de `id -u`-bestaanscontrole in `grant.sh`, niet door de regex. Status
  bleef `IN ORDE`, maar de **load-bearing verdediging is een andere regel dan gedacht** — dat
  is genoteerd bij de aannames (§7), want het betekent dat wie die `id -u`-check ooit
  weghaalt, de injectie heropent.
- **`a03b4a9e` `bereikbaar_door`:** de oppervlak-agent had "alleen-gebruiker"; gecorrigeerd
  naar "elk-lokaal-proces", want elk uid-501-proces kan de bundel schrijven.

## 6. Wat niet beoordeeld is

Geen enkele bevinding staat op `NIET TE BEPALEN` — de kernvragen waren empirisch haalbaar.
Buiten bereik van deze run, met waar het antwoord wél staat:

| Onbeoordeeld | Waar het antwoord staat |
|---|---|
| Is de keychain-sleutel van het Developer-certificaat met een wachtwoord beschermd | Keychain Access, lokaal, met de hand |
| FileVault-status | `fdesetup status`, vereist beheerder |
| Branch protection op `peter46jan/dopamine-code` | GitHub → Settings → Branches |
| Gedrag op een andere Mac of macOS-versie | Buiten bereik: één machine getest |

## 7. Aannames waarop het model rust

Wat is de láátste barrière voor welk doel — wat valt om bij een toekomstige wijziging?

- **Doel D (bredere root) hangt volledig aan de exacte argumentmatch in de sudoers-regel.**
  Wordt daar ooit een wildcard of een kale `/usr/bin/pmset` van gemaakt, dan valt de hele
  categorie open. `pmset` kan meerdere setting/value-paren op één regel (o.a.
  `destroyfvkeyonstandby`, die de FileVault-sleutel bij standby vernietigt).
- **Doel B via `grant.sh`-injectie wordt tegengehouden door de `id -u`-bestaanscontrole in
  `grant.sh`, niet door de gebruikersnaam-regex.** Wie die check weghaalt in de veronderstelling
  dat de regex volstaat, heropent de injectie.
- **De hele socket-veiligheid rust op de `LOCAL_PEERCRED`-uid-check** (`ControlServer.swift:205`).
  Die is nu correct, maar het is de enige barrière; de delta is toch al nul omdat een same-uid
  proces niets extra's krijgt.
- **De wachter vertrouwt op `codesign --verify` zonder identiteit** (`RestartGuard.swift:451`).
  Nu nul-delta, maar zodra iets belangrijkers op die controle gaat leunen, is `a03b4a9e` geen
  laagrisico meer.

## 8. Top 10 naar risico × moeite

| # | Bevinding | Risico | Moeite fix |
|---|---|---|---|
| 1 | `f855c2d2` schrijfbare `grant.sh` + gedocumenteerde root-uitvoer | midden | laag |
| 2 | Keten 1 (idem, als volledige route) | midden | laag — zelfde fix als #1 |
| 3 | `a03b4a9e` `codesign` zonder `-R` | laag | zeer laag — één regel |
| 4 | Keten 2 (herlevende uid-501-code) | midden* | laag — zelfde fix als #3 |
| 5 | `README.md:424-425` onjuiste claim over de leesbare kopie | laag | zeer laag |

*Keten 2's "midden" zit in de persistentie/vermomming, niet in privilege — de delta blijft
uid 501. De overige bevindingen zijn `IN ORDE` en staan niet in deze lijst.

Twee fixes dekken alles: (1) de handmatige route niet meer een schijfbestand als root laten
draaien (dekt #1, #2, #5), en (2) `-R` op de wachter-check (dekt #3, #4).

## 9. Beperkingen van deze run

- **`gitleaks`, `semgrep`, `trufflehog` niet geïnstalleerd.** Secrets handmatig gescand over
  alle 200 git-objecten (`audit/tools/secrets-handmatig.txt`) — schoon, maar zonder
  entropie-analyse. Niets daaruit scoort hoger dan `AFWEZIGHEID`.
- **Getest op de productiemachine van de gebruiker**, want er is geen isolatie. Alle
  empirische tests waren niet-destructief en teruggedraaid: de blokkade is na elke test op 0
  gecontroleerd, er staat geen markerbestand op `/private/var/root/`, en bundelmanipulatie
  gebeurde uitsluitend op kopieën in de scratchmap.
- **De code is grotendeels door een model geschreven en hier door modellen beoordeeld.** Wat
  de bouwer normaal vond, vindt de auditeur mogelijk ook normaal. Dit rapport hoort door een
  mens of een ander model tegengelezen te worden — met bijzondere aandacht voor `f855c2d2`,
  de enige bevinding met een reële weg naar root.
