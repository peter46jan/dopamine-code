#!/bin/bash
# Probe voor f855c2d2 — draait een door de app verzonden instructie het ON-DISK grant.sh
# als root, terwijl dat bestand door de gewone gebruiker schrijfbaar is?
#
# De bevinding is NIET "grant.sh is schrijfbaar" op zich (dat is een bundel-eigenschap), maar
# de COMBINATIE: schrijfbaar bestand ÉN de app instrueert je het als root uit te voeren. Deze
# probe toetst die combinatie in de bron, want dat is wat de fix wegneemt.
#
# NIET-DESTRUCTIEF. Leest alleen. Schrijft niets, voert grant.sh niet uit.
#
# FAALT (exit 1) zolang een uitvoeringspad het schijfbestand als root draait.
# SLAAGT (exit 0) zodra geen enkele route dat meer doet — ook al blijft het bestand
# schrijfbaar en leesbaar in de bundel.
set -uo pipefail

SRC="$(cd "$(dirname "$0")/../.." && pwd)"
GRANT="/Applications/Dopamine Code.app/Contents/Resources/grant.sh"
schrijfbaar=0; [ -w "$GRANT" ] && schrijfbaar=1

# 1. manualCommand: draait hij een bestandspad (/bin/bash '<pad>') of pipet hij de payload?
#    De kwetsbare vorm heeft "/bin/bash '" met een pad erachter; de veilige vorm pipet
#    base64 naar "/bin/bash -s" (leest van stdin, geen pad).
manual_kwetsbaar=0
if grep -A4 'static var manualCommand' "$SRC/Sources/DopamineCode/SudoersGrant.swift" \
   | grep -qE "/bin/bash '"; then
  manual_kwetsbaar=1
fi

# 2. README: staat er een UITVOERBARE regel (begint met sudo) die grant.sh draait?
#    Prozauitleg die het woord grant.sh noemt telt niet — alleen een commandoregel.
readme_kwetsbaar=0
if grep -qE "^\s*sudo\b.*grant\.sh" "$SRC/README.md"; then
  readme_kwetsbaar=1
fi

echo "grant.sh door gebruiker schrijfbaar        : $([ $schrijfbaar = 1 ] && echo ja || echo nee)"
echo "manualCommand draait het schijfbestand     : $([ $manual_kwetsbaar = 1 ] && echo JA || echo nee, pipet payload)"
echo "README toont een sudo-grant.sh commandoregel: $([ $readme_kwetsbaar = 1 ] && echo JA || echo nee)"

if [ "$manual_kwetsbaar" = 1 ] || [ "$readme_kwetsbaar" = 1 ]; then
  echo "RESULTAAT: KWETSBAAR — een verzonden instructie draait het schrijfbare bestand als root."
  exit 1
fi
echo "RESULTAAT: dicht — geen route draait het on-disk grant.sh als root; de payload komt uit de binary."
exit 0
