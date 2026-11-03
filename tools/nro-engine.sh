#!/usr/bin/env bash
# nro-engine.sh — the platform-neutral engine behind the one-click builder.
#
#   bash tools/nro-engine.sh              # all stages, NDJSON on stdout
#   bash tools/nro-engine.sh --plan       # only report what would happen
#   bash tools/nro-engine.sh --stage env  # one stage: env|src|inputs|build|verify|deliver|sweep
#   bash tools/nro-engine.sh --full --dump "path/to/dump.rvz" --jobs 16
#   bash tools/nro-engine.sh --no-map     # skip the drag-and-drop SD folder
#   bash tools/nro-engine.sh --native --deps "path/to/deps"   # without docker
#   bash tools/nro-engine.sh --docker     # force docker, even with a toolchain
#   bash tools/nro-engine.sh --keep-recomp  # skip the cleanup entirely
#   bash tools/nro-engine.sh --free-cache   # cleanup that also drops the 5 GiB build cache
#   bash tools/nro-engine.sh --deps-build   # compile the render stack here, never take the package
#   bash tools/nro-engine.sh --deps-package mkw-render-deko3d-….tar.xz   # a file or url to install
#
# Render stack (Dawn + libuam) without the hours: by default the engine installs the
# verified prebuilt package (tools/render-deps.sh, pinned in tools/render-deps-
# pins.env) when this host lacks the stack and a package is reachable, and only
# falls back to compiling it when no package exists.
#
# Contract, one JSON object per line on stdout (only ASCII escapes needed):
#   {"t":"stage","stage":"env","state":"start"|"ok"|"fail","msg":"…","secs":3,"total":12}
#   {"t":"progress","stage":"build","pct":62,"msg":"[527/849]","phase":"compiling and linking","total":318}
#   {"t":"result","nro":"/abs/path.nro","bytes":74432656,"sha256":"…","expected":"…","match":true,"seconds":712}
#   {"t":"deliver","map":"/abs/path/to/folder","files":2040,"bytes":2900000000}
#   {"t":"deliver","zip":"/abs/path/to/zip","bytes":…,"sha256":"…"}
#   {"t":"disk","free":"123456789","need_gib":"8","backend":"native","path":"/abs/path"}
#   {"t":"sweep","freed":"3958354944","removed":"build-switch-release discs/extract …","kept":"0","kept_cache":1,"cache_bytes":2429624320}
#   {"t":"error","stage":"inputs","msg":"…"}
# Values may appear quoted or bare (bytes/match/seconds/secs/total are bare, pct is
# quoted): a frontend has to tolerate both. `phase` is the phase the build is in
# right now (metering for the bar), `total` seconds since the start.
# The raw builder stream (builder, ninja, nod) goes to a log file, never to
# stdout: stdout stays machine-readable. Frontends show the path of that log.
# Two backends: native (devkitA64 on the host, no docker) and docker (fallback).
# Requires: bash 3.2+, git, and either devkitA64 + libnx + elf2nro on the PATH or docker.
# GNU and BSD (macOS) are both handled.
set -euo pipefail

WS="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO="$WS/WiiCompiled-Switch"
PRODUCT="$REPO/local-product/native-deko3d"
NRO="$PRODUCT/WiiCompiled-Switch-native-deko3d.nro"
ASSETS="$REPO/local-product/Assets"
IMAGE="mkw-host:1"
VOLUME="mkwdeps"
CONTAINER_DEPS="/deps/native-deko3d"          # pad binnenuit het volume

# Deps-kaart voor de native-route. De motor zoekt zelf, zodat een dubbelklik
# zonder één vlag werkt: $MKW_DEPS_DIR wint, daarna de vaste plekken waar een
# eerdere run of een setup-nehaalactie iets neerlegt. Een boom telt alleen als
# Dawn en libuam er echt staan; een lege map is geen deps. Twee vormen tellen:
# de bronboom die deze host zelf bouwde, en het pakket van tools/render-deps.sh
# (~600 MB, alleen wat de link nodig heeft).
deps_is_ready() {
  { [ -d "$1/dawn/src" ] && [ -f "$1/uam/meson.build" ]; } ||
  { [ -f "$1/.mkw-render-package" ] &&
    [ -f "$1/dawn-build-switch/src/dawn/native/libwebgpu_dawn.a" ] &&
    [ -f "$1/uam/build-switch/libuam.a" ]; }
}
HOST_DEPS="${MKW_DEPS_DIR:-}"
if [ -z "$HOST_DEPS" ]; then
  for _cand in "$WS/.deps/native-deko3d" \
               "$HOME/mkw-toolchain/deps/native-deko3d" \
               "$HOME/mkw-deps/native-deko3d" \
               /opt/mkw-deps/native-deko3d; do
    deps_is_ready "$_cand" && { HOST_DEPS="$_cand"; break; }
  done
  [ -n "$HOST_DEPS" ] || HOST_DEPS="$WS/.deps/native-deko3d"
fi
DEPS_DIR="$CONTAINER_DEPS"                  # wordt gezet zodra de backend bekend is

# Haalt deze host de renderstack als pakket? Het pakketscript kent de pins en de
# lokale map; deze motor vraagt alleen ís er iets te halen en wat het weegt, en
# beslist daarna. $RENDER_PLAN is de uitkomst: have | package | build en wordt
# ná de opties berekend (--deps-package, --deps-build).
render_package_source() {
  local line
  [ -n "$RENDER_SRC" ] && return 0
  line="$(bash "$WS/tools/render-deps.sh" --source 2>/dev/null)" || return 1
  RENDER_SRC="$(printf '%s\n' "$line" | head -n 1)"
  RENDER_BYTES="$(printf '%s\n' "$line" | tail -n 1)"
  [ -n "$RENDER_SRC" ]
}
REF_PIN="8b33d31016a8b8735fe35b4fb633c491d33774c6"
VERIFIED_SHA="a58e4bdf781ea7363cc20376d5a7ed64ae0de89bb4ace6d56749c788502fef78"

EXPECT="$VERIFIED_SHA"
JOBS="$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 8)"
FULL=0
DUMP=""
ONLY_STAGE=""
PLAN_ONLY=0
DO_ZIP=0
DO_MAP=1
DO_DEPLOY=0
ALLOW_MISMATCH=0
# Renderstack (Dawn + libuam): auto = pakket als het te bereiken is, anders hier
# bouwen; build = dwaling de urenroute; package = pakket vereist. --deps-package
# zet een eigen bron (bestand of url) neer, voor een machine zonder internet of
# voor een pakket dat via een USB-stick meekwam.
RENDER_WANT="${MKW_RENDER_DEPS:-auto}"
RENDER_SRC=""
RENDER_BYTES=0
RENDER_MIN=""
RENDER_COST=""
# Aanvinken = de herbouwbare tussenproducten laten staan (objecten, shards,
# extract). De UI toont dat vinkje als "keep everything"; niet aanvinken
# houdt in dat de motor opruimt — maar standaard blijft die wél de dure kant
# liggen. Meting (2026-11-02, deze host): een koude build-stap kost 867 s terwijl
# ccache 682 van de 682 cachebare aanroepen raakte — de tijd zit dus in de 104
# grootste gast-shards, en precies die blijven nu staan. Daarmee is een volgende
# rebuild 67 s in plaats van 15 min. `--free-cache` (omgeving MKW_FREE_CACHE=1)
# ruimt ook díe op (5,1 GiB), voor een schijf die het echt te vol heeft.
# MKW_KEEP_RECOMP=1 is de UI-vlag: dan blijft er níets over op te ruimen.
KEEP_RECOMP="${MKW_KEEP_RECOMP:-0}"
FREE_CACHE="${MKW_FREE_CACHE:-0}"
BACKEND="${MKW_BACKEND:-auto}"              # auto | native | docker

# Windows-leer: MSYS_NO_PATHCONV wordt alleen vóór de `docker run` gezet. Gezet
# in de omgeving (zoals de webui dat vroeger deed) maakt het elke host-aanroep
# kapot: git krijgt dan een letterlijk `/c/Users/…`-argument en zegt "not a
# repository", dus elke host-stap faalt.
unset MSYS_NO_PATHCONV 2>/dev/null || true
CUR=""
CUR_T0=$(date +%s)
T0=$CUR_T0

j() { # j t k v [k v …]  -> één JSON-regel; strings worden ge-escapet
  printf '{"t":"%s"' "$1"
  shift
  while [ $# -gt 1 ]; do
    v=$(printf '%s' "$2" | tr -d '\r' | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')
    printf ',"%s":"%s"' "$1" "$v"
    shift 2
  done
  printf '}\n'
}
# stage <naam> <state> [msg]  — met de duur van deze stap en de totale verstreken tijd.
stage() {
  now=$(date +%s)
  [ "$2" = start ] && CUR_T0=$now
  printf '%s\n' "$(j stage stage "$1" state "$2" msg "${3:-}" \
    secs "$(( now - CUR_T0 ))" total "$(( now - T0 ))")"
}
fail() {
  printf '%s\n' "$(j error stage "$CUR" msg "$1")"
  exit 1
}

while [ $# -gt 0 ]; do
  case "$1" in
    --plan) PLAN_ONLY=1 ;;
    --stage) ONLY_STAGE="${2:?--stage needs a stage name}"; shift ;;
    --full) FULL=1 ;;
    --dump) DUMP="${2:?--dump needs a path}"; shift ;;
    --jobs) JOBS="${2:?--jobs needs a number}"; shift ;;
    --expect) EXPECT="${2:?--expect needs a sha or 'none'}"; shift ;;
    --zip) DO_ZIP=1 ;;
    --no-map) DO_MAP=0 ;;
    --deploy) DO_DEPLOY=1 ;;
    --allow-revision-mismatch) ALLOW_MISMATCH=1 ;;
    --keep-recomp) KEEP_RECOMP=1 ;;
    --free-cache) FREE_CACHE=1 ;;
    --docker) BACKEND=docker ;;
    --native) BACKEND=native ;;
    --deps) HOST_DEPS="${2:?--deps needs a folder}"; shift ;;
    --deps-package) RENDER_SRC="${2:?--deps-package needs a file or url}"; RENDER_WANT=package; shift ;;
    --deps-build) RENDER_WANT=build ;;
    -h|--help) awk 'NR==1{next} /^#/{sub(/^# ?/,"");print;next} {exit}' "${BASH_SOURCE[0]}" >&2; exit 0 ;;
    *) printf '%s\n' "$(j error stage args msg "unknown option: $1")" >&2; exit 1 ;;
  esac
  shift
done

want() { [ -z "$ONLY_STAGE" ] || [ "$ONLY_STAGE" = "$1" ]; }
if [ -n "$ONLY_STAGE" ]; then
  case "$ONLY_STAGE" in
    env|src|inputs|build|verify|deliver|sweep) ;;
    *) printf '%s\n' "$(j error stage args msg "--stage must be one of env|src|inputs|build|verify|deliver|sweep")" >&2; exit 1 ;;
  esac
fi

# Duurt de renderstack hier uren of minuten? Die vraag wordt vóór het werk
# beantwoord, omdat zowel de setup (renderstack-gereedschap ja/nee), de
# schijfruimte als de bouw zelf ervan afhangen.
if [ -n "$RENDER_SRC" ] && [ "$RENDER_BYTES" = 0 ]; then
  # Een explicit meegegeven pakket (USB-stick, eigen pad) is niet via --source
  # gewogen. Het getal op de lijn en de schijfpoort hangen eraf, en een bestand
  # dat niet bestaat is pas een fout als de motor het gaat halen.
  case "$RENDER_SRC" in
    http://* | https://*) ;;
    *) if [ ! -f "$RENDER_SRC" ]; then
         printf '%s\n' "$(j error stage env msg "--deps-package points at a file that is not there: $RENDER_SRC")" >&2
         exit 1
       fi
       RENDER_BYTES="$(wc -c < "$RENDER_SRC" | tr -d ' ')" ;;
  esac
fi
RENDER_PLAN=have
if [ "$RENDER_WANT" != build ] && ! deps_is_ready "$HOST_DEPS" && render_package_source; then
  RENDER_PLAN=package
fi
if [ "$RENDER_WANT" = package ] && [ "$RENDER_PLAN" = build ]; then
  printf '%s\n' "$(j error stage env msg "no render-stack package is reachable: set MKW_RENDER_DEPS_URL in tools/render-deps-pins.env, put the file in dist/render-deps/, or drop --deps-package")" >&2
  exit 1
fi
if [ "$RENDER_WANT" = build ]; then RENDER_PLAN=build; fi
case "$RENDER_PLAN" in
  package)
    # Een URL-pakket weegt hier nog niets: dan blijft de eerlijke maat onbekend
    # en de zin zegt "fetched once" in plaats van een verzonden "0 MB".
    if [ "$RENDER_BYTES" -gt 0 ]; then
      RENDER_MIN=$(( (RENDER_BYTES + 500000) / 1000000 ))
      RENDER_COST="${RENDER_MIN} MB downloaded once"
    else
      RENDER_COST="fetched once"
    fi ;;
  build) RENDER_MIN=0 ;;
esac

# Bestandsgrootte, GNU en BSD.
filesize() {
  if stat -c%s "$1" 2>/dev/null; then return 0; fi
  stat -f%z "$1" 2>/dev/null || echo 0
}

# Byte-som van een boom in ÉÉN du-oproep. Hier stond een lus die per bestand stat
# liet draaien: gemeten 74 s voor 2040 bestanden op deze pc (elke stat is een eigen
# proces), terwijl du hetzelfde in 0,15 s doet — en met --apparent-size exact dezelf-
# de uitkomst geeft. Dat was het hele deliver-stap: 67 van de 126 s van een bouw.
tree_bytes() {
  local n
  n=$(du -s --apparent-size --block-size=1 "$1" 2>/dev/null | cut -f1 | tr -d '[:space:]')
  if ! printf '%s' "$n" | grep -qE '^[0-9]+$'; then
    # BSD/macOS kennen geen --block-size: -A is schijnbare grootte, -k in KiB.
    n=$(du -sAk "$1" 2>/dev/null | cut -f1 | tr -d '[:space:]')
    if printf '%s' "$n" | grep -qE '^[0-9]+$'; then n=$(( n * 1024 )); else n=0; fi
  fi
  printf '%s\n' "$n"
}

# sha256, GNU coreutils en BSD/macOS shasum.
hashfile() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

# Dezelfde som, maar dan van wat via stdin binnenkomt.
hashstdin() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{print $1}'
  else
    shasum -a 256 | awk '{print $1}'
  fi
}

# Eén veld uit een klein JSON-bestand, zonder jq (dat is op geen enkele host
# gegarandeerd). Alleen de "veld":"waarde"-vorm hieronder komt hier voor.
json_get() {
  [ -f "$1" ] || return 0
  sed -n "s/.*\"$2\":\"\\([^\"]*\\)\".*/\\1/p" "$1" | head -1
}

# ---- of deze bouw wel nieuw werk is ------------------------------------------
# Twee keer op Start zonder dat er iets verandert, hoeft niet twee keer hetzelfde
# werk te doen. Erger nog: een herbouw is nooit bit-identiek (de link-layout
# verschuift), dus een tweede klik zou het bewezen goede bestand vervangen door een
# ongetest kandidaat. Deze vingerafdrek dekt alles wat de uitkomst bepaalt: de
# bronnet en wat erop is gepatcht, de game-data, de vertaalde shards, het
# gereedschap en of er opnieuw vertaald moet worden. Verandert er iets, dan verandert
# de som en wordt er gewoon weer gebouwd.
#
# Twee grenzen, allebei bewust. Alleen de native-route doet mee: in docker wijst
# $DEPS_DIR naar een pad binnenuit het volume, en daarvan zijn de shards hier niet
# te tellen. En de voorwerp-boom van de compiler (build-switch-release) staat er
# níet in - die verandert bij elke bouw, dus die zou het overslaan onmogelijk
# maken. Wie dawn of uam met de hand vervangt, is toe aan --full.
BUILD_RECORD="$WS/logs/last-build.json"
REUSE_SHA=""
FP_AFTER=""

build_fingerprint() {
  local shards="${MKW_DEKO3D_WORK_DIR:-$DEPS_DIR/driftdroid}/generated/build_shards"
  {
    printf 'backend %s\n' "$BACKEND"
    printf 'full %s\n' "$FULL"
    printf 'repo %s\n' "$(git -C "$REPO" rev-parse HEAD 2>/dev/null || echo none)"
    printf 'patched %s\n' "$(git -C "$REPO" diff HEAD 2>/dev/null | hashstdin)"
    printf 'extra %s\n' "$(git -C "$REPO" status --porcelain 2>/dev/null | hashstdin)"
    printf 'driftdroid %s\n' "$(git -C "$REPO/third_party/DriftDroid" rev-parse HEAD 2>/dev/null || echo none)"
    printf 'dawn %s\n' "$(git -C "$DEPS_DIR/dawn" rev-parse HEAD 2>/dev/null || echo none)"
    printf 'uam %s\n' "$(git -C "$DEPS_DIR/uam" rev-parse HEAD 2>/dev/null || echo none)"
    printf 'dol %s\n' "$(hashfile "$ASSETS/main.dol")"
    printf 'rel %s\n' "$(hashfile "$ASSETS/StaticR.rel")"
    printf 'shards %s\n' "$(tree_bytes "$shards")"
    printf 'tooling %s\n' "$(cat "$WS/tools/build-in-container.sh" 2>/dev/null | hashstdin)"
  } | hashstdin
}

# true als de .nro op disk nog precies het bestand van de laatste bouw is en er
# sindsdien niets aan die invoer veranderd is; dan komt zijn sha in $REUSE_SHA.
reuse_is_current() {
  [ -f "$NRO" ] && [ -f "$BUILD_RECORD" ] || return 1
  local fp sha
  fp="$(build_fingerprint)"
  sha="$(json_get "$BUILD_RECORD" sha256)"
  [ "$(json_get "$BUILD_RECORD" fingerprint)" = "$fp" ] || return 1
  [ -n "$sha" ] && [ "$sha" = "$(hashfile "$NRO")" ] || return 1
  REUSE_SHA="$sha"
  FP_AFTER="$fp"
}

# Vrije bytes op de schijf van een pad. `df -P` (Portable) op GNU én BSD/macOS;
# de -k maakt het een vast formaat van 1K-blokken, dus vermenigvuldigen met 1024.
free_bytes() {
  local n
  n=$(df -Pk "${1:-$WS}" 2>/dev/null | awk 'NR==2{print $4}')
  case "$n" in (''|*[!0-9]*) n=$(df -k "${1:-$WS}" 2>/dev/null | awk 'END{print $(NF-1)}') ;; esac
  case "$n" in (''|*[!0-9]*) n=0 ;; esac
  printf '%s\n' "$(( n * 1024 ))"
}

# Docker heeft op Windows een andere schrijfwijze voor bind-mounts nodig.
host_mount() {
  case "$(uname -s 2>/dev/null || echo unknown)" in
    MINGW*|MSYS*|CYGWIN*) cygpath -aw "$1" | tr '\\' '/' ;;
    *) printf '%s\n' "$1" ;;
  esac
}

# Laatste [x/y] voortgangsteller in de rauwe log, als percentage. Alleen cijfers
# uit een vaste grep, nooit uit geëvalueerde bouwer-tekst.
pct_in_log() {
  last=$(grep -o '\[[0-9][0-9]*/[0-9][0-9]*\]' "$1" 2>/dev/null | tail -n 1 || true)
  [ -n "$last" ] || return 0
  a=${last#[}; a=${a%%/*}
  b=${last#*/}; b=${b%%]*}
  [ "$b" -gt 0 ] || return 0
  printf '%s %s\n' "$(( 100 * a / b ))" "$last"
}

# Laste ">> BEGIN <fase> (totaal N s)" marker van build-in-container.sh, als
# "fase|seconden". Vertelt een frontend WAT er nu bezig is, niet alleen hoeveel.
phase_in_log() {
  line=$(grep '^>> BEGIN ' "$1" 2>/dev/null | tail -n 1 || true)
  [ -n "$line" ] || return 0
  line=${line#>> BEGIN }
  name=${line%% (*}
  secs=$(printf '%s' "${line#*(}" | tr -dc '0-9')
  case "$secs" in (''|*[!0-9]*) secs=0 ;; esac
  printf '%s|%s\n' "$name" "$secs"
}

mkdir -p "$WS/logs"

# Backendkeuze vóór de stappen: native heeft voorrang, docker is de valback voor
# wie geen devkitA64 geïnstalleerd heeft. --stage build moet hetzelfde deps-pad
# zien als --stage env, dus deze keuze staat buiten de stappen.
. "$WS/tools/native-env.sh"
NATIVE_OK=0
native_probe && NATIVE_OK=1
# Klik-en-klaar: een verse pc heeft géén toolchain, en de gebruiker hoort geen
# commando te hoeven kiezen. Haal het gereedschap dan zelf op — één keer, in de
# gereedschapsmap van de app, zonder installator en zonder administrator. Daarna
# wordt opnieuw geprobeerd en bouwt de motor native. MKW_AUTOPROVISION=0 zet dit
# uit (CI, of wie bewust voor de docker-valback kiest); --plan provisioneert nooit.
if [ "$NATIVE_OK" != 1 ] && [ "$BACKEND" = auto ] && [ "$PLAN_ONLY" != 1 ] \
   && [ "${MKW_AUTOPROVISION:-1}" != 0 ]; then
  CUR=provision
  # Eerder werd alleen de toolchain opgehaald en bleef de eenmalige renderstack
  # dan uren later falen op één ontbrekend commando. Die gereedschappen wegen
  # niets (~40 MB) tegenover die teleurstelling, dus ze gaan mee zodra deze
  # host de stack zélf moet bouwen. Is er een pakket te halen, dan blijven ze
  # achter: meson/bison/flex zijn alleen voor het compileren van Dawn nodig.
  SETUP_ARGS=(--install)
  RENDER_NOTE=""
  if [ "$RENDER_PLAN" = build ]; then
    SETUP_ARGS=(--install --render)
    RENDER_NOTE=" + the render-stack tools (meson, bison, flex, Mako)"
  fi
  stage provision start "one-off setup: fetching the toolchain (devkitA64 + cmake/ninja/.NET, a few GB)$RENDER_NOTE"
  if bash "$WS/tools/setup-native.sh" "${SETUP_ARGS[@]}" >>"$WS/logs/setup-native.log" 2>&1; then
    native_probe && NATIVE_OK=1
    stage provision ok "toolchain installed in ${DEVKITPRO:-$HOME/mkw-toolchain}"
  else
    stage provision fail "download failed — details: logs/setup-native.log"
  fi
fi
if [ "$BACKEND" = auto ]; then
  if [ "$NATIVE_OK" = 1 ]; then BACKEND=native; else BACKEND=docker; fi
fi
if [ "$BACKEND" = native ]; then
  DEPS_DIR="$HOST_DEPS"
else
  DEPS_DIR="$CONTAINER_DEPS"
fi

# Slot tegen dubbel starten: twee gelijktijdige builings delen hetzelfde volume,
# dezelfde WORK_DIR en hetzelfde productpad, en schrijven dan over elkaar heen.
# --plan is read-only en krijgt de slot dus niet.
LOCKDIR="$WS/logs/engine.lock"
if [ "$PLAN_ONLY" != 1 ]; then
  CUR=lock
  if ! mkdir "$LOCKDIR" 2>/dev/null; then
    age=$(( $(date +%s) - $(stat -c%Y "$LOCKDIR" 2>/dev/null || stat -f%Y "$LOCKDIR" 2>/dev/null || echo 0) ))
    if [ "$age" -gt 21600 ]; then
      rm -rf "$LOCKDIR"
      mkdir "$LOCKDIR" 2>/dev/null || fail "cannot create the build lock"
    else
      fail "a build is already running (lock $LOCKDIR, $age s old, pid $(cat "$LOCKDIR/pid" 2>/dev/null || echo '?')). Wait for it to finish."
    fi
  fi
  printf '%s\n' "$$" > "$LOCKDIR/pid"
  trap 'rm -rf "$LOCKDIR"' EXIT
fi

# ---- env --------------------------------------------------------------------
CUR=env
if want env; then
  if [ "$BACKEND" = native ]; then
    stage env start "checking the native toolchain on this host"
    [ "$NATIVE_OK" = 1 ] || fail "cannot build natively yet: $NATIVE_MISS"
    stage env ok "devkitA64 native: $DEVKITPRO"
    # Een lege deps-map is geen fout, maar wél een mededeling vóór het werk: die
    # eenmalige stack kost uren. Zonder deze regel liep de motor door naar de
    # bouw en brak hij daar af op één ontbrekend commando. deps_is_ready is
    # dezelfde toets als de ruimtepoort hieronder, dus de twee spreken niet tegen.
    if deps_is_ready "$DEPS_DIR"; then
      if [ -f "$DEPS_DIR/.mkw-render-package" ]; then
        stage env ok "render stack present: $DEPS_DIR (prebuilt package)"
      else
        stage env ok "render stack present: $DEPS_DIR"
      fi
    elif [ "$PLAN_ONLY" = 1 ]; then
      if [ "$RENDER_PLAN" = package ]; then
        stage env ok "plan: the render stack (Dawn + libuam) comes as a verified package — ${RENDER_COST:-fetched once}, a few minutes"
      else
        stage env ok "plan: this host still has to build the render stack (Dawn + libuam) in $DEPS_DIR — hours, one-off; after that a build is minutes"
      fi
    elif [ "$RENDER_PLAN" = package ]; then
      # Het pakket is geen verrassing meer: 600 MB aan voorgebouwde Dawn en
      # libuam, sha256-gecheckt tegen de pin in de gereedschapsmap en daarna per
      # bestand nagerekend, waarna de bouw van minuutwerk uitgaat.
      mkdir -p "$DEPS_DIR"
      stage env start "render stack: fetching the prebuilt package (${RENDER_COST:-fetched once}, one-off)"
      if MKW_DEKO3D_DEPS_DIR="$DEPS_DIR" bash "$WS/tools/render-deps.sh" --install "$RENDER_SRC" \
           >>"$WS/logs/render-deps.log" 2>&1; then
        stage env ok "render stack installed from the package: $DEPS_DIR (minutes, not hours)"
      else
        fail "the render-stack package did not install — details: logs/render-deps.log"
      fi
    elif native_render_probe; then
      mkdir -p "$DEPS_DIR"
      stage env ok "render stack missing: meson/bison/flex are present, so the build step compiles Dawn + libuam now — hours, one-off"
    else
      fail "the render stack (Dawn + libuam) is not built here yet and its tools are missing:$RENDER_MISS — fetch them with: bash tools/setup-native.sh --install --render"
    fi
  else
    stage env start "checking docker, image and volume"
    command -v docker >/dev/null 2>&1 || fail "no docker here, and no devkitA64 toolchain either. A real run fetches that toolchain by itself (into .local/mkw-toolchain, a few GB, one time); installing Docker is only the alternative."
    docker info >/dev/null 2>&1 || fail "the docker daemon is not running (start Docker)"
    if docker image inspect "$IMAGE" >/dev/null 2>&1; then
      stage env ok "image $IMAGE present"
    elif [ "$PLAN_ONLY" = 1 ]; then
      stage env ok "plan: build image $IMAGE (one-off, ~10 min)"
    else
      docker build -q -t "$IMAGE" -f "$WS/docker/mkw-host.Dockerfile" "$WS/docker" >/dev/null
      stage env ok "image $IMAGE built"
    fi
    if docker volume inspect "$VOLUME" >/dev/null 2>&1; then
      stage env ok "volume $VOLUME present"
    elif [ "$PLAN_ONLY" = 1 ]; then
      # Een plan schept niets: "created" zou hier logen, want er is niets gemaakt.
      stage env ok "plan: create volume $VOLUME"
    else
      docker volume create "$VOLUME" >/dev/null
      stage env ok "volume $VOLUME created"
    fi
  fi
  # Ruimte-poort vóór het werk: een bouw die halverwege op een volle schijf loopt,
  # kost de gebruiker een uur en laat een halve boom achter. De getallen zijn gemeten
  # op een volledige native bouw (2026-11-02): 2,5 GiB uitgepakte game-data + 1,8 GiB
  # objecten en link + 0,4 GiB shards + 2,6 GiB sleepbare SD-map, afgerond naar 8.
  # De eenmalige renderstack telt alleen mee als hij nog niet staat: 6 GiB als
  # deze hem zelf bouwt (Dawn-bom + build-tree), 2 GiB als het pakket hem komt
  # halen — de piek is download + uitpak-map + geplaatste boom, dus 600 MB die
  # twee keer langs komt. Het gereedschap (0,7 GiB) is verwaarloosbaar achter
  # deze afronding.
  need_gib=8
  if [ "$BACKEND" != docker ] && ! deps_is_ready "$DEPS_DIR"; then
    if [ "$RENDER_PLAN" = package ]; then
      need_gib=$(( need_gib + 2 ))
    else
      need_gib=$(( need_gib + 6 ))
    fi
  fi
  free=$(free_bytes "$WS")
  printf '%s\n' "$(j disk free "$free" need_gib "$need_gib" backend "$BACKEND" path "$WS")"
  if [ "$PLAN_ONLY" != 1 ] && [ "$free" -lt $(( need_gib * 1073741824 )) ]; then
    fail "not enough free space: $(( free / 1073741824 )) GiB on $WS — this build wants at least $need_gib GiB (free up space or put the workspace on a larger disk)"
  fi
  stage env ok "space: $(( free / 1073741824 )) GiB free, at least $need_gib GiB needed"
fi

# ---- src --------------------------------------------------------------------
CUR=src
if want src; then
  stage src start "source and ref pins"
  if [ ! -d "$REPO/.git" ] && [ "$PLAN_ONLY" = 1 ]; then
    # In een lege map is nog niets te controleren: zeg dat eerlijk in plaats van
    # "repo cloned" te claimen en dan op een pin te falen die nog niet bestaat.
    stage src ok "source not fetched here yet: a real run clones $REPO and checks the pins"
  else
    if [ ! -d "$REPO/.git" ]; then
      git clone --config core.autocrlf=input https://github.com/yashin-sh/WiiCompiled-Switch "$REPO"
      stage src ok "repo cloned"
    fi
    if git -C "$REPO" submodule status --recursive 2>/dev/null | grep -q '^-[0-9a-f]'; then
      [ "$PLAN_ONLY" = 1 ] || git -C "$REPO" submodule update --init --recursive
      stage src ok "submodules fetched"
    fi
    # Een submodule die half is aangekomen - de schijf liep vol tijdens de eerste
    # run, of de map werd tussen schijven verplaatst en de diepe Dawn-paden en
    # `.git/modules` zijn niet volledig meegeraakt - leest niet "niets" maar het
    # hoofd van de bovenliggende repo, want een map zonder `.git` zoekt erboven
    # verder. Dus: één keer zelf proberen te herstellen vóór er iets geëist wordt.
    # `submodule update --init` zet precies de gepinde commit weer neer.
    ref_head="$(git -C "$REPO/third_party/DriftDroid" rev-parse HEAD 2>/dev/null || echo empty)"
    if [ "$ref_head" != "$REF_PIN" ] && [ "$PLAN_ONLY" != 1 ]; then
      stage src start "the DriftDroid reference reads $ref_head - fetching the submodules again"
      git -C "$REPO" submodule update --init --recursive >>"$WS/logs/src-submodule.log" 2>&1 || :
      ref_head="$(git -C "$REPO/third_party/DriftDroid" rev-parse HEAD 2>/dev/null || echo empty)"
    fi
    if [ "$ref_head" = "$REF_PIN" ]; then
      stage src ok "repo at $(git -C "$REPO" rev-parse --short HEAD), DriftDroid ref = pin"
    elif [ "$PLAN_ONLY" = 1 ]; then
      # In plan-modus is een bron die hier nog niet ligt geen fout: er is niets te
      # repareren zolang er niets gedraaid wordt, en een echte run haalt en checkt hem.
      stage src ok "plan: this clone has no DriftDroid reference yet — a real run fetches and checks it"
    else
      fail "the WiiCompiled-Switch clone in this folder is incomplete: its DriftDroid reference reads '$ref_head' instead of the pinned $REF_PIN. That happens when a disk filled up mid-clone or when the folder was moved between drives. Repair: git -C WiiCompiled-Switch submodule update --init --recursive   (needs network and room; details go to logs/src-submodule.log) — or delete the WiiCompiled-Switch folder and run this again: it is cloned fresh, and nothing else in this folder is touched."
    fi
    # Een pakket levert de renderstack als bytes in plaats van als bronboom, en
    # de ontvangst-poort van de productbouw accepteert die vorm alleen met een
    # extra tak. Upstream heeft die tak niet en wij kunnen daar niet pushen, dus
    # ligt hij als patch bij het gereedschap en wordt hij hier op de clone gelegd
    # — hetzelfde patroon als de link-fixes in tools/patches/.
    if [ "$BACKEND" = native ] && [ "$PLAN_ONLY" != 1 ] &&
       { [ "$RENDER_PLAN" = package ] || [ -f "$DEPS_DIR/.mkw-render-package" ]; } &&
       ! grep -q "RENDER_PACKAGE" "$REPO/scripts/build-local-native-deko3d.sh" 2>/dev/null; then
      if git -C "$REPO" apply --check "$WS/tools/patches/render-deko3d-package.diff" 2>/dev/null &&
         git -C "$REPO" apply "$WS/tools/patches/render-deko3d-package.diff" 2>/dev/null; then
        stage src ok "render-stack package support patched into the clone"
      else
        fail "upstream changed scripts/build-local-native-deko3d.sh, so the render-stack package no longer fits this clone. Build the stack here instead: --deps-build (needs meson, bison, flex: bash tools/setup-native.sh --install --render)"
      fi
    fi
  fi
fi

# ---- inputs -----------------------------------------------------------------
CUR=inputs
if want inputs; then
  stage inputs start "dump and game inputs"
  if [ -f "$ASSETS/main.dol" ] && [ -f "$ASSETS/StaticR.rel" ] && [ "$FULL" != 1 ]; then
    stage inputs ok "main.dol + StaticR.rel are in place"
  else
    if [ -z "$DUMP" ]; then
      # Sorteer op grootte zonder GNU-only find -printf: BSD-find heeft het niet.
      best=0
      while IFS= read -r cand; do
        [ -n "$cand" ] || continue
        sz=$(filesize "$cand")
        if [ "$sz" -gt "$best" ]; then best=$sz; DUMP="$cand"; fi
      done <<EOF2
$(find "$WS" -maxdepth 2 -type f \( -iname '*.rvz' -o -iname '*.wbfs' -o -iname '*.iso' -o -iname '*.gcm' \) 2>/dev/null)
EOF2
    fi
    [ -n "$DUMP" ] && [ -f "$DUMP" ] || fail "no dump found; pass --dump"
    stage inputs ok "dump: $DUMP ($(filesize "$DUMP") bytes)"
    if [ "$PLAN_ONLY" = 1 ]; then
      stage inputs ok "plan: extract with nod and check the SHA pins"
    else
      preplan="$WS/logs/prepare-rmcp01-latest.log"
      bash "$WS/tools/prepare-rmcp01.sh" "$DUMP" >"$preplan" 2>&1 || fail "extraction failed (see $preplan)"
      if grep -q '^MATCH' "$preplan"; then
        stage inputs ok "MATCH: dump == the pinned PAL revision"
      elif [ "$ALLOW_MISMATCH" = 1 ]; then
        stage inputs ok "different revision, accepted on request (--allow-revision-mismatch)"
      else
        fail "dump revision differs from the manifest pins; new address attribution needed (see $preplan)"
      fi
    fi
  fi
fi

# ---- build ------------------------------------------------------------------
CUR=build
if want build; then
  if [ "$PLAN_ONLY" = 1 ]; then
    stage build ok "plan: $BACKEND build mkw-full=$FULL jobs=$JOBS deps=$DEPS_DIR"
  elif [ "$BACKEND" = native ] && [ "$FULL" != 1 ] && reuse_is_current; then
    stage build ok "nothing changed since this .nro was built - reusing ${REUSE_SHA:0:12}... (tick retranslate, or --full, for a new one)"
  else
    raw="$WS/logs/engine-build-raw.log"
    : > "$raw"
    if [ "$BACKEND" = native ]; then
      [ "$NATIVE_OK" = 1 ] || fail "cannot build natively yet: $NATIVE_MISS"
      stage build start "translating and compiling on this host, no docker (detail log: $raw)"
      MKW_DEKO3D_DEPS_DIR="$DEPS_DIR" MKW_JOBS="$JOBS" MKW_FULL="$FULL" \
        bash "$WS/tools/build-in-container.sh" >"$raw" 2>&1 &
    else
      stage build start "translating and compiling in the container (detail log: $raw)"
      MSYS_NO_PATHCONV=1 docker run --rm \
        -v "$(host_mount "$WS"):/work:rw" -v "$VOLUME:/deps" \
        -w /work/WiiCompiled-Switch \
        -e MKW_DEKO3D_DEPS_DIR="$DEPS_DIR" -e MKW_JOBS="$JOBS" -e MKW_FULL="$FULL" \
        "$IMAGE" bash /work/tools/build-in-container.sh >"$raw" 2>&1 &
    fi
    dpid=$!
    seen=""
    seen_phase=""
    while kill -0 "$dpid" 2>/dev/null; do
      sleep 2
      phase=$(phase_in_log "$raw" || true)
      if [ -n "$phase" ] && [ "$phase" != "$seen_phase" ]; then
        seen_phase="$phase"
        printf '%s\n' "$(j progress stage build phase "${phase%%|*}" secs "${phase##*|}" msg "phase: ${phase%%|*}")"
      fi
      reading=$(pct_in_log "$raw" || true)
      if [ -n "$reading" ] && [ "$reading" != "$seen" ]; then
        seen="$reading"
        set -- $reading
        printf '%s\n' "$(j progress stage build pct "$1" msg "$2" phase "${seen_phase%%|*}")"
      fi
    done
    status=0
    wait "$dpid" || status=$?
    reading=$(pct_in_log "$raw" || true)
    if [ -n "$reading" ] && [ "$reading" != "$seen" ]; then
      set -- $reading
      printf '%s\n' "$(j progress stage build pct "$1" msg "$2" phase "${seen_phase%%|*}")"
    fi
    # Per-fase tijden uit de bouwer vastleggen: dat is de onderbouw voor elke
    # uitspraak over hoe snel een bouw is (en waar de minuten zitten).
    grep '^>> EIND \|^>> TOTAAL ' "$raw" > "$WS/logs/engine-phase-times.txt" 2>/dev/null || true
    [ "$status" = 0 ] || {
      tail=$(tr -d '\r' < "$raw" | tail -n 12 | tr '\n' ' | ' | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')
      fail "build failed via the $BACKEND route (exit code $status). Last lines: $tail"
    }
    stage build ok "build complete"
    # De vingerafdrek pas NÁ de bouw opnemen: de shards en de werkbom zijn nu
    # precies zoals ze waren toen deze .nro ontstond. Dat is de vergelijking
    # waarmee de volgende klik overslaat. Docker doet hier niet aan mee.
    if [ "$BACKEND" = native ]; then
      FP_AFTER="$(build_fingerprint)"
    fi
  fi
fi

# ---- verify -----------------------------------------------------------------
CUR=verify
if want verify; then
  if [ "$PLAN_ONLY" = 1 ]; then
    stage verify ok "plan: compare sha256 of $NRO with $EXPECT"
  else
    [ -f "$NRO" ] || fail "no .nro produced: $NRO"
    nro_sha="$(hashfile "$NRO")"
    recorded="$(awk '{print $1}' "$NRO.sha256" 2>/dev/null || true)"
    { [ -z "$recorded" ] || [ "$recorded" = "$nro_sha" ]; } || fail ".nro differs from its own record"
    match=false
    if [ "$EXPECT" = "none" ] || [ "$EXPECT" = "$nro_sha" ]; then match=true; fi
    printf '{"t":"result","nro":"%s","bytes":%s,"sha256":"%s","expected":"%s","match":%s,"seconds":%s}\n' \
      "$NRO" "$(filesize "$NRO")" "$nro_sha" "$EXPECT" "$match" "$(( $(date +%s) - T0 ))"
    # Nu er een .nro staat die deze vingerafdrek heeft opgeleverd, mag die paar
    # seconden worden onthouden: de volgende klik zonder wijzigingen bouwt niet
    # opnieuw, hij leest alleen weer wat er al stond.
    if [ -n "$FP_AFTER" ]; then
      printf '{"fingerprint":"%s","sha256":"%s","nro":"%s","backend":"%s","at":"%s"}\n' \
        "$FP_AFTER" "$nro_sha" "$NRO" "$BACKEND" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$BUILD_RECORD"
    fi
    stage verify ok "verification complete"
  fi
fi

# ---- deliver ----------------------------------------------------------------
CUR=deliver
if want deliver; then
  if [ "$PLAN_ONLY" = 1 ]; then
    plan="plan:"
    if [ "$DO_MAP" = 1 ]; then plan="$plan drag-and-drop SD folder in dist/MarioKartWii-Switch"; fi
    if [ "$DO_ZIP" = 1 ]; then plan="$plan + SD zip"; fi
    if [ "$DO_DEPLOY" = 1 ]; then plan="$plan + push to the console"; fi
    stage deliver ok "$plan"
    exit 0
  fi
  MAP_OUT="$WS/dist/MarioKartWii-Switch"
  [ -f "$NRO" ] || fail "no .nro to deliver: $NRO"
  if [ ! -d "$WS/discs/extract/files" ]; then
    # De napruimactie haalt de extractie weg; de sleepbare map uit een eerdere run
    # houd je game-data al. Die data mag alleen hergebruikt worden als deze bouw
    # voor de gepinde revisie is (anders hoort er andere data bij).
    if [ "$DO_MAP" = 1 ] && [ -d "$MAP_OUT/switch/WiiCompiled/DATA/files" ] && [ "$ALLOW_MISMATCH" != 1 ]; then
      stage deliver start "refreshing the .nro in the drag-and-drop SD folder ($MAP_OUT)"
      cp -f "$NRO" "$MAP_OUT/switch/WiiCompiled-Switch/$(basename "$NRO")" \
        || fail "cannot copy the .nro into $MAP_OUT"
      files="$(find "$MAP_OUT" -type f | wc -l | tr -d ' ')"
      bytes="$(tree_bytes "$MAP_OUT")"
      printf '%s\n' "$(j deliver map "$MAP_OUT" files "$files" bytes "$bytes")"
      stage deliver ok "SD folder updated with this .nro; the game data is reused from the previous run ($files files, $bytes bytes)"
    else
      stage deliver ok "drag-and-drop folder skipped: no extracted game data in discs/extract"
    fi
  else
    if [ "$DO_MAP" = 1 ]; then
      stage deliver start "filling the drag-and-drop SD folder ($MAP_OUT)"
      bash "$WS/tools/pack-sd.sh" --map --map-out "$MAP_OUT" ${DUMP:+"$DUMP"} \
        >"$WS/logs/engine-map.log" 2>&1 \
        || fail "SD folder build failed (see $WS/logs/engine-map.log)"
      files="$(find "$MAP_OUT" -type f | wc -l | tr -d ' ')"
      bytes="$(tree_bytes "$MAP_OUT")"
      printf '%s\n' "$(j deliver map "$MAP_OUT" files "$files" bytes "$bytes")"
      stage deliver ok "folder ready to drag onto your SD card: $MAP_OUT ($files files, $bytes bytes)"
    fi
    if [ "$DO_ZIP" = 1 ]; then
      stage deliver start "building the SD zip"
      bash "$WS/tools/pack-sd.sh" --zip ${DUMP:+"$DUMP"} >"$WS/logs/engine-zip.log" 2>&1 \
        || fail "SD zip failed (see $WS/logs/engine-zip.log)"
      zip="$WS/dist/MarioKartWii-Switch.zip"
      printf '%s\n' "$(j deliver zip "$zip" bytes "$(filesize "$zip")" sha256 "$(awk '{print $1}' "$zip.sha256" 2>/dev/null || echo unknown)")"
      stage deliver ok "SD zip built: $zip"
    fi
  fi
  if [ "$DO_DEPLOY" = 1 ]; then
    stage deliver start "pushing to the console over FTP"
    bash "$WS/switch-ops/switch.sh" push "$NRO" >"$WS/logs/engine-deploy.log" 2>&1 \
      || fail "push failed (check switch-ops/switch.env and see $WS/logs/engine-deploy.log)"
    stage deliver ok "placed on the SD card; start it from hbmenu with title override"
  fi
fi

# ---- sweep ------------------------------------------------------------------
# Napruimen wat de motor uit jóuw dump zelf weer kan maken, zodat één klik geen
# gigabytes achterlaat. Voorwaarden: de .nro bestaat (anders is er niets om voor op
# te ruimen), de native-route (bij docker wonen die bomen in een volume, dat ruimt
# men elders op), en niet om `--keep-recomp` gevraagd. Standaard blijft de bouw-
# cache (objecten + vertaalde shards, gemeten 5,1 GiB) liggen: dáár zit de tijd,
# want een koude build-stap kostte 867 s terwijl ccache al zijn 682 cachebare
# aanroepen raakte — de 104 gast-shards die overblijven pakt ccache niet (het
# shard-doel bouwt met een voorgecompileerd koptekstje), dus hun objecten zijn het
# enige wat de tijd mag hebben. Met ze behalten is de volgende rebuild 67 s in
# plaats van 15 min; `--free-cache` ruimt ook dat op. Wat áltijd blijft staan: de
# .nro en local-product (terugval op de geverifieerde build), dist/ (de sleepbare
# SD-map), de deps-cache en het gereedschap. Een mislukte napruiming mag een verder
# geslaagde bouw niet alsnog als fout laten eindigen.
CUR=sweep
if want sweep && [ "$PLAN_ONLY" != 1 ]; then
  if [ "$KEEP_RECOMP" = 1 ]; then
    printf '%s\n' "$(j sweep freed 0 removed "none (kept as requested)" kept 1)"
    stage sweep ok "recomp files kept: objects, shards and the extract stay, so the next rebuild is the fastest one"
  elif [ "$BACKEND" != native ]; then
    stage sweep ok "cleanup skipped: the docker route builds inside a volume"
  elif [ ! -f "$NRO" ]; then
    stage sweep ok "cleanup skipped: there is no .nro"
  else
    stage sweep start "removing temporary build files"
    # Zonder --free-cache blijft de bouwcache liggen: dat is het deel dat de
    # minuten kost, en het is de moeite waard om 2 GiB voor te houden.
    SWEEP_ARGS=""
    [ "$FREE_CACHE" = 1 ] || SWEEP_ARGS="--keep-cache"
    # shellcheck disable=SC2086
    sweep_out="$(bash "$WS/tools/sweep-temp.sh" --deps "$DEPS_DIR" --ws "$WS" $SWEEP_ARGS 2>&1)" || {
      printf '%s\n' "$sweep_out" >&2
      stage sweep fail "cleanup failed — the .nro and the SD folder are done; clean up by hand with: bash tools/sweep-temp.sh --deps $DEPS_DIR --ws $WS"
      sweep_out=""
    }
    line=$(printf '%s\n' "$sweep_out" | grep '^{"t":"sweep"' | tail -n 1 || true)
    [ -n "$line" ] && printf '%s\n' "$line"
    freed=$(printf '%s' "$line" | sed -n 's/.*"freed":\([0-9][0-9]*\).*/\1/p')
    if [ "$FREE_CACHE" = 1 ]; then
      stage sweep ok "$(( ${freed:-0} / 1073741824 )) GiB freed; the .nro, the SD folder, the deps cache and the toolchain stay"
    else
      cache_gib=$(printf '%s' "$line" | sed -n 's/.*"cache_bytes":\([0-9][0-9]*\).*/\1/p')
      stage sweep ok "$(( ${freed:-0} / 1073741824 )) GiB freed, the $(( ${cache_gib:-0} / 1073741824 )) GiB build cache stays so the next rebuild is about a minute (--free-cache or the Clean up card gives it back)"
    fi
  fi
fi
