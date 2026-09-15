# SENTINEL — the mass loop (v2 direction)

A revision of the core loop. Captured here because it changes the economy, the
wave trigger and the player unit, and those need to be written down rather than
living in a chat message.

**Status: proposal, partially built.** `docs/design-brief.md` still describes
the v1 loop (6 module bays, salvage currency, 45-second timer waves, teleporter
fragments). Where the two disagree, this document is the newer intent — but the
brief has not been rewritten, and that decision is open.

---

## The premise

A small module crashes from the ship. Everything around it is dark. Beside it
lies debris from the wreck. The module has one flying drone.

That is the whole starting state.

## The one resource: mass

There is no salvage, no credits, no separate currency. **The module's mass IS
its body.** Debris the drone recovers becomes mass; the module visibly grows.
Building a unit or a structure spends mass; the module visibly shrinks.

This is the idea the rest hangs on, and it is worth protecting:

- Cost is legible without a UI. A player can *see* they are spending themselves.
- Nothing is lost permanently. A destroyed unit leaves parts; the drone
  recovers them; the mass comes home.
- Over-building has an obvious, physical downside.

**Mass is conserved. It is never consumed, only relocated.** It moves from the
wreck, into the module's body, out into a unit, and back again. Nothing in the
loop burns it away.

That rule has consequences, and they are load-bearing:

- **Digging costs nothing.** Earth is not body. A trench is paid for in the
  drone's time and in the fact that the convoy moves on without it.
- **The cost of churn is time, not a mass tax.** `recovery_loss` and
  `scrap_loss` in `data/gameplay/mass.tres` are both **0.0**. Nothing is
  deleted. What stops free repurposing is the clock:
  - mass leaves the module the instant the button is pressed, so it shrinks now
  - the machine spends `build_time_s` (4s) in the assembly queue and does not
    exist yet
  - scrapping a live machine leaves a **wreck where it stood**; nothing comes
    back until the drone flies out and hauls it home

  A player who rebuilds their army every wave is not poorer, they are late, and
  their line has a hole in it while they wait.

## Pacing is the player's, not a timer

v1 sent a wave every 45 seconds. That fights an exploration game.

Instead: **large debris is stuck in the ground.** Sending the drone to free it
starts the attacks. Attacks continue while the drone works, and **stop when the
piece comes free.** The player chooses when to start a fight, and how much
defence to build first.

Small debris is free to collect and triggers nothing. So the opening minutes
are quiet, and the player decides when that ends.

## Fog of war

Only the area around the module and its units is visible. A radar structure
extends that and pings alien nests and large debris. Exploration has a cost and
a reward.

## What is built so far

| Piece | State |
|---|---|
| Mass economy — fully conserved, time-priced | built, headless-tested |
| Module grows and shrinks with mass | built |
| Drone: fly out, collect, haul home | built |
| Small debris (free) and large debris (stuck) | built |
| Event-triggered waves tied to freeing debris | built, headless-tested |
| Wreck recovery — destroyed units return mass | built |
| Fog of war with reveal sources | built |
| Procedural terrain material, sun, sky | built |
| Build menu spending mass | built |
| Assembly queue — mass committed, machine delayed | built, headless-tested |
| Scrapping a machine into a wreck | built, headless-tested |
| Machine customisation — chassis, hardpoints, parts | built, headless-tested |
| Melee / ranged / artillery / mixed roles | built, headless-tested |

Machine customisation has its own write-up:
**[docs/machine-customisation.md](machine-customisation.md)**.

## Deliberately not built yet

- Repurposing a unit directly into a *different* unit (today: refund to mass,
  then build). Same outcome, one more step, far less code.
- Radar pings for nests and large debris.
- An in-game loadout editor. The parts system supports arbitrary
  chassis+part combinations; the build bar only offers eight pre-assembled
  machines. How much fiddling is fun on a phone is a feel question.
- Shell travel time for artillery. Splash lands instantly today, so there is
  no arc to read and no leading a moving target.
- Units auto-following the module as a caravan.
- Alien adaptation (the v1 system still exists and is tested; it is not wired
  into this loop yet).

## Found by building it

- **Hostiles ate the module in under three seconds.** The first pass drained
  1.75 mass/second per hostile in contact; a 36-mass module died before the
  player could react. That is not a fight, it is a cutscene. Now
  `module_drain_per_s`, in `.tres`, and deliberately gentle — the number is a
  feel question.
- **Fog cost more than the game did.** Rebuilding all 16,800 cells per frame in
  GDScript was the single most expensive thing in the loop, the same shape as
  the `units 5.80 ms` finding from Spike A. Reveal is now O(cells touched) and
  runs at 15 Hz.
- **Simulation had to be split from presentation** before the loop could be
  tested at all. `step()` runs the game; `_present()` only reads it.

## Resolved: the caravan is total

Everything the module builds travels with it — turrets, radar, bulwarks, units.
Nothing roots down. Convoy members hold evenly spaced stations in a ring, at a
per-option radius so heavy things sit further out and meet trouble first, and
close the gap faster the further behind they fall.

**The only permanent mark the player leaves on the world is dug terrain.** That
is what gives the deformable heightfield a job no building can take, and it
makes a trench a genuine commitment: you cannot take it with you. Digging is
free of mass — earth is not body — so the whole price of a trench is time and
immobility.

## Lighting is part of the measurement

`data/gameplay/lighting.tres` plus `LightingRig` are the shipped lighting, and
both the prototype and Spike A apply them from that one source
(`tools/export_spike_map.gd` syncs the copy into the standalone spike). A
frame-rate soak run without shadows and a lit sky measures a configuration
nobody plays, so the soak CSV now records the lighting settings in its header
and terrain and units both cast.

Mobile-renderer reality shaped the values: no SDFGI, no volumetric fog, no
SSAO/SSIL, one directional shadow. Ambient comes from the sky rather than a
bake, because the terrain deforms at runtime and cannot be baked.

## Models, and the one constraint they impose

`models/*.glb`, built procedurally by `tools/blender/build_*.py` (deterministic,
re-runnable, no hand-authored art). `ModelLibrary` loads them, grounds each
instance from its own AABB — three assets shipped 7-17 cm low, and fixing it
centrally beats hoping every future build script complies — and extracts a
single module growth form from the file that holds all three.

| Asset | Tris | Budget |
|---|---|---|
| module forms 0 / 1 / 2 | 984 / 2090 / 3392 | 4000 each |
| turret / radar / bulwark | 512 / 448 / 704 | 900 |
| drone / guard | 264 / 400 | 600 |
| swarmer / breacher | 576 / 704 | 900 |

**A skinned mesh cannot be rendered through MultiMesh.** Godot has nowhere to
put per-instance bone matrices. Both aliens are skinned — swarmer 16 joints
(idle, run), breacher 11 joints (idle, walk, slam) — so every animated alien is
an individual node. `animated_alien_cap` bounds how many get a real body before
the rest fall back to instanced boxes.

That is the live tradeoff: readable alien animation, or crowd size. Spike A
measured 600 instanced units at 5.80 ms; individually animated skinned meshes
will not reach that number. The cap is in `.tres` so the phone can settle it.

The convoy is individual nodes too, but for a different reason: it is a dozen
things, and nodes buy animated sub-parts free — the turret head and radar dish
aim at what they are tracking.

## Open design questions — not mine to answer

1. ~~**How much recovery loss?**~~ Settled: none. See 3.
2. **Can the module starve?** If building drops it below a floor, is that a
   loss state, a vulnerability, or simply impossible?
3. ~~**Should `recovery_loss` and `scrap_loss` be zero?**~~ Settled: yes, both
   zero, with time as the price. Implemented and tested.
4. ~~**Where does the dug earth go?**~~ Settled: nowhere. Conservation applies
   to mass — the module's body — and earth is not body, so a trench raises no
   berm and the dug ground is simply gone. Not built, deliberately.
5. **Is four seconds the right assembly time?** `build_time_s` is the entire
   cost of repurposing, so it is the single most load-bearing number in the
   economy. Too short and churn is free; too long and experimenting with
   loadouts is punished. This is a feel question and needs playing, not
   deriving.
6. **Should parts be gated?** Every chassis and part is available from the
   first minute. Almost certainly wants to change once missions exist, but what
   unlocks what is a progression decision, not a systems one.
