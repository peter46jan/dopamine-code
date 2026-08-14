# Kroonjuwelen en aanvalsdoelen — Dopamine Code

*Fase 0.5. Een checklist vindt wat op de lijst staat; doelen vinden wat ertussenin valt.*

---

## Kroonjuwelen

Afgeleid uit wat de app werkelijk in handen heeft, niet uit aannames.

| # | Juweel | Waarom het de moeite waard is |
|---|---|---|
| K1 | **De wachtwoordloze route naar root** | `/etc/sudoers.d/dopamine-code-disablesleep` plus het script dat als root draait. Wie hier een gaatje vindt, gaat van "als jij" naar "als root" — de enige echte escalatie op deze Mac |
| K2 | **De bouwketen** | `Resources/grant.sh` wordt base64 in de binary gebakken en later door root uitgevoerd. Wie dat bestand vóór een build wijzigt, bepaalt wat root doet — met een handtekening eromheen |
| K3 | **De slaapblokkade zelf** | Eén globale kernelwaarde. Aan houden = accu leeg, Mac heet in een tas. Uit houden = de app doet niet waarvoor hij bestaat |
| K4 | **De vangnetten** | Timer, accugrens, temperatuurbewaking. Ze vervangen de kernel-noodslaap die de blokkade uitzet. Vallen ze om terwijl de blokkade staat, dan is er niets meer |
| K5 | **De wachter** | Start elke 30 s automatisch een binary op een vast pad. Dat is een terugkerende uitvoeringsroute die niemand aanklikt |
| K6 | **Het logboek** | Accustanden, klepstanden, tijdstippen, procesnamen en pid's. Een gedetailleerde aanwezigheidsregistratie: wanneer je werkt, wanneer je wegloopt, wat je draait |

K3 en K6 zijn secundair — vervelend, niet ernstig. **K1, K2, K4 en K5 zijn waar deze audit
zijn tijd aan hoort te besteden.**

## Aanvalsdoelen

Acht doelen, elk in de vorm "bereik X als principal Y", elk toetsbaar. De principals staan
in `00-rollenmatrix.md`.

---

**D1 — Voer code uit als root, als proces dat draait als de gebruiker (P3)**
Het hoofddoel. Twee bekende ingangen: de shellstring in `SudoersGrant.swift:109` waarin
`payload` en `user` geïnterpoleerd worden, en de sudoers-regel zelf. Slaagt dit, dan is al
het andere bijzaak.
→ *Agents A, E, R*

**D2 — Krijg een blijvende regel die méér toestaat dan de twee pmset-commando's (P3/P4)**
Kan `grant.sh` gestuurd worden om een ruimere regel te schrijven, via `DOPAMINE_USER`, via
argumenten, via een gebruikersnaam met sudoers-metatekens, of via een tweede bestand in
`sudoers.d`? Bevestig ook dat de argumentmatch echt exact is: probeer of er een
`pmset`-aanroep bestaat die aan de regel voldoet en méér doet dan de blokkade zetten.
→ *Agents A, B, E, R*

**D3 — Laat de wachter een bundel starten die niet van Dopamine Code is (P2/P3)**
`/Applications` is `drwxrwxr-x root:admin`. De wachter draait `codesign --verify --strict`,
wat het zegel controleert en niet de ondertekenaar. Vervang de bundel door een eigen,
ad-hoc ondertekende kopie en kijk of de wachter hem elke 30 seconden start. Toets dit in de
scratchmap, **nooit op `/Applications`**.
→ *Agents A, R*

**D4 — Zet de vangnetten uit terwijl de blokkade aan staat (P3)**
Kan een proces als jij de timer op oneindig zetten, de accugrens op nul, of de
temperatuurbewaking laten zwijgen — via `defaults write`, via de socket, of via de
klemwaarden heen? Doel is niet "de instelling veranderen" (dat mag) maar "de blokkade
blijft staan en niets haalt hem meer weg".
→ *Agents C, F, R*

**D5 — Misleid de wachter zodat hij de app niet meer terughaalt (P3)**
Schrijf `afsluiting.json` met `blokkadeStondAan: false`. De wachter concludeert dan "iets
anders houdt de Mac wakker" en stopt — zonder tijdslimiet op die conclusie. Combineer met
een `kill -9` en de Mac blijft wakker met geen enkel vangnet. Dit is de aanvalskant van de
bug die vanmiddag aan de schrijfkant is gerepareerd.
→ *Agents F, H, R*

**D6 — Bereik iets via het besturingskanaal als iets dat níét de gebruiker is (P0/P1/P2)**
De socket staat op 0600 in een 0700-map, met een `LOCAL_PEERCRED`-uid-controle. Drie lagen.
Toets ze los van elkaar: valt de uid-controle om als de rechten kloppen, en andersom. Toets
ook het protocol zelf: een misvormd bericht, een enorm bericht, een halve verbinding, veel
verbindingen tegelijk. Deze code is één dag oud.
→ *Agents E, G, R*

**D7 — Laat de app zelf de vlag laten staan zonder dat iemand het merkt (P3)**
Niet via rechten maar via logica: een toestand waarin de app denkt dat er niets loopt terwijl
de kernelvlag op 1 staat en niets hem weghaalt. Kandidaten: een mislukte release gevolgd
door een backoff, de proceskoppeling, het schemavenster, een race tussen de socket en de
guardian-tik. Drie van de vier bugs van vanmiddag zaten precies hier.
→ *Agents F, R*

**D8 — Lees uit het logboek wanneer de gebruiker weg is (P1/P3)**
`~/Library/Logs/Dopamine Code/`. Bevat elke vijf minuten accustand, klepstand en
temperatuur, plus procesnamen en pid's. Bepaal wie erbij kan en of daar iets in staat dat
niet zichtbaar hoort te zijn. Toets ook of gevoelige tekst uit de socket of de CLI ongefilterd
in het logboek belandt.
→ *Agents H, A*

---

## Verdeling over de agents

| Agent | Onderwerp na herschaling | Doelen |
|---|---|---|
| **A** | Secrets, ondertekening, bouwketen, de root-route | D1, D2, D3, D8 |
| **B** | *Vervalt.* Geen database. Herbestemd: de sudoers-regel als toegangsmodel — de enige "policy" die dit project heeft | D2 |
| **C** | *Herbestemd:* de rollenmatrix cel voor cel, empirisch, op de lokale principals | D4 |
| **D** | *Vervalt grotendeels.* Geen auth-levenscyclus. Herbestemd: de autorisatieprompt en het gedrag bij annuleren, time-out en herhaling | D1 |
| **E** | Invoer en injectie: de shellstring, het socketprotocol, alles wat geïnterpoleerd wordt | D1, D2, D6 |
| **F** | Toestandsovergangen en races in de sessielogica en de vangnetten | D4, D5, D7 |
| **G** | *Herbestemd:* geen headers en geen cache. Wel: luisterende poorten, uitgaand verkeer, de socket als oppervlak | D6 |
| **H** | Bestanden, rechten, logboek, bewaartermijnen, wat er achterblijft na verwijderen | D5, D8 |
| **R** | Ongebonden. Krijgt alleen dit bestand en `00-feiten.md` | Alle acht |

## Regels voor experimenten op deze machine

Er is geen testomgeving; er is één echte Mac van de gebruiker.

1. **Niets aan `/Applications`.** Bundelmanipulatie voor D3 gebeurt op een kopie in de
   scratchmap.
2. **Niets aan `/etc/sudoers.d/`.** De regel wordt gelezen, nooit geschreven of verwijderd.
3. **De blokkade mag gezet worden**, want dat is normaal gebruik — maar altijd met een
   controle achteraf dat hij weer op 0 staat.
4. **`kill -9` op de app mag**, want `--killtest` doet dat ook. Melden vóór en na.
5. **Voorkeuren mogen gewijzigd worden**, mits de oude waarde eerst wordt vastgelegd en
   daarna teruggezet.
6. Elk experiment dat hier niet onder valt, wordt eerst als voorstel gerapporteerd en niet
   uitgevoerd.
