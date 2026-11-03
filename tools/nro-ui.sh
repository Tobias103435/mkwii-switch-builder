#!/usr/bin/env bash
# nro-ui.sh — minimale menselijke weergave bovenop nro-engine.sh.
#
#   bash tools/nro-engine.sh | bash tools/nro-ui.sh
#
# Het is bewust een dunne laag: alle bouwisioening zit in de engine, dit bestand
# kennt alleen het NDJSON-contract. Een grafische frontend (Windows, macOS, web)
# leest dezelfde stdout van de engine en hoeft niets van de build te begrijpen.
# Vereisten: bash 3.2, sed, awk. Kleur alleen als de terminal dat aankan.
set -uo pipefail

n=0
last_pct=-1
fail_seen=0

# Eén parser per regel, dan velden uit een tabel. Een regex op de hele regel
# kan niet werken: ".*" matcht het eerste sleutelnaam-deel en geeft dan de
# verkeerde waarde (msg bevat willekeurige tekst, inclusief punten).
vals=()
parse_json() {
  vals=()
  local i=0 c name innum
  local s=$1
  local len=${#s}
  while [ "$i" -lt "$len" ]; do
    c=${s:i:1}
    if [ "$c" = '"' ]; then
      name=''
      i=$(( i + 1 ))
      while [ "$i" -lt "$len" ] && [ "${s:i:1}" != '"' ]; do
        name="$name${s:i:1}"
        i=$(( i + 1 ))
      done
      i=$(( i + 1 ))
      while [ "$i" -lt "$len" ] && [ "${s:i:1}" != ':' ]; do i=$(( i + 1 )); done
      i=$(( i + 1 ))
      innum=''
      c=${s:i:1}
      if [ "$c" = '"' ]; then
        i=$(( i + 1 ))
        while [ "$i" -lt "$len" ]; do
          c=${s:i:1}
          [ "$c" = '\' ] && { innum="$innum${s:i+1:1}"; i=$(( i + 2 )); continue; }
          [ "$c" = '"' ] && break
          innum="$innum$c"
          i=$(( i + 1 ))
        done
        i=$(( i + 1 ))
      else
        while [ "$i" -lt "$len" ] && [ "${s:i:1}" != ',' ] && [ "${s:i:1}" != '}' ]; do
          innum="$innum${s:i:1}"
          i=$(( i + 1 ))
        done
      fi
      vals+=("$name" "$innum")
    else
      i=$(( i + 1 ))
    fi
  done
}
field() { # veld uit de laatst geparseerde regel
  local i=0
  while [ "$i" -lt "${#vals[@]}" ]; do
    if [ "${vals[i]}" = "$1" ]; then printf '%s' "${vals[i + 1]}"; return 0; fi
    i=$(( i + 2 ))
  done
  return 0
}

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  B=$'\033[1m'; G=$'\033[32m'; R=$'\033[31m'; C=$'\033[36m'; Z=$'\033[0m'
else
  B=''; G=''; R=''; C=''; Z=''
fi

while IFS= read -r line; do
  [ -n "$line" ] || continue
  case "$line" in (*'{'*) ;; (*) printf '%s\n' "$line"; continue ;; esac
  parse_json "$line"
  t=$(field t)
  case "$t" in
    stage)
      st=$(field state); sg=$(field stage); msg=$(field msg); secs=$(field secs)
      case "$st" in
        start) n=$((n + 1)); printf '\n%s[%d] %s %s%s\n' "$B" "$n" "$sg" "$msg" "$Z" ;;
        ok)
          case "$secs" in (''|*[!0-9]*) secs='' ;; esac
          printf '  %s✓%s %s%s\n' "$G" "$Z" "$msg" "${secs:+ ($secs s)}" ;;
        fail)  printf '  %s✗ %s%s\n' "$R" "$msg" "$Z" ;;
      esac ;;
    progress)
      pct=$(field pct)
      ph=$(field phase)
      case "$pct" in (''|*[!0-9]*) pct='' ;; esac
      if [ -z "$pct" ] && [ -n "$ph" ]; then
        # Fase-wissel: zeg WAT er bezig is, niet alleen hoeveel er al is.
        printf '\n  %s…%s %s (%s s total)\n' "$C" "$Z" "$ph" "$(field secs)"
      elif [ -n "$pct" ] && [ "$pct" != "$last_pct" ]; then
        bars=$(( pct / 2 )); [ "$bars" -gt 50 ] && bars=50
        empty=$(( 50 - bars ))
        printf '\r  %s[%s%s%s]%s %3s%% %s' "$C" \
          "$(printf '#%.0s' $(seq 1 "$bars" 2>/dev/null))" \
          "$(printf '%*s' "$empty" '')" "$Z" "$Z" "$pct" "$(field msg)"
        last_pct=$pct
      fi ;;
    deliver)
      map=$(field map); zip=$(field zip)
      if [ -n "$map" ]; then
        printf '\n  %sSD folder%s : %s\n' "$B" "$Z" "$map"
        printf '  %scontent%s   : %s files, %s bytes\n' "$B" "$Z" "$(field files)" "$(field bytes)"
        printf '  %sdrag%s      : copy the switch/ folder from this path to the ROOT of your SD card,\n' "$B" "$Z"
        printf '             then start hbmenu and pick WiiCompiled-Switch.\n'
      fi
      [ -n "$zip" ] && printf '  %sSD zip%s    : %s (%s bytes)\n' "$B" "$Z" "$zip" "$(field bytes)" ;;
    sweep)
      freed=$(field freed); removed=$(field removed); kept=$(field kept)
      case "$freed" in (''|*[!0-9]*) freed=0 ;; esac
      if [ "$kept" = 1 ] || [ "$freed" = 0 ]; then
        printf '  %srecomp files kept%s — no cleanup, so the next rebuild starts from the cache.\n' "$C" "$Z"
      else
        printf '  %scleaned up%s    : %s GiB of temporary files removed (%s)\n' "$G" "$Z" \
          "$(awk -v b="$freed" 'BEGIN{printf "%.1f", b/1073741824}')" "$removed"
      fi ;;
    result)
      printf '\n'
      sha=$(field sha256); exp=$(field expected)
      match=$(field match)
      printf '  %s.nro%s    : %s\n' "$B" "$Z" "$(field nro)"
      printf '  %sbytes%s   : %s\n' "$B" "$Z" "$(field bytes)"
      printf '  %ssha256%s  : %s\n' "$B" "$Z" "$sha"
      printf '  %sruntime%s : %s seconds\n' "$B" "$Z" "$(field seconds)"
      case "$match" in
        true) printf '  %sverdict%s : MATCH with the expected build\n' "$G" "$Z" ;;
        *)    printf '  %sverdict%s : NEW CANDIDATE (expectation was %s) — test on the console first\n' "$R" "$Z" "$exp" ;;
      esac ;;
    error)
      fail_seen=1
      printf '\n  %sERROR [%s] %s%s\n' "$R" "$(field stage)" "$(field msg)" "$Z" ;;
  esac
done

# De engine stopt met een niet-nul afsluitcode als een stap faalde; pipefail
# bezorgt die hier, maar de menselijke tekst is al geprint.
exit "$fail_seen"
