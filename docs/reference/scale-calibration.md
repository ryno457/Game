# How big is a thing, and how big does it look

## The headline

**Feature sizes transfer from the reference to the game almost one to one.**
Both images sit within 20% of each other in pixels per metre, so a root that
reads as 0.6 m across in the painting should be about 0.6 m across in the game.

An earlier version of this file said the opposite — that the reference was 6x
closer and everything should be authored 6x larger. That was wrong, and the
error is worth recording because it is easy to repeat.

## The measurement

Both images carry a grid, so both can be calibrated. The reliable method is
**autocorrelation read as a curve**, not an FFT argmax:

| | grid period | evidence |
|---|---|---|
| reference 01 | **159 px** | autocorr 0.273 at lag 159, with a clean harmonic at 319 = 2x159 |
| the game, 630 px tall | **108 px** | autocorr 0.223 at lag 108 |

The game's number has an independent check that does not involve the image at
all. The camera sits `hypot(48, 17)` = 50.9 m from the rig at a 58 degree
vertical FOV, so it frames `2 * 50.9 * tan(29 deg)` = 56.5 m vertically. At 630
px that is 11.16 px/m, and 108 px / 11.16 = 9.7 m — the 10 m survey grid, to
within the measurement. Two independent methods agree, so 108 px is real.

Taking the reference's grid as the same 10 m gives it 15.9 px/m against the
game's 19.1 px/m at 1080p. Within 20%. Sizes transfer.

## Why the first attempt was wrong

It took `np.argmax` over an FFT of the column means and got 37.3 px — roughly
159/4. A faint periodic signal buried in strong painted content puts as much
energy in its harmonics as in its fundamental, and argmax has no way to prefer
one over the other. Autocorrelation makes the mistake visible, because the true
period shows up with its harmonics at exact multiples and a harmonic does not.

The lesson is narrow and practical: **never take the argmax of a spectrum as a
period.** Print the curve and look for the harmonic ladder.

## The honest caveat

Reference 01 is a virtual-tabletop map, and the tabletop convention is 5 ft
(1.524 m) per square, not 10 m. If that convention holds, the reference is
really 104 px/m and its features are six times smaller in world terms than this
page assumes.

It does not matter for matching the look, and that is the point worth keeping.
What transfers is **the fraction of a grid square a feature occupies**, because
the grid is the one unit both images show the viewer. A root bundle covering a
third of a grid square should cover a third of a grid square in the game — 3.3 m
against the game's 10 m grid — whatever the painter thought a square meant.

So: measure features in grid squares, not in metres, and multiply by 10.
