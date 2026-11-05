#!/usr/bin/env bash
# tools/build-quiet-dawn.sh — de Dawn-archive ANT kalm maken, als stap die iemand
# anders ook kan draaien, en met de afwijking op het papier in plaats van eronder.
#
# Het probleem dat dit oplost. kDeko3dDiag (elke 300e frame: GPU laten wachten plus
# ~4 miljoen pixels op de CPU doorlopen = een hapering per 5 s, ook in menu en bij
# pauze) wordt door de gepinde upstream-patch op AAN gezet. Die vlag uitzetten in de
# Dawn-werkboom kan niet: scripts/patch-dawn-switch.py toetst of de upstream-patch
# zich volledig uit de boom laat terugdraaien, en dan klopt één gewijzigde regel niet
# meer. Dat is good behaviour — het is precies de check die voorkomt dat wij ongemerkt
# een andere Dawn linken dan ons ontvangstbewijs claimt.
#
# De route die wél kan. Delta állerdeerst, dan de archive bouwen in de container met
# dezelfde gcc als het origineel, dan de boom weer pin-gelijk maken en de delta-hash
# in een marker zetten. Die marker wordt door tools/render-deps.sh --make in het
# ontvangstbewijs van het pakket opgenomen, en --install/--verify tonen hem. Een
# ontvanger krijgt dan een pakket waarvan het papier zegt: deze stack is gebouwd met
# <delta-sha> bovenop de pinned patch. Aantoonbaar stil, in plaats van stilzwijgend.
#
# Waarom Docker en niet de host: deze build-boom is in een container geboren
# (build.ninja verwijst naar /deps/… en /opt/devkitpro/…), dus precies die omgeving
# is hier de correcte. De host-ninja faalt erop, en dat is géen verlies: de container
# gebruikt gcc 15.2.0, dezelfde als waarmee de archive oorspronkelijk gebouwd is, dus
# de 536 bytes die wegvallen komen uit dezelfde compiler-versie.
#
# Gebruik: bash tools/build-quiet-dawn.sh [--restore]
#   --restore: de kalmte ongedaan maken (archive met diagnostiek terug, marker weg).
set -uo pipefail

WS="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEPS="${MKW_DEKO3D_DEPS_DIR:-$HOME/mkw-toolchain/deps/native-deko3d}"
DAWN="$DEPS/dawn"
BUILD="$DEPS/dawn-build-switch"
ARCHIVE="$BUILD/src/dawn/native/libwebgpu_dawn.a"
QUIET="$ARCHIVE.quiet"
LOUD="$ARCHIVE.diag-on.bak"
DELTA="$WS/tools/patches/dawn-diagnostics-off.diff"
MARKER="$DEPS/.mkw-render-diagnostics"
IMAGE="devkitpro/devkita64"

die() { printf 'Fout: %s\n' "$1" >&2; shift; for l in "$@"; do printf '      %s\n' "$l" >&2; done; exit 1; }
say() { printf '  %s\n' "$1"; }

# Transactioneel: de Dawn-werkboom mag onder geen beding afgeweken achterblijven. Zonder
# deze afhandeling liet een eerdere versie van dit script de delta staan nadat de
# container-bouw afbrak — en dan faalt de upstream-audit bij de eerstvolgende bouw met
# een melding die naar de bron wijst in plaats van naar dit script.
DELTA_APPLIED=0
cleanup() {
  local rc=$?
  if [ "$DELTA_APPLIED" = 1 ]; then
    if (cd "$DAWN" && patch -p1 -R --forward < "$DELTA") >/dev/null 2>&1; then
      say "afhandeling: delta teruggezet, werkboom weer pin-gelijk"
    else
      printf 'Fout: dit script brak met de TOEGEPASTE delta in %s\n' "$DAWN" >&2
      printf '      Herstel met: git -C %s checkout -- src/dawn/native/deko3d/DeviceDeko3d.h\n' "$DAWN" >&2
    fi
  fi
  return $rc
}
trap cleanup EXIT

[ -d "$DAWN" ] || die "geen Dawn-werkboom in $DAWN" "Deze stap bouwt de renderstack; die bron staat in de deps-map."
[ -f "$DELTA" ] || die "delta ontbreekt: $DELTA"
[ -f "$ARCHIVE" ] || die "geen bestaande archive: $ARCHIVE" "Zonder valnet wil ik niet ombouwen."

# --restore: terugschakelen en klaar.
if [ "${1:-}" = "--restore" ]; then
  [ -f "$LOUD" ] || die "er ligt geen kalme archive om terug te draaien ($LOUD)"
  cp -f "$LOUD" "$ARCHIVE"
  rm -f "$MARKER"
  echo ">> teruggezet: archive met diagnostiek aan, marker weg"
  say "archive sha256 $(sha256sum "$ARCHIVE" | cut -c1-16)… ($(wc -c < "$ARCHIVE" | tr -d ' ') B)"
  exit 0
fi

echo "== 1. omgeving"
command -v docker >/dev/null 2>&1 || die "geen docker-command op deze host"
docker info >/dev/null 2>&1 || die "de docker-daemon draait niet" "Start Docker Desktop; zonder daemon kan deze stap niet bouwen."
if docker image inspect "$IMAGE" >/dev/null 2>&1; then
  say "image $IMAGE aanwezig"
else
  say "image $IMAGE wordt opgehaald (~1 GB, eenmalig)"
  docker pull -q "$IMAGE" >/dev/null || die "pulled niet: $IMAGE — netwerk of dockerhub"
fi
# Let op: Git Bash zetten een los argument als `/opt/...` andersom naar een Windows-pad
# (hier: C:/Program Files/Git1/opt/...), dus dit moet met MSYS_NO_PATHCONV — dezelfde
# val die we al in de docker-run van de bouw zelf ving. Zonder die vlag lijkt het alsof
# de image geen compiler heeft.
gcc_in_image=$(MSYS_NO_PATHCONV=1 docker run --rm --entrypoint /opt/devkitpro/devkitA64/bin/aarch64-none-elf-g++ "$IMAGE" --version 2>&1 | grep -a -m1 'aarch64-none-elf-g++' || true)
say "compiler in die image: ${gcc_in_image:-onbekend}"

echo
echo "== 2. delta"
delta_sha=$(sha256sum "$DELTA" | cut -d' ' -f1)
say "tools/patches/dawn-diagnostics-off.diff  sha256 ${delta_sha:0:16}…"
if (cd "$DAWN" && patch -p1 -R --dry-run --forward < "$DELTA") >/dev/null 2>&1; then
  say "delta staat al in de werkboom"
  DELTA_APPLIED=1
elif (cd "$DAWN" && patch -p1 -N --forward < "$DELTA") >/dev/null 2>&1; then
  say "delta toegepast"
  DELTA_APPLIED=1
else
  die "de delta past niet meer op $DAWN" "upstream (pin 13abc3bc) wijzigde DeviceDeko3d.h; maak de delta opnieuw."
fi

echo
echo "== 3. archive bouwen"
cp -n "$ARCHIVE" "$LOUD" 2>/dev/null || true
t0=$(date +%s)
# De container moet exact het pad zien dat in CMakeCache.txt staat (hier
# /deps/native-deko3d/dawn). Mount je de deps-zelf op /deps, dan ligt de bron op
# /deps/dawn, herken cmake zijn eigen cache niet, en faalt de bouw met een
# argument-gezeur in plaats van met die mededeling. Daarom: de PARENT van $DEPS
# mounten en het geneste pad aanzouden. Slashes, want `cygpath -w` geeft backslashes
# en die mounten hier een lege boom.
# De sleutel heet hier niet CMAKE_HOME_DIRECTORY maar Dawn_SOURCE_DIR, en het bestand
# heeft CRLF-einden: de CR eraf halen is het verschil tussen "/deps/native-deko3d/dawn"
# en een pad dat op niets wijst.
cache_dir=$(tr -d '\r' < "$BUILD/CMakeCache.txt" 2>/dev/null \
  | awk -F= '/^Dawn_SOURCE_DIR|^CMAKE_HOME_DIRECTORY/{print $2; exit}')
case "$cache_dir" in
  "") die "geen Dawn_SOURCE_DIR in $BUILD/CMakeCache.txt — deze buildmap is niet herkenbaar" ;;
esac
case "$cache_dir" in
  /deps/*)
    nested=${cache_dir#/deps/}          # native-deko3d/dawn
    nested=${nested%/dawn}              # native-deko3d
    deps_host=$(dirname "$DEPS")
    rel_build="$nested/dawn-build-switch"
    ;;
  *)
    deps_host="$DEPS"
    rel_build="dawn-build-switch"
    say "let op: de cache zegt $cache_dir (buiten /deps) — gemount zoals de map zelf ligt"
    ;;
esac
deps_mount=$(cygpath -m "$deps_host" 2>/dev/null || printf '%s' "$deps_host")
say "mount: $deps_mount → /deps, werken in /deps/$rel_build (zoals de cache het vraagt)"
MSYS_NO_PATHCONV=1 docker run --rm --entrypoint bash \
  -v "${deps_mount}:/deps" -w "/deps/$rel_build" "$IMAGE" \
  -c "test -f build.ninja || { echo 'PAD-FOUT: /deps/$rel_build bevat geen build.ninja'; exit 40; }; ninja src/dawn/native/libwebgpu_dawn.a" \
  >"$WS/logs/build-quiet-dawn.log" 2>&1
rc=$?
if [ $rc -ne 0 ]; then
  tail -n 5 "$WS/logs/build-quiet-dawn.log" >&2
  if [ "$rc" = 40 ]; then
    die "de container zag geen build.ninja in /deps/$rel_build (gemount: $deps_mount)" \
        "Controleer of Docker Desktop schijf C: deelt (Settings → Resources → File sharing)."
  fi
  die "ninja in de container faalde (rc $rc); zie logs/build-quiet-dawn.log"
fi
new_size=$(wc -c < "$ARCHIVE" | tr -d ' ')
old_size=$(wc -c < "$LOUD" | tr -d ' ')
say "gebouwd in $(( $(date +%s) - t0 )) s"
say "kalm: $new_size B   met diagnostiek: $old_size B   verschil: $(( old_size - new_size )) B"
[ "$new_size" != "$old_size" ] || die "de archive is identiek aan de luide versie — de delta heeft geen effect"

echo
echo "== 4. werkboom weer pin-gelijk"
if ! (cd "$DAWN" && patch -p1 -R --forward < "$DELTA") >/dev/null 2>&1; then
  die "de delta kon niet teruggezet worden; de Dawn-werkboom staat nu AFWEKEND van de pin" \
      "Herstel handmatig met: git -C $DAWN checkout -- src/dawn/native/deko3d/DeviceDeko3d.h"
fi
DELTA_APPLIED=0
say "werkboom teruggezet (patch -R) — de upstream-audit geldt weer"

echo
echo "== 5. registratie"
cp -f "$ARCHIVE" "$QUIET"
{
  printf 'diagnostics=off\n'
  printf 'delta_sha256=%s\n' "$delta_sha"
  printf 'delta_file=tools/patches/dawn-diagnostics-off.diff\n'
  printf 'built_with=%s\n' "${gcc_in_image:-unknown}"
  printf 'archive_sha256=%s\n' "$(sha256sum "$ARCHIVE" | cut -d' ' -f1)"
  printf 'archive_bytes=%s\n' "$new_size"
  printf 'built_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
} > "$MARKER" || die "marker niet te schrijven: $MARKER"
say "marker: $MARKER"
sed 's/^/      /' "$MARKER"

echo
echo "== 6. wat er nu klopt"
say "de actieve archive is kalm en de bron is pin-gelijk: dat hoort bij elkaar"
say "via de marker, niet via een stilzwijgende stilte."
say "volgende stap is registreren in het pakket: bash tools/render-deps.sh --make"
say "terugdraaien altijd: bash tools/build-quiet-dawn.sh --restore"
