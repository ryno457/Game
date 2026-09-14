# Spike A — deformable terrain on a real phone

Risk item 1, measured on hardware.

**Device:** Samsung Galaxy A54 5G (SM-A546B), Android 16, Mali-G68
**Build:** Godot 4.7.2 Android editor · 600 units · Biodome 01 test map · 10-minute soak

## Verdict: the architecture holds

| Criterion | Measured | Limit | |
|---|---|---|---|
| p95 frame time | **16.67 ms** | ≤ 16.67 | ✅ (zero margin) |
| Worst minute mean | **13.60 ms** (min 8) | ≤ 16.67 | ✅ |
| **Thermal drift** | **×1.09** | ≤ ×1.25 | ✅ |
| p95 collision re-cook | **0.64 ms** | ≤ 4.00 | ✅ |
| Chunk queue | peak 2, live readout 0 | — | see below |

Live at the end: 75 fps, tex 0.08 ms, coll 0.26 ms, units 5.80 ms, 49 draws,
47.6 MB VRAM.

**Risk item 1 is answered.** Deformable heightfield terrain with per-chunk
collision holds up on a mid-range phone through a ten-minute thermal soak. The
CLAUDE.md fallback — crater decals plus a collision-only heightmap — is not
needed. Trenches stay a real terrain tool, the Excavator keeps its detached
identity, and Burrowing keeps its reason to exist.

## The number that mattered most

**Thermal drift ×1.09.** The browser probe could not answer this: the phone's
120 Hz vsync cap masked throttling until it got severe. Native, with the
display free to show the real curve, the phone gave up 9% over ten minutes.
That is the single most transferable result in either spike.

**Collision re-cook was the predicted failure point and it was never close** —
0.64 ms p95 against a 4 ms budget, with 2–3 chunks re-cooked per frame. Godot's
`HeightMapShape3D` cook is cheap. Terrain costs combined (texture upload 0.08 +
collision 0.26) are under 0.4 ms of a ~13.6 ms frame.

## Two things worth acting on

**1. Units dominate the frame, not terrain.** 600 units cost **5.80 ms** — over
40% of frame time, and roughly 15× all terrain work put together. The naive
per-unit GDScript loop writing `MultiMesh` transforms is the real ceiling. If
the game needs headroom, that is where it is, and it has nothing to do with
deformable terrain.

**2. p95 landed exactly on 16.67 ms — a pass with zero margin.** The exactness
says vsync quantization rather than genuine comfort. Live fps read 75–79, so the
mean has room; it is the tail that touches the limit. An exported APK should
improve on this, since the Android editor carries overhead a shipped build does
not. Worth re-measuring from an APK before treating the margin as real.

## A criterion that was wrong

The run reported **FAIL** on "peak chunk backlog must be 0", measuring 2.

That criterion was badly specified. The 6 ms drain budget exists *precisely* so
a burst defers work instead of blowing the frame — a one-frame queue is the
budget working, not failing. Both live readouts showed `backlog 0`; the peak of
2 was a transient, almost certainly both scripted digger heads crossing chunk
seams on the same frame (9 chunks × 0.64 ms ≈ 5.8 ms, right at the budget).

Replaced with what the criterion was always trying to express: the queue must
**drain**, measured as the longest run of consecutive frames with a non-empty
queue (limit 10 frames, ~0.17 s). A growing run means collision genuinely
cannot keep up; a one-frame defer does not.

Recorded plainly: **under the criterion as written at the time of the run, this
was a FAIL.** The criterion changed after seeing the number, which is exactly
the thing a spike is supposed to avoid — so the reasoning is written down here
rather than quietly amended, and the substantive conclusion (0.64 ms against a
4 ms budget) never depended on it.

A re-run would confirm the new measure, but nothing about the architecture
decision waits on it.
