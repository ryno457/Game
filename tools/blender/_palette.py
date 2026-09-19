"""The machines' colours, in ONE place.

WHY THIS FILE EXISTS. build_machines.py, build_module.py and build_structures.py
each carried their own copy of these three hex strings and each was expected to
be kept in step by hand. It did not work, twice:

  * build_module.py's own comment records the first time — "last pass only
    build_machines.py was changed and the player's own MODULE stayed dark teal
    while its drone and guard went grey".
  * It then happened again and stayed shipped. build_structures.py was still on
    12303a / 16222c, a dark teal that is effectively black at linear
    0.006 / 0.030 / 0.042, which is why turret, radar and bulwark render as
    black boxes in build/hdri/model_lineup.png while drone, guard and
    module_forms read light grey beside them. Nine of the fourteen build
    options map to those three models.

A comment saying "keep these in step by hand" is a bug with a note attached.
This is the note removed and the bug with it.

MANUFACTURED, without competing with the bioluminescence for attention.
tools/build_biodome.gd keeps every ground material teal-tinted to protect that
separation: the landscape is what grew, the machines are what was built, and
the line between them is the whole look.
"""

## Light grey. The hull is the large plate area, PLATE the recessed and shadowed
## parts, and ACCENT the powered slots — pods, sights, vents — which are the
## only colour a machine has and the only thing that says it is switched on.
HULL_HEX = "b9bdc2"
PLATE_HEX = "8e949b"
ACCENT_HEX = "4fe3c1"

## Material slot indices, shared for the same reason the colours are.
HULL, PLATE, ACCENT = 0, 1, 2
