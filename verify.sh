#!/bin/bash
#
# Verifies the parts of Dopamine Code that cannot be tested without your password, plus the
# ones that change what is on screen. Nothing in the standard round is destructive: every
# flag it sets it also puts back. De enige uitzondering is --killtest, die je expliciet moet
# aanroepen en die eerst om toestemming vraagt.
#
#   ./verify.sh            run everything, asking before each step that needs consent
#   ./verify.sh --flag     only the disablesleep round trip (the critical one)
#   ./verify.sh --display  only the display-sleep test
#   ./verify.sh --report   read-only status report, no password, no side effects
#   ./verify.sh --killtest schiet de app hard af tijdens een lopende sessie en kijkt of het
#                          vangnet de slaapblokkade binnen twee minuten opruimt. Beëindigt de
#                          sessie die op dat moment loopt — draai hem bewust.
#   ./verify.sh --after    after a real lid-closed run: did the Mac sleep anyway?
#                          Windows on the last session in the app's own log. Both bounds
#                          can be given by hand:
#                            ./verify.sh --after "2026-08-11 17:56:37" "2026-08-11 19:50:00"
#
set -uo pipefail

BOLD=$'\033[1m'; RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; OFF=$'\033[0m'
pass() { printf '%s  PASS%s  %s\n' "$GREEN" "$OFF" "$1"; }
fail() { printf '%s  FOUT%s  %s\n' "$RED" "$OFF" "$1"; FAILURES=$((FAILURES+1)); }
skip() { printf '%s  OVER%s  %s\n' "$YELLOW" "$OFF" "$1"; }
section() { printf '\n%s== %s%s\n' "$BOLD" "$1" "$OFF"; }
FAILURES=0

# Reads the kernel flag. NOT `pmset -g` — that only prints SleepDisabled once the key
# has been set at least once, so on a fresh machine it is silent and unusable.
read_flag() {
  ioreg -a -r -d 1 -c IOPMrootDomain 2>/dev/null \
    | plutil -extract '0.SleepDisabled' raw -o - - 2>/dev/null
}

read_prop() {
  ioreg -a -r -d 1 -c IOPMrootDomain 2>/dev/null \
    | plutil -extract "0.$1" raw -o - - 2>/dev/null
}

# Waits for the kernel flag to reach an expected value.
#
# `pmset` does not write the IORegistry itself: it stores a preference and posts a
# notification, powerd picks that up, and the kernel then queues its own power event.
# A single `sleep 1` before reading is a race — and losing it here would report the
# central mechanism as broken when it is fine.
wait_for_flag() {
  local expected="$1" deadline=$(( SECONDS + ${2:-8} ))
  while [ "$SECONDS" -lt "$deadline" ]; do
    [ "$(read_flag)" = "$expected" ] && return 0
    sleep 0.25
  done
  return 1
}

# Is a specific command permitted WITHOUT a password?
#
# Plain `sudo -l <cmd>` cannot answer that: `man sudo` says exit 0 means the command is
# permitted, full stop. And macOS ships `%admin ALL=(ALL) ALL`, so for an admin account
# every command is permitted. `-l -l` prints the matching rule in verbose form, which is
# the only way to see whether the match carries the NOPASSWD tag.
is_nopasswd() {
  local out
  out="$(sudo -n -l -l "$@" 2>&1)" || return 1
  printf '%s' "$out" | grep -qE '!authenticate|NOPASSWD'
}

# sysadminctl prefixes its output with an os_log line; keep only the sentence.
screenlock_status() {
  sysadminctl -screenLock status 2>&1 \
    | grep -o 'screenLock.*' \
    | tail -1
}

ask() {
  printf '%s%s%s [j/N] ' "$BOLD" "$1" "$OFF"
  read -r answer < /dev/tty
  [[ "$answer" =~ ^[jJyY]$ ]]
}

# Waar dit script vandaan komt, zodat de broncontroles ook werken als je het vanuit een
# andere map aanroept.
PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"

# De `dopamine`-binary uit de geïnstalleerde bundel, met de bouwmap als terugval. Beide
# paden bevatten een spatie, dus alles blijft aangehaald.
cli_path() {
  local candidate
  for candidate in "/Applications/Dopamine Code.app/Contents/MacOS/dopamine" \
                   "$PROJECT_DIR/build/Dopamine Code.app/Contents/MacOS/dopamine"; do
    if [ -x "$candidate" ]; then printf '%s' "$candidate"; return 0; fi
  done
  return 1
}

# Eén veld uit een JSON-antwoord, zonder jq (dat staat niet op elke Mac). plutil leest JSON
# van stdin, net als bij read_flag hierboven.
json_field() {
  printf '%s' "$1" | plutil -extract "$2" raw -o - - 2>/dev/null
}

WATCHDOG_LABEL="com.peter46jan.dopaminecode.watchdog"
WATCHDOG_STATE="$HOME/Library/Application Support/Dopamine Code/vangnet-status.json"

# De pids van draaiende exemplaren van de app, zónder de wachter.
#
# De wachter is dezelfde binary met het argument --vangnet, dus `pgrep -x DopamineCode` vindt
# hem ook — elke 30 seconden even. Zonder dat filter zou "de app is teruggekomen" al waar zijn
# omdat er toevallig een wachterronde liep. Let op de spaties in het patroon: een teruggehaalde
# app draait met --vangnet-herstart, en dat is géén wachter.
app_pids() {
  local pid args
  for pid in $(pgrep -x DopamineCode 2>/dev/null); do
    args=" $(ps -o args= -p "$pid" 2>/dev/null) "
    case "$args" in
      *" --vangnet "*) ;;
      *) printf '%s ' "$pid" ;;
    esac
  done
}

# Eén regel over het vangnet uit fase 2: is de wachter geladen, en wanneer keek hij voor het
# laatst? Een vangnet dat stil niet meer draait is erger dan geen vangnet, dus het hoort in
# het statusoverzicht en niet alleen in het logboek.
watchdog_line() {
  local staat="NIET geladen" laatste melding epoch nu
  launchctl print "gui/$(id -u)/$WATCHDOG_LABEL" >/dev/null 2>&1 && staat="geladen"
  if [ -f "$WATCHDOG_STATE" ]; then
    laatste="$(plutil -extract laatsteRonde raw -o - "$WATCHDOG_STATE" 2>/dev/null || true)"
    melding="$(plutil -extract laatsteMelding raw -o - "$WATCHDOG_STATE" 2>/dev/null || true)"
    if [ -n "${laatste:-}" ]; then
      epoch="$(date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$laatste" +%s 2>/dev/null || true)"
      nu="$(date -u +%s)"
      [ -n "${epoch:-}" ] && staat="$staat, keek $((nu - epoch)) s geleden"
    fi
    [ -n "${melding:-}" ] && staat="$staat — $melding"
  else
    staat="$staat, nog niet gekeken"
  fi
  printf '%s' "$staat"
}

APP_DOMAIN="com.peter46jan.dopaminecode"

# Eén instelling uit de voorkeuren van de app, of de meegegeven terugval.
pref() {
  defaults read "$APP_DOMAIN" "$1" 2>/dev/null || printf '%s' "${2:-}"
}

# Een plist-array uit `defaults read` platgeslagen tot "a, b, c". Leeg als de sleutel nooit
# geschreven is — een geregistreerde standaardwaarde staat niet in het plistbestand, dus de
# aanroeper zegt er zelf bij wat de standaard dan is.
pref_list() {
  defaults read "$APP_DOMAIN" "$1" 2>/dev/null \
    | tr -d '()" ' | tr '\n' ' ' \
    | sed 's/  */ /g; s/^ *//; s/ *$//; s/,$//; s/,/, /g'
}

# Minuten na middernacht als kloktijd.
clock_of() {
  awk -v m="${1:-0}" 'BEGIN { printf "%02d:%02d", int(m/60), m%60 }'
}

# Wat er vanzelf aan mag gaan (fase 3).
#
# Rechtstreeks uit de voorkeuren, zonder de app te openen en zonder iets te wijzigen: de
# vraag die dit moet beantwoorden is "waarom deed hij vanochtend niks", en die stel je
# achteraf — vaak op een moment dat de app allang herstart is en zelf niets meer weet.
trigger_lines() {
  local aan dagen van tot laatst apps
  aan="$(pref scheduleEnabled 0)"
  # Een sleutel die nooit aangeraakt is staat niet in het plistbestand; de standaardwaarde
  # komt uit `register(defaults:)` in Prefs.swift en is hier met de hand herhaald.
  dagen="$(pref_list scheduleDays)"
  [ -z "$dagen" ] && dagen="2, 3, 4, 5, 6 (standaard)"
  van="$(clock_of "$(pref scheduleStartMinute 540)")"
  tot="$(clock_of "$(pref scheduleEndMinute 1080)")"
  laatst="$(pref scheduleLastArmedWindowStart)"

  if [ "$aan" = "1" ]; then
    # De dagnummers zijn die van Calendar: 1 = zondag … 7 = zaterdag.
    printf '  Schema           AAN — dagen %s (1=zo), %s tot %s\n' "$dagen" "$van" "$tot"
    [ -n "$laatst" ] && printf '  Schema laatst    venster van %s is al afgehandeld\n' "$laatst"
  else
    printf '  Schema           uit (zou zijn: dagen %s, %s tot %s)\n' "$dagen" "$van" "$tot"
  fi

  apps="$(pref_list appTriggerBundleIDs)"
  printf '  App-triggers     %s\n' "${apps:-geen}"
}

# --------------------------------------------------------------------------------------

report() {
  section "Status (alleen lezen)"
  printf '  macOS            %s (%s)\n' "$(sw_vers -productVersion)" "$(sw_vers -buildVersion)"
  printf '  Model            %s / %s\n' "$(sysctl -n hw.model)" "$(sysctl -n machdep.cpu.brand_string 2>/dev/null || uname -m)"
  printf '  SleepDisabled    %s\n' "$(read_flag)"
  printf '  Klep dicht       %s\n' "$(read_prop AppleClamshellState)"
  printf '  Klep→slaap-beleid %s (volgt de vlag niet)\n' "$(read_prop AppleClamshellCausesSleep)"
  printf '  Batterij         %s\n' "$(pmset -g batt | tail -1 | sed 's/^[[:space:]]*//')"
  printf '  Vergrendeling    %s\n' "$(screenlock_status)"
  printf '  Sudoers-bestand  %s\n' "$([ -f /etc/sudoers.d/dopamine-code-disablesleep ] && ls -l /etc/sudoers.d/dopamine-code-disablesleep | awk '{print $1, $3":"$4}' || echo 'ontbreekt')"

  if is_nopasswd /usr/bin/pmset -a disablesleep 1; then
    printf '  Sudoers-regel    actief (wachtwoordloos)\n'
  else
    printf '  Sudoers-regel    NIET actief\n'
  fi

  printf '  App draait       %s\n' "$(pgrep -x DopamineCode >/dev/null && echo ja || echo nee)"
  printf '  Wachter          %s\n' "$(watchdog_line)"
  trigger_lines

  # Wat de app zelf zegt, náást de kernelregel hierboven — nooit in plaats daarvan. Het
  # verschil tussen die twee is precies waar deze app voor bestaat, dus ze staan hier onder
  # elkaar in plaats van samengevat tot één "aan/uit".
  local cli json
  if cli="$(cli_path)"; then
    json="$("$cli" status --json 2>/dev/null)"
    if [ "$(json_field "$json" code)" = "4" ]; then
      # Draait de app wél maar antwoordt hij niet, dan is dit een oudere versie zonder
      # besturingskanaal, of de socket kon niet aangemaakt worden — dat staat dan in het
      # logboek van de app.
      printf '  Besturingskanaal onbereikbaar (%s)\n' "$(json_field "$json" zin)"
    elif [ -n "$json" ]; then
      printf '  App-sessie       %s\n' "$(json_field "$json" sessieLoopt)"
      printf '  App zegt         %s\n' "$(json_field "$json" zin)"
      local einde proces
      einde="$(json_field "$json" eindtijd)"
      [ -n "$einde" ] && printf '  Sessie tot       %s\n' "$einde"
      proces="$(json_field "$json" procesNaam)"
      [ -n "$proces" ] && printf '  Gekoppeld proces %s (%s)\n' "$proces" "$(json_field "$json" procesPid)"
    else
      printf '  Besturingskanaal geen antwoord van %s\n' "$cli"
    fi
  else
    printf '  Opdrachtregel    niet gevonden (bouw met ./build.sh)\n'
  fi

  # Een ad-hoc handtekening heeft geen Authority-regel. Zonder terugval bleef hier een leeg
  # veld staan, en dat leest als "niet ondertekend" terwijl er wel degelijk een zegel op zit —
  # alleen zonder certificaat. Zeg dan wát het is, inclusief het gevolg dat ertoe doet.
  #
  # De uitvoer wordt één keer opgehaald en daarna met `case` doorzocht, niet met `grep -q` in
  # een pijp. Dat is geen stijlkwestie: `grep -q` stopt bij de eerste match en sluit de pijp,
  # de schrijver ervoor krijgt SIGPIPE en eindigt op 141, en met `set -o pipefail` (regel 20)
  # is dát de uitkomst van de hele pijp. De test las een ad-hoc bundel daardoor als "onbekend".
  local cs ondertekening
  cs="$(codesign -dvv '/Applications/Dopamine Code.app' 2>&1)"
  ondertekening="$(printf '%s\n' "$cs" | grep '^Authority' | head -1 | cut -d= -f2-)"
  if [ -z "$ondertekening" ]; then
    case "$cs" in
      *"Signature=adhoc"*)
        ondertekening="ad-hoc (geen certificaat; identiteit is de cdhash en verandert bij elke herbouw)" ;;
      *) ondertekening="onbekend" ;;
    esac
  fi
  printf '  Handtekening     %s\n' "$ondertekening"
  printf '  Andere wakers    %s\n' "$(pmset -g | grep 'sleep prevented by' | sed 's/.*prevented by //; s/)//' || echo geen)"

  # Anything else in sudoers.d is a second passwordless writer to the same global flag.
  # Amphetamine's Power Protect installs amphetamine_powerProtect there and reaches
  # exactly the value this whole project is built around; neither app knows about the
  # other, so either can clear it while the other still needs it.
  #
  # Only the directory is listed, never a rule's contents: sudoers.d is 0755 so the names
  # are readable by anyone, while the files themselves are root-only. The names are all
  # this needs, and it keeps --report free of sudo.
  local foreign
  foreign="$(ls /etc/sudoers.d/ 2>/dev/null | grep -v '^dopamine-code-disablesleep$' | tr '\n' ' ')"
  if [ -n "${foreign// /}" ]; then
    printf '  Andere sudoers   %s\n' "$foreign"
    case "$foreign" in
      *amphetamine*) printf '                   LET OP: Amphetamine schrijft naar dezelfde vlag.\n' ;;
    esac
  fi
}

# --------------------------------------------------------------------------------------

test_includedir() {
  section "1. Leest /etc/sudoers de map sudoers.d?"
  if sudo grep -Eq '^[[:space:]]*[#@]includedir[[:space:]]+/(private/)?etc/sudoers\.d' /etc/sudoers; then
    pass "/etc/sudoers bevat de includedir-regel, dus een drop-in wordt gelezen."
  else
    fail "Geen includedir in /etc/sudoers — een drop-in zou stilzwijgend genegeerd worden."
  fi
}

test_flag_roundtrip() {
  section "2. Werkt disablesleep echt op deze M5? (het kernpunt)"

  # The app's guardian releases any flag it did not set, within twenty seconds. That is
  # correct behaviour and exactly what would make this test report a working mechanism as
  # broken, so stand the app down for the duration.
  local app_was_running=0
  if pgrep -x DopamineCode >/dev/null; then
    app_was_running=1
    echo "  (Dopamine Code tijdelijk afgesloten; zijn guardian zou deze test tegenwerken)"
    osascript -e 'quit app "Dopamine Code"' 2>/dev/null || pkill -x DopamineCode 2>/dev/null
    for _ in $(seq 1 20); do pgrep -x DopamineCode >/dev/null || break; sleep 0.25; done
  fi
  restart_app_if_needed() {
    if [ "$app_was_running" = "1" ]; then
      open -a "/Applications/Dopamine Code.app" 2>/dev/null && echo "  (Dopamine Code weer gestart)"
    fi
  }
  local before after_on after_off clam_before clam_on
  before="$(read_flag)"
  clam_before="$(read_prop AppleClamshellCausesSleep)"
  printf '  vooraf: SleepDisabled=%s  AppleClamshellCausesSleep=%s\n' "$before" "$clam_before"

  if [ "$before" = "true" ]; then
    fail "De vlag staat al op 1. Zet hem eerst uit voordat je test."
    return
  fi

  # Between setting the flag and putting it back there is a window in which Ctrl-C, a
  # closed terminal or any early exit would leave the Mac permanently unable to sleep.
  # This is the one script that must not be able to do that.
  restore_flag() {
    # Do not condition on seeing the flag already set: powerd applies the write
    # asynchronously, so an interrupt in that window reads false, restores nothing, and
    # the flag lands on 1 a moment later with nobody left to clear it. Clearing an
    # already-clear flag costs one harmless command.
    if [ "$(read_flag)" != "false" ] || [ "${FLAG_WRITE_ISSUED:-0}" = "1" ]; then
      printf '\n%s  Onderbroken — vlag terugzetten...%s\n' "$YELLOW" "$OFF" >&2
      sudo -n pmset -a disablesleep 0 2>/dev/null || sudo pmset -a disablesleep 0
      wait_for_flag false 8 \
        && printf '  vlag hersteld op 0\n' >&2 \
        || printf '%s  LET OP: herstel handmatig met: sudo pmset -a disablesleep 0%s\n' "$RED" "$OFF" >&2
    fi
  }
  trap 'restore_flag; trap - INT TERM EXIT; exit 130' INT TERM
  trap 'restore_flag' EXIT

  echo "  → sudo pmset -a disablesleep 1"
  FLAG_WRITE_ISSUED=1
  if ! sudo pmset -a disablesleep 1; then
    fail "pmset gaf een fout bij het zetten."
    trap - INT TERM EXIT
    return
  fi
  wait_for_flag true 8 || true
  after_on="$(read_flag)"
  clam_on="$(read_prop AppleClamshellCausesSleep)"
  printf '  daarna: SleepDisabled=%s  AppleClamshellCausesSleep=%s\n' "$after_on" "$clam_on"

  if [ "$after_on" = "true" ]; then
    pass "De kernelvlag staat op 1. disablesleep werkt op macOS 26 / M5."
  else
    fail "pmset meldde geen fout, maar de kernel meldt SleepDisabled=$after_on. Route is niet bruikbaar."
  fi

  # Informative only. Measured on this Mac: this property does NOT flip when the flag is
  # set — it tracks clamshell/desktop-mode policy, while the sleep veto happens later in
  # the kernel's checkSystemSleepAllowed(). Failing the run on it would report the working
  # mechanism as broken.
  printf '  (ter info: AppleClamshellCausesSleep=%s — dit volgt de vlag niet en zegt niets\n' "$clam_on"
  printf '   over of het veto werkt; alleen een echte klep-dicht-run bewijst dat.)\n'

  # Does pmset -g start printing the line once the key exists? Purely informational.
  if pmset -g | grep -qi sleepdisabled; then
    printf '  (ter info: pmset -g toont de regel nu wél: %s)\n' "$(pmset -g | grep -i sleepdisabled | tr -s ' ')"
  else
    printf '  (ter info: pmset -g toont SleepDisabled nog steeds niet)\n'
  fi

  echo "  → sudo pmset -a disablesleep 0"
  sudo pmset -a disablesleep 0
  wait_for_flag false 8 || true
  after_off="$(read_flag)"
  if [ "$after_off" = "false" ]; then
    pass "Vlag netjes teruggezet op 0."
  else
    fail "Vlag staat na terugzetten op $after_off. Zet handmatig terug: sudo pmset -a disablesleep 0"
  fi

  # Only leave the danger window if the flag is genuinely back to 0. Disarming here
  # unconditionally — including on the branch that just reported the flag still stuck —
  # threw away the one mechanism that would have put it back.
  restart_app_if_needed
  if [ "$after_off" = "false" ]; then
    trap - INT TERM EXIT
  else
    printf '%s  Trap blijft actief: de vlag staat nog op 1.%s\n' "$YELLOW" "$OFF"
  fi
}

test_grant() {
  section "3. Doet de sudoers-regel wat hij moet doen — en niet meer?"
  if [ ! -f /etc/sudoers.d/dopamine-code-disablesleep ]; then
    skip "Regel is niet geïnstalleerd. Installeer via het menu van Dopamine Code of:"
    echo "       sudo DOPAMINE_USER=\$(id -un) /bin/bash '/Applications/Dopamine Code.app/Contents/Resources/grant.sh'"
    return
  fi

  local perms owner
  perms="$(stat -f '%Lp' /etc/sudoers.d/dopamine-code-disablesleep)"
  owner="$(stat -f '%Su:%Sg' /etc/sudoers.d/dopamine-code-disablesleep)"
  [ "$perms" = "440" ] && pass "Rechten 0440." || fail "Rechten zijn $perms, moeten 0440 zijn."
  [ "$owner" = "root:wheel" ] && pass "Eigenaar root:wheel." || fail "Eigenaar is $owner, moet root:wheel zijn."

  sudo visudo -c >/dev/null 2>&1 \
    && pass "Volledige sudoers-configuratie parst schoon." \
    || fail "visudo -c faalt — dit kan sudo systeembreed breken. Verwijder de regel."

  if is_nopasswd /usr/bin/pmset -a disablesleep 1 && is_nopasswd /usr/bin/pmset -a disablesleep 0; then
    pass "Beide toegestane commando's zijn wachtwoordloos beschikbaar."
  else
    fail "De twee commando's zijn niet wachtwoordloos beschikbaar."
  fi

  # The whole point of pinning the arguments: nothing else may slip through.
  local leaked=0
  for forbidden in "-a hibernatemode 0" "-a sleep 0" "restoredefaults" "-a disablesleep 2"; do
    # shellcheck disable=SC2086
    if is_nopasswd /usr/bin/pmset $forbidden; then
      fail "Te ruim: 'pmset $forbidden' is óók wachtwoordloos toegestaan."
      leaked=1
    fi
  done
  [ "$leaked" -eq 0 ] && pass "Geen enkel ander pmset-commando is wachtwoordloos toegestaan."
}

test_display() {
  section "4. Gaat het scherm uit zonder root?"
  echo "  Dit zet je scherm uit. Met 'vergrendeling: immediate' moet je daarna opnieuw inloggen."
  if ! ask "  Nu uitvoeren?"; then skip "Overgeslagen."; return; fi
  echo "  → pmset displaysleepnow (over 3 seconden, zonder sudo)"
  sleep 3
  if pmset displaysleepnow; then
    pass "pmset displaysleepnow gaf exitcode 0 als gewone gebruiker."
  else
    fail "pmset displaysleepnow mislukte zonder root — de app moet dit anders oplossen."
  fi
}

test_backlight() {
  section "5. Toetsenbordverlichting via CoreBrightness"
  local probe="${TMPDIR:-/tmp}/dopamine-kb-probe.swift"
  cat > "$probe" <<'SWIFT'
import Foundation
guard Bundle(path: "/System/Library/PrivateFrameworks/CoreBrightness.framework")?.load() == true,
      let cls = NSClassFromString("KeyboardBrightnessClient") as? NSObject.Type else {
    print("NIET-BESCHIKBAAR"); exit(1)
}
let c = cls.init()
typealias IDs = @convention(c) (NSObject, Selector) -> NSArray?
typealias GetF = @convention(c) (NSObject, Selector, UInt64) -> Float
func imp<T>(_ o: NSObject, _ s: Selector, _ t: T.Type) -> T? {
    guard let m = class_getInstanceMethod(Swift.type(of: o), s) else { return nil }
    return unsafeBitCast(method_getImplementation(m), to: t)
}
let idSel = NSSelectorFromString("copyKeyboardBacklightIDs")
let kbID = (imp(c, idSel, IDs.self)?(c, idSel)?.firstObject as? NSNumber)?.uint64Value ?? 1
let getSel = NSSelectorFromString("brightnessForKeyboard:")
guard let get = imp(c, getSel, GetF.self) else { print("GEEN-GETTER"); exit(1) }
print("OK id=\(kbID) niveau=\(get(c, getSel, kbID))")
SWIFT
  # Compiler diagnostics are kept, not sent to /dev/null. Without the toolchain installed
  # the build fails, `out` came out empty, and this reported "CoreBrightness niet bruikbaar
  # ()" — blaming a framework that was never asked, and failing the whole run over a
  # missing compiler that the app does not need at runtime.
  local build out
  if ! build="$(swiftc -O -o "${TMPDIR:-/tmp}/dopamine-kb-probe" "$probe" 2>&1)"; then
    skip "Kon de proef niet compileren, dus niet getest: $(printf '%s' "$build" | head -3 | tr '\n' ' ')"
    rm -f "$probe"
    return
  fi
  out="$("${TMPDIR:-/tmp}/dopamine-kb-probe" 2>&1)"
  case "$out" in
    OK*) pass "CoreBrightness bereikbaar zonder rechten: $out" ;;
    *)   fail "CoreBrightness niet bruikbaar ($out). De app valt terug op CGEvent + Toegankelijkheid." ;;
  esac
  rm -f "$probe" "${TMPDIR:-/tmp}/dopamine-kb-probe"
}

# De opdrachtregel mag de kernelvlag niet kunnen schrijven — niet nu, en niet nadat er nog
# drie fases overheen zijn gegaan. Eén schrijver, dat is de hele architectuur; een tweede
# maakt precies het conflict dat dit project Amphetamine verwijt.
test_cli_purity() {
  section "7. Blijft de opdrachtregel van de kernelvlag af?"

  # Op het IOKit-*framework*, niet op de naam: de Swift-runtime hangt er zelf een zwakke
  # libswiftIOKit.dylib aan die niets zegt over wat deze binary doet.
  local cli
  if cli="$(cli_path)"; then
    if otool -L "$cli" 2>/dev/null | grep -q 'Frameworks/IOKit'; then
      fail "De dopamine-binary linkt het IOKit-framework. Hij hoort alleen Foundation te gebruiken."
    else
      pass "De dopamine-binary linkt het IOKit-framework niet."
    fi
  else
    skip "Geen dopamine-binary gevonden; bouw eerst met ./build.sh."
  fi

  # Commentaar telt niet mee: juist deze bestanden leggen in hun commentaar uit waarom ze
  # pmset en de kernelvlag NIET aanraken, en dat mag geen fout opleveren.
  local leaked="" f
  for f in "$PROJECT_DIR/Sources/dopamine"/*.swift "$PROJECT_DIR/Sources/Shared"/*.swift; do
    [ -f "$f" ] || continue
    if sed 's://.*::' "$f" | grep -qE 'pmset|IOKit|SleepFlag|disablesleep'; then
      leaked="$leaked $(basename "$f")"
    fi
  done
  if [ -n "${leaked// /}" ]; then
    fail "Deze bestanden raken de vlag of pmset aan, terwijl ze dat niet mogen:$leaked"
  else
    pass "Geen enkel bestand van de opdrachtregel raakt pmset, IOKit of de vlag aan."
  fi

  # Er hoort precies één plek te zijn die de vlag AANzet. Meer dan één betekent een route die
  # de accugrens, de warmtegrens of de wachtwoordvrijstelling overslaat.
  #
  # Twee greps over de hele bronmap, niet één op één bestand. De oude controle telde alleen
  # `await write(true` in AppModel.swift, en juist de gevaarlijke variant viel daarbuiten: een
  # nieuw bestand dat rechtstreeks `SleepFlag.set(true, …)` aanroept gaat langs de wikkel én
  # langs alle drie de controles, en werd niet geteld. Dat is precies de route die een
  # volgende fase per ongeluk neemt.
  #
  # Terugzetten (`false`) staat hier bewust niet in: de blokkade uitzetten is nooit gevaarlijk.
  local wrapped direct
  wrapped="$(grep -rho 'await write(true' "$PROJECT_DIR/Sources" 2>/dev/null | wc -l | tr -d ' ')"
  direct="$(grep -rn 'SleepFlag\.set(true' "$PROJECT_DIR/Sources" 2>/dev/null \
            | grep -vc '/SleepFlag\.swift:' || true)"
  direct="${direct:-0}"
  if [ "$wrapped" = "1" ] && [ "$direct" = "0" ]; then
    pass "Er is precies één plek die de slaapblokkade aanzet, en niets omzeilt hem."
  else
    fail "Aanzetroutes: $wrapped via write(true) en $direct rechtstreeks via SleepFlag.set(true; dat horen er 1 en 0 te zijn."
  fi
}

# De tegenhanger van test_cli_purity, voor het vangnet uit fase 2.
#
# De wachter draait als dezelfde binary als de app en heeft dus dezelfde
# wachtwoordvrijstelling binnen handbereik: "even zelf op 0 zetten" is technisch mogelijk. Dat
# zou een tweede schrijver zijn zonder enige kennis van wat er loopt, die een gewilde sessie
# kan beëindigen. Hij mag daarom uitsluitend lezen, en dat is met één grep aan te tonen.
test_watchdog_purity() {
  section "8. Blijft de wachter van de kernelvlag af?"

  local f="$PROJECT_DIR/Sources/DopamineCode/RestartGuard.swift"
  if [ ! -f "$f" ]; then
    skip "RestartGuard.swift niet gevonden."
    return
  fi

  if grep -qE 'SleepFlag\.set|pmset|disablesleep' "$f"; then
    fail "RestartGuard.swift noemt het schrijfpad. De wachter hoort alleen SleepFlag.read() te gebruiken."
  else
    pass "RestartGuard.swift raakt het schrijfpad nergens aan."
  fi

  # Geen tweede boekhouding over "loopt er een sessie": dat is precies het defect waar de
  # guardian uit voortkomt.
  if grep -qE 'intendedOn|sessionStart|deadline' "$f"; then
    fail "RestartGuard.swift houdt sessiestand bij; dat hoort alleen in AppModel te staan."
  else
    pass "RestartGuard.swift houdt geen enkele sessiestand bij."
  fi
}

test_lock() {
  section "6. Vergrendelmechanisme aanwezig?"
  if dyld_info -exports /System/Library/PrivateFrameworks/login.framework/Versions/A/login 2>/dev/null \
     | grep -q _SACLockScreenImmediate; then
    pass "SACLockScreenImmediate bestaat in login.framework."
  else
    fail "SACLockScreenImmediate niet gevonden — vergrendelen valt terug op de schermbeveiliging."
  fi
  local delay
  delay="$(screenlock_status)"
  case "$delay" in
    *immediate*) pass "Vergrendeling: $delay" ;;
    *)           skip "Vergrendeling: $delay — bij openklappen wordt mogelijk geen wachtwoord gevraagd." ;;
  esac
}

# --------------------------------------------------------------------------------------

# After a real multi-hour lid-closed run, this is the question that matters: did the
# Mac sleep anyway? pmset keeps its own log of every sleep and its reason, so this is
# evidence rather than an impression.
test_afterwards() {
  section "Na een echte sessie: heeft de Mac tóch geslapen?"

  # The path contains a space. Unquoted, `tail` was reading two non-existent files and
  # the section came out empty every time — and because tail still exits 0, the fallback
  # never fired either.
  local log="$HOME/Library/Logs/Dopamine Code/dopamine-code.log"

  # Scope the verdict to the session that was actually run — at BOTH ends.
  #
  # Without a start time this check is not merely imprecise, it is backwards: this machine
  # has hundreds of entirely ordinary Clamshell Sleeps in its history, one for every lid
  # close ever made with the flag off. Reporting one of those as proof that the kernel veto
  # fails would condemn a mechanism that was never engaged.
  #
  # An open upper end is the same error mirrored, and it is not hypothetical. Measured here:
  # the session of 14:00:17 lasted three seconds — a SIGTERM from build.sh cleared the flag
  # at 14:00:20 — and the lid then shut at 14:03:42 "met status uit", producing a textbook
  # Clamshell Sleep at 14:03:47. With only a lower bound, that sleep lands inside the window
  # and the script condemns the core mechanism over an event from three minutes after it was
  # switched off.
  local since="${1:-}" upto="${2:-}" open_end=0 upto_given=0
  [ -n "$upto" ] && upto_given=1

  # The archive counts too. Since the log started rotating by rename, a session that ended
  # just as the file passed a megabyte leaves its markers in dopamine-code.1.log and an
  # empty current log — which used to leave BOTH bounds unset and hand the whole pmset
  # history to the verdict.
  # An ARRAY, not a string. The log path contains a space ("Logs/Dopamine Code/"), so an
  # unquoted "$sources" word-splits into two non-existent files and every read silently
  # returns nothing — the same unquoted-path-with-a-space that once made this whole section
  # print an empty report.
  local archive="${log%.log}.1.log"
  local -a sources=("$log")
  [ -f "$archive" ] && sources=("$archive" "$log")

  if [ -z "$since" ]; then
    # Both spellings: the switch was renamed from "Blijf actief" to "Wakker houden" on
    # 14 augustus 2026, and logs from before that are still on disk (and still rotate in).
    since="$(cat "${sources[@]}" 2>/dev/null | grep -E '(Blijf actief|Wakker houden) AAN' | tail -1 | cut -c1-19)"
  fi
  # Loopt er nú een sessie, dan weet de app zelf wanneer die begon. Dat helpt precies in het
  # geval waarin de log-grep niets vindt: het logboek is net geroteerd, of de app is herstart
  # na een sessie die nog steeds loopt. De grep hierboven blijft de eerste bron — na afloop
  # van een sessie is de app die start allang vergeten.
  if [ -z "$since" ]; then
    local cli json started epoch
    if cli="$(cli_path)"; then
      json="$("$cli" status --json 2>/dev/null)"
      started="$(json_field "$json" gestartOp)"
      if [ -n "$started" ]; then
        # De app schrijft ISO8601 in UTC; het logboek en pmset staan in lokale tijd.
        epoch="$(TZ=UTC date -j -f '%Y-%m-%dT%H:%M:%SZ' "$started" '+%s' 2>/dev/null)"
        [ -n "$epoch" ] && since="$(date -r "$epoch" '+%Y-%m-%d %H:%M:%S')"
        [ -n "$since" ] && printf '  (sessiestart uit de draaiende app: %s)\n' "$since"
      fi
    fi
  fi
  if [ -z "$since" ]; then
    # Fail closed. With no window the filter passed every Sleep event ever recorded, and
    # this machine has four perfectly ordinary Clamshell Sleeps from this afternoon alone —
    # so the one tool that judges the core promise would routinely convict it. No window,
    # no verdict.
    skip "Geen sessiestart in het logboek gevonden — geen venster, dus geen oordeel."
    echo "       Geef er zelf een mee als je weet wanneer de sessie liep:"
    echo "         ./verify.sh --after '2026-08-11 17:56:37' '2026-08-11 21:14:32'"
    echo
    echo "  Laatste 25 regels van het logboek:"
    cat "${sources[@]}" 2>/dev/null | tail -25 | sed 's/^/    /' || echo "    (geen logboek)"
    return
  else
    # The end of the window is the moment the flag verifiably reached 0, whatever caused it:
    # the user, a safety net, a SIGTERM or a quit. That single log line covers all four,
    # because every one of them goes through SleepFlag.verify().
    # Every way a session can end, not just the verified write.
    #
    # There is exactly one path that ends a session without SleepFlag.verify() running: the
    # guardian finds the flag already at 0 because something outside the app cleared it —
    # `sudo pmset -a disablesleep 0`, the command this project hands out in its own error
    # messages. That branch writes no flag, so the verify line never appears, the window
    # stayed open, and the next entirely ordinary lid-close got reported as a failure.
    if [ -z "$upto" ]; then
      upto="$(cat "${sources[@]}" 2>/dev/null | awk -v s="$since" '
        substr($0,1,19) > s &&
        (/SleepDisabled = 0, geverifieerd/ ||
         /van buitenaf op 0 gezet/ ||
         /Sessie afgesloten —/ ||
         /(Blijf actief|Wakker houden) UIT/) { print substr($0,1,19); exit }
      ')"
    fi
    if [ -z "$upto" ]; then
      upto="$(date '+%Y-%m-%d %H:%M:%S')"
      open_end=1
    fi
    printf '  Venster: %s → %s' "$since" "$upto"
    if [ "$open_end" = "1" ]; then
      if [ "$(read_flag)" = "true" ]; then
        printf ' (sessie loopt nog)\n'
      else
        # No closing line but the flag is down: killed with -9, or the log was rotated.
        # Widening to "now" can only produce a false alarm, never a false pass — but say so,
        # because an unexplained failure inside this window may not belong to the session.
        printf ' (geen afsluitregel gevonden; einde onbekend, venster loopt door tot nu)\n'
      fi
    elif [ "$upto_given" = "1" ]; then
      # Say what we know. Claiming the flag came down at a time the caller typed in would be
      # inventing evidence for a check whose whole job is to produce evidence.
      printf ' (bovengrens met de hand opgegeven)\n'
    else
      printf ' (vlag ging op %s terug naar 0)\n' "${upto##* }"
    fi
  fi

  # In `pmset -g log` the event type is the fourth whitespace field, after
  # "<date> <time> <tz>". Matching on the word "Sleep" anywhere would drag in every
  # PreventUserIdleSystemSleep assertion line.
  #
  # "Wake Requests" also has "Wake" in field four and is scheduled-maintenance bookkeeping,
  # not a wake. Measured here: 416 of 868 matching lines were those, so nearly half of the
  # twenty-line window was noise crowding out the events the verdict is computed from.
  local events
  events="$(pmset -g log 2>/dev/null | awk -v since="$since" -v upto="$upto" '
      ($4 == "Sleep" || $4 == "Wake") && !($4 == "Wake" && $5 == "Requests") {
        stamp = $1 " " $2
        if (since != "" && stamp < since) next
        if (upto  != "" && stamp > upto)  next
        print
      }' | tail -20)"

  # `since` is guaranteed non-empty here: the no-window case returned above rather than
  # judging. So "binnen het venster" is now true in all three verdicts, where the FOUT and
  # OVER texts used to claim it even when the filter had seen the entire history.
  if [ -z "$events" ]; then
    pass "Geen enkele Sleep- of Wake-gebeurtenis binnen het venster."
  else
    printf '%s\n' "$events" | cut -c1-150 | sed 's/^/    /'
    if printf '%s' "$events" | grep -qi clamshell; then
      fail "Clamshell Sleep binnen het venster — de Mac is door dichtklappen gaan slapen."
      echo "       Het kernelveto houdt op deze hardware geen stand; 'Mac wakker houden' lost dit niet op."
    else
      skip "Slaap/waak-gebeurtenissen binnen het venster, maar geen door de klep. Vergelijk de tijden."
    fi
  fi

  echo
  echo "  Dopamine Code's eigen logboek binnen het venster:"
  cat "${sources[@]}" 2>/dev/null | awk -v s="$since" -v u="$upto" '
      substr($0,1,19) >= s && (u == "" || substr($0,1,19) <= u)
    ' | tail -60 | sed 's/^/    /' || echo "    (geen logboek op $log)"
}

# --------------------------------------------------------------------------------------

# De enige controle in dit script die iets kapotmaakt, en daarom niet in de standaardronde.
#
# `SIGKILL` is per definitie niet af te vangen: de app krijgt geen enkele kans om de
# slaapblokkade terug te zetten. Wat er daarna gebeurt moet dus van buiten de app komen, en dat
# is precies wat hier gemeten wordt. Zonder deze test is het vangnet uit fase 2 een bewering.
test_killtest() {
  section "Vangnet: overleeft de slaapblokkade een kill -9?"

  local draaiend
  draaiend="$(app_pids)"
  if [ -z "${draaiend// /}" ]; then
    fail "Dopamine Code draait niet; er valt niets af te schieten."
    return
  fi
  if [ "$(read_flag)" != "true" ]; then
    fail "De slaapblokkade staat niet aan. Zet 'Mac wakker houden' eerst aan — zonder lopende sessie meet dit niets."
    return
  fi

  echo "  Dit schiet Dopamine Code hard af (kill -9) terwijl de Mac wakker gehouden wordt."
  echo "  De sessie die nu loopt is daarmee voorbij. Dat is precies wat er getest wordt:"
  echo "  het vangnet hoort de app binnen twee minuten terug te halen, waarna die de"
  echo "  slaapblokkade bij het starten opruimt."
  if ! ask "Doorgaan?"; then
    skip "Afgebroken; er is niets afgeschoten."
    return
  fi

  local begin=$SECONDS
  pkill -9 -x DopamineCode || { fail "kill -9 mislukte."; return; }
  echo "  Afgeschoten: $draaiend"

  local verstreken=0
  while [ $((SECONDS - begin)) -lt 180 ]; do
    [ "$(read_flag)" = "false" ] && break
    sleep 1
  done
  verstreken=$((SECONDS - begin))

  if [ "$(read_flag)" = "false" ]; then
    pass "De slaapblokkade stond na ${verstreken}s weer op 0."
    if [ "$verstreken" -le 120 ]; then
      pass "Binnen de belofte van twee minuten."
    else
      fail "Buiten de belofte van twee minuten (${verstreken}s)."
    fi
  else
    fail "De slaapblokkade staat na ${verstreken}s nog steeds aan."
    echo "       Zet hem zelf terug: sudo pmset -a disablesleep 0"
  fi

  local terug
  terug="$(app_pids)"
  if [ -n "${terug// /}" ]; then
    pass "Dopamine Code draait weer (pid ${terug% })."
  else
    fail "Dopamine Code is niet teruggekomen. Kijk in Instellingen → Diagnose of de wachter geladen is."
  fi

  echo
  printf '  Vangnet nu:      %s\n' "$(watchdog_line)"
  echo "  De laatste regels uit het logboek:"
  tail -14 "$HOME/Library/Logs/Dopamine Code/dopamine-code.log" 2>/dev/null | sed 's/^/    /'
}

# De updatecontrole is het enige waarlangs iets van buiten deze app binnenkomt. Bij een app
# met een wachtwoordloze root-route is dat de plek om streng op te zijn — niet omdat er nu
# iets mis is, maar omdat een latere wijziging het stil kan bederven.
test_update_check() {
  section "10. Bijwerken: de versievergelijking, de stempeling, en de grens van UpdateCheck"

  # --- 1. De vergelijking -------------------------------------------------------------
  #
  # Dit is de enige plek in de updatecontrole waar fout gaan géén storing oplevert maar
  # stil verkeerd gedrag: "1.9.0 is nieuwer dan 1.10.0" is precies wat je krijgt als iemand
  # dit ooit vervangt door een string-vergelijking, en dat merk je pas als niemand meer een
  # update aangeboden krijgt.
  local src="$PROJECT_DIR/Sources/DopamineCode/Version.swift"
  if [ ! -f "$src" ]; then
    fail "Version.swift ontbreekt."
  else
    local dir; dir="$(mktemp -d)"
    cat > "$dir/main.swift" <<'SWIFT'
import Foundation

var fouten = 0
func eis(_ voorwaarde: Bool, _ wat: String) {
    if !voorwaarde { print("FOUT: \(wat)"); fouten += 1 }
}
func v(_ s: String) -> Version? { Version(s) }

// Gewone volgorde.
eis(v("1.0.0")! < v("1.0.1")!, "1.0.0 < 1.0.1")
eis(v("1.0.0")! < v("1.1.0")!, "1.0.0 < 1.1.0")
eis(v("1.0.0")! < v("2.0.0")!, "1.0.0 < 2.0.0")
// Het geval dat een string-vergelijking omgooit.
eis(v("1.9.0")! < v("1.10.0")!, "1.9.0 < 1.10.0")
eis(v("2.0.0")! > v("1.99.99")!, "2.0.0 > 1.99.99")
// Gelijkheid, en de vormen die hetzelfde betekenen.
eis(v("1.2.3")! == v("1.2.3")!, "1.2.3 == 1.2.3")
eis(v("v1.2.3")! == v("1.2.3")!, "v-prefix telt niet mee")
eis(v("1.2")! == v("1.2.0")!, "1.2 == 1.2.0")
eis(v("1")! == v("1.0.0")!, "1 == 1.0.0")
eis(!(v("1.2.3")! < v("1.2.3")!), "gelijk is niet kleiner")
// Alles wat geen versie is, moet nil worden — niet een gok.
for rommel in ["", "  ", "release-final", "1.2.3-beta", "1.-2.0", "1.2.3.4",
               "abc", "1..2", ".1.2", "1.2.", "v", "99999999999999999999.0.0"] {
    eis(v(rommel) == nil, "'\(rommel)' hoort nil te zijn, werd \(String(describing: v(rommel)))")
}
print(fouten == 0 ? "OK" : "FOUTEN=\(fouten)")
exit(fouten == 0 ? 0 : 1)
SWIFT
    local build
    if ! command -v swiftc >/dev/null 2>&1; then
      # Geen toolchain: de app heeft die niet nodig om te draaien, dus dit is geen fout.
      skip "swiftc niet gevonden; de versievergelijking is niet getest."
    elif ! build="$(swiftc -O -o "$dir/probe" "$src" "$dir/main.swift" 2>&1)"; then
      # Wél een compiler, maar de proef bouwt niet. Dat is een echte fout: hier stil OVER
      # melden liet de eindregel "alles is in orde" zeggen terwijl er niets getest was.
      fail "De versieproef compileert niet: $(printf '%s' "$build" | grep error: | head -2 | tr '\n' ' ')"
    else
      local uit
      if uit="$("$dir/probe" 2>&1)"; then
        pass "Versievergelijking klopt op alle gevallen, inclusief 1.9.0 < 1.10.0."
      else
        fail "Versievergelijking deugt niet: $(printf '%s' "$uit" | tr '\n' ' ')"
      fi
    fi
    rm -rf "$dir"
  fi

  # --- 2. De stempeling ---------------------------------------------------------------
  #
  # Een app die de verkeerde versie over zichzelf zegt, biedt updates aan die er niet zijn
  # of verzwijgt updates die er wel zijn.
  local app="$PROJECT_DIR/build/Dopamine Code.app"
  [ -d "$app" ] || app="/Applications/Dopamine Code.app"
  if [ ! -d "$app" ]; then
    skip "Geen gebouwde app gevonden; bouw eerst met ./build.sh."
  else
    local gestempeld verwacht
    gestempeld="$(/usr/libexec/PlistBuddy -c 'Print :DCSourceVersion' "$app/Contents/Info.plist" 2>/dev/null || echo ONTBREEKT)"
    if [ "$gestempeld" = "ONTBREEKT" ]; then
      fail "De bundel draagt geen DCSourceVersion. Is hij met een oude build.sh gemaakt?"
    else
      verwacht="$(cd "$PROJECT_DIR" && git describe --tags --always --dirty 2>/dev/null || echo onbekend)"
      if [ "$gestempeld" = "$verwacht" ]; then
        pass "Bundelversie komt overeen met de bron ($gestempeld)."
      else
        # Geen fout: na een commit klopt een eerder gebouwde bundel gewoon niet meer.
        skip "Bundel zegt '$gestempeld', de bron staat op '$verwacht' — opnieuw bouwen om gelijk te trekken."
      fi
    fi
  fi

  # --- 3. De grens --------------------------------------------------------------------
  #
  # UpdateCheck leest een antwoord van een server die deze app niet beheert. Zolang daar
  # niets anders uitkomt dan twee strings om te tónen, kan een gekaapt of vervalst antwoord
  # niets. Die eigenschap is de hele veiligheidsredenering, dus hij hoort afgedwongen te
  # worden en niet alleen opgeschreven in het commentaar erboven.
  local f="$PROJECT_DIR/Sources/DopamineCode/UpdateCheck.swift"
  if [ ! -f "$f" ]; then
    fail "UpdateCheck.swift ontbreekt."
  else
    # Commentaar eraf: juist dit bestand legt in zijn commentaar uit wat het NIET doet.
    local verboden
    verboden="$(sed 's://.*::' "$f" \
      | grep -oE 'Process\(|NSTask|posix_spawn|\bsystem\(|dlopen|SleepFlag|pmset|disablesleep|createFile|write\(to:|removeItem|copyItem|\.launch\(\)' \
      | sort -u | tr '\n' ' ')"
    if [ -n "${verboden// /}" ]; then
      fail "UpdateCheck.swift raakt dingen aan die buiten zijn grens vallen: $verboden"
    else
      pass "UpdateCheck.swift voert niets uit, schrijft niets weg en raakt de vlag niet aan."
    fi
  fi
}

# De voorkeur "start bij inloggen" en wat het systeem werkelijk doet, horen hetzelfde te
# zeggen. Lopen ze uiteen, dan merk je dat pas bij het volgende inloggen — als de app er niet
# is. `LaunchAtLogin.reconcile()` trekt ze bij elke start gelijk; dit controleert of dat werkt.
test_login_item() {
  section "11. Start bij inloggen: zegt de voorkeur hetzelfde als het systeem?"

  local wens systeem hoe
  wens="$(defaults read "$APP_DOMAIN" launchAtLogin 2>/dev/null || echo 0)"

  systeem=0; hoe="niets"
  if [ -f "$HOME/Library/LaunchAgents/$APP_DOMAIN.agent.plist" ]; then
    systeem=1; hoe="LaunchAgent"
  fi
  # De app-vermelding in de background-task-database. Alleen het blok met ONZE bundle-id, en
  # alleen als de dispositie 'enabled' zegt: een vermelding die de gebruiker in
  # Systeeminstellingen heeft uitgezet blijft staan, maar telt niet als ingeschakeld.
  #
  # Regel voor regel, niet blok-voor-blok met een opgespaarde string: in awk ankert `$` op
  # het einde van de hele string en niet van een regel, dus een patroon met `$` tegen een
  # meerregelig blok matcht nooit. Dat kostte deze controle eerst een test die niet kón
  # slagen. De vergelijking is bovendien een exacte string en geen regex — het bundle-id
  # zit vol punten, en die zijn in een regex geen punten.
  if sfltool dumpbtm 2>/dev/null | awk -v id="$APP_DOMAIN" '
        /^ #[0-9]+:/ { disp = 0; zelfde = 0 }
        /Disposition:.*enabled/ { disp = 1 }
        {
          regel = $0
          sub(/^[[:space:]]+/, "", regel)
          if (regel == "Bundle Identifier: " id) zelfde = 1
          if (disp && zelfde) gevonden = 1
        }
        END { exit gevonden ? 0 : 1 }'; then
    systeem=1; [ "$hoe" = "niets" ] && hoe="SMAppService"
  fi

  if [ "$wens" = "1" ] && [ "$systeem" = "1" ]; then
    pass "Beide aan (via $hoe)."
  elif [ "$wens" != "1" ] && [ "$systeem" = "0" ]; then
    pass "Beide uit."
  elif [ -z "$(app_pids)" ]; then
    # Zonder draaiende app heeft reconcile() nog niet kunnen lopen; dan is dit geen fout
    # maar een nog niet uitgevoerde reparatie.
    skip "Voorkeur zegt '$wens', systeem zegt '$systeem' — de app draait niet, dus reconcile() heeft nog niet gelopen."
  else
    fail "Voorkeur zegt '$wens' maar het systeem zegt '$systeem' ($hoe), terwijl de app draait. LaunchAtLogin.reconcile() had dit gelijk moeten trekken."
  fi
}

# Vier talen die met de hand bijgehouden worden lopen uit de pas. Niet misschien: gegarandeerd,
# want een nieuwe tekst voeg je toe waar je bezig bent en de andere drie bestanden staan ergens
# anders. Een ontbrekende sleutel is bovendien niet stil — macOS toont dan de sleutel zelf in
# de knop — maar dat merk je alleen als je die taal draait, en dat doe je niet.
test_translations() {
  section "12. Vertalingen: hebben alle vier de talen dezelfde sleutels?"

  local bron="$PROJECT_DIR/Resources/nl.lproj/Localizable.strings"
  if [ ! -f "$bron" ]; then
    fail "Resources/nl.lproj/Localizable.strings ontbreekt — dat is de bron."
    return
  fi

  # Alleen echte sleutelregels: "sleutel" = "waarde"; Commentaar en lege regels vallen af.
  sleutels_van() { grep -oE '^[[:space:]]*"[^"]+"[[:space:]]*=' "$1" | tr -d ' "=' | sort; }

  local nl_keys; nl_keys="$(sleutels_van "$bron")"
  local aantal; aantal="$(printf '%s\n' "$nl_keys" | grep -c . )"
  pass "Bron (nl) heeft $aantal sleutels."

  local taal bestand mist extra
  for taal in en de fr; do
    bestand="$PROJECT_DIR/Resources/$taal.lproj/Localizable.strings"
    if [ ! -f "$bestand" ]; then
      fail "$taal: Localizable.strings ontbreekt."
      continue
    fi
    mist="$(comm -23 <(printf '%s\n' "$nl_keys") <(sleutels_van "$bestand") | tr '\n' ' ')"
    extra="$(comm -13 <(printf '%s\n' "$nl_keys") <(sleutels_van "$bestand") | tr '\n' ' ')"
    if [ -n "${mist// /}" ]; then
      fail "$taal mist: ${mist% }"
    elif [ -n "${extra// /}" ]; then
      # Geen fout maar wel rommel: een sleutel die nergens meer gebruikt wordt, of een typefout.
      skip "$taal heeft sleutels die nl niet kent: ${extra% }"
    else
      pass "$taal: compleet."
    fi
  done

  # Dezelfde invulwaarden in elke taal.
  #
  # `String(format:)` leest de opmaakaanduidingen uit de vertaalde zin, niet uit het
  # Nederlands. Staat er in het Frans één %d minder dan er waarden worden meegegeven, dan
  # verdwijnt die waarde stil; staat er één méér, dan leest Foundation een argument dat niet
  # bestaat — en dat is geen typefout maar een crash bij een gebruiker die je taal niet
  # spreekt. Vergelijken dus, per sleutel, en niet vertrouwen op zorgvuldigheid.
  local afwijkend=""
  for taal in en de fr; do
    bestand="$PROJECT_DIR/Resources/$taal.lproj/Localizable.strings"
    [ -f "$bestand" ] || continue
    while IFS= read -r sleutel; do
      [ -n "$sleutel" ] || continue
      local bron_spec taal_spec
      # Alleen de aanduidingen, gesorteerd: de vólgorde mag per taal verschillen (daar zijn
      # %1$@ en %2$@ voor), de verzameling niet.
      bron_spec="$(grep -F "\"$sleutel\" = " "$bron" | grep -oE '%[0-9]+\$[@df]|%[@df]' | sort | tr '\n' ' ')"
      taal_spec="$(grep -F "\"$sleutel\" = " "$bestand" | grep -oE '%[0-9]+\$[@df]|%[@df]' | sort | tr '\n' ' ')"
      [ "$bron_spec" = "$taal_spec" ] || afwijkend="$afwijkend $taal:$sleutel(nl='${bron_spec% }' $taal='${taal_spec% }')"
    done <<< "$nl_keys"
  done
  if [ -n "${afwijkend// /}" ]; then
    fail "Invulwaarden komen niet overeen:$afwijkend"
  else
    pass "Elke sleutel heeft in alle talen dezelfde invulwaarden."
  fi

  # En andersom: gebruikt de code sleutels die nergens gedefinieerd zijn? Dat levert een knop
  # op waar letterlijk "menu.voet.stop" in staat.
  #
  # Commentaar eerst weg, net als bij test_cli_purity. Zonder dat telt een sleutel die in een
  # documentatievoorbeeld staat mee als "in gebruik" — en dan meldt deze controle een fout
  # over een sleutel die nergens in de app voorkomt. Precies dat gebeurde bij het schrijven
  # ervan, met een voorbeeld in de doc-commentaar van L10n.swift.
  local gebruikt onbekend f
  gebruikt="$(for f in "$PROJECT_DIR/Sources"/*/*.swift; do
        [ -f "$f" ] || continue
        sed 's://.*::' "$f"
      done \
      | grep -oE '(Text|Label|Button|LabeledContent|Section)\("[a-z]+(\.[a-z]+)+"|L10n\.t\("[a-z]+(\.[a-z]+)+"' \
      | grep -oE '"[a-z]+(\.[a-z]+)+"' | tr -d '"' | sort -u)"
  if [ -z "$gebruikt" ]; then
    skip "Geen sleutelgebruik in de bronnen gevonden; nog niets omgezet?"
    return
  fi
  onbekend="$(comm -23 <(printf '%s\n' "$gebruikt") <(printf '%s\n' "$nl_keys") | tr '\n' ' ')"
  if [ -n "${onbekend// /}" ]; then
    fail "De code gebruikt sleutels die in nl ontbreken: ${onbekend% }"
  else
    pass "Elke sleutel die de code gebruikt, bestaat ($(printf '%s\n' "$gebruikt" | grep -c .) in gebruik)."
  fi
}

test_paneel() {
  section "14. Paneel: meters, kaarttoestand en de rangorde van waarschuwingen"

  local src="$PROJECT_DIR/Sources/DopamineCode/Meter.swift"
  if [ ! -f "$src" ]; then
    fail "Meter.swift ontbreekt."
  else
    local dir; dir="$(mktemp -d)"
    cat > "$dir/main.swift" <<'SWIFT'
import Foundation

var fouten = 0
func eis(_ voorwaarde: Bool, _ wat: String) {
    if !voorwaarde { print("FOUT: \(wat)"); fouten += 1 }
}

// --- de accumeter -------------------------------------------------------------
// De vulling is de stand, de zone is de grens. Ze mogen nooit hetzelfde getal zijn.
let vol = AccuMeter(percent: 84, grens: 15, aanDeLader: false)
eis(vol.vulling == 0.84, "84% vult 0,84, werd \(vol.vulling)")
eis(vol.zone == 0.15, "grens 15% geeft zone 0,15, werd \(vol.zone)")
eis(!vol.grijptIn, "84% boven een grens van 15% grijpt niet in")

// De grens is `<=`, precies zoals AppModel hem toepast. Op de grens zelf grijpt hij dus in.
eis(AccuMeter(percent: 15, grens: 15, aanDeLader: false).grijptIn, "15 <= 15 grijpt in")
eis(!AccuMeter(percent: 16, grens: 15, aanDeLader: false).grijptIn, "16 > 15 grijpt niet in")

// Aan de lader kan dit vangnet niet afgaan — AppModel eist `!battery.onAC`. Een meter die
// hem dan als scherp tekent, belooft iets wat niet gebeurt.
eis(!AccuMeter(percent: 5, grens: 15, aanDeLader: true).grijptIn, "aan de lader grijpt hij niet in")
eis(AccuMeter(percent: 5, grens: 15, aanDeLader: true).sluimert, "aan de lader sluimert het vangnet")
eis(!AccuMeter(percent: 84, grens: 15, aanDeLader: false).sluimert, "op accu sluimert het niet")

// Rommel van buiten mag niet buiten de balk tekenen.
eis(AccuMeter(percent: 140, grens: 15, aanDeLader: false).vulling == 1.0, "boven 100 klemt op 1")
eis(AccuMeter(percent: -8, grens: 15, aanDeLader: false).vulling == 0.0, "onder 0 klemt op 0")
eis(AccuMeter(percent: 50, grens: 140, aanDeLader: false).zone == 1.0, "grens boven 100 klemt op 1")
eis(AccuMeter(percent: 50, grens: -8,  aanDeLader: false).zone == 0.0, "grens onder 0 klemt op 0")

// --- de warmtemeter -----------------------------------------------------------
// Vier stappen, want macOS geeft er vier. De laatste is waar de sessie stopt.
let koel = WarmteMeter(stap: 1)
eis(koel.aantal == 4, "vier stappen, werd \(koel.aantal)")
eis(koel.stopBij == 4, "stopt bij de vierde")
eis(koel.brandt(1) && !koel.brandt(2), "bij stap 1 brandt alleen het eerste blokje")
eis(!koel.grijptIn, "stap 1 grijpt niet in")

let heet = WarmteMeter(stap: 4)
eis(heet.grijptIn, "stap 4 grijpt in")
eis(heet.brandt(1) && heet.brandt(4), "bij stap 4 branden ze allemaal")
eis(!WarmteMeter(stap: 2).brandt(0), "index 0 brandt nooit")
eis(!WarmteMeter(stap: 2).brandt(-3), "een negatieve index brandt nooit")

// Een stap buiten 1…4 mag niet stil doorglippen naar "alles in orde".
eis(WarmteMeter(stap: 9).stap == 4, "boven het aantal klemt op het aantal")
eis(WarmteMeter(stap: 0).stap == 1, "onder 1 klemt op 1")

print(fouten == 0 ? "OK" : "FOUTEN=\(fouten)")
exit(fouten == 0 ? 0 : 1)
SWIFT
    local build
    if ! command -v swiftc >/dev/null 2>&1; then
      skip "swiftc niet gevonden; de meters zijn niet getest."
    elif ! build="$(swiftc -O -o "$dir/probe" "$src" "$dir/main.swift" 2>&1)"; then
      fail "De meterproef compileert niet: $(printf '%s' "$build" | grep error: | head -2 | tr '\n' ' ')"
    else
      local uit
      if uit="$("$dir/probe" 2>&1)"; then
        pass "Accumeter en warmtemeter rekenen goed, inclusief de lader-uitzondering."
      else
        fail "Meters deugen niet: $(printf '%s' "$uit" | tr '\n' ' ')"
      fi
    fi
    rm -rf "$dir"
  fi

  # --- 2. De kaarttoestand ------------------------------------------------------------
  local src2="$PROJECT_DIR/Sources/DopamineCode/KaartToestand.swift"
  if [ ! -f "$src2" ]; then
    fail "KaartToestand.swift ontbreekt."
  else
    local dir2; dir2="$(mktemp -d)"
    cat > "$dir2/main.swift" <<'SWIFT'
import Foundation

var fouten = 0
func eis(_ voorwaarde: Bool, _ wat: String) {
    if !voorwaarde { print("FOUT: \(wat)"); fouten += 1 }
}

let nu = Date(timeIntervalSince1970: 1_000_000)

// Niets aan: de kaart biedt het armen aan, want dat is het enige zinnige aanbod.
let uit = KaartToestand(intendedOn: false, armTot: nil, sessieStart: nil, deadline: nil, nu: nu)
eis(uit.isUit, "niets aan is .uit")
eis(uit.voortgang == 0, "uit heeft geen voortgang")

// Gearmd wint van uit, ook al is intendedOn nog vals: er staat iets te gebeuren.
let arm = KaartToestand(intendedOn: false, armTot: nu.addingTimeInterval(270),
                        sessieStart: nil, deadline: nil, nu: nu)
eis(arm.isGearmd, "armTot in de toekomst is .gearmd")

// Een arming die verlopen is telt niet meer mee.
let armVoorbij = KaartToestand(intendedOn: false, armTot: nu.addingTimeInterval(-1),
                               sessieStart: nil, deadline: nil, nu: nu)
eis(armVoorbij.isUit, "een verlopen arming valt terug naar .uit")

// Aan: de boog toont het verstreken deel.
let aan = KaartToestand(intendedOn: true,
                        armTot: nil,
                        sessieStart: nu.addingTimeInterval(-3600),
                        deadline: nu.addingTimeInterval(3600),
                        nu: nu)
eis(aan.isAan, "intendedOn met deadline is .aan")
eis(abs(aan.voortgang - 0.5) < 0.001, "halverwege is 0,5, werd \(aan.voortgang)")

// Aan zonder deadline mag niet als 100% vol tekenen — dat zou "bijna klaar" zeggen.
let aanZonder = KaartToestand(intendedOn: true, armTot: nil, sessieStart: nu,
                              deadline: nil, nu: nu)
eis(aanZonder.isAan, "intendedOn zonder deadline is nog steeds .aan")
eis(aanZonder.voortgang == 0, "zonder deadline is de boog leeg, werd \(aanZonder.voortgang)")

// Een deadline die voorbij is: nul, niet negatief, en de boog blijft binnen de rand.
let over = KaartToestand(intendedOn: true, armTot: nil,
                         sessieStart: nu.addingTimeInterval(-7200),
                         deadline: nu.addingTimeInterval(-60), nu: nu)
eis(over.voortgang == 1.0, "voortgang klemt op 1")

eis(KaartToestand(intendedOn: true, armTot: nil, sessieStart: nu, deadline: nu, nu: nu).voortgang == 0,
    "deadline gelijk aan de start geeft geen NaN")

// Aan wint van gearmd: staat de sessie al te lopen, dan is de arming niet meer het nieuws.
let allebei = KaartToestand(intendedOn: true, armTot: nu.addingTimeInterval(270),
                            sessieStart: nu, deadline: nu.addingTimeInterval(60), nu: nu)
eis(allebei.isAan, "een lopende sessie wint van een arming")

print(fouten == 0 ? "OK" : "FOUTEN=\(fouten)")
exit(fouten == 0 ? 0 : 1)
SWIFT
    local build2
    if ! command -v swiftc >/dev/null 2>&1; then
      skip "swiftc niet gevonden; de kaarttoestand is niet getest."
    elif ! build2="$(swiftc -O -o "$dir2/probe" "$src2" "$dir2/main.swift" 2>&1)"; then
      fail "De kaartproef compileert niet: $(printf '%s' "$build2" | grep error: | head -2 | tr '\n' ' ')"
    else
      local uit2
      if uit2="$("$dir2/probe" 2>&1)"; then
        pass "Kaarttoestand klopt in alle drie de toestanden en op de randen."
      else
        fail "Kaarttoestand deugt niet: $(printf '%s' "$uit2" | tr '\n' ' ')"
      fi
    fi
    rm -rf "$dir2"
  fi
}

# De formule in de Homebrew-tap wijst naar een tarball van een tag. Blijft die achter op de
# nieuwste release, dan installeert `brew install` stilletjes een oude versie — geen fout,
# geen melding, en de beheerder merkt het niet omdat zijn eigen app gewoon werkt. release.sh
# werkt de formule bij, maar dit is de controle die het opmerkt als dat ooit misgaat.
test_tap() {
  section "13. Homebrew-tap: wijst de formule naar de nieuwste release?"

  local formule
  if ! command -v brew >/dev/null 2>&1; then
    skip "brew niet geïnstalleerd; de tap is niet te controleren."
    return
  fi
  formule="$(brew --repository 2>/dev/null)/Library/Taps/peter46jan/homebrew-dopamine/Formula/dopamine-code.rb"
  if [ ! -f "$formule" ]; then
    skip "De tap staat hier niet; haal hem op met 'brew tap peter46jan/dopamine'."
    return
  fi

  local in_formule laatste_tag
  in_formule="$(grep -oE 'tags/v[0-9]+\.[0-9]+\.[0-9]+\.tar\.gz' "$formule" \
                | head -1 | sed 's|tags/||; s|\.tar\.gz||')"
  laatste_tag="$(cd "$PROJECT_DIR" && git tag -l 'v*' --sort=-v:refname | head -1)"

  if [ -z "$in_formule" ]; then
    fail "Kon geen versie uit de formule lezen; staat er nog een geldige url in?"
  elif [ -z "$laatste_tag" ]; then
    skip "Nog geen tags in deze repo, dus niets om tegen af te zetten."
  elif [ "$in_formule" = "$laatste_tag" ]; then
    pass "Formule en nieuwste tag staan allebei op $laatste_tag."
  else
    fail "Formule wijst naar $in_formule, maar de nieuwste tag is $laatste_tag — 'brew install' geeft dus de oude versie."
  fi
}

case "${1:-}" in
  --report)  report; exit 0 ;;
  # Niet in de standaardronde: de kop bovenaan belooft dat die niets kapotmaakt.
  --killtest) test_killtest; exit "$FAILURES" ;;
  # Return the real count, not 0. This is the one check that judges the core promise, and
  # exiting 0 after printing "de Mac is door dichtklappen gaan slapen" makes a failure
  # machine-indistinguishable from a pass — in a wrapper, a cron line, or a plain `&& echo ok`.
  --after)   test_afterwards "${2:-}" "${3:-}"; exit "$FAILURES" ;;
  --flag)    test_flag_roundtrip ;;
  --display) test_display ;;
  # Losse ronde: deze drie hebben geen wachtwoord nodig en geen draaiende sessie, dus ze
  # zijn bruikbaar als snelle controle na een wijziging aan de updatecontrole.
  --update)  test_update_check ;;
  --login)   test_login_item ;;
  --talen)   test_translations ;;
  --tap)     test_tap ;;
  --paneel)  test_paneel ;;
  *)
    report
    test_includedir
    test_flag_roundtrip
    test_grant
    test_backlight
    test_lock
    test_cli_purity
    test_watchdog_purity
    test_display
    test_update_check
    test_login_item
    test_translations
    test_tap
    test_paneel
    ;;
esac

section "Resultaat"
if [ "$FAILURES" -eq 0 ]; then
  printf '%sAlles wat automatisch te testen is, is in orde.%s\n' "$GREEN" "$OFF"
else
  printf '%s%d controle(s) mislukt.%s\n' "$RED" "$FAILURES" "$OFF"
fi
printf 'Het echte bewijs blijft een run van meerdere uren met de klep dicht.\n'
printf 'Kijk daarna in "$HOME/Library/Logs/Dopamine Code/dopamine-code.log".\n'
exit "$FAILURES"
