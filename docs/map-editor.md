# The map editor

A second scene in the same project. Reach it from the prototype's **MAP
EDITOR** button, or set it as the main scene. It runs on the phone, which is
the point.

## Two of them

**In Godot** — `scenes/editor/map_editor.tscn`, reached from the prototype's
MAP EDITOR button. Judges the map at the camera it is played at, under the
lighting it ships with.

**In a browser** — `tools/web_map_editor.html`, a single self-contained page
(397 KB) published as an artifact. Same tools, same JSON, no Godot needed.
`tools/export_map_web.gd` bakes the real biodome into it: height, water and
material in one 150x112 PNG straight out of TerrainBuilder, the whole-map
ground texture, plus the 408 props the dressing actually scatters and the
Hive's own notice radii. The point is that the page draws the REAL map — a
designer placing a nest "next to that plant" has to be looking at the plant
that is actually there.

### The background is the real ground

`build/web/albedo.jpg` is a 1400 px copy of `textures/ground_vines_c.png` —
the whole-map bake the terrain shader itself samples, unwrapped across the
floor rather than tiled, resized to the map's aspect so the browser draws it
into the map rectangle one-to-one. Before this the background was a
four-colour height ramp, which is a DIAGRAM of the map: it showed open ground
where the floor is in fact under a vine mat, and the designer was placing
against a fiction.

The page composites four layers, once per edit, into one offscreen canvas:

    mix(height ramp, bake, 0.8) * relief

with the chasm and the wall mask re-asserted between the bake and the relief.
Three of those four are computed live from the edited heights, so a sculpt
still reads. **The bake does not move.** It is a fixed unwrap of the unedited
floor, so raising a plateau changes its shading and its tint and leaves the
vines where they were baked — which the sculpt tools say in their hint text,
because a page that quietly implies otherwise is worse than one with no
texture at all.

Two numbers in there are not the game's, and both were measured rather than
picked:

- **0.8, where the shader uses `baked_colour` = 0.55.** The shader mixes the
  bake over the material-mapped, stroke-painted floor colour. The page has a
  four-colour ramp instead, and spending 45% of the picture on a stand-in for
  a layer it cannot reproduce threw away well over half the bake's contrast —
  the first build of this rendered as a pale sheet with the vines barely under
  it. At 0.8 the check measures 68% of the bake's detail surviving.
- **A per-channel gain on the ramp.** The palette stores its colours linear and
  the page draws them as sRGB bytes, so the ramp lands ~40% brighter than the
  bake. Each channel is scaled so the ramp's mean over the open floor equals
  the bake's; the mix then moves colour around — pools greener, ridges lighter
  — without moving brightness.

### Re-baking

    godot --headless --path . --script tools/export_map_web.gd
    python3 tools/inline_map_web.py
    node tools/web_map_check.mjs

The page is deliberately one file, because it gets opened off a phone's
downloads folder or pasted into a chat artifact and neither can fetch a
sibling. So the three baked assets live inside it as literals and
`inline_map_web.py` rewrites those literals in place. They were pasted by hand
the first time, which worked exactly once: a re-bake that has to be transcribed
is a re-bake that quietly does not happen, and then the page is showing a map
the game no longer has.

`tools/web_map_check.mjs` drives the page in headless Chromium and asserts what
a screenshot cannot — that the composite really is that formula to within a
level, that the background is the bake and not the ramp, that the floor's
brightness is the bake's shaded by the relief, that at least 55% of the bake's
detail survives, and that a stamped plateau still moves pixels. Every one of
those has already caught something: the first two runs of it were themselves
wrong, comparing layers at mismatched resolutions and then over mismatched
pixel sets, and reported a broken composite that was not broken.

Its sculpt maths is a line-by-line port of `Heightfield.deform` and
`TerrainBuilder._disc` / `_polygon` — `cos(d/r * PI/2)` squared, the same
clamp range, the same cell-centre test for walls — because a preview that
disagrees with what the apply tool will do is a preview that lies. The clamp
range is exported rather than typed twice for the same reason.

Getting the file out is the clipboard, not a download: the artifact sandbox
makes `<a download>` and script-driven saves inert, so a download button would
be a button that does nothing.

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
| BLOCK | carve a chasm the player cannot cross | tap |
| WALL | free-form invisible wall, no terrain change | tap out corners |
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

## Two ways to say "you cannot go here"

| | BLOCK | WALL |
|---|---|---|
| shape | a disc under the brush | free-form outline, tap out the corners |
| the ground | carved to a chasm | **untouched** |
| visible? | yes, it is a hole | no — whatever is standing there is the visual |
| for | the obstacle IS the terrain | a thicket of plants, a cluster of structures |

**WALL is the one for clusters of alien growth.** Those things stand on ground
that is perfectly fine. Digging a chasm under them would say the wrong thing
about what is stopping you, and would drop the props into the hole. So a wall
is a separate mask on the heightfield (`Heightfield.blocked`), consulted by
`is_passable` and changing not one height.

Tap out the corners; tap the first one again to close, or press **CLOSE WALL**.
**CANCEL WALL** drops one in progress. A wall in progress draws cyan, a
finished one amber, and both draw as *dots along the outline* rather than a
filled shape — a wall is invisible in the game and the editor must not make it
look like a floor decal the player will see.

Nothing renders a wall at runtime, and nothing should: **if the player cannot
see why they are being stopped, the wall is in the wrong place.** The props are
the explanation.

It is a `wall` op like any other, so it rides through `TerrainMap.ops`, the
JSON, and the apply tool with no new plumbing — and because it touches no
heights, nothing applied after it can undo one.

### And the JSON nearly ate them

`JSON.stringify` turns a `Vector2` into the **string** `"(12, 34)"`. A wall
saved and reloaded came back as a perfectly valid-looking entry with corners
that were text, blocking absolutely nothing. Corners go out as `[x, z]` pairs
now, and `MapEdit.wall_points()` reads all three shapes they might arrive in
(Vector2 from the editor, `[x, z]` from a file, `{"x":, "z":}` from someone
hand-writing one by copying the rest of the format). The check builds the
terrain *after* a round trip and asserts it still blocks.

The apply tool's walkable-fraction safety net also had to learn about them: it
read heights only, so a map papered over with invisible walls until nothing was
reachable would have been reported as perfectly healthy — the one safety net in
the tool, blind to the one edit that leaves no trace in the terrain.

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

Use WALL when the obstacle is something standing on good ground.

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

### One more trap, found by an undo

`_replay()` originally called `terrain.setup()` again to rebuild after an undo.
`setup()` builds a **new** `ShaderMaterial`, while the chunk meshes keep a
`material_override` pointing at the old one — and the chunks are only ever
built once, inside `set_detail_scale_factor()`, so nothing rebinds them. The
terrain would have gone quietly stale after the first undo, still drawing the
heights it had before, with no error and no visible cause. The field is
rebuilt **in place** now, into the object the view already holds.

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
