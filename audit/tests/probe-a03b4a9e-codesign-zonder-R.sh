#!/bin/bash
# Probe voor a03b4a9e — accepteert de wachter-handtekeningcontrole een ad-hoc getekende
# bundel die niet van de eigen Team-ID is?
#
# NIET-DESTRUCTIEF. Bouwt een mini-nepbundel in een eigen tijdelijke map, tekent hem
# ad-hoc, en draait er de EXACTE controle uit RestartGuard.swift:451 op. Raakt de echte
# bundel niet aan. Ruimt alles op.
#
# FAALT (exit 1) zolang de bevinding open staat: `codesign --verify --strict` laat de
# nepbundel door. SLAAGT (exit 0) zodra de controle een Team-ID-requirement afdwingt en
# de nepbundel weigert.
#
# Deze probe test of de bevinding nog leeft door BEIDE controlevormen op de nepbundel los
# te laten: de oude (--verify --strict, de bug) en de nieuwe (voldoen aan de designated
# requirement van de echte app). De probe faalt zolang de nepbundel de designated
# requirement van de app haalt.
set -uo pipefail

APP="/Applications/Dopamine Code.app"
[ -d "$APP" ] || APP="$(cd "$(dirname "$0")/../.." && pwd)/build/Dopamine Code.app"

TEAM="<team-id>"
TMP="$(mktemp -d)/Fake.app"
trap 'rm -rf "$(dirname "$TMP")"' EXIT

mkdir -p "$TMP/Contents/MacOS"
cat > "$TMP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>DopamineCode</string>
<key>CFBundleIdentifier</key><string>com.peter46jan.dopaminecode</string>
</dict></plist>
PLIST
printf '#!/bin/bash\necho payload\n' > "$TMP/Contents/MacOS/DopamineCode"
chmod +x "$TMP/Contents/MacOS/DopamineCode"

codesign -s - --force --deep "$TMP" >/dev/null 2>&1

# De oude controle (de bug): alleen het zegel, niet de identiteit.
if codesign --verify --strict "$TMP" >/dev/null 2>&1; then
  oud="LAAT DOOR (dit was de bug)"
else
  oud="weigert"
fi

# De controle zoals de wachter hem NU doet: voldoet de nepbundel aan de designated
# requirement van de echte app? Dat is precies wat SecStaticCodeCheckValidity met de eigen
# requirement afdwingt; codesign -R met "=<app>" toetst hetzelfde vanaf de opdrachtregel.
if codesign --verify -R="=\"$APP\"" "$TMP" >/dev/null 2>&1; then
  nieuw="laat door (FOUT — fix werkt niet)"
  faal=1
else
  nieuw="weigert (fix werkt)"
  faal=0
fi

echo "app-identiteit die geëist wordt        : $(codesign -dvv "$APP" 2>&1 | grep -m1 TeamIdentifier || echo onbekend)"
echo "ad-hoc nepbundel, OUDE check (strict)  : $oud"
echo "ad-hoc nepbundel, NIEUWE check (=app)  : $nieuw"

if [ "$faal" = 1 ]; then
  echo "RESULTAAT: KWETSBAAR — de nepbundel voldoet aan de app-identiteit. Fix ontbreekt of faalt."
  exit 1
fi
echo "RESULTAAT: dicht — de wachter weigert een bundel die niet van de eigen identiteit is."
exit 0
