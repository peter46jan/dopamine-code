# Rollenmatrix — Dopamine Code

*Fase 0. Wat het systeem volgens de code zou moeten toestaan. Dit is de verwachting, niet
de meting: fase 1 loopt elke cel af en vult de werkelijkheid in.*

---

## Waarom deze matrix er anders uitziet dan de opdracht vraagt

De opdracht vraagt om applicatierollen (admin, gebruiker, gast) tegen gevoelige handelingen.
Die bestaan hier niet: de app heeft geen accounts, geen inlog en geen rollen.

Wat er wél is, is een **lokaal rechtenmodel**. De rijen zijn daarom principals in
macOS-termen. Dat is de enige indeling waarin de vraag "mag dit" hier betekenis heeft.

## De principals

| Id | Principal | Toelichting |
|---|---|---|
| P0 | Netwerk, zonder lokale toegang | Iemand op hetzelfde wifi, of het internet |
| P1 | Andere lokale gebruiker, niet-beheerder | Tweede account op deze Mac, eigen uid |
| P2 | Andere lokale gebruiker, beheerder | Tweede beheerdersaccount |
| P3 | **Proces als de gebruiker zelf** | Alles wat jij draait: een script, een gedownloade app, een npm-pakket, een gecompromitteerde editor-plug-in. **De belangrijkste rij.** |
| P4 | De gebruiker aan het toetsenbord | Kan een wachtwoordvenster beantwoorden |
| P5 | root | Al klaar; alleen relevant als doelwit |

**P3 is waar deze audit over gaat.** Op een persoonlijke Mac is "iets draait als jou" het
realistische scenario, en het is precies de rij waar de sudoers-regel, de socket en de
wachter allemaal aan de goede kant van moeten blijven.

## De handelingen

| Id | Handeling |
|---|---|
| H1 | De slaapblokkade aanzetten (Mac wakker houden) |
| H2 | De slaapblokkade uitzetten |
| H3 | De sudoers-regel installeren |
| H4 | De sudoers-regel verwijderen |
| H5 | Willekeurige code als root uitvoeren |
| H6 | De vangnetten uitschakelen (timer, accugrens, temperatuur) |
| H7 | De wachter uitschakelen of misleiden |
| H8 | Het logboek lezen |
| H9 | De lopende sessie aansturen via de socket |
| H10 | Bepalen wat de wachter start |

## De matrix — wat de code zou moeten toestaan

`JA` = hoort te mogen · `NEE` = hoort geweigerd te worden · `WW` = mag, maar alleen met
wachtwoord · `?` = de code geeft geen duidelijk antwoord, uitzoeken in fase 1

| | H1 | H2 | H3 | H4 | H5 | H6 | H7 | H8 | H9 | H10 |
|---|---|---|---|---|---|---|---|---|---|---|
| **P0** netwerk | NEE | NEE | NEE | NEE | NEE | NEE | NEE | NEE | NEE | NEE |
| **P1** andere gebruiker | NEE | NEE | NEE | NEE | NEE | NEE | NEE | NEE | NEE | NEE |
| **P2** andere beheerder | NEE | NEE | WW | WW | WW | NEE | ? | NEE | NEE | **?** |
| **P3** proces als jij | **JA** | **JA** | WW | WW | **NEE** | **NEE** | **?** | JA | **JA** | **?** |
| **P4** jij aan het toetsenbord | JA | JA | WW | WW | WW | NEE | JA | JA | JA | JA |
| **P5** root | JA | JA | JA | JA | JA | JA | JA | JA | JA | JA |

## De cellen die ertoe doen

Vijf cellen dragen het hele model. De rest volgt daaruit.

### P3 × H1/H2 — JA, en dat is ontwerp

Elk proces dat als jou draait mag de blokkade zetten, via de socket of via `sudo -n pmset`.
Dat is geen fout: de sudoers-regel is aan de gebruiker gekoppeld, niet aan een binary, en
sudo kan niet zien welke app hem aanroept. Een socket met uid-controle verandert daar niets
aan, want de aanvaller heeft diezelfde uid.

**Gevolg voor het rapport:** "een proces als jou kan de Mac wakker houden" is géén bevinding.
Het is de aanvaarde prijs van een wachtwoordloze regel. Wat wél een bevinding is: of het
verder komt dan die twee commando's.

### P3 × H5 — moet NEE zijn, en dit is de belangrijkste cel van de audit

Van "ik draai als jij" naar "ik draai als root" is de enige echte escalatie hier. Twee routes
verdienen bewijs, geen redenering:

- De shellstring in `SudoersGrant.swift:109`, met `payload` en `user` erin geïnterpoleerd.
  De twee regexcontroles (regels 100 en 105) zijn de enige barrière.
- De sudoers-regel zelf: houdt de exacte argumentmatch stand, of is er een `pmset`-aanroep
  die eraan voldoet en méér doet.

### P3 × H6 — moet NEE zijn

De vangnetten zijn wat de app veilig maakt zonder de kernel-noodslaap. Kan een proces als jij
de timer, de accugrens of de temperatuurbewaking uitzetten of oprekken, dan blijft de blokkade
staan met niets erachter. De voorkeuren staan in `UserDefaults` en zijn schrijfbaar met
`defaults write` — **dat is per definitie waar, dus de vraag is wat de app ermee doet.**
`Prefs` klemt de duur op 5 min tot 24 uur en de accugrens op 5–90 %; of die klem overal geldt
is een meting.

### P3 × H7 en P3/P2 × H10 — allebei een vraagteken, en allebei nieuw

De wachter beslist op basis van bestanden in een 0700-map. Voor P3 is die map open. Schrijf
een `afsluiting.json` met `blokkadeStondAan: false` en de wachter concludeert "niet van ons"
en doet niets meer — zonder tijdslimiet. Dat is vanmiddag als *bug* gerepareerd aan de
schrijfkant; als *aanval* is het ongetoetst.

H10 voor P2 is een aparte: `/Applications` is `drwxrwxr-x root:admin`, dus elke beheerder kan
de bundel vervangen. De wachter draait er `codesign --verify --strict` op — dat controleert
het zegel, niet de ondertekenaar. Een eigen bundel met geldige ad-hoc handtekening komt daar
mogelijk doorheen, en wordt dan elke 30 seconden automatisch gestart.

## Wat deze matrix níét dekt

- **P4 is geen aanvaller.** Wie aan het toetsenbord zit en beheerder is, kan alles. De app
  beschermt niet tegen zijn eigen gebruiker en hoort dat ook niet te doen.
- **P0 heeft geen oppervlak.** Geen luisterende netwerkpoort, geen inkomende verbinding.
  Het enige uitgaande verkeer is de captive-portal-test naar een vast Apple-adres. Te
  bevestigen met `lsof -i` door agent G.
- **P1 en P2 zijn op deze Mac hypothetisch** — er is één account. De cellen blijven staan
  omdat ze het model compleet maken, maar bewijs zal daar vaak `NIET TE BEPALEN` zijn.
