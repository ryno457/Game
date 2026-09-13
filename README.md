# SENTINEL

Mobile RTS for Android. You are a Sentinel machine stranded on a hostile
planet, escaping a sealed biodome by scavenging a teleporter out of a crashed
supply ship. The planet's native life adapts to how you fight.

Read **[CLAUDE.md](CLAUDE.md)** before touching gameplay code, then
**[docs/design-brief.md](docs/design-brief.md)**.

---

## Layout

```
autoload/              EventBus (signals) and GameData (the only .tres load point)
scripts/resources/     Resource class definitions — the shape of the data
scripts/systems/       Sim systems. Plain RefCounted where possible, so they test headlessly.
data/                  Every tunable number in the project, as .tres
prototype/             The original JS prototype. Runnable, and the balance source of truth.
docs/                  Design brief and the extracted balance reference
tests/unit/            GUT tests. Every numeric threshold gets one.
```

## Where the numbers live

`docs/prototype-balance.md` is the extracted, annotated balance reference —
every value pulled out of the JS prototype, including the ones that were buried
in `step()` rather than its DATA block. The `.tres` files under `data/` are the
runtime authority; the document explains *why* each number is what it is.

GDScript `@export` defaults exist only so the editor has something to show.
**They are not balance.** If a number matters, it is set explicitly in a `.tres`.

## Running the prototype

Open `prototype/sentinel_prototype.html` in any browser. Touch or mouse.
It is a vertical slice of the whole design: modular chassis, drag-to-detach,
deformable heightfield, salvage economy, teleporter objective, adaptive AI.

## Tests

Tests target [GUT](https://github.com/bitwes/Gut), which is **not yet vendored**
— install it to `addons/gut/` before running:

```
godot --headless -s addons/gut/gut_cmdln.gd -gdir=res://tests -ginclude_subdirs -gexit
```

The suites that exist now cover the two systems with numeric thresholds that
have already cost the project time:

- `test_heightfield.gd` — proves the excavator actually breaches
  `impassable_below`, and that weapon scarring can never trap friendly units.
- `test_adaptation_tracker.gd` — proves an idle player is not counter-adapted.

## What is deliberately not built yet

Terrain rendering, collision heightmap, flow-field pathfinding and the mission
scene are stubs. They sit behind risk item 1 in CLAUDE.md — deformable terrain
holding 60fps on a physical mid-range phone — and that has to be proven on
hardware before anything is built on top of it.

Scope for v1 is 3 missions in biodome 1. Not 9 in 3.
