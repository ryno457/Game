# The module base — mobile and deployed

Status: **proposal, not built.** Written 2026-09-19 from a spoken brief. The
numbers are starting points chosen to be argued with, not measurements. Every
open question is marked **Q**.

This supersedes nothing yet. `docs/loop-v2.md` is still the shipped loop.

---

## Why this is the right shape

`CLAUDE.md` already says the thing this design is built on:

> The attached-vs-detached tradeoff is the core of the game. Every module must
> do something genuinely useful in both states, or the decision collapses.

Today that tradeoff is a per-module recall with no cost, which CLAUDE.md also
flags as broken — *"module recall must cost something ... which removes the
decision entirely"*. This design promotes the tradeoff from a per-module fiddle
to **one posture the player commits the whole base to**, which is a decision
worth making because it is rare, visible, and reversible only at a price.

It also fixes a direction error in the current build: the base **shrinks** as
mass is spent, so the player's machine gets smaller as they succeed. Growth
should read as growth.

---

## Resources

Four, where there is one and a half today.

| resource | source | spent on | reads as |
|---|---|---|---|
| **Mass** | salvage, wrecks | building and repairing modules | the metal |
| **Debris** | heavy scrap, wave caches | **growing the base** — more slots | the chassis |
| **Module** | wave caches only | unlocking a module *type* to build | the blueprint |
| **Energy** | base generation + caches | support powers, and running deployed modules | the power |

**Mass and Debris are deliberately different.** Mass is the flow — you spend it
constantly. Debris is the stock — it only ever goes into the base, and the base
never gives it back. That keeps "do I grow or do I build" a real question
instead of one pool with two names.

**Module caches replace the big mass debris that currently triggers waves.**
Taking one is the wave trigger, and it pays out module + energy + mass together.
So the escalation and the progression are the same object: you cannot grow
without pulling the map down on yourself.

> **Q1.** Should Debris also drop from killed aliens, or only from map scrap and
> caches? Aliens dropping it makes defence profitable; scrap-only makes the map
> the pacing mechanism.

> **Q2.** Is Module a single fungible currency ("3 modules, spend on anything")
> or typed ("this cache held a Radar")? Typed makes each cache a decision and a
> run feel different; fungible is far simpler and never dead-ends the player.

---

## The base

Starts at **tier 1**, the smallest chassis, and grows by spending Debris.

| tier | debris | slots | notes |
|---|---|---|---|
| 1 | — | 2 | start |
| 2 | 40 | 3 | |
| 3 | 110 | 5 | |
| 4 | 240 | 7 | |

Slots are the only thing tiers give directly. Speed, hull and power all follow
from what is *in* the slots, so a big empty base is worse than a small full one
— which stops tiering up from being the obvious first move every time.

The three existing `module_forms` meshes already grow by accreting plate, so
tiers 1–3 have art. Tier 4 needs a fourth form or reuses tier 3 scaled.

> **Q3.** Four tiers or three? Three matches the art that exists. Four gives a
> late-game goal but needs a model.

---

## The two modes

### Mobile

Every module is docked on the chassis. The base drives.

- Modules run at **reduced capability** — not off. A docked Radar still gives
  the base its own detection bubble; a docked Turret still shoots, at shorter
  range and with the base's own arc.
- The base is **one target**. All the hull in one place.
- This is how you travel, reposition, and run.

### Deployed

Modules undock, walk a short distance out, and anchor. **Power cables** run from
each module back to the chassis.

- Modules run at **full capability**, and several change *kind* rather than
  degree — a deployed Radar sweeps the map, a deployed Artillery module can
  actually fire indirect.
- The base **cannot move**. Undocking and re-docking both take time.
- Modules are now **separate targets** with their own hull, and the cables are
  a visible weak point.

**The cable is the design, not decoration.** It is what makes deployment
readable at a glance, it is what bounds the deploy radius, and it is the thing
an alien can cut. A module with a cut cable drops to mobile-mode capability
where it stands until the cable is repaired — worse than either posture.

Proposed: deploy radius **8 m**, undock **2.5 s** per module staggered, re-dock
**4 s** per module. Re-docking is slower than deploying on purpose: committing
is cheap, running away is not.

> **Q4.** Does the base deploy **all** modules at once, or does the player
> deploy them one at a time? All-at-once is one clean button and one clean
> decision. Individually is more tactical but re-creates the fiddly per-module
> recall CLAUDE.md says removed the decision.

> **Q5.** Can a deployed module be **abandoned** — undeploy the base and leave
> it behind as a permanent structure? That would be the bridge to holding
> ground, but it also means the base can seed turrets across the map and never
> come back, which may be too strong.

> **Q6.** What happens to a module whose cable is cut and whose base then drives
> away out of range? Destroyed, or stranded and recoverable?

---

## Modules, in both states

Every module needs a genuine job in both postures or the decision collapses.
This is the whole test. First pass at the catalogue:

| module | mobile | deployed |
|---|---|---|
| **Radar** | short detection bubble around the base | long sweep, reveals fog at range, spots burrowed aliens |
| **Turret** | fires, base arc, short range | full range, own arc, own target priority |
| **Artillery** | cannot fire — dead weight while moving | indirect fire anywhere in range |
| **Shield** | one bubble over the base | bubbles over other modules and nearby units |
| **Forge** | slow repair of the base | builds and repairs anything on the cable network |
| **Reactor** | energy trickle | full energy generation, and extends cable range for others |

**Artillery is the deliberate exception** — a module that is useless in one
state. One such module is interesting because it forces a real commitment.
Two would make deployment mandatory, which kills the choice.

> **Q7.** Is that list right, and is Artillery-useless-while-mobile acceptable,
> or should everything be useful in both as CLAUDE.md's rule reads literally?

---

## Energy and support powers

Energy is generated by the base (and Reactor modules) and pools up to a cap.
The player **allocates** it rather than spending it: it is a dial, not a wallet.

Proposed: three channels, allocate a share of generation to each.

| channel | effect | feel |
|---|---|---|
| **Shielding** | regenerating hull over units and modules | survive the wave |
| **Bombardment** | charges a called-in strike | break the wave |
| **Overdrive** | fire rate and movement across the board | outpace the wave |

Allocation is continuous and re-allocatable at any time, but the *stored* charge
in a channel drains when you move the dial away from it. So switching costs
something without locking the player out.

> **Q8.** Is a three-way dial the right interface on a phone? The alternative is
> three buttons that spend a pool — cruder, but a single tap instead of a drag.

> **Q9.** Should energy also be the thing that *runs* deployed modules — i.e.
> deploying costs upkeep — or is deployment free once paid for in time? Upkeep
> makes the Reactor essential and gives energy a second job; it also adds a
> failure state where the player deploys and then browns out.

---

## What this does to the wave loop

Today, waves are triggered by taking big mass debris. That stays, with the
debris replaced by module caches. The shape becomes:

1. Drive, mobile, to a cache.
2. Decide whether to take it now or clear the ground first.
3. Take it → wave triggers → **this is the moment deployment is for.**
4. Deploy, fight the wave with full-capability modules and allocated energy.
5. Re-dock, drive on, spend the module and debris.

That is a loop with one big decision per cycle, in a fixed place, which is what
a mobile RTS session wants.

---

## Cost, honestly

This is not an increment. It touches the resource model, the build catalogue,
the base, the HUD, the wave trigger and the drone's job system. The parts that
already exist and help:

- `module_forms` already swaps the chassis mesh by tier — the growth art is there.
- The drone's salvage job system already moves things from the map to the player.
- Modules are already meant to be nodes with behaviour scripts, per CLAUDE.md.

The parts that do not exist at all: cables, undock/dock states and their
timings, per-module hull and targeting, the energy dial, module caches, and a
build catalogue keyed by owned module types instead of mass cost.

**Recommended order**, each step shippable and testable on its own:

1. Invert base growth: tier from Debris, slots per tier, HUD shows both. No
   modes yet. *Smallest change that fixes the direction error.*
2. Modules as slotted nodes with mobile-mode behaviour. Build menu becomes
   slot-filling. Still no deploy.
3. Deploy/undock with cables and full-capability behaviour.
4. Energy and support powers.
5. Module caches replace mass debris as the wave trigger.

Steps 1 and 2 are worth doing regardless of what the answers to Q1–Q9 turn out
to be. Step 3 is where the answers start to matter.
