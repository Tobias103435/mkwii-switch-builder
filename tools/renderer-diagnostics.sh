#!/usr/bin/env bash
# tools/renderer-diagnostics.sh — de renderer-diagnostiek van Dawn stillen, en
# ervoor zorgen dat de bytes daarna ook werkelijk stil zijn.
#
# Waaróm dit bestaat. Dawn's Deko3D-backend krijgt van de gepinde upstream-patch
# (aurora-main/cmake/patches/dawn-nintendo-switch-platform.patch, regel 2920) mee:
#
#     inline constexpr bool kDeko3dDiag = true;
#
# Met die vlag doet elke 300e Presented frame twee dingen: de GPU laten stillopen
# (dkQueueWaitIdle) en daarna ~4 miljoen pixels op de CPU doorlopen om er een regel
# van te loggen. Bij 60 fps is dat één hapering per 5,0 s, en hij valt ook in menu's
# en tijdens pauze, want de trigger telt frames en geen seconden. Tijdens het
# opstarten was dit onmisbaar — zo zijn de cachefout en de zwarte voertuigen gevonden
# — maar niets in een released product zou ervoor moeten betalen.
#
# Waarom géén vinkje in de app. Het is een compileertijd-vlag in een archive die wij
# als 76 MB pakket serveren. Een vinkje dat bij een voorgebouwde archive niets kan
# veranderen is erger dan geen vinkje: het belooft iets dat het niet houdt. Dus is het
# ingebouwd — het product is stil. Wie de logs terugwil: MKW_RENDERER_DIAG=on (bronboom)
# of -DMKW_DEKO3D_DIAG=1 (eigen cmake-run).
#
# Twee valkuilen die dit script dicht:
#   1. Alleen de header omzetten verandert de gelinkte bytes niet. Dus wordt de
#      Dawn-archive herbouwd zodra die ouder is dan de header; lukt dat niet, stopt
#      de bouw in plaats van een archive met de verkeerde vlag te linken.
#   2. Een voorgebouwd pakket is niet te veranderen. Dat wordt hardop gezegd.
#
# Gebruik: bash tools/renderer-diagnostics.sh <deps-dir>
set -uo pipefail

DEPS=${1:?"gebruik: renderer-diagnostics.sh <deps-dir>"}
WANT="${MKW_RENDERER_DIAG:-off}"
TOOLS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WS="$(cd "$TOOLS_DIR/.." && pwd)"
HEADER="$DEPS/dawn/src/dawn/native/deko3d/DeviceDeko3d.h"
MARKER="$DEPS/.mkw-render-diagnostics"
DAWN_BUILD="$DEPS/dawn-build-switch"
ARCHIVE="$DAWN_BUILD/src/dawn/native/libwebgpu_dawn.a"
REBUILD_LOG="$WS/logs/renderer-diagnostics-rebuild.log"

case "$WANT" in
  on|off) ;;
  *) echo "Fout: MKW_RENDERER_DIAG is '$WANT'; verwacht on of off." >&2; exit 2 ;;
esac

note() { printf '>> diag %s\n' "$1"; }

consequence() {
  printf '   Elke 300e frame: de GPU laten wachten plus ~4 miljoen pixels op de CPU.\n'
  printf '   Bij 60 fps = elke 5 s een zichtbare hapering, ook in menu en bij pauze.\n'
  printf '   Uit = rustiger beeld, geen frame-dumps in stderr.txt. Aan = die dumps terug,\n'
  printf '   alleen zinvol als er iets opgezocht wordt.\n'
}

# De archive moet bij de vlag horen: ouder dan de header = verkeerde bytes.
ensure_archive_matches() {
  if [ ! -f "$ARCHIVE" ]; then
    note "geen Dawn-archive nog — de vlag staat vóór de eerste compilatie, dat is de gewone volgorde"
    return 0
  fi
  if [ ! -f "$DAWN_BUILD/build.ninja" ]; then
    echo "Fout: $ARCHIVE staat er zonder build.ninja, dus kan de vlag niet verwerkt worden." >&2
    echo "      Bouw de stack opnieuw: bash tools/build-nro.sh --deps-build" >&2
    return 1
  fi
  if [ "$HEADER" -nt "$ARCHIVE" ]; then
    note "archive is ouder dan de vlag: Dawn herbouwen (18 deko3d-objecten + archive)"
    local t0; t0=$(date +%s)
    if ninja -C "$DAWN_BUILD" src/dawn/native/libwebgpu_dawn.a >"$REBUILD_LOG" 2>&1; then
      note "archive herbouwd in $(( $(date +%s) - t0 )) s, $(wc -c < "$ARCHIVE" | tr -d ' ') bytes"
      return 0
    fi
    echo "Fout: de header zegt '$WANT' maar de Dawn-archive herbouwen mislukte. Het product" >&2
    echo "      zou een archive linken die bij de VERKEERDE vlag hoort, dus de bouw stopt" >&2
    echo "      hier in plaats van stilletjes door te gaan. Zie $REBUILD_LOG" >&2
    return 1
  fi
  note "archive is al gebouwd met deze vlag — niets te doen"
  return 0
}

if [ ! -e "$HEADER" ]; then
  if [ -f "$DEPS/.mkw-render-package" ]; then
    if [ "$WANT" = off ]; then
      note "kan NIET uitzetten bij dit pakket: $DEPS is een voorgebouwde libwebgpu_dawn.a"
      echo "   De vlag zit in die compiled bytes. Keuzes: (a) het pakket opnieuw laten maken"
      echo "   met de vlag uit — dan is het voor iedereen stil — of (b) de stack hier zelf"
      echo "   bouwen: bash tools/build-nro.sh --deps-build (eenmalig, daarna minuten)."
      echo "   Dit product draait door MET de hapering van ~5 s."
      consequence
      printf 'package-on\n' > "$MARKER" 2>/dev/null || true
      exit 0
    fi
    note "on: het pakket bevat de diagnostiek al, niets te doen"
    printf 'package-on\n' > "$MARKER" 2>/dev/null || true
    exit 0
  fi
  note "overgeslagen: geen Dawn-bronboom in $DEPS/dawn — de prepare-stap haalt en patched hem eerst"
  exit 0
fi

line=$(grep -n '^inline constexpr bool kDeko3dDiag' "$HEADER" | head -1 | cut -d: -f1 || true)
if [ -z "$line" ]; then
  echo "Fout: $HEADER definieert kDeko3dDiag niet langer zoals verwacht. upstream heeft die" >&2
  echo "regel verplaatst of hernoemd; pas dit script aan voordat er verder gebouwd wordt." >&2
  exit 1
fi

printf '   regel %s: %s\n' "$line" "$(sed -n "${line}p" "$HEADER")"
want_flag=$( [ "$WANT" = on ] && echo 1 || echo 0 )

if grep -q "^#define MKW_DEKO3D_DIAG $want_flag\$" "$HEADER" &&
   sed -n "${line}p" "$HEADER" | grep -q 'MKW_DEKO3D_DIAG != 0'; then
  note "$WANT staat al in de bron; alleen de archive gecontroleerd"
  printf '%s\n' "$WANT" > "$MARKER" 2>/dev/null || true
  ensure_archive_matches || exit 1
  exit 0
fi

# Omzetten: macro-gestuurd, met de uitleg erboven, zodat een volgende lezer ziet waarom
# dit hier staat en niet in de gepinde upstream-patch (die is byte-gehid in het
# ontvangstbewijs van het renderpakket; daaraan komen we niet).
tmp="$HEADER.mkwdiag.tmp"
{
  sed -n "1,$((line - 1))p" "$HEADER"
  cat <<TXT
// MKW builder: deliberately not a hard-coded value. Every dump round waits for the GPU
// (dkQueueWaitIdle) and then walks about four million pixels on the CPU once every 300
// presented frames - a visible hitch every five seconds at 60 fps, in menus and while
// paused included, because the trigger counts frames and not seconds. A released product
// should be quiet, so this is off unless a build asks for it with -DMKW_DEKO3D_DIAG=1.
#ifndef MKW_DEKO3D_DIAG
#define MKW_DEKO3D_DIAG $want_flag
#endif
TXT
  printf 'inline constexpr bool kDeko3dDiag = MKW_DEKO3D_DIAG != 0;\n'
  sed -n "$((line + 1)),\$p" "$HEADER"
} > "$tmp" || { rm -f "$tmp"; echo "Fout: $HEADER kon niet herschreven worden" >&2; exit 1; }

if ! grep -q '^inline constexpr bool kDeko3dDiag = MKW_DEKO3D_DIAG != 0;$' "$tmp" ||
   ! grep -q "^#define MKW_DEKO3D_DIAG $want_flag\$" "$tmp"; then
  rm -f "$tmp"
  echo "Fout: de herschreven header bevat de verwachte vlag niet; niets gewijzigd." >&2
  exit 1
fi
mv -f "$tmp" "$HEADER"
printf '%s\n' "$WANT" > "$MARKER" 2>/dev/null || true
note "$WANT gezet in $(basename "$HEADER")"
ensure_archive_matches || exit 1
consequence
