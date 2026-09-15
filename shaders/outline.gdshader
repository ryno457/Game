shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, depth_test_disabled, fog_disabled;

// Ink lines, from depth alone.
//
// The reference map has linework around every shape, and the usual way to get
// it in Godot is to read the normal-roughness buffer and look for places where
// the normal turns sharply. THAT DOES NOT COMPILE ON THE MOBILE RENDERER —
// `normal_roughness_buffer` is only defined in the Forward+ GLSL and is left
// undeclared in Mobile (godotengine/godot#78411). The proposal to add it
// (godot-proposals#11992) is still open. So every normal-based outline
// tutorial is unavailable to this project.
//
// Depth is available everywhere, so all of this comes out of the depth buffer:
//
//   · a first difference catches SILHOUETTES — where one thing ends and
//     something much further away begins
//   · a second difference (a Laplacian) catches CREASES — on a flat surface
//     the centre sample equals the average of its neighbours, so anything that
//     does not is a fold
//
// Both are divided by depth, which makes the test scale-invariant: a crease
// forty metres away inks as readily as one under the camera, instead of the
// whole distance fading out.

uniform sampler2D screen_tex : hint_screen_texture, filter_linear;
uniform sampler2D depth_tex : hint_depth_texture, filter_nearest;

uniform vec3 ink_colour : source_color = vec3(0.02, 0.05, 0.06);
uniform float ink_strength = 0.0;          // master; 0 makes this a no-op
uniform float silhouette_threshold = 0.012;
uniform float crease_threshold = 0.003;
uniform float thickness_px = 1.3;
/// Past this, stop inking. Distant ground would otherwise turn into a mesh of
/// lines as every metre of relief crosses the threshold in one pixel.
uniform float fade_m = 140.0;

void vertex() {
	// A 2x2 quad written straight to clip space at the far plane. No camera
	// child node, no cull margin to get wrong.
	POSITION = vec4(VERTEX.xy, 1.0, 1.0);
}

float linear_depth(vec2 uv, mat4 inv_proj) {
	float d = textureLod(depth_tex, uv, 0.0).x;
	vec4 view = inv_proj * vec4(vec3(uv * 2.0 - 1.0, d), 1.0);
	return -(view.xyz / view.w).z;
}

void fragment() {
	vec3 col = textureLod(screen_tex, SCREEN_UV, 0.0).rgb;
	// No early `return` — Godot's shader language forbids it in fragment().
	// The branch is on a uniform, so it is coherent across the whole draw and
	// the depth taps below are skipped for free when the ink is off.
	float line = 0.0;
	if (ink_strength > 0.0) {
	vec2 px = thickness_px / VIEWPORT_SIZE;
	float d = linear_depth(SCREEN_UV, INV_PROJECTION_MATRIX);
	float dl = linear_depth(SCREEN_UV - vec2(px.x, 0.0), INV_PROJECTION_MATRIX);
	float dr = linear_depth(SCREEN_UV + vec2(px.x, 0.0), INV_PROJECTION_MATRIX);
	float du = linear_depth(SCREEN_UV - vec2(0.0, px.y), INV_PROJECTION_MATRIX);
	float dd = linear_depth(SCREEN_UV + vec2(0.0, px.y), INV_PROJECTION_MATRIX);

	float inv_d = 1.0 / max(d, 0.001);
	float silhouette = max(max(abs(dl - d), abs(dr - d)),
		max(abs(du - d), abs(dd - d))) * inv_d;
	float crease = (abs(dl + dr - 2.0 * d) + abs(du + dd - 2.0 * d)) * inv_d;

	line = max(
		smoothstep(silhouette_threshold, silhouette_threshold * 2.4, silhouette),
		smoothstep(crease_threshold, crease_threshold * 3.0, crease));
	line *= 1.0 - smoothstep(fade_m * 0.6, fade_m, d);
	}

	ALBEDO = mix(col, ink_colour, clamp(line * ink_strength, 0.0, 1.0));
}
