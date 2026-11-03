#!/usr/bin/env bash
# Eén klik: jouw Wii-dump -> één .zip met de gecompileerde .nro + alle game-bestanden
# al op het juiste SD-pad, zodat de ontvanger alleen hoeft uit te pakken.
#
#   bash tools/pack-sd.sh                       # dump automatisch zoeken, NRO hergebruiken
#   bash tools/pack-sd.sh "pad/naar/dump.rvz"   # expliciete dump (.rvz/.wbfs/.iso/.gcm)
#   bash tools/pack-sd.sh --rebuild             # NRO opnieuw compileren (Docker, ~13 min)
#   bash tools/pack-sd.sh --map                 # aflevering als MAP (standaard): dist/MarioKartWii-Switch/
#   bash tools/pack-sd.sh --zip                 # aflevering als .zip (2,8 GB, één bestand)
#   bash tools/pack-sd.sh --both                # map én zip
#   bash tools/pack-sd.sh --out pad.zip         # andere zip-bestemming
#   bash tools/pack-sd.sh --map-out pad/naar/map
#   bash tools/pack-sd.sh --deflate             # comprimeren i.p.v. puur opslaan
#
# De game-data van MKWii is al gecomprimeerd: meten gaf 2,57 GiB bron -> 2,63
# GiB zip met deflate, dus "opslaan zonder compressie" is hier sneller èn kleiner.
#
# Vereisten: precies wat deze werkmap al gebruikt — Docker (alleen voor extractie of
# --rebuild) en Python. Er wordt niets gewist en niets naar de console geschreven.
set -euo pipefail

WS="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO="$WS/WiiCompiled-Switch"
PRODUCT="$REPO/local-product/native-deko3d"
NRO="$PRODUCT/WiiCompiled-Switch-native-deko3d.nro"
EXTRACT="$WS/discs/extract"
MANIFEST="$REPO/local-product-support/recomp.local.yml"
OUT="$WS/dist/MarioKartWii-Switch.zip"
MAP="$WS/dist/MarioKartWii-Switch"
DUMP=""
REBUILD=0
FORCE=0
COMPRESS=store
# Standaard krijg je een map die je rechtstreeks op je SD sleept. --zip maakt er
# één bestand van (handig om naar een andere pc te sturen), --both doet allebei.
MODE=map

while [ $# -gt 0 ]; do
  case "$1" in
    --rebuild) REBUILD=1 ;;
    --force) FORCE=1 ;;
    --deflate) COMPRESS=deflate ;;
    --store) COMPRESS=store ;;
    --map) MODE=map ;;
    --zip) MODE=zip ;;
    --both) MODE=both ;;
    --out) OUT="$2"; shift ;;
    --map-out) MAP="$2"; shift ;;
    -h|--help) sed -n '2,15p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) echo "Onbekende optie: $1" >&2; exit 1 ;;
    *) DUMP="$1" ;;
  esac
  shift
done

# Python-opzoeker: op Windows staan er Store-stubs in PATH die geen Python zijn.
find_python() {
  local c
  for c in "py -3" python3 python; do
    # shellcheck disable=SC2086
    if [ "$($c -c 'print(1)' 2>/dev/null || true)" = "1" ]; then echo "$c"; return 0; fi
  done
  return 1
}
PY="$(find_python || true)"
[ -n "$PY" ] || { echo "Fout: Python ontbreekt (nodig om de zip te bouwen)." >&2; exit 1; }

# De gekozen interpreter is op Windows een native build (py -3 / python.exe) en die
# verstaat geen MSYS-paden zoals /c/Users/… . Bronpadten dus converteren wanneer we
# in Git Bash draaien; de boog-namen in de zip blijven gewoon forward slashes.
hostpath() {
  case "$(uname -s 2>/dev/null || echo unknown)" in
    MINGW*|MSYS*|CYGWIN*) cygpath -aw "$1" ;;
    *) printf '%s\n' "$1" ;;
  esac
}

# Bestandsgrootte, GNU en BSD (macOS) — dezelfde helper als in de motor.
filesize() {
  if stat -c%s "$1" 2>/dev/null; then return 0; fi
  stat -f%z "$1" 2>/dev/null || echo 0
}

# Zie nro-engine.sh: de byte-som van een boom in één du, niet met een stat-proces
# per bestand (2040 bestanden kostten hier 74 s, du doet het in 0,15 s).
tree_bytes() {
  local n
  n=$(du -s --apparent-size --block-size=1 "$1" 2>/dev/null | cut -f1 | tr -d '[:space:]')
  if ! printf '%s' "$n" | grep -qE '^[0-9]+$'; then
    n=$(du -sAk "$1" 2>/dev/null | cut -f1 | tr -d '[:space:]')
    if printf '%s' "$n" | grep -qE '^[0-9]+$'; then n=$(( n * 1024 )); else n=0; fi
  fi
  printf '%s\n' "$n"
}

# sha256, GNU coreutils en BSD/macOS shasum.
hashfile() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

echo "== Stap 1/5: dump vinden =="
if [ -z "$DUMP" ]; then
  # Grootste image wins; zonder GNU-only find -printf (BSD-find heeft het niet).
  best=0
  while IFS= read -r cand; do
    [ -n "$cand" ] || continue
    sz=$(filesize "$cand")
    if [ "$sz" -gt "$best" ]; then best=$sz; DUMP="$cand"; fi
  done <<EOF2
$(find "$WS" -maxdepth 2 -type f \( -iname '*.rvz' -o -iname '*.wbfs' -o -iname '*.iso' -o -iname '*.gcm' \) 2>/dev/null)
EOF2
fi
if [ -n "$DUMP" ]; then
  [ -f "$DUMP" ] || { echo "Fout: dump niet gevonden: $DUMP" >&2; exit 1; }
  echo "   dump: $DUMP ($(filesize "$DUMP") bytes)"
else
  echo "   geen dump gevonden — de reeds geëxtraheerde data wordt gebruikt."
fi

echo "== Stap 2/5: game-data op de PC =="
if [ -f "$EXTRACT/sys/main.dol" ] && [ -f "$EXTRACT/sys/fst.bin" ] && [ -d "$EXTRACT/files" ]; then
  echo "   extractie bestaat al: $EXTRACT ($(find "$EXTRACT/files" -type f | wc -l) bestanden in files/)"
elif [ -n "$DUMP" ]; then
  command -v docker >/dev/null 2>&1 || { echo "Fout: Docker nodig om de dump uit te pakken." >&2; exit 1; }
  echo "   extraheren met nod (dit is de zware stap, een paar minuten)"
  rm -rf "$EXTRACT"
  bash "$WS/tools/nodtool" extract "$DUMP" "$EXTRACT" -p data
else
  echo "Fout: geen dump en geen bestaande extractie." >&2
  echo "      Geef je dump expliciet op: bash tools/pack-sd.sh \"pad/naar/dump.rvz\"" >&2
  exit 1
fi
for need in sys/boot.bin sys/bi2.bin sys/apploader.img sys/main.dol sys/fst.bin; do
  [ -f "$EXTRACT/$need" ] || { echo "Fout: $EXTRACT/$need ontbreekt — extractie is onvolledig." >&2; exit 1; }
done

echo "== Stap 3/5: dump komt overeen met de gecompileerde code =="
want_dol="$(sed -n '/^  dol:/,/  rel:/p' "$MANIFEST" | awk '/sha256/{print $2}')"
want_rel="$(sed -n '/^  rel:/,/^translation:/p' "$MANIFEST" | awk '/sha256/{print $2}')"
got_dol="$(hashfile "$EXTRACT/sys/main.dol")"
rel="$(find "$EXTRACT" -type f -name 'StaticR.rel' | head -1)"
got_rel=""; [ -n "$rel" ] && got_rel="$(hashfile "$rel")"
printf '   main.dol     %s\n' "$got_dol"
printf '   StaticR.rel  %s\n' "${got_rel:-niet gevonden}"
if [ "$got_dol" != "$want_dol" ] || [ "$got_rel" != "$want_rel" ]; then
  echo "   LET OP: dit is een andere dumprevisie dan waar de bestaande .nro op gebouwd is." >&2
  [ "$FORCE" = 1 ] || { echo "      Compileren voor deze dump: bash tools/pack-sd.sh --rebuild (~13 min)." >&2; exit 1; }
  echo "   --force: de bestaande .nro wordt meegegeven ondanks het verschil." >&2
fi

echo "== Stap 4/5: .nro =="
if [ "$REBUILD" = 1 ]; then
  command -v docker >/dev/null 2>&1 || { echo "Fout: Docker nodig om te compileren." >&2; exit 1; }
  # De compilering zit in tools/build-nro.sh: die past na een verse vertaling ook
  # de link-fixes weer toe (prepare-local-native-deko3d-product.sh wist ze).
  echo "   compileren via tools/build-nro.sh --full"
  bash "$WS/tools/build-nro.sh" --full ${DUMP:+"--dump"} ${DUMP:+"$DUMP"}
fi
[ -f "$NRO" ] || { echo "Fout: geen .nro gevonden en er is niet gecompileerd: $NRO" >&2; exit 1; }
nro_sha="$(hashfile "$NRO")"
recorded="$(awk '{print $1}' "$NRO.sha256" 2>/dev/null || true)"
[ -z "$recorded" ] || [ "$recorded" = "$nro_sha" ] || { echo "Fout: .nro wijkt af van de registratie in $NRO.sha256" >&2; exit 1; }
echo "   $(basename "$NRO") $(filesize "$NRO") bytes"
echo "   sha256 $nro_sha"

echo "== Stap 5/5: aflevering bouwen (mode: $MODE) =="
read -r -d '' NOTICE <<'TXT' || true
Mario Kart Wii - Switch homebrew
================================

Sleep de map "switch" uit dit pakket op de ROOT van je SD-kaart (hij staat dan
naast "atmosphere" op de SD). Start daarna hbmenu op de Switch en kies
WiiCompiled-Switch.

Er is geen schijfkeuze-venster: de game-data staat al uitgepakt op de juiste
plaats, dus de app gaat direct naar Ready.

Dit pakket bevat code en bestanden die van Nintendo zijn. Het is gemaakt met een
eigen dump van de bouwer en is uitsluitend voor persoonlijk gebruik. Publiceer,
verkoop of deel dit pakket niet; het bouwgereedschap is wél delbaar, iedereen
bouwt met zijn eigen dump.

Bronnen: WiiCompiled (statische PPC->AArch64-vertaling), DriftDroid en
WiiCompiled-Switch (runtime/aurora-integratie), aurora + Dawn + averne/libuam
(Deko3D-renderer), triniblo/encounter nod (uitpakken).
TXT

# Eén opbouwlijst voor beide afleveringen, zodat map en zip niet kunnen verschillen.
SD_ARGS=(
  --file "switch/WiiCompiled-Switch/$(basename "$NRO")" "$(hostpath "$NRO")"
  --tree "switch/WiiCompiled/DATA/sys" "$(hostpath "$EXTRACT/sys")"
  --tree "switch/WiiCompiled/DATA/files" "$(hostpath "$EXTRACT/files")"
)

if [ "$MODE" = map ] || [ "$MODE" = both ]; then
  $PY "$(hostpath "$WS/tools/make-sd-dir.py")" "$(hostpath "$MAP")" "${SD_ARGS[@]}" \
    --text "LEES-MIJ.txt" "$NOTICE"
  map_files="$(find "$MAP" -type f | wc -l | tr -d ' ')"
  map_bytes="$(tree_bytes "$MAP")"
  printf '   map:  %s\n' "$MAP"
  printf '   %s bestanden, %s bytes\n' "$map_files" "$map_bytes"
fi

if [ "$MODE" = zip ] || [ "$MODE" = both ]; then
  mkdir -p "$(dirname "$OUT")"
  # make-sd-zip.py zorgt zelf voor de afsluitende newline van de notice.
  $PY "$(hostpath "$WS/tools/make-sd-zip.py")" "$(hostpath "$OUT")" --compress "$COMPRESS" \
    "${SD_ARGS[@]}" --text "LEES-MIJ.txt" "$NOTICE"
  zip_sha="$(hashfile "$OUT")"
  printf '%s  %s\n' "$zip_sha" "$(basename "$OUT")" > "$OUT.sha256"
  printf '   zip:  %s (%s bytes, sha256 %s)\n' "$OUT" "$(filesize "$OUT")" "$zip_sha"
fi

echo
echo "KLAAR."
echo "   Installatie op een SD: kopieer de map switch/ (of unzip de zip) op de ROOT"
echo "   van die SD, start hbmenu, kies WiiCompiled-Switch."
echo "   Deze console heeft die mappen al; dit is voor een andere SD of een kopie."
echo "   Bevat Nintendo-materiaal: niet publiceren, alleen persoonlijk delen."
