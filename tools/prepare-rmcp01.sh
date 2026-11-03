#!/usr/bin/env bash
# Haalt uit de eigen PAL-RMCP01-dump precies die inputs die WiiCompiled-Switch verwacht.
# Stappen: info -> extract -> sha-controle -> in debouwposities plaatsen.
# Niets hier kopieert game-data naar git; alles blijft onder discs/ en local-product/.
set -euo pipefail

WS="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DISC="${1:-$WS/discs/mkw-pal.rvz}"
REPO="$WS/WiiCompiled-Switch"
EXTRACT="$WS/discs/extract"
ASSETS="$REPO/local-product/Assets"
GEN="$REPO/local-product/generated"
NOD="$WS/tools/nodtool"
MANIFEST="$REPO/local-product-support/recomp.local.yml"

[ -f "$DISC" ] || { echo "Fout: dump niet gevonden: $DISC" >&2; exit 1; }
[ -f "$NOD" ] || { echo "Fout: $NOD ontbreekt" >&2; exit 1; }

echo "[1/5] Disc-info (region-ID, revisie, versleuteling)"
mkdir -p "$WS/discs"
bash "$NOD" info "$DISC" | tee "$WS/discs/disc-info.txt"

# nod schrijft de DATA-partitie direct in de doelmap: sys/ + files/ + ticket/TMD.
if [ -f "$EXTRACT/sys/main.dol" ] && [ -d "$EXTRACT/files" ]; then
  echo "[2/5] Extractie bestaat al over te slaan: $EXTRACT"
else
  echo "[2/5] Extraheren van de DATA-partitie (dit is de zware stap)"
  rm -rf "$EXTRACT"
  bash "$NOD" extract "$DISC" "$EXTRACT" -p data
fi

dol="$(find "$EXTRACT" -type f -path '*/sys/main.dol' | head -1)"
rel="$(find "$EXTRACT" -type f -name 'StaticR.rel' | head -1)"
fst="$(find "$EXTRACT" -type f -path '*/sys/fst.bin' | head -1)"
boot="$(find "$EXTRACT" -type f -path '*/sys/boot.bin' | head -1)"
for v in dol rel fst boot; do
  [ -n "${!v}" ] || { echo "Fout: ${v} niet gevonden in $EXTRACT" >&2; exit 1; }
done

echo "[3/5] SHA-256 van de inputs vs. de pinnen in het manifest"
want_dol="$(sed -n '/^  dol:/,/  rel:/p' "$MANIFEST" | awk '/sha256/{print $2}')"
want_rel="$(sed -n '/^  rel:/,/^translation:/p' "$MANIFEST" | awk '/sha256/{print $2}')"
got_dol="$(sha256sum "$dol" | awk '{print $1}')"
got_rel="$(sha256sum "$rel" | awk '{print $1}')"
printf 'main.dol     : %s\n  verwacht   : %s\n' "$got_dol" "$want_dol"
printf 'StaticR.rel  : %s\n  verwacht   : %s\n' "$got_rel" "$want_rel"
if [ "$got_dol" = "$want_dol" ] && [ "$got_rel" = "$want_rel" ]; then
  echo "MATCH: dump is exact dezelfde PAL-revisie als waar upstream op gebouwd is."
else
  echo "VERSCHIL: andere dumprevisie. Het manifest en de adres-attributie moeten" >&2
  echo "op jouw hashes worden gezet voordat er vertaald kan worden." >&2
fi

echo "[4/5] Inputs op hun plaats leggen"
mkdir -p "$ASSETS" "$GEN"
cp "$dol" "$ASSETS/main.dol"
cp "$rel" "$ASSETS/StaticR.rel"
cp "$MANIFEST" "$REPO/local-product/recomp.yml"

echo "  Assets: $(du -h "$ASSETS/main.dol" "$ASSETS/StaticR.rel" | awk '{print $1, $2}' | tr '\n' ' ')"

echo "[5/5] DVD-bron voor de console (DATA/sys + DATA/files)"
mkdir -p "$WS/discs/sd-DATA"
sd_src="$(dirname "$(dirname "$fst")")"
for item in sys files; do
  [ -e "$sd_src/$item" ] && cp -a "$sd_src/$item" "$WS/discs/sd-DATA/"
done
du -sh "$WS/discs/sd-DATA"/* 2>/dev/null || true
echo "$REPO local-product:" && du -sh "$GEN" 2>/dev/null || true
