#!/usr/bin/env bash
# native-env.sh — zoekt een native devkitA64-install op het host-systeem.
#
#   . tools/native-env.sh && native_probe        # set DEVKITPRO/DEVKITARM, of reden in $NATIVE_MISS
#
# Wordt geprefix (sourced), nooit uitgevoerd: de gevonden paden moeten in de
# omgeving van de motor blijven staan. De motor gebruikt dit om te beslissen of
# hij zonder Docker kan bouwen; docker is alleen een valback voor wie geen
# toolchain geïnstalleerd heeft.
#
# Vereisten van de native-route (hetzelfde wat de container biedt):
#   devkitA64  : aarch64-none-elf-g++, linker scripts, sysroot
#   libnx      : $DEVKITPRO/libnx/{include,lib} + switch.specs + switch.ld
#   portlibs   : $DEVKITPRO/portlibs/switch (of $DEVKITPRO/portlibs op Linux)
#   tools      : elf2nro + nacptool in $DEVKITPRO/tools/bin
#   host       : git, cmake, ninja, python3, dotnet 8 voor de vertaler
set -u

NATIVE_MISS=""

# De kleine app haalt gereedschap zelf naar een losse map (standaard
# $HOME/mkw-toolchain) in plaats van naar de host te installeren. Deze functie
# zet die mappen op de PATH vóór elke zoekronde, zodat een gedownloade cmake,
# ninja, ccache of .NET door native_probe gevonden wordt alsof ze systeemweit
# geïnstalleerd zijn.
#
# `pytools` is de pip-`--prefix` van setup-native.sh --render: daar liggen meson
# en Mako. Een console-script in zo'n prefix voegt zijn eigen site-packages níet
# aan sys.path toe, dus die boom moet óók op PYTHONPATH — anders bestaat meson wel,
# maar crasht het onmiddellijk op "No module named mesonbuild", en `import mako`
# in het deps-script faalt net zo.
native_use_portable() {
  local root="${MKW_TOOLCHAIN_PREFIX:-$HOME/mkw-toolchain}" p add=""
  for p in "$root/bin" "$root/cmake/bin" "$root/dotnet" "$root/wfb" \
           "$root/pytools/Scripts" "$root/pytools/bin"; do
    [ -d "$p" ] || continue
    case ":$PATH:" in *":$p:"*) continue ;; esac
    add="${add:+$add:}$p"
  done
  # Het scheidingsteken hoort tussen de nieuwe mappen en de oude PATH. Zonder
  # die dubbele punt lijm je de laatste entry op de eerste van de gastheer
  # ("/…/Scripts" + "/c/…/.qoder/bin" is één pad dat nergens bestaat) en verdwijnt
  # die oude map stilletjes uit de zoekroute. Meson was hier de eerste die het zag.
  [ -n "$add" ] && export PATH="$add:$PATH"
  for p in "$root/pytools/Lib/site-packages" \
           "$root"/pytools/lib/python*/site-packages; do
    [ -d "$p" ] || continue
    case ":${PYTHONPATH:-}:" in *":$p:"*) continue ;; esac
    export PYTHONPATH="${PYTHONPATH:+$PYTHONPATH:}$p"
  done
  return 0
}

# Heeft deze host het gereedschap voor de eenmalige renderstack (Dawn + libuam)?
# Dat is méér dan de toolchain: de productbouw zelf heeft meson, bison, flex en
# Mako niet aan. De motor vraagt dit alleen wanneer de deps-cache ontbreekt en
# die stack dus gebouwd moet worden; $RENDER_MISS noemt de ontbrekende stukken.
native_render_probe() {
  RENDER_MISS=""
  native_use_portable
  local t
  for t in meson bison flex; do
    command -v "$t" >/dev/null 2>&1 || RENDER_MISS="$RENDER_MISS $t"
  done
  if native_python_setup; then
    python3 -c 'import mako' >/dev/null 2>&1 || RENDER_MISS="$RENDER_MISS mako(python3)"
  else
    RENDER_MISS="$RENDER_MISS python3"
  fi
  [ -z "$RENDER_MISS" ]
}

# Een `command -v python3` is géén bewijs dat Python er is. Op Windows wijst die
# naam naar de Store-alias in `%LOCALAPPDATA%\Microsoft\WindowsApps\python.exe`:
# vanuit bash doet hij alsof hij bestaat, en hij faalt pas met "Python was not
# found; run without arguments to install from the Microsoft Store". In dit
# project gebeurde dat midden in de vertaling — vijftien minuten later, exit 49,
# één regel in de faal. Daarom: dezelfde zoeker als de GUI (échte interpreter,
# alias onderaan), en daarna een shim in de gereedschapsmap zodat `python` en
# `python3` in élk dochterproces naar die interpreter wijzen — ook in de
# upstream-scripts, die de naam letterlijk aanroepen. De PATH van de gastheer
# wordt niet aangerakt, alleen die van deze procesboom.
native_python_setup() {
  local py shim tools_dir n
  if [ -n "${MKW_PYTHON_OK:-}" ] && [ -x "${MKW_PYTHON_OK}" ]; then return 0; fi
  tools_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  py="$(bash "$tools_dir/ensure-ui-env.sh" --posix 2>/dev/null)" || return 1
  [ -n "$py" ] && [ -x "$py" ] || return 1
  shim="${MKW_PYSHIM_DIR:-${WS:-$tools_dir/..}/.local/pyshim}"
  mkdir -p "$shim" 2>/dev/null || return 1
  for n in python python3; do
    { printf '#!/bin/sh\nexec "%s" "$@"\n' "$py" > "$shim/$n" && chmod 0755 "$shim/$n"; } || return 1
  done
  case ":$PATH:" in
    *":$shim:"*) ;;
    *) PATH="$shim:$PATH" ;;
  esac
  export PATH PYTHON="$py" MKW_PYTHON_OK="$py"
}

native_probe() {
  NATIVE_MISS=""
  native_use_portable
  local cand portable
  # de kleine app installeert zíjn gereedschap in een eigen map (via
  # MKW_TOOLCHAIN_PREFIX, of in .local/mkw-toolchain naast de app) en die moet
  # hier bóvenaan staan: anders is een zojuist geslaagde download van 532 MB weg
  # en valt de motor terug op docker. native_use_portable zet dezelfde map al op
  # de PATH voor cmake/ninja/ccache/.NET; devkitPro was dat tot nu toe vergeten.
  portable="${MKW_TOOLCHAIN_PREFIX:-}"
  [ -n "$portable" ] || portable="${WS:+$WS/.local/mkw-toolchain}"
  if [ -n "${DEVKITPRO:-}" ]; then
    cand="$DEVKITPRO"
  else
    for cand in "${portable:+$portable/opt/devkitpro}" \
                /opt/devkitpro \
                "$HOME/mkw-toolchain/opt/devkitpro" \
                "${SYSTEMDRIVE:-}/devkitPro" \
                "${SYSTEMDRIVE:-}/msys64/opt/devkitpro" "${SYSTEMDRIVE:-}/msys64/devkitPro" \
                "${LOCALAPPDATA:-}/devkitPro" \
                /c/devkitPro \
                /c/msys64/opt/devkitpro /c/msys64/devkitPro \
                /usr/local/devkitpro /opt/homebrew/opt/devkitpro; do
      [ -n "$cand" ] || continue
      [ -f "$cand/cmake/Switch.cmake" ] && break
    done
  fi
  [ -n "$cand" ] && [ -f "$cand/cmake/Switch.cmake" ] || {
    NATIVE_MISS="no devkitPro install found (tried \$DEVKITPRO, the app's own toolchain folder, /opt/devkitpro, the system drive's devkitPro and msys64). Install devkitA64 + libnx, or let the engine build via --docker."
    return 1
  }
  export DEVKITPRO="$cand"
  export DEVKITARM="${DEVKITARM:-$cand/devkitA64}"

  local miss="" tool
  for tool in "devkitA64/bin/aarch64-none-elf-g++" "tools/bin/elf2nro" "libnx/lib/libnx.a"; do
    if [ -f "$DEVKITPRO/$tool" ] || [ -f "$DEVKITPRO/$tool.exe" ] || [ -f "$DEVKITPRO/$tool".* ]; then
      continue
    fi
    miss="$miss $tool"
  done
  for tool in git cmake ninja dotnet; do
    command -v "$tool" >/dev/null 2>&1 || miss="$miss $tool"
  done
  # python3 staat hier níét bij de andere namen: `command -v` laat de
  # Store-alias slagen en de bouw valt dan vijftien minuten later. Deze zoeker
  # draait de interpreter werkelijk en legt een shim neer die `python3` aan die
  # interpreter koppelt.
  native_python_setup || miss="$miss python3"
  # portlibs zit op Linux onder portlibs, op Windows/MSYS2 onder portlibs/switch.
  if [ ! -d "$DEVKITPRO/portlibs/switch" ] && [ ! -d "$DEVKITPRO/portlibs" ]; then
    miss="$miss portlibs"
  fi
  if [ -n "$miss" ]; then
    NATIVE_MISS="devkitPro is at $DEVKITPRO but is missing:$miss"
    return 1
  fi
  return 0
}

# devkitPro verbiedt Windows-cmaker expliciet: dkp-initialize-path.cmake opent met
# een FATAL_ERROR "CMake must be installed and launched from msys2". Dat is een
# beleid, geen technische grens — de cross-compilers in ónze eigen, zelf uitgepakte
# prefix zijn gewone Windows-.exe's en cmake en ninja draaien hier al. Deze functie
# neutraliseert daarom precies die één regel, laat alle andere devkitPro-regels
# ongemoeid, en bewaart het ongeschonden bestand als .orig zodat het terug te zetten
# is. Idempotent (merker grep) en stillerig op platformen waar de abort er niet is.
native_toolchain_win_patch() {
  local f="${DEVKITPRO:-}/cmake/dkp-initialize-path.cmake"
  [ -f "$f" ] || return 0
  grep -q 'MKW:Windows-abort' "$f" && return 0
  grep -q 'FATAL_ERROR "CMake must be installed and launched from msys2' "$f" || return 0
  cp "$f" "$f.orig" || return 1
  sed -i '/FATAL_ERROR "CMake must be installed and launched from msys2/c\  # MKW:Windows-abort geneutraliseerd: devkitPro-cmake draait hier onder Windows-cmake' "$f"
  grep -q 'MKW:Windows-abort' "$f" || {
    echo "Error: cannot reach the Windows abort in $f — devkitPro has been moved, look at $f.orig." >&2
    return 1
  }
  echo ">> devkitPro Windows-abort geneutraliseerd in $f (terugzetten: $f.orig)"
}

# Cmake's eigen curl heeft op Windows geen standaard-CA-boom, dus elke FetchContent
# (abseil, xxhash, SDL3) strandt op status 60. Deze zoeker levert een bestand dat
# wél vertrouwen waard is: de bundle van de Git-installatie, van msys2, of door
# setup-native.sh opgehaalde cacert.pem. De eerste treft; een ontbrekende bundle is
# geen reden om verificatie uit te zetten (CMAKE_TLS_VERIFY=0 blijft verboden).
native_ca_bundle() {
  local c
  # De Git-installatie waardoor deze shell zelf draait is de zekerste bron: `cygpath
  # -w /` is háár map, op welke schijfletter die ook staat. Zonder die zoeker zou
  # een builder op D: of E: zijn CA-bundle moeten missen terwijl hij die bij zich
  # heeft. msys2 geeft met dezelfde regel zijn eigen mingw64-bundle.
  local gitroot=""
  if command -v cygpath >/dev/null 2>&1; then
    gitroot="$(cygpath -w / 2>/dev/null | sed 's%[\\/]*$%%')"
  fi
  for c in "${MKW_TLS_CAINFO:-}" \
           "${gitroot:+$gitroot/mingw64/etc/ssl/certs/ca-bundle.crt}" \
           "${LOCALAPPDATA:-}/mkw-ca/cacert.pem" \
           "$HOME/mkw-toolchain/ssl/ca-bundle.crt" \
           "${SYSTEMDRIVE:-}/msys64/mingw64/etc/ssl/certs/ca-bundle.crt" \
           "${SYSTEMDRIVE:-}/Program Files/Git/mingw64/etc/ssl/certs/ca-bundle.crt" \
           /c/mingw64/etc/ssl/certs/ca-bundle.crt \
           /c/msys64/etc/ssl/certs/ca-bundle.crt \
           "/c/Program Files/Git/mingw64/etc/ssl/certs/ca-bundle.crt" \
           "/c/Program Files/Git1/mingw64/etc/ssl/certs/ca-bundle.crt" \
           /etc/ssl/certs/ca-certificates.crt \
           /usr/local/etc/openssl/cert.pem; do
    [ -n "$c" ] && [ -f "$c" ] && { printf '%s\n' "$c"; return 0; }
  done
  return 1
}

# De poortbibliotheken uit het devkitPro-pakketarchief dragen het Linux-pad
# `/opt/devkitpro/…`. De .pc-bestanden hoeven daar niet voor te worden aangepast:
# pkgconf (3.x) leidt de echte prefix af uit de plaats van het bestand, dus
# `pkg-config --libs zlib` geeft hier al het hostpad. Wél hardgeschreven in de
# CMake-pakketconfigs van diezelfde bomen, en cmake leest die letterlijk:
# freetype-config.cmake zet `INTERFACE_LINK_LIBRARIES "/opt/devkitpro/…/libz.a;…"`.
# Dat absolute pad bestaat op de host niet, dus ninja's linkregel strandt op
# `missing and no known rule to make it` vóór de eerste link. Deze functie verzet
# alléén dat prefix in die pakketconfigs — geen archiefbyte, geen .pc, geen enkele
# door de ontvangst gehashte regel.
#
# Idempotent, want de vervanging zelf bevat `/opt/devkitpro` als deelstring: stap
# één vouwt elk reeds verzet pad terug naar de leesbron-vorm, stap twee verzet
# één keer. Twee runs geven zo dezelfde tekst.
native_portlibs_relocate() {
  local base root want n=0 f rest
  root="${DEVKITPRO:-}/portlibs/switch/lib/cmake"
  [ -d "$root" ] || return 0
  base="${DEVKITPRO%/opt/devkitpro}"
  [ "$base" != "$DEVKITPRO" ] || {
    echo "Error: DEVKITPRO=$DEVKITPRO does not end in /opt/devkitpro — root unknown." >&2
    return 1
  }
  # In de container én op een Linux-host met de standaardinstallatie is het pad
  # al correct; er is dan niets te verzetten.
  [ -n "$base" ] || return 0
  want="$(cygpath -m "$base" 2>/dev/null || printf '%s' "$base")"
  while IFS= read -r -d '' f; do
    sed -e "s|$want/opt/devkitpro|/opt/devkitpro|g" -e "s|/opt/devkitpro|$want/opt/devkitpro|g" -i "$f" || return 1
    n=$(( n + 1 ))
  done < <(grep -rlZ '/opt/devkitpro' "$root" 2>/dev/null)
  # Bewijs: na het verzetten mag geen enkel pad buiten de host-wortel staan. De
  # test vouwt eerst elk geldig hostpad weg; wat dan nog `/opt/devkitpro` bevat,
  # is een dubbel gezet of onbruikbaar pad.
  rest=$(while IFS= read -r -d '' f; do
           sed "s|$want/opt/devkitpro||g" "$f" | grep -q '/opt/devkitpro' && printf '%s\n' "$f"
         done < <(grep -rlZ '/opt/devkitpro' "$root" 2>/dev/null))
  [ -z "$rest" ] || { echo "Fout: verzetten onvolledig in: $rest" >&2; return 1; }
  [ "$n" = 0 ] || echo ">> portlibs-cmake verzet: $n pakketconfig(s) wijzen nu naar $want/opt/devkitpro"
}

# Maakt een geëxporteerde deps-boom op Windows git-leesbaar zodat de
# upstream-provenancepoort (scripts/build-local-native-deko3d.sh) zijn hashes
# reproduceert. Een Linux-volume-boom bevat gebroken symlinks (Mac-pad),
# exec-bits en vuile submodule-werkbomen; Windows-git struikelt daarover en
# zou elke drek als "gewijzigd" rapporteren, dus de poort faalt op een boom die
# byte-identiek is. Na deze instellingen gaf de export exact de received hashes
# (dawn_worktree_diff = fc2ed472…, abseil = 7d26b156…, uam = leeg).
# Aanroeper: tools/build-in-container.sh, alleen op MINGW/MSYS/CYGWIN.
native_deps_hygiene() { # native_deps_hygiene <depsdir>
  local deps="$1" repo link tgt n=0
  # Elke git-repo in de boom, dus óók de submodules van Dawn: de upstream-poort
  # loopt met `--ignore-submodules=none` door die bomen heen en vererft anders de
  # globale Windows-core.autocrlf, waardoor elk tekstbestand "gewijzigd" lijkt.
  local repos=""
  while IFS= read -r -d '' g; do
    repo="$(dirname "$g")"
    [ -e "$repo/.git" ] || continue
    repos="$repos
$repo"
  done < <(find "$deps/dawn" "$deps/uam" -name .git -print0 2>/dev/null)
  while IFS= read -r repo; do
    [ -n "$repo" ] || continue
    [ -e "$repo/.git" ] || continue
    git -C "$repo" config core.autocrlf false
    git -C "$repo" config core.eol lf
    git -C "$repo" config core.safecrlf false
    git -C "$repo" config core.symlinks false
    git -C "$repo" config core.filemode false
    git -C "$repo" config core.ignorecase false
    git -C "$repo" config core.trustctime false
    git -C "$repo" config diff.ignoreSubmodules all
  done <<EOF
$repos
EOF
  while IFS= read -r -d '' link; do
    tgt=$(readlink "$link") || continue
    rm -f "$link" && printf '%s' "$tgt" > "$link" && n=$(( n + 1 ))
  done < <(find "$deps/dawn" "$deps/uam" -type l -print0 2>/dev/null)
  echo ">> deps-hygiëne (Windows): symlinks materiaalised=$n, git-config gezet in alle dep-repos"
}
