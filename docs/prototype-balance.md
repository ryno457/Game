# SENTINEL — prototype balance reference

Every number below was extracted from the working JS prototype
(`prototype/sentinel_prototype.html`). **Carry these over to `.tres` rather than
re-deriving them.** They are tuned against each other; changing one in isolation
will not behave.

> The prototype's own header claims "every tunable lives in the DATA block".
> That is not true — most of the numbers below are buried in `step()`,
> `spawnWave()` and `scatterWorld()`. This document is the real DATA block.

---

## World & terrain

| Value | Number | Notes |
|---|---|---|
| Heightfield grid | 150 × 112 cells | `GW`, `GH` |
| Cell size | 16 px | `CELL` |
| World size | 2400 × 1792 px | `GW*CELL`, `GH*CELL` |
| Biodome radius | 842.2 px | `min(WW,WH) * 0.47` |
| Biodome centre | (1200, 896) | world centre |
| Dome soft margin | 18 px | units are held `DOME_R - 18` from the wall |

### Passability thresholds (normalized 0–1)

| Threshold | Value | Effect |
|---|---|---|
| Neutral ground | 0.50 | `GROUND` — what the excavator flattens toward |
| Impassable chasm | below 0.26 | `PIT` |
| Rough ground | below 0.38 | `ROUGH` — movement at 55% speed |
| Ridge | above 0.85 | colour ramp only; no movement effect in the prototype |
| Hard clamp | 0.02 – 0.98 | `deform()` never exceeds this |

### Worldgen

Three octaves of value noise, summed then centred on `GROUND`:

| Octave | Frequency | Weight |
|---|---|---|
| 1 | 0.055 | 0.60 |
| 2 | 0.14 | 0.28 |
| 3 | 0.31 | 0.12 |

Amplitude `(n - 0.5) * 0.30` around `GROUND`, then **14 crash craters**, radius
40–110 px, depth −0.20 to −0.46.

Deterministic LCG seeded at `20260913` (`seed*1664525 + 1013904223`).

### Deformation magnitudes

Falloff is `cos(d/r * π/2)²` — smooth cosine, squared.

| Source | Radius | Delta | Cadence |
|---|---|---|---|
| Weapon impact | 16 px | −0.011 | per bullet hit |
| Chassis rig mining | 16 px | −0.012 | per 0.55 s tick |
| Salvage drone mining | 20 px | −0.016 | per 0.50 s tick |
| Module deploy impact | 30 px | −0.03 | once, on drop |
| **Excavator drone** | 26 px | **−1.5 / second** | continuous while moving |
| Excavator attached (flatten) | 34 px | lerp 0.10 toward `GROUND` | continuous while driving |

**This is the "5× deeper than intuitive" lesson made concrete.** The digger's
−1.5/s over a 26 px radius clears the 0.50 → 0.26 gap in roughly 0.35 s of
sustained digging. Anything gentler reads as a cosmetic dent. Verify any Godot
port against `PIT` in a headless test, not by eye.

---

## Sentinel chassis

| Stat | Value |
|---|---|
| Base hull | 600 |
| Hull per Bastion Plate attached | +250 |
| Speed | 46 px/s |
| Collision radius | 26 px |
| Arrive threshold | 8 px |
| Start position | dome centre + 0.55 × `DOME_R` on Y |
| Start loadout | Salvage Rig, Gun Pod (bays 0 and 1) |
| Module bays | 6 |

### Attached module effects

| Module | Effect |
|---|---|
| Gun Pod | 18 dmg, 0.6 s cooldown, 210 px range |
| Salvage Rig | 4 salvage per 0.55 s, 120 px range |
| Reactor | ×1.45 mining and fabrication speed, multiplicative per reactor |
| Bastion Plate | +250 hull |
| Excavator | flattens terrain while the chassis is under a move order |

---

## Detached units

| Unit | HP | Speed | Radius | Damage | Range |
|---|---|---|---|---|---|
| Salvage Drone | 70 | 78 | 9 | — | — |
| Combat Drone | 110 | 66 | 10 | 14 | 150 |
| Turret | 240 | 0 | 13 | 34 | 230 |
| Digger Drone | 90 | 70 | 10 | — | — |
| Beacon | 140 | 0 | 12 | — | 170 (repair) |

| Behaviour | Value |
|---|---|
| Mobile weapon cooldown | 0.65 s |
| Static weapon cooldown | 0.90 s |
| Combat drone acquisition range | 330 px |
| Combat drone standoff | closes to 80% of weapon range |
| Beacon repair rate | 11 hp/s |
| Drone mining yield | 9 per 0.50 s tick |
| Drone cargo capacity | 25 |
| Deposit range (to chassis) | 46 px |
| Mining approach range | 26 px |
| Unit arrive threshold | 10 px |
| Rough-ground speed multiplier | 0.55 |

Bullets travel at 430 px/s, live 2.2 s, and hit at `target.radius + 5`.

---

## Aliens

| Stat | Formula |
|---|---|
| Spawn count | `2 + floor(wave * 1.4)` |
| HP | `60 + wave*10 + chitin*30` |
| Speed | `42 + swift*13` |
| Damage | `9 + wave*1.6` |
| Attack cooldown | 1.0 s |
| Radius | 10 px |
| Spawn scatter | ±35 px from nest |

Targeting: nearest **unit** within 260 px, otherwise the chassis. Burrowing
aliens ignore heightfield passability but are still held inside the dome.

Chitin damage resistance: `max(0.45, 1 - chitin*0.14)` — floors at 55% damage
taken, reached at 4 stacks.

---

## Economy & mission

| Value | Number |
|---|---|
| Starting salvage | 60 |
| Salvage nodes | 34, each 60–110 salvage, within `DOME_R - 70` |
| Fragment nodes | 7 placed, 5 required, at 0.45–0.95 × `DOME_R` |
| Nests | 4, 420 HP, at 0.86 × `DOME_R` |
| Salvage per alien kill | 6 |
| Salvage per nest kill | 45 |
| Wave interval | 45 s |
| Teleporter charge (hold the line) | 35 s |

### Module costs

| Module | Cost |
|---|---|
| Salvage Rig | 20 |
| Excavator | 25 |
| Gun Pod | 30 |
| Bastion Plate | 35 |
| Reactor | 40 |

---

## Adaptation

See `docs/design-brief.md` for intent. The prototype's original trigger was
broken; the corrected rule is:

1. Accumulate reliance per wave in **unit-seconds**, one shared currency:
   - `turret` — seconds a static armed unit (or a *stationary* gun-pod chassis)
     had a hostile in range
   - `drone` — seconds a mobile armed unit had a hostile in range
   - `trench` — seconds a Digger Drone spent actively carving
2. If total reliance `< 6` unit-seconds, **adapt nothing** (passive wave).
3. If the leading tactic holds `< 40%` of the total, **adapt nothing**
   (genuinely mixed play).
4. On an exact tie, **adapt nothing**.
5. Otherwise the leader grants its counter: turret → Chitin Plating,
   drone → Sprint Glands, trench → Burrowing.

| Tunable | Value |
|---|---|
| `ADAPT_MIN_SECONDS` | 6.0 |
| `ADAPT_MIN_SHARE` | 0.40 |

Salvage drones are deliberately excluded from `drone` — mining is not a combat
tactic, and counting it made every economic opening read as a drone swarm.

---

## Known issues carried over from the prototype

These are **not** fixed in the prototype and must be handled in the Godot port.

1. **`flatten()` is frame-rate dependent.** It applies a fixed `lerp(h, GROUND,
   0.10)` per *frame* rather than per second, so the attached Excavator
   flattens roughly twice as fast at 120 fps as at 60. `deform()` is correct
   (dt-scaled); `flatten()` is not. Breaks the deterministic-sim requirement.
   Fix: rate-based strength, `1 - pow(1 - 6.0, dt)` or simply `6.0 * dt` clamped
   to 1.
2. **Weapon scarring is unbounded.** Every bullet hit digs −0.011 at radius 16
   with no floor beyond the global 0.02 clamp. A long firefight in one place
   will dig below `PIT` and trap the player's own units — exactly the hazard
   CLAUDE.md warns about. Fix: floor incidental scarring at `ROUGH` rather than
   the global clamp, so weapons can roughen ground but never sever it.
3. **`bar()` reads `maxHp` on the chassis before it is set** on the first frame
   of a fresh game. Harmless in the prototype because `step()` runs first, but
   it is an ordering dependency worth removing.
