#!/bin/bash
#
# Brengt een versie uit.
#
#   ./release.sh 1.1.0
#
# Tagt de huidige commit, duwt de tag, en maakt er een GitHub Release van — als CONCEPT,
# met de commits sinds de vorige tag als opzet voor de notities. Publiceren doe je zelf,
# nadat je die tekst hebt gelezen.
#
# Waarom een concept en niet meteen live: een tag die eenmaal gepusht is, is de versie die
# mensen te zien krijgen via de updatecontrole in de app. Zit er iets fout in, dan wil je
# dat merken vóórdat de melding bij iedereen verschijnt, niet erna.
set -euo pipefail

cd "$(dirname "$0")"

say() { printf '\033[1m%s\033[0m\n' "$*"; }
warn() { printf '\033[33m%s\033[0m\n' "$*" >&2; }
die() { printf '\033[31m%s\033[0m\n' "$*" >&2; exit 1; }

VERSION="${1:-}"
[ -n "$VERSION" ] || die "Gebruik: ./release.sh 1.1.0"

# Exact drie getallen. `build.sh` leest de tag terug om er CFBundleShortVersionString van te
# maken, en Apple accepteert daar niets anders dan één tot drie getallen met punten ertussen.
# Alles wat hier doorheen komt moet daar passen, dus de streng is hier.
case "$VERSION" in
  *[!0-9.]*|''|*..*|.*|*.) die "'$VERSION' is geen versienummer. Verwacht: 1.2.3" ;;
esac
[ "$(printf '%s' "$VERSION" | tr -cd . | wc -c | tr -d ' ')" = "2" ] \
  || die "'$VERSION' moet drie delen hebben: 1.2.3"

TAG="v$VERSION"

# --- controles vooraf ---------------------------------------------------------

git rev-parse --git-dir >/dev/null 2>&1 || die "Dit is geen git-repo."

[ -z "$(git status --porcelain)" ] \
  || die "Er staan wijzigingen open. Commit of stash ze eerst — een tag hoort op een schone boom te staan."

BRANCH="$(git rev-parse --abbrev-ref HEAD)"
[ "$BRANCH" = "main" ] || warn "Je staat op '$BRANCH', niet op main."

git rev-parse "$TAG" >/dev/null 2>&1 && die "Tag $TAG bestaat al."
if git ls-remote --exit-code --tags origin "refs/tags/$TAG" >/dev/null 2>&1; then
  die "Tag $TAG staat al op de remote."
fi

# Een tag op een commit die niet gepusht is, wijst voor iedereen behalve jou nergens heen.
git fetch -q origin "$BRANCH" 2>/dev/null || true
if ! git merge-base --is-ancestor HEAD "origin/$BRANCH" 2>/dev/null; then
  die "HEAD staat niet op de remote. Push eerst je commits."
fi

command -v gh >/dev/null 2>&1 || die "gh (de GitHub CLI) is niet geïnstalleerd."
# "owner/repo" uit de remote-URL, met gewone parameteruitbreiding.
#
# Niet met `sed -E` en een luie kwantor: `+?` bestaat niet in BSD sed, en dat is de sed die
# op macOS staat. Dat brak hier op de eerste echte run — de wachtposten hierboven sloegen bij
# het testen altijd eerder af, dus deze regel was nog nooit uitgevoerd.
#
# Werkt voor beide vormen die git teruggeeft:
#   git@github.com:owner/repo.git
#   https://github.com/owner/repo(.git)
REPO_URL="$(git remote get-url origin)"
REPO_URL="${REPO_URL%.git}"
REPO_URL="${REPO_URL%/}"
REPO_NAAM="${REPO_URL##*/}"
REPO_REST="${REPO_URL%/*}"
REPO_EIGENAAR="${REPO_REST##*[:/]}"
REPO="$REPO_EIGENAAR/$REPO_NAAM"
[ -n "$REPO_NAAM" ] && [ -n "$REPO_EIGENAAR" ] \
  || die "Kon 'owner/repo' niet uit de remote-URL halen: $(git remote get-url origin)"
gh repo view "$REPO" >/dev/null 2>&1 \
  || die "gh kan $REPO niet zien. Draait het juiste account? Kijk met 'gh auth status'."

# --- de notities --------------------------------------------------------------

PREVIOUS="$(git describe --tags --abbrev=0 2>/dev/null || true)"
if [ -n "$PREVIOUS" ]; then
  RANGE="$PREVIOUS..HEAD"
  say "Commits sinds $PREVIOUS:"
else
  RANGE="HEAD"
  say "Commits (dit is de eerste release):"
fi

# Alleen de onderwerpregel. De uitgebreide toelichting in dit project is vaak vijftien
# regels — waardevol in de geschiedenis, te veel voor een lijstje release-notities.
NOTES="$(git log --reverse --format='- %s' "$RANGE")"
[ -n "$NOTES" ] || die "Geen commits sinds $PREVIOUS. Er is niets om uit te brengen."
printf '%s\n\n' "$NOTES"

# --- bevestigen ---------------------------------------------------------------

printf 'Tag %s aanmaken op %s en pushen? [j/N] ' "$TAG" "$(git rev-parse --short HEAD)"
read -r ANTWOORD
case "$ANTWOORD" in
  j|J|ja|Ja) ;;
  *) die "Afgebroken. Er is niets gewijzigd." ;;
esac

# --- uitbrengen ---------------------------------------------------------------

git tag -a "$TAG" -m "$TAG"
say "✓ tag $TAG aangemaakt"

# Vanaf hier kan een halve mislukking iets achterlaten, dus elke stap ruimt zichzelf op.
if ! git push -q origin "$TAG"; then
  git tag -d "$TAG" >/dev/null
  die "Pushen van de tag mislukte. De lokale tag is weer weggehaald."
fi
say "✓ tag gepusht"

if ! URL="$(gh release create "$TAG" --repo "$REPO" --draft --title "$TAG" --notes "$NOTES" 2>&1)"; then
  warn "De tag staat er, maar het aanmaken van de release mislukte:"
  warn "$URL"
  warn "Je kunt hem met de hand maken, of de tag terugtrekken met:"
  warn "  git push origin :refs/tags/$TAG && git tag -d $TAG"
  exit 1
fi
say "✓ concept-release aangemaakt"

printf '\n'
say "Nu jij: lees de notities na en publiceer hem."
printf '  %s\n' "$URL"
printf '\n'
printf 'Zolang de release een concept is, ziet de updatecontrole in de app hem niet.\n'
printf 'Pas na publiceren krijgen mensen te horen dat %s er is.\n' "$VERSION"
