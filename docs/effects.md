# What effects this game can have

Written 2026-09-18, against Forward Mobile and this codebase. Ordered by what
each one buys, not by how it looks in a list.

## Built: the first four

`EffectsConfig` (`data/gameplay/effects.tres`) holds every number, and each
effect has its own switch — because the frame budget has never been measured on
the phone, so they have to be priceable **one at a time**. The **EFFECTS**
button walks `all → none → flash+death → shake → wind → ring` and restarts the
frame timings on each press. "None" is in there as the baseline; without it the
other readings are four numbers with nothing to subtract from.

### Hit flash and death

Damage lights a thing up for 0.12 s and killing it starts a third of a second
of shrinking, tipping and sinking.

**The death state has teeth, and most of the work went there.** A corpse is not
a target, cannot be damaged, does not bite, and is not counted in the HOSTILES
tally. Without every one of those, the effect would have made the game *harder*
— twelve machines would keep firing into something already falling over and a
third of a second of everyone's damage would go nowhere, and the tally would
read 3 when everything was dead.

Two bugs it took a test to find:

- **`dying` counted down past zero and reset itself.** `dying < 0` was the
  sentinel for "has not started dying", so a corpse that reached −0.03 read as
  alive-but-dead on the next frame and was given a fresh `death_s`. Forever. It
  is clamped at zero now and the sentinel is a named `ALIVE` constant.
- **Initialising `dying` to `0.0` made every living alien test as a corpse.**
  Nothing on the map could be shot at all. Zero is the worst possible value for
  "has not started" when the timer counts *down to* zero to mean "gone".

### Camera shake

Splash impacts kick the camera, scaled by damage and falling off to nothing at
44 m from the **view centre** — the question is "did the player see this", so
an explosion off screen shakes nothing. Shakes take the maximum rather than
adding up: twelve machines firing at once would otherwise sum to a camera
leaving the building.

**It moves the camera, never the rig.** The rig is the view centre and the pan,
the leash and the minimap all read it; shaking that would drag the world's idea
of where the player is looking. A quiet frame does not touch the camera at all,
which is what makes this effect genuinely free.

### Vine wind

A sway in the vertex stage of `painted_prop.gdshader`, anchored at the base so
a plant *bends* rather than sliding — the first version moved the whole mesh and
the vines skated across the ground like decals. The phase comes from the prop's
own world position, taken from `MODEL_MATRIX` so it works through a MultiMesh;
without it every plant on the map leans the same way at the same moment, which
reads as the camera moving, not as wind.

Only things called `flora_*` sway. Machines, rocks and ruins are deliberately
rigid: stone that sways is worse than stone that does not move. `sway_m` is
zero on those, so the shader's branch is uniform across their draw calls.

It is the one effect the button cannot toggle live — it lives in a material the
`ModelLibrary` mutates once at spawn — so it takes effect on the next scene
load, and the button says so.

### Emerge dust ring

A ring of discs pushing outward and fading over the 1.5 s an alien spends
climbing out. That beat was already in the design and already in the code; it
was simply invisible, so it did not exist.

### What they cost, and why that sentence is nearly empty

`tools/effect_cost.sh` times each rung on its own, twice, once forwards and
once backwards, against a "none" baseline. The clean run:

```
  rung               ms/frame    vs none    draws
  all                   264.5 under noise      216
  none                  259.6       +0.0      210
  flash + death         260.5 under noise      203
  camera shake          258.8 under noise      206
  vine wind*            258.9 under noise      201
  emerge ring           261.3 under noise      209

  noise floor 13.3 ms — the worst a rung disagreed with ITSELF
```

**Every effect, and all four together, came in under the noise floor.** That is
the whole result. It is not "they are free": this machine has no GPU and
renders in software at about 260 ms a frame, so an effect costing a phone a
third of a millisecond is four orders of magnitude below anything it can see.
What the run establishes is the only thing it *can* — **none of the four is a
disaster.** All four on adds six draw calls, which is the one number here that
is a count rather than a timing and therefore worth something.

The A54 is the only thing that can price these, and the EFFECTS button is how
it gets asked.

Two mistakes getting to that table, both worth keeping:

- **The first run reported every single effect as FASTER than no effects at
  all.** Impossible, and it was the machine warming up — a steady drift across
  the run, aliased onto rung order. Measuring forwards then backwards makes a
  monotonic drift cancel.
- **The second run had a screenshot render competing for the CPU.** One rung
  measured 488 ms and then 266 ms — the same code, twice, 222 ms apart — while
  the tool cheerfully reported a 9 ms noise floor, because it was estimating
  noise from the drift in "none" rather than from how badly a rung disagreed
  with *itself*. It uses the worst pass-to-pass disagreement now, and names any
  rung that failed to repeat. **Measure nothing while anything else is
  running.**

## Where we actually are

Before this, there was **no effects system at all** — no particles, no tweens,
no decals, no screen effects beyond the ink pass, and no audio. The four above
are the first, and everything below them is still unbuilt. That is not an
oversight: CLAUDE.md puts us in a **grey-box vertical slice**, so everything
below is code and shader work, and anything needing a modelled asset or a sound
file is out of phase and marked as such.

Two hard constraints shape the whole list:

- **The frame budget is unmeasured on the current build** (CLAUDE.md risk 4).
  Nothing here is affordable until it is soaked from an APK on the A54. The
  costs below are estimates of *shape*, not measurements.
- **Mobile runs no volumetric fog, no SSAO, no SSR, no SDFGI.** Anything that
  sounds like "atmospheric haze" or "screen-space glow around objects" has to
  be faked geometrically or not done. See `docs/research/godot-mobile-lighting.md`.

## Tier 1 — essentially free, and mostly about LEGIBILITY

These reuse MultiMeshes, instance colours and transforms that are already being
written every frame. No new draw calls, no new passes.

| Effect | What it fixes | Cost |
|---|---|---|
| **Hit flash** | you currently cannot tell whether a shot connected | one instance colour, already written per frame |
| **Death shrink-and-drop** | things vanish mid-stride; nothing reads as *killed* | one transform, 0.25 s |
| **Muzzle flash** | which machine fired is invisible in a crowd | one extra tracer instance for two frames |
| **Impact mark** | a shell that lands leaves no evidence | one fading disc in `_mm_marks` |
| **Camera shake** | artillery has no weight | pure maths on the rig, zero draw cost |
| **Tap ripple** | no confirmation an order was received | one expanding ring |
| **Emerge dust ring** | the 1.5 s climb-out is invisible | a ring of discs on a timer that already exists |
| **Module damage tint** | being chewed on is a number in a bar | one colour on a mesh already drawn |

**Camera shake is the best value in the whole document.** It costs literally
nothing to draw and it is the single biggest contributor to a hit feeling like
a hit. It is also the easiest to overdo, which makes it a feel question.

## Tier 2 — cheap shader work, and mostly about the world being ALIVE

One more instruction in a shader that already runs, or one new MultiMesh
animated entirely in its vertex shader. No CPU per-frame work.

- **Wind on the vines.** A `sin(TIME + world_pos)` sway in the vertex stage of
  the painted shader. The map is *full* of vines and they are all rigid. This
  is probably the largest atmosphere-per-millisecond item available.
- **Water motion.** The pools already carry a water mask the shader samples.
  Scrolling a ripple where `water > 0` is a few instructions in a branch that
  is already taken.
- **Drifting spores.** 150–250 unlit quads in one MultiMesh, positions animated
  from `TIME` and the instance index in the vertex shader. One draw call, no
  CPU. Sells "sealed biodome, thick air" better than fog we cannot have.
- **Breathing emissives.** Machines and nests pulse slowly. The glow pass
  already exists; this is a multiply on `EMISSION`.
- **Heat shimmer over the teleporter** when it charges — a UV distortion in the
  ink pass, which is already a full-screen pass, so the cost is a texture read.

## Tier 3 — real cost, worth it for specific moments

- **GPUParticles3D.** Mobile runs them. Each system is a draw call, so they
  want pooling and a hard cap — a dozen, not a hundred. Right for: a roamer's
  death, the teleporter firing, a large debris piece coming free. Wrong for:
  every bullet.
- **Decals.** Supported, and they cost a pass over the affected pixels. Proper
  scorch marks and blast rings. Tier 1's flat discs get 80% of this for ~5% of
  the cost, so this is a later polish item.
- **Full-screen damage vignette.** The ink pass exists and is already
  full-screen, so adding a tint/vignette uniform is nearly free — the reason it
  is Tier 3 is that it is easy to make a game look cheap with.

## What we cannot have, and what to do instead

| Wanted | Why not | Instead |
|---|---|---|
| Volumetric god-rays | no volumetric fog on Mobile | the canopy cast layers already in the terrain shader |
| Screen-space AO on props | no SSAO on Mobile | baked AO, which the terrain already has |
| Real-time reflections | no SSR on Mobile | the reflection probes on the pools |
| Bounced light from explosions | no SDFGI/VoxelGI | a brief omni light, which Mobile *does* run |
| Sound | out of phase — no audio this slice | — |

## What I would build first, and why

1. **Hit flash + death shrink.** The game currently has a combat system you
   cannot read. Everything else is decoration until this is fixed.
2. **Camera shake.** Free, and it is most of "weight".
3. **Wind on the vines.** The single biggest change to how alive the map looks,
   for one vertex instruction.
4. **Emerge dust ring.** The 1.5 s climb-out is a deliberate design beat and it
   is currently invisible — the effect is what makes the beat exist.

That is four items, all Tier 1 or 2, none of which needs an asset. Say the word
and I will build them, measure the frame cost of each on its own, and ship the
ones that pay for themselves.

**How much shake, how bright a flash, how much sway** are feel questions and
not mine to decide — I will pick a starting value, say what I picked, and
expect to be corrected.
