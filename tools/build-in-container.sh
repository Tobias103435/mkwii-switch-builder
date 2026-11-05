#!/usr/bin/env bash
# Bouwt het product: vertalen (kan overgeslagen), link-fixes toepassen,
# compileren, linken en de NRO-verpakken.
#
# Draait op twee manieren met dezelfde stappen:
#   --docker  : binnenuit de devkitA64-container, aangeroepen door de motor
#   native    : direct op de host, mits devkitA64 + libnx geïnstalleerd zijn
# De paden volgen uit de plaats van dit script: in de container is dat /work,
# op de host de werkruimte zelf. Aanroeper: tools/nro-engine.sh. Omgevingsvariabelen:
#   DEVKITPRO / DEVKITARM   toolchain (door de container gezet, of door native-env.sh)
#   MKW_DEKO3D_DEPS_DIR  deps (volume of host-map), verplicht
#   MKW_FULL             1 = opnieuw vertalen, anders de cached shards hergebruiken
#   MKW_JOBS             paralleliteit (standaard: alle cpu's)
#   MKW_CCACHE           0 = compilercache uitzetten
set -euo pipefail

WS="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO="${MKW_REPO_DIR:-$WS/WiiCompiled-Switch}"
TOOLS="$WS/tools"
DEPS_DIR="${MKW_DEKO3D_DEPS_DIR:?MKW_DEKO3D_DEPS_DIR ontbreekt}"
WORK_DIR="${MKW_DEKO3D_WORK_DIR:-$DEPS_DIR/driftdroid}"
# Het build-archief buiten WORK_DIR houden: prepare-local-native-deko3d-product.sh
# wist WORK_DIR (daarin zat ook build-switch-release), dus elke volledige bouw
# verloor daarmee álle 849 gecompileerde objecten.
BUILD_DIR="${MKW_DEKO3D_BUILD_DIR:-$DEPS_DIR/build-switch-release}"
JOBS="${MKW_JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 8)}"
FULL="${MKW_FULL:-0}"

export PATH="$DEVKITPRO/devkitA64/bin:$DEVKITPRO/tools/bin:$DEVKITPRO/portlibs/bin:$PATH"
# Windows kent geen extensieloze bash-wrappers, dus CMake vindt daar alleen de
# .exe-versies van tools en pkg-config. Op Linux/macOS (en in de container) laat
# dit de geverifieerde build-route onaangeraakt.
case "$(uname -s 2>/dev/null || echo unknown)" in
  MINGW*|MSYS*|CYGWIN*)
    if [ -d "$DEVKITPRO/portlibs/switch/bin" ]; then
      export PATH="$PATH:$DEVKITPRO/portlibs/switch/bin"
      export PKG_CONFIG_LIBDIR="$DEVKITPRO/portlibs/switch/lib/pkgconfig"
      export PKG_CONFIG_DIR= PKG_CONFIG_PATH= PKG_CONFIG_SYSROOT_DIR=
    fi
    # De provenancepoort van de repo berekent `git diff`-hashes van de deps-bomen.
    # Die zijn op Windows pas reproduceerbaar nadat de boom git-leesbaar is gemaakt
    # (symlinks, exec-bits, vuile submodule-werkbomen), anders faalt een bouw op
    # een dep-boom die byte-identiek is aan het volume.
    . "$TOOLS/native-env.sh"
    # Eigen gereedschap vooraan, ook als dit script standalone draait: de
    # eenmalige renderstack heeft meson/bison/flex uit die mappen nodig en het
    # deps-script doet `import mako`, wat alleen via dezelfde PYTHONPATH lukt.
    native_use_portable
    native_toolchain_win_patch || exit 3
    native_portlibs_relocate || exit 3
    # CA-boom voor cmake's eigen curl (FetchContent): Windows-cmake vindt anders
    # geen vertrouwde roots en elke download geeft status 60. cmake is een
    # Windows-binary en verstaat geen /c/pad, dus cygpath -m — gemengde vorm met
    # forward slashes. Met cygpath -w (\-vorm) breekt het: cmake plakt het pad in
    # een gegenereerd download-script, waar "C:\Program Files\…" een ongeldige
    # escape '\P' oplevert.
    if CA=$(native_ca_bundle); then
      export MKW_TLS_CAINFO="$(cygpath -m "$CA" 2>/dev/null || printf '%s' "$CA")"
      echo ">> ca-bundle: $MKW_TLS_CAINFO"
    else
      echo ">> ca-bundle: geen — downloadstappen zullen falen, run: bash tools/setup-native.sh --install" >&2
    fi
    [ -d "$DEPS_DIR/dawn/.git" ] && native_deps_hygiene "$DEPS_DIR"
    # Upstream plakt Path()-waarden als tekst in patch-markers; op Windows geeft
    # str(Path) backslashes en verwerpt de Dawn-verificatie dan een correcte boom.
    # De fix zélf in scripts/patch-dawn-switch.py zetten kan niet: de ontvangst
    # toetst de byte-hash van dat bestand en maakt dan de hele deps-cache ongeldig.
    # Daarom buigt een shim alleen de pad-weergave in het python-proces om, zodat
    # Windows zich hier gedraagt zoals Linux zich al gedraagt.
    export PYTHONPATH="$TOOLS/py-shims${PYTHONPATH:+:$PYTHONPATH}"
    export MKW_POSIX_PATHS=1
    ;;
esac
cd "$REPO"

# Tijdsmeting per fase. De motor (tools/nro-engine.sh) leest deze markers uit de
# rauwe log en zet ze door als voortgang, zodat een frontend kan laten zien WAT er
# op dit moment duurt en hoe lang de vorige fase was.
# De fase-NAMEN zijn Engels: die leven door in de UI. De echo-teksten hieronder
# blijven Nederlands; dat is het detaillogboek, alleen voor wie het opent.
T0=$(date +%s)
PHASE_T0=$T0
begin() { # begin <fase>  -> sluit de vorige fase af met zijn duur, begint de nieuwe
  now=$(date +%s)
  [ -n "${PHASE:-}" ] && printf '>> EIND %s %s s\n' "$PHASE" "$(( now - PHASE_T0 ))"
  PHASE="$1"; PHASE_T0=$now
  printf '>> BEGIN %s (totaal %s s)\n' "$1" "$(( now - T0 ))"
}
finish() { # finish -> sluit de laatste fase af en rapporteert de totaaltijd
  now=$(date +%s)
  [ -n "${PHASE:-}" ] && printf '>> EIND %s %s s\n' "$PHASE" "$(( now - PHASE_T0 ))"
  printf '>> TOTAAL %s s\n' "$(( now - T0 ))"
}
begin startup

# Compilercache op het volume. De cache-zelf is hier alleen maar geconfigureerd;
# het gekoppelde stuk is de launcher die patch-workdir.sh in de WORK_DIR zet,
# want de devkitA64-toolchain schrijft zijn compiler absolute voor en laat een
# PATH-masquerade dus links liggen.
#
# MAXFILESIZE staat op 0 (geen limiet) — de standaard van ccache is 2 MiB en de
# grootste gast-shards zijn 2,6-2,7 MiB bron met 13-21 MiB object, dus zonder die
# vlag zou ccache ze weigeren op grootte. Let op wat wél de reden is dat ze niet
# in de cache komen: met CCACHE_DEBUG=1 ernaast gezegd, `Result:
# could_not_use_precompiled_header`. De shard-target bouwt met een CMake-voorgecompileerd
# koptekst (`-include cmake_pch.hxx`) en dat kan ccache niet vangen. Gemeten na een
# bouw van 900 s: 682 cachebare aanroepen, 682 hits, 104 oncachebare. De winp is
# daarom niet de cache-logica maar de napruiming: die 104 blijven in
# build-switch-release staan (zie nro-engine.sh, --keep-cache) en maken een volgende
# rebuild 67 s.
if [ "${MKW_CCACHE:-1}" != 0 ] && command -v ccache >/dev/null 2>&1; then
  export CCACHE_DIR="${CCACHE_DIR:-$DEPS_DIR/ccache}"
  export CCACHE_MAXSIZE="${CCACHE_MAXSIZE:-8G}"
  export CCACHE_MAXFILESIZE="${CCACHE_MAXFILESIZE:-0}"
  export CCACHE_COMPILERCHECK="${CCACHE_COMPILERCHECK:-content}"
  mkdir -p "$CCACHE_DIR"
  ccache --zero-stats >/dev/null 2>&1 || true
  echo ">> ccache aan: dir=$CCACHE_DIR max=$CCACHE_MAXSIZE maxfilesize=$CCACHE_MAXFILESIZE ($(ccache --version | head -1))"
else
  echo ">> ccache uit"
fi

begin "render stack"
if [ "${MKW_SKIP_DEPS_CHECK:-0}" != 1 ] && [ ! -f "$DEPS_DIR/native-deko3d-toolchain.receipt" ]; then
  echo ">> Deko3D-renderstack (Dawn + libuam) staat nog niet op het volume: dit duurt uren."
  MKW_DEKO3D_DEPS_DIR="$DEPS_DIR" MKW_JOBS="$JOBS" bash scripts/prepare-native-deko3d-deps.sh
fi

# NOTE (2026-11-05): de renderer-diagnostiek van Dawn (kDeko3dDiag, elke 300e frame een
# GPU-wacht plus een CPU-scan over ~4 miljoen pixels = een hapering per 5 s) staat AAN in
# de gepinde upstream-patch. hem hier uitzetten kan níet: scripts/patch-dawn-switch.py
# toetst of die patch zich volledig en byte-echt uit de Dawn-werkboom laat terugdraaien,
# en élke wijziging — ook één regel in DeviceDeko3d.h — maakt die audit waardevol kapot.
# De juiste plek is daarom niet deze flow maar de patch-zelf: tools/renderer-diagnostics.sh
# zet de vlag en is expliciet aan te roepen; zodra de vlag in een eigen, gehasste
# extra-patch achter de upstream-patch zit (met die hash in het ontvangstbewijs) wordt
# het product stil zonder dat de audit zwijgt. Zolang dit niet zo is, is wat wij leveren
# luidruchtig en moeten we dat op de README kunnen zeggen.

# Een opruiming (sweep) of een schone machine laat geen cached vertaling achter.
# Dat is geen fout die de gebruiker met een vlag moet kunnen oplossen: er is één
# knop, dus de bouwer pakt zelf door naar de volledige route en zegt dat hardop.
if [ "$FULL" != 1 ] && [ ! -f "$WORK_DIR/generated/build_shards/shards.cmake" ]; then
  echo ">> No cached translation in $WORK_DIR (cleaned up or first run) — retranslating from scratch, this takes about 15 minutes."
  FULL=1
fi

if [ "$FULL" = 1 ]; then
  begin "translating"
  echo ">> Volledige route: vertalen van main.dol/StaticR.rel naar native C++"
  bash scripts/prepare-local-native-deko3d-product.sh
else
  begin "cached translation"
  echo ">> Incrementele route: bestaande vertaling (generated/build_shards) hergebruiken"
fi

begin "link fixes"
bash "$TOOLS/patch-workdir.sh" "$WORK_DIR"

begin "compiling and linking"
echo ">> Bouwen en linken: mkw_release (MKW_JOBS=$JOBS, build=$BUILD_DIR)"
MKW_DEKO3D_DEPS_DIR="$DEPS_DIR" MKW_DEKO3D_WORK_DIR="$WORK_DIR" \
MKW_DEKO3D_BUILD_DIR="$BUILD_DIR" \
MKW_SKIP_DEKO3D_DEPS=1 MKW_SKIP_TRANSLATE=1 MKW_JOBS="$JOBS" \
  bash scripts/build-local-native-deko3d.sh

begin "ccache report"
if [ "${MKW_CCACHE:-1}" != 0 ] && command -v ccache >/dev/null 2>&1; then
  echo ">> ccache-uitkomst na deze bouw:"
  ccache --show-stats --hide-parsed 2>/dev/null || ccache -s 2>/dev/null || true
fi
finish
