#!/usr/bin/env python3
"""Zet dezelfde SD-layout die make-sd-zip.py in een zip stopt neer als een map.

Waarom een map: de ontvanger sleept `switch/` rechtstreeks op zijn SD-kaart in
plaats van een zip van 2,8 GB uit te pakken. De argumenten zijn identiek aan
make-sd-zip.py (--file/--tree/--text/--marker), zodat pack-sd.sh dezelfde
opbouwlijst voor beide afleveringen kan gebruiken en de twee niet kunnen
verschillen.

Waar mogelijk worden hardlinks gebruikt in plaats van kopiëren: de game-data is
2,6 GB en een kopie kost seconden tot minuten. Een hardlink is byte-identiek en
verdwijnt niet halverwege; de bron (discs/extract) blijft onaangeroerd.
"""

import argparse
import os
import shutil
import sys


def place(src, dst):
    os.makedirs(os.path.dirname(dst) or ".", exist_ok=True)
    if os.path.lexists(dst):
        os.remove(dst)
    try:
        os.link(src, dst)
        return "hardlink"
    except OSError:
        shutil.copy2(src, dst)
        return "kopie"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("out", help="doelmap waar 'switch/' in ontstaat")
    ap.add_argument("--file", nargs=2, action="append", default=[], metavar=("ARC", "SRC"))
    ap.add_argument("--tree", nargs=2, action="append", default=[], metavar=("ARC", "SRC"))
    ap.add_argument("--text", nargs=2, action="append", default=[], metavar=("ARC", "TEKST"))
    ap.add_argument("--marker", default="switch/WiiCompiled/DATA/.import_complete")
    args = ap.parse_args()

    items = list(args.file)
    for arc, src in args.tree:
        if not os.path.isdir(src):
            print(f"ontbreekt (map): {src}", file=sys.stderr)
            return 1
        for root, _, names in os.walk(src):
            for name in sorted(names):
                full = os.path.join(root, name)
                rel = os.path.relpath(full, src).replace(os.sep, "/")
                items.append((f"{arc}/{rel}", full))

    missing = [src for _, src in items if not os.path.isfile(src)]
    if missing:
        for path in missing[:10]:
            print(f"ontbreekt: {path}", file=sys.stderr)
        print(f"({len(missing)} bestanden ontbreken)", file=sys.stderr)
        return 1

    if os.path.isdir(args.out):
        shutil.rmtree(args.out)
    os.makedirs(args.out, exist_ok=True)

    linked = copied = 0
    total = 0
    for arc, src in items:
        mode = place(src, os.path.join(args.out, arc.replace("/", os.sep)))
        linked += mode == "hardlink"
        copied += mode != "hardlink"
        total += os.path.getsize(src)
    if args.marker:
        path = os.path.join(args.out, args.marker.replace("/", os.sep))
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w", encoding="utf-8", newline="\n") as fh:
            fh.write("channel=beta-switch\nformat=1\n")
        items_marker = 1
    else:
        items_marker = 0
    for arc, text in args.text:
        path = os.path.join(args.out, arc.replace("/", os.sep))
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w", encoding="utf-8", newline="\n") as fh:
            fh.write(text if text.endswith("\n") else text + "\n")

    print(
        f"   {len(items) + items_marker + len(args.text)} bestanden, "
        f"{total / 2**30:.2f} GiB ({linked} hardlinks, {copied} kopieën)"
    )
    print(f"   map: {os.path.abspath(args.out)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
