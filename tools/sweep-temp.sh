#!/usr/bin/env bash
# sweep-temp.sh — verwijdert ná een geslaagde bouw de herbouwbare tussenproducten.
#
#   bash tools/sweep-temp.sh --deps <deps-map> --ws <werkruimte>
#   bash tools/sweep-temp.sh --deps … --ws … --dry-run    # alleen melden
#   bash tools/sweep-temp.sh --deps … --ws … --skip-extract
#   bash tools/sweep-temp.sh --deps … --ws … --keep-cache # objecten + shards laten staan
#
# Wat eraf gaat, is alles wat de motor uit jouw eigen dump opnieuw kan maken:
#   <deps>/build-switch-release   objecten + build.ninja van deze bouw  (--keep-cache: blijft)
#   <deps>/driftdroid/generated   vertaalde shards                      (--keep-cache: blijft)
#   <ws>/discs/extract            uitgepakte game-data (jouw dump zelf blijft liggen)
#   <ws>/logs/tmp                 proef-builds en tijdelijke uitleesbestanden
# --keep-cache is wat de motor standaard doet: die twee bomen samen zijn het deel
# van de bouw dat de tijd kost (gemeten: koude build-stap 867 s, warme 67 s), dus
# met ze behalten is een volgende rebuild circa één minuut in plaats van een
# kwartier. Ze zijn later alsnog weg te halen — met deze vlag uit, of met
# tools/clean-app.sh --leftovers.
# Wat NOOIT weg gaat: de .nro en local-product (terugval op de geverifieerde build),
# dist/ (de sleepbare SD-map), de deps-cache (dawn + libuam, uren werk), de
# toolchain en de mappen die hieronder als root zijn meegegeven zelf.
#
# Veiligheid: elk pad wordt alleen weggehaald als het (a) onder de meegegeven root
# ligt, (b) exact de bekende naam heeft en (c) een bewijsbestand bevat dat hoort bij
# een echte bouwboom. Een lege of halve map wordt overgeslagen, niet geraden.
# Exit 0 = niets te doen of opgeruimd; 1 = pad afgeslagen (raadgever aangepast).
set -euo pipefail

DEPS="" WS="" DRY=0 SKIP_EXTRACT=0 KEEP_CACHE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --deps) DEPS="${2:?--deps needs a folder}"; shift ;;
    --ws) WS="${2:?--ws needs a folder}"; shift ;;
    --dry-run) DRY=1 ;;
    --skip-extract) SKIP_EXTRACT=1 ;;
    --keep-cache) KEEP_CACHE=1 ;;
    *) printf 'unknown option: %s\n' "$1" >&2; exit 2 ;;
  esac
  shift
done
[ -n "$DEPS" ] && [ -n "$WS" ] || { echo "usage: --deps <folder> --ws <folder>" >&2; exit 2; }

# Byte-grootte van een boom, GNU en BSD/macOS.
dirsize() {
  local n
  if n=$(du -s --block-size=1 "$1" 2>/dev/null | cut -f1); then :; else
    n=$(du -sk "$1" 2>/dev/null | cut -f1)
    [ -n "$n" ] && n=$(( n * 1024 ))
  fi
  printf '%s\n' "${n:-0}"
}
gib() { printf '%s' "$(awk -v b="${1:-0}" 'BEGIN{printf "%.2f", b/1073741824}')"; }

FREED=0
CHANGED=""

# sweep_one <root> <pad> <bewijs> — de drie poorten hierboven.
sweep_one() {
  local root="$1" p="$2" proof="$3" sz rel depth
  [ -n "$p" ] || return 0
  [ -d "$p" ] || return 0
  case "$p" in /*) ;; *) printf '   ERROR: %s is not an absolute path\n' "$p" >&2; return 1 ;; esac
  # (a) onder de meegegeven root, de root zelf nooit. Twee niveaus diep minimum:
  #     een lege of gekapte root-variable levert dan /naam op, en dat weigeren we.
  [ "$p" != "$root" ] || { printf '   ERROR: %s is the root itself\n' "$root" >&2; return 1; }
  case "$p" in "$root"/*) ;; *) printf '   ERROR: %s is not under %s\n' "$p" "$root" >&2; return 1 ;; esac
  depth=$(printf '%s' "${p#/}" | tr -dc '/' | wc -c | tr -d ' ')
  [ "$depth" -ge 2 ] || { printf '   ERROR: %s is too shallow to be a build tree\n' "$p" >&2; return 1; }
  # (b) product, SD-map en deps-cache zijn geen tussenproduct.
  case "$p" in
    *local-product*|*/dist|*/dist/*|*/dawn|*/dawn-build-switch|*/uam)
      printf '   ERROR: %s is not an intermediate product\n' "$p" >&2; return 1 ;;
  esac
  # (c) bewijs dat het de echte bouwboom is.
  [ -e "$p/$proof" ] || { printf '   skipped (no %s in %s)\n' "$proof" "$p"; return 0; }
  sz=$(dirsize "$p")
  rel=${p#"$root"/}
  if [ "$DRY" = 1 ]; then
    printf '   dry run: %s (%s GiB) would be removed\n' "$rel" "$(gib "$sz")"
  else
    rm -rf "$p" && printf '   removed: %s (%s GiB)\n' "$rel" "$(gib "$sz")"
  fi
  FREED=$(( FREED + sz ))
  CHANGED="${CHANGED:+$CHANGED }$rel"
}

# size_of <pad> — omvang van iets dat blijft staan, voor de melding alleen.
size_of() { [ -d "$1" ] && dirsize "$1" || printf '0\n'; }

printf '== temporary build files ==\n'
if [ "$KEEP_CACHE" = 1 ]; then
  printf '   kept on purpose: build-switch-release, driftdroid/generated (the part that costs the minutes)\n'
else
  sweep_one "$DEPS" "$DEPS/build-switch-release" build.ninja
  sweep_one "$DEPS" "$DEPS/driftdroid/generated" build_shards
fi
[ "$SKIP_EXTRACT" = 1 ] || sweep_one "$WS" "$WS/discs/extract" files
sweep_one "$WS" "$WS/logs/tmp" .

KEPT=$(( $(size_of "$DEPS/build-switch-release") + $(size_of "$DEPS/driftdroid/generated") ))
printf 'freed: %s GiB%s\n' "$(gib "$FREED")" "${CHANGED:+ ($CHANGED)}"
if [ "$KEEP_CACHE" = 1 ]; then
  printf 'build cache kept: %s GiB (rebuild in about a minute; sweep-temp.sh without --keep-cache removes it)\n' "$(gib "$KEPT")"
fi
printf '{"t":"sweep","freed":%s,"removed":"%s","dry":%s,"kept_cache":%s,"cache_bytes":%s}\n' \
  "$FREED" "${CHANGED:-none}" "$DRY" "$KEEP_CACHE" "$KEPT"
