#!/usr/bin/env bash
# setup-native.sh — gereedschap voor een bouw zonder Docker, op de host zelf.
#
#   bash tools/setup-native.sh              # wat heeft deze host, wat ontbreekt
#   bash tools/setup-native.sh --install    # toolchain + gereedschap neerhalen
#   bash tools/setup-native.sh --install --render
#   bash tools/setup-native.sh --install --prefix "pad/naar/toolchain"
#
# --install gebruikt de officiële pakketten van devkitPro (pkg.devkitpro.org) voor
# de toolchain en de officiële release-bundels van Kitware, ninja, ccache en
# Microsoft (.NET 8, nodig om de vertaler te bouwen) voor de rest. Alles wordt
# uitgepakt met de tar van het besturingssysteem zelf: geen Docker, geen
# installator, geen administratorrechten. Het landt in een losse map (standaard
# $HOME/mkw-toolchain) die je weer kunt weggooien; de rest van de host blijft schoon.
#
# --install haalt het gereedschap voor de *productbouw* op: vertaler, compilers,
# linker, verpakker. --render haalt daarna het gereedschap voor de
# eenmalige renderstack (Dawn + libuam): meson en Mako via pip in een eigen
# prefix, en op Windows winflexbison (bison + flex) van de releasepagina van
# lexxmark/winflexbison, met een SHA-256-controle. De motor geeft die vlag
# automatisch mee als hij de renderstack nog moet bouwen.
#
# Let op: dit zet de *gereedschappen* neer. De bouw van de renderstack zelf kost
# daarna nog uren (Dawn + libuam, scripts/prepare-native-deko3d-deps.sh). Wie die
# stack al als deps-cache heeft, is die drie gereedschappen kwijt: de motor bouwt
# dan alleen de vertaalde shards en linkt.
set -uo pipefail

WS="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$WS/tools/native-env.sh"

PREFIX="${MKW_TOOLCHAIN_PREFIX:-$HOME/mkw-toolchain}"
INSTALL=0
RENDER=0

while [ $# -gt 0 ]; do
  case "$1" in
    --install) INSTALL=1 ;;
    # --render alleen is niet "alleen rapporteren": wie die vlag noemt, wil die
    # gereedschappen, en de rest van deze installatie is er de voorwaarde voor.
    --render) RENDER=1; INSTALL=1 ;;
    --prefix) PREFIX="${2:?--prefix heeft een map nodig}"; shift ;;
    *) printf 'onbekende optie: %s\n' "$1" >&2; exit 2 ;;
  esac
  shift
done

OS="$(uname -s 2>/dev/null || echo unknown)"
case "$OS" in
  MINGW*|MSYS*|CYGWIN*) HOST_OS=windows; HOST_ARCH=x86_64 ;;
  Linux)                HOST_OS=linux;   HOST_ARCH="$(uname -m)" ;;
  Darwin)               HOST_OS=macos;   HOST_ARCH="$(uname -m)" ;;
  *)                    HOST_OS=unknown; HOST_ARCH=x86_64 ;;
esac

LIBS="https://pkg.devkitpro.org/packages"        # doelkant: host-onafhankelijk
HOSTREPO=""
case "$HOST_OS" in
  windows) HOSTREPO="$LIBS/windows/$HOST_ARCH" ;;
  linux)   HOSTREPO="$LIBS/linux/$HOST_ARCH" ;;
esac

# Doeepakketten: arch "any", dus dezelfde bestanden op elk besturingssysteem.
TARGET_PKGS="libnx deko3d switch-cmake devkita64-cmake dkp-cmake-common-utils devkita64-newlib switch-pkg-config"
# Hostpakketten: compiler, linker en de verpakkingsgereedschappen (elf2nro, nacptool).
HOST_PKGS="devkita64-gcc devkita64-binutils switch-tools general-tools"

TAR_BIN=tar
if [ "$HOST_OS" = windows ]; then
  # Windows' bsdtar kan .zst en .xz; de tar uit Git Bash niet altijd. De Windows-map
  # volgt $SYSTEMROOT, want een installatie op een andere schijfletter dan C: bestaat
  # ook; de /c/-vorm blijft als back-up voor een shell zonder die variabele.
  for _t in "${SYSTEMROOT:-C:/Windows}/System32/tar.exe" /c/Windows/System32/tar.exe; do
    [ -x "$_t" ] && { TAR_BIN="$_t"; break; }
  done
fi

say() { printf '%s\n' "$*"; }
die() { printf 'FOUT: %s\n' "$*" >&2; exit 1; }

fetch_db() { # fetch_db <url> <bestemmingsbestand>
  [ -s "$2" ] && return 0
  # pacman is de enige UA die devkitPro's mirror voor databanken accepteert.
  curl -fsSL -A "pacman/6.1.0" -o "$2.part" "$1" || return 1
  mv -f "$2.part" "$2"
}

fetch_pkg() { # fetch_pkg <repo-url> <databank> <pakketnaam> <in-namellijst:>
  local repo="$1" db="$2" naam="$3" fn url
  fn=$("$TAR_BIN" -xzOf "$db" "$naam-"*/desc 2>/dev/null | awk '/^%FILENAME%$/{getline; gsub(/\r/,""); print; exit}')
  [ -n "$fn" ] || { say "  overslaan: $naam staat niet in de databank"; return 1; }
  if [ "$4" = libs ]; then url="$LIBS/$fn"; else url="$repo/$fn"; fi
  if [ ! -s "$DL/$fn" ]; then
    say "  halen: $fn"
    curl -fsSL -A "pacman/6.1.0" -o "$DL/$fn.part" "$url" || { rm -f "$DL/$fn.part"; say "  LUKKNIET: $url"; return 1; }
    mv -f "$DL/$fn.part" "$DL/$fn"
  fi
  say "  uitpakken: $fn"
  "$TAR_BIN" -xf "$DL/$fn" -C "$PREFIX" || return 1
}

report() {
  say "== wat heeft deze host =="
  if native_probe; then
    say "devkitA64 gevonden: $DEVKITPRO"
    say "  compiler: $("$DEVKITPRO/devkitA64/bin/aarch64-none-elf-g++" --version 2>/dev/null | head -1)"
  else
    say "devkitA64: $NATIVE_MISS"
  fi
  local t
  for t in cmake ninja python3 git dotnet ccache; do
    if command -v "$t" >/dev/null 2>&1; then
      say "  $t: ja"
    else
      say "  $t: ONTBREKEND"
    fi
  done
  say ""
  if native_render_probe; then
    say "renderstack-gereedschap (meson, bison, flex, mako): compleet"
  else
    say "renderstack-gereedschap: ONTBREKEND$RENDER_MISS"
    say "  alleen nodig voor de eenmalige bouw van Dawn + libuam: bash tools/setup-native.sh --install --render"
  fi
  say ""
  say "== wat betekent dit =="
  case "$HOST_OS" in
    linux)
      say "devkitA64 + libnx:  bash tools/setup-native.sh --install"
      say "                     (of devkitPro's eigen pacman-setup: apt.devkitpro.org/install-devkitpro-pacman)"
      say "meson/bison/flex:   sudo apt install meson bison flex python3-mako"
      ;;
    windows)
      say "devkitA64 + libnx:  bash tools/setup-native.sh --install"
      say "                     (devkitPro's eigen Windows-pakketten; geen Docker, geen installator)"
      say "meson/bison/flex:   bash tools/setup-native.sh --install --render"
      say "                     (meson + Mako via pip in de gereedschapsmap, winflexbison van github.com/lexxmark/winflexbison)"
      ;;
    macos)
      say "devkitA64 + libnx:  de devkitPro-installer van github.com/devkitPro/installer, of hun"
      say "                     pacman-route: https://devkitpro.org/wiki/devkitPro_pacman"
      say "meson/bison/flex:   brew install meson bison flex mako"
      ;;
    *) say "onbekend besturingssysteem: $OS" ;;
  esac
  say "De motor kiest automatisch: native zodra dit gevonden is, anders docker."
}

if [ "$INSTALL" = 0 ]; then
  report
  exit 0
fi

[ -n "$HOSTREPO" ] || die "automatische installatie kent alleen Windows en Linux; op macOS: github.com/devkitPro/installer"
DBCACHE="$PREFIX/db"; DL="$PREFIX/dl"
mkdir -p "$PREFIX/opt/devkitpro" "$DBCACHE" "$DL" || die "kan $PREFIX niet aanmaken"
say "== gereedschap naar $PREFIX/opt/devkitpro =="

fetch_db "$LIBS/dkp-libs.db" "$DBCACHE/libs.db" || die "databank $LIBS/dkp-libs.db niet bereikbaar"
say "- doeel-libraries"
for p in $TARGET_PKGS; do fetch_pkg "$LIBS" "$DBCACHE/libs.db" "$p" libs || true; done

fetch_db "$HOSTREPO/dkp-$HOST_OS.db" "$DBCACHE/host.db" || die "databank $HOSTREPO/dkp-$HOST_OS.db niet bereikbaar"
say "- host-gereedschap"
for p in $HOST_PKGS; do fetch_pkg "$HOSTREPO" "$DBCACHE/host.db" "$p" host || true; done

# ---------------------------------------------------------------------------
# Host-gereedschap dat devkitPro niet levert: cmake, ninja, ccache en .NET 8.
# Alle vier van hun eigen officiële release-pagina, als portable archief: geen
# installator, geen administrator, alles in $PREFIX. native_use_portable zet ze
# op de PATH, dus de motor vindt ze na dit gesprek alsof ze systeemweit staan.
# ---------------------------------------------------------------------------
extract_to() { # extract_to <archief> <map>
  local arc="$1" dir="$2"
  mkdir -p "$dir" || return 1
  case "$arc" in
    *.zip)
      if [ "$HOST_OS" = windows ]; then "$TAR_BIN" -xf "$arc" -C "$dir"; return $?; fi
      if command -v unzip >/dev/null 2>&1; then unzip -q -o "$arc" -d "$dir"; return $?; fi
      python3 - "$arc" "$dir" <<'PY'
import os, sys, zipfile
with zipfile.ZipFile(sys.argv[1]) as z:
    z.extractall(sys.argv[2])
for root, _, files in os.walk(sys.argv[2]):
    for f in files:
        p = os.path.join(root, f)
        os.chmod(p, os.stat(p).st_mode | 0o111)
PY
      ;;
    *) "$TAR_BIN" -xf "$arc" -C "$dir" ;;
  esac
}

sha256_of() { # sha256_of <bestand>
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1; exit}'
  elif command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1; exit}'
  else python3 -c 'import hashlib,sys;print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$1"; fi
}

install_archive() { # install_archive <url> <destmap> <strip-n> [sha256]
  local url="$1" dest="$2" strip="$3" want="${4:-}" fn tmp src sub d i got
  fn="${url##*/}"
  if [ ! -s "$DL/$fn" ]; then
    say "  halen: $fn"
    curl -fL --retry 3 -o "$DL/$fn.part" "$url" \
      || { rm -f "$DL/$fn.part"; say "  LUKKNIET: $url"; return 1; }
    mv -f "$DL/$fn.part" "$DL/$fn"
  fi
  # Een gecheckte bron is een gepinde bron: de releasepagina kan vandaag een
  # andere binair leveren dan gisteren, en een bouw die dan mislukt wijst naar
  # deze map in plaats naar de game. Een cached archief dat niet klopt, wordt
  # weggegooid zodat de volgende run het opnieuw haalt.
  if [ -n "$want" ]; then
    got=$(sha256_of "$DL/$fn")
    if [ "$got" != "$want" ]; then
      say "  SHA-256 klopt niet: $fn (verwacht $want, gekregen ${got:-geen}) — archief weggegooid"
      rm -f "$DL/$fn"
      return 1
    fi
    say "  sha256 gecontroleerd: $fn"
  fi
  tmp="$DL/x-$fn"; rm -rf "$tmp"; mkdir -p "$tmp"
  extract_to "$DL/$fn" "$tmp" || { rm -rf "$tmp"; say "  uitpakken mislukt: $fn"; return 1; }
  src="$tmp"; i=0
  while [ "$i" -lt "$strip" ]; do
    d=""
    for sub in "$src"/*/; do [ -d "$sub" ] && { d="$sub"; break; }; done
    [ -n "$d" ] || { rm -rf "$tmp"; say "  verpakking onverwacht: $fn"; return 1; }
    src="$d"; i=$(( i + 1 ))
  done
  mkdir -p "$dest"
  # tar-pijp, geen cp -r: behoudt exec-bits op Linux en werkt met Windows-bsdtar.
  ( cd "$src" && tar -cf - . ) | ( cd "$dest" && tar -xf - ) || { rm -rf "$tmp"; return 1; }
  rm -rf "$tmp"
  say "  naar: $dest"
}

TOOL_SPECS=""
case "$HOST_OS" in
  windows)
    TOOL_SPECS="
cmake|https://github.com/Kitware/CMake/releases/download/v3.30.5/cmake-3.30.5-windows-x86_64.zip|$PREFIX/cmake|1
ninja|https://github.com/ninja-build/ninja/releases/download/v1.12.1/ninja-win.zip|$PREFIX/bin|0
ccache|https://github.com/ccache/ccache/releases/download/v4.10.2/ccache-4.10.2-windows-x86_64.zip|$PREFIX/bin|1
dotnet|https://builds.dotnet.microsoft.com/dotnet/Sdk/8.0.427/dotnet-sdk-8.0.427-win-x64.zip|$PREFIX/dotnet|0
" ;;
  linux)
    TOOL_SPECS="
cmake|https://github.com/Kitware/CMake/releases/download/v3.30.5/cmake-3.30.5-linux-x86_64.tar.gz|$PREFIX/cmake|1
ninja|https://github.com/ninja-build/ninja/releases/download/v1.12.1/ninja-linux.zip|$PREFIX/bin|0
ccache|https://github.com/ccache/ccache/releases/download/v4.10.2/ccache-4.10.2-linux-x86_64.tar.xz|$PREFIX/bin|1
dotnet|https://builds.dotnet.microsoft.com/dotnet/Sdk/8.0.427/dotnet-sdk-8.0.427-linux-x64.tar.gz|$PREFIX/dotnet|0
" ;;
esac

say "- host-gereedschap (cmake, ninja, ccache, .NET 8)"
native_use_portable
while IFS='|' read -r tool url dest strip; do
  [ -n "$tool" ] || continue
  if command -v "$tool" >/dev/null 2>&1; then
    say "  aanwezig: $tool ($(command -v "$tool"))"
    continue
  fi
  install_archive "$url" "$dest" "$strip" || true
  native_use_portable
done <<EOF
$TOOL_SPECS
EOF

# De ingebouwde curl van cmake kent op Windows geen eigen CA-bundel, dus elke
# download in de build (abseil, xxhash, SDL3) faalt op status 60. Haal de officiële
# Mozilla-bundel van curl.se als er geen bundel op de host gevonden wordt.
if ! native_ca_bundle >/dev/null 2>&1; then
  say "- CA-bundel voor cmake (curl.se/ca/cacert.pem)"
  mkdir -p "$PREFIX/ssl" && curl -fL --retry 3 -o "$PREFIX/ssl/ca-bundle.crt" \
    https://curl.se/ca/cacert.pem && say "  naar: $PREFIX/ssl/ca-bundle.crt" \
    || say "  LUKKNIET: geen CA-bundle gehaald; downloads in de bouw zullen falen"
fi

# ---------------------------------------------------------------------------
# --render: het gereedschap voor de eenmalige renderstack (Dawn + libuam).
#
# scripts/prepare-native-deko3d-deps.sh eist meson, bison, flex en (via python3)
# Mako. Geen van die vier zit in devkitPro's pakketten en géén van ze heeft een
# installator nodig: meson + Mako gaan met `pip install --prefix` in een eigen
# boom, en op Windows levert winflexbison beide generators als losse .exe's in
# één zip. De deps-script kijkt naar `bison`/`flex`; de zip heet ze
# `win_bison`/`win_flex`, dus ernaast staan kopiën onder de naam die gezocht wordt
# — dezelfde binaire, dus dezelfde versie en dezelfde `data/`-boom ernaast.
#
# Dit is géén garantie dat de stack daarna bouwbaar is: die bouw zelf duurt uren.
# Wat hier staat, is alleen dat de vier commando's bestaan.
# ---------------------------------------------------------------------------
install_pip_tools() {
  local py="" c args
  for c in python3 python; do
    command -v "$c" >/dev/null 2>&1 && { py="$c"; break; }
  done
  [ -n "$py" ] || { say "  LUKKNIET: geen python3 op de PATH; meson en Mako hebben python nodig"; return 1; }
  args=(install --no-input --prefix "$PREFIX/pytools" meson Mako)
  say "  halen: meson + Mako via pip, naar $PREFIX/pytools"
  if "$py" -m pip "${args[@]}" >/dev/null 2>&1; then
    native_use_portable
    say "  naar: $PREFIX/pytools"
    return 0
  fi
  # PEP 668: een distro-python verbiedt pip buiten een venv. Met --prefix landt
  # er niets in die python, dus dat verbod is hier een formaliteit.
  "$py" -m ensurepip >/dev/null 2>&1 || true
  if "$py" -m pip "${args[@]}" --break-system-packages >/dev/null 2>&1; then
    native_use_portable
    say "  naar: $PREFIX/pytools"
    return 0
  fi
  say "  LUKKNIET: pip kon meson/Mako niet zetten ($py -m pip install --prefix $PREFIX/pytools meson Mako)"
  return 1
}

install_render() {
  say "- renderstack-gereedschap (meson, Mako, bison, flex)"
  native_use_portable
  if command -v meson >/dev/null 2>&1 && python3 -c 'import mako' >/dev/null 2>&1; then
    say "  aanwezig: meson $(meson --version 2>/dev/null) + mako"
  else
    install_pip_tools || true
  fi
  case "$HOST_OS" in
    windows)
      if command -v bison >/dev/null 2>&1 && command -v flex >/dev/null 2>&1; then
        say "  aanwezig: bison + flex"
      else
        install_archive \
          https://github.com/lexxmark/winflexbison/releases/download/v2.5.25/win_flex_bison-2.5.25.zip \
          "$PREFIX/wfb" 0 8d324b62be33604b2c45ad1dd34ab93d722534448f55a16ca7292de32b6ac135 \
          || { say "  bison/flex ontbreken dus nog"; return 1; }
        local exe alt
        for pair in "win_bison:bison" "win_flex:flex"; do
          exe="${pair%%:*}" alt="${pair##*:}"
          [ -f "$PREFIX/wfb/$exe.exe" ] || continue
          [ -f "$PREFIX/wfb/$alt.exe" ] || cp "$PREFIX/wfb/$exe.exe" "$PREFIX/wfb/$alt.exe"
        done
        native_use_portable
      fi
      ;;
    linux)
      if command -v bison >/dev/null 2>&1 && command -v flex >/dev/null 2>&1; then
        say "  aanwezig: bison + flex"
      else
        say "  bison/flex: deze installer kan die twee niet zonder root zetten."
        say "              sudo apt install bison flex   (of: sudo dnf install bison flex, sudo pacman -S bison flex)"
        return 1
      fi
      ;;
    *) say "  bison/flex: onbekend besturingssysteem; zet ze zelf op de PATH"; return 1 ;;
  esac
  if native_render_probe; then
    say "  compleet: meson $(command -v meson), bison $(command -v bison), flex $(command -v flex)"
    return 0
  fi
  say "  nog niet compleet:$RENDER_MISS"
  return 1
}

if [ "$RENDER" = 1 ]; then
  install_render || true
elif ! native_render_probe; then
  say "- renderstack-gereedschap: overgeslagen (nodig voor de eenmalige Dawn + libuam-bouw; voeg --render toe)"
fi

say "== controle =="
report
native_probe && say "KLAAR: de motor bouwt nu zonder Docker."
