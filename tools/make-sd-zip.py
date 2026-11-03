#!/usr/bin/env python3
"""Pakt een SD-layout .zip zonder de 2,6 GB game-data naar een staging-map te kopiëren.

Elke invoer koppelt een pad in de zip (arc) aan een bron op schijf (src), zodat de
uiteindelijke boom direct conforms de app-verwachtingen is zonder tussenstap.
"""

import argparse
import os
import sys
import zipfile

MARKER = "channel=beta-switch\nformat=1\n"


def walk(arc, src):
    if os.path.isdir(src):
        for root, _, names in os.walk(src):
            for name in sorted(names):
                full = os.path.join(root, name)
                rel = os.path.relpath(full, src).replace(os.sep, "/")
                yield f"{arc}/{rel}", full
    else:
        yield arc, src


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("out")
    ap.add_argument("--file", nargs=2, action="append", default=[], metavar=("ARC", "SRC"))
    ap.add_argument("--tree", nargs=2, action="append", default=[], metavar=("ARC", "SRC"))
    ap.add_argument("--text", nargs=2, action="append", default=[], metavar=("ARC", "TEXT"))
    ap.add_argument("--compress", choices=["deflate", "store"], default="deflate")
    ap.add_argument("--marker", default="switch/WiiCompiled/DATA/.import_complete")
    args = ap.parse_args()

    items = []
    for arc, src in args.file:
        items.append((arc, src))
    for arc, src in args.tree:
        items.extend(walk(arc, src))

    missing = [src for _, src in items if not os.path.isfile(src)]
    if missing:
        for path in missing:
            print(f"ontbreekt: {path}", file=sys.stderr)
        return 1

    total = sum(os.path.getsize(src) for _, src in items)
    mode = zipfile.ZIP_DEFLATED if args.compress == "deflate" else zipfile.ZIP_STORED
    os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
    if os.path.exists(args.out):
        os.remove(args.out)

    done = 0
    packed = 0
    kwargs = {"compresslevel": 1} if args.compress == "deflate" else {}
    with zipfile.ZipFile(args.out, "w", mode, **kwargs) as zf:
        if args.marker:
            zf.writestr(args.marker, MARKER)
        for arc, src in items:
            zf.write(src, arc)
            done += os.path.getsize(src)
            if total > 2**26 and done * 50 // total != (done - os.path.getsize(src)) * 50 // total:
                print(f"   ... {done // (1024 * 1024)} / {total // (1024 * 1024)} MiB")
        for arc, text in args.text:
            zf.writestr(arc, text if text.endswith("\n") else text + "\n")

    packed = os.path.getsize(args.out)
    print(
        f"   {len(items) + len(args.text) + (1 if args.marker else 0)} entries, "
        f"{total / 2**30:.2f} GiB bron -> {packed / 2**30:.2f} GiB zip"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
