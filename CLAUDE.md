# SENTINEL — project instructions

Mobile 3D real-time strategy. Player is a Sentinel machine stranded on a hostile
planet, escaping via teleporter from inside sealed biodomes.

Full design brief: `docs/design-brief.md` — read it before any gameplay work.
Balance reference: `docs/prototype-balance.md` — tuned values from the working
JS prototype, carry these over rather than re-deriving them.

---

## Stack — decided, do not relitigate

- **Godot 4.7**, GDScript. Not C#, not Python, not another engine.
- **Heightmap terrain deformation, NOT voxel.** Voxel gives overhangs and caves
  but will not hold framerate on a mid-range phone under thermal throttle.
  Craters and trenches come from a displacement heightfield plus a collision
  heightmap updated per-chunk.
- **Flow-field pathfinding, not per-unit A*.** One shared field per order group.
  Must rebuild affected chunks when terrain deforms.
- **MultiMesh** for unit rendering.

## Conventions

- **Everything tunable lives in `.tres` Resources, never in code.** Unit stats,
  module definitions, wave tables, adaptation rules, mission scripts. If a
  number is in a `.gd` file, that is a bug.
- **Composition over inheritance.** Modules are nodes with behaviour scripts.
  Detaching a module is a reparent operation, not a type change.
- **Global event bus autoload.** Systems emit signals; they do not call each
  other directly.
- **Deterministic sim + input replay logging.** Highest-value debugging
  investment in the project. Build it early, not when it hurts.

---

## Scope discipline

Ship target for v1 is **3 missions in 1 biodome**, not 9 in 3.
Do not build content for biodomes 2 and 3 until v1 ships.

Current phase: **grey-box vertical slice.** No art, no audio. Placeholder
capsules and cubes only. Do not suggest asset work.

## Risk order — prove these before building on top of them

1. Deformable 3D terrain holding 60fps on a physical mid-range Android phone.
   This is the largest unknown in the project. If it fails, the fallback is
   crater decals plus a collision-only heightmap, which changes the design.
2. Pathfinding that reacts correctly to a freshly dug U-shaped trench.
3. Save/load of a deformed heightfield. Naive serialization is megabytes per
   save — store the procedural seed plus a deformation diff.

---

## Hard-won lessons from the prototype

- **Terrain deformation needs to be roughly 5x deeper than feels intuitive.**
  First pass had the excavator digging at a rate that looked like it worked but
  never actually breached the impassable threshold. Trenches read as cosmetic
  dents. Always verify deformation against the passability threshold with a
  headless test, never by eye.
- **Module recall must cost something.** In the prototype it is free and
  instant, which removes the decision entirely. Needs a cooldown, a salvage
  cost, or a vulnerable travel-back animation.
- **Incidental terrain scarring from weapons can trap the player's own units.**
  Keep per-shot deformation small. Test long firefights near a static turret.
- The attached-vs-detached tradeoff is the core of the game. Every module must
  do something genuinely useful in both states, or the decision collapses.

---

## Working agreement

- Commit before and after any multi-file change. Never leave the tree dirty
  across a session boundary.
- Write a GUT test for any system with a numeric threshold. Balance bugs are
  invisible without them.
- When something is a feel question — does this have weight, is this fair, does
  this read clearly — stop and ask rather than guessing. Those are not mine to
  decide.
- Prefer a boring working implementation over a clever one. This codebase will
  be read months from now by someone rebuilding context from scratch.
