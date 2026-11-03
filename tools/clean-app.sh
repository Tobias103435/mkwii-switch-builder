#!/usr/bin/env bash
# clean-app.sh -- removes what this builder created, on purpose and in two sizes.
#
#   bash tools/clean-app.sh --leftovers              # build trees and the extract
#   bash tools/clean-app.sh --everything --yes       # the whole folder, back to one file
#   bash tools/clean-app.sh --everything --dry-run   # only say what would go
#
# --leftovers  : more than the builder sweeps by default. The default sweep only
#                drops the extracted game data and keeps the ~2 GiB build cache,
#                because that cache is what makes the next rebuild take a minute.
#                This level gives that space back too: object trees, translated
#                shards, the extracted game data and temp logs. The .nro, the SD
#                folder, the deps cache and the toolchain stay.
# --everything : everything the app put in this folder - the tooling it unpacked,
#                the clone, the extracted data, the .nro and the SD folder, the
#                toolchain and deps it fetched - so the folder ends up holding only
#                MKWii-Builder.cmd again. That is the "undo" a shared PC wants.
#
# What it will never touch: your disc image (.rvz .wbfs .iso .gcm) and anything else
# that was already in the folder. It only removes exact names from the list below,
# only directly under this app folder, and it refuses a running build, a symlink and
# --everything without --yes.
#
# tools/ is left for the caller to remove, because this script lives inside it and
# Windows does not let a running program delete its own file. The web window and the
# .cmd both do that step after this script returns.
set -uo pipefail

WS="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LEVEL=""
ASSUME_YES=0
DRY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --leftovers) LEVEL=leftovers ;;
    --everything) LEVEL=everything ;;
    --yes) ASSUME_YES=1 ;;
    --dry-run) DRY=1 ;;
    -h|--help) sed -n '2,24p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done
[ -n "$LEVEL" ] || { echo "usage: --leftovers | --everything [--yes|--dry-run]" >&2; exit 2; }

# A build in progress owns this folder; cleaning under it would break both.
if [ -d "$WS/logs/engine.lock" ]; then
  echo "a build is running (logs/engine.lock exists) - nothing removed. Wait for it, or remove that folder only when you are sure nothing runs." >&2
  printf '{"t":"clean","level":"%s","refused":"build running"}\n' "$LEVEL"
  exit 1
fi

dirsize() {
  local n
  if n=$(du -s --block-size=1 "$1" 2>/dev/null | cut -f1); then :; else
    n=$(du -sk "$1" 2>/dev/null | cut -f1)
    [ -n "$n" ] && n=$(( n * 1024 ))
  fi
  printf '%s\n' "${n:-0}"
}

# The top-level names this app creates. Nothing else is ever a candidate.
APP_DIRS="WiiCompiled-Switch discs dist docker logs switch-ops templates tools .local .deps out .nod-cache"
APP_FILES="Bouw-NRO.cmd bouw-nro.command README-Switch-Port.md .mkw-payload-stamp"

FREED=0
REMOVED=""
note() { printf '   %s\n' "$1"; }

remove_one() {  # <path> <label>
  local p="$1"
  [ -e "$p" ] || return 0
  if [ -L "$p" ]; then note "skipped (symlink, not touched): $p"; return 0; fi
  local sz; sz=$(dirsize "$p")
  if [ "$DRY" = 1 ]; then
    note "would remove: ${p#"$WS"/}  ($(( sz / 1073741824 )) GiB)"
  else
    if [ -d "$p" ]; then rm -rf "$p"; else rm -f "$p"; fi
    if [ -e "$p" ]; then note "STILL THERE (Windows held it): ${p#"$WS"/}"; return 1; fi
    note "removed: ${p#"$WS"/}  ($(( sz / 1073741824 )) GiB)"
  fi
  FREED=$(( FREED + sz ))
  REMOVED="${REMOVED:+$REMOVED }${p#"$WS"/}"
  return 0
}

echo "== clean ($LEVEL) in $WS =="

# leftovers: the intermediates, through the sweep that already has the proof checks.
if [ "$LEVEL" = leftovers ]; then
  DEPS="${MKW_DEKO3D_DEPS_DIR:-$WS/.deps/native-deko3d}"
  [ -d "$DEPS" ] || DEPS="$HOME/mkw-toolchain/deps/native-deko3d"
  SWEEP_ARGS=""
  [ "$DRY" = 1 ] && SWEEP_ARGS="--dry-run"
  # shellcheck disable=SC2086
  bash "$WS/tools/sweep-temp.sh" --deps "$DEPS" --ws "$WS" $SWEEP_ARGS
  echo "freed: $(( FREED / 1073741824 )) GiB (see the sweep lines above)"
  printf '{"t":"clean","level":"leftovers","freed":%s,"removed":"see sweep"}\n' "$FREED"
  exit 0
fi

if [ "$ASSUME_YES" != 1 ] && [ "$DRY" != 1 ]; then
  echo "--everything removes the .nro, the SD folder, the toolchain and the tooling."
  echo "Add --yes to really do it, or --dry-run to see the list first."
  printf '{"t":"clean","level":"everything","refused":"needs --yes"}\n'
  exit 1
fi

for name in $APP_DIRS; do
  case "$name" in
    tools) continue ;;   # the caller removes tools/ after this script returns
  esac
  remove_one "$WS/$name"
done
for name in $APP_FILES; do remove_one "$WS/$name"; done

echo
if [ "$DRY" = 1 ]; then
  echo "dry run: nothing was removed. tools/ stays too (this script sits in it)."
else
  echo "done: only MKWii-Builder.cmd and your own files are left, plus tools/ - the"
  echo "window or the .cmd removes tools/ now, and the folder is as it was before."
fi
printf '{"t":"clean","level":"%s","freed":%s,"removed":"%s","remaining":"tools"}\n' "$LEVEL" "$FREED" "${REMOVED:-none}"
exit 0
