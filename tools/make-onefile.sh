#!/usr/bin/env bash
# make-onefile.sh — één bestand bouwen dat de hele bouwer is.
#
#   bash tools/make-onefile.sh   # MKWii-Builder.cmd (Windows) + .command (macOS/Linux)
#   bash tools/make-onefile.sh --check  # alleen controleren, niets schrijven
#
# Waarom: iemand die dit willen delen geeft één bestand, niet een map met 23 losse
# scripts. Elk van die twee bestanden draagt de *zelfde* gegarandeerde zip van
# make-publish.sh in zich: Windows als base64 tussen `rem`-regels (cmd.exe voert
# er niets van uit), macOS/Linux als tar.gz achter de `exit` van een POSIX-shell.
# Bij de eerste run pakt het zichzelf uit in de map waar het staat en opent het
# de normale flow: bash zoeken, Python zoeken, venster openen.
#
# Wat erin zit is uitsluitend gereedschap: make-publish.sh heeft al de Lek-garde
# gedaan (geen .nro, geen game-data, geen sleutels, geen persoonlijke paden), dus
# dit script kopieert niets zelf en verzwakt niets.
set -euo pipefail

WS="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$WS/dist/publish"
ZIP="$OUT/MarioKartWii-Switch-builder.zip"
TEMPLATE="$WS/templates/MKWii-Builder.cmd.in"
UNPACK="$WS/templates/unpack.ps1"
TARGET="$OUT/MKWii-Builder.cmd"
SHELL_TEMPLATE="$WS/templates/MKWii-Builder.command.in"
SHELL_TARGET="$OUT/MKWii-Builder.command"
MARK="MKWII-PAYLOAD"
CHECK_ONLY=0
[ "${1:-}" = "--check" ] && CHECK_ONLY=1

for f in "$TEMPLATE" "$UNPACK" "$SHELL_TEMPLATE"; do
  [ -f "$f" ] || { echo "Fout: sjabloon ontbreekt: $f" >&2; exit 1; }
done

if [ "$CHECK_ONLY" = 1 ]; then
  [ -f "$ZIP" ] || { echo "Fout: geen gereedschapszip; draai eerst tools/make-publish.sh." >&2; exit 1; }
else
  echo "== Stap 1/3: het gegarandeerde gereedschap (make-publish.sh) =="
  bash "$WS/tools/make-publish.sh"
fi
[ -f "$ZIP" ] || { echo "Fout: $ZIP bestaat niet." >&2; exit 1; }

echo "== Stap 2/3: zip + uitpakkers in het sjabloon =="
python - "$ZIP" "$TEMPLATE" "$UNPACK" "$TARGET" "$MARK" "$CHECK_ONLY" "$SHELL_TEMPLATE" "$SHELL_TARGET" <<'PY'
import base64, gzip, io, os, sys, tarfile, zipfile

(zip_path, template_path, unpack_path, target_path, mark, check_only,
 shell_template, shell_target) = sys.argv[1:9]

ps = io.open(unpack_path, encoding="utf-8").read().replace("\r\n", "\n")
bad = [c for c in ps if ord(c) > 126]
if bad:
    raise SystemExit("Fout: unpack.ps1 moet ASCII zijn, vond: %r" % bad[:4])
ps1 = base64.b64encode(ps.encode("utf-16-le")).decode("ascii")

raw = io.open(zip_path, "rb").read()
names = zipfile.ZipFile(io.BytesIO(raw)).namelist()
if not any(n.endswith("tools/nro-engine.sh") for n in names):
    raise SystemExit("Fout: de zip bevat geen tools/nro-engine.sh - onvolledig gereedschap")
for n in names:
    if n.endswith((".nro", ".wbfs", ".rvz", ".iso", ".gcm")) or "/DATA/" in n:
        raise SystemExit("Fout: game-data in het gereedschapspakket: " + n)

# Windows: de zip zelf, als `rem`-regels (cmd.exe voert er niets van uit).
body = base64.encodebytes(raw).decode("ascii").strip().splitlines()
payload = "\n".join("rem " + line for line in body)

text = io.open(template_path, encoding="utf-8").read()
for token in ("__PS1__", "__PAYLOAD_NAME__", "__PAYLOAD__"):
    if token not in text:
        raise SystemExit("Fout: sjabloon heeft geen " + token)
out = (text.replace("__PS1__", ps1)
           .replace("__PAYLOAD_NAME__", mark)
           .replace("__PAYLOAD__", payload))
out = out.replace("\r\n", "\n").replace("\n", "\r\n")

# macOS/Linux: dezelfde inhoud als tar.gz (die kunnen een zip niet openen zonder
# unzip, en tar + gzip + base64 zijn er wél altijd). De modes komen uit de zip:
# een script dat daar al 0755 had, blijft uitvoerbaar na het uitpakken.
zin = io.BytesIO()
# Gzip noteert anders het actuele klokmoment in zijn header; met mtime=0 blijft
# de tar.gz bij elke run byte-identiek, net als hieronder met de tar-stamp.
# TarFile sluit een meegegeven fileobj niet, dus die laag sluit apart.
gz = gzip.GzipFile(filename="", mode="wb", compresslevel=9, fileobj=zin, mtime=0)
with zipfile.ZipFile(io.BytesIO(raw)) as zr, tarfile.open(fileobj=gz, mode="w") as tr:
    for info in zr.infolist():
        if info.is_dir():
            continue
        data = zr.read(info)
        ti = tarfile.TarInfo(info.filename)
        ti.size = len(data)
        ti.mtime = 1730000000          # vast: dezelfde tar.gz bij elke run
        mode = (info.external_attr >> 16) & 0o777
        # De modes uit een rits die op Windows is gemaakt, zijn het halve pad kwijt
        # (switch.sh stond er bijvoorbeeld op 0666). Een script móet hier 0755 worden,
        # anders zegt een mac "permission denied" op precies het moment dat iemand
        # dit voor het eerst probeert.
        if info.filename.endswith((".sh", ".py", ".command")):
            ti.mode = 0o755
        else:
            ti.mode = mode if mode else 0o644
        tr.addfile(ti, io.BytesIO(data))
gz.close()
sbody = base64.encodebytes(zin.getvalue()).decode("ascii").strip().splitlines()
spayload = "\n".join("# " + line for line in sbody)

stext = io.open(shell_template, encoding="utf-8").read()
for token in ("__PAYLOAD_NAME__", "__PAYLOAD__"):
    if token not in stext:
        raise SystemExit("Fout: .command-sjabloon heeft geen " + token)
sout = stext.replace("__PAYLOAD_NAME__", mark).replace("__PAYLOAD__", spayload)
sout = sout.replace("\r\n", "\n")

if check_only == "1":
    print("   sjabloon + zip passen: %d regels payload (cmd), %d regels (.command), %d bestanden"
          % (len(body), len(sbody), len(names)))
    raise SystemExit(0)

os.makedirs(os.path.dirname(target_path), exist_ok=True)
io.open(target_path, "w", encoding="ascii", newline="").write(out)
io.open(shell_target, "w", encoding="ascii", newline="\n").write(sout)
os.chmod(shell_target, 0o755)
print("   %d bestanden ingebed in beide: %d regels base64 (cmd) + %d (.command)"
      % (len(names), len(body), len(sbody)))
PY

echo "== Stap 3/3: controle =="
python - "$TARGET" "$MARK" <<'PY'
import io, os, sys, zipfile

target, mark = sys.argv[1], sys.argv[2]
# newline='' houden: dit bestand ís CRLF, en een batch-regel is alleen een regel
# als je die einden niet weg filtreert (universele newlines zouden het hele bestand
# als één regel geven en de markers "ontbreken" dan).
lines = io.open(target, encoding="ascii", newline="").read().split("\r\n")
while lines and lines[-1] == "":
    lines.pop()
begin = "rem ==== %s ====" % mark
end = "rem ==== %s-END ====" % mark
if begin not in lines or end not in lines:
    raise SystemExit("Fout: payload-markers ontbreken in " + target)
raw = "\r\n".join(lines)
if raw.count("\n") != raw.count("\r\n"):
    raise SystemExit("Fout: dit batch-bestand heeft losse LF-reinden; cmd.exe parseert het dan verkeerd")
if lines[-1] != "exit /b 0" and not lines[-1].startswith("exit /b"):
    raise SystemExit("Fout: het bestand eindigt niet met exit /b - cmd zou de payload gaan uitvoeren")
i, j = lines.index(begin), lines.index(end)
b64 = "".join(l[4:] for l in lines[i + 1:j])
import base64
blob = base64.b64decode(b64)
n = len(zipfile.ZipFile(io.BytesIO(blob)).namelist())
if any("/DATA/" in x or x.endswith((".nro", ".wbfs", ".rvz")) for x in
        zipfile.ZipFile(io.BytesIO(blob)).namelist()):
    raise SystemExit("Fout: game-data in de ingebedde payload")
print("   ingebed pakket leest terug als zip: %d bestanden" % n)

# Een echo met kaal haakje binnen een ( ... )-blok is voor cmd.exe het einde van
# dat blok: de rest van de regel wordt toen een commando en de gebruiker ziet
# ". was unexpected at this time." in plaats van de melding. Cijfer de diepte
# zoals cmd doet (dubbele quotes en ^-escapes tellen niet mee) en wijs die regels
# aan voordat ze in het veld verschijnen.
def bare(code):
    return code.replace("^(", "").replace("^)", "")

depth, problems = 0, []
for no, line in enumerate(lines[:lines.index(begin)], 1):
    word = line.strip().lower()
    if word.startswith("rem ") or word == "rem" or word.startswith("::"):
        continue
    out, quoted = [], False
    for ch in line:
        if ch == '"':
            quoted = not quoted
        elif not quoted:
            out.append(ch)
    code = bare("".join(out))
    low = word
    is_echo = low.startswith("echo ") or low.startswith("@echo ")
    if is_echo and depth > 0 and ("(" in code or ")" in code):
        problems.append("regel %d: kaal haakje in een echo binnen een blok: %s" % (no, line.strip()))
    for ch in code:
        if ch == "(":
            depth += 1
        elif ch == ")":
            depth -= 1
        if depth < 0:
            problems.append("regel %d: een ) sluit een blok dat niet open is: %s" % (no, line.strip()))
            depth = 0
if depth != 0:
    problems.append("het laatste blok van dit batch-bestand wordt nooit gesloten")
if problems:
    raise SystemExit("Fout: cmd.exe zou dit bestand verkeerd parseren:\n  " + "\n  ".join(problems))
print("   batch-opbouw: alle ( ... )-blokken sluiten, geen kaal haakje in een echo")
PY

# De .command is hetzelfde idee in een andere taal: de shell mag er niets van
# uitvoeren ná `exit`, het bestand moet LF-reinden hebben (CRLF = `command not
# found` op elke Linux/macOS), en zijn payload moet een tar.gz zijn die écht
# uitpakt tot gereedschap. Dat laatste is hier meetbaar, niet gehoopt.
python - "$SHELL_TARGET" "$MARK" <<'PY'
import base64, gzip, io, os, sys, tarfile

target, mark = sys.argv[1], sys.argv[2]
text = io.open(target, encoding="ascii", newline="").read()
if "\r\n" in text:
    raise SystemExit("Fout: .command heeft CRLF-reinden; sh/dash ziet dan `\\r` in elke regel")
lines = text.split("\n")
while lines and lines[-1] == "":
    lines.pop()
begin, end = "# ==== %s ====" % mark, "# ==== %s-END ====" % mark
if begin not in lines or end not in lines:
    raise SystemExit("Fout: payload-markers ontbreken in " + target)
i, j = lines.index(begin), lines.index(end)
body = "".join(l[2:] for l in lines[i + 1:j])
blob = base64.b64decode(body)
with gzip.GzipFile(fileobj=io.BytesIO(blob)) as gz:
    tf = tarfile.open(fileobj=gz)
    members = [m for m in tf.getmembers() if m.isfile()]
names = [m.name for m in members]
if not any(n.endswith("tools/nro-engine.sh") for n in names):
    raise SystemExit("Fout: de ingebedde tar.gz bevat geen tools/nro-engine.sh")
if any(n.endswith((".nro", ".wbfs", ".rvz", ".iso", ".gcm")) or "/DATA/" in n for n in names):
    raise SystemExit("Fout: game-data in de ingebedde tar.gz")
for m in members:
    if m.name.endswith((".sh", ".py")) and not (m.mode & 0o755) == 0o755:
        raise SystemExit("Fout: %s staat op 0%o - een script moet hier 0755 zijn" % (m.name, m.mode))
head = "\n".join(lines[:lines.index(begin)])
if not head.startswith("#!/bin/sh"):
    raise SystemExit("Fout: .command begint niet met #!/bin/sh")
# /bin/sh is op een Linux-distro vaak dash, op een mac bash in POSIX-modus. Wat
# hier dus niet in mag zijn bash-uitjes: die geven op precies die distro een
# "illegal option" terwijl het op de testmachine leek te werken.
import re
BASHISM = re.compile(r"read (?:-r )?-p |\[\[ |\(\(|^[ \t]*local |\$\{\!")
clumsy = ["%d: %s" % (n + 1, l.strip()) for n, l in enumerate(lines[:i]) if BASHISM.search(l)]
if clumsy:
    raise SystemExit("Fout: deze .command gebruikt bash-uitjes (dash geeft op):\n  " + "\n  ".join(clumsy))
if "exit $RC" not in "\n".join(lines[:i]):
    raise SystemExit("Fout: de shell-stappen sluiten zichzelf vóór de payload niet af")
print("   .command: tar.gz leest terug als %d bestanden, scripts staan op 0755, LF-reinden, geen bash-uitjes"
      % len(members))
PY
bash --posix -n "$SHELL_TARGET" || { echo "Fout: sh kan deze .command niet parsen" >&2; exit 1; }
echo "   shell-opbouw: POSIX-sh parseert het, payload staat achter de exit"
hash_of() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}';
  else shasum -a 256 "$1" | awk '{print $1}'; fi
}
echo
sums=""
for f in "$ZIP" "$TARGET" "$SHELL_TARGET"; do
  [ -f "$f" ] || { echo "Fout: $f verdween tijdens het bouwen" >&2; exit 1; }
  echo "KLAAR: $f  ($(stat -c%s "$f" 2>/dev/null || stat -f%z "$f") bytes)"
  echo "   sha256 $(hash_of "$f")"
  sums="$sums$(hash_of "$f")  $(basename "$f")"$'\n'
done
# Wie een controle-getal ergens neerzet, kan dat niet in deze log doen: de log
# reist zelf mee in het pakket, dus elke zin schuift het getal op. Dit bestand
# staat ernaast en blijft kloppen zolang de stukken niet veranderen.
printf '%s' "$sums" > "$(dirname "$TARGET")/SHA256SUMS.txt"
echo "   controle:  cd $(dirname "$TARGET") && sha256sum -c SHA256SUMS.txt"
echo "   MKWii-Builder.cmd is het ene bestand voor Windows, MKWii-Builder.command"
echo "   dat ene bestand voor macOS en Linux: allebei in elke map neerzetten, dubbelklikken,"
echo "   ze pakken zichzelf uit en openen daarna het venster. Alleen gereedschap, geen Nintendo-data."
