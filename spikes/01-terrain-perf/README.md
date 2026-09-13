# Spike A — deformable terrain performance

**Throwaway.** Standalone Godot project, self-contained, deletable with one
`rm -rf spikes/01-terrain-perf`. No gameplay, and none should ever be added.

It answers risk item 1 in `CLAUDE.md`:

> Deformable 3D terrain holding 60fps on a physical mid-range Android phone.
> This is the largest unknown in the project. If it fails, the fallback is
> crater decals plus a collision-only heightmap, **which changes the design.**

---

## What it measures

The architecture under test is the one we would actually ship:

- **Rendering** — a shared height texture displaces static chunk grids in the
  vertex shader. The CPU never rebuilds terrain geometry; digging costs one
  texture upload. Render cost is therefore roughly *fixed*, whatever happens.
- **Collision** — one `HeightMapShape3D` per chunk, re-cooked only for chunks
  a dig touched, under a 6 ms/frame budget. This is the variable cost and the
  likely failure point, so it is timed separately from everything else.
- **Units** — 150 `MultiMesh` capsules (600 available) walking the field and
  sampling terrain height, to put a realistic CPU and draw load alongside.

Field is **160 × 128 cells at 1 m** — 22% more cells than the real 150 × 112.
Deliberately conservative: the spike should be slightly *harder* than production,
never easier.

## What it does NOT measure

- **Pathfinding.** Units use the same naive local steering as the JS prototype
  and *will* get stuck in a U-trench. That is Spike B, and nothing here should
  be read as evidence about it.
- **Save/load** of a deformed field (risk item 3).
- Anything about whether the game is fun.

---

## Pass criteria

Fixed in `scripts/probe.gd` **before the spike was ever run on a device**. A
threshold argued for after seeing the number is not a threshold.

| # | Criterion | Limit |
|---|---|---|
| 1 | p95 frame time across the whole soak | ≤ 16.67 ms |
| 2 | Worst 60-second bucket, mean frame time | ≤ 16.67 ms |
| 3 | Thermal drift — last minute vs first minute | ≤ 1.25× |
| 4 | p95 collision re-cook per frame | ≤ 4.00 ms |
| 5 | Peak chunk backlog (collision keeping up with digging) | 0 |

Criterion 3 is the one that needs the full ten minutes. A phone holds 60fps
easily for thirty seconds; the question is whether it still does once the
chassis is hot and the governor has stepped the clocks down.

## Running it

**On a phone — the only run that counts.** Export an Android debug APK
(Editor → Project → Export → Android), install, launch, press **SOAK 10 MIN**,
then put the phone on a desk screen-up and leave it alone for ten minutes. Do
not hold it — a hand is a heatsink and will flatter the result.

Or start the soak without tapping, e.g. over adb:

```
godot --path . -- --soak
```

**On desktop** — useful only for sanity, never for the verdict. Desktop thermal
behaviour tells you nothing about a phone under a throttling governor.

**Headless data check** — no device needed, verifies the spike is measuring the
right thing (and that the reporting path works):

```
godot --headless --path . --script tests/headless_check.gd
```

### Controls

| Control | Effect |
|---|---|
| **SOAK 10 MIN** | Start/stop the instrumented run with the scripted digger |
| **UNITS** | Cycle 150 → 300 → 600 → 0, to find the ceiling |
| **DIG / PAN** | Drag to carve, or drag to move the camera |

## Reading the result

The verdict prints on screen and is written to a CSV under `user://`
(`/sdcard/Android/data/<package>/files/` on device, path shown on screen). One
row per second, plus per-minute buckets and a PASS/FAIL line per criterion in
the header comments.

The columns that matter most: `collision_ms` and `backlog`. If frame time is
bad and `collision_ms` is small, the problem is elsewhere and the design
survives. If `collision_ms` dominates, the per-chunk re-cook is the wall.

### If it PASSES

Build on it. Proceed to Spike B — flow-field pathfinding over a freshly dug
U-trench, which decides whether trenches are a tactic or a decoration.

### If it FAILS

Do not tune it into a pass. Read *which* criterion failed first:

- **Criterion 4 or 5 (collision)** — the heightfield idea is fine, the cook
  rate is not. Try smaller chunks, or a collision field at half the render
  resolution, before giving up on the design.
- **Criterion 3 only (thermal)** — it works cold, not hot. That is still a
  fail, but it points at a frame budget problem rather than an architecture one.
- **Criterion 1 and 2 badly, with small `collision_ms`** — the vertex
  displacement itself is too expensive on this GPU class. This is the one that
  triggers the `CLAUDE.md` fallback: crater decals plus a collision-only
  heightmap, and trenches stop being a terrain tool.

Decide the fallback *before* reading the number, or the number will decide it
for you.

---

## One finding already, from building it

The headless check reports that at the tuned dig rate (−1.5/s over a 1.6 m
radius) ground is severed **0.15 s** after digging starts, and spends only
about **0.07 s** — four frames — passing through the "rough ground, 55% speed"
band on the way.

So `rough_below` is very nearly a non-state while an excavator is actively
digging: terrain goes from walkable to severed almost instantly, with no
readable warning. That may be exactly right — a deliberate, fast, decisive
tool. But it means the rough band currently does its work on *old* terrain
(craters, spent mining sites), not on trenches being cut. Worth a look when
tuning, and it is a feel question, so it is yours.
