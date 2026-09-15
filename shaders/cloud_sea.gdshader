shader_type spatial;
render_mode cull_back, unshaded, depth_draw_opaque, diffuse_burley;

// The cloud deck the peaks stand above.
//
// One horizontal plane under the map, filling every gap where the terrain has
// discarded itself. Unshaded on purpose: a real lit surface would need normals
// out of the noise gradient and would still not look like cloud, whereas a
// hand-rolled sun term costs three lines and is directly tunable.
//
// The noise helpers below are duplicated from terrain_lit.gdshader rather than
// shared through an include. They are ten lines, the two shaders are free to
// diverge, and a shared include is one more file to get wrong for no saving.

uniform vec3 lit_colour : source_color = vec3(0.86, 0.93, 1.00);
uniform vec3 shadow_colour : source_color = vec3(0.19, 0.28, 0.40);
uniform vec3 deep_colour : source_color = vec3(0.05, 0.09, 0.16);
uniform vec3 horizon_colour : source_color = vec3(0.30, 0.55, 0.62);

uniform float cloud_scale = 0.012;      // cycles per metre
uniform float coverage = 0.48;          // how much of the deck is cloud
uniform float softness = 0.30;          // edge feather
uniform float scroll_mps = 0.6;
uniform float relief = 0.55;            // fake sun term strength
uniform float fade_start_m = 180.0;     // distance the deck blends into sky
uniform float fade_end_m = 420.0;

varying vec3 v_world;

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

// Four octaves. The deck is most of the screen in the gaps between peaks, so
// this is the one place in the project where a full fbm is worth paying for —
// three octaves reads as soup and five is invisible on a phone.
float fbm(vec2 p) {
	return vnoise(p) * 0.52 + vnoise(p * 2.1) * 0.26
		+ vnoise(p * 4.3) * 0.14 + vnoise(p * 8.7) * 0.08;
}

void vertex() {
	v_world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	vec2 p = v_world.xz * cloud_scale;
	float drift = TIME * scroll_mps * cloud_scale;

	// Two layers at different speeds. A single scrolling field reads as a
	// printed sheet being dragged sideways; two shearing against each other
	// reads as weather.
	float upper = fbm(p + vec2(drift, drift * 0.35));
	float lower = fbm(p * 0.63 - vec2(drift * 0.55, drift * 0.2) + 17.3);
	float density = upper * 0.65 + lower * 0.35;

	// Coverage cuts the field into billows; softness feathers the edges so the
	// gaps between peaks do not end in a cookie-cutter line.
	float cloud = smoothstep(coverage - softness, coverage + softness, density);

	// Fake sun: brighter where the field is rising, which is where a real
	// billow would be turned toward the light. The gradient is one extra tap
	// because the second is the sample already taken.
	float slope = fbm(p + vec2(0.035, 0.02)) - upper;
	float lit = clamp(0.5 + slope * 14.0 * relief, 0.0, 1.0);

	vec3 cloud_rgb = mix(shadow_colour, lit_colour, lit);
	// Below the billows, the drop the peaks actually stand over.
	vec3 rgb = mix(deep_colour, cloud_rgb, cloud);

	// Blend into the sky at the rim so the plane has no visible edge.
	float d = length(v_world.xz - CAMERA_POSITION_WORLD.xz);
	rgb = mix(rgb, horizon_colour, smoothstep(fade_start_m, fade_end_m, d));

	ALBEDO = rgb;
}
