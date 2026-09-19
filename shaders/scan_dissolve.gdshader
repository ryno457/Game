shader_type spatial;
render_mode cull_disabled, depth_draw_opaque, specular_schlick_ggx;

// Scanning and demolecularization, for one object at a time.
//
// Two effects from the supplied guides (docs/reference/shader-guides/) in one
// shader, because they happen to the SAME object one after the other: the
// drone sweeps a band over a piece of debris to read it, then takes it apart.
// One material, two uniforms, no swap between the passes.
//
// WHY THIS IS NOT A FLAG ON painted_prop.gdshader. It would be one branch and
// one fetch, and when `dissolve` is 0 the branch is uniform across the draw
// call, so the arithmetic is nearly free. `discard` is not. A shader that can
// discard has to be treated as one that will, and the tiler gives up early-Z
// for all of it — including the 600-instance scenery MultiMesh that shares
// painted_prop and never dissolves. So the dissolve lives in its own shader
// and is swapped onto the handful of objects actually being eaten.
//
// EVERYTHING ELSE IS painted_prop's, deliberately. Same half-Lambert into the
// same tone ramp, same COLOR_0 vertex colours carrying the baked sky light,
// same detail maps. A machine that is half dissolved has to still look like
// that machine, and it will not if the surviving half is lit by a different
// model.

uniform vec4 albedo : source_color = vec4(1.0);
uniform sampler2D tone_ramp : filter_linear, repeat_disable;
uniform float tone_ramp_strength = 1.0;
uniform float terminator_k = 1.45;
uniform float roughness_v : hint_range(0.0, 1.0) = 0.9;
uniform bool use_vertex_colour = true;

uniform sampler2D detail_n : hint_normal;
uniform sampler2D detail_ao;
uniform float detail_strength = 0.0;
uniform float detail_ao_strength = 0.7;

// THE NOISE THAT DECIDES WHICH FLECK GOES FIRST. Any FastNoiseLite will do;
// ScanFx builds one rather than shipping a PNG, because a 128 px noise is
// smaller as four lines of GDScript than as an imported asset.
uniform sampler2D noise_tex : filter_linear, repeat_enable;
// How many times the noise wraps across the object. Low numbers give big
// chunks, high numbers give dust. 6 is roughly gravel at a 1 m machine.
uniform float noise_scale = 6.0;

// --- the dissolve -----------------------------------------------------------
// 0 is whole, 1 is gone. Run it the other way and the object assembles out of
// nothing with the same lit edge, which is what builds a module; there is no
// separate "build" path because there does not need to be one.
uniform float dissolve : hint_range(0.0, 1.0) = 0.0;
uniform vec4 edge_colour : source_color = vec4(0.55, 0.95, 1.0, 1.0);
uniform float edge_thickness : hint_range(0.0, 0.3) = 0.07;
uniform float edge_energy = 2.5;
// HOW MUCH OF THE ORDER COMES FROM HEIGHT rather than from the noise. At 0 the
// object pops apart at random, which reads as static rather than as a beam
// doing something. At 1 it is a clean wipe with no grain. The mix is what
// makes it look like matter being taken, and it sweeps along the object's own
// Y so it does not depend on the unwrap — see the note on the scanner below.
uniform float dissolve_height_bias : hint_range(0.0, 1.0) = 0.55;
// The object's own height in metres, so the bias can be normalised without a
// bounding box lookup at runtime. Set by ScanFx from the mesh AABB.
uniform float object_h_m = 2.0;

// --- the scan band ----------------------------------------------------------
// Non-destructive: the band lights the surface it crosses and leaves it. -1
// parks it off the object, which is the off switch.
uniform float scan_pos : hint_range(-1.0, 2.0) = -1.0;
uniform float scan_width : hint_range(0.0, 0.5) = 0.06;
uniform vec4 scan_colour : source_color = vec4(0.55, 0.95, 1.0, 1.0);
uniform float scan_energy = 2.5;
// The sci-fi grid inside the beam, in cycles per metre of object rather than
// per UV unit.
uniform float scan_grid_per_m = 40.0;

varying vec3 v_col;
varying vec3 v_local;

void vertex() {
	v_col = use_vertex_colour ? COLOR.rgb : vec3(1.0);
	// OBJECT SPACE, NOT UV. The supplied scanner guide sweeps on UV.y, which is
	// only bottom-to-top if the unwrap happens to run that way — and the models
	// here are unwrapped by tools/blender/bake_machines.py into an atlas, where
	// it does not. Sweeping on the mesh's own Y costs the same and cannot break
	// that way. It also survives a MultiMesh, where every instance shares one UV
	// set but has its own transform.
	v_local = VERTEX;
}

void fragment() {
	float h01 = clamp(v_local.y / max(object_h_m, 0.01) + 0.5, 0.0, 1.0);
	float grain = texture(noise_tex, v_local.xz * noise_scale * 0.1 + 0.5).r;

	if (dissolve > 0.0) {
		// Low values go first. Biasing toward h01 takes the top off before the
		// base; 1.0 - h01 would eat it from the ground up, which is what a
		// build wants and is had for free by driving `dissolve` backwards.
		float order = mix(grain, 1.0 - h01, dissolve_height_bias);
		// The threshold has to clear 1.0 at full progress or the last flecks
		// never go: `order` reaches 1 and a raw `dissolve` of 1 is not greater
		// than it. Widening by the edge leaves nothing behind.
		float thr = dissolve * (1.0 + edge_thickness);
		if (order < thr) {
			discard;
		}
		float edge = step(order, thr + edge_thickness);
		vec3 base = albedo.rgb * v_col;
		if (detail_strength > 0.0) {
			NORMAL_MAP = texture(detail_n, UV).rgb;
			NORMAL_MAP_DEPTH = detail_strength;
			float o = texture(detail_ao, UV).r;
			base *= mix(1.0, o, detail_ao_strength);
			AO = o;
			AO_LIGHT_AFFECT = 0.4;
		}
		ALBEDO = mix(base, edge_colour.rgb, edge);
		EMISSION = edge_colour.rgb * edge * edge_energy;
		ROUGHNESS = roughness_v;
		SPECULAR = 0.12;
	} else {
		vec3 base = albedo.rgb * v_col;
		if (detail_strength > 0.0) {
			NORMAL_MAP = texture(detail_n, UV).rgb;
			NORMAL_MAP_DEPTH = detail_strength;
			float o = texture(detail_ao, UV).r;
			base *= mix(1.0, o, detail_ao_strength);
			AO = o;
			AO_LIGHT_AFFECT = 0.4;
		}
		float band = 0.0;
		if (scan_pos > -0.5) {
			band = smoothstep(scan_width, 0.0, abs(h01 - scan_pos));
			// The grid, on the object's own metres so it does not stretch with
			// the unwrap. +0.2 keeps the beam visible between the lines rather
			// than strobing to nothing.
			float g = clamp(sin(v_local.x * scan_grid_per_m)
				* sin(v_local.z * scan_grid_per_m), 0.0, 1.0);
			band *= g + 0.2;
		}
		ALBEDO = mix(base, scan_colour.rgb, band);
		EMISSION = scan_colour.rgb * band * scan_energy;
		ROUGHNESS = roughness_v;
		SPECULAR = 0.12;
	}
}

void light() {
	// painted_prop.gdshader's, unchanged. See the note there: no ALBEDO in
	// here, because the engine multiplies DIFFUSE_LIGHT by it afterwards and
	// writing it here squares it.
	float ndl = dot(normalize(NORMAL), LIGHT);
	float t = pow(clamp(ndl * 0.5 + 0.5, 0.0, 1.0), terminator_k) * ATTENUATION;
	vec3 tone = texture(tone_ramp, vec2(t, 0.5)).rgb;
	tone = mix(vec3(t), tone, tone_ramp_strength);
	DIFFUSE_LIGHT += LIGHT_COLOR * tone;
}
