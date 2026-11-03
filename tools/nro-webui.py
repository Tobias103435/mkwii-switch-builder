#!/usr/bin/env python3
"""nro-webui.py — de simple one-click-UI bovenop tools/nro-engine.sh.

    python3 tools/nro-webui.py            # venster in je browser, poort willekeurig
    python3 tools/nro-webui.py --no-browser --port 8765   # voor tests en SSH

Waarom een localhost-pagina en geen tkinter: tkinter zit op Linux vaak in een
aparte package (python3-tk) en op macOS moet het een versie met Tk 8.6 zijn,
dus dubbelklikken werkt er niet overal. Een HTML-pagina met stdlib http.server
werkt op Windows, macOS en Linux met precies dezelfde code, en de bouwlog blijft
aanraakbaar. Alle bouwisieking staat in tools/nro-engine.sh; dit bestand kent
alleen het NDJSON-contract van die motor en toont het.

Dit bestand raakt zelf géén game-data: het geeft alleen het dump-pad door dat de
gebruiker kiest en laat de motor doen wat de motor al deed.
"""

import argparse
import html
import json
import os
import re
import secrets
import shutil
import signal
import subprocess
import sys
import threading
import time
import webbrowser
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

HERE = os.path.dirname(os.path.abspath(__file__))
WS = os.path.dirname(HERE)
ENGINE = os.path.join(WS, "tools", "nro-engine.sh")
RAW_LOG = os.path.join(WS, "logs", "engine-build-raw.log")
NOD = os.path.join(WS, "tools", "nodtool")

# De bouw is aan één revisie gepind: PAL RMCP01. Het venster leest alleen de
# disc-kop (nod doet dat in seconden); de echte SHA-pins controleert de motor in de
# inputs-stap. Dit is dus een vooraanzegging, geen tweede waarheid.
EXPECTED_ID = "RMCP01"
REGION_OF = {"RMCP00": "NTSC-U", "RMCP01": "PAL (Europe, Australia)", "RMCP02": "NTSC-J"}

EXTRA = []          # motor-opties die het venster doorgeeft aan elke bouw

# Schatting van de schijfruimte, in GiB. Gemeten op een Windows-host met een
# volledige bouw (2026-11-02): de getallen zijn de bomen zoals die onder getuigde
# builds groeien, niet de theorie. `toolchain` en `deps` zijn eenmalig — de motor
# haalt ze zelf op als ze ontbreken —, `extract` is wat de napruimactie weghaalt,
# `cache` is wat er standaard wél blijft staan (objecten + shards: gemeten 867 s
# van de bouwtijd, en met ze behalten is de volgende bouw 67 s), en `map` is het
# product dat blijft staan.
NEED = {
    "toolchain": ("toolchain (devkitA64 + cmake/ninja/.NET)", 0.7, "once"),
    "deps": ("renderstack cache (Dawn + libuam)", 6.0, "once"),
    "extract": ("unpacked game data", 2.5, "temp"),
    "build": ("objects and link", 4.7, "cache"),
    "shards": ("translated shards", 0.4, "cache"),
    "map": ("drag-and-drop SD folder", 2.6, "keeps"),
}
DISK_CACHE = {"at": 0.0, "data": None}

# ---- tijdschatting ------------------------------------------------------------
# De motor meldt bij elke stap zijn eigen `total`: seconden sinds die run begon.
# Een schatting hoeft dus niets te raden zodra er één meting bestaat, en de
# meting van de vorige bouw op dezelfde machine is de beste voorspeller voor de
# volgende. BASE_SECONDS is waar een allereerste schatting vandaan komt: gemeten
# op deze host (logs/build-nro-20261102-180708.ndjson: build 971 s, alles bij
# elkaar 980 s, met toolchain en renderstack al aanwezig). PROVISION_SECONDS is
# géén meting maar de eigen tekst van de motor over een toolchain-download, en
# de eenmalige renderstack noemt de motor zelf "hours, one-off" - dat wordt dan
# ook zo gezegd, in plaats van een cijfer verzinnen.
BASE_SECONDS = {"env": 3, "src": 3, "inputs": 12, "build": 965, "verify": 6,
                "deliver": 45, "sweep": 10}
PROVISION_SECONDS = 900
ETA_ORDER = ["provision", "env", "src", "inputs", "build", "verify", "deliver", "sweep"]
ETA_HISTORY = os.path.join(WS, "logs", "eta-history.json")

LOCK = threading.Lock()
# De motor neemt zelf een slot (logs/engine.lock) zodat twee builings niet over
# elkaars work tree en productpad schrijven. Het venster leest dat slot vóór het
# Start: anders wordt "er busy al een" pas na een halve minuut een onleesbare
# exit-code 1, terwijl de motor het antwoord allang weet.
ENGINE_LOCKDIR = os.path.join(WS, "logs", "engine.lock")
LOCK_STALE_S = 21600   # dezelfde grens als in de motor: ouder = een restoort
# De standaardplek van de sleepbare SD-map (tools/nro-engine.sh: MAP_OUT) en het
# bestand dat onthoudt wat de laatste run daar achterliet.
SD_MAP = os.path.join(WS, "dist", "MarioKartWii-Switch")
DELIV_FILE = os.path.join(WS, "logs", "last-delivery.json")
STATE = {
    "running": False,
    "cmd": [],
    "stages": {},          # naam -> laatste events (lijst van dicts)
    "order": [],           # volgorde van voortschrijden
    "progress": None,      # laatste progress-regel
    "result": None,
    "deliver": None,
    "sweep": None,         # {"freed":bytes,"removed":"…"} van de napruimactie
    "error": None,
    "t0": None,
    "exit": None,
    "mode": "default",       # "default" of "full": de schatter onthoudt per set
    "log": RAW_LOG,
}

DUMP_FILTERS = ["*.rvz", "*.wbfs", "*.iso", "*.gcm"]
# --dump van de commando-regel vult het veld al in (handig via de snelkoppelingen);
# main() schrijft deze global, de import-waarde is leeg.
PRESET_DUMP = ""
PRE_FULL = "0"
PRE_ZIP = "0"


BASH_CACHE = {"path": None, "why": ""}


def bash_probe(c):
    """Eisen: de kandidaat moet WERKELIJK draaien, niet alleen bestaan.
    Op Windows wijst `where bash` naar de WSL-relay (System32\bash.exe) of de
    Store-alias: dat zijn bestanden, maar er zit geen Linux-bash achter, en de
    motor sterft dan op `execvpe(/bin/bash) failed`. Zelfde les als bij Python:
    wie zich niet kan uitvoeren, is het niet."""
    try:
        p = subprocess.run([c, "-c", "printf mkwok"], capture_output=True, text=True, timeout=20)
    except (OSError, subprocess.TimeoutExpired):
        return False
    return p.returncode == 0 and "mkwok" in (p.stdout or "")


def find_bash():
    """Een bash om de motor in te starten, op elk platform: de eerste die draait."""
    if BASH_CACHE["path"]:
        return BASH_CACHE["path"]
    cands = []
    if os.environ.get("MKW_BASH"):
        cands.append(os.environ["MKW_BASH"])
    if os.name == "nt":
        pf = os.environ.get("ProgramFiles", r"C:\Program Files")
        pfx86 = os.environ.get("ProgramFiles(x86)", r"C:\Program Files (x86)")
        la = os.environ.get("LOCALAPPDATA", "")
        # Git Bash is de bash die deze builder bedoelt: hij ziet de C:\-paden zoals de
        # .cmd ze doorgeeft en hij draait devkitA64 op de host.
        for base in [b for b in (pf, pfx86, os.path.join(la, "Programs") if la else "") if b]:
            for sub in (("bin",), ("usr", "bin")):
                cands.append(os.path.join(base, "Git", *sub, "bash.exe"))
            for sub in (("bin",), ("usr", "bin")):
                cands.append(os.path.join(base, "Git1", *sub, "bash.exe"))
        found = shutil.which("bash") or ""
        # De PATH-vindplek als laatste: op veel machines is dat de WSL-relay of de
        # Store-alias, en die helpen hier niet - ook niet als ze toevallig antwoorden.
        low = found.replace("/", "\\").lower()
        if low and "\\system32\\" not in low and "windowsapps" not in low:
            cands.append(found)
    else:
        cands += ["/bin/bash", "/usr/bin/bash", shutil.which("bash") or ""]
    for c in cands:
        if c and os.path.isfile(c) and bash_probe(c):
            BASH_CACHE["path"] = c
            return c
    BASH_CACHE["why"] = "tried: " + ", ".join(x for x in cands if x)
    return None


def reset_state(cmd, mode="default"):
    with LOCK:
        STATE.update(
            running=True, cmd=cmd, stages={}, order=[], progress=None,
            result=None, deliver=None, sweep=None, error=None, t0=time.time(), exit=None,
            mode=mode,
        )
        DISK_CACHE["data"] = None   # gereedschap/cache kan tijdens deze run zijn verschenen


def read_stream(proc):
    """NDJSON van de motor → STATE. Eén regel per keer, nooit gebufferd weergegeven."""
    for line in proc.stdout:
        line = line.strip()
        if not line or not line.startswith("{"):
            continue
        try:
            ev = json.loads(line)
        except ValueError:
            continue
        t = ev.get("t")
        # Paden meekrijgen in twee vormen: wat de motor meldt (POSIX) en wat deze
        # host laat zien en openen (Windows/macOS/Linux). De UI heeft alleen de
        # tweede nodig, en de knop die alleen de eerste kende, deed niets.
        if t in ("deliver", "result"):
            for k in ("map", "zip", "nro"):
                if ev.get(k):
                    ev[k + "_native"] = native_path(ev[k])
        with LOCK:
            if t == "stage":
                name = ev.get("stage", "?")
                if name not in STATE["order"]:
                    STATE["order"].append(name)
                STATE["stages"].setdefault(name, []).append(ev)
            elif t == "progress":
                STATE["progress"] = ev
            elif t == "result":
                STATE["result"] = ev
            elif t == "deliver":
                # De motor meldt map en zip als twee regels met dezelfde veldnamen
                # (bytes, sha256). De zip krijgt daarom zijn eigen naam: anders
                # wist zijn omvang die van de sleepmap en toont de kaart het
                # verkeerde getal - en de Open-knop het verkeerde pad.
                prev = STATE["deliver"] or {}
                merged = dict(prev)
                if ev.get("zip"):
                    merged["zip"] = ev["zip"]
                    merged["zip_native"] = ev.get("zip_native", "")
                    for k in ("bytes", "sha256"):
                        if ev.get(k):
                            merged["zip_" + k] = ev[k]
                else:
                    merged.update(ev)
                STATE["deliver"] = merged
                save_delivery(merged)
            elif t == "sweep":
                STATE["sweep"] = ev
            elif t == "error":
                STATE["error"] = ev


def watch(proc):
    code = proc.wait()
    with LOCK:
        STATE.update(running=False, exit=code)
    DISK_CACHE["data"] = None   # vrije ruimte is nu anders: opnieuw meten
    if code == 0:
        # Nooit weggoeien wat er op deze machine duurde: de volgende schatting
        # mag hier rechtstreeks uit putten. Een deelrun (één stap, of een run
        # zonder build) levert geen bruikbare mijlpaal op en gaat dus niet in de
        # geschiedenis.
        ms, wall = observed_durations()
        if wall > 0 and int(ms.get("build") or 0) > 30:
            with LOCK:
                mode = STATE["mode"]
            eta_remember(mode, ms, wall)


def engine_lock():
    """(leeftijd in s, pid) van het motor-slot, of None als er geen staat."""
    if not os.path.isdir(ENGINE_LOCKDIR):
        return None
    pid = ""
    try:
        with open(os.path.join(ENGINE_LOCKDIR, "pid")) as fh:
            pid = fh.read().strip()
    except OSError:
        pass
    try:
        return time.time() - os.path.getmtime(ENGINE_LOCKDIR), pid
    except OSError:
        return None


def engine_busy():
    l = engine_lock()
    return l is not None and l[0] < LOCK_STALE_S


def check_dump(path):
    """Leest de disc-kop en zegt of dit de ROM is waarvoor gebouwd wordt."""
    if not path:
        return {"state": "empty", "ok": False, "msg": "pick your ROM to continue"}
    if not os.path.isfile(path):
        return {"state": "missing", "ok": False, "msg": "no file at that path"}
    size = os.path.getsize(path)
    bash = find_bash()
    if not (os.path.isfile(NOD) and bash):
        return {"state": "unknown", "ok": True, "size": size,
                "msg": "header check unavailable here (nod is missing); the build still checks the pins"}
    rc, out, err = run2([bash, NOD, "info", path])
    if rc is None:
        return {"state": "error", "ok": True, "size": size,
                "msg": "nod did not answer (is bash still on this machine?); the build checks the pins itself"}
    if out is None:
        if engine_busy():
            return {"state": "busy", "ok": True, "size": size,
                    "msg": "a build is running right now, so nod cannot open the disc next to it; "
                            "the header check answers again once that build is done"}
        time.sleep(0.8)
        rc, out, err = run2([bash, NOD, "info", path])
    if out is None:
        hint = " ".join((err or "").split())[:180]
        # Een WSL-relay of een kapotte Store-alias meldt zich als "nod kon dit niet
        # lezen", terwijl het probleem de gekozen bash is: niet de dump de schuld geven.
        if any(k in (err or "") for k in ("WSL", "execvpe", "/bin/bash")):
            return {"state": "error", "ok": True, "size": size,
                    "msg": "this window picked a bash that is not a real one (" + hint +
                           "); install Git for Windows and start MKWii-Builder.cmd again"}
        return {"state": "unreadable", "ok": True, "size": size,
                "msg": "nod could not read this file (exit %s; is it a complete disc image?)%s"
                       % (rc, " nod said: " + hint if hint else "")}
    ids, fmt, rev = [], "", ""
    for line in out.splitlines():
        t = line.strip()
        if t.startswith("Game ID:"):
            ids.append(t.split(":", 1)[1].strip().split()[0])
        elif t.startswith("Format:") and not fmt:
            fmt = t.split(":", 1)[1].strip()
        elif t.startswith("Disc 1, Revision") and not rev:
            rev = t.split()[-1]
    gid = next((i for i in ids if i.startswith("RMCP")), ids[0] if ids else "")
    where = " / ".join(x for x in (fmt, "rev " + rev if rev else "") if x)
    if gid == EXPECTED_ID:
        return {"state": "right", "ok": True, "gid": gid, "size": size,
                "msg": "Mario Kart Wii " + REGION_OF[EXPECTED_ID] + " (" + gid + "), "
                       + "revision " + (rev or "?") + " - the revision this build is pinned to"
                       + (" [" + where + "]" if where else "")}
    if gid in REGION_OF:
        return {"state": "wrong", "ok": False, "gid": gid, "size": size,
                "msg": "that is " + REGION_OF[gid] + " (" + gid + "), but this build is pinned to PAL "
                       + EXPECTED_ID + ". Tick 'use it anyway' to try; the pin check will still stop it "
                       "unless the addresses happen to match."}
    return {"state": "unknown", "ok": True, "gid": gid or "?", "size": size,
            "msg": "Game ID " + (gid or "not readable") + " - not recognised as Mario Kart Wii PAL; "
                   "the build checks the pins itself before it extracts anything."}


def start_build(opts):
    if STATE["running"]:
        return "A build is already running."
    l = engine_lock()
    if l and l[0] < LOCK_STALE_S:
        return ("A build is already running: the engine holds its lock (%d min old, pid %s). "
                "Wait for it to finish - two builings share one work tree and would overwrite "
                "each other. If nothing is running any more, delete logs/engine.lock."
                % (int(l[0] // 60), l[1] or "?"))
    bash = find_bash()
    if not bash:
        return ("I cannot find a working bash. This builder runs on Git Bash - install "
                "Git for Windows (git-scm.com/download/win) and start the file again. "
                + BASH_CACHE["why"])
    if not os.path.isfile(ENGINE):
        return f"Engine is missing: {ENGINE}"
    cmd = [bash, ENGINE]
    if opts.get("dump"):
        cmd += ["--dump", opts["dump"]]
    if opts.get("full"):
        cmd.append("--full")
    if opts.get("zip"):
        cmd.append("--zip")
    if opts.get("no_map"):
        cmd.append("--no-map")
    # De napruimactie haalt standaard alleen de uitgepakte game-data weg (2,5 GiB);
    # de objecten en vertaalde shards (~5 GiB) blijven staan. Meting: een koude
    # build-stap kostte 867 s terwijl ccache al zijn 682 cachebare aanroepen raakte,
    # dus de tijd zit in de grote gast-shards — en die blijven nu liggen. Een
    # volgende bouw is dan 67 s in plaats van 15 min. Wie die ruimte terugwil zet
    # het vinkje aan; `keep` is de andere richting, dan blijft er niets over.
    if opts.get("keep"):
        cmd.append("--keep-recomp")
    if opts.get("free"):
        cmd.append("--free-cache")
    if opts.get("allow"):
        cmd.append("--allow-revision-mismatch")
    if opts.get("deploy"):
        cmd.append("--deploy")
    if opts.get("jobs"):
        cmd += ["--jobs", str(int(opts["jobs"]))]
    cmd += EXTRA
    # Voor de schatting telt een bouw met lege cache als een volledige bouw: anders
    # onthoudt 'm een snelle warme rebuild en belooft daarna 1 minuut aan iemand die
    # juist voor 'free the build cache' koos.
    cold = bool(opts.get("full") or opts.get("free"))
    reset_state(cmd, "full" if cold else "default")
    env = dict(os.environ)
    # Geen MSYS_NO_PATHCONV hier: de motor zet die alleen rond zijn eigen
    # `docker run` zelf. Global gezet maakt host-git (en dus de src-stap) kapot.
    os.makedirs(os.path.join(WS, "logs"), exist_ok=True)
    errlog = open(os.path.join(WS, "logs", "engine-stderr.log"), "ab")
    try:
        proc = subprocess.Popen(
            cmd, cwd=WS, stdout=subprocess.PIPE, stderr=errlog,
            stdin=subprocess.DEVNULL, text=True, encoding="utf-8", errors="replace",
            env=env,
        )
    except OSError as exc:
        with LOCK:
            STATE.update(running=False, error={"stage": "start", "msg": str(exc)})
        return None
    threading.Thread(target=read_stream, args=(proc,), daemon=True).start()
    threading.Thread(target=watch, args=(proc,), daemon=True).start()
    return None


def pick_file():
    """Native bestandskezer, per platform. Levert None op als er geen is."""
    if os.name == "nt":
        ps = (
            "Add-Type -AssemblyName System.Windows.Forms;"
            "$d = New-Object System.Windows.Forms.OpenFileDialog;"
            "$d.Title = 'Choose your Wii dump';"
            "$d.Filter = 'Wii disc (*.rvz, *.wbfs, *.iso, *.gcm)|"
            + ";".join(DUMP_FILTERS)
            + "|All files (*.*)|*.*';"
            "if ($d.ShowDialog()) { $d.FileName }"
        )
        out = run(["powershell", "-NoProfile", "-Command", ps])
    elif sys.platform == "darwin":
        out = run([
            "osascript", "-e",
            'POSIX path of (choose file with prompt "Choose your Wii dump"'
            ' of type {"rvz","wbfs","iso","gcm","public.item"})',
        ])
    else:
        out = run(["zenity", "--file-selection", "--title=Choose your Wii dump",
                   "--file-filter=Wii disc | " + " ".join(DUMP_FILTERS)])
        if out is None:
            out = run(["kdialog", "--getopenfilename", os.path.expanduser("~")])
    if not out:
        return None
    path = out.strip().strip('"')
    return path or None


def run2(argv, timeout=120):
    """(rc, stdout, stderr); rc is None als het proces zelf niet started of te lang draait."""
    try:
        p = subprocess.run(argv, capture_output=True, text=True, timeout=timeout)
    except (OSError, subprocess.TimeoutExpired):
        return None, None, None
    return p.returncode, (p.stdout if p.returncode == 0 else None), p.stderr


def run(argv):
    return run2(argv)[1]


def native_path(path):
    """Een POSIX-pad van de motor omzetten naar wat het besturingssysteem toont.

    De motor is bash en meldt `<jouw-werkmap>/...` (of, onder een andere bash,
    `/mnt/c/...`). Op Windows zegt `os.path.exists()` daar nee tegen en opent de
    verkenner iets anders dan de bedoeling was - dlatego de knop "Open SD folder"
    stil faalde. Eerst de eigen, voorspelbare regel voor een schijfletter, want
    `cygpath` maakt van `/mnt/c/x` een pad ín zijn eigen installatie. Pas daarna
    `cygpath`, voor de vormen die deze UI niet kent (`/home/...`).
    """
    if not path:
        return ""
    p = str(path).strip().strip('"')
    if os.name != "nt":
        return p
    m = re.match(r"^/(?:mnt/|cygdrive/)?([A-Za-z])(/.*|)$", p)
    if m:
        return m.group(1).upper() + ":" + ((m.group(2) or "\\").replace("/", "\\"))
    if os.path.exists(p):
        return p          # al native, bijvoorbeeld een pad dat hier is gekozen
    out = run(["cygpath", "-w", p])
    return out.strip() if out else p


def reveal(path, select=""):
    """Map in de verkenner van het platform, zonder iets te wissen of te verplaatsen.

    `select` is een bestand of submap ín die map: dan opent de verkenner met dat
    item gemarkeerd. Dat is waarom deze UI de `switch`-map aanwijst - iemand die
    het pad alleen ziet, moet in één oogopslag weten wat er moet worden gekopieerd.
    """
    target = native_path(path)
    if not target or not os.path.exists(target):
        return False
    pick = native_path(select) if select else ""
    if pick and not os.path.exists(pick):
        pick = ""
    try:
        if os.name == "nt":
            if pick:
                # `explorer /select,` wil één argument en een backslash-pad; het
                # scheidingsteken in het argument is geen vlag, dus geen shell-quote.
                subprocess.Popen(["explorer", "/select," + pick])
            else:
                os.startfile(target)  # noqa: S606 - opent alleen een bestaand lokaal pad
        elif sys.platform == "darwin":
            subprocess.Popen(["open", "-R", pick] if pick else ["open", target])
        else:
            # Linux: geen enkele verkenner markeert hier een item via een opdracht,
            # dus opent deze route de ouder - dat is wat de gebruiker zoekt.
            opener = shutil.which("xdg-open")
            if not opener:
                return False
            subprocess.Popen([opener, os.path.dirname(pick) if pick else target])
    except (OSError, ValueError):
        return False
    return True


def save_delivery(ev):
    """De weg naar de sleepbare SD-map op disk zetten.

    Het venster onthoudt anders alleen wat déze sessie bouwde. Iemand die het
    product gisteren maakte, het venster sluit en heden terugkomt, vraagt precies
    één ding: wáár die map is. Eén klein bestand antwoordt, ook als de motor toen
    nog niet eens bestond.
    """
    try:
        os.makedirs(os.path.dirname(DELIV_FILE), exist_ok=True)
        cur = {}
        if os.path.isfile(DELIV_FILE):
            with open(DELIV_FILE, encoding="utf-8") as fh:
                cur = json.load(fh)
        cur.update({k: v for k, v in ev.items()
                    if k in ("map", "zip", "files", "bytes", "sha256", "zip_bytes", "zip_sha256")})
        cur["at"] = int(time.time())
        with open(DELIV_FILE, "w", encoding="utf-8") as fh:
            json.dump(cur, fh)
    except OSError:
        pass   # de leveringskaart valt terug op de map die er daadwerkelijk staat


def sd_report():
    """Waar de sleepbare SD-map staat, in woorden die deze host begrijpt.

    Eerst wat er nu live gemeld is, dan wat de vorige run achterliet, en als beide
    zwijgen de standaardplek van de motor - maar alleen als die map er echt staat.
    De paden zijn omgerekend naar Windows/macOS/Linux-notatie, want de POSIX-vorm
    van de motor is voor een verkenningsadres onbruikbaar.
    """
    with LOCK:
        dl = dict(STATE["deliver"] or {})
    if not dl.get("map") and os.path.isfile(DELIV_FILE):
        try:
            with open(DELIV_FILE, encoding="utf-8") as fh:
                dl.update(json.load(fh))
        except (OSError, ValueError):
            pass
    if not dl.get("map") and os.path.isdir(os.path.join(SD_MAP, "switch")):
        dl["map"] = SD_MAP
    native = native_path(dl.get("map") or "")
    if not native or not os.path.isdir(native):
        # Nog geen map: zeg waar hij komt, dan is die plek alvast geen raadtsel.
        return {"found": 0, "pending": 1, "path": native_path(SD_MAP)}
    inner = os.path.join(native, "switch")
    return {"found": 1, "path": native, "switch": inner if os.path.isdir(inner) else "",
            "files": dl.get("files"), "bytes": dl.get("bytes"), "zip": native_path(dl.get("zip") or ""),
            "at": dl.get("at")}


def clean_app(level):
    """Alles wat deze bouwer maakte, weg halen - in twee maten.

    leftovers  : alleen de herbouwbare tussenproducten (wat de motor ook na een
                 geslaagde bouw weghaalt).
    everything : de hele map terug naar alleen MKWii-Builder.cmd; het product (.nro,
                 SD-map), de clone, de toolchain en het gereedschap gaan allemaal mee.

    tools/ is het laatste: Windows laat een draaiend script zijn eigen bestand niet
    weg. Deze UI woont in tools/, en python leest zijn bron bij start in, dus zij kan
    die map wél verwijderen nadat het script terugkwam.
    """
    if level not in ("leftovers", "everything"):
        return {"ok": False, "msg": "unknown cleanup level"}
    if engine_busy():
        return {"ok": False, "msg": "a build is running right now - wait for it, then clean up"}
    bash = find_bash()
    if not bash:
        return {"ok": False, "msg": "bash is needed to clean up and none was found"}
    script = os.path.join(WS, "tools", "clean-app.sh")
    if not os.path.isfile(script):
        return {"ok": False, "msg": "tools/clean-app.sh is missing"}
    rc, out, err = run2([bash, script, "--" + level, "--yes"], timeout=3600)
    text = "\n".join(x for x in ((out or "").strip(), (err or "").strip()) if x)
    note = ""
    if level == "everything":
        tools_dir = os.path.join(WS, "tools")
        try:
            shutil.rmtree(tools_dir)
            note = "\n   removed: tools"
        except OSError as exc:
            note = "\n   tools/ stayed (close this window and remove it by hand): %s" % exc
    if rc is None:
        return {"ok": False, "msg": (text or "cleanup did not finish") + note}
    return {"ok": rc == 0, "msg": ((text or ("cleaned up" if rc == 0 else "cleanup failed"))) + note}


def deps_dir():
    """Zelfde zoekvolgorde als tools/nro-engine.sh: een boom telt alleen met Dawn
    en libuam, in de vorm van een eigen bouw of van het pakket van
    tools/render-deps.sh."""
    cands = []
    if os.environ.get("MKW_DEPS_DIR"):
        cands.append(os.environ["MKW_DEPS_DIR"])
    home = os.path.expanduser("~")
    cands += [
        os.path.join(WS, ".deps", "native-deko3d"),
        os.path.join(home, "mkw-toolchain", "deps", "native-deko3d"),
        os.path.join(home, "mkw-deps", "native-deko3d"),
        "/opt/mkw-deps/native-deko3d",
    ]
    for c in cands:
        source = os.path.isdir(os.path.join(c, "dawn", "src")) and \
            os.path.isfile(os.path.join(c, "uam", "meson.build"))
        packed = os.path.isfile(os.path.join(c, ".mkw-render-package")) and \
            os.path.isfile(os.path.join(c, "dawn-build-switch", "src", "dawn", "native",
                                        "libwebgpu_dawn.a")) and \
            os.path.isfile(os.path.join(c, "uam", "build-switch", "libuam.a"))
        if source or packed:
            return c
    return None


RENDER_PINS = os.path.join(WS, "tools", "render-deps-pins.env")
RENDER_LOCAL = os.environ.get("MKW_RENDER_DEPS_LOCAL") or os.path.join(WS, "dist", "render-deps")


def render_pins():
    """tools/render-deps-pins.env lezen als gegevens, niet als shell-bron."""
    out = {}
    try:
        with open(RENDER_PINS, encoding="utf-8") as fh:
            for line in fh:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                key, value = line.split("=", 1)
                out[key.strip()] = value.strip().strip('"').strip("'")
    except OSError:
        pass
    return out


def render_package():
    """Het pakket waarmee deze machine aan de renderstack kan komen: (bron, bytes).

    None als er niets te halen is, want dan is de eerlijke tekst uren werk in
    plaats van een download. Zelfde volgorde als tools/render-deps.sh: eerst het
    bestand dat hier al ligt, dan de pinned url.
    """
    if os.environ.get("MKW_RENDER_DEPS") == "build" or deps_dir() is not None:
        return None
    pins = render_pins()
    name = pins.get("MKW_RENDER_DEPS_NAME", "")
    if name:
        path = os.path.join(RENDER_LOCAL, name)
        if os.path.isfile(path):
            return (path, os.path.getsize(path))
    url = pins.get("MKW_RENDER_DEPS_URL", "")
    if url:
        return (url, int(pins.get("MKW_RENDER_DEPS_BYTES") or 0))
    if os.path.isdir(RENDER_LOCAL):
        for f in sorted(os.listdir(RENDER_LOCAL)):
            if f.startswith("mkw-render-deko3d-") and f.endswith((".tar.xz", ".tar.gz")):
                path = os.path.join(RENDER_LOCAL, f)
                return (path, os.path.getsize(path))
    return None


def toolchain_dir():
    cand = os.environ.get("DEVKITPRO") or os.path.join(os.path.expanduser("~"), "mkw-toolchain", "opt", "devkitpro")
    return cand if os.path.isdir(os.path.join(cand, "devkitA64", "bin")) else None


def cache_dirs():
    """De twee bomen die een herbouw snel maken, op de plekken die de bouwer
    zelf gebruikt (tools/build-in-container.sh): de voorwerp-boom en de
    vertaalde shards."""
    deps = deps_dir()
    if not deps:
        return []
    work = os.environ.get("MKW_DEKO3D_WORK_DIR") or os.path.join(deps, "driftdroid")
    return [os.environ.get("MKW_DEKO3D_BUILD_DIR")
            or os.path.join(deps, "build-switch-release"),
            os.path.join(work, "generated", "build_shards")]


def warm_report():
    """Wat deze machine al hergebruikt kan worden - feiten, geen voorspelling.

    Na een geslaagde bouw zet de motor een vingerafdruk in logs/last-build.json.
    Die kan dit venster niet herberekenen (git en sha256 leven in bash-land), dus
    `reusable` betekent hier: de record, het .nro dat erbij hoort en beide
    cachebomen staan er. Of de vingerafdruk ook echt nog klopt, weet pas de
    motor zelf op het moment dat hij begint.
    """
    out = {"record": False, "nro": False, "cache": 0, "reusable": False, "sha": ""}
    try:
        with open(os.path.join(WS, "logs", "last-build.json"), encoding="utf-8") as fh:
            rec = json.load(fh)
        out["record"] = True
        out["sha"] = str(rec.get("sha256") or "")[:12]
        p = native_path(rec.get("nro") or "")
        out["nro"] = bool(p) and (os.path.exists(p) or os.path.exists(rec.get("nro") or ""))
    except (OSError, ValueError):
        pass
    dirs = cache_dirs()
    out["cache"] = sum(1 for d in dirs if os.path.isdir(d) and os.listdir(d))
    out["reusable"] = out["record"] and out["nro"] and len(dirs) == out["cache"]
    return out


def eta_history():
    """De gemeten mijlpalen van eerdere bouwen op deze machine (logs/eta-history.json)."""
    try:
        with open(ETA_HISTORY, encoding="utf-8") as fh:
            data = json.load(fh)
        return data if isinstance(data, list) else []
    except (OSError, ValueError):
        return []


def eta_remember(mode, durations, wall):
    """Een afgelopen bouw is de beste voorspeller voor de volgende. Er gaan
    alleen seconden en de optiezets in: geen paden, geen bestandsnamen, geen ROM."""
    entries = eta_history()
    entries.append({"mode": mode, "wall": int(wall), "milestones": durations,
                    "platform": sys.platform, "at": int(time.time())})
    try:
        os.makedirs(os.path.dirname(ETA_HISTORY), exist_ok=True)
        with open(ETA_HISTORY, "w", encoding="utf-8") as fh:
            json.dump(entries[-12:], fh, indent=1)
    except OSError:
        pass


def observed_durations():
    """Per stap de duur in seconden, uit de `total`-velden van de motor zelf."""
    with LOCK:
        done = {n: [e for e in evs if e.get("state") == "ok"]
                for n, evs in STATE["stages"].items()}
        order = list(STATE["order"])
    ms, prev, wall = {}, 0, 0
    for name in order:
        evs = done.get(name) or []
        if not evs:
            continue
        t = int(evs[-1].get("total") or 0)
        ms[name] = max(0, t - prev)
        prev = max(prev, t)
        wall = t
    return ms, wall


def minutes(s):
    s = int(round(s))
    m, sec = divmod(s, 60)
    if m >= 60:
        return "%d h %02d min" % (m // 60, m % 60)
    return ("%d min %02d s" % (m, sec)) if m else ("%d s" % sec)


def minutes_r(s):
    """Deze tekst staat naast een balk die al op de seconde afgaat; een halve
    zin in minuten leest hier rustiger dan '17 min 24 s'."""
    s = int(round(s))
    if s < 90:
        return "%d s" % s
    m = int(round(s / 60.0))
    if m < 60:
        return "%d min" % m
    return "%d h %02d min" % (m // 60, m % 60)


def eta_expected(mode):
    """(seconden per stap, totaal, waar het vandaan komt, gemeten hier?) — een
    afgelopen bouw op deze machine steekt boven de tabelfiguur, maar de meting
    moet wel bij deze optiezets horen."""
    for e in reversed(eta_history()):
        if e.get("mode") != mode:
            continue
        ms = e.get("milestones") or {}
        wall = int(e.get("wall") or 0)
        if wall > 60 and int(ms.get("build") or 0) > 30:
            return ms, wall, "measured on your last build here (%s)" % minutes_r(wall), True
    total = sum(BASE_SECONDS.values())
    return dict(BASE_SECONDS), total, "cold-build figure (%s for a full rebuild)" % minutes_r(total), False


def eta_report():
    """Hoe lang het nog duurt, en wat dit werk eigenlijk gaat kosten.

    Drie bronnen, in volgorde van betrouwbaarheid: de `total`-velden die de motor
    per stap meldt, het percentage dat ninja tijdens de build-stap zelf afgeeft,
    en pas daaronder de tabelfiguur. Eén correctie: deze machine is wat hij
    is, dus de resterende stappen worden geschaald met de verhouding die de al
    afgeronde stappen lieten zien. Een stap die ver zijn eigen duur voorbij is en
    waar de motor geen percentage meer meldt, krijgt géén schatting: dan is "we
    weten het niet" eerlijker dan een getal dat elk moment 0 kan worden.
    """
    with LOCK:
        running = STATE["running"]
        t0 = STATE["t0"]
        exit_code = STATE["exit"]
        mode = STATE["mode"]
        stages = {k: list(v) for k, v in STATE["stages"].items()}
        order = list(STATE["order"])
        progress = dict(STATE["progress"] or {}) if STATE["progress"] else {}

    dur, total, basis, measured = eta_expected(mode)

    # Wat er vóór de start al vaststaat: een toolchain die nog gedownload moet
    # worden en een renderstack die nog gebouwd moet worden, zijn geen minuten.
    ahead = []
    need_toolchain = toolchain_dir() is None
    if need_toolchain:
        ahead.append("first run here also downloads the toolchain (a few GB, roughly %s)" % minutes_r(PROVISION_SECONDS))
    if deps_dir() is None:
        pkg = render_package()
        if pkg:
            ahead.append("first run also fetches the render stack as a verified package (%s MB, one-off)"
                         % max(1, int(pkg[1] // 1e6)))
        else:
            ahead.append("the render stack (Dawn + libuam) still has to be built once here: hours, not minutes")
    # provision telt alleen mee als die download hier nog moet gebeuren; een
    # machine die de toolchain al heeft, wacht er straks niet op.
    pipeline = [s for s in ETA_ORDER if (s != "provision" or need_toolchain) and (s in dur or s == "provision")]
    planned = sum(dur.get(s, PROVISION_SECONDS) for s in pipeline) or total

    if not running and t0 is None:
        return {"left": planned, "total": planned, "pct": 0, "stage": None,
                "basis": basis, "measured": measured, "ahead": ahead, "detail": "", "note": ""}
    if not running and exit_code == 0:
        ms, wall = observed_durations()
        if int(ms.get("build") or 0) > 30:
            detail = "your build took %s" % minutes(wall)
            note = "remembered for the next build" if eta_history() else \
                   "next run on this machine starts from this measurement"
        else:
            # Een deelrun (één stap, of een rebuild van alleen de schijf) is geen
            # meeting van een volledige bouw en doet dus ook geen belofte.
            detail = "that run covered only part of the build (%s)" % minutes(wall)
            note = ""
        return {"left": 0, "total": max(wall, planned), "pct": 100, "stage": None,
                "basis": basis, "measured": measured, "ahead": ahead, "detail": detail, "note": note}

    cum = {}
    for name, evs in stages.items():
        oks = [e for e in evs if e.get("state") == "ok"]
        if oks:
            cum[name] = int(oks[-1].get("total") or 0)
    # `total` is cumulatief: seconden sinds de run begon. De duur van één stap is
    # het verschil met de vorige, en zonder die omrekening zou de correctiefactor
    # de som van alle klokken door de som van alle duur delen en dus exploderen.
    dur_obs, prev = {}, 0
    for name in order:
        if name in cum:
            t = cum[name]
            dur_obs[name] = max(0, t - prev)
            prev = max(prev, t)
    last_total = prev
    cur, cur_at = None, 0
    for name in order:
        if name in cum:
            continue
        starts = [int(e.get("total") or 0) for e in stages.get(name, []) if e.get("state") == "start"]
        if starts:
            cur, cur_at = name, min(starts)
            break

    elapsed = (time.time() - t0) if running and t0 else last_total

    # Correctie: hoe verhoudt deze machine zich tot de figuur? Alleen wie echt
    # iets heeft gemeten mag de rest van de planning opschalen. De eerste stappen
    # zijn seconde-werk: daar een factor uit halen zou betekenen dat een bouw die
    # toevallig 4 s deed in plaats van 18 s straks op 16 % van de werkelijkheid
    # staat te wijzen. provision is een download en zegt niets over rekensnelheid.
    seen_base = sum(dur.get(s, 0) for s in dur_obs if s != "provision")
    seen_obs = sum(v for s, v in dur_obs.items() if s != "provision")
    factor = 1.0
    if seen_base >= 30 and seen_obs >= 60:
        factor = min(2.5, max(0.4, seen_obs / seen_base))

    pending = [s for s in pipeline if s not in cum and s != cur]
    left = sum(dur.get(s, PROVISION_SECONDS) for s in pending) * factor
    note = detail = ""
    if cur:
        base_cur = dur.get(cur, PROVISION_SECONDS if cur == "provision" else 0)
        used = max(0.0, elapsed - cur_at)
        pct_raw = int(progress.get("pct") or 0) if cur == "build" else 0
        if pct_raw >= 3:
            p = min(99, pct_raw)
            left += used * (100 - p) / p
            detail = "%d%% of the compile done" % p
        elif base_cur > 0 and used > 1.15 * base_cur * factor:
            left = None
            note = ("the %s step is past its usual length and the engine reports no "
                    "percentage here, so there is no honest number for what is left - "
                    "the detail log says what it is doing" % cur)
        else:
            left += max(0.0, base_cur * factor - used)

    if not running and exit_code not in (None, 0):
        note = note or "stopped here - the reason is in the error card above"

    pct = 0
    if left is not None:
        pct = max(1, min(99, int(round(100 * (1 - left / max(planned, 1))))))
        if exit_code == 0 and not running:
            pct = 100
    return {"left": int(left) if left is not None else None, "total": int(planned),
            "pct": pct, "stage": cur, "basis": basis, "measured": measured, "ahead": ahead,
            "detail": detail, "note": note}


def disk_report():
    """Wat de bouw qua ruimte gaat kosten, vóórdat iemand op Start drukt.

    `once` telt alleen mee als het gereedschap of de cache er nog niet staat;
    `temp` is wat de napruimactie weghaalt; `cache` blijft standaard staan (en is
    dus wél ruimte die de bouw opeist); `keeps` is het product. De vrije ruimte
    wordt live van de schijf van deze werkruimte gelezen.
    """
    now = time.time()
    if DISK_CACHE["data"] and now - DISK_CACHE["at"] < 30:
        return DISK_CACHE["data"]
    free = shutil.disk_usage(WS).free
    dirs = cache_dirs()
    have = {"deps": deps_dir() is not None, "toolchain": toolchain_dir() is not None,
            "build": len(dirs) > 0 and os.path.isdir(dirs[0]),
            "shards": len(dirs) > 1 and os.path.isdir(dirs[1]),
            "map": os.path.isdir(os.path.join(SD_MAP, "switch"))}
    parts = []
    need = once = temp = cache = product = 0.0
    for key, (label, gib, kind) in NEED.items():
        present = have.get(key, False)
        if key == "deps" and not present:
            # Een pakket laten neerziene is geen 5 GiB bron- en build-boom, maar
            # 600 MB archive plus headers — en die 600 MB komt twee keer langs
            # (uitpak-map, dan de geplaatste boom), dus de piek is ruim 1 GiB.
            pkg = render_package()
            if pkg:
                label = "renderstack package (Dawn + libuam, %s MB download)" % max(
                    1, int(pkg[1] // 1e6))
                gib = 1.4
        parts.append({"key": key, "label": label, "gib": gib, "kind": kind, "present": present})
        if kind == "keeps":
            product += gib
        elif kind == "temp":
            temp += gib
        elif kind == "cache":
            cache += gib
        elif not present:
            once += gib
    need = once + temp + cache + product
    data = {"free": free, "need": round(need, 1), "once": round(once, 1), "temp": round(temp, 1),
            "cache": round(cache, 1), "product": round(product, 1), "parts": parts, "path": WS,
            "enough": free >= need * 1024 ** 3}
    DISK_CACHE.update(at=now, data=data)
    return data


def tail_log(limit=6000):
    try:
        with open(RAW_LOG, "rb") as fh:
            fh.seek(0, os.SEEK_END)
            size = fh.tell()
            fh.seek(max(0, size - limit))
            return fh.read().decode("utf-8", "replace")
    except OSError:
        return ""


class Handler(BaseHTTPRequestHandler):
    token = ""
    protocol_version = "HTTP/1.1"

    def log_message(self, *a):
        pass

    def _send(self, code, body, ctype="application/json; charset=utf-8"):
        raw = body.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(raw)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(raw)

    def _allowed(self):
        return self.client_address[0] in ("127.0.0.1", "::1")

    def do_GET(self):
        if not self._allowed():
            return self._send(403, "{}")
        u = urlparse(self.path)
        if u.path == "/":
            return self._send(200, PAGE.replace("__TOKEN__", self.token).replace("__DUMP__", html.escape(PRESET_DUMP, quote=True))
                .replace("__PRE_FULL__", PRE_FULL).replace("__PRE_ZIP__", PRE_ZIP), "text/html; charset=utf-8")
        q = parse_qs(u.query)
        if q.get("token", [""])[0] != self.token:
            return self._send(403, '{"error":"token"}')
        if u.path == "/api/state":
            # Buiten de snapshot-lock: eta_report() neemt die slot zelf ook.
            eta = eta_report()
            sd = sd_report()
            # Oók voor de snapshot-lock: warm_report() loopt over de cachebomen en
            # native_path kan een cygpath-process starten terwijl de motor op
            # diezelfde slot wacht.
            warm = warm_report()
            # Het .nro-pad komt uit bash-land; getoond en geopend wordt het in de
            # notatie van deze host, anders levert de Open-knop een vraag op die
            # niemand kan beantwoorden. Buiten de lock, want native_path kan een
            # cygpath-process starten en de motor staat op diezelfde lock te wachten.
            res = dict(STATE["result"] or {})
            if res.get("nro"):
                res["nro_native"] = native_path(res["nro"])
            with LOCK:
                snap = json.dumps({
                    "running": STATE["running"], "cmd": STATE["cmd"],
                    "order": STATE["order"], "stages": STATE["stages"],
                    "progress": STATE["progress"], "result": (res or None),
                    "deliver": STATE["deliver"], "sweep": STATE["sweep"],
                    "error": STATE["error"], "eta": eta, "mode": STATE["mode"],
                    "sd": sd, "warm": warm,
                    "t0": STATE["t0"], "exit": STATE["exit"],
                    "engine_lock": (int(engine_lock()[0]) if engine_lock() else None),
                    "elapsed": (time.time() - STATE["t0"]) if STATE["t0"] else 0,
                    "now": time.time(),
                })
            return self._send(200, snap)
        if u.path == "/api/log":
            return self._send(200, tail_log(), "text/plain; charset=utf-8")
        if u.path == "/api/disk":
            return self._send(200, json.dumps(disk_report()))
        return self._send(404, '{"error":"unknown"}')

    def do_POST(self):
        if not self._allowed():
            return self._send(403, "{}")
        u = urlparse(self.path)
        q = parse_qs(u.query)
        if q.get("token", [""])[0] != self.token:
            return self._send(403, '{"error":"token"}')
        length = int(self.headers.get("Content-Length") or 0)
        try:
            body = json.loads(self.rfile.read(length) or b"{}") if length else {}
        except ValueError:
            body = {}
        if u.path == "/api/start":
            err = start_build(body)
            return self._send(200 if err is None else 409, json.dumps({"error": err}))
        if u.path == "/api/check":
            return self._send(200, json.dumps(check_dump(body.get("path", ""))))
        if u.path == "/api/clean":
            return self._send(200, json.dumps(clean_app(body.get("level", "leftovers"))))
        if u.path == "/api/pick":
            return self._send(200, json.dumps({"path": pick_file()}))
        if u.path == "/api/open":
            return self._send(200, json.dumps({"ok": bool(reveal(body.get("path", ""), body.get("select", "")))}))
        if u.path == "/api/quit":
            self._send(200, '{"ok":true}')
            threading.Thread(target=shutdown_server, daemon=True).start()
            return None
        return self._send(404, '{"error":"unknown"}')


SERVER = None


def shutdown_server():
    time.sleep(0.4)
    if SERVER:
        SERVER.shutdown()


PAGE = r"""<!doctype html>
<html lang="en"><head>
<meta charset="utf-8"><title>WiiCompiled-Switch — one-click builder</title>
<meta name="viewport" content="width=device-width,initial-scale=1">
<style>
:root{--bg:#0b0e12;--panel:#141922;--panel2:#1a2130;--line:#2c3546;--tx:#eaf0f8;--dim:#93a0b5;
--go:#37c96f;--go2:#6ee79c;--blue:#38a7e8;--warn:#f0b429;--err:#ff6b6b;
--mono:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace}
*{box-sizing:border-box}
body{margin:0;color:var(--tx);font:15px/1.55 system-ui,"Segoe UI",Roboto,sans-serif;background:var(--bg)}
/* Checkerbord-achtergrond, helemaal in CSS: geen Nintendo-materiaal in dit pakket. */
.bg{position:fixed;inset:0;z-index:-1;opacity:.95;background:
 radial-gradient(1200px 620px at 50% -14%,#1c2f45 0,transparent 62%),
 repeating-conic-gradient(#131821 0% 25%,#0c1016 0% 50%) 0 0/64px 64px}
.bg::after{content:"";position:absolute;inset:0;opacity:.16;background:
 repeating-linear-gradient(45deg,transparent 0 22px,#ffffff08 22px 24px)}
.wrap{width:min(1120px,100%);padding:26px 20px 56px;margin:0 auto}
header{display:flex;align-items:center;gap:16px;margin-bottom:8px;flex-wrap:wrap}
.ring{width:66px;height:66px;border-radius:50%;border:7px solid var(--blue);flex:0 0 66px;
 box-shadow:0 0 22px #38a7e855,inset 0 0 16px #38a7e833}
h1.metal{margin:0;font-size:33px;font-weight:900;letter-spacing:2.5px;line-height:1;
 background:linear-gradient(#ffffff,#cdd7e4 44%,#78859a 56%,#f2f6fb);
 -webkit-background-clip:text;background-clip:text;color:transparent}
.wii{font-size:19px;font-weight:800;color:#cfe3f5;letter-spacing:1px;margin-top:2px}
.tag{margin:0 0 0 auto;color:var(--dim);font-size:13px;text-align:right}
.cols{display:grid;grid-template-columns:1.05fr 1.25fr .9fr;gap:14px;margin:22px 0 0}
@media (max-width:900px){.cols{grid-template-columns:1fr}}
.card{background:linear-gradient(180deg,var(--panel2),var(--panel));border:1px solid var(--line);
 border-radius:16px;padding:16px 17px 18px;box-shadow:0 14px 34px -24px #000}
.card.pending{opacity:.5}
.card.on{border-color:#3a4a66}
.title{font-size:12px;letter-spacing:.09em;text-transform:uppercase;color:var(--dim);
 margin:0 0 12px;display:flex;align-items:center;gap:8px}
.title b{display:grid;place-items:center;width:20px;height:20px;border-radius:50%;background:#232b3a;
 border:1px solid var(--line);color:var(--tx);font-size:11px;letter-spacing:0}
.card.on .title{color:var(--tx)}
.card.on .title b{background:var(--blue);border-color:var(--blue);color:#06101f}
.row{display:flex;gap:9px;align-items:center;flex-wrap:wrap}
input[type=text]{flex:1;min-width:190px;background:#0a0e14;border:1px solid var(--line);color:var(--tx);
 border-radius:10px;padding:11px 12px;font:12.5px var(--mono)}
input[type=text]:focus{outline:none;border-color:var(--blue)}
button{background:#232b39;border:1px solid var(--line);color:var(--tx);border-radius:10px;
 padding:10px 14px;font-size:14px;cursor:pointer;transition:.15s}
button:hover{border-color:#4a5872;background:#2b3444}
button.go{background:linear-gradient(#f6f9fc,#dde5ef);color:#0f1420;border:1px solid #b9c4d3;
 border-radius:12px;padding:12px 28px;font-size:16px;font-weight:750;
 box-shadow:0 10px 22px -16px #000,inset 0 -2px 0 #00000014}
button.go:hover{background:linear-gradient(#ffffff,#e8f5ee);border-color:var(--go)}
button.go[disabled]{background:#20262f;color:var(--dim);border-color:var(--line);box-shadow:none;cursor:default}
label.opt{display:flex;gap:7px;align-items:center;color:var(--dim);font-size:12.5px;cursor:pointer;
 padding:5px 10px;border:1px solid var(--line);border-radius:999px;background:#111721}
label.opt:hover{color:var(--tx)}
.opts{display:flex;flex-direction:column;gap:7px;align-items:flex-start;margin-top:12px}
.sub{font-size:11px;letter-spacing:.09em;text-transform:uppercase;color:#7f8ca3;font-weight:700}
.romstate{display:flex;gap:8px;align-items:baseline;margin-top:11px;padding:9px 11px;border-radius:11px;
 border:1px solid var(--line);background:#0f141d;font-size:13px;color:var(--dim)}
.romstate b{font-weight:650}
.romstate.ok{border-color:#1e4a33;background:#102a1c;color:#c8f0d6}
.romstate.bad{border-color:#5a2a2a;background:#2a1214;color:#ffd4d4}
.track{height:22px;background:#0a0e14;border:1px solid var(--line);border-radius:999px;
 position:relative;overflow:hidden;margin-top:6px}
.track>div{height:100%;width:0;background:linear-gradient(90deg,#1f9d55,var(--go));
 transition:width .45s;position:relative}
.track>div::after{content:"";position:absolute;right:-3px;top:-3px;bottom:-3px;width:16px;
 border-radius:999px;background:var(--go2);box-shadow:0 0 12px #37c96f88}
.track.idle>div::after{opacity:.35}
.pctlab{display:flex;justify-content:space-between;align-items:baseline;font:12px var(--mono);
 color:var(--dim);margin-top:10px}
.pctlab #pct{font-size:15px;color:var(--tx);font-weight:700}
ul{list-style:none;margin:14px 0 0;padding:0}
li{display:flex;gap:10px;align-items:baseline;padding:6px 8px;font-size:13px;color:var(--dim);border-radius:9px}
li b{color:var(--tx);font-weight:550}
li .ic{width:15px;text-align:center;flex:0 0 15px}
.done .ic{color:var(--go)}.run .ic{color:var(--blue)}.bad .ic{color:var(--err)}
.done{background:#122018aa}.run{background:#101b2bcc}
li .secs{margin-left:auto;font:11px var(--mono);color:#7f8ca3}
.credits{font-size:13px;color:var(--dim)}
.credits h3{margin:14px 0 6px;font-size:12px;letter-spacing:.08em;text-transform:uppercase;color:var(--tx)}
.credits ul{margin:0}
.credits li{display:list-item;padding:2px 0;background:none;list-style:disc}
.credits li b{font-weight:600}
.kv{display:grid;grid-template-columns:110px 1fr;gap:5px 12px;font:12.5px var(--mono);margin-top:14px}
.kv div:nth-child(odd){color:var(--dim)}
.kv div:nth-child(even){word-break:break-all}
pre{background:#0a0e14;border:1px solid var(--line);border-radius:10px;padding:12px;font:12px var(--mono);
 color:var(--dim);max-height:250px;overflow:auto;white-space:pre-wrap;word-break:break-all}
.hidden{display:none}
.note{font-size:12.5px;color:var(--dim);margin-top:10px}
code{font:12px var(--mono);color:#cfe3f5}
/* Het pad van de sleepbare map: markeerbaar in één klik, want kopiëren uit een
   verkenningsvenster is voor iemand die het zoekt juist het lastige deel. */
.path{flex:1;min-width:260px;font:12.5px var(--mono);background:#0a0e14;border:1px solid var(--line);
 border-radius:10px;padding:10px 12px;color:var(--tx);word-break:break-all;user-select:all}
.ok{color:var(--go)}.bad{color:var(--err)}.warn{color:var(--warn)}
.wide{margin-top:14px}
.hero{display:flex;gap:12px;align-items:center;flex-wrap:wrap}
.tag2{font-size:12px;letter-spacing:.08em;text-transform:uppercase;padding:5px 11px;border-radius:999px;
 background:#123021;color:var(--go);border:1px solid #1e4a33;font-weight:700}
.tag2.cand{background:#31250c;color:var(--warn);border-color:#5a4514}
ol.how{margin:12px 0 0;padding-left:20px;font-size:13.5px;color:var(--dim)}
ol.how li{display:list-item;padding:0;background:none;border-radius:0}
ol.how li+li{margin-top:4px}
ol.how b{color:var(--tx);font-weight:600}
.foot{margin-top:18px;padding:13px 15px;border:1px dashed var(--line);border-radius:14px;
 color:var(--dim);font-size:12.5px}
</style></head><body><div class="bg"></div><div class="wrap">
<header>
 <div class="ring"></div>
 <div><h1 class="metal">MARIOKART</h1><div class="wii">Wii &rarr; Switch</div></div>
 <p class="tag">native builder &middot; your own dump in, a <code>.nro</code> out<br>
 nothing leaves this computer</p>
</header>

<div class="cols">
 <section class="card" id="c1">
  <div class="title"><b>1</b> Choose your ROM</div>
  <div class="row">
   <input type="text" id="dump" value="__DUMP__" placeholder="path/to/Mario Kart Wii (PAL).wbfs">
   <button onclick="pick()">Browse&hellip;</button>
  </div>
  <div class="romstate" id="romstate"><b>Checking&hellip;</b></div>
  <div class="opts">
   <div class="sub">Options</div>
   <label class="opt"><input type="checkbox" id="full"> retranslate from scratch</label>
   <label class="opt"><input type="checkbox" id="zip"> also a zip for another SD card</label>
   <label class="opt"><input type="checkbox" id="free"> free the build cache (5 GiB back, next rebuild starts from zero)</label>
   <label class="opt"><input type="checkbox" id="keep"> keep everything (no cleanup at all)</label>
   <label class="opt hidden" id="allowrow"><input type="checkbox" id="allow"> use this ROM anyway</label>
  </div>
  <div class="note" id="disk">measuring disk space&hellip;</div>
  <div class="note">Supported: <code>.rvz .wbfs .iso .gcm</code> &mdash; your own retail dump.
   The builder checks the PAL revision itself.</div>
 </section>

 <section class="card" id="c2">
  <div class="title"><b>2</b> NRO Compiler</div>
  <div class="track idle" id="bar"><div id="fill"></div></div>
  <div class="pctlab"><span><span id="pct">0%</span> <span id="phase">Nothing yet.</span></span><span id="clock"></span></div>
  <div class="row" style="margin-top:6px">
   <button class="go" id="start" onclick="begin()">Start</button>
   <span class="note" id="startwhy" style="margin:0;flex:1;min-width:140px"></span>
  </div>
  <div class="pctlab"><span id="eta">first run translates the disc: about 15 min</span></div>
  <ul id="stages"></ul>
 </section>

 <aside class="card credits">
  <div class="title"><b>i</b> Not my code</div>
  The porting is other people&rsquo;s work; this app only builds, patches and tests it.
  <h3>Credits</h3>
  <ul>
   <li><b>WiiCompiled</b> &mdash; the recompilation engine</li>
   <li><b>DriftDroid / WiiCompiled-Switch</b> &mdash; runtime and Switch launcher</li>
   <li><b>aurora</b> &mdash; GameCube/Wii GX on WebGPU</li>
   <li><b>Dawn</b> + <b>libuam</b> &mdash; WebGPU to Deko3D</li>
   <li><b>nod</b> &mdash; RVZ/WBFS reading</li>
   <li><b>Nintendo</b> &mdash; the game and its data</li>
  </ul>
 </aside>
</div>

<div class="card wide hidden" id="sd">
 <div class="title"><b>&#8595;</b> Your SD card folder</div>
 <div class="row"><span class="path" id="sdpath">&nbsp;</span></div>
 <div class="row" style="margin-top:11px">
  <button class="go" id="sdopen" onclick="openp(SD.path,SD.switch)">Open it and show the switch folder</button>
  <button onclick="cpPath(SD.path)">Copy path</button>
  <span class="note" id="sdmsg" style="margin:0"></span>
 </div>
 <div class="note">This folder is the whole install: <code>switch\WiiCompiled\DATA</code> is the game
  and <code>switch\WiiCompiled-Switch\*.nro</code> is the program. Drag it onto the <b>root</b> of your
  SD card, or copy just the <code>switch</code> folder &mdash; it belongs next to <code>atmosphere</code>.
  <span id="sdmeta"></span></div>
</div>

<div class="card hidden wide" id="out">
 <div class="title"><b>3</b> Result</div>
 <div class="hero"><span class="tag2" id="verdict-tag">ready</span>
  <button onclick="openp(SD.path,SD.switch)">Open SD folder</button>
  <span id="outmeta" class="note" style="margin:0"></span></div>
 <ol class="how">
  <li>Copy the <b>switch</b> folder from the SD-card folder above to the <b>root</b> of your SD card, next to <code>atmosphere</code> &mdash; or drag the whole folder there.</li>
  <li>Start hbmenu on the Switch and pick <b>WiiCompiled-Switch</b>, with <b>title override / full memory</b>.</li>
  <li>The game data is already at its path, so there is no disc-picker to wait for.</li>
 </ol>
 <div class="kv" id="result"></div>
 <div class="note" id="verdict"></div>
 <div class="note" id="sweepline"></div>
</div>

<div class="card wide" id="clean">
 <div class="title">Clean up</div>
 <div class="row">
  <button id="claleft" onclick="cleanNow('leftovers')">Remove build leftovers</button>
  <span class="note" style="margin:0">only the throw-away parts: object files, translated
   shards and the extracted game data. The <code>.nro</code> and the SD folder stay.</span>
 </div>
 <div class="row">
  <button id="claall" onclick="cleanNow('everything')">Remove everything this app made</button>
  <span class="note" style="margin:0">the folder ends with only <code>MKWii-Builder.cmd</code>
   in it: the <code>.nro</code>, the SD folder, the source clone, the toolchain and the tooling
   all go. <b>Your own dump stays.</b></span>
 </div>
 <div class="note" id="cleanmsg"></div>
</div>

<div class="card hidden wide" id="errcard">
 <div class="title"><b>!</b> Error</div>
 <div id="errmsg" class="bad"></div>
 <pre id="errlog" class="hidden"></pre>
 <div class="row" style="margin-top:10px"><button onclick="toggleLog()">Show build log</button></div>
</div>

<div class="foot">The .nro contains recompiled Nintendo code: personal use only, do not share or sell it.
Built on a free software route to yashin-sh/WiiCompiled-Switch &mdash; the porting itself is other people&rsquo;s work.</div>
</div>
<script>window.__FULL__=__PRE_FULL__;window.__ZIP__=__PRE_ZIP__;</script>
<script>
const TOKEN="__TOKEN__";
let DELIV={},SD={},busy=false,timer=null,extLock=0;
const PRESET={full:!!Number(window.__FULL__||0),zip:!!Number(window.__ZIP__||0)};
const $=id=>document.getElementById(id);
async function api(p,body){const r=await fetch(`/api/${p}?token=${TOKEN}`,{method:'POST',
 headers:{'Content-Type':'application/json'},body:JSON.stringify(body||{})});return r.json();}
async function get(p){const r=await fetch(`/api/${p}?token=${TOKEN}`);
 return p=='log'?r.text():r.json();}
function pick(){api('pick').then(j=>{if(j.path){$('dump').value=j.path;checkRom();}});}
// Opruimen is de enige knop die wist wat er hier stond, dus twee dingen vooraf:
// er mag geen bouw lopen en de gebruiker moet zien wát er weg gaat. "everything"
// laat alleen MKWii-Builder.cmd over; de dump van de gebruiker blijft altijd liggen.
async function cleanNow(level){
 const all=level=='everything';
 if(busy){$('cleanmsg').innerHTML='<span class="bad">a build is running</span> &mdash; wait for it, then clean up.';return;}
 if(!confirm(all
  ? 'Remove everything this app made?\n\nThe .nro, the drag-and-drop SD folder, the source clone, the toolchain and the tooling all go. Your own dump stays. This cannot be undone.'
  : 'Remove the temporary build files?\n\nThe next rebuild then translates and compiles everything again, so it takes the full time.')) return;
 const b=$('claleft'),a=$('claall');
 b.disabled=a.disabled=true;
 $('cleanmsg').innerHTML='cleaning&hellip; a folder of several GiB takes a minute or two.';
 const j=await api('clean',{level});
 $('cleanmsg').innerHTML=(j.ok?'<span class="ok">done:</span> ':'<span class="bad">stopped:</span> ')
  +esc(j.msg||'').replace(/\n/g,' &middot; ');
 if(j.ok&&all)$('cleanmsg').innerHTML+='<br>only <code>MKWii-Builder.cmd</code> is left here &mdash; close this window and double-click that file whenever you want to build again.';
 else b.disabled=a.disabled=false;
}
// De ROM-keuze is de eerste drempel, niet de laatste: dit leest alleen de disc-kop,
// de pin-controle doet de motor zelf nog vóór het uitpakken.
let romTimer=null,romOk=false;
function checkRom(){
 const v=$('dump').value.trim();
 clearTimeout(romTimer);
 if(!v){romOk=false;setRom('','No ROM chosen','Pick your own Wii dump with Browse.');gate('');return;}
 setRom('','Reading the disc header&hellip;','');
 romTimer=setTimeout(()=>api('check',{path:v}).then(j=>{
  const size=j.size?(gib(j.size)+' GiB &middot; '):'';
  if(j.state=='right'){romOk=true;setRom('ok','Right ROM',size+esc(j.msg));gate('');}
  else if(j.state=='wrong'){romOk=false;setRom('bad','Different region',size+esc(j.msg));
   $('allowrow').classList.remove('hidden');gate('tick use-this-ROM-anyway to try it');}
  else{romOk=true;setRom('',size+(j.state=='busy'?'Build in progress &middot; ':'Cannot confirm: ')+esc(j.msg));gate('');
   // 'busy' is een momentopname: straks, als de bouw klaar is, wijst de kop
   // zich vanzelf. Dus over tien seconden opnieuw, zonder de gebruiker te laten klikken.
   if(j.state=='busy'){clearTimeout(romTimer);romTimer=setTimeout(checkRom,10000);}}
 }).catch(()=>{romOk=true;setRom('','Cannot confirm','the local check did not answer; the build checks the pins itself');gate('');}),350);
}
function setRom(cls,strong,detail){const e=$('romstate');e.className='romstate'+(cls?' '+cls:'');
 e.innerHTML='<b>'+strong+'</b>'+(detail?'<span>'+detail+'</span>':'');}
let romWhy='';
function gate(why){if(why!==undefined)romWhy=why;
 // Eén plek die de knop-toestand bepaalt, op volgorde van belangrijkheid:
 // een bouw die al draagt, een slot van de motor, en pas dan de ROM-keuze.
 // Zo hoeft geen enkele aanroep een reden te onthouden of te raden.
 const b=$('start');
 b.disabled=busy||extLock||(!romOk&&!$('allow').checked);
 $('startwhy').textContent=!b.disabled?'':
  busy?'building':extLock?`engine is building elsewhere (${Math.round(extLock/60)} min) - wait for it`
  :(romWhy||'choose a ROM first');}
$('allow').addEventListener('change',()=>gate());
$('dump').addEventListener('input',()=>{$('allowrow').classList.add('hidden');$('allow').checked=false;checkRom();});
function openp(p,sel){if(!p){$('sdmsg').innerHTML='<span class="warn">no folder here yet</span> &mdash; it appears after a build.';return;}
 $('sdmsg').textContent='opening…';
 api('open',{path:p,select:sel||''}).then(j=>{
  $('sdmsg').innerHTML=j.ok
   ?'<span class="ok">opened</span>'+(sel?' &mdash; the highlighted <code>switch</code> folder is what goes on your SD card':'')
   :`<span class="bad">this window could not open it</span> &mdash; copy the path above into your file manager: it is there.`;
 }).catch(()=>$('sdmsg').innerHTML='<span class="bad">the app did not answer</span> &mdash; the folder is still at the path above.');}
function cpPath(p){if(!p)return;
 const ok=()=>{$('sdmsg').innerHTML='<span class="ok">path copied</span> &mdash; paste it in any file-manager address bar.';};
 if(navigator.clipboard&&navigator.clipboard.writeText){navigator.clipboard.writeText(p).then(ok,()=>selPath());}
 else selPath();}
// Het pad in één klik geselecteerd neerzetten is het valbareback voor browsers
// zonder clipboard-rechten: de gebruiker drukt dan zelf Ctrl+C.
function selPath(){const r=document.createRange();r.selectNodeContents($('sdpath'));
 const s=getSelection();s.removeAllRanges();s.addRange(r);$('sdmsg').innerHTML='<b>the path is selected</b> &mdash; press Ctrl+C.';}
// De SD-kaart is het enige deel van dit venster dat nog uren later nut heeft: de
// map staat dan al lang op disk, ook zonder dat deze sessie hem bouwde. Daarom
// hangt hij aan de state-poll en niet alleen aan het Result.
function renderSd(d){SD=d||{};const c=$('sd'),open=$('sdopen');
 if(!SD.found){
  // Na een opruimactie of op een eerste run: de kaart blijft staan met de plek
  // waar de map komt, want "straks hier" is bruikbaarder dan een vacuüm.
  if(!SD.pending){c.classList.add('hidden');return;}
  c.classList.remove('hidden');open.classList.add('hidden');
  $('sdpath').textContent=SD.path||'';
  $('sdmeta').innerHTML='<span class="note">not created yet &mdash; a build puts it here</span>';
  $('sdmsg').textContent='';return;
 }
 open.classList.remove('hidden');c.classList.remove('hidden');
 $('sdpath').textContent=SD.path;
 const bits=[];
 if(SD.files)bits.push(`${esc(String(SD.files))} files`);
 if(SD.bytes)bits.push(`${(Number(SD.bytes)/2**30).toFixed(2)} GiB`);
 if(SD.zip)bits.push('zip: '+esc(SD.zip));
 $('sdmeta').innerHTML=bits.length?'<span class="note">'+esc(bits.join('  ·  '))+'</span>':'';
}
function begin(){
 const body={dump:$('dump').value.trim(),full:$('full').checked,zip:$('zip').checked,free:$('free').checked,keep:$('keep').checked,allow:$('allow').checked};
 if(body.dump && !/\.(rvz|wbfs|iso|gcm)$/i.test(body.dump)){
  if(!confirm("That does not look like a Wii disc image. Try anyway?"))return;}
 DELIV={};busy=true;$('out').classList.add('hidden');gate();
 $('errcard').classList.add('hidden');boot();tick();
 api('start',body).then(j=>{if(j.error){busy=false;gate('');showErr(j.error);}});
 if(!timer)timer=setInterval(tick,900);
}
function gib(b){return (b/1073741824).toLocaleString('en-US',{maximumFractionDigits:1});}
// De schatting staat er al vóór iemand op Start drukt: wat eenmalig bijkomt, wat
// de bouw tijdelijk kost (en ná afloop weer weg is), en wat er daadwerkelijk vrij
// is op deze schijf. Te weinig ruimte tonen is erger dan te veel: dus conservatief.
function disk(){get('disk').then(d=>{
 const p={};(d.parts||[]).forEach(x=>p[x.key]=x);
 const once=d.once>0?`one-off ≈ ${d.once} GiB (toolchain + renderstack, fetched once) · `:'';
 let txt=`${once}temporary ≈ ${d.temp} GiB (the unpacked game data, deleted when the build is done) · build cache ≈ ${d.cache} GiB (objects and shards — these stay on purpose, that is what makes the next rebuild about a minute; tick 'free the build cache', or use Clean up, to reclaim them) · product ≈ ${d.product} GiB — free on this disk: ${gib(d.free)} GiB`;
 $('disk').innerHTML=d.enough?esc(txt):`<span class="bad">${esc(txt)} — that is not enough. Free up space or point the workspace at a larger disk.</span>`;
}).catch(()=>{});}
const LABEL={provision:'Fetching the toolchain (first run only)',env:'Environment (devkitA64 or Docker)',src:'Source at the pinned ref',
 inputs:'Finding and unpacking your dump',build:'Translating and compiling',
 verify:'Checking the .nro',deliver:'Filling the drag-and-drop SD folder',sweep:'Removing temporary files'};
function reusedBuild(s){return (s.stages.build||[]).some(e=>e.state=='ok'&&/nothing changed since/.test(e.msg||''));}
// 'nog ~8 min' is voor iemand die voor het eerst wacht bruikbaarder dan een kaal
// percentage - en de bron van dat getal erbij, zodat blijkt of het een meting op
// deze machine is of de eerste voorspelling.
// De motor zegt het zelf als hij niets hoefde te doen; dat letterlijk melden is
// eerlijker dan de schatter laten praten over 'een deel van de bouw'.
// Stilstand: wat er nú op deze machine staat geeft de zin, niet een getal uit een
// tabel. Een .nro met zijn twee cachebomen ernaast is seconden werk; staat er
// alleen een cache, dan is een herbouwen ongeveer een minuut; is er niets, dan is
// een volledige bouw minuten werk en wordt dat ook zo gezegd.
function etaText(s,et){
 if(busy){
  if(et&&et.left!=null) return `<b>est ${fmt(et.left)} left</b> <span class="note">of ~${fmt(et.total)} · ${(et.basis||'').toLowerCase()}${et.detail?' · '+esc(et.detail):''}</span>`;
  return (et&&et.note)?esc(et.note):'estimating, give it a moment…';
 }
 if(s.exit==0){
  if(reusedBuild(s)) return '<b>nothing needed rebuilding</b> <span class="note">this .nro was already here and nothing that feeds it changed &mdash; tick &ldquo;retranslate from scratch&rdquo; to force a new one</span>';
  return `finished - ${esc((et&&et.detail)||'see step 3 below')}${et&&et.note?' · '+esc(et.note):''}`;
 }
 const w=s.warm||{};
 if(w.reusable) return `<b>about 10 s if nothing changed</b> <span class="note">the build cache and its .nro are both on this machine: the engine re-hashes sources, game data and translated shards and rebuilds only what moved &mdash; a re-link is about a minute, a forced retranslate about 15${w.sha?' · current .nro '+esc(w.sha):''}</span>`;
 if(!et) return 'about 15 min for a full rebuild, about a minute for a re-link, seconds if nothing changed';
 if(w.cache) return `<b>about a minute</b> <span class="note">the build cache is here, but no .nro is recorded as built from it, so a re-link is likely and a full rebuild up to ${fmt(et.total)}${et.ahead&&et.ahead.length?' &middot; first run: '+esc(et.ahead.join(' · ')):''}</span>`;
 return `<b>up to ${fmt(et.total)}</b> <span class="note">${et.measured?'measured on your last build here':'cold rebuild, from the reference figure'}${et.ahead&&et.ahead.length?' · first run: '+esc(et.ahead.join(' · ')):' · much less once this machine has a build cache'}</span>`;
}
function tick(){get('state').then(s=>{
 if(s.sd)renderSd(s.sd);
 const ev=s.elapsed||0;$('clock').textContent=busy?fmt(ev):'';
 // Een bouw die elders draagt heeft een slot op de engine: laat Start niet toe
 // dat hier een tweede bovenop zetten, ook al ziet deze UI die bouw niet.
 extLock=(!busy&&s.engine_lock!=null&&s.engine_lock<21600)?s.engine_lock:0;
 let steps=s.order.map(n=>({n,evs:s.stages[n]||[]}));
 // De balk en de tijdschatting komen uit één bron: de server rekent met de
 // mijlpalen die de motor zelf meldt (en, tijdens het compileren, met het
 // percentage dat ninja afgeeft). De gewichtetabel hieronder is alleen een
 // terugval voor het geval die bron nog niets kan melden.
 const et=s.eta||null;
 let done=0;
 const w={provision:20,env:3,src:3,inputs:6,build:48,verify:8,deliver:9,sweep:3};
 steps.forEach(st=>{const name=st.n,evs=st.evs;
  const last=evs[evs.length-1]||{};
  const ok=evs.some(x=>x.state=='ok');
  if(ok){done+=w[name]||6;return;}
  if(name=='build'&&s.progress){
   const p=parseInt(s.progress.pct||'0',10);
   if(!isNaN(p))done+=(w.build||62)*(Math.min(p,100)/100)*0.9;
  }});
 const tot=Object.values(w).reduce((a,b)=>a+b,0);
 let pct=(et&&et.pct)?et.pct:Math.min(100,Math.round(100*done/tot));
 if(!busy&&s.exit==0)pct=100;
 $('fill').style.width=pct+'%';
 $('pct').textContent=pct+'%';
 $('bar').classList.toggle('idle',!busy);
 $('c1').classList.toggle('pending',busy);
 $('c2').classList.toggle('on',busy);
 let ph='';
 if(s.progress&&busy){ph=`<b>${esc(s.progress.phase||'building')}</b> · ${esc(s.progress.msg||'')}`;}
 $('phase').innerHTML=busy?(ph||'starting…')
  :(extLock?`engine is building elsewhere (${Math.round(extLock/60)} min)`
  :(s.exit==0?'done':s.exit!=null?'stopped':'Nothing yet.'));
 gate();
 $('eta').innerHTML=etaText(s,et);
 $('stages').innerHTML=steps.map(st=>{
  const evs=st.evs,last=evs[evs.length-1]||{};
  const ok=evs.some(e=>e.state=='ok');
  const cls=ok?'done':(st.n&&last.state=='start'?'run':'');
  const ic=ok?'✓':(cls=='run'?'●':'·');
  return `<li class="${cls}"><span class="ic">${ic}</span><b>${esc(LABEL[st.n]||st.n)}</b>
   <span>— ${esc(last.msg||'')}</span>${last.secs?` <span style="margin-left:auto">${esc(last.secs)}s</span>`:''}</li>`;
 }).join('');
 // De .nro is af en gecontroleerd vóórdat de sleepmap vol is: die kaart eerder
 // tonen dan de map er staat, maakt dat iemand "klaar" leest terwijl er nog
 // 2,6 GiB game-bestanden gekopieerd wordt. Dus: resultaat pas als de lever-stap
 // haar cijfers meldt (of als de motor is afgemeld), en zolang het wachten is
 // zegt de balk zelf wat er nog gebeurt.
 const delivered = !!(s.deliver && (s.deliver.files || s.deliver.map || s.deliver.zip));
 if(s.result&&busy&&!delivered){
  $('eta').innerHTML='the .nro is built and checked &mdash; <b>filling the SD folder now</b>'
   +' <span class="note">2.6 GiB of game files, this is the last step before the cleanup</span>';
 }
 if(s.result&&(!busy||delivered)){DELIV=Object.assign(DELIV,s.deliver||{});showResult(s.result,DELIV);}
 if(s.sweep){const b=Number(s.sweep.freed||0),kc=Number(s.sweep.kept_cache||0),cb=Number(s.sweep.cache_bytes||0);
  $('sweepline').innerHTML = Number(s.sweep.kept||0)
   ?'<span class="warn">nothing cleaned up</span> &mdash; as requested, the extract and the build cache both stayed.'
   :(kc===1
     ?(b>0?`<span class="ok">cleaned up:</span> ${gib(b)} GiB removed (${esc(s.sweep.removed||'')}). `
            :'<span class="ok">nothing to remove:</span> the game data was already gone. ')
      +`<span class="note">the ${gib(cb)} GiB build cache stays on purpose: the next rebuild takes about a minute instead of a quarter of an hour. Tick 'free the build cache', or use Clean up, to give that space back.</span>`
     :`<span class="ok">cleaned up:</span> ${gib(b)} GiB of temporary files removed (${esc(s.sweep.removed||'')}).`);}
 if(s.error){busy=false;gate('');showErr(`${s.error.stage||''}: ${s.error.msg||''}`,s.log);}
 if(!busy)return;
 if(s.exit!=null){busy=false;gate();disk();
  // De motor meldt zélf waarom hij stopte (een error-regel). 'exit code 1' over
  // die tekst heen zetten is precies het bericht waar niemand iets aan heeft.
  if(s.exit!=0&&!s.error){showErr('The build failed (exit code '+s.exit+').');}
  clearInterval(timer);timer=null;}
}).catch(()=>{});}
function showResult(r,dl){
 $('out').classList.remove('hidden');$('out').classList.add('on');
 $('c1').classList.remove('pending');$('c2').classList.remove('on');
 const m=(dl&&dl.map_native)||(dl&&dl.map)||(SD&&SD.path);
 DELIV=dl||{};
 $('outmeta').textContent=m?`${(dl.files||'—')} files · ${(Number(dl.bytes||0)/2**30).toFixed(2)} GiB`:(r.nro_native||r.nro||'');
 const rows=[['.nro',r.nro_native||r.nro],['size',(Number(r.bytes||0)/2**20).toFixed(1)+' MiB'],
  ['sha256',r.sha256],['runtime',r.seconds+' s']];
 if(dl&&dl.zip)rows.push(['zip',dl.zip_native||dl.zip]);
 if(m)rows.push(['SD folder',m]);
 $('result').innerHTML=rows.map(([k,v])=>`<div>${k}</div><div>${esc(String(v))}</div>`).join('');
 const match=r.match===true||r.match=='true';
 const tag=$('verdict-tag');tag.textContent=match?'ready to install':'needs a console test';
 tag.className='tag'+(match?'':' cand');
 $('verdict').innerHTML=match
  ?`<span class="ok">MATCH</span> with the build that was found playable on your Switch (${esc(r.expected)}).`
  :`<span class="warn">NEW CANDIDATE</span> — the expectation was ${esc(r.expected)}.`
   +' A rebuild is never bit-identical (the link layout shifts), so test this file on the console first.';
}
function showErr(msg){$('errcard').classList.remove('hidden');$('errmsg').textContent=msg;
 $('c1').classList.remove('pending');$('c2').classList.remove('on');$('bar').classList.add('idle');
 $('eta').textContent='fix the cause above, then press Start again';}
function toggleLog(){const p=$('errlog');
 if(p.classList.contains('hidden')){p.textContent='';get('log').then(t=>p.textContent=t);p.classList.remove('hidden');}
 else p.classList.add('hidden');}
function fmt(s){s=Math.round(s);const m=Math.floor(s/60);return m?`${m} min ${String(s%60).padStart(2,'0')} s`:`${s} s`;}
function boot(){if(PRESET.full)$("full").checked=true;if(PRESET.zip)$("zip").checked=true;}
function esc(t){return String(t==null?'':t).replace(/[&<>"]/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]));}
// Direct één keer tekenen en daarna blijven polling: een herladen tabblad of een
// tweede venster toont meteen de stand van de bouw die al draait.
boot();tick();disk();checkRom();
if(!timer)timer=setInterval(tick,1400);
</script></body></html>
"""


def main():
    ap = argparse.ArgumentParser(description="One-click builder UI (localhost page).")
    ap.add_argument("--port", type=int, default=0)
    ap.add_argument("--no-browser", action="store_true", help="do not open a browser (for tests)")
    ap.add_argument("--dump", default="", help="dump path to fill in up front")
    ap.add_argument("--full", action="store_true", help="pre-tick 'retranslate'")
    ap.add_argument("--zip", action="store_true", help="pre-tick 'also a zip'")
    args, extra = ap.parse_known_args()
    # Onbekende opties zijn motor-opties (--jobs 8, --no-map, --expect …): die gaan mee
    # naar elke bouw die uit dit venster wordt gestart, zodat de snelkoppelingen en
    # de terminal dezelfde taal spreken.
    EXTRA.extend(extra)

    if not os.path.isfile(ENGINE):
        print(f"Error: engine not found: {ENGINE}", file=sys.stderr)
        return 1
    if not find_bash():
        print("Error: bash not found. On Windows: install Git for Windows.", file=sys.stderr)
        return 1
    global SERVER, PRESET_DUMP, PRE_FULL, PRE_ZIP
    PRESET_DUMP = args.dump.replace('"', "")
    PRE_FULL = "1" if args.full else "0"
    PRE_ZIP = "1" if args.zip else "0"
    Handler.token = secrets.token_hex(10)
    SERVER = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    port = SERVER.server_address[1]
    url = f"http://127.0.0.1:{port}/?t={Handler.token}"
    print(f"  builder UI: {url}")
    print("  (to stop: Ctrl-C, or the button in the page)")
    if not args.no_browser:
        threading.Timer(0.4, lambda: webbrowser.open(url)).start()
    try:
        SERVER.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        SERVER.server_close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
