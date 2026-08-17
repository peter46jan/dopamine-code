# Het paneel op tegels

18 augustus 2026. Vervolg op [het herontwerp van 17 augustus](2026-08-17-paneel-herontwerp.md).

## De klacht

"Ik zie nog geen glass." Het paneel had `.glassEffect()` op elke kaart staan en zag er toch
grijs uit.

Dat kwam niet door een verkeerde instelling. `.glassEffect()` breekt wat er **in hetzelfde
venster** achter ligt. Een `MenuBarExtra` heeft een egale systeemachtergrond, dus er viel niets
te breken — glas over grijs is grijs.

CleanMyMac omzeilt dat door zijn eigen achtergrond te schilderen, van rand tot rand. Dat is de
hele truc, en dit is de uitwerking ervan.

## Wat er veranderd is

1. **Het paneel schildert zijn eigen achtergrond.** Eén donker paarsblauw verloop achter de
   `VStack`, uit `Palet.achtergrond`. Pas daardoor heeft het glas iets om zich van te
   onderscheiden.
2. **De vangnetten zijn tegels.** Accu en warmte naast elkaar, de wachter over de volle breedte
   eronder. In de oude rij vochten de stand en de grens om één kolom van honderd punten; nu
   heeft elk zijn eigen regel.
3. **De aandachtsrij klapt niet meer in.** Elke melding is een tegel in de kleur van zijn ernst.
   Rood dwong het uitklappen al af; nu is het de normale toestand. Een waarschuwing die je moet
   openklappen om te zien, is een waarschuwing die je niet ziet.
4. **Eén palet.** `Palet.swift` is de enige plek met kleuren, zodat geen tegel zijn eigen paars
   verzint.

## Wat het kost

**Licht en donker gaat eraan.** Eén vaste look, ook als de Mac in lichte modus staat — zoals
CleanMyMac dat doet. Een eigen achtergrond en een meebewegend palet gaan niet samen: op
donkerpaars is `Color.primary` in lichte modus zwart.

Dat betekent dat `Color.primary`, `Color.secondary` en `.tertiary` in dit paneel niet meer
bruikbaar zijn. Alles wat het paneel zelf tekent haalt zijn kleur uit `Palet`. Voor wat het
paneel *niet* zelf tekent — de segmentkiezer, de tijdkiezer, de schakelaar, de knoppen — staat
`\.colorScheme` op `.dark` over het hele paneel.

**Het wordt hoger.** Gemeten aan het echte venster:

| toestand | nl / en / de | fr |
|---|---|---|
| sessie loopt | 434 pt | 437 pt |
| uit | 408 pt | 408 pt |
| één fout | 506 pt | 509 pt |
| twee waarschuwingen, waarvan één met knoppen | 625–638 pt | 641 pt |

Het oude paneel zat rond de 380. De schatting vooraf was 520; dat viel dus mee.

## Wat er niet veranderd is

`Meter.swift`, `KaartToestand.swift`, `Aandacht.swift` en de afgeleide eigenschappen in
`AppModel` zijn onaangeroerd. Dit is weergavewerk. Hun vier proeven in `verify.sh --paneel`
zijn groen gebleven, en dat is meteen het bewijs dat er niets aan het gedrag veranderd is.

De drie vangnetten zijn niet aangeraakt. De sudoers-regel is niet aangeraakt.

## Wat er gemeten is, en waarmee

De gebruiker sliep. Drie gereedschappen hebben zijn plaats ingenomen.

### 1. Breedtes, vóór het bouwen (`breedte.swift`)

`NSAttributedString.size(withAttributes:)` met de échte systeemfonts, tegen de échte
`.strings`-bestanden, in vier talen. Alle regels van het ontwerp uitgerekend tegen hun budget
voordat er een letter code geschreven was.

De krapste: het Franse **"légèrement élevée"** is **131,4 pt** in een tegel die **140,5 pt**
inhoud heeft. Negen punten over. Vandaar `minimumScaleFactor(0.75)` op de waarderegel.

Dit ving één ontwerpfout niet — zie hieronder — omdat het budget van de heldentegel op 192 pt
geschat was en in werkelijkheid krapper is.

### 2. Het echte venster naar PNG (`paneelproef`)

Een echte `MenuBarExtra`, opengeklikt, en de laag van het paneelvenster getekend in een bitmap.
Twintig platen: vier talen × vijf toestanden.

Wat dat opleverde:

- **De Franse onderregel werd afgekapt** tot `"éveillé jusqu'à 21:56 · écran ouv…"`. Juist die
  laatste twee woorden zijn de klepstand, het onderwerp van deze app. Nu twee regels.
- **De hartslag van de wachterstip raakte de eerste letter** van de zin ernaast. De ring zwelt
  tot 2,6 keer zijn maat; de kier van 8 pt was te krap. Nu 11.
- **"SICHERUNG" onder de kop "SICHERUNGEN"** las als "het vangnet" in plaats van "de wachter".
  De Duitse tegel heet nu `Wächter`, en `vangnet.wachter.stil` is meeverhuisd zodat er niet
  twee namen voor één ding staan.

### 3. De onderdelen naar hun uiterlijk vragen (`uiterlijk.swift`)

Op de platen stonden de segmentkiezer, de schakelaar en de knoppen **wit**. Dat leek een fout
en was er geen: `CALayer.render(in:)` tekent geen achtergrondfilters, en AppKit zet die
onderdelen op een `NSVisualEffectView`. Ze komen er als een dekkend vlak uit.

Niet nóg een plaat dus, maar de vraag zelf: loop de vensterboom af en vraag elk onderdeel naar
zijn `effectiveAppearance`. Gemeten, met het systeem in **lichte** modus:

| aanpak | uiterlijk van de onderdelen |
|---|---|
| niets | `NSAppearanceNameVibrantLight` |
| `.environment(\.colorScheme, .dark)` | **`NSAppearanceNameVibrantDark`** |
| `.preferredColorScheme(.dark)` | `NSAppearanceNameVibrantLight` |
| `venster.appearance = .darkAqua` | `NSAppearanceNameVibrantLight` |
| `NSApp.appearance = .darkAqua` | `NSAppearanceNameVibrantDark` |

Alleen de omgeving werkt, en die raakt de rest van de app niet. Vandaar die regel in `MenuView`.

## Twee vallen waar tijd in ging zitten

**`ImageRenderer` tekent de inhoud van een eigen `ViewModifier` niet.** `.glas()` levert er een
lege tegel op — de juiste rand, de juiste vulling, en niets erin. De inhoud telt daar zelfs niet
mee voor de indeling. Vervelend, want ImageRenderer is het voor de hand liggende gereedschap.
De laagafdruk van het echte venster tekent het wél goed, en dat is de weg geworden. Zie
`var-f-echte-glas.png`.

**`CALayer.render(in:)` liegt over alles wat op vibrancy staat.** Een halfuur is opgegaan aan
de conclusie dat het donkere schema niet werkte, terwijl het gewoon werkte. Een plaat is bewijs
voor wat je zelf tekent en voor niets anders.

**Deze Mac draait macOS 26.5.** Alle platen zijn dus met het échte `.glassEffect()` gemaakt. De
terugval voor 14 en 15 is hier nooit vanzelf uitgevoerd en daarom apart afgedwongen in
`glasproef`: dezelfde tegels naast elkaar, met en zonder glas. Ze zijn nagenoeg gelijk — de
terugval is iets vlakker, en de indeling is identiek.

## Wat overwogen en niet gedaan is

**Een tegel rood kleuren zodra zijn vangnet ingrijpt.** `AccuMeter.grijptIn` en
`WarmteMeter.grijptIn` weten dat al. Maar op het moment dat zo'n vangnet ingrijpt eindigt de
sessie, dus die toestand staat er hooguit een seconde. Een kleur die je nooit ziet is geen
kleur.

**De besturingselementen zelf tekenen**, zoals de mockup deed. Dat zou het paneel volledig van
het systeem losmaken, maar het kost de toetsenbordbediening en de toegankelijkheid die AppKit
gratis geeft. De omgevingsinstelling doet hetzelfde werk voor één regel.
