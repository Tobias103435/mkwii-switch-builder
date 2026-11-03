# Mario Kart Wii → Switch: native builder

One click that turns **your own** Mario Kart Wii (PAL, `RMCP01`) dump into a
*native* Switch `.nro` — statically recompiled guest code, not an emulator — and
hands you a zip whose contents sit at their real SD paths.

## How to use it

1. Get the builder:
   - **Releases page:** `MKWii-Builder.cmd` (Windows) or `MKWii-Builder.command`
     (macOS / Linux). Each is one self-unpacking file, no Python or git needed.
   - or run `Bouw-NRO.cmd` / `bouw-nro.command` from this repo.
2. Point it at your dump (`.rvz`, `.iso` or `.wbfs`) — drag and drop works.
3. Press build. It installs the devkitA64 toolchain, fetches the prebuilt render
   stack, extracts the game data with `nod`, compiles, and packages.
4. Unpack the resulting zip onto the SD root and start the `.nro` from hbmenu.

Needs about 8 GiB free and a few minutes on a normal desktop. Put the folder on the
PC's own disk: a USB stick or an exFAT drive works too, but git refuses to work in a
folder whose drive does not record file ownership until it is trusted — the builder
trusts its own folder (and only that one) instead of stopping there. Docker is
optional — the builder can run devkitA64 natively.

The translation step needs a real Python 3. On Windows the names `python` and
`python3` often point at the Microsoft Store shortcut instead of an interpreter,
which fails only when the build is already running; the builder looks up an
interpreter that actually runs and links those two names to it for its own
processes, so a shortcut in the PATH is not a reason to install anything.

The dump is **not** in this repository and cannot be: you have to bring your own
copy of the game. The built `.nro` and the extracted game data are guest code, so
they are not shareable either — the tooling here is.

## This is not my code

Everything that actually ports the game is other people's work; this repository is
the glue around it:

- the Wii→Switch recompilation itself: **yashin-sh / WiiCompiled-Switch**, plus the
  Deko3D/GPU porting discussion around it
- **Dawn / Tint** (Google, BSD-3) cross-compiled for Switch, and **libuam**
  (**averne**, zlib-style) — the two libraries the product links against
- **nod** (**encounter**) for reading the disc, **aurora** for the Abseil patch the
  Switch build needs
- **devkitPro / devkitA64**, **CMake**, **Ninja**, **ccache** for the toolchain, and
  **DriftDroid**'s Dawn-on-console work, pinned as a reference commit in the receipt

Licenses: the scripts, patches and CI glue in this repo are GPL-3.0-only, matching
the upstream port (`LICENSE`). The compiled render-stack package ships the licence
texts of Dawn, Abseil and libuam inside the archive; it contains no guest code.

`tools/render-deps.sh` turns that render stack — the step that used to cost hours of
cross-compiling — into a 76 MB hash-verified download, which is attached to the
release and pinned by name, size and sha256 in `tools/render-deps-pins.env`.

## Where this stands

Verified on real hardware: a playable race (that build is `a58e4bdf…`). Known open
defect: some vehicles render as black silhouettes. No honest FPS number yet —
none has been measured, so none is quoted here. `README-Switch-Port.md` documents
the pipeline, the provenance checks and the limits in detail.
