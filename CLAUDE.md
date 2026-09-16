# SENTINEL — project instructions

Mobile 3D real-time strategy. Player is a Sentinel machine stranded on a hostile
planet, escaping via teleporter from inside sealed biodomes.

Full design brief: `docs/design-brief.md` — read it before any gameplay work.
Balance reference: `docs/prototype-balance.md` — tuned values from the working
JS prototype, carry these over rather than re-deriving them.

---

## Stack — decided, do not relitigate

- **Godot 4.7**, GDScript. Not C#, not Python, not another engine.
- **Heightmap terrain, NOT voxel.** Voxel gives overhangs and caves but will
  not hold framerate on a mid-range phone under thermal throttle.
- **RUNTIME DEFORMATION IS OUT OF THE DESIGN** (decided 2026-09-16). Trenches,
  craters and weapon scarring are cut. The call was that the landscape looking
  right matters more than it being diggable, and the two were in direct
  conflict: a surface that changes shape cannot hold a UV unwrap, and without
  an unwrap the ground can only be textured by projection and noise, which is
  why it read flat for so long.
  The terrain is now a FIXED shape, which buys a real unwrap, a whole-map
  baked normal and albedo, and a cage bake from high-detail geometry. See
  `docs/research/blender-to-godot-baking.md` and `tools/blender/detail_source.py`.
  The deformation code still exists in `Heightfield.deform()` and its ops; it
  is unused, not deleted.
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

1. ~~Deformable 3D terrain holding 60fps~~ — **resolved by cutting it.** Risks
   2 and 3 below went with it.
2. ~~Pathfinding reacting to a freshly dug trench~~ — no longer arises.
3. ~~Save/load of a deformed heightfield~~ — the map is the procedural seed
   again, so a save is the seed and the game state.
4. **The frame budget is unmeasured on the current build.** Spike A's p95 of
   16.67 ms was measured against a 59-line terrain shader with one texture
   fetch. The shader that ships today is an order of magnitude heavier, plus a
   full-screen ink pass that did not exist then, plus two whole-map baked
   textures. Nothing should be called affordable until it is re-soaked from an
   APK on the A54.

---

## Hard-won lessons from the prototype

- **Terrain deformation needed to be roughly 5x deeper than felt intuitive.**
  Kept although deformation is cut, because the general lesson outlived it:
  the first pass dug at a rate that looked like it worked but never breached
  the impassable threshold, so trenches read as cosmetic dents. An effect that
  looks like it is happening is not evidence that it is. Verify against the
  threshold with a headless test, never by eye.
- **Measure the render, do not judge it.** `tools/look_check.py` scores a frame
  against the reference art's value structure, and `tools/screenshot.sh` takes
  that frame out of the real engine. Both exist because the previews lied:
  Blender's Cycles is a different renderer, a headless boot compiles no shaders
  at all, and the first version of look_check counted unexplored void as dark
  terrain and so passed a frame that was a third too bright.
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
