# Baking detail in Blender, using it in Godot

Research for the high-detail-source → baked-map pipeline. Gathered September
2026; every engine-side claim below was checked against the Godot source or the
official docs rather than taken from a tutorial, because the tutorials disagree
with each other on two of these points.

## Can Godot use normal maps at all, on Mobile?

**Yes.** `NORMAL_MAP_USED` is present throughout
`servers/rendering/renderer_rd/shaders/forward_mobile/scene_forward_mobile.glsl`
(the tangent-frame branch is at :1171, the normal-map application at :1200), so
the Mobile renderer supports them fully. This was verified by reading the
shipped 4.7 source in this container, not from memory.

## Two gotchas that would have cost a day each

**1. Blender and Godot agree on tangent space — do NOT flip the green channel.**
Godot expects OpenGL-style normal maps (X+, Y+, Z+), and Blender bakes
OpenGL-style. The `Process > Normal Map Invert Y` import option exists for
DirectX-style maps from other engines and must stay OFF for Blender bakes. Half
the tutorials online tell you to invert; they are written for Unity or Unreal.

**2. `Compress > Normal Map` should stay on "Detect".**
It switches the texture to RGTC, which stores only red and green — the two
channels a normal map actually needs, the third being reconstructed — and the
docs are explicit that this "preserve[s] its detail much better, while using the
same amount of memory as a standard RGBA VRAM-compressed texture." Ordinary
block compression produces visible artefacts on normal data.

Caveat for THIS project: `project.godot` sets
`textures/vram_compression/import_etc2_astc=true`, so the Android build uses
ASTC rather than RGTC. ASTC handles normal data acceptably, but it is not the
same path the docs describe, and any artefact hunt should start there.

## The part the tutorials get wrong for our case

Nearly every "Blender to Godot" baking tutorial describes a **high-poly to
low-poly mesh bake**: two meshes, the low one UV-unwrapped, a cage, ray distance
tuning. That is the right workflow for a prop.

**It is the wrong workflow for this terrain, and the reason is that the terrain
has no UVs and never will.** `terrain_lit.gdshader` projects everything from
world XZ specifically so that the ground survives being dug — there is nothing
to unwrap, because there was never an unwrap. The heightfield changes shape at
runtime.

So what we want is the other kind of bake: a **flat plane over a detailed
scene**, baked to a SEAMLESS TILING texture, which the shader then projects in
world space and repeats. The Blender setup is:

- a detailed source scene built on a plane of known size,
- a flat plane at the same coordinates as the bake target,
- Cycles, `Bake > Normal` (and a second pass for colour),
- the source geometry duplicated across the plane's edges, so features that
  cross the boundary are continuous — this is what makes the result tile.

## The tangent problem, and why we sidestep it

A `NORMAL_MAP` write in a Godot shader needs a TANGENT, and our terrain mesh is
a generated `PlaneMesh` grid with no tangents.

We do not need one. The existing shader already perturbs `NORMAL` directly in
world space (`detail_normal()`), using the fact that a heightfield's world X and
Z are close enough to tangents that building a real TBN is not worth it. A baked
normal map can be applied exactly the same way: sample it in world XZ, treat
its R and G as slopes along world X and Z, perturb, done. No tangents, no UVs,
no import-time tangent generation, and it survives deformation.

That also means the texture must be imported **without** `source_color` — it is
data, not a picture — which is the same reason `textures/brush_strokes.png` is
imported uncompressed with `detect_3d/compress_to=0`.

## Sources

- <https://raw.githubusercontent.com/godotengine/godot-docs/master/tutorials/assets_pipeline/importing_images.rst> — the authoritative import settings
- <https://blenderartists.org/t/normal-baking-in-blender-4-5-high-poly-to-low-poly-workflow/1604801>
- <https://supermatrix.studio/blog/how-to-create-realistic-pbr-materials-in-blender-for-godot-4>
- <https://salivity.github.io/blender/article/create-seamless-tileable-textures-in-blender>
- <https://bitsoulhosting.com/marketplace/blog/blender-to-godot-4-glb-export-workflow-guide>

---

## Update, 2026-09-16: deformation was cut, and that changed the answer

The section above says the mesh-bake workflow every tutorial describes — a UV
unwrap, a cage, a high-poly and a low-poly — is the wrong one for this terrain,
because the ground can be dug and a deformable surface cannot hold an unwrap.

**Runtime deformation has since been cut from the design**, on the grounds that
the landscape looking right matters more than it being diggable. That inverts
the conclusion, so the note above is kept as the record of why the first
pipeline was built the way it was, and this is what supersedes it.

With a fixed terrain shape, the tutorials' workflow is now exactly right, and
better in two ways than the tiling version:

- **There is no tiling to hide.** The whole 150 x 112 m map bakes into one
  texture and nothing repeats. That is not a better-tuned tile; it is the
  removal of the problem.
- **The unwrap costs nothing to make.** A heightfield is a graph over the XZ
  plane, so `(x / width, z / depth)` is injective over the whole surface with
  no seams, no packing and no overlap — and it is the SAME mapping the shader's
  material map and distance fields already use, so the bake lands in the
  coordinate system the game is already sampling.

**The cage.** Vines sit above the ground, so rays must start above them and
travel down. `cage_extrusion` pushes the low-poly outward along its own normals
to launch from. Too small and the tops of the vines are missed; too large and a
ray launched from one side of a ridge reaches geometry on the other. Set it from
the tallest feature plus a margin (here 1.4 m against a ~0.9 m vine) rather than
by trial.

**Samples.** A NORMAL bake is geometric and a colour-only DIFFUSE bake reads
material values directly — neither is a light integration, so Cycles samples buy
nothing. Four is not a corner cut; forty would produce identical output for
minutes more CPU.

**What this costs if deformation ever comes back.** The whole-map bake becomes
invalid the moment the ground changes shape, and there is no partial re-bake:
Blender is not in the loop at runtime. Returning to deformation means returning
to the tiling approach in this file's first half, which is why it has not been
deleted.
