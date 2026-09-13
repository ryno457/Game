shader_type spatial;
render_mode cull_back, diffuse_lambert, specular_disabled, shadows_disabled;

// Vertex displacement from a shared heightfield texture. The CPU never
// rebuilds terrain geometry — it only uploads the height texture and re-cooks
// collision. That split is the whole point of the spike: if it fails, it
// should fail on the collision side, and we want to see that separately.

uniform sampler2D height_map : filter_linear, repeat_disable;
uniform vec2 field_size_m = vec2(160.0, 128.0);
uniform float height_scale_m = 12.0;
uniform float impassable_below = 0.26;
uniform float rough_below = 0.38;
uniform float texel_m = 1.0;

uniform vec3 col_chasm : source_color = vec3(0.055, 0.075, 0.145);
uniform vec3 col_rough : source_color = vec3(0.42, 0.30, 0.16);
uniform vec3 col_ground : source_color = vec3(0.33, 0.31, 0.37);
uniform vec3 col_ridge : source_color = vec3(0.62, 0.60, 0.66);

varying float v_h;

float sample_h(vec2 world_xz) {
	return textureLod(height_map, world_xz / field_size_m, 0.0).r;
}

void vertex() {
	vec3 world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	float h = sample_h(world.xz);
	v_h = h;
	VERTEX.y += h * height_scale_m;

	// Finite-difference normal. Chunks are translated only, never rotated or
	// scaled, so a model-space normal is already the world-space one.
	float e = texel_m;
	float hl = sample_h(world.xz - vec2(e, 0.0));
	float hr = sample_h(world.xz + vec2(e, 0.0));
	float hd = sample_h(world.xz - vec2(0.0, e));
	float hu = sample_h(world.xz + vec2(0.0, e));
	NORMAL = normalize(vec3((hl - hr) * height_scale_m, 2.0 * e, (hd - hu) * height_scale_m));
}

void fragment() {
	vec3 c;
	if (v_h < impassable_below) {
		c = col_chasm;
	} else if (v_h < rough_below) {
		c = mix(col_chasm, col_rough, (v_h - impassable_below) / (rough_below - impassable_below));
	} else {
		c = mix(col_ground, col_ridge, clamp((v_h - rough_below) / 0.5, 0.0, 1.0));
	}
	// Hard line exactly at the passability threshold, so a trench that has
	// actually been severed is unmistakable on a phone screen at arm's length.
	if (abs(v_h - impassable_below) < 0.006) {
		c = vec3(1.0, 0.30, 0.36);
	}
	ALBEDO = c;
	ROUGHNESS = 0.95;
}
