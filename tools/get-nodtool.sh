#!/usr/bin/env bash
# get-nodtool.sh — zet een ECHT bijbehorende nodtool op deze machine, zonder Docker.
#
#   bash tools/get-nodtool.sh            # halen (of hergebruiken) wat hier past
#   bash tools/get-nodtool.sh --check    # alleen melden wat er staat
#   bash tools/get-nodtool.sh --force    # opnieuw halen
#
# nod is de lezer van de schijfbeelden (.rvz .wbfs .iso .gcm); zonder nod komt er
# niets uit een dump. De releases van encounter/nod bevatten per besturingssysteem
# één los commando-programma, dus dit script kiest het juiste, controleert de
# SHA-256 en legt het in .local/bin van deze map. Er wordt niets geïnstalleerd op
# de computer zelf en er gaat niets naar buiten: alleen dit programma wordt
# opgehaald, en het wordt door de SHA-256 die hieronder staat vastgepind.
#
# Waarom pinnen: een download van internet is pas vertrouwd als je weet wat je
# kreeg. De hashes hier zijn met de hand gemeten (2026-11-02, deze versie); wijkt
# de hash af, dan stopt dit script en roept niets anders uit.
set -uo pipefail

WS="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BINDIR="$WS/.local/bin"
NOD_VERSION="v2.0.0-alpha.12"
UPSTREAM="https://github.com/encounter/nod"

FORCE=0
CHECK_ONLY=0
for a in "$@"; do
  case "$a" in
    --check) CHECK_ONLY=1 ;;
    --force) FORCE=1 ;;
    -h|--help) sed -n '2,18p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $a" >&2; exit 2 ;;
  esac
done

# ---- wat is dit voor een machine ------------------------------------------------
os="$(uname -s)"
case "$os" in
  Linux) NOD_OS=linux ;;
  Darwin) NOD_OS=macos ;;
  MINGW*|MSYS*|CYGWIN*) NOD_OS=windows ;;
  *) echo "unsupported OS: $os" >&2; exit 1 ;;
esac
arch="$(uname -m)"
case "$arch" in
  x86_64|amd64) NOD_ARCH=x86_64 ;;
  arm64) NOD_ARCH=arm64 ;;
  aarch64) if [ "$NOD_OS" = windows ]; then NOD_ARCH=arm64; else NOD_ARCH=aarch64; fi ;;
  *) echo "unsupported CPU: $arch" >&2; exit 1 ;;
esac

asset="nodtool-$NOD_OS-$NOD_ARCH"
[ "$NOD_OS" = windows ] && asset="$asset.exe"

# vastgepinde SHA-256 per programma (NOD_VERSION hierboven, 2026-11-02 gemeten)
pin=""
case "$asset" in
  nodtool-windows-x86_64.exe) pin="f65de62c44f0ad5d179eff85bd1e92099713ffacbf717f651fb761129a25c7bc" ;;
  nodtool-windows-arm64.exe)  pin="463d5f7fd7d753fde05c6772f8114ec6f8ab6eaf054790ed9b95a89ef8c63526" ;;
  nodtool-linux-x86_64)       pin="ee8345c004248eb82a86dd0c6068e0fcf3dc75baf68d18fe949bf4589822f5a5" ;;
  nodtool-linux-aarch64)      pin="33e801c0e4aee7e714ad84e89521f50e2f79005571b9d4779b695e44ea21ff99" ;;
  nodtool-macos-x86_64)       pin="d1e7ba904c2e557fafbd3bf2d9b75a7901a2bf1568c0fb3a505fca0f30b0a833" ;;
  nodtool-macos-arm64)        pin="524c0b27c0c4289e435df4474d288ea7e63d6a34814cc7c650231688dd1e53b4" ;;
esac
[ -n "$pin" ] || { echo "no pin for $asset - add it to tools/get-nodtool.sh" >&2; exit 1; }

sha_tool=""
if command -v sha256sum >/dev/null 2>&1; then sha_tool=sha256sum
elif command -v shasum >/dev/null 2>&1; then sha_tool=shasum
fi
hash_of() {
  [ -n "$sha_tool" ] || return 1
  case "$sha_tool" in
    sha256sum) sha256sum "$1" | cut -d' ' -f1 ;;
    shasum) shasum -a 256 "$1" | cut -d' ' -f1 ;;
  esac
}

DEST="$BINDIR/$asset"

# macOS: a downloaded program carries a "from the internet" mark and Gatekeeper
# then blocks it; dropping that attribute is the honest way to let it run.
macos_unquarantine() {
  [ "$NOD_OS" = macos ] || return 0
  xattr -d com.apple.quarantine "$1" 2>/dev/null || true
}

if [ "$CHECK_ONLY" = 1 ]; then
  if [ -f "$DEST" ]; then
    have="$(hash_of "$DEST" || echo unreadable)"
    if [ "$have" = "$pin" ]; then
      echo "nodtool ready: $DEST ($NOD_VERSION, sha256 $have)"
      exit 0
    fi
    echo "nodtool WRONG hash: $DEST has $have, pin wants $pin" >&2
    exit 1
  fi
  echo "nodtool not fetched yet: $DEST (want $asset from $NOD_VERSION)"
  exit 1
fi

if [ -f "$DEST" ] && [ "$FORCE" != 1 ]; then
  have="$(hash_of "$DEST" || echo unreadable)"
  if [ "$have" = "$pin" ]; then
    echo "nodtool already here, hash matches: $DEST"
    exit 0
  fi
  echo "nodtool was present but did not match the pin ($have) - fetching again"
fi

command -v curl >/dev/null 2>&1 || { echo "curl is needed to fetch nodtool" >&2; exit 1; }
url="$UPSTREAM/releases/download/$NOD_VERSION/$asset"
mkdir -p "$BINDIR"
tmp="$DEST.part"
echo "fetching $asset ($NOD_VERSION) from the nod releases"
if ! curl -fL --retry 3 -m 900 -o "$tmp" "$url"; then
  rm -f "$tmp"
  echo "download failed: $url" >&2
  exit 1
fi
have="$(hash_of "$tmp" || echo unreadable)"
if [ "$have" != "$pin" ]; then
  rm -f "$tmp"
  echo "refusing to install: SHA-256 $have != the pinned $pin" >&2
  exit 1
fi
mv -f "$tmp" "$DEST"
chmod 755 "$DEST"
macos_unquarantine "$DEST"
echo "nodtool installed: $DEST (sha256 $have)"
