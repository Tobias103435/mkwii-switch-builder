#!/usr/bin/env bash
# bouw-nro.command — double-click entry point for macOS and Linux.
#
# Does exactly what Bouw-NRO.cmd does on Windows: with Python 3 the window first
# (pick a ROM, Start, progress bar), without Python the builder right here in
# this terminal window. All logic lives in tools/nro-engine.sh; these two entry
# points only contain the splash, the choice and the pause.
#
# From a terminal:  ./bouw-nro.command --full --zip
set -uo pipefail
cd "$(dirname "$0")" || exit 1

ENGINE=tools/nro-engine.sh
UI=tools/nro-ui.sh
WEBUI=tools/nro-webui.py

if [ ! -f "$ENGINE" ] || [ ! -f "$UI" ]; then
  echo "Error: $ENGINE and $UI must sit next to this file." >&2
  read -r -p "Press Enter to close: " _
  exit 1
fi

if ! command -v docker >/dev/null 2>&1 \
   && ! bash -c 'cd "'"$(dirname "$0")"'" && . tools/native-env.sh && native_probe' >/dev/null 2>&1; then
  echo "No build environment found."
  echo "Without Docker (recommended):  bash tools/setup-native.sh --install"
  echo "                     — fetches devkitA64 + libnx in under a minute."
  echo "Or install Docker Desktop / docker-ce and start it."
  read -r -p "Press Enter to close: " _
  exit 1
fi

echo
echo "  WiiCompiled-Switch — one-click .nro builder"
echo "  dump in, native Switch .nro + drag-and-drop SD folder out."
echo "  Full rebuild ~12 min on the test PC (8 cores), incremental 0-1 min."
echo "  Requires: devkitA64 (or Docker as fallback), git, your own Wii dump."
echo

# Python for the window is looked up by tools/ensure-ui-env.sh, on every platform,
# and only accepted after it really printed 1. --posix: a shell wants /c/... paths,
# cmd.exe wants backslashes; the Windows entry uses the same finder without it.
FINDER=tools/ensure-ui-env.sh
PYCMD=""
if [ -f "$FINDER" ]; then
  PYCMD=$(bash "$FINDER" --posix 2>/dev/null || true)
else
  for cand in python3 python; do
    if [ "$(LANG=C $cand -c 'print(1)' 2>/dev/null || true)" = "1" ]; then PYCMD="$cand"; break; fi
  done
fi

if [ -z "$PYCMD" ] && [ -f "$FINDER" ] && [ -t 0 ]; then
  echo "  The window - pick a ROM, press Start, watch the progress - runs on"
  echo "  Python 3, and this machine has no reachable one."
  bash "$FINDER" --reason
  echo
  printf '  Install Python 3 now and open the window? [y/N] '
  read -r ans
  case "$ans" in
    [yY]|[yY][eE][sS])
      bash "$FINDER" --install
      PYCMD=$(bash "$FINDER" --posix 2>/dev/null || true)
      [ -n "$PYCMD" ] || echo "  Still unreachable: close this window and open it again,"
      [ -n "$PYCMD" ] || echo "  because only a new shell sees the updated PATH."
      ;;
  esac
  echo
fi

if [ -n "$PYCMD" ]; then
  echo "  Interface: $PYCMD + your browser. Do not close this window."
  echo
  # The window shows the progress; the build itself runs in the engine.
  LANG=C "$PYCMD" "$WEBUI" "$@"
  code=$?
else
  echo "  Note: Python 3 was not found — this time without a window."
  echo "  Install Python 3 (on macOS: 'xcode-select --install' or brew install python)"
  echo "  and the next double-click gives you the graphical builder."
  echo "  Terminal mode still builds the same .nro: it asks for the dump path first."
  echo
  bash "$ENGINE" "$@" | bash "$UI"
  # Pipelines only report the right-hand side; the engine is the deciding code.
  codes=("${PIPESTATUS[@]}")
  code=${codes[0]}
  if [ "$code" = 0 ]; then code=${codes[1]}; fi
fi

echo
if [ "$code" = 0 ]; then
  echo "  DONE."
  echo "    drag-and-drop SD folder: dist/MarioKartWii-Switch/  (the switch/ folder goes at the root of your SD)"
  echo "    the .nro itself:         WiiCompiled-Switch/local-product/native-deko3d/"
  echo "  Required: test it on the Switch yourself before saying anything about FPS or gameplay."
else
  echo "  FAILED (exit code $code). Details: logs/engine-build-raw.log"
fi
echo "  The .nro contains recompiled Nintendo code: do not publish it, personal use only."
echo
[ -t 0 ] && read -r -p "Press Enter to close: " _
exit "$code"
