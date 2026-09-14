# Spike B — flow field vs a freshly dug U-trench

Risk item 2. Decides whether trenches are a real defensive tool or a
decoration, and therefore whether **Burrowing** is a counter or just unfair
scaling.

Unlike Spike A this is a **correctness** question, so it runs headlessly and
deterministically — no device, no eyeballing:

```
godot --headless --path . --script tools/spike_b_scenario.gd
```

Ground is deliberately **flat**: the dug trench is the only obstacle, so
nothing else can explain a result.

---

## Verdict

**Correctness passes. Performance fails, and the fix is not "make it faster".**

| Criterion | Result | |
|---|---|---|
| Units reach the goal | 100% of 120 | ✅ |
| Nobody trapped in the U pocket | 0 | ✅ |
| No wall-grinding | 0.00% of unit-seconds | ✅ |
| No diagonal corner-cutting | 0 | ✅ |
| Burrowers ignore the trench | 126.9 m vs 140.4 m detour | ✅ |
| Full rebuild fits one frame | **111 ms vs 16.67 ms budget** | ❌ |

## Why the pocket never traps anyone

The integration field is a **true cost-to-goal** produced by Dijkstra from the
goal cell. A true distance field has no local minima, so there is no pocket to
sit in — the cell at the back of the U simply has a higher cost than the cells
leading back out. A potential or steering field would trap units there; this is
the whole reason CLAUDE.md specifies a flow field.

Two implementation details do real work and must not be lost:

- **No corner cutting.** A diagonal step is only legal when both orthogonal
  neighbours are passable. Without it units slip through a one-cell-thick
  trench wall and the trench does nothing at all.
- **Rebuild on deform.** A dig anywhere can change routes anywhere, so this is
  a full rebuild, not a chunk patch. Chunk-local repair is only valid when the
  dig cannot affect connectivity — exactly the case a trench breaks.

## The performance finding

Full rebuild over 16,756 reachable cells:

| Version | Cost |
|---|---|
| First implementation | 309 ms |
| Precomputed passability/cost arrays | **111 ms** |

The first version called `is_passable_cell()` and `cell_cost()` per neighbour
visit — roughly 270k GDScript function calls per build, which dominated
everything else. Flattening them into two arrays in one linear pass gave 2.8×.

111 ms is still **6.7× over a one-frame budget**. But the next result says that
does not matter.

## Latency is cheap — which decides the fix

A stale field costs almost nothing, so the rebuild does not need to be fast, it
needs to be **off the critical path**:

| Rebuild lands | Arrival | Trapped | Grinding | Mean path |
|---|---|---|---|---|
| Same frame | 100% | 0 | 0.00% | 140.4 m |
| 7 frames late (~110 ms) | 100% | 0 | 0.00% | 140.8 m |
| 30 frames late (~500 ms) | 100% | 0 | 0.00% | 142.3 m |

Half a second of staleness costs **1.9 m of path, about 1.4%**, and traps
nobody. Units commit a little further toward the trench before turning, which
is exactly the expected signature and is imperceptible.

**Recommendation:** rebuild on a `WorkerThreadPool` task and swap the field in
when it completes, with amortizing across frames as the fallback. Do not
micro-optimize Dijkstra, and do not reach for GDExtension — the budget problem
is a scheduling problem.

## Burrowing works, and its strength is a tuning lever

Burrowers path 126.9 m — essentially the straight line — against the walkers'
140.4 m detour, 10% shorter. The *mechanism* is confirmed: identical field,
one flag, no separate movement system.

The *magnitude* is a property of this scenario's trench (16 m deep, 26 m tall,
on a 150 m map), not of the design. Trench size and placement are how you make
the tactic matter; 10% is what a small trench buys.

## What this scenario does NOT establish

- **Weighted vs uniform cost is untested here.** Both produce identical
  140.4 m paths because the ground is flat, so no cell is ever rough. The
  comparison needs real terrain to mean anything.
- Rebuild cost is measured on a desktop CPU. A phone will be slower; the
  threaded-rebuild recommendation gets more important, not less.
- Nothing about multiple simultaneous order groups, which is where "one shared
  field per group" starts to cost real memory.
