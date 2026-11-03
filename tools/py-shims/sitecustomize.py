# py-shims/sitecustomize.py — Windows gedraagt zich hier als Linux.
#
# Aan alleen als MKW_POSIX_PATHS=1 en op Windows; Python importeert dit bestand
# vanzelf zodra deze map op PYTHONPATH staat.
#
# Waarom: upstream-scripts (o.a. scripts/patch-dawn-switch.py) plakt de tekst van
# een Path()-object in diff-markers en git-excludes. Op Linux is die tekst posix
# ("src/dawn/native/..."), op Windows backslash ("src\\dawn\\native\\..."), dus
# mist elke marker en verwerpt de Dawn-patchverificatie een boom die byte-identiek
# is. Oplossen kon door het upstream-bestand te_editeren — maar de
# provenance-ontvangst van de repo toetst de byte-hash van precies dat bestand, en
# een gewijzigde hash maakt de hele gebouwde deps-cache ongeldig ("rebuild
# dependencies"). Dus: de repo blijft onaangetast en alleen de weergave van paden
# in het python-proces wordt op Windows naar posix gezet, wat zijn eigen gedrag op
# elk ander platform is.
import os
import pathlib

if os.name == "nt" and os.environ.get("MKW_POSIX_PATHS") == "1":
    # str(Path) levert posix-weergave, zoals op elk ander platform. Let op: niet
    # einfach as_posix als __str__ zetten — as_posix belt zelf str(), dus dat is
    # oneindige recursie.
    _orig_str = pathlib.PurePath.__str__

    def _posix_str(self):
        return _orig_str(self).replace("\\", "/")

    pathlib.PurePath.__str__ = _posix_str
