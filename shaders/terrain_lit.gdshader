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
uniform vec3 vein_glow : source_color = vec3(0.25, 0.92, 0.70);
uniform float vein_strength = 0.0;
uniform float vein_scale = 0.055;
uniform float vein_sharpness = 9.0;
uniform float threshold_line_strength = 0.85;

varying float v_h;
varying vec3 v_world;

float sample_h(vec2 world_xz) {
	return textureLod(height_map, world_xz / field_size_m, 0.0).r;
}

// Cheap value noise — grain and mottling so flat ground is not a dead surface.
float hash(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
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
	NORMAL = normalize(vec3((hl - hr) * height_scale_m, 2.0 * e, (hd - hu) * height_scale_m));
}

void fragment() {
	vec3 n = normalize(NORMAL);
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
		emit += pool_glow * pool_glow_strength * shore * (0.25 + 0.75 * depth) * ripple;
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

	ALBEDO = base;
	EMISSION = emit * seen;
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
