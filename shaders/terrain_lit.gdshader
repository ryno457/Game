shader_type spatial;
render_mode cull_back, diffuse_burley, specular_schlick_ggx;

// Procedural terrain surface. No texture assets — everything here is generated
// in the shader, so there is no art pipeline to maintain during grey-box.
// Passability still reads at a glance: chasm, rough and clear are distinct
// colour bands, with a hard line exactly at the impassable threshold.

uniform sampler2D height_map : filter_linear, repeat_disable;
uniform sampler2D fog_map : filter_linear, repeat_disable;
// Which low ground is actually a pool. See Heightfield.water — height alone
// cannot tell a basin from the outer rim of an island, because they sit in the
// same band and a fragment can only see its own cell.
uniform sampler2D water_map : filter_linear, repeat_disable;

// WHAT THE GROUND IS MADE OF, one byte per cell.
//
// The reference map is large flat areas of different stuff with hard organic
// borders — moss flats, bare rock, pale sediment at the waterline, and a root
// mat ringing every plateau. A height ramp cannot express that: two places at
// the same altitude are routinely different materials.
//
// filter_nearest on purpose. A blurred lookup would give a material index
// halfway between rock and moss, which is not a material. The border is made
// organic by jittering the SAMPLE POSITION with noise instead, which keeps
// every sample a real slot and gives the hard painterly edge the reference has.
uniform sampler2D material_map : filter_nearest, repeat_disable;

// DISTANCE TO THE THINGS THE SHADING RAMPS OFF. R edge, G root strand, B
// waterline, each normalised over `field_range_m`.
//
// This is the change that replaces posterised bands with gradients. Almost
// every gradient in the reference is a DISTANCE, not a height: ground darkens
// as it nears the edge of the mass, lightens away from a strand, pales toward
// a shoreline. Two places at the same height shade differently depending how
// far they are from a feature, and a height ramp cannot say that at all — which
// is exactly why the banded version reads flat.
//
// A distance field is smooth by construction: it changes by about one per cell,
// so every ramp built on it is continuous. filter_linear, unlike the material
// map, because here a value halfway between two cells is a real distance.
uniform sampler2D field_map : filter_linear, repeat_disable;
uniform float field_range_m = 20.0;
uniform float edge_shade = 0.0;      // darkening as ground nears the drop
uniform float edge_falloff_m = 9.0;
uniform float strand_range_m = 4.0;  // the G channel's own SIGNED range
uniform float strand_shade = 0.0;    // contact shadow beside a root strand
uniform float strand_falloff_m = 3.0;
uniform float shore_pale = 0.0;      // bleaching toward a waterline
uniform float shore_falloff_m = 7.0;

// ROOT STRANDS AS ROUNDED TUBES.
//
// In the reference a root is not a green line painted on the floor — it is a
// tube, lit along its crest and shadowed at its base. That reads as geometry
// without being geometry, and it is the single biggest thing separating the
// reference's roots from a scribble.
//
// The trick is that a distance field already describes a tube. Take a circular
// cross-section of radius `tube_radius_m`: at distance d from the strand the
// surface rises by sqrt(r^2 - d^2), and its normal tilts away from the centre
// by exactly d/r. So the shading normal comes out of the field with no extra
// geometry, no normal map, and no mesh — two texture taps for the gradient.
uniform float tube_radius_m = 0.0;   // 0 disables the whole thing
uniform float tube_blend = 0.8;
// --- PAINTED LIGHT -----------------------------------------------------------
// The three shape cues a painted map is built from, and the colour rule that
// ties them together. See BiomePalette's "Painted light" group for the why.
//
// R = ambient occlusion, G = cast shadow, B = wide curvature (0.5 is flat).
// One fetch for all three, because each costs ~50 taps to compute and a phone
// cannot pay that per fragment: AO alone at 2.4 Mpix would be 120M taps a
// frame. TerrainBuilder.bake_shade pays it once per CELL instead.
uniform sampler2D shade_map : filter_linear, repeat_disable;
uniform float ao_strength = 0.0;        // 0 skips the whole painted-light path
uniform float ao_light_affect = 0.55;
uniform float shadow_strength = 0.0;

// The gradient map. A single scalar illumination value picks a COLOUR here,
// not a brightness — which is the difference between a shadow that is just
// darker and one that is darker, cooler and more saturated the way a painter
// mixes it. 256x1, filter_linear, so the output has no steps anywhere.
uniform sampler2D tone_ramp : filter_linear, repeat_disable;
uniform float tone_ramp_strength = 0.0;
uniform float terminator_k = 1.5;

// Curvature. The FINE scale runs live from four height taps, because it is the
// cheapest thing in this shader and because running it live means a trench dug
// this frame gets its highlighted lip and its dark inner crease this frame —
// which is the specific fix for "trenches read as cosmetic dents".
uniform float curv_gain = 0.0;
// Physical range the baked wide-curvature channel was companded over. Must
// match TerrainBuilder.CURV_RANGE or every crease reads at the wrong depth.
uniform float curv_range = 3.0;

// BIOLUMINESCENT BOUNCE.
//
// In the reference the glow is the dominant light source: ground beside a
// pool measures luma 0.297 against 0.19 for the same ground far from one.
// Godot Mobile has no global illumination worth a Mali-G68's time and an
// emissive material does not light its neighbours, so that lift has to be
// faked — and it comes out FREE here, because the two distance fields it
// needs are already fetched for the tube and the shoreline. No new bake, no
// new tap, about eight ALU.
//
// It modulates by the surface's own albedo, because that is what a real
// bounce does: rock beside a teal pool goes teal, moss goes green-teal.
uniform float bio_pool_gain = 0.0;
uniform float bio_pool_reach_m = 6.0;
uniform float bio_root_gain = 0.0;
uniform float bio_root_reach_m = 2.5;
uniform float crease_ink = 0.0;
uniform float ridge_gain = 0.0;
uniform vec3 ridge_tint : source_color = vec3(0.80, 0.93, 0.78);

uniform vec3 mat_colour[5] : source_color;
uniform vec3 mat_colour_alt[5] : source_color;
uniform float mat_rough[5];
uniform float mat_vein[5];
uniform float mat_stroke[5];
uniform float material_jitter_m = 1.8;
// How FAST the jitter noise varies, in cycles per metre.
//
// This matters more than the amplitude and it was wrong. At 0.33 the jitter
// wavelength is three metres — three times the cell size — so the border wobbled
// as a whole while every individual cell still showed as a square step. The
// jitter has to vary faster than one cell for neighbouring fragments inside the
// same cell to land in different slots, which is what dissolves the staircase
// into a torn edge.
uniform float material_jitter_scale = 1.1;
uniform vec2 field_size_m = vec2(150.0, 112.0);
uniform float height_scale_m = 12.0;
uniform float texel_m = 1.0;
uniform float impassable_below = 0.26;
uniform float rough_below = 0.38;

// Palette and glow come from a BiomePalette resource, not from these defaults.
// The defaults are the grey-box look, kept so the shader still reads sanely if
// it is dropped on a mesh with nothing configured.
uniform vec3 col_pool : source_color = vec3(0.035, 0.045, 0.085);   // the low band: liquid, not a hole
uniform vec3 col_rough : source_color = vec3(0.40, 0.29, 0.17);
uniform vec3 col_ground : source_color = vec3(0.37, 0.36, 0.40);
uniform vec3 col_ridge : source_color = vec3(0.66, 0.64, 0.69);
uniform vec3 col_cliff : source_color = vec3(0.24, 0.23, 0.27);
uniform vec3 fog_tint : source_color = vec3(0.05, 0.06, 0.10);
// How much ambient reaches ground nobody can see. Not zero: the reference
// keeps unexplored ground readable as terrain rather than as a black hole.
uniform float fog_ao_floor = 0.25;

// Bioluminescence. The low band is standing liquid rather than a black hole,
// and it is the brightest thing on the map — in a cavern with one weak sun the
// pools are most of the fill light.
uniform vec3 pool_glow : source_color = vec3(0.18, 0.94, 0.82);
uniform float pool_glow_strength = 0.0;
uniform vec3 pool_glow_alt : source_color = vec3(0.72, 0.28, 0.95);
uniform float pool_alt_mix = 0.0;
uniform vec3 vein_glow : source_color = vec3(0.25, 0.92, 0.70);
uniform float vein_strength = 0.0;
uniform float vein_scale = 0.055;
uniform float vein_sharpness = 9.0;
uniform float threshold_line_strength = 0.85;

// THE EDGE OF THE WORLD. Ground below this height is not drawn at all, so the
// map reads as peaks of a very high range standing above a cloud sea rather
// than as a continuous valley floor. Everything below it is cloud.
//
// Distinct from `impassable_below`, which is a GAMEPLAY threshold (units may
// not walk there). This one is purely "is there ground here", and it sits
// lower, so a shoreline still exists between the two.
uniform float void_below = 0.0;

// Survey grid, as in the reference map. Off by default; it is a readability
// aid for judging distance on a top-down camera, not decoration.
uniform float grid_spacing_m = 0.0;
uniform vec3 grid_colour : source_color = vec3(0.55, 0.85, 0.92);
uniform float grid_strength = 0.18;
uniform float grid_width_px = 1.4;

// --- PAINTERLY ---------------------------------------------------------------
// Brush strokes at MATERIAL level, not as a post-process.
//
// The obvious answer to "make it painterly" is a Kuwahara filter over the whole
// screen, and that is what most engines do. Two reasons it is not what this
// does. First, Godot's CompositorEffect only has limited support on the Mobile
// renderer — compute shaders cannot write the colour texture there — so the
// clean route is unavailable, leaving a screen-reading full-screen quad.
// Second, a Kuwahara kernel is on the order of fifty texture fetches PER PIXEL
// at 2400x1080, on a phone with no measured frame-time headroom.
//
// The technique that actually fits this project is triplanar-style projection
// of a stroke field: it needs NO UVS, which is exactly why it survives ground
// that changes shape every time the player digs. There is nothing to re-unwrap
// because there was never an unwrap.
//
// The strokes FOLLOW THE FORM. Their direction comes from the heightfield
// gradient, which the vertex stage already computes for the normal — so they
// run along the contour the way a painter's would, rather than in a fixed
// screen direction. That is the single thing that stops it reading as noise.
uniform float paint_strength = 0.0;     // master; 0 skips all of it
uniform float stroke_scale = 1.1;       // strokes per metre
uniform float stroke_stretch = 7.0;     // how long a stroke is vs how wide
uniform float stroke_depth = 0.60;      // how hard the stroke bends the normal
uniform float paint_quantise = 0.0;     // albedo posterise steps; 0 is off
uniform float paint_tone = 0.0;         // how much a stroke shifts the COLOUR
uniform float canvas_grain = 0.0;       // the weave under the paint

// The brush sheet. R is the stroke value, GB is its gradient packed to 0..1,
// A is canvas grain. Packing the gradient means ONE FETCH gives both the value
// and the slope needed to bend the normal — computing the gradient in the
// shader would take two more taps and undo the saving.
//
// No `source_color`: this is data, not a picture, and an sRGB conversion would
// bend the packed gradient. It is also imported uncompressed, because block
// compression treats the gradient channels as colour and smears them.
uniform sampler2D brush_tex : filter_linear_mipmap, repeat_enable;

// Surface detail. There are no textures in this project — no image files, no
// UVs on any mesh — so "higher quality ground" means more procedural surface,
// not a bigger bitmap. These are the knobs for how much of it to pay for.
uniform float detail_strength = 0.0;    // bump depth; 0 skips the work entirely
// How much the same detail field shifts the COLOUR, not the normal.
//
// Measured: detail_strength 0.9 tilts the normal about 7 degrees, which under
// this camera and this light moves the shaded value by about +/-13% — and
// only where detail_fade is non-zero. An albedo multiply is one instruction,
// works on every fragment regardless of facing, is untouched by the
// terminator, and is where the reference's contrast actually lives. The build
// carries MORE fine-scale chroma than the references already while carrying a
// third of their fine LUMA: colour wobble with no value structure, which
// reads as a dirty flat.
uniform float detail_albedo = 0.0;

// BAKED DETAIL, from art/detail_source.blend by way of
// tools/blender/detail_source.py. Modelled geometry lit and baked down, not
// noise: the build already carries MORE fine-scale chroma than the reference
// paintings while carrying a third of their fine LUMA, which is what colour
// wobble with no underlying form measures as.
//
// Sampled in WORLD XZ, like everything else here. No UVs, no tangents, no
// unwrap — the ground changes shape when it is dug and there is nothing to
// re-unwrap because there was never an unwrap. The map's R and G are read as
// slopes along world X and Z and used to perturb NORMAL directly, which is
// the same thing detail_normal() already does with noise.
//
// The tile is 26.8 m because at the shipped camera's 19.13 px/m a 512 px
// sheet over 26.8 m is sampled at exactly one texel per screen pixel: mip 0,
// full detail, no aliasing, no texels paid for and not seen.
uniform sampler2D detail_normal_tex : filter_linear_mipmap, repeat_enable;
// source_color on the COLOUR map and deliberately NOT on the normal map.
// The colour bake is an albedo — a picture — so its bytes are sRGB and Godot
// has to linearise them on the way in. Sampling it raw made the ground read
// about eight times too bright: sRGB 0.126 taken as linear is linear 0.126,
// where it means linear 0.0145. The normal map is data and would be bent by
// the same conversion.
uniform sampler2D detail_colour_tex : source_color, filter_linear_mipmap, repeat_enable;
uniform float baked_tile_m = 26.8;
uniform float baked_normal = 0.0;   // 0 skips both fetches entirely
uniform float baked_colour = 0.0;
uniform float detail_scale = 2.6;       // cycles per metre
uniform float detail_fade_m = 55.0;     // past this, flat — and cheaper
uniform float macro_scale = 0.018;      // broad colour drift across the valley
uniform float macro_strength = 0.0;
uniform float striation_strength = 0.0; // banding on steep faces

varying float v_h;
varying vec3 v_world;
// The ground normal in WORLD space.
//
// NORMAL in fragment() is view space in Godot, so every `n.y` down there was
// really asking "does this face the camera's up", not "does this face the
// sky". With a near-top-down RTS camera the two are close enough that the
// slope colouring looked right, which is exactly why it survived this long.
// Carrying the world normal explicitly makes the slope test mean what it says,
// and gives the detail bump a frame to be perturbed in.
varying vec3 v_normal_w;
// Carried from fragment() into light(). Godot allows a varying to be written in
// the fragment stage and read in the light stage, which is the only way to get
// the baked AO, the cast shadow and the live curvature into the tone ramp —
// light() cannot fetch them itself and has no access to fragment locals.
varying float v_shade;   // AO * cast shadow, already weighted
varying float v_curv;    // signed: negative convex, positive concave
varying float v_seen;    // fog of war, so light() can respect it too
varying float v_detail;  // fine surface detail, as a VALUE shift
varying vec3 v_baked;    // baked detail colour, mixed into the pigment


float sample_h(vec2 world_xz) {
	return textureLod(height_map, world_xz / field_size_m, 0.0).r;
}

// Cheap value noise — grain and mottling so flat ground is not a dead surface.
//
// No sin() in the hash. The usual fract(sin(dot(...)) * 43758.5) is fine on a
// desktop GPU and bands visibly on mobile, where the shader compiler is free
// to evaluate it at mediump: sin of a large argument loses all its low bits and
// the "noise" collapses into repeating stripes. This one is pure multiply-add
// and is stable at any precision the driver picks.
float hash(vec2 p) {
	vec3 p3 = fract(vec3(p.x, p.y, p.x) * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}

float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash(i), hash(i + vec2(1.0, 0.0)), f.x),
	           mix(hash(i + vec2(0.0, 1.0)), hash(i + vec2(1.0, 1.0)), f.x), f.y);
}

float fbm(vec2 p) {
	return vnoise(p) * 0.55 + vnoise(p * 2.3) * 0.27 + vnoise(p * 5.1) * 0.18;
}

// Detail bump. ONE octave, not an fbm: this runs per fragment over most of the
// screen, and a full fbm here would cost more than every other thing the
// fragment does put together. At the RTS camera distance one octave of grain
// is all that is visible anyway.
//
// Two extra taps for the gradient rather than a normal map, because a normal
// map would need UVs and an image, and this project has neither.
vec3 detail_normal(vec2 world_xz, vec3 n, float fade) {
	float e = 0.35 / detail_scale;
	vec2 p = world_xz * detail_scale;
	float dx = vnoise(p + vec2(e, 0.0)) - vnoise(p - vec2(e, 0.0));
	float dz = vnoise(p + vec2(0.0, e)) - vnoise(p - vec2(0.0, e));
	// Perturb in the tangent plane. The ground is a heightfield, so world X and
	// Z are close enough to tangents that building a real TBN is not worth it.
	return normalize(n + vec3(-dx, 0.0, -dz) * detail_strength * fade);
}

void vertex() {
	vec3 w = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	float h = sample_h(w.xz);
	v_h = h;
	VERTEX.y += h * height_scale_m;
	v_world = vec3(w.x, VERTEX.y, w.z);

	float e = texel_m;
	float hl = sample_h(w.xz - vec2(e, 0.0));
	float hr = sample_h(w.xz + vec2(e, 0.0));
	float hd = sample_h(w.xz - vec2(0.0, e));
	float hu = sample_h(w.xz + vec2(0.0, e));
	vec3 nw = normalize(vec3((hl - hr) * height_scale_m, 2.0 * e,
		(hd - hu) * height_scale_m));
	v_normal_w = nw;
	NORMAL = nw;
}

// A stroke field, stretched along the contour. One fbm plus two taps for the
// gradient — three evaluations, against a Kuwahara filter's fifty fetches.
//
// `along` runs perpendicular to the slope, so strokes lie across the hill the
// way a brush would; `down` is squashed by stroke_stretch, which is what turns
// round noise blobs into long thin marks.
vec3 paint_strokes(vec2 world_xz, vec3 n, float size_mult, out float tone) {
	// Stroke direction. On a slope it follows the contour, which is what a
	// painter does — the marks describe the form. On FLAT ground there is no
	// contour to follow, and normalising a near-zero gradient gives a direction
	// that flips from pixel to pixel; the first version did exactly that and
	// the strokes vanished into noise on every plateau top. So where the
	// gradient dies, fall back to a slowly-rotating field: still coherent over
	// a few metres, just not tied to a slope that is not there.
	vec2 down = vec2(n.x, n.z);
	float grade = length(down);
	float a = fbm(world_xz * 0.035) * TAU;
	vec2 drift = vec2(cos(a), sin(a));
	down = normalize(mix(drift, down / max(grade, 0.0001),
		smoothstep(0.02, 0.18, grade)));
	vec2 along = vec2(-down.y, down.x);

	// The sheet's strokes all run along +X, so rotating the LOOKUP is what
	// makes them follow the contour. The texture must carry no direction of
	// its own for this to work.
	vec2 sp = world_xz * stroke_scale * size_mult;
	vec2 rot = vec2(dot(sp, along), dot(sp, down) * stroke_stretch);

	// One fetch, replacing three fbm evaluations — twelve value-noise lookups
	// and forty-eight hash operations. Cheaper AND it looks like a brush
	// instead of like noise, which is the rare case where the better-looking
	// option is also the faster one.
	vec4 b = texture(brush_tex, rot);
	float c0 = b.r;
	vec2 g = (b.gb - 0.5) * 2.0;
	float dx = g.x;
	float dz = g.y;

	// The stroke's own value, handed back to modulate ALBEDO.
	//
	// This is the half that was missing. Bending the normal only shows up
	// through the light, and on flat ground under a high sun every pixel has
	// the same N·L — so the first pass changed almost nothing where most of
	// the map is. A painter laying marks on a flat field varies the COLOUR,
	// not the surface angle.
	tone = (c0 - 0.5) * paint_tone * paint_strength;
	// Canvas under the paint. Sampled unrotated and much finer, because a
	// weave belongs to the surface being painted on, not to the marks.
	if (canvas_grain > 0.0) {
		float weave = texture(brush_tex, world_xz * 0.9).a;
		tone += (weave - 0.5) * canvas_grain * paint_strength;
	}

	vec2 bend = along * dx + down * dz;
	return normalize(n + vec3(bend.x, 0.0, bend.y) * stroke_depth * paint_strength);
}

void fragment() {
	// Nothing below the world edge. discard rather than a clip plane because
	// the edge follows the heightfield, which is not a plane — and because the
	// cliff face above it has to keep rendering, which a clip would cut too.
	//
	// discard costs early-Z on a tile-based GPU, so it is OFF unless a map
	// actually asks for it: void_below stays 0 for a continuous map.
	if (void_below > 0.0 && v_h < void_below) {
		discard;
	}
	vec3 n = normalize(v_normal_w);

	// Surface detail, faded out with distance. Two reasons for the fade, and
	// the cheap one is the point: past detail_fade_m the two extra noise taps
	// are skipped entirely, so most of the screen never pays for them. The
	// other reason is that per-pixel bump on distant ground is pure shimmer.
	float detail_fade = 0.0;
	v_detail = 0.0;
	v_baked = vec3(0.0);
	if (detail_strength > 0.0 || detail_albedo > 0.0) {
		float d = length(v_world - CAMERA_POSITION_WORLD);
		detail_fade = 1.0 - smoothstep(detail_fade_m * 0.45, detail_fade_m, d);
		if (detail_fade > 0.003) {
			if (detail_strength > 0.0) {
				n = detail_normal(v_world.xz, n, detail_fade);
			}
			// The baked detail. Two taps, and they replace the reason the
			// ground reads flat: modelled form rather than noise.
			if (baked_normal > 0.0 || baked_colour > 0.0) {
				vec2 buv = v_world.xz / baked_tile_m;
				if (baked_normal > 0.0) {
					vec2 bn = texture(detail_normal_tex, buv).rg * 2.0 - 1.0;
					// Tangent-space R/G as world X/Z slopes. Valid because a
					// heightfield's world X and Z are close enough to tangents
					// that building a real TBN is not worth two more varyings.
					n = normalize(n + vec3(-bn.x, 0.0, -bn.y)
						* baked_normal * detail_fade);
				}
				if (baked_colour > 0.0) {
					v_baked = texture(detail_colour_tex, buv).rgb;
				}
			}
			// The same field, in the domain that survives this camera.
			if (detail_albedo > 0.0) {
				v_detail = (vnoise(v_world.xz * detail_scale) - 0.5)
					* detail_albedo * detail_fade;
			}
		}
	}
	// Material is decided before the strokes, because rock takes shorter,
	// choppier marks than moss and the stroke size comes from the slot.
	vec2 jit0 = vec2(fbm(v_world.xz * material_jitter_scale),
		fbm(v_world.xz * material_jitter_scale + 9.13)) - 0.5;
	int mid0 = clamp(int(textureLod(material_map,
		(v_world.xz + jit0 * material_jitter_m) / field_size_m, 0.0).r * 255.0 + 0.5), 0, 4);
	float stroke_tone = 0.0;
	if (paint_strength > 0.0) {
		n = paint_strokes(v_world.xz, n, mat_stroke[mid0], stroke_tone);
	}
	float slope = 1.0 - clamp(n.y, 0.0, 1.0);

	// Which material this is — the SAME lookup as mid0 above, reused.
	//
	// This used to be computed a second time from character-identical
	// expressions: same jitter scale, same +9.13, same jitter metres, same
	// textureLod of the same map. The two results were necessarily equal, so
	// the fragment was paying a whole extra texture tap and six noise
	// evaluations for a value it already held. A driver may fold the fbm
	// pair; it is much less likely to fold a second textureLod.
	int mid = mid0;

	// Two values per material, mixed by the stroke field where painting is on
	// and by plain noise where it is not — a painter mixes two and reuses them
	// rather than filling flat.
	float blend = fbm(v_world.xz * 0.22);
	vec3 base = mix(mat_colour[mid], mat_colour_alt[mid], clamp(blend, 0.0, 1.0));

	// Height still has a say, but only where it means something: standing
	// water reads as water whatever the ground under it is made of, and the
	// high ridges bleach out.
	if (v_h < impassable_below) {
		base = mix(base, col_pool, 0.80);
	} else if (v_h > rough_below) {
		base = mix(base, col_ridge, clamp((v_h - 0.62) / 0.34, 0.0, 1.0) * 0.55);
	}
	// Steep faces read as exposed rock regardless of height band.
	base = mix(base, col_cliff, smoothstep(0.35, 0.8, slope));

	// Two scales of grain: broad mottling plus fine grit.
	float m = fbm(v_world.xz * 0.09);
	float grit = fbm(v_world.xz * 1.7);
	base *= 0.82 + 0.36 * m;
	base += (grit - 0.5) * 0.05;

	// Macro variation: one very low-frequency drift across the whole valley,
	// so the ground is not one flat colour with grain sprinkled on it. This is
	// what stops a hundred square metres of it reading as a single material.
	if (macro_strength > 0.0) {
		float macro = fbm(v_world.xz * macro_scale);
		base *= 1.0 + (macro - 0.5) * 2.0 * macro_strength;
	}

	// Striation on steep faces. Rock is bedded, and horizontal banding is the
	// single cheapest thing that makes a cliff read as rock rather than as a
	// grey ramp. Keyed to world height, so the bands line up across a face.
	if (striation_strength > 0.0) {
		float bands = vnoise(vec2(v_world.y * 2.7, v_world.x * 0.09 + v_world.z * 0.07));
		base *= 1.0 + (bands - 0.5) * striation_strength
			* smoothstep(0.25, 0.75, slope);
	}

	// --- bioluminescence ----------------------------------------------------
	// Filaments: a ridged fold of the same noise field, so the web costs
	// arithmetic rather than another texture fetch. It fades out on steep
	// faces, where a glowing vein reads as a smear rather than a root.
	// The filament web grows on the ROOT MAT, not everywhere. That is the whole
	// difference between a border of vines and a carpet of them.
	vec3 emit = vec3(0.0);
	float vein_here = vein_strength * mat_vein[mid];
	if (vein_here > 0.0) {
		float w = fbm(v_world.xz * vein_scale * 10.0);
		float ridge = 1.0 - abs(w * 2.0 - 1.0);
		float web = pow(clamp(ridge, 0.0, 1.0), vein_sharpness);
		emit += vein_glow * web * vein_here * (1.0 - smoothstep(0.3, 0.7, slope));
	}

	// Standing liquid. Brightest at the deepest point and feathered at the
	// shoreline, so a freshly dug trench fills in rather than stamping a
	// hard-edged puddle the moment it breaches.
	float wet = textureLod(water_map, v_world.xz / field_size_m, 0.0).r;
	if (pool_glow_strength > 0.0 && wet > 0.001) {
		float depth = clamp((impassable_below - v_h) / max(0.001, impassable_below), 0.0, 1.0);
		float shore = smoothstep(-0.03, 0.05, impassable_below - v_h) * wet;
		float ripple = 0.85 + 0.30 * fbm(v_world.xz * 0.55 + vec2(TIME * 0.05, 0.0));
		// Which colour this basin is. One very low-frequency field, so a whole
		// pool takes one tint and the next one over takes the other, instead of
		// the two marbling together inside a single body of water.
		vec3 water = pool_glow;
		if (pool_alt_mix > 0.0) {
			float pick = smoothstep(0.42, 0.58, fbm(v_world.xz * 0.011 + 41.7));
			water = mix(pool_glow, pool_glow_alt, pick * pool_alt_mix);
		}
		emit += water * pool_glow_strength * shore * (0.25 + 0.75 * depth) * ripple;
	}

	// The passability line. A severed trench must be unmistakable at arm's
	// length on a phone. Readability aid, not art — turn it off for stills.
	if (threshold_line_strength > 0.0 && abs(v_h - impassable_below) < 0.005) {
		base = mix(base, vec3(1.0, 0.32, 0.38), threshold_line_strength);
	}

	// Fog of war: unseen ground goes dark, explored-but-unwatched stays dim.
	// The glow is fogged too — unexplored pools must not give the map away.
	float seen = clamp(textureLod(fog_map, v_world.xz / field_size_m, 0.0).r, 0.0, 1.0);
	v_seen = seen;
	base = mix(fog_tint, base, seen);

	// Survey grid. Screen-space derivatives keep the line one pixel wide at any
	// zoom, which is the whole reason it is drawn here and not as a texture —
	// there is no texture in this project to draw it into.
	if (grid_spacing_m > 0.0) {
		vec2 g = v_world.xz / grid_spacing_m;
		vec2 w = fwidth(g) * grid_width_px;
		vec2 lines = abs(fract(g - 0.5) - 0.5) / max(w, vec2(0.0001));
		float line = 1.0 - min(min(lines.x, lines.y), 1.0);
		base = mix(base, grid_colour, line * grid_strength);
	}

	// Lay the stroke down as a value shift.
	base *= 1.0 + stroke_tone + v_detail;
	// Mixed rather than multiplied: the bake carries the reference's own
	// ground and vine colours, so at full strength it IS the surface.
	if (baked_colour > 0.0) {
		base = mix(base, v_baked, baked_colour * detail_fade);
	}

	// --- distance gradients --------------------------------------------------
	// Three ramps off one texture fetch. Each is an exponential shoulder rather
	// than a linear one, because contact darkening in a painted map falls off
	// fast near the feature and long after it — a linear ramp reads as a fog.
	vec3 draw = textureLod(field_map, v_world.xz / field_size_m, 0.0).rgb;
	// R and B are plain distances over field_range_m. G is SIGNED over its own
	// shorter range: positive outside a root strand, zero at its edge, negative
	// toward its centreline. See TerrainBuilder.bake_fields for why it needs an
	// inside at all.
	vec3 dist = vec3(draw.r * field_range_m,
		(draw.g * 2.0 - 1.0) * strand_range_m,
		draw.b * field_range_m);

	if (edge_shade > 0.0) {
		float t = exp(-dist.r / max(0.01, edge_falloff_m));
		base *= 1.0 - t * edge_shade;
	}
	if (strand_shade > 0.0) {
		// max(dist.g, 0): the contact shadow belongs BESIDE a strand, not on it.
		// Keyed on the raw distance it hit exp(0) = 1 right across the mat and
		// darkened at full strength the very thing it exists to set off.
		float t = exp(-max(dist.g, 0.0) / max(0.01, strand_falloff_m));
		base *= 1.0 - t * strand_shade;
	}
	if (shore_pale > 0.0) {
		float t = exp(-dist.b / max(0.01, shore_falloff_m));
		base = mix(base, base * 1.35 + 0.06, t * shore_pale);
	}

	// --- root strands as rounded tubes --------------------------------------
	// Only INSIDE a strand. dist.g < 0 there, and how far below zero is how far
	// in from the edge — the coordinate a circular cross-section actually wants.
	if (tube_radius_m > 0.0 && dist.g < 0.0) {
		// u: 0 at the strand's edge, growing inward. t: 1 at the edge, 0 at the
		// crest. The section rises from nothing at the rim to full height at the
		// centreline, and a mat wider than 2 * tube_radius_m gets a flat top
		// with domed shoulders rather than a crease down its spine.
		float u = -dist.g;
		float t = clamp(1.0 - u / tube_radius_m, 0.0, 1.0);
		float crest = sqrt(max(0.0, 1.0 - t * t));

		// Which way is out. Two taps rather than screen derivatives: dFdx/dFdy
		// are screen space, which only matches world x/z near the middle of a
		// top-down view and skews at the edges. On the SIGNED field this is
		// well conditioned everywhere; on the unsigned one it was exactly zero
		// across the whole interior, which is what flattened the mat to a mesa.
		float e = 1.0;
		vec2 c = v_world.xz / field_size_m;
		vec2 ue = vec2(e, 0.0) / field_size_m;
		vec2 un = vec2(0.0, e) / field_size_m;
		vec2 away = vec2(
			textureLod(field_map, c + ue, 0.0).g - textureLod(field_map, c - ue, 0.0).g,
			textureLod(field_map, c + un, 0.0).g - textureLod(field_map, c - un, 0.0).g);
		float glen = length(away);
		away = glen > 0.0001 ? away / glen : vec2(0.0);

		vec3 tube_n = normalize(vec3(away.x * t, max(crest, 0.08), away.y * t));
		// Faded by crest so the tube meets the ground rather than ending in a seam.
		n = normalize(mix(n, tube_n, tube_blend * crest));
	}

	// --- painted light: AO, cast shadow, curvature ---------------------------
	// One fetch, three cues. See the uniform block for why they are baked.
	float ao = 1.0;
	float curv = 0.0;
	if (ao_strength > 0.0 || shadow_strength > 0.0 || curv_gain > 0.0) {
		vec3 sh = textureLod(shade_map, v_world.xz / field_size_m, 0.0).rgb;
		ao = mix(1.0, sh.r, ao_strength);
		float cast_shadow = mix(1.0, sh.g, shadow_strength);

		// Curvature at two scales. The wide one is baked (it needs a few cells
		// of reach); the fine one is four taps here, so a trench dug this frame
		// gets its lip and its crease this frame with nothing to re-bake.
		// Undo bake_shade's signed-sqrt compander. Stored that way because
		// curvature is near zero almost everywhere, and a linear 8-bit encode
		// wide enough not to clip spends almost no codes on the values that
		// cover half the map.
		float we = sh.b * 2.0 - 1.0;
		float wide = sign(we) * we * we * curv_range;
		float e = texel_m;
		float lap = sample_h(v_world.xz - vec2(e, 0.0))
			+ sample_h(v_world.xz + vec2(e, 0.0))
			+ sample_h(v_world.xz - vec2(0.0, e))
			+ sample_h(v_world.xz + vec2(0.0, e))
			- 4.0 * v_h;
		float fine = lap * height_scale_m / e;
		// Broad first, crisp on top — the order an airbrushed highlight is laid
		// down. Positive is concave, negative is convex.
		// The gain goes HERE, after both scales are combined and in floating
		// point, so it is a look and not a quantisation. Applying it inside
		// the bake railed 23.5% of the map against the 8-bit ends and drew a
		// hard contour through a quarter of the ground — a manufactured
		// band, in the change whose entire purpose was removing bands.
		curv = clamp((wide * 0.65 + fine * 0.45) * curv_gain, -1.0, 1.0);

		// The crease line goes in the PIGMENT, not the light: a painter puts a
		// dark mark where a form meets the ground and it is there whichever way
		// the sun points. Squared so it stays a line and does not grey the flat.
		float crease = max(curv, 0.0);
		base *= 1.0 - crease * crease * crease_ink;

		v_shade = mix(1.0, ao, ao_light_affect) * cast_shadow;
		v_curv = curv;
	} else {
		v_shade = 1.0;
		v_curv = 0.0;
	}

	// Posterise is OFF by default now. It was the banding: a painter mixing a
	// handful of values is a good description of ALBEDO in a painting and a bad
	// one for a surface that also has to carry distance gradients, and the two
	// fight. Kept as a knob rather than deleted because at a low setting it
	// still helps the flats read as mixed rather than computed.
	if (paint_quantise > 1.0) {
		base = floor(base * paint_quantise + 0.5) / paint_quantise;
	}

	ALBEDO = base;
	// AO darkens AMBIENT; ao_light_affect is folded into v_shade for the direct
	// term instead, because a custom light() bypasses the engine's own AO path.
	AO = ao;
	AO_LIGHT_AFFECT = 0.0;
	// The bioluminescent lift. After the fog, because unexplored ground must
	// not be given away by the glow of something the player has not found.
	if (bio_pool_gain > 0.0 || bio_root_gain > 0.0) {
		vec3 bio = pool_glow * bio_pool_gain
			* exp(-dist.b / max(0.01, bio_pool_reach_m))
		+ vein_glow * bio_root_gain
			* exp(-max(dist.g, 0.0) / max(0.01, bio_root_reach_m));
		// * ao so the bounce does not climb out of a crevice it cannot reach.
		emit += base * bio * ao;
	}
	EMISSION = emit * seen;
	// Back to view space, which is what the fragment stage wants written.
	NORMAL = normalize((VIEW_MATRIX * vec4(n, 0.0)).xyz);
	ROUGHNESS = mix(mat_rough[mid], mat_rough[mid] * 0.78,
		smoothstep(0.3, 0.8, slope));
	// Wet ground under the waterline. A pool that is as matte as the rock
	// beside it does not read as liquid however brightly it glows.
	if (v_h < rough_below && wet > 0.001) {
		float slick = smoothstep(rough_below, impassable_below - 0.04, v_h) * wet;
		ROUGHNESS = mix(ROUGHNESS, 0.12, slick);
		SPECULAR = mix(0.12, 0.6, slick);
	} else {
		SPECULAR = 0.12;
	}
	// FOG KILLS THE SHEEN TOO.
	//
	// Fogging only ALBEDO leaves a hole: specular is not multiplied by albedo,
	// so on unseen ground — where albedo is a near-black fog_tint and the
	// diffuse term collapses to nothing — the sky's indirect specular is the
	// only thing left, and it is pale. 91% of this map is unseen at the start,
	// and it was rendering as a sheet of bone-white haze with the explored
	// circle as a small green island in it. Exactly inverted: the unknown was
	// the brightest thing on screen.
	//
	// Suppressing SPECULAR by the same `seen` term costs nothing and closes it.
	SPECULAR *= seen;
	// AO carries it into the ambient term as well, so unseen ground is not lit
	// by the sky either.
	AO = min(AO, mix(fog_ao_floor, 1.0, seen));
}


// The diffuse model. This is where the painted look mostly lives.
//
// It used to posterise N*L into steps. That WAS the banding — it was authored,
// not an artefact of precision, which is why turning on debanding would never
// have fixed it. What replaces it is a gradient map: reduce the light to one
// scalar, and use that scalar to look up a COLOUR rather than a brightness.
//
// Three things make that read as paint rather than as Lambert:
//
//  - HALF-LAMBERT. Clamping N*L at zero crushes everything past the terminator
//    to flat black, which reads as a hard band even with no quantisation at
//    all. Remapping to 0..1 across the whole sphere keeps the shadow side alive
//    the way a painter's fill light does.
//  - The RAMP's hue path. Into shadow the ramp goes darker, cooler and MORE
//    saturated, which is what a painter mixes and what plain Lambert cannot do
//    at any number of steps.
//  - CURVATURE biases the lookup rather than being added as a separate grey.
//    So a crest slides up the ramp into the warm end and a crease slides down
//    into the saturated end, and both inherit the hue path for free.
//
// Defining light() overrides the render_mode diffuse model, so this is the
// model or Lambert, never Burley.
void light() {
	float ndl = dot(normalize(NORMAL), LIGHT);

	if (tone_ramp_strength > 0.0) {
		// Half-Lambert: 0..1 across the whole sphere, no clamp at the
		// terminator. pow() then pushes the terminator where the art wants it.
		float t = pow(clamp(ndl * 0.5 + 0.5, 0.0, 1.0), terminator_k);
		t *= ATTENUATION * v_shade;
		// A crest reads lit, a crease reads occluded, regardless of facing.
		t = clamp(t + max(-v_curv, 0.0) * 0.15 - max(v_curv, 0.0) * 0.25,
			0.0, 1.0);

		vec3 tone = texture(tone_ramp, vec2(t, 0.5)).rgb;
		tone = mix(vec3(t), tone, tone_ramp_strength);
		// NO ALBEDO HERE. The engine multiplies DIFFUSE_LIGHT by albedo after
		// light() returns — forward_mobile's `diffuse_light *= albedo`, which
		// is outside any custom-light guard — so writing ALBEDO in here squares
		// it. That was in this shader from the start and it is most of why the
		// map rendered darker than every preview of it: the previews compute
		// albedo * light once, which is the correct picture, and the game was
		// computing albedo * albedo * light.
		DIFFUSE_LIGHT += LIGHT_COLOR * tone;

		// The bright line along a convex crest, gated by the LIT side so a
		// crest in shadow does not glow. This is the other half of what makes
		// a root read as a rounded tube and a fresh trench read as dug.
		if (ridge_gain > 0.0) {
			float ridge = max(-v_curv, 0.0);
			// SPECULAR_LIGHT, not DIFFUSE_LIGHT: the crest line is a light on
			// the surface rather than a property of it, and only diffuse gets
			// multiplied by albedo. Put it in diffuse and dark ground gives a
			// dark highlight, which is the one place it has to stay bright.
			// * v_seen, and it is not optional. This term is added to the light,
			// not multiplied into the pigment, so the fog's albedo has no
			// hold on it: on unseen ground, where the diffuse term collapses
			// to nothing against a near-black fog_tint, this was the ONLY
			// surviving term. 91% of the map is unseen at the start, and it
			// rendered as a sheet of pale green haze with the explored circle
			// as a small island inside it. The unknown was the brightest
			// thing on screen — the exact inverse of what fog is for.
			SPECULAR_LIGHT += ridge_tint * ridge * ridge * ridge_gain
				* max(ndl, 0.0) * ATTENUATION * v_shade * v_seen * LIGHT_COLOR;
		}
	} else {
		// No ramp configured: plain Lambert, still carrying the shape cues.
		// This is the grey-box fallback, so a palette with nothing set still
		// reads sanely. (if/else rather than an early return: Godot rejects a
		// bare `return` in these stage functions.)
		DIFFUSE_LIGHT += LIGHT_COLOR * ATTENUATION
			* clamp(ndl, 0.0, 1.0) * v_shade;
	}
}
