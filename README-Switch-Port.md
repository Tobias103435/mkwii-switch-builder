# Mario Kart Wii on the Nintendo Switch — my private test build

This is a **private experiment**. Not an official product, not an official release.

## Important: the credits

**I wrote essentially no code for this port.** The entire technical achievement —
statically recompiling Mario Kart Wii to native ARM64, the graphics translation layer,
and the Switch backend — is other people's work, which I only built on top of and
tested:

- **WiiCompiled** — the static-recompilation engine that converts MKWii (PPC) into
  native C++/ARM64. Without it this port does not exist.
- **DriftDroid / WiiCompiled-Switch** — the runtime, the Switch launcher, the disc
  import and the aarch64 paths I built and ran here.
- **aurora** — the GameCube/Wii GX compatibility layer on WebGPU.
- **Dawn (Google)** and **averne/libuam** — WebGPU → **Deko3D** on Switch.
- **triniblo / encounter (nod)** — RVZ/WBFS reading on the PC side.
- **Nintendo** — Mario Kart Wii itself. The game and its data remain their property.

My contribution is limited to: getting the existing source to **link into a working
Switch build** (a few small integration fixes), a small packaging script that zips the
result into the right SD layout, pushing it to my own console, and testing it. That is
integration, glue and testing work — not porting work.

## What works

On a modded Switch (atmosphère / homebrew, launched via hbmenu with
**title override / full memory**) the game boots and you can race. Two things that
used to be listed as open defects are now explained and closed on hardware: vehicles
rendering as black silhouettes (that is a cold pipeline cache — SQLite refused to open
one at all, see the section below) and a stutter every ~5 seconds (that was Dawn's
frame-dumping diagnostic, now compiled out of the shipped render package). No measured
FPS comparison against Dolphin NX on the same console yet — and none will be quoted
from any run made while that diagnostic was still on, because it was measuring itself
into the frame time.

### The caches and the hitch (both found on the console, not in the code)

- **`Cache/dawn_cache.db` and `Cache/pipeline_cache.db` could never be opened.**
  SQLite's Horizon build keeps `SQLITE_DEFAULT_UNIX_VFS="unix-none"`, and that VFS
  answers every open with `SQLITE_CANTOPEN`. So every boot recompiled every shader:
  that is the black-silhouette start, not a GPU defect. The port now registers its
  SDL-backed VFS as the default before `aurora_initialize`. Two traps on the way
  there, both read out of the amalgamation rather than guessed: reporting
  `SQLITE_IOCAP_IMMUTABLE` makes SQLite force the pager read-only (`sqlite3.c:63907`),
  and read-past-EOF on Horizon returns `EIO`, while `pager.c` tolerates
  **only** `SQLITE_IOERR_SHORT_READ` on its 16-byte change counter — so the VFS clamps
  reads past its own known size and answers that. Caches verified on hardware: 368,640
  B and 561,152 B written, reused on the next boot.
- **The ~5 s hitch was `kDeko3dDiag`**, a bring-up instrument in Dawn's Deko3D backend:
  every 300th presented frame it runs `dkQueueWaitIdle` and then reads ~4 million
  pixels on the CPU. It counts frames, not seconds, which is why it also fired in
  menus and while paused. `tools/build-quiet-dawn.sh` turns it into a build-time macro
  (default off), rebuilds the archive with the same container compiler that made the
  original, and records the delta hash in the package receipt — so the quiet bytes are
  a property of the distributed package, not of one developer's machine.

## Relationship to upstream (measured 2026-11-05)

A maintainer reading this should be able to answer three questions in two minutes:
what are you building on, is it reproducible, and what is actually yours.

**What we build on.** The runtime comes from DriftDroid's `android-port` branch at
`8b33d310` (2026-10-09), pinned by the builder. That branch has moved since: 21 commits
ahead, top `d912de32` (2026-11-04, "play the game disc's Wii Menu banner while the game
starts"). The main repository `yashin-sh/WiiCompiled-Switch` has not moved (`b851db9`,
2026-10-14). We stay on the pin on purpose — every other input (Dawn, libuam, nod, the
disc revision) is pinned too, and a moving pin makes a provenance receipt meaningless.

**They fixed the frame dumper themselves, and that is worth saying first.**
`ce83b2cf` (2026-11-03) — "Switch: turn off the deko3d bring-up diagnostics (periodic GPU
stall every 300 frames)" — sets `kDeko3dDiag = false` in
`aurora-main/cmake/patches/dawn-nintendo-switch-platform.patch` (line 2920). Our
`tools/patches/dawn-diagnostics-off.diff` reaches the same quiet state for the older pin
this builder still uses, and turns it into a build-time macro instead of a hard-coded
value; on their current HEAD the effect is already upstream, so our delta there is
smaller than the story above makes it sound.

**What is not upstream.** A *writable* cache VFS. At their current HEAD,
`aurora-main/lib/gfx/pipeline_cache.cpp` refuses writes by design: `sdl_vfs_open()`
(line 230) returns `SQLITE_CANTOPEN` for any request carrying
`SQLITE_OPEN_READWRITE`, `xWrite` (157) and `xTruncate` (159) return `SQLITE_READONLY`,
`xDelete` (246) likewise, and the bundled seed is opened
`SQLITE_OPEN_READONLY | SQLITE_OPEN_PRIVATECACHE` (606). So on their code the caches can
be read but never created or updated — every boot recompiles every shader, which is the
black-vehicles symptom. The fix here is `tools/patches/switch-cache-vfs.patch` (16 hunks
over `aurora-main/include/aurora/gfx.h`, `pipeline_cache.cpp` and
`runtime/src/main.cpp`, 21.820 B), applied automatically by `tools/patch-workdir.sh`.

**Honest port state against their HEAD.** A `patch -p1 --dry-run --forward` of that file
against a tree of exactly those three files at `d912de32` (measured 2026-11-05): 15 of
the 16 hunks land — 12 of the 13 in `pipeline_cache.cpp`, with **one failing**;
`aurora-main/include/aurora/gfx.h` lands only with fuzz 2; and the second hunk in
`runtime/src/main.cpp` lands with fuzz 2 at a 43-line offset. The failing one is our
export block: it expects `aurora_get_queued_pipeline_count()` to be the last function,
and they have since inserted `aurora_is_pipeline_prewarm_active()` there. So this patch
does not yet apply cleanly to their branch. Re-porting it is our job, and until it is
done this page says so rather than implying the work is finished.

**Reproducibility of the numbers quoted above.** The cache figures are file sizes on the
card, not benchmarks: after a clean exit from build `5e1fa104…`,
`sdmc:/switch/WiiCompiled/Cache/dawn_cache.db` is 368.640 B and `pipeline_cache.db`
561.152 B; the same two files were 0 B (with `Failed to create schema table: disk I/O
error` in `stderr.txt`) in builds `0bf292ee…`/`09b1d0f0…`, and did not exist at all
before the VFS was registered. Both are re-measurable with any FTP server on the console.
Per upstream's own testing rule — behaviour claims need a real-hardware run with device
and build type — the single device behind all of this is one Switch V2 on HOS 21.1.0
with an **overclocked CPU**. That is why this repository quotes no FPS and no
"faster than": on an OC'd console those numbers would not be comparable to anything.

**And one rule we follow from their `CONTRIBUTING.md`:** issue and PR text must be written
by a human, not generated. So this repository deliberately ships no canned issue body,
no template and no suggested replies for the upstream thread — the discussion there is
the author's own words, or it does not happen.

## Legal — read before you upload anything

- **NEVER publish the built `.nro`.** It contains translated MKWii code (= Nintendo
  copyright). Not even "with my own dump inside it".
- **Never put a dump or game files in a repo:** `.wbfs`/`.rvz`/`.iso`, `main.dol`,
  `StaticR.rel`, and no `prod.keys`/`title.keys`.
- **What you may do:** keep it locally, use it on your **own** console with your
  **own** legally obtained dump, and share your own scripts/patches/notes with proper
  credits + a matching license.
- Want to share something? Share only the **method** ("build it yourself, bring your
  own dump"), never the compiled binary.

## Build it yourself (your own dump required)

1. Your own **PAL Mario Kart Wii (RMCP01)** dump, as `.rvz`/`.wbfs`.
2. `tools/build-nro.sh` (or the double-click entries below) drives the upstream
   scripts: translates, builds the Deko3D stack, packages a `.nro`. Needs a devkitA64
   install; Docker is only a fallback backend.
3. Result: `local-product/native-deko3d/WiiCompiled-Switch-native-deko3d.nro`
   (this build: SHA-256 `a58e4bdf781ea7363cc20376d5a7ed64ae0de89bb4ace6d56749c788502fef78`).
4. Put the `.nro` in `sdmc:/switch/`, place your `.wbfs` next to it, launch with
   title override / full memory. The app extracts the `.wbfs` itself.

### One click: the builder app

**Double-click `MKWii-Builder.cmd`** on Windows or **`MKWii-Builder.command`** on
macOS/Linux — either one is the whole builder in a single file (see *Sharing it* below);
or run `bash tools/build-nro.sh` from a clone. You get a window in your browser: pick
your ROM, press Start, watch the progress and the estimate of what is left. That same
entry point finds (or installs) a devkitA64 toolchain, extracts and SHA-checks your
dump, translates, compiles, packages the `.nro` and prints the hash — compared against
the hash that is known to work on hardware. **Docker is not required any more**; it stays
available as a fallback backend (`--docker`) for machines that have it and no toolchain.

The estimate is a measurement, not a guess. Before Start it promises what this machine
took last time (`logs/eta-history.json` holds the last twelve finished builds, seconds
only — no paths, no hashes); with no history yet it falls back to the per-stage baseline
measured on a real run. While building, the engine's own milestones set the remaining
time, and during the compile the percentage ninja reports is extrapolated over the rest
of that step, scaled by how fast this machine turns out to be against the baseline. If
the numbers stop agreeing — a step running far past its usual length with no percentage
to work from — the page says it has no honest number instead of inventing one. After the
run it reports what your build actually cost and remembers it. When nothing is running
the page stops quoting a table and reads the machine instead: if the `.nro` and both
build caches are sitting here it says *about 10 s if nothing changed*, if only the caches
are here it says *about a minute*, and with nothing on disk it quotes the full rebuild.
Those are facts about what is present, not a promise — the engine still re-hashes
everything before it decides to skip the compile.

Nothing is hidden behind a path you have to remember either: the SD card folder keeps its
own card, with the path in this machine's own notation, a button that opens it with the
`switch` folder selected inside, and a copy-path button. After a cleanup the card stays
and says *not created yet — a build puts it here*.

One more honesty rule, learned from a real complaint: the `.nro` is finished and checked
before the 2.6 GiB of game files are copied into the drag-and-drop folder, so the result
card waits for that last step's numbers. While the copy runs the bar says *"the .nro is
built and checked — filling the SD folder now"* rather than going quiet.

Before you press Start the page shows what the build will occupy: a one-off part
(toolchain + render stack), the unpacked game data that is deleted again when the build
succeeds, and the **build cache** (~5 GiB of objects and translated shards) that
deliberately *stays*. That cache is the whole difference in waiting: measured on this
PC, a build from an empty object tree takes 867 s while the same build with the cache
in place takes **67 s** — the compiler cache already catches 682 of 682 calls it can
handle, and the ~104 big guest shards it cannot (they compile against a precompiled
header, which ccache refuses) are exactly the files the sweep now leaves alone. Tick
**free the build cache** to reclaim the space, or use the Clean up card later; nothing
else changes.

The ROM picker answers before anything heavy starts: `nod` reads only the disc header,
so the page says "right ROM — PAL RMCP01, revision 0", or names the region it found and
keeps Start locked until you tick *use this ROM anyway*. If the header cannot be read
while a build is running, the page says exactly that instead of blaming your dump.
A second Start is refused while the engine holds its lock, whether that build came from
this window or from a terminal — two builds share one work tree and would overwrite each
other. And after the automatic cleanup the SD folder stays in step: the `.nro` inside it
is refreshed from game data that was already extracted and pin-checked, so one click is
still one folder you can drag onto the card.

### Sharing it: one file that carries the rest

`bash tools/make-onefile.sh` produces **two** single files (a little over 200 KB each) that
are each the whole builder:

* **`dist/publish/MKWii-Builder.cmd`** — Windows 10/11.
* **`dist/publish/MKWii-Builder.command`** — macOS and Linux. Same engine, same window,
  a POSIX `/bin/sh` script instead of a batch file, with the tooling inside as a
  base64'd `.tar.gz` (tar, gzip and base64 all exist on those systems; `unzip` often
  does not).

Someone you share it with puts the file in any folder and double-clicks it: the first run
unpacks its own embedded tooling into that same folder (`tools/`, this README, the
project log), reopens itself, and shows the window. Nothing is installed on the machine
and nothing leaves it. What it *does* download by itself, when it is asked to build, is
the compiling tooling — devkitA64 plus cmake, ninja, ccache and .NET (about 0.7 GB the
first time), the pinned `nod` reader for that operating system, and the prebuilt render
stack (Dawn + libuam, ~76 MB, one-off). All of it lands in a folder next to the
file (`.local/mkw-toolchain`) and is thrown away by the same window's cleanup; it needs
no administrator, and `nod` is refused unless its SHA-256 matches what
`tools/get-nodtool.sh` pins. Two tools can genuinely be missing on a clean machine, and
for both the window stops and asks before it touches anything: on Windows the builder
needs bash, which Git for Windows brings, so it offers *Install Git for Windows now?
[y/N]* and then drives winget (or choco, or opens the download page when neither exists),
reopens itself on the bash that was just installed; on macOS/Linux bash is already there
but git may not be — a clean Mac only has the `/usr/bin/git` shim — so it offers the
command line tools (or `brew`, or `apt`/`dnf`/`pacman`/`zypper`) the same way. Answering
no, or running it where there is no terminal to ask in, installs nothing and prints the
two ways on instead. It still needs your own dump.

The one cost that *used* to sit in front of the first build was the render stack: a
machine that had never built this before had to cross-compile Dawn and libuam for the
Switch, and *that* took hours. It no longer does. The stack now ships as one
hash-verified package — 76 MB, 46 files, unpacked 620 MB — which the app downloads and
places where the builder expects it, and the builder verifies it against this
repository's own pins before linking (see
[The render stack without the hours](#the-render-stack-without-the-hours)). The window
says which of the two it is about to do, in the pre-build line ("comes as a verified
package — 76 MB downloaded once, a few minutes"), the `--plan` output says the same in
one line, and the disk card shows the download instead of a 6 GiB source tree. Only when
no package is reachable — no `MKW_RENDER_DEPS_URL`, no file beside the tooling — does it
fall back to compiling here, and then it says so *before* starting, plus the four tools
(meson, Mako, bison, flex) that step demands; `bash tools/setup-native.sh --install
--render` fetches them, and a fresh machine gets that offer automatically. Every build
after that first one is the measured minutes.

Two things to know about the `.command` file. On **macOS**, a file that arrives through a
browser or chat app carries a quarantine attribute, so the first double-click may say it
cannot be opened: right-click → *Open* once, or clear it with
`xattr -d com.apple.quarantine MKWii-Builder.command`. If the executable bit is lost on
the way (it often is, over a USB stick or a chat upload), run it through the shell
instead — that needs no bit at all:

```
sh MKWii-Builder.command          # macOS / Linux, when double-click or ./ does not work
```

The scripts inside it are packed with mode 0755 and the unpacker re-applies that, so a
file that *can* start can always start its tooling; the `.command` is verified by
`make-onefile.sh` to parse as plain POSIX sh (no bash-only constructs), because
`/bin/sh` on many Linux systems is dash, not bash.

All three published files — the two single-file builders and the tooling `.zip` — are
**byte-for-byte reproducible**: every entry carries a fixed timestamp and a unix mode,
and the gzip header of the `.command` payload is stamped zero. Regenerating them from
unchanged tooling therefore yields the same SHA-256, so a hash you post next to a
download keeps matching it after you rebuild, and a recipient can tell whether the file
they got is the one you tested. The same run writes those three hashes to
`dist/publish/SHA256SUMS.txt` — beside the files, deliberately not inside them, because
this README travels in the package and any number quoted here would describe the previous
build. Check with `cd dist/publish && sha256sum -c SHA256SUMS.txt`. The hash does change
when the tooling itself changes, which is the point.

Reading the dump no longer needs Docker either: `tools/nodtool` prefers a **native**
`nodtool` for the machine it runs on - `.local/bin/nodtool-windows-x86_64.exe` and
friends, from the `encounter/nod` releases, verified against a pinned hash - and falls
back to the container only when no native one is available. Measured on this dump: a
full native `extract -p data` gives 2043 files and both pinned hashes match
(`main.dol 80d18895…`, `StaticR.rel 16d9d146…`), with no container involved.

**Clean up** is a card in the window with two sizes, and both are `tools/clean-app.sh`
underneath (also from the file: `MKWii-Builder.cmd --clean` / `--clean-all`).
*Remove build leftovers* deletes only what the builder can remake from your dump
(objects, translated shards, the extracted game data) and keeps the `.nro`, the SD
folder and the toolchain. *Remove everything this app made* takes the folder back to
just `MKWii-Builder.cmd`: the clone, the `.nro`, the SD folder, the toolchain and the
unpacked tooling. Your own dump is never in either list, a running build refuses the
cleanup, and the everything level needs an explicit yes.

The window is `tools/nro-webui.py`: a few hundred lines of Python standard library
serving one localhost page — no framework, no build step, nothing uploaded. It locates
its own interpreter with `tools/ensure-ui-env.sh`, which accepts a candidate only after
running it. That matters on Windows, where the `python` entry in PATH is a Microsoft
Store alias that is not a real interpreter: the old probe read that as "no Python" and
quietly dropped you into the terminal, without a ROM picker. If Python is genuinely
missing the entry point asks before installing it (`[y/N]`; winget on Windows, brew on
macOS, the package manager on Linux), and builds in the terminal if you decline.

```
bash tools/setup-native.sh                    # what's missing on this machine, per platform
bash tools/setup-native.sh --install          # pull devkitA64 + libnx from pkg.devkitpro.org
MKWii-Builder.cmd                             # one file for Windows (make-onefile.sh builds it)
MKWii-Builder.command                         # one file for macOS/Linux, same engine
Bouw-NRO.cmd / bouw-nro.command               # older double-clickers, still work from a clone
bash tools/build-nro.sh               # incremental: re-link only (~1 min, ~10 s if nothing changed)
bash tools/build-nro.sh --full        # retranslate from scratch (~17 min here)
bash tools/build-nro.sh --free-cache  # cleanup that also drops the ~5 GiB build cache
bash tools/build-nro.sh --plan        # show what would happen, build nothing
bash tools/nro-engine.sh --native --deps "<map met dawn/uam>" --full   # explicit native
bash tools/nro-engine.sh --deps-package "<pak of url>"  # build with a prebuilt render stack
bash tools/nro-engine.sh --deps-build   # force: compile the render stack here (unproven on Windows — see below)
bash tools/render-deps.sh --status      # which render stack this host has, and the pin
bash tools/render-deps.sh --make        # pack this host's stack into one verified file
bash tools/render-deps.sh --install     # fetch it, check the pin, place it
bash tools/nro-engine.sh --docker     # force the container route
bash tools/build-nro.sh --zip         # also build the ready-to-unpack SD zip
bash tools/build-nro.sh --keep-recomp # leave the objects and shards for a fast rebuild
bash tools/build-nro.sh --no-map      # skip the SD folder, only the .nro
bash tools/nro-engine.sh --stage env  # one stage only: env|src|inputs|build|verify|deliver|sweep
bash tools/build-nro.sh --deploy      # also push the .nro to your console over FTP
```

**The logic and the UI are separate files on purpose.** `tools/nro-engine.sh` owns
every build step and speaks one machine-readable contract: newline-delimited JSON on
stdout (`stage`, `progress`, `result`, `error`), with the raw docker/ninja stream kept
in `logs/engine-build-raw.log` so stdout stays parseable. `tools/nro-ui.sh` is a ~100
line renderer of that contract, `tools/build-nro.sh` is a CLI that only forwards
arguments and pipes the engine into it, and each platform entry point is a few lines
of shell or batch around the same pair. A graphical or web front end can consume the
same stream and needs to know nothing about devkitA64, Docker or the translator. The
engine itself avoids OS-specific assumptions: GNU *and* BSD `stat`, no `find -printf`,
`shasum` as a fallback for `sha256sum`, and `cygpath` only where it exists.

The `--full` run took **1021 s (~17 min)** here (Ryzen 7 9700X, native devkitA64 on
Windows, 16 jobs). With the object tree and the translated shards left on disk the same
run is **72 s**, of which the compiler itself reports "no work to do" — the 66 s inside
that stage is the builder's own environment and configure overhead, and the
fill-the-SD-folder stage went from 67 s to **1 s** once it stopped `stat`-ing 2040
files one by one. A third tier exists now: after a successful build the engine writes a
fingerprint of everything that feeds the `.nro` (repo ref, applied patch, submodule
refs, `main.dol` and `StaticR.rel`, the shard tree, the builder script itself) into
`logs/last-build.json`, and an unchanged repeat click reuses the product instead of
recompiling — **8,5 s** measured end to end, including the delivery and the sweep. Tick
"retranslate from scratch" (or pass `--full`) and that shortcut is skipped; the
fingerprint costs 0,63 s to compute and is only taken on the native backend.
`ccache` covers 682 of the 682 calls it can handle, and the ~104 guest shards it cannot
(they compile against a CMake precompiled header, which ccache refuses outright) are now
left on disk by the cleanup instead of being deleted and repaid, which is where those
13 minutes went. A build is still allowed to retranslate from scratch when the shards
are genuinely missing; nothing needs a flag. One caveat worth knowing, measured rather
than assumed: a `--full` build does **not** reproduce the known-good hash even
on the default work directory `/deps/native-deko3d/driftdroid`. The translated shards
themselves are byte-identical between runs, but the link lands 544 bytes different in
`.text`, so a rebuilt `.nro` is a new candidate that must be tested on the console
again before you trust it. The re-linked incremental build is bit-identical, because
nothing recompiles there.

The build needs my integration fixes, because upstream never linked this product.
Four of them live in `tools/patches/native-deko3d-link-fixes.patch`: an `extern "C"`
block that had leaked into an anonymous namespace, a duplicate Mesa GLSL-IR symbol
between two Switch libraries, Dawn's GL adapter path being chosen on a backend that has
no GL, and three POSIX calls that libnx declares but does not implement. Three more only
bite on Windows and are applied by `tools/patch-workdir.sh`: a ccache launcher that
survives the toolchain's absolute compiler path, a TLS CA bundle for CMake's
FetchContent, and the ELF section flags the translator writes as COFF when it runs on
Windows (binutils then refuses to link them into an ELF). `scripts/prepare-local-native-deko3d-product.sh`
wipes its work tree and re-extracts the pinned reference, so those fixes live in
**`tools/patches/native-deko3d-link-fixes.patch`** and `tools/patch-workdir.sh` puts
them back after every fresh translation. The patch contains no Nintendo data.

### The render stack without the hours

The product links two cross-compiled libraries: Dawn (patched for Switch, Deko3D
backend) and libuam. Compiling them is the one step that costs *hours*, and it is also
the step that changes least — so `tools/render-deps.sh` turns it into a download.

```
bash tools/render-deps.sh --make    # on a machine that already built the stack
```

That writes `dist/render-deps/mkw-render-deko3d-<dawn-pin>-<uam-pin>-<date>.tar.xz`
plus a `.sha256` sidecar. It carries only what the product link actually reads —
`dawn/include`, the generated Dawn headers, `libwebgpu_dawn.a`, `libuam.a`, the
toolchain receipt and the licence texts of Dawn, Abseil and libuam: **46 files,
620,296,999 B unpacked into 76,026,648 B** (xz). No source trees; those exist only to
be compiled. `--make` writes a `MANIFEST.txt` of sha256 + byte size for every file and
records the archive's own name, hash and size in `tools/render-deps-pins.env` — that
file is data, never sourced as shell, and it is the pin every later install is checked
against.

The current package also carries `.mkw-render-diagnostics`, written by
`tools/build-quiet-dawn.sh`: the frame-dump delta it applied, the sha256 and byte size
of the archive inside, and the exact compiler that made it. `--make` recomputes
`dawn_archive_sha256` in the staged receipt, so the package proves the quiet bytes are
the bytes it ships — a package whose archive does not match its marker is refused on
the host rather than discovered on the console.

To ship it: put the archive on anything that serves a plain HTTPS GET and fill in
`MKW_RENDER_DEPS_URL` in `tools/render-deps-pins.env`. A GitHub release of a
**tooling-only** repository is the shortest safe route, since 76 MB is well inside the
per-asset limit and the URL never moves:

```
git init mkwii-tooling && cd mkwii-tooling
unzip ../dist/publish/MarioKartWii-Switch-builder.zip -d .
cp -a WiiCompiled-Switch-builder/. . && rm -r WiiCompiled-Switch-builder   # tooling at the repo root
git add -A && git commit -m "MKWii Switch builder tooling" && git remote add origin <your-repo-url>
git push -u origin main
gh release create v1 ../dist/render-deps/mkw-render-deko3d-13abc3bc-f8c9eef0-20261105.tar.xz
```

(`cp -a`, not `mv …/*`, because the tooling archive carries a `.gitignore` and a plain
glob leaves dotfiles behind — the repo would then show every run's `dist/` as dirty.)

and then set the pin to the asset address it prints:
`MKW_RENDER_DEPS_URL="https://github.com/<you>/<repo>/releases/download/v1/mkw-render-deko3d-13abc3bc-f8c9eef0-20261105.tar.xz"`.
Check it before telling anyone: `bash tools/render-deps.sh --status` should name that URL,
and `bash tools/nro-engine.sh --plan` on a machine without the stack should answer "comes
as a verified package". Recipients need nothing else. With no URL set, the engine looks
for the file in `dist/render-deps/` beside the tooling, so a package can also travel by
USB stick or your own share — and if neither exists, the app says so and offers to compile
the stack instead of failing an hour in. Two flags override the choice:
`bash tools/nro-engine.sh --deps-package <file|url>` means "use this, never build",
`--deps-build` means "ignore any package, compile here".

This is not a shortcut around the provenance checks. The builder's package branch —
shipped as `tools/patches/render-deko3d-package.diff` and applied by the engine's `src`
stage so a fresh upstream clone gets it too — swaps the git-worktree audit of a 3.4 GiB
Dawn checkout for a recomputation of the same receipt: the sha256 of both archives, of
the Switch patch, of both patcher scripts and of the Aurora Abseil patch, all against
the files *in the current repository*, plus the pinned commits and the four Tint
feature flags. Edit any Switch patch and every package built before it stops verifying,
exactly as editing a patch already invalidates a source tree. The fields that cannot be
re-derived on a foreign machine — worktree diff hashes, the CMake cache hash, the
compiler versions — are printed as recorded provenance instead of quietly skipped.
`--verify` then asks devkitA64's `nm` whether `dawn::native::deko3d` symbols really are
inside the archive, so a package that would link but not run on the console is refused
on the host, before anyone downloads it.

Measured with this route on a work tree that had never seen the package: the stack
installed in **13 s**, the builder verified it and reported `render stack : prebuilt
package`, and the product then compiled all 850 targets and packaged the `.nro` in
**16 m 6 s** cold (966 s, no ccache) — the hours are gone; what is left is the compile
time of this port's own guest shards. The same tree one run later is **30 s**.

One caveat worth saying out loud: those archives are machine code. They were produced by
the devkitA64/GCC named in the receipt, and a recipient on a much newer or much older
toolchain can meet an ABI error at link time. Nothing hides it — the link stage fails
with the compiler's own words, and `--deps-build` remains the route that compiles the
stack for whatever this machine has. **That route is not proven on Windows**, and it is
worth knowing before you rely on it: attempted there it stops in libuam's configure step,
because `uam/meson.build` still calls `import('python3')` and
`distutils.version.StrictVersion` — and `distutils` was removed in Python 3.12. (The same
file also receives an MSYS-style compiler path from meson on that platform.) The package
in this release was compiled from source inside the pinned `devkitpro/devkita64`
container, which is where the quiet archive came from. So on Windows: take the package —
which is the default — and treat `--deps-build` as the route that still needs its libuam
fix upstream (`python3` → `python`, `StrictVersion` → a plain version compare) before it
can be promised.
The distributable rules are unchanged: the package
is Dawn and libuam object code under their own licences (texts included) with no
Nintendo data in it, while the `.nro` and the game data still are not shareable.

### One command instead of the four steps

```
bash tools/pack-sd.sh                 # finds your dump, reuses the verified .nro
bash tools/pack-sd.sh "path/to/dump.rvz"
bash tools/pack-sd.sh --rebuild       # recompile the .nro for a different dump
```

It checks the dump against the pins the build was made for, then writes one `.zip`
holding the `.nro` **and** the already-extracted game data at their real SD paths
(`switch/WiiCompiled-Switch/MKWii.nro`, `switch/WiiCompiled/DATA/{sys,files,.import_complete}`),
so whoever receives it only unpacks onto the SD root — no disc picker, no extraction on
the console. The launch file is always `MKWii.nro` — the name the builder delivers and
the name `switch-ops/switch.sh deploy` keeps it at, rotating the previous build to
`archief-<sha>.nro.bak` instead of deleting anything — and hbmenu shows `MKWii` with its
own 256×256 icon rather than a hash, so "which of these five files is the current one"
is not a question anyone has to ask on a TV. It needs the toolchain
(extract/compile) and Python (the zip), plus the
`.nro` you built; Docker only if you chose it as the backend. The zip is Nintendo data: keep it private, share only this script.

A development log of this port exists and is kept private: it names the author's own
console, disc dump and LAN addresses. Everything that matters for using or auditing
the tooling is in this file instead — and any Nintendo data stays out of both.
