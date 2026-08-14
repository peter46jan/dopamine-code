#!/bin/bash
#
# Verifies the parts of Dopamine Code that cannot be tested without your password, plus the
# ones that change what is on screen. Nothing here is destructive: every flag it sets
# it also puts back.
#
#   ./verify.sh            run everything, asking before each step that needs consent
#   ./verify.sh --flag     only the disablesleep round trip (the critical one)
#   ./verify.sh --display  only the display-sleep test
#   ./verify.sh --report   read-only status report, no password, no side effects
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
  printf '  Handtekening     %s\n' "$(codesign -dvv '/Applications/Dopamine Code.app' 2>&1 | grep '^Authority' | head -1 | cut -d= -f2-)"
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

case "${1:-}" in
  --report)  report; exit 0 ;;
  # Return the real count, not 0. This is the one check that judges the core promise, and
  # exiting 0 after printing "de Mac is door dichtklappen gaan slapen" makes a failure
  # machine-indistinguishable from a pass — in a wrapper, a cron line, or a plain `&& echo ok`.
  --after)   test_afterwards "${2:-}" "${3:-}"; exit "$FAILURES" ;;
  --flag)    test_flag_roundtrip ;;
  --display) test_display ;;
  *)
    report
    test_includedir
    test_flag_roundtrip
    test_grant
    test_backlight
    test_lock
    test_display
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
