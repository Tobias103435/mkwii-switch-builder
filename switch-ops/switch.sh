#!/usr/bin/env bash
# Schakel tussen deze PC en een Switch met FTP-server (sys-ftpd of ftpd.nro).
# Veiligheid: ik schrijf en lees ALLEEN binnen DEPLOY_DIR en wis nooit iets.
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ENVF="$HERE/switch.env"
[ -f "$ENVF" ] || { echo "Fout: maak $ENVF aan vanuit switch.env.example" >&2; exit 1; }
# shellcheck disable=SC1090
source "$ENVF"
: "${SWITCH_IP:?SWITCH_IP ontbreekt}"
PORT="${SWITCH_FTP_PORT:-5000}"
BASE="ftp://${SWITCH_IP}:${PORT}"
AUTH=()
[ -n "${SWITCH_FTP_USER:-}" ] && AUTH=(--user "${SWITCH_FTP_USER}:${SWITCH_FTP_PASS}")

# Blokkeer elke pad die buiten onze projectmap op de SD probeert te komen.
# Alleen de prefix vergelijken is níet genoeg: `/switch/WiiCompiled-Switch/../x` begint
# letterlijk met de projectmap maar wijst ernaast, en die val heb ik hier zelf getest.
# Elke `..`-component wordt daarom verworpen, ongeacht waar hij staat.
guard() {
  case "$1" in
    *..*) echo "Geweigerd: '..' is geen toegestaan pad-onderdeel: $1" >&2; exit 1 ;;
  esac
  case "$1" in
    "$DEPLOY_DIR"/*|"$DEPLOY_DIR") return 0 ;;
    *) echo "Geweigerd: $1 valt buiten $DEPLOY_DIR" >&2; exit 1 ;;
  esac
}

# De ene naam die hbmenu toont; zie het deploy-commando. Alles Olderijft als .nro.bak,
# want hbmenu toont geen .bak en er wordt niets verwijderd.
DEPLOY_NAME="${SWITCH_DEPLOY_NAME:-MKWii.nro}"

# mv <oude naam> <nieuwe naam> — binnen DEPLOY_DIR, hernoemen, met terugleescontrole.
do_mv() {
  old=${1:?geef de oude naam}
  new=${2:?geef de nieuwe naam}
  guard "$DEPLOY_DIR/$old"; guard "$DEPLOY_DIR/$new"
  echo ">> $old -> $new"
  curl -sS "${AUTH[@]}" -Q "RNFR $DEPLOY_DIR/$old" -Q "RNTO $DEPLOY_DIR/$new" \
    "$BASE$DEPLOY_DIR/" >/dev/null
  listing=$(curl -sS "${AUTH[@]}" "$BASE$DEPLOY_DIR/")
  printf '%s' "$listing" | grep -qF "$new" || { echo "Fout: $new staat niet op de kaart" >&2; exit 1; }
  printf '%s' "$listing" | grep -qF "$old" && { echo "Fout: $old staat nog steeds op de kaart" >&2; exit 1; }
  echo "   hernoemd en teruggelezen"
}

cmd=${1:-help}
shift || true

case "$cmd" in
  mv)
    # mv <oude remotaam> <nieuwe remotaam> — alleen BINNEN $DEPLOY_DIR, en alleen
    # hernoemen: er bestaat geen verplaatsing naar elders en geen wiscommando.
    do_mv "${1:?geef de oude naam}" "${2:?geef de nieuwe naam}"
    ;;
  push)
    # push <lokaal-bestand> [remotenaam]
    local_file=$1
    remote_name=${2:-$(basename "$local_file")}
    target="$DEPLOY_DIR/$remote_name"
    guard "$target"
    echo ">> $local_file -> $target"
    sha256sum "$local_file"
    curl -sS -T "$local_file" "${AUTH[@]}" "$BASE$target"
    echo "   geplaatst; controleer grootte:"
    curl -sSI "${AUTH[@]}" "$BASE$target" | grep -iE 'content-length|226' || true
    ;;
  pull)
    # pull <remote-rel-pad> [lokaal-bestand]
    rel=${1:?geef een pad binnen $DEPLOY_DIR}
    target="$DEPLOY_DIR/$rel"
    guard "$target"
    out=${2:-"$HERE/pulled/$(basename "$rel")"}
    mkdir -p "$(dirname "$out")"
    curl -sS "${AUTH[@]}" -o "$out" "$BASE$target"
    echo ">> $target -> $out ($(stat -c%s "$out") bytes)"
    sha256sum "$out"
    ;;
  ls)
    rel=${1:-}
    target="$DEPLOY_DIR${rel:+/$rel}"
    guard "$target"
    # curl FTP: zonder trailing slash wordt een map als bestand behandeld (fout 78).
    curl -sS "${AUTH[@]}" "$BASE$target/"
    ;;
  logs)
    # Al het bekende diagnose-arsenaal van dit project, in één keer.
    mkdir -p "$HERE/pulled"
    for f in runtime-bootstrap.txt fast-track-progress.txt fast-track-heartbeat.txt \
             fast-track-dispatch-blocker.txt fast-track-exception.txt \
             fast-track-thread-events.txt fast-track-main-reached.txt \
             fast-track-heartbeat-history.txt; do
      curl -sS --fail "${AUTH[@]}" -o "$HERE/pulled/$f" "$BASE$DEPLOY_DIR/$f" \
        && echo "OK   $f" || echo "afwezig $f"
    done
    ;;
  pullfrom)
    # pullfrom <abs-remote-pad> <lokaal-bestand> : alleen LEZEN buiten DEPLOY_DIR.
    # Voor de eigen discs: sys-ftpd kan niet beperkt worden tot één map, dus het
    # pad komt van de gebruiker, en dit commando voert uitsluitend een FTP-get uit.
    # Er bestaat geen write- of deletevariant buiten DEPLOY_DIR.
    rel=${1:?geef een absoluut pad op de SD}
    out=${2:?geef een lokaal bestand}
    [ "${rel:0:1}" = / ] || { echo "Fout: remote pad moet absoluut zijn" >&2; exit 1; }
    # curl wijst rauwe spaties/haakjes in een URL af (fout 3), dus encoderen.
    rel_enc=$(printf '%s' "$rel" | sed -e 's/%/%25/g' -e 's/ /%20/g' -e 's/(/%28/g' -e 's/)/%29/g')
    url="$BASE$rel_enc"
    mkdir -p "$(dirname "$out")"
    # sys-ftpd: eerst de remote-grootte, zodat we compleetheid kunnen afdwingen.
    remote_size=$(curl -g -sSI --connect-timeout 15 "${AUTH[@]}" "$url" | awk 'tolower($1)=="content-length:"{print $2}' | tr -d '\r')
    [ -n "$remote_size" ] || { echo "Fout: remote grootte onbekend" >&2; exit 1; }
    # sys-ftpd kent géén REST (curl-fout 31, ook bij --range: FTP-range = REST).
    # Hervatten kan dus niet op deze server: een afgebroken haal pakt het hele
    # bestand opnieuw. Voor de grote bestanden is DBI-MTP over USB de snellere en
    # robuustere route als WiFi struikelt.
    have=0
    [ -f "$out" ] && have=$(stat -c%s "$out")
    if [ "$have" -eq "$remote_size" ]; then
      echo ">> $rel is al compleet lokaal ($have bytes)"
    else
      [ "$have" -gt 0 ] && echo ">> onvolledig lokaal stuk ($have/$remote_size) wordt herhaald — REST wordt niet ondersteund"
      echo ">> $rel -> $out  ($remote_size bytes)"
      # -Y/-y: breek af als de console in slaap valt, anders hangt curl uren op een
      # dode WiFi-verbinding. Korte vormen: curl 8.18 (Windows) kent de lange alias
      # --low-speed-limit niet.
      curl -g -sS --connect-timeout 15 -Y 4096 -y 90 \
        "${AUTH[@]}" -o "$out" "$url" || {
          echo "Fout: transfer afgebroken; opnieuw aanroepen (geen resume mogelijk)." >&2
          exit 1
        }
    fi
    # Completheidscontrole: alleen als de grootte exact klopt is het klaar.
    now=$(stat -c%s "$out")
    [ "$now" -eq "$remote_size" ] || { echo "Fout: $now != $remote_size bytes, bestand is onvolledig" >&2; exit 1; }
    echo ">> compleet: $now bytes"
    sha256sum "$out"
    ;;
  run)
    # run <lokaal.nro> : nxlink uit de devkitA64-container; hbmenu moet open staan.
    nro=${1:?geef een .nro}
    MSYS_NO_PATHCONV=1 docker run --rm \
      -v "$(dirname "$nro"):/nro:rw" -w /nro \
      devkitpro/devkita64 bash -c \
      "nxlink -a $SWITCH_IP -p '$DEPLOY_DIR' -s '/$(basename "$nro")'"
    ;;
  deploy)
    # deploy <bestand.nro> — zet de kandidaat neer als HET ene bestand dat hbmenu toont:
    # MKWii.nro. Een vorige versie blijft altijd op de kaart maar krijgt de naam
    # archief-<sha-12>.nro.bak; die .bak-suffix haalt hem uit het hbmenu-overzicht
    # (hbmenu toont alleen .nro) zonder iets te verwijderen. Eén lijst, één keuze, en
    # elke eerdere hardware-run is met `switch.sh mv` weer terug te draaien.
    nro=${1:?geef een .nro}
    local_size=$(stat -c%s "$nro")
    local_sha=$(sha256sum "$nro" | cut -c1-12)
    echo ">> te plaatsen: $(basename "$nro")  $local_size B  sha $local_sha"
    if curl -sSI "${AUTH[@]}" "$BASE$DEPLOY_DIR/$DEPLOY_NAME" >/dev/null 2>&1; then
      curl -sS "${AUTH[@]}" -o "$HERE/pulled/.previous.nro" "$BASE$DEPLOY_DIR/$DEPLOY_NAME" \
        || { echo "Fout: het huidige $DEPLOY_NAME is niet terug te lezen; niets overschreven" >&2; exit 1; }
      old_sha=$(sha256sum "$HERE/pulled/.previous.nro" | cut -c1-12)
      rm -f "$HERE/pulled/.previous.nro"
      [ "$old_sha" = "$local_sha" ] && { echo "   $DEPLOY_NAME is al precies deze build — niets te doen"; exit 0; }
      bak="archief-${old_sha}.nro.bak"
      curl -sS "${AUTH[@]}" "$BASE$DEPLOY_DIR/" | grep -qF "$bak" && bak="archief-${old_sha}-$(date +%H%M%S).nro.bak"
      echo "   huidige $DEPLOY_NAME (sha $old_sha) opzij als $bak"
      do_mv "$DEPLOY_NAME" "$bak"
    fi
    echo ">> uploaden als $DEPLOY_NAME"
    curl -sS -T "$nro" "${AUTH[@]}" "$BASE$DEPLOY_DIR/$DEPLOY_NAME"
    remote_size=$(curl -sSI "${AUTH[@]}" "$BASE$DEPLOY_DIR/$DEPLOY_NAME" | tr -d '\r' \
      | awk 'tolower($1)=="content-length:"{print $2}')
    [ "$remote_size" = "$local_size" ] || { echo "Fout: kaart heeft ${remote_size:-niets} B, lokaal $local_size B" >&2; exit 1; }
    echo "   OK: hbmenu toont vanaf nu alleen $DEPLOY_NAME ($local_size B, sha $local_sha)"
    ;;
  *)
    cat <<'EOF'
Gebruik:
  switch.sh deploy <bestand.nro>                 als MKWii.nro op de kaart, vorige → archief-*.nro.bak
  switch.sh mv <oude-naam> <nieuwe-naam>         hernoemen binnen $DEPLOY_DIR (nooit wissen)
  switch.sh push <bestand.nro> [naam.op.sd]     upload naar /switch/WiiCompiled-Switch
  switch.sh pull <rel-pad> [lokaal-bestand]     download binnen $DEPLOY_DIR
  switch.sh pullfrom <abs-pad> <lokaal>         alleen lezen buiten $DEPLOY_DIR ( discs )
  switch.sh ls [subdir]                         directory listing
  switch.sh logs                                alle fast-track + bootstrap logs pullen
  switch.sh run <bestand.nro>                   deploy + starten via nxlink (hbmenu open)
EOF
    ;;
esac
