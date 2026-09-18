# The map editor

A second scene in the same project. Reach it from the prototype's **MAP
EDITOR** button, or set it as the main scene. It runs on the phone, which is
the point.

## Why it is inside the game

The map has to be judged at the camera it is played at, on the screen it is
played on, under the lighting it ships with. "Does this plateau read at arm's
length on a phone" is a different question from "does this plateau look right
in a plan view on a laptop", and only the first one decides whether a map is
any good. So the editor loads the same `TerrainMap`, the same palette, the same
`LightingRig` and the same quality preset, and its camera is the game's camera
pulled back 2.4× — same pitch, same field of view, same three zoom rungs.

## The tools

| Tool | What it does | Gesture |
|---|---|---|
| RAISE / LOWER | push the ground up or down under the brush | drag |
| FLATTEN | pull the ground toward LEVEL, softly | drag |
| PLATEAU | stamp a disc at LEVEL, at full strength | tap |
| BLOCK | mark an area the player cannot enter | tap |
| PLANT | place a piece of vegetation | tap |
| ROAMER | one of the large creatures, with its territory | tap |
| NEST | a plant hive, spawning SPAWNS at a time | tap |
| PATCH | a burrow, giving SPAWNS once | tap |
| ERASE | remove the nearest placement | tap |

Three sliders: **BRUSH** (1–26 m), **LEVEL** (0–1, the heightfield's own units,
the same numbers the ops and the passability thresholds are written in), and
**SPAWNS** (how many come out of the next nest or patch placed).

Two fingers is always the camera, never the brush — pinch to zoom, one finger
to pan unless the tool paints. **UNDO** takes back the last edit whatever kind
it was.

## Blocked areas are chasms, and that is a decision

There is no invisible wall. Below `TerrainConfig.impassable_below` you cannot
walk, and that is how this game has always defined impassable — the ravine
edges already read that way. A BLOCK carves the ground under it to just below
the threshold.

**It is a polygon, not a disc**, and that took a failing test to discover. A
`plateau` op is a disc with a cosine-squared falloff: at two thirds of the
radius it has moved the ground only a *quarter* of the way toward the level it
was given. So a nine-metre blocked disc blocked about five metres and left a
walkable ring the designer drew and could not see — exactly the mistake
CLAUDE.md records from the first prototype, where trenches read as cosmetic
dents because they never breached the threshold. The check for it asserts
against `is_passable` **at the rim**, not against the height in the middle.

If invisible walls are wanted instead, say so — that is a different feature
(a mask the flow field reads) and not a tweak to this one.

## Getting the map off the phone

Two buttons, because the useful one depends on where you are.

- **SAVE** writes `user://map_edit.json` and prints the absolute path. On a
  desktop that is a real file you can go and get. On Android `user://` is
  inside the app's own sandbox, where nothing else can reach it — so on the
  platform this editor is *for*, this is the less useful of the two.
- **COPY JSON** puts the whole thing on the clipboard. Paste it into chat.
  That is where it is going anyway.

Either way the file also reloads itself next time the editor opens, so a phone
call does not cost an afternoon of placement.

## Applying it

```
godot --headless --path . --script tools/apply_map_edit.gd -- data/maps/mine.json --dry
godot --headless --path . --script tools/apply_map_edit.gd -- data/maps/mine.json
```

`--dry` reports and writes nothing. Put a pasted JSON in `data/maps/` and say
"apply it" and this is what runs.

**It validates everything before it writes anything.** The input has been
through a phone, a clipboard and possibly a chat window, and a half-applied map
— new terrain, old hive — is worse than a rejected one. Every entry is checked
for being on the map and having the fields it needs, and then one check that is
worth more than all of them together: it builds the edited terrain and measures
how much of it is still walkable. A slider left at the wrong end can flatten a
biodome into a chasm while every individual entry in the file is perfectly
valid. Below 4% walkable it refuses.

It writes four things and backs up each one to `<name>.bak` first:

| File | Gets |
|---|---|
| `data/terrain/biodome_map_01.tres` | the shape ops, appended, blocked last |
| `data/gameplay/hive.tres` | the counts the placements imply |
| `data/gameplay/hive_placements.tres` | exactly where everything goes |
| — | vegetation rides in the placements file |

### Why placements are a separate resource

`HiveConfig` is **rules** — how far a creature wanders, how long a nest waits,
how many come out of a patch — and those should hold in biodome 2 without
editing. `HivePlacements` is one map's **layout**, and none of it transfers.
Mixing them would mean a second biodome could not reuse the first one's
balance.

`Hive.place()` honours hand placements exactly and is not allowed to
second-guess them: a designer who put a creature somewhere meant it there, and
re-running the "far from the landing site, far from each other" rules over
their layout would quietly move it with nothing on screen to say why. Anything
the file does not name is scattered as before, so **an empty placements
resource behaves exactly like no resource at all** — which is what lets a map
be half hand-placed while it is being worked on, and what the check asserts.

## The file

`data/maps/example_map_edit.json` is a worked example, not applied to anything.

```json
{
  "format": "sentinel-map-edit", "version": 1,
  "map": "res://data/terrain/biodome_map_01.tres",
  "notes": "",
  "ops":     [ {"op": "plateau", "x": 62, "z": 48, "r": 14, "level": 0.62, "strength": 1.0} ],
  "blocked": [ {"x": 118, "z": 30, "r": 9} ],
  "plants":  [ {"model": "flora_brain", "x": 55, "z": 60, "yaw": 0.8, "scale": 1.1} ],
  "hive": {
    "roamers": [ {"x": 34, "z": 78, "wander_m": 26} ],
    "nests":   [ {"x": 55, "z": 60, "count": 3, "interval_s": 7.0} ],
    "patches": [ {"x": 80, "z": 84, "count": 4} ]
  }
}
```

It is hand-writable, which is deliberate: the ops vocabulary is the one
`TerrainMap` already uses, so anything the editor can express can also be typed.

## Two traps this cost

**The editor rendered a perfectly laid out HUD over a black screen.** Twice,
for two different reasons.

The first was the fog. The terrain shader samples `fog_map` unconditionally, so
a fog that is never uploaded reads as all-zero, which means "never explored",
which means the entire map renders as void. The editor hides nothing and still
has to upload a fog every frame.

The second was worse: **`TerrainView` builds its chunk meshes inside
`set_detail_scale_factor()`**, which only `QualityRig` ever calls. An editor
that skipped "quality settings" as cosmetic got a terrain with zero geometry in
it. Nothing errors; `terrain.get_child_count()` is just 0. Applying the preset
is the fix and it is the right thing anyway — the editor should judge the map
at the fidelity the game will draw it.

Both were invisible to every headless check and took one `print` each to find,
after two rounds of guessing did not. Guessing at a black screen is not
debugging.
