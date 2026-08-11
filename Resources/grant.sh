#!/bin/bash
#
# Installs (or removes) the passwordless sudoers grant Dopamine Code needs.
#
# The grant permits exactly two fully-specified commands and nothing else:
#     /usr/bin/pmset -a disablesleep 1
#     /usr/bin/pmset -a disablesleep 0
#
# Because the Cmnd entries carry their arguments, sudo requires the user's command
# line to match those arguments exactly. A bare `/usr/bin/pmset` would instead have
# handed over passwordless `pmset restoredefaults`, `pmset schedule wake ...` and the
# rest of power management as root.
#
# Must be run as root. Dopamine Code invokes it through an authorisation prompt; you can also
# run it yourself. The account name goes through `env` rather than as a sudo-level
# assignment, because macOS sudoers uses env_reset without setenv and refuses those:
#
#     sudo /usr/bin/env DOPAMINE_USER="$USER" /bin/bash '/Applications/Dopamine Code.app/Contents/Resources/grant.sh'
#     sudo '/Applications/Dopamine Code.app/Contents/Resources/grant.sh' --remove
#
set -euo pipefail

DST="/etc/sudoers.d/dopamine-code-disablesleep"

# The filename must contain no dot and must not end in '~'. sudo's @includedir skips
# both silently: no error, no log, just a grant that never applies.
case "$(basename "$DST")" in
  *.*|*~) echo "fout: bestandsnaam ${DST##*/} wordt door sudo genegeerd." >&2; exit 1 ;;
esac

if [ "$(id -u)" -ne 0 ]; then
  echo "fout: dit script moet als root draaien (sudo $0)." >&2
  exit 1
fi

# Removal comes first, and needs no account name: it is `rm -f` on two fixed paths.
#
# It used to sit below the DOPAMINE_USER/SUDO_USER checks, which meant the grant could not
# be revoked from a plain root shell (`sudo -i`, a root launchd job, recovery) — exactly
# the contexts you end up in when something has gone wrong and you want the rule gone.
if [ "${1:-}" = "--remove" ]; then
  rm -f "$DST" "/etc/sudoers.d/wakker-disablesleep"
  # The removal itself is what matters. A failing `visudo -c` here means some *other*
  # drop-in is broken; reporting that as a failed removal would leave the app claiming
  # the rule is still active when it is gone.
  if ! /usr/sbin/visudo -c >/dev/null 2>&1; then
    echo "let op: sudoers parst niet schoon, maar dat komt niet door $DST — die is verwijderd." >&2
  fi
  echo "verwijderd: $DST"
  exit 0
fi

# Under `do shell script ... with administrator privileges` the script runs as root with
# SUDO_USER unset, so `id -un` would yield "root" and we would install a useless
# root-only rule. The caller passes the real account name in.
USER_NAME="${DOPAMINE_USER:-${SUDO_USER:-}}"
if [ -z "$USER_NAME" ] || [ "$USER_NAME" = "root" ]; then
  echo "fout: geen bruikbare gebruikersnaam. Zet DOPAMINE_USER of draai via sudo." >&2
  exit 1
fi

# Reject anything that is not a plain local account name before it reaches the file.
if ! printf '%s' "$USER_NAME" | grep -Eq '^[A-Za-z0-9._-]+$'; then
  echo "fout: ongeldige gebruikersnaam '$USER_NAME'." >&2
  exit 1
fi
if ! id -u "$USER_NAME" >/dev/null 2>&1; then
  echo "fout: gebruiker '$USER_NAME' bestaat niet." >&2
  exit 1
fi

# A drop-in is only read if /etc/sudoers actually includes the directory. If that line
# were missing, installing the file would appear to succeed and change nothing.
if ! grep -Eq '^[[:space:]]*[#@]includedir[[:space:]]+/(private/)?etc/sudoers\.d' /etc/sudoers; then
  echo "fout: /etc/sudoers bevat geen includedir voor /etc/sudoers.d — drop-in zou genegeerd worden." >&2
  exit 1
fi

TMP="$(mktemp /tmp/dopamine-sudoers.XXXXXX)"
trap 'rm -f "$TMP"' EXIT

# This comment is the recovery note that outlives the app: if Dopamine Code is ever deleted while
# the flag is set, this file is what is left to explain how to undo it. So it states the
# real escape hatch, not a command that only works from inside the bundle.
cat > "$TMP" <<EOF
# Dopamine Code — passwordless grant, installed by Dopamine Code.app.
# Permits ONE user to run, as root, exactly two fully-specified commands and nothing else.
#
# Mac will not sleep any more? Undo it with:
#     sudo pmset -a disablesleep 0
# Check it took effect (pmset -g does NOT print this until it has been set once):
#     ioreg -r -d 1 -c IOPMrootDomain | grep SleepDisabled
# Remove this grant:
#     sudo rm $DST
$USER_NAME ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 1, /usr/bin/pmset -a disablesleep 0
EOF

# Validate BEFORE the file lands in /etc/sudoers.d. A syntax error in that directory
# poisons the whole sudoers parse and can lock you out of sudo entirely.
if ! /usr/sbin/visudo -cf "$TMP" >/dev/null; then
  echo "fout: gegenereerde regel komt niet door visudo; niets geïnstalleerd." >&2
  exit 1
fi

/usr/bin/install -m 0440 -o root -g wheel "$TMP" "$DST"

# Post-install self-check against the real /etc/sudoers plus every drop-in. If the
# combined parse fails, roll our file back rather than leaving sudo broken.
if ! /usr/sbin/visudo -c >/dev/null; then
  rm -f "$DST"
  echo "fout: sudoers parst niet na installatie; regel teruggedraaid." >&2
  exit 1
fi

# Only once the new rule is installed AND the combined parse is clean: the check above
# deletes $DST when it fails, and removing the legacy rule before that point could leave
# the machine with no grant at all.
LEGACY="/etc/sudoers.d/wakker-disablesleep"
if [ -f "$LEGACY" ]; then
  rm -f "$LEGACY"
  echo "oude regel verwijderd: $LEGACY"
fi

echo "geïnstalleerd: $DST (root:wheel 0440) voor gebruiker $USER_NAME"
