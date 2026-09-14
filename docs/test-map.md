# Biodome 01 test map

A designed fixture for Spike A and Spike B, stored as **seed + ops** rather
than a heightfield.

That format is deliberate. CLAUDE.md risk item 3 says a save must be "the
procedural seed plus a deformation diff" instead of megabytes of floats — so
the test maps are authored in exactly that format, and `build_test_map.gd`
asserts a rebuild is bit-identical. If the representation cannot express the
maps we want, we find out now instead of at save/load time.

## Regenerate

```
godot --headless --path . --script tools/build_test_map.gd

tools/blender/install.sh          # once per container; prints the interpreter
~/.cache/blender-venv/bin/python tools/blender/terrain_preview.py \
    build/terrain/test_map_01.r32 150 112 build/terrain
```

The Blender scripts run under either front end — the `bpy` module above, or a
normal `blender --background --python ... -- <args>` install. `bpy` is how this
environment gets a current Blender at all: `download.blender.org` is blocked by
the egress policy, and Ubuntu's apt build is 4.0 and lacks OpenImageDenoise, so
its renders come out grainy. The render helper detects that and falls back
rather than hardcoding denoising off for everyone.

Everything under `build/` is generated and gitignored — the `.tres` is the
source of truth.

| Artefact | Use |
|---|---|
| `test_map_01.r32` | 150×112 float32, row-major — feeds Blender and any external tool |
| `test_map_01_height.png` | greyscale heightmap |
| `test_map_01_legend.png` | passability legend: chasm / rough / clear |
| `test_map_01_persp.png`, `_top.png` | Cycles CPU renders, ~15 s each |
| `test_map_01.glb` | 3D mesh with passability as vertex colours |

## What is on it, and why

| Feature | Exists to test |
|---|---|
| **Chasm at x=75, two crossings** (z≈26, z≈86) | Chokepoint funnelling. Forces every route through one of two gaps. |
| **Rough band**, x 30–62, z 10–46 | Weighted vs uniform cost. Sits **on the forced corridor**, so crossing it is a real decision. |
| **U-pocket**, ~x 92–104, z 43–69, opening west | The local-minimum trap. Cost inside must exceed cost at the mouth. |
| **Four crash craters** | Irregular terrain; deformation load for Spike A. |
| **Flat plateaus** at spawn and goal | Stable staging, so start/end conditions are not noise-dependent. |

## Validation

`tools/build_test_map.gd` asserts the map has the properties the spikes need:

```
PASS  rebuild is bit-identical          seed + 13 ops, 61.7 ms
PASS  has meaningful rough ground       7.0% rough
PASS  has meaningful impassable ground  3.7% chasm, 96.3% passable
PASS  goal is reachable from spawn      cost-to-goal 148.4, 16693 cells
PASS  map is not fragmented             0.0% of passable ground cut off
PASS  U pocket is a genuine dead end    inside 72.8 vs mouth 69.5
PASS  weighted avoids rough             weighted 0 rough cells, uniform 27
```

That last line closes the gap Spike B recorded: with flat ground the weighted
and uniform fields were indistinguishable. They now provably diverge.

### Two design mistakes this validation caught

Worth keeping, because both looked fine and were not:

1. **The rough band was off the decision path.** It started on the map's
   midline, but the chasm chokepoint funnels every route north — so both cost
   models detoured around the band without ever choosing. Moving the band onto
   the corridor made it a real choice.
2. **A crater sat inside the band.** −0.34 applied to 0.325 ground clamps to
   impassable, which would have sealed the only northern crossing. Moved.

Also worth noting: comparing the two fields' *cost numbers* is meaningless —
one is in time-equivalent, the other in cells travelled. The check compares
the **routes** they produce.
