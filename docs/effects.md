# What effects this game can have

Written 2026-09-18, against Forward Mobile and this codebase. Ordered by what
each one buys, not by how it looks in a list.

## Where we actually are

There is **no effects system at all** right now — no particles, no tweens, no
decals, no screen effects beyond the ink pass, and no audio. That is not an
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
