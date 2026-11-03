#!/usr/bin/env bash
# ensure-ui-env.sh — één plek die een bruikbare Python 3 voor de GUI vindt.
#
#   bash tools/ensure-ui-env.sh              # absolute pad op stdout, exit 0
#   bash tools/ensure-ui-env.sh --quiet      # alleen de exitcode, geen uitvoer
#   bash tools/ensure-ui-env.sh --reason     # plus een uitleg voor de mens
#   bash tools/ensure-ui-env.sh --install    # installeren (na toestemming), dan opnieuw
#
# Exit 0 = gevonden (één regel: het commando om te gebruiken).
# Exit 3 = geen bruikbare interpreter.  Exit 4 = installatie geprobeerd, stills niets.
#
# Waarom dit bestand bestaat: de dubbelklik-instappers probeerden Python via de
# PATH van cmd.exe. Op Windows wijst die naar de Store-alias
# `%LOCALAPPDATA%\Microsoft\WindowsApps\python.exe`, en die alias is geen echte
# interpreter: vanuit cmd roept hij "not recognized" of "cannot find the path",
# vanuit bash doet hij het wél. De instapper zag dat als "geen Python" en viel
# stil terug op de terminal — precies de verwarrende ervaring zonder ROM-keuze.
# Dit script lost dat op: het probeert de echte runtime op de plek waar die
# werkelijk staat, en geeft pas op als een kandidaat écht `print(1)` uitvoert.
#
# Platform-neutraal: op macOS/Linux is de PATH te vertrouwen, daar is de zoektocht
# simpel. Op Windows zijn absolute paden de norm, met backslashes, want de
# aanroeper is cmd.exe en die kan geen `/c/...`-vorm gebruiken.
set -uo pipefail

MODE=""
FORM=""
for a in "$@"; do
  case "$a" in
    --quiet|--reason|--install) MODE="${a#--}" ;;
    --posix) FORM=posix ;;
    --win) FORM=win ;;
    *) printf 'onbekende optie: %s\n' "$a" >&2; exit 2 ;;
  esac
done

say() { [ "$MODE" = quiet ] || printf '%s\n' "$1" >&2; }

UNAME=$(uname -s 2>/dev/null || echo unknown)
case "$UNAME" in
  *MINGW*|*MSYS*|*CYGWIN*) OS=windows ;;
  *Darwin*)                OS=macos ;;
  *)                       OS=linux ;;
esac

# Kandidaten, in volgorde van vertrouwen. Een pad dat werkelijk bestaat gaat vóór
# een PATH-naam, en de WindowsApps-alias gaat helemaal onderaan: die doet voor
# bash alsof hij bestaat en voor cmd alsof hij het niet is.
candidates() {
  local c p
  [ -n "${PYTHON:-}" ] && printf '%s\n' "$PYTHON"
  case "$OS" in
    windows)
      for c in "$LOCALAPPDATA/Python/pythoncore-"*"/python.exe" \
               "$LOCALAPPDATA/Programs/Python/Python"*/python.exe \
               "/c/Program Files/Python3"*/python.exe \
               "/c/Program Files (x86)/Python3"*/python.exe \
               /c/Python3*/python.exe; do
        [ -f "$c" ] && printf '%s\n' "$c"
      done
      for c in python python3; do
        p=$(command -v "$c" 2>/dev/null) || continue
        case "$p" in
          *WindowsApps*) : ;;
          *) printf '%s\n' "$p" ;;
        esac
      done
      ;;
    macos)
      for c in python3 /opt/homebrew/bin/python3 /usr/local/bin/python3 /usr/bin/python3 python; do
        p=$(command -v "$c" 2>/dev/null) && printf '%s\n' "$p"
      done
      ;;
    linux)
      for c in python3 /usr/bin/python3 python; do
        p=$(command -v "$c" 2>/dev/null) && printf '%s\n' "$p"
      done
      ;;
  esac
}

# Elke kandidaat wordt echt gedraaid: Python 3.8+ schrijft "1", anders niets.
# De timeout bestaat niet op elke mac, dus is hij optioneel.
runs() {
  local exe="$1" out
  if command -v timeout >/dev/null 2>&1; then
    out=$(timeout 10 "$exe" -c 'import sys; sys.stdout.write("1" if sys.version_info >= (3,8) else "")' 2>/dev/null)
  else
    out=$("$exe" -c 'import sys; sys.stdout.write("1" if sys.version_info >= (3,8) else "")' 2>/dev/null)
  fi
  [ "$out" = "1" ]
}

# De vorm volgt de aanroeper, niet het besturingssysteem: cmd.exe wil backslashes,
# een shell wil `/c/...`. --posix en --win stoven dat expliciet om.
as_invoke() {
  local want="$FORM"
  [ -n "$want" ] || { [ "$OS" = windows ] && want=win || want=posix; }
  if [ "$want" = win ] && command -v cygpath >/dev/null 2>&1; then
    cygpath -w "$1" 2>/dev/null || printf '%s\n' "$1"
    return
  fi
  # De Windows-glob hierboven komt uit $LOCALAPPDATA, en dat is zelf al een
  # backslash-pad. Een shell kan dat niet uitvoeren, dus eerst omzetten.
  case "$1" in
    *\\*|?:*)
      if command -v cygpath >/dev/null 2>&1; then
        cygpath -u "$1" 2>/dev/null || printf '%s\n' "$1"
        return
      fi ;;
  esac
  printf '%s\n' "$1"
}

find_python() {
  local c
  while IFS= read -r c; do
    [ -n "$c" ] || continue
    if runs "$c"; then as_invoke "$c"; return 0; fi
  done < <(candidates)
  return 1
}

# ---- installeren: alleen aangeroepen nadat de instapper Y/N heeft gevraagd ----
install_python() {
  say "Installing Python 3 (one time, about a minute)..."
  case "$OS" in
    windows)
      if command -v winget >/dev/null 2>&1; then
        for c in Python.Python.3 Python.Python.3.12; do
          say "  winget install $c"
          winget install -e --id "$c" --scope user --accept-source-agreements \
                --accept-package-agreements --silent >/dev/null 2>&1 && return 0
        done
        say "  winget did not install it."
        return 1
      fi
      if command -v choco >/dev/null 2>&1; then
        choco install python3 -y --no-progress >/dev/null 2>&1 && return 0
        say "  choco did not install it."
        return 1
      fi
      say "  No winget or choco here, so open the download page yourself:"
      say "    https://www.python.org/downloads/"
      say "  Tick 'Add python.exe to PATH' during install, then re-open the builder."
      return 1
      ;;
    macos)
      if command -v brew >/dev/null 2>&1; then
        brew install python3
        return $?
      fi
      say "  No Homebrew here. Run:  xcode-select --install"
      say "  (or install brew from https://brew.sh, then re-open the builder)"
      return 1
      ;;
    *)
      if command -v apt-get >/dev/null 2>&1; then sudo apt-get update -qq && sudo apt-get install -y python3
      elif command -v dnf >/dev/null 2>&1; then sudo dnf install -y python3
      elif command -v pacman >/dev/null 2>&1; then sudo pacman -Sy --noconfirm python
      elif command -v zypper >/dev/null 2>&1; then sudo zypper -n install python3
      else say "  No known package manager; install Python 3 by hand."; return 1; fi
      ;;
  esac
}

if [ "$MODE" = install ]; then
  install_python || { say "Could not install Python 3 automatically."; exit 4; }
  found=$(find_python) && { printf '%s\n' "$found"; exit 0; }
  say "Installed, but this window still cannot reach it. Close it and re-open the builder: a new window reloads PATH."
  exit 4
fi

found=$(find_python) || {
  [ "$MODE" = reason ] && say "No usable Python 3 found (tried the real runtimes on disk, then PATH, skipping the Microsoft Store alias)."
  exit 3
}
[ "$MODE" = reason ] && say "Using: $found"
printf '%s\n' "$found"
