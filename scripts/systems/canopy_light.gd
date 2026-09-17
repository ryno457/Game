class_name CanopyLight
extends RefCounted
## Moonlight through the biodome's canopy, as a light cookie.
##
## The design brief says the player is inside a SEALED BIODOME and nothing in
## the frame has ever said so — the map reads as open ground under a night sky.
## This throws a hex lattice of structural ribs across the floor, which says
## "there is a roof on this" for the price of one texture fetch inside a light
## loop. It is the shadow of a thing that does not have to exist: no geometry,
## no draw call, no triangle.
##
## A SPOT, BECAUSE THE MOON CANNOT DO IT. Verified against the engine's own
## shader source in 4.7.2: `projector_rect` is present for spot, omni and area
## lights and absent for directional. A DirectionalLight3D has no frustum to
## project through, so the sun/moon in this scene can never carry a cookie. The
## canopy therefore needs a light of its own, and that light's only job is the
## pattern — it casts no shadows, because the moon already does and a second
## shadow-casting light is the most expensive thing on this renderer.
##
## OFF BY DEFAULT, AND NOT BECAUSE IT IS WRONG. A SpotLight3D with anything in
## light_projector contributes exactly ZERO on this machine — measured on a
## bare scene, on Forward+ and Mobile alike, with an imported texture and with
## a runtime ImageTexture, while the same spot without a projector lights it
## fine. That is a software-Vulkan (lavapipe) limitation and it cannot be told
## apart from an engine bug without a real GPU, so this ships disabled and
## terrain_lit.gdshader carries the canopy in world space instead. Turn it on
## the day there is a phone to test it on.
##
## POINTING STRAIGHT DOWN, which is not where the moon is. Tilting it to match
## the moon's 38 degrees would be more truthful about where the light comes
## from and would slide the cone off the map: covering 150 m from a shallow
## angle needs either an enormous cone or a light so far away the pattern
## stretches to nothing. Coverage of the playable area wins. The canopy is
## overhead, so light through it arriving from overhead is not a lie either.

const COOKIE := "res://textures/canopy_cookie.png"


static func build(p: BiomePalette, map_size_m: Vector2) -> SpotLight3D:
	if not p.canopy_enabled or not ResourceLoader.exists(COOKIE):
		return null
	var s := SpotLight3D.new()
	s.name = "CanopyLight"
	# Above the middle of the map, high enough that the cone covers it.
	s.position = Vector3(map_size_m.x * 0.5, p.canopy_height_m,
		map_size_m.y * 0.5)
	s.rotation_degrees = Vector3(-90.0, 0.0, 0.0)
	# The half-angle that just covers the map's longest axis from that height,
	# plus a margin. Derived rather than typed: change the map size or the
	# height and the cone still covers it.
	var reach := map_size_m.length() * 0.5 * p.canopy_cover
	s.spot_angle = clampf(rad_to_deg(atan(reach / maxf(1.0, p.canopy_height_m))),
		5.0, 89.0)
	s.spot_range = p.canopy_height_m * 2.0
	# Flat falloff. A spot normally wants its edge to fade, but this one is
	# standing in for a roof: the pattern should be as strong over the far
	# plateau as over the near one, and a falloff would read as a second,
	# rounder pool of light laid over the canopy.
	s.spot_attenuation = p.canopy_attenuation
	s.light_energy = p.canopy_energy
	s.light_color = p.canopy_colour
	s.light_projector = load(COOKIE)
	s.light_specular = 0.0          # the pattern belongs in the diffuse only
	s.shadow_enabled = false
	s.light_bake_mode = Light3D.BAKE_DISABLED
	return s
