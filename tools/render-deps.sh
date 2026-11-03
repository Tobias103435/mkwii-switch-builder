#!/usr/bin/env bash
# The render stack (Dawn + libuam) as a portable package.
#
# A recipient who builds this stack here spends hours compiling Dawn for
# devkitA64. `--make` on a machine that already has it packs only what the
# product build really links afterwards into one verified file (~72 MB xz for
# 650 MB); `--install` fetches that, checks it against the pin in
# tools/render-deps-pins.env and places it at the paths
# scripts/build-local-native-deko3d.sh itself uses.
#
#   bash tools/render-deps.sh --status
#   bash tools/render-deps.sh --make  [output-file]
#   bash tools/render-deps.sh --install [file|url]
#   bash tools/render-deps.sh --source            # what this host would take: source + bytes
#   bash tools/render-deps.sh --verify
#   bash tools/render-deps.sh --print-pins [file]
#
# With no argument, --install first looks in dist/render-deps/ and then at
# MKW_RENDER_DEPS_URL. A package that fails the pin is not installed;
# MKW_ALLOW_UNPINNED=1 bypasses that, for the developer only.
set -euo pipefail

WS="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PINS="$WS/tools/render-deps-pins.env"
LOCAL_SEARCH="${MKW_RENDER_DEPS_LOCAL:-$WS/dist/render-deps}"

# Het deps-pad volgt dezelfde zoekvolgorde als tools/nro-engine.sh, zodat dit
# script en de motor nooit naar twee verschillende bomen kijken.
DEPS_DIR="${MKW_DEKO3D_DEPS_DIR:-${MKW_DEPS_DIR:-}}"
if [ -z "$DEPS_DIR" ]; then
  for c in "$WS/.deps/native-deko3d" "$HOME/mkw-toolchain/deps/native-deko3d" \
           "$HOME/mkw-deps/native-deko3d" "/opt/mkw-deps/native-deko3d"; do
    if [ -f "$c/dawn-build-switch/src/dawn/native/libwebgpu_dawn.a" ] ||
       [ -f "$c/native-deko3d-toolchain.receipt" ] || [ -f "$c/.mkw-render-package" ]; then
      DEPS_DIR="$c"; break
    fi
  done
  [ -n "$DEPS_DIR" ] || DEPS_DIR="$WS/.deps/native-deko3d"
fi

DAWN_DIR="$DEPS_DIR/dawn"
DAWN_BUILD="$DEPS_DIR/dawn-build-switch"
DAWN_LIB="$DAWN_BUILD/src/dawn/native/libwebgpu_dawn.a"
UAM_DIR="$DEPS_DIR/uam"
UAM_LIB="$UAM_DIR/build-switch/libuam.a"
RECEIPT="$DEPS_DIR/native-deko3d-toolchain.receipt"
MARKER="$DEPS_DIR/.mkw-render-package"

# Wat er in het pakket thuishoort: alleen de kop-en-staart van de stack. De
# bronbomen die de build-tree wél bevat (third_party, angle, dxc, de complete
# Dawn- en uam-werkboom) zijn voor het compileren, niet voor het linken.
PACK_PATHS=(
  "dawn/include"
  "dawn-build-switch/gen/include"
  "dawn-build-switch/src/dawn/native/libwebgpu_dawn.a"
  "uam/build-switch/libuam.a"
)

sha() { sha256sum "$1" | awk '{print $1}'; }
bytes_of() { wc -c < "$1" | tr -d ' '; }
die() { echo "error: $*" >&2; exit 1; }

have_package_stack() { [ -f "$MARKER" ] && [ -f "$DAWN_LIB" ] && [ -f "$UAM_LIB" ] && [ -f "$RECEIPT" ]; }
have_source_stack()  { [ -f "$DAWN_LIB" ] && [ -f "$UAM_LIB" ] && [ -d "$DAWN_DIR/.git" ]; }

read_pin() { # read_pin <key> — the pins file is data, never a shell source
  # No Python here on purpose. The engine may have found its interpreter under
  # `python`, `py -3` or not at all, and this function decides whether the render
  # stack arrives as a 76 MB package or gets compiled for hours. A missing
  # `python3` must never be able to silently pick the slow route.
  [ -f "$PINS" ] || return 0
  sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*//p" "$PINS" | head -n 1 |
    sed -e "s/^[\"']//" -e "s/[\"'][[:space:]]*$//"
}

# ---- manifest ---------------------------------------------------------------
# Regelvorm: <sha256> <bytes> <pad>. Eén spatie als scheider, want `read -r`
# knipt de twee eerste velden af en laat het pad (mag spaties bevatten) heel.
manifest_write() { # manifest_write <map>: sha256 + grootte van elk meegepakt bestand
  local root="$1" rel
  : > "$root/MANIFEST.txt"
  ( cd "$root"
    find . -type f ! -name MANIFEST.txt -print | sed 's|^\./||' | LC_ALL=C sort |
    while IFS= read -r rel; do
      printf '%s %s %s\n' "$(sha "./$rel")" "$(bytes_of "./$rel")" "$rel" >> "$root/MANIFEST.txt"
    done )
}

manifest_check() { # manifest_check <map>: de lijst is de belofte, hier wordt hij afgerekend
  local root="$1" sum bytes rel
  [ -s "$root/MANIFEST.txt" ] || die "package has no MANIFEST.txt"
  while read -r sum bytes rel; do
    [ -n "$rel" ] || continue
    [ -f "$root/$rel" ] || die "package is missing $rel"
    [ "$(bytes_of "$root/$rel")" = "$bytes" ] || die "$rel has the wrong size"
    [ "$(sha "$root/$rel")" = "$sum" ] || die "$rel has the wrong sha256"
  done < "$root/MANIFEST.txt"
}

write_licenses() { # de bronnen blijven naamrechtelijk in orde: hun licentieteksten reizen mee
  local stage="$1"
  mkdir -p "$stage/LICENSES"
  cp "$DAWN_DIR/LICENSE" "$stage/LICENSES/dawn-BSD-3.txt" 2>/dev/null || true
  cp "$DAWN_DIR/third_party/abseil-cpp/LICENSE" "$stage/LICENSES/abseil-Apache-2.0.txt" 2>/dev/null || true
  cp "$UAM_DIR/LICENSE" "$stage/LICENSES/uam-zlib.txt" 2>/dev/null || true
  {
    echo "This archive contains compiled objects of Dawn/Tint (BSD-3-Clause, Google and"
    echo "the Dawn & Tint authors), Abseil (Apache-2.0) and libuam (zlib-style licence,"
    echo "fincs; parts imported from Mesa under its MIT licence). The licence texts are"
    echo "in LICENSES/. No Nintendo code and no game data is included: the objects come"
    echo "only from google/dawn, averne/libuam and their pinned third_party trees,"
    echo "built by scripts/prepare-native-deko3d-deps.sh at the commits named in"
    echo "native-deko3d-toolchain.receipt."
  } > "$stage/LICENSES.txt"
}

# ---- --make -----------------------------------------------------------------
do_make() {
  local out="${1:-}" stage tag dawn8 uam8 date p
  have_source_stack || die "no built render stack in $DEPS_DIR — this machine still has to compile it once (that is the hours part)"
  [ -f "$RECEIPT" ] || die "no receipt in $DEPS_DIR"
  dawn8="$(awk -F= '/^dawn_base_commit=/{print substr($2,1,8)}' "$RECEIPT")"
  uam8="$(awk -F= '/^uam_commit=/{print substr($2,1,8)}' "$RECEIPT")"
  date="$(date -u +%Y%m%d)"
  tag="mkw-render-deko3d-${dawn8}-${uam8}-${date}"
  [ -n "$out" ] || out="$WS/dist/render-deps/$tag.tar.xz"
  command -v xz >/dev/null 2>&1 || die "xz is needed to pack (650 MB stays ~72 MB with it)"
  mkdir -p "$(dirname "$out")"

  # Staging met hardlinks: het 600 MB archive kost dan geen extra ruimte en geen
  # kopieertijd, maar vraagt wel hetzelfde bestandssysteem.
  stage="$DEPS_DIR/.pack-$$"
  rm -rf "$stage"
  mkdir -p "$stage"
  for p in "${PACK_PATHS[@]}"; do
    [ -e "$DEPS_DIR/$p" ] || die "the package would be incomplete: $DEPS_DIR/$p is missing"
    mkdir -p "$stage/$(dirname "$p")"
    cp -al "$DEPS_DIR/$p" "$stage/$p" 2>/dev/null || cp -R "$DEPS_DIR/$p" "$stage/$p"
  done
  cp "$RECEIPT" "$stage/native-deko3d-toolchain.receipt"

  # De marker vertelt de productbouw dat deze boom uit een pakket komt. De
  # zekerheid zit niet in die tekst maar in de ontvangst: native-deko3d-
  # toolchain.receipt noemt de archives, de patches en de pins, en die wordt bij
  # elke bouw nage rekend met de patches die in de gereedschapsmap staan.
  {
    echo "MKW-RENDER-PACKAGE=1"
    echo "built=$date"
    echo "dawn_base_commit=$dawn8"
    echo "uam_commit=$uam8"
    echo "source_deps_dir=$DEPS_DIR"
    echo "packed_from=$(awk -F= '/^(compiler|cmake|ninja|meson|devkitpro)=/{print}' "$RECEIPT" | tr '\n' ' ')"
  } > "$stage/.mkw-render-package"
  write_licenses "$stage"
  manifest_write "$stage"

  tar -cJf "$out" -C "$stage" \
      .mkw-render-package MANIFEST.txt LICENSES.txt native-deko3d-toolchain.receipt \
      dawn dawn-build-switch uam LICENSES || die "packing failed"
  rm -rf "$stage"
  ( cd "$(dirname "$out")" && sha256sum "$(basename "$out")" > "$(basename "$out").sha256" )

  echo ">> package: $out ($(bytes_of "$out") bytes)"
  echo ">> sha256 : $(sha "$out")"
  write_pins "$out"
  echo
  echo ">> pinned in: $PINS (fill in MKW_RENDER_DEPS_URL there once the file is hosted)"
}

write_pins() { # keep the pin with the package: retyping it by hand is the error source
  # awk, not Python: `--make` runs on the build host, and that host decides later
  # whether the stack arrives as a package or gets compiled — see read_pin().
  local file="$1" digest name bytes
  digest="$(sha "$file")"
  name="$(basename "$file")"
  bytes="$(bytes_of "$file")"
  [ -f "$PINS" ] || : > "$PINS"
  awk -v name="$name" -v digest="$digest" -v bytes="$bytes" '
    function setline(key, value) { print key "=\"" value "\""; seen[key] = 1 }
    {
      key = $0
      if (key ~ /^[[:space:]]*#/ || key !~ /=/) { print; next }
      sub(/[[:space:]]*=.*$/, "", key); gsub(/^[[:space:]]+|[[:space:]]+$/, "", key)
      if (key == "MKW_RENDER_DEPS_NAME")   { setline(key, name);   next }
      if (key == "MKW_RENDER_DEPS_SHA256") { setline(key, digest); next }
      if (key == "MKW_RENDER_DEPS_BYTES")  { setline(key, bytes);  next }
      print
    }
    END {
      if (!seen["MKW_RENDER_DEPS_NAME"])   setline("MKW_RENDER_DEPS_NAME", name)
      if (!seen["MKW_RENDER_DEPS_SHA256"]) setline("MKW_RENDER_DEPS_SHA256", digest)
      if (!seen["MKW_RENDER_DEPS_BYTES"])  setline("MKW_RENDER_DEPS_BYTES", bytes)
    }
  ' "$PINS" > "$PINS.new" && mv -f "$PINS.new" "$PINS"
  echo ">> pins updated in $PINS: $digest"
}

# ---- --install --------------------------------------------------------------
resolve_source() { # --install zonder argument: eerst de lokale map, dan de pinned url
  local src="${1:-}" url name found
  [ -n "$src" ] && { printf '%s\n' "$src"; return 0; }
  name="$(read_pin MKW_RENDER_DEPS_NAME)"
  if [ -d "$LOCAL_SEARCH" ] && [ -n "$name" ] && [ -f "$LOCAL_SEARCH/$name" ]; then
    printf '%s\n' "$LOCAL_SEARCH/$name"; return 0
  fi
  url="$(read_pin MKW_RENDER_DEPS_URL)"
  if [ -n "$url" ]; then printf '%s\n' "$url"; return 0; fi
  if [ -d "$LOCAL_SEARCH" ]; then
    found="$(find "$LOCAL_SEARCH" -maxdepth 1 -name 'mkw-render-deko3d-*.tar.*' ! -name '*.sha256' -print -quit 2>/dev/null)"
    [ -n "$found" ] && { printf '%s\n' "$found"; return 0; }
  fi
  return 1
}

expected_sha() { # expected_sha <source>: de pin hoort bij een naam, niet bij elk bestand
  local src="$1" name
  name="$(basename "$src")"
  if [ -n "$(read_pin MKW_RENDER_DEPS_SHA256)" ] && [ "$(read_pin MKW_RENDER_DEPS_NAME)" = "$name" ]; then
    printf '%s pin\n' "$(read_pin MKW_RENDER_DEPS_SHA256)"; return 0
  fi
  if [ -f "$src.sha256" ]; then
    printf '%s sidecar\n' "$(awk '{print $1}' "$src.sha256" | head -1)"; return 0
  fi
  return 1
}

fetch() { # fetch <bron> -> pad naar een lokaal bestand
  local src="$1" out
  if [ -f "$src" ]; then printf '%s\n' "$src"; return 0; fi
  case "$src" in
    http://*|https://*) ;;
    *) die "neither a file nor a url: $src" ;;
  esac
  mkdir -p "$LOCAL_SEARCH"
  out="$LOCAL_SEARCH/$(basename "$src")"
  rm -f "$out.part"
  echo ">> downloading: $src" >&2
  curl --fail --location --retry 3 --retry-delay 2 --connect-timeout 15 -o "$out.part" "$src" >&2 \
    || die "download failed: $src"
  mv -f "$out.part" "$out"
  printf '%s\n' "$out"
}

do_install() {
  local src want srcfile info
  have_package_stack && { echo ">> render stack already present as a package in $DEPS_DIR"; return 0; }
  have_source_stack && { echo ">> render stack already present as a source tree in $DEPS_DIR — nothing to do"; return 0; }
  src="$(resolve_source "${1:-}")" ||
    die "no render-stack package found: set the url in $PINS, put the file in $LOCAL_SEARCH, or build the stack here"
  info="$(expected_sha "$src")" || info=""
  if [ -n "$info" ]; then
    want="${info%% *}"; echo ">> sha256 to check (${info##* }): $want" >&2
  elif [ "${MKW_ALLOW_UNPINNED:-0}" = 1 ]; then
    want=""; echo ">> WARNING: unpinned package, only because MKW_ALLOW_UNPINNED=1" >&2
  else
    die "$src does not match the pin in $PINS — add its sha256 (or, for development only, MKW_ALLOW_UNPINNED=1)"
  fi
  srcfile="$(fetch "$src")"
  if [ -n "$want" ]; then
    [ "$(sha "$srcfile")" = "$want" ] || die "sha256 of $srcfile does not match the pin — refusing to install"
    echo ">> sha256 matches" >&2
  fi

  # Uitpakken in een tijdelijke map ernaast en pas daarna overal tegelijk
  # neerzetten: een afgebroken of halfreturned pakket mag nooit een halve
  # renderstack achterlaten waar de bouw later op crasht.
  local stage="$DEPS_DIR/.unpack-$$"
  trap 'rm -rf "$stage"' EXIT
  rm -rf "$stage"; mkdir -p "$stage"
  tar -xf "$srcfile" -C "$stage" || die "unpacking failed: $srcfile"
  manifest_check "$stage"
  [ -f "$stage/.mkw-render-package" ] || die "the package has no .mkw-render-package marker"
  mkdir -p "$DEPS_DIR"
  cp -R "$stage/." "$DEPS_DIR/" || die "placing into $DEPS_DIR failed"
  rm -rf "$stage"
  trap - EXIT
  do_verify
  echo ">> render stack installed from the package into $DEPS_DIR"
}

# ---- --verify ---------------------------------------------------------------
do_verify() {
  [ -f "$MARKER" ] || die "no render-stack package in $DEPS_DIR (marker missing)"
  manifest_check "$DEPS_DIR"
  # De twee archives zijn het enige wat echt gelinkt wordt. Ontbreken de
  # Deko3D-symbolen, dan zegt de bouw later alleen 'undefined reference'; die
  # teleurstelling kost weer uren, dus wordt hier naar gekeken.
  local nm="${DEVKITPRO:-}/devkitA64/bin/aarch64-none-elf-nm"
  if [ -x "$nm" ]; then
    "$nm" -C --defined-only "$DAWN_LIB" 2>/dev/null | grep -q 'dawn::native::deko3d' ||
      die "libwebgpu_dawn.a shows no dawn::native::deko3d symbols"
    echo ">> Deko3D symbols present in libwebgpu_dawn.a"
  else
    echo ">> symbol check skipped: no aarch64-nm (DEVKITPRO not set?)"
  fi
  echo ">> package is sound: $(wc -l < "$DEPS_DIR/MANIFEST.txt" | tr -d ' ') files, sha256 verified"
}

do_source() { # --source: wat pakt deze host? twee regels: bron en omvang in bytes
  local src bytes
  src="$(resolve_source '')" || return 1
  bytes="$(read_pin MKW_RENDER_DEPS_BYTES)"
  [ -f "$src" ] && bytes="$(bytes_of "$src")"
  printf '%s\n%s\n' "$src" "${bytes:-0}"
}

do_status() {
  printf 'deps dir      : %s\n' "$DEPS_DIR"
  if have_package_stack; then
    printf 'render stack  : package (%s bytes Dawn, %s bytes libuam)\n' "$(bytes_of "$DAWN_LIB")" "$(bytes_of "$UAM_LIB")"
  elif have_source_stack; then
    printf 'render stack  : source tree (built on this host)\n'
  else
    printf 'render stack  : missing\n'
  fi
  printf 'pin name      : %s\n' "$(read_pin MKW_RENDER_DEPS_NAME)"
  printf 'pin url       : %s\n' "$(read_pin MKW_RENDER_DEPS_URL)"
  printf 'pin sha256    : %s\n' "$(read_pin MKW_RENDER_DEPS_SHA256)"
  printf 'pin bytes     : %s\n' "$(read_pin MKW_RENDER_DEPS_BYTES)"
  printf 'local folder  : %s%s\n' "$LOCAL_SEARCH" "$([ -d "$LOCAL_SEARCH" ] && echo '' || echo '  (does not exist yet)')"
}

do_print_pins() {
  local out="${1:-}" name
  [ -n "$out" ] && [ -f "$out" ] || die "nothing to print; give the file that was made"
  name="$(basename "$out")"
  cat <<EOF
MKW_RENDER_DEPS_NAME="$name"
MKW_RENDER_DEPS_URL=""
MKW_RENDER_DEPS_SHA256="$(sha "$out")"
MKW_RENDER_DEPS_BYTES="$(bytes_of "$out")"
EOF
}

usage() { sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; }

case "${1:---status}" in
  --status) do_status ;;
  --make) shift; do_make "${1:-}" ;;
  --install) shift; do_install "${1:-}" ;;
  --source) do_source ;;
  --verify) do_verify ;;
  --print-pins) shift; do_print_pins "${1:-}" ;;
  -h|--help|help) usage ;;
  *) die "unknown option: $1 (see --help)" ;;
esac
