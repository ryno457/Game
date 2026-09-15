shader_type spatial;
render_mode cull_back, diffuse_burley, specular_schlick_ggx;

// Procedural terrain surface. No texture assets — everything here is generated
// in the shader, so there is no art pipeline to maintain during grey-box.
// Passability still reads at a glance: chasm, rough and clear are distinct
// colour bands, with a hard line exactly at the impassable threshold.

uniform sampler2D height_map : filter_linear, repeat_disable;
uniform sampler2D fog_map : filter_linear, repeat_disable;
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

// Surface detail. There are no textures in this project — no image files, no
// UVs on any mesh — so "higher quality ground" means more procedural surface,
// not a bigger bitmap. These are the knobs for how much of it to pay for.
uniform float detail_strength = 0.0;    // bump depth; 0 skips the work entirely
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
	if (detail_strength > 0.0) {
		float d = length(v_world - CAMERA_POSITION_WORLD);
		detail_fade = 1.0 - smoothstep(detail_fade_m * 0.45, detail_fade_m, d);
		if (detail_fade > 0.003) {
			n = detail_normal(v_world.xz, n, detail_fade);
		}
	}
	float slope = 1.0 - clamp(n.y, 0.0, 1.0);

	vec3 base;
	if (v_h < impassable_below) {
		base = col_pool;
	} else if (v_h < rough_below) {
		base = mix(col_pool, col_rough,
			(v_h - impassable_below) / max(0.001, rough_below - impassable_below));
	} else {
		base = mix(col_ground, col_ridge, clamp((v_h - rough_below) / 0.42, 0.0, 1.0));
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
	vec3 emit = vec3(0.0);
	if (vein_strength > 0.0) {
		float w = fbm(v_world.xz * vein_scale * 10.0);
		float ridge = 1.0 - abs(w * 2.0 - 1.0);
		float web = pow(clamp(ridge, 0.0, 1.0), vein_sharpness);
		emit += vein_glow * web * vein_strength * (1.0 - smoothstep(0.3, 0.7, slope));
	}

	// Standing liquid. Brightest at the deepest point and feathered at the
	// shoreline, so a freshly dug trench fills in rather than stamping a
	// hard-edged puddle the moment it breaches.
	if (pool_glow_strength > 0.0) {
		float depth = clamp((impassable_below - v_h) / max(0.001, impassable_below), 0.0, 1.0);
		float shore = smoothstep(-0.03, 0.05, impassable_below - v_h);
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

	ALBEDO = base;
	EMISSION = emit * seen;
	// Back to view space, which is what the fragment stage wants written.
	NORMAL = normalize((VIEW_MATRIX * vec4(n, 0.0)).xyz);
	ROUGHNESS = mix(0.95, 0.7, smoothstep(0.3, 0.8, slope));
	// Wet ground under the waterline. A pool that is as matte as the rock
	// beside it does not read as liquid however brightly it glows.
	if (v_h < rough_below) {
		float wet = smoothstep(rough_below, impassable_below - 0.04, v_h);
		ROUGHNESS = mix(ROUGHNESS, 0.12, wet);
		SPECULAR = mix(0.12, 0.6, wet);
	} else {
		SPECULAR = 0.12;
	}
}
