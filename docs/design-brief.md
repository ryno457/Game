# SENTINEL — design brief

## Premise

A supply ship has crashed on a hostile planet. Its wreckage is scattered across
three sealed biodomes. The player is a Sentinel machine: an autonomous mobile
base that must scavenge the wreck, build a short-range teleporter to move
between domes, and eventually assemble a full-scale teleporter to leave.

The planet's native life is hostile and **adapts to how the player fights.**

## Structure

- 3 biodomes, 3 missions each, 9 total. **Ship 3 missions in biodome 1 first.**
- Mission 1 is the vertical slice: arrive, scavenge, survive waves, recover 5
  teleporter fragments, hold during teleporter charge.
- Chassis loadout carries forward between missions. Losing modules hurts.

---

## Core mechanic — the modular chassis

The Sentinel has **6 module bays**. Modules can be fabricated with salvage,
attached to a bay, or **detached onto the map** where they become an
independent unit or structure.

Every module does something meaningfully different attached vs detached. This
tension is the game.

| Module | Attached | Detached |
|---|---|---|
| Salvage Rig | chassis auto-mines nearby salvage | Salvage Drone — mines and hauls |
| Gun Pod | chassis gains a turret | Combat Drone — mobile fighter |
| Bastion Plate | +250 chassis hull | Turret — static, long range, high damage |
| Excavator | chassis flattens terrain as it drives | Digger Drone — carves impassable trenches |
| Reactor | +45% mining and fabrication speed | Beacon — repairs nearby friendlies |

Six bays forces real choices. A player who detaches everything has a powerful
field force and a fragile, slow chassis.

**Recall must cost something** — see CLAUDE.md. Free instant recall destroys the
decision.

---

## Deformable terrain

Terrain is a heightfield. Deformation is a single operation: apply a
cosine-falloff delta to cells within a radius.

Thresholds (prototype values, normalized 0–1, neutral ground = 0.50):

- below **0.26** — impassable chasm
- below **0.38** — rough ground, movement at ~55% speed
- above 0.85 — ridge

Sources of deformation:

- Excavator drones carving trenches (fast, deep, deliberate)
- Depleted salvage nodes leaving shallow pits
- Weapon impacts scarring ground over long firefights (small, cumulative)
- Pre-existing crash craters at worldgen

Terrain must matter tactically. Trenches are a real defensive tool. This is why
alien **Burrowing** adaptation exists — to punish over-reliance on it.

---

## Adaptive alien AI

The sim tracks which tool the player leans on between waves. Each wave grants
the aliens a counter-trait:

| Player behaviour | Alien adaptation | Effect |
|---|---|---|
| Static turret defence | **Chitin Plating** | damage resistance |
| Drone swarms | **Sprint Glands** | movement speed |
| Trench digging | **Burrowing** | ignores terrain impassability |

Adaptations stack across waves and persist across missions within a biodome.
They must be **visible in the HUD** — the player has to understand they are
being counter-adapted, or it just reads as unfair difficulty scaling.

Design intent: punish monotony, reward switching tactics.

---

## Controls — touch first

- Drag the map to pan; tap to command.
- Tap a unit or the chassis to select.
- **Drag a module off the dock and drop it on the map to deploy it.** This is
  the signature interaction and must feel physical and immediate.
- The dock occupies the bottom of the screen; keep the play area clear above it.

Design for a 5-inch phone held in one hand, then scale up to tablet. Never the
reverse.

---

## Economy

- **Salvage** — scattered ship wreckage. Funds module fabrication.
- **Teleporter fragments** — rare, 5 per biodome. The mission objective.
- Waves arrive on a timer (~45s in the prototype). Teleporter activation starts
  a hold-the-line countdown.

---

## Deliberately out of scope for v1

- Biodomes 2 and 3
- Multiplayer, of any kind
- Voxel terrain, caves, overhangs
- Procedural mission generation
- Any art or audio beyond placeholders
