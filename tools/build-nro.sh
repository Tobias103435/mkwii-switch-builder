#!/usr/bin/env bash
# The one-click builder: your Wii dump in, a native Switch .nro out.
#
#   bash tools/build-nro.sh                 # smart: reuse what is valid, build the rest
#                                           #   (~10 s if nothing changed, ~1 min with the
#                                           #    build cache in place, ~17 min from empty)
#   bash tools/build-nro.sh --full          # retranslate: ~17 min on this PC
#   bash tools/build-nro.sh --dump "path/dump.rvz"
#   bash tools/build-nro.sh --zip           # also make the SD zip (tools/pack-sd.sh)
#   bash tools/build-nro.sh --deploy        # also push the .nro to the console (FTP)
#   bash tools/build-nro.sh --expect none   # do not check a hash expectation
#   bash tools/build-nro.sh --free-cache    # cleanup that also drops the 5 GiB build cache
#   bash tools/build-nro.sh --plan          # only show what would happen
#
# This script contains no build logic: the steps live in tools/nro-engine.sh and
# the display in tools/nro-ui.sh. That way every platform entry point (MKWii-Builder.cmd
# for Windows, MKWii-Builder.command for macOS/Linux, the browser window, a terminal),
# drives the same engine through the NDJSON contract. This file only: passes arguments
# through, writes a log and shows the raw builder text when something goes wrong.
#
# This script deletes no game data and writes nothing to the SD card except with --deploy.
# Requires a devkitA64 toolchain (bash tools/setup-native.sh --install) or, as a
# fallback, a running Docker; the engine fetches the rest itself.
set -uo pipefail

WS="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENGINE="$WS/tools/nro-engine.sh"
UI="$WS/tools/nro-ui.sh"
LOGDIR="$WS/logs"
mkdir -p "$LOGDIR"
STAMP="$(date +%Y%m%d-%H%M%S)"
NDJSON="$LOGDIR/build-nro-$STAMP.ndjson"
RAW="$LOGDIR/engine-build-raw.log"

case "${1:-}" in
  -h|--help) sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
esac

if [ ! -f "$ENGINE" ] || [ ! -f "$UI" ]; then
  echo "Error: tools/nro-engine.sh and tools/nro-ui.sh must sit next to this file." >&2
  exit 1
fi

# stdout van de motor = machineleesbaar contract, gaat naar de UI én naar het logboek.
# stderr van de motor = de rauwe bouwer-/ninja-stroom, apart vastgelegd.
bash "$ENGINE" "$@" 2>"$RAW" | tee "$NDJSON" | bash "$UI"
codes=("${PIPESTATUS[@]}")
code=${codes[0]}
if [ "$code" = 0 ]; then code=${codes[2]}; fi

echo
echo "  NDJSON log: $NDJSON"
if [ "$code" != 0 ]; then
  echo "  Raw builder log: $RAW"
  echo "  Last lines:"
  tail -n 12 "$RAW" 2>/dev/null | sed 's/^/    /'
  echo
  echo "  FAILED (exit code $code)."
fi
echo "  The .nro contains recompiled Nintendo code: do not publish it, personal use only."
exit "$code"
