#!/usr/bin/env bash
# Past de integratie-fixes toe op de vertaal-WORK_DIR: de vier uit de patch, plus
# de drie die alleen op Windows nodig zijn (ccache-launcher, CA-bundel, ELF-secties).
# Idempotent: een WORK_DIR die de fixes al bevat wordt ongewijzigd gelaten.
#
# Waarom dit nodig is: scripts/prepare-local-native-deko3d-product.sh doet
# `rm -rf $WORK_DIR` en pakt pin 8b33d310 vers uit via `git archive`. Daarbij
# verdwijnen de fixes die nodig zijn om te kunnen linken, dus na elke verse
# vertaling moesten ze handmatig terug. Dit bestand maakt dat automatisch.
#
# Gebruik: bash tools/patch-workdir.sh <WORK_DIR>
set -euo pipefail

WORK_DIR=${1:?"gebruik: patch-workdir.sh <WORK_DIR>"}
WS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PATCH="$WS_ROOT/tools/patches/native-deko3d-link-fixes.patch"
[ -d "$WORK_DIR" ] || { echo "Fout: WORK_DIR bestaat niet: $WORK_DIR" >&2; exit 1; }
[ -f "$PATCH" ] || { echo "Fout: patch ontbreekt: $PATCH" >&2; exit 1; }

mark() { printf '   %s\n' "$1"; }

# Vier merkers, één per bestand. return 0 als alles al aanwezig is.
already_applied() {
  awk '/^namespace \{/{exit} /kGuestMapSymbolCount/{found=1} END{exit !found}' \
      "$WORK_DIR/runtime/src/system_bridge.cpp" || return 1
  grep -q -- '--allow-multiple-definition' "$WORK_DIR/runtime/CMakeLists.txt" || return 1
  grep -qx '#if defined(__ANDROID__) && defined(DAWN_ENABLE_BACKEND_OPENGLES)' \
      "$WORK_DIR/aurora-main/lib/webgpu/gpu.cpp" || return 1
  [ -f "$WORK_DIR/runtime/src/mkw_switch_syscall_stubs.cpp" ] || return 1
  return 0
}

if already_applied; then
  mark "link-fixes: al aanwezig in deze WORK_DIR, overslaan"
else
  echo "   link-fixes: toepassen op $WORK_DIR"
  patch -p1 -N --forward -d "$WORK_DIR" < "$PATCH"
  if already_applied; then
    mark "link-fixes: alle vier merkers aanwezig (gpu.cpp, CMakeLists.txt, stubs-TU, system_bridge.cpp)"
  else
    echo "Fout: patch liep zonder fout maar de merkers kloppen niet." >&2
    exit 1
  fi
fi

# De cache-reparatie voor de console. SQLite is op Switch gebouwd met de lock-loze
# "unix-none" VFS als standaard (devkitA64-newlib heeft geen POSIX-bestandsslot), en
# die VFS weigert élke bestandsopening. Het gevolg is op de console gemeten, niet
# bedacht: "running without a shader cache", elke boot opnieuw élke shader en élke
# pipeline compileren, zwarte voertuigen op koude schermen. De patch maakt de SDL-VFS
# — de enige die hier wél bij de SD-kaart kan — schrijfbaar en registreert hem als
# standaard. Metingen, en de twee SQLite-valkuilen die ermee opgelost zijn (het
# READONLY-folgt van IMMUTABLE, en de outFlags die een writing connection read-only
# maken), staan in PROJECT-LOG.md §3 rij 55 en §11.
CACHE_PATCH="$WS_ROOT/tools/patches/switch-cache-vfs.patch"
CACHE_STAMP="$WORK_DIR/.mkw-cache-vfs.stamp"
DRIFT_DIR="$WS_ROOT/WiiCompiled-Switch/third_party/DriftDroid"

# Bestanden die deze patch aanraakt, gehaald uit zijn eigen @@-koppen — zo raakt de
# lijst nooit achter op de inhoud. "b/" is de DriftDroid-werkboom, dus het voorvoegsel
# eraf en dedupliceren.
patch_files() {
  sed -n 's|^+++ b/\([^ \t]\{1,\}\)[ \t].*|\1|p; s|^+++ b/\([^ \t]\{1,\}\)$|\1|p' "$CACHE_PATCH" \
    | awk '!seen[$0]++'
}

# "Al aanwezig" op een merker CONTROLEREN IS HIER NIET VEILIG: een aangepaste patch
# bevat die merker ook, en dan link je maanden de versie die je juist wilde vervangen.
# Deze toets is content: de patch moet zich úít de WORK_DIR kunnen terugdraaien.
cache_applied() {
  patch -p1 -R --dry-run --forward -d "$WORK_DIR" < "$CACHE_PATCH" >/dev/null 2>&1
}

# Eén versie terugdraaien volstaat niet als de vorige patch ándere bestanden aanraakte
# (gpu_cache.cpp en sqlite_utils.hpp zijn eruit, main.cpp en gfx.h erin). De stempel
# onthoudt welke bestanden de vorige keer zijn gepatcht; die worden óók teruggezet naar
# de pin vóórdat de nieuwe patch erop gaat.
restore_to_pin() {
  local f
  for f in "$@"; do
    [ -n "$f" ] || continue
    [ -d "$DRIFT_DIR/.git" ] || [ -f "$DRIFT_DIR/.git" ] || {
      echo "Fout: $WORK_DIR bevat een oudere cache-patch en $DRIFT_DIR is geen git-clone, dus $f kan niet naar de pin terug. Herstel de submodule (git -C WiiCompiled-Switch submodule update --init --recursive) of draai een volledige bouw." >&2
      return 1
    }
    git -C "$DRIFT_DIR" show "HEAD:$f" > "$WORK_DIR/$f.mkwtmp" || {
      echo "Fout: $f staat niet in de gepinde commit van $DRIFT_DIR" >&2
      return 1
    }
    mv -f "$WORK_DIR/$f.mkwtmp" "$WORK_DIR/$f"
  done
}

if [ ! -f "$CACHE_PATCH" ]; then
  echo "Fout: de cache-patch ontbreekt: $CACHE_PATCH" >&2
  exit 1
elif cache_applied; then
  mark "cache-vfs: deze versie van de patch staat al in de WORK_DIR, overslaan"
else
  PREVIOUS=""
  [ -f "$CACHE_STAMP" ] && PREVIOUS=$(tr -d '\r' < "$CACHE_STAMP")
  if [ -n "$PREVIOUS" ]; then
    # Een eerdere, weer andere versie (haar stempel leeft nog, terugdraaien van de
    # huidige lukt niet): zet eerst alle bestanden van toen én van nu terug naar de
    # pin, zodat er geen resten van de vorige versie in de Work_dir achterblijven.
    mark "cache-vfs: andere versie aangetroffen — bestanden opnieuw uit de pin"
    restore_to_pin $PREVIOUS $(patch_files) || exit 1
  fi
  echo "   cache-vfs: toepassen op $WORK_DIR"
  if ! patch -p1 -N --forward -d "$WORK_DIR" < "$CACHE_PATCH"; then
    echo "Fout: switch-cache-vfs.patch past niet meer op $WORK_DIR — upstream (pin 8b33d310) wijzigde een van zijn bestanden. Kijk met 'git diff' in third_party/DriftDroid naar wat er verschoven is en maak de patch opnieuw tegen die pin." >&2
    exit 1
  fi
  cache_applied || {
    echo "Fout: cache-vfs-patch liep zonder fout maar staat niet byte-gelijk in $WORK_DIR." >&2
    exit 1
  }
  # De stempel onthoudt welke bestanden nu gepatcht zijn, zodat een volgende, weer
  # andere versie juist díe terugzet naar de pin vóórdat hij zich schrijft.
  patch_files > "$CACHE_STAMP" || {
    echo "Fout: cache-stempel kon niet geschreven worden: $CACHE_STAMP" >&2
    exit 1
  }
  mark "cache-vfs: toegepast en teruglees-controle geslaagd"
fi

# Compilercache: de devkitA64-toolchain schrijft de compiler absouut voor
# (/opt/devkitpro/devkitA64/bin/…), dus een PATH-masquerade wordt genegeerd.
# CMAKE_<LANG>_COMPILER_LAUNCHER in de top van runtime/CMakeLists.txt wél:
# CMake zet dan vóór elke compilatie ccache voor diezelfde absolute compiler.
# Effect op de bytes is er niet — identieke invoer levert identieke objecten.
CMAKE_TOP="$WORK_DIR/runtime/CMakeLists.txt"
if grep -q 'MKW_CCACHE_LAUNCHER' "$CMAKE_TOP"; then
  mark "ccache-launcher: al aanwezig"
else
  awk '
    { print }
    /^project\(mkw_recompiled\)/ && !done {
      print ""
      print "# MKW_CCACHE_LAUNCHER — door de one-click bouwer ingevoegd, geen upstream-wijziging."
      print "find_program(MKW_CCACHE_PROGRAM ccache)"
      print "if(MKW_CCACHE_PROGRAM)"
      print "    set(CMAKE_CXX_COMPILER_LAUNCHER \"${MKW_CCACHE_PROGRAM}\")"
      print "    set(CMAKE_C_COMPILER_LAUNCHER \"${MKW_CCACHE_PROGRAM}\")"
      print "endif()"
      done = 1
    }
  ' "$CMAKE_TOP" > "$CMAKE_TOP.mkwtmp" && mv "$CMAKE_TOP.mkwtmp" "$CMAKE_TOP"
  grep -q 'MKW_CCACHE_LAUNCHER' "$CMAKE_TOP" || {
    echo "Fout: ccache-launcher kon niet ingevoegd worden in $CMAKE_TOP" >&2
    exit 1
  }
  mark "ccache-launcher: ingevoegd na project(mkw_recompiled)"
fi

# Windows-les: de ingebouwde curl van cmake heeft daar geen vertrouwde CA-boom, dus elke
# FetchContent-download (abseil-cpp, xxhash, SDL3) faalt met status 60 "SSL peer
# certificate … was not OK". CMAKE_TLS_CAINFO is daar de officieel ondersteunde
# variabele voor; FetchContent draagt hem aan de download-subbuild over. Zetten op
# de command-line kan niet, want upstream bouwt die argumentlijst zelf in
# scripts/build-local-native-deko3d.sh, dus hij vóór de eerste add_subdirectory in
# de top-CMakeLists — wat precies de WORK_DIR is die hier al gepatcht wordt, dus
# wederom geen upstream-wijziging. TLS-verificatie blijft aan: CMAKE_TLS_VERIFY=0
# zou een beveiligingsverslechtering zijn en wordt daarom nadrukkelijk niet gebruikt.
if grep -q 'MKW_TLS_CAINFO' "$CMAKE_TOP"; then
  mark "ca-bundle: al aanwezig"
else
  awk '
    { print }
    /^project\(mkw_recompiled\)/ && !done {
      print ""
      print "# MKW_TLS_CAINFO — door de one-click bouwer ingevoegd, geen upstream-wijziging."
      print "if(DEFINED ENV{MKW_TLS_CAINFO})"
      print "    set(CMAKE_TLS_CAINFO \"$ENV{MKW_TLS_CAINFO}\")"
      print "endif()"
      done = 1
    }
  ' "$CMAKE_TOP" > "$CMAKE_TOP.mkwtmp" && mv "$CMAKE_TOP.mkwtmp" "$CMAKE_TOP"
  grep -q 'MKW_TLS_CAINFO' "$CMAKE_TOP" || {
    echo "Fout: ca-bundle kon niet ingevoegd worden in $CMAKE_TOP" >&2
    exit 1
  }
  mark "ca-bundle: ingevoegd na project(mkw_recompiled)"
fi

# De vertaal-kant van Windows. Translator.Core/IO/AssemblyBlobWriter.cs kiest de
# assemblage-syntaxis van de data-sectie op `OperatingSystem.IsWindows()`: een
# Windows-vertaler schrijft COFF/PE-vlaggen (`.section .rdata,"dr"`), een Linux-
# vertaler ELF (`.section .rodata,"a",@progbits`) plus een `.note.GNU-stack`. Die
# aanname is juist zolang het product op hetzelfde platform wordt gelinkt — maar
# wij vertalen op Windows en linken naar ELF voor de Switch. binutils 2.46 (de
# huidige devkitPro-pakketten) verwerpt de COFF-vlaggen voor ELF dan met
# "unrecognized .section attribute" en "SHF_ALLOC isn't set for GNU_MBIND section",
# wat de link van een verder perfecte bouw op één bestand laat falen. Dit blok schrijft
# het gegenereerde bestand naar exact de vorm die de Linux-vertaler produceert.
# Bewust niet de C#-bron aanpassen: die staat op pin 8b33d310 en hoort byte-
# identiek te blijven, net als de patcher waar de ontvangst naar hash.
for BLOBS in "$WORK_DIR"/generated/*.S; do
  [ -f "$BLOBS" ] || continue
  grep -q '\.section \.rdata,"dr"' "$BLOBS" || continue
  sed -e 's|^\.section \.rdata,"dr".*|.section .rodata,"a",@progbits|' "$BLOBS" | tr -d '\r' > "$BLOBS.mkwtmp"
  grep -q '\.note\.GNU-stack' "$BLOBS.mkwtmp" \
    || printf '.section .note.GNU-stack,"",@progbits\n' >> "$BLOBS.mkwtmp"
  mv -f "$BLOBS.mkwtmp" "$BLOBS"
  mark "data-blobs: $(basename "$BLOBS") naar ELF-sectievorm (+ GNU-stack, LF-einden)"
done
