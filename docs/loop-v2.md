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

**Conversion must lose something.** If a unit refunds its full cost instantly,
repurposing is free and the decision collapses — the same trap CLAUDE.md
already records for free module recall. Current model charges a **recovery
loss** on the way back, so churn costs mass. That number is a feel question and
is deliberately in `.tres`.

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
| Mass economy — spend, refund, recovery loss | built, headless-tested |
| Module grows and shrinks with mass | built |
| Drone: fly out, collect, haul home | built |
| Small debris (free) and large debris (stuck) | built |
| Event-triggered waves tied to freeing debris | built, headless-tested |
| Wreck recovery — destroyed units return mass | built |
| Fog of war with reveal sources | built |
| Procedural terrain material, sun, sky | built |
| Build menu spending mass | built |

## Deliberately not built yet

- Repurposing a unit directly into a *different* unit (today: refund to mass,
  then build). Same outcome, one more step, far less code.
- Radar pings for nests and large debris.
- Weapon/defence/process attachments on units.
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

## Open design questions — not mine to answer

1. **Caravan versus emplacement.** "Units move automatically with the module"
   and "the player sets up defence and trenches" pull opposite ways: a trench
   cannot follow you. Does a structure root in place while units follow?
2. **How much recovery loss?** Enough that churn hurts, little enough that
   experimenting is not punished.
3. **Can the module starve?** If building drops it below a floor, is that a
   loss state, a vulnerability, or simply impossible?
