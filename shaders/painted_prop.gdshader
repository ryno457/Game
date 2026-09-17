shader_type spatial;
render_mode cull_back, specular_schlick_ggx;

// Props and machines, lit by the SAME model as the ground.
//
// Everything that is not terrain used to be lit by Godot's default Lambert
// while the terrain ran a custom light() with a tone ramp whose gain reaches
// 2.98. The moon rig was then tuned so the TERRAIN landed on the reference's
// value — which left every prop, plant and machine underlit by roughly the
// ramp's gain. Measured on a frame: ground 0.155/0.347/0.319 against a module
// at 0.081/0.119/0.128, when the module's albedo is a LIGHT GREY (#b9bdc2) and
// should be the brighter of the two. That is what "the black plants" was.
//
// So this is the terrain's light() with the terrain parts taken out. Same
// half-Lambert into the same 1D ramp, so a grey machine and a teal ground sit
// in one lighting model and the painted hue path reaches both.

uniform vec4 albedo : source_color = vec4(1.0);
uniform sampler2D tone_ramp : filter_linear, repeat_disable;
uniform float tone_ramp_strength = 1.0;
uniform float terminator_k = 1.45;
uniform float roughness_v : hint_range(0.0, 1.0) = 0.9;
uniform vec3 emission_tint : source_color = vec3(0.0);
uniform float emission_energy = 0.0;
// Baked occlusion arrives in COLOR_0 on every generated asset. See
// ModelLibrary: the glTF importer cannot be trusted to wire it up.
uniform bool use_vertex_colour = true;
// A dark line around the form, the same rule the ground uses. Not black: a
// black outline reads as clip art and the reference's measured ink holds real
// chroma.
uniform float rim_ink = 0.0;

// HIGH-DETAIL BAKED MAPS, from tools/blender/bake_machines.py.
//
// The ground's detail came from modelled vines — organic shapes at metre scale.
// A machine's is the opposite kind: panel seams and the small catch of light
// along a chamfer. That is what reads as MANUFACTURED, which is the whole point
// of the machines being visually separate from the alien landscape, and none of
// it exists in a 528-triangle procedural hull.
//
// These use NORMAL_MAP and so need a TANGENT. The machine models already carry
// one; what they did NOT carry was UVs, which the bake tool unwraps and
// re-exports.
uniform sampler2D detail_n : hint_normal;
uniform sampler2D detail_ao;
uniform float detail_strength = 0.0;   // 0 skips both fetches
uniform float detail_ao_strength = 0.7;

varying vec3 v_col;
varying vec3 v_normal_w;
varying vec3 v_view_w;

void vertex() {
	v_col = use_vertex_colour ? COLOR.rgb : vec3(1.0);
	v_normal_w = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
	v_view_w = normalize(CAMERA_POSITION_WORLD
		- (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz);
}

void fragment() {
	vec3 base = albedo.rgb * v_col;
	if (rim_ink > 0.0) {
		// Facing ratio: 1 straight on, 0 at a grazing silhouette. Darkening the
		// grazing edge draws the line all the way round the form without a
		// second geometry pass, which a 600-unit MultiMesh cannot afford.
		float face = clamp(dot(normalize(v_normal_w), normalize(v_view_w)),
			0.0, 1.0);
		float line = pow(1.0 - face, 2.4) * rim_ink;
		base = mix(base, base * vec3(0.26, 0.38, 0.42), line);
	}
	if (detail_strength > 0.0) {
		NORMAL_MAP = texture(detail_n, UV).rgb;
		NORMAL_MAP_DEPTH = detail_strength;
		// AO into the pigment as well as the AO slot: on this dim rig the
		// ambient term is small, so an AO that only darkens ambient barely
		// shows on the thing it is meant to describe.
		float o = texture(detail_ao, UV).r;
		base *= mix(1.0, o, detail_ao_strength);
		AO = o;
		AO_LIGHT_AFFECT = 0.4;
	}
	ALBEDO = base;
	ROUGHNESS = roughness_v;
	SPECULAR = 0.12;
	EMISSION = emission_tint * emission_energy;
}

void light() {
	float ndl = dot(normalize(NORMAL), LIGHT);
	// Half-Lambert into the ramp, exactly as terrain_lit.gdshader does it:
	// clamping at the terminator crushes the shadow side to flat black, which
	// on a dark map is most of the object.
	float t = pow(clamp(ndl * 0.5 + 0.5, 0.0, 1.0), terminator_k) * ATTENUATION;
	vec3 tone = texture(tone_ramp, vec2(t, 0.5)).rgb;
	tone = mix(vec3(t), tone, tone_ramp_strength);
	// No ALBEDO here. The engine multiplies DIFFUSE_LIGHT by albedo after
	// light() returns, so writing it here squares it.
	DIFFUSE_LIGHT += LIGHT_COLOR * tone;
}
