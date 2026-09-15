class_name MiniMap
extends Control
## The corner map, drawn rather than rendered.
##
## A second Viewport with a second camera would cost a whole extra pass over
## the scene for a panel two hundred pixels wide. This draws the fog texture
## stretched to the panel and stamps a dot per contact on top, which is a
## handful of draw calls and reads better at that size anyway — a real
## top-down render of a 150-metre map at 200 pixels is mush.

var fog: FogOfWar
var field_size := Vector2(150.0, 112.0)

## Filled by the owner each frame it wants a repaint. Kept as plain arrays of
## {pos, colour, size} so the minimap knows nothing about units, debris or
## wrecks — it draws dots.
var blips: Array[Dictionary] = []
var module_pos := Vector2.ZERO
var view_centre := Vector2.ZERO
var view_radius := 0.0

var _fog_tex: ImageTexture


func bind(p_fog: FogOfWar, size_m: Vector2) -> void:
	fog = p_fog
	field_size = size_m
	_fog_tex = p_fog.texture()


func _draw() -> void:
	var r := Rect2(Vector2.ZERO, size)
	draw_rect(r, Color(0.02, 0.05, 0.07, 0.92))
	if _fog_tex != null:
		# The fog texture IS the explored map: one channel, one texel per cell.
		# Tinted rather than drawn white so it reads as terrain, not as a mask.
		draw_texture_rect(_fog_tex, r, false, Color(0.16, 0.52, 0.48, 0.95))

	for b in blips:
		var p: Vector2 = _to_panel(b.pos)
		draw_circle(p, b.get("size", 2.4), b.colour)

	# Where the camera is looking. Without it the player cannot tell which part
	# of the map the main view is showing, which is the one job a minimap has
	# that a fog texture does not do by itself.
	if view_radius > 0.0:
		var c := _to_panel(view_centre)
		var rx := view_radius / maxf(1.0, field_size.x) * size.x
		var ry := view_radius / maxf(1.0, field_size.y) * size.y
		draw_rect(Rect2(c - Vector2(rx, ry), Vector2(rx, ry) * 2.0),
			Color(0.85, 0.95, 1.0, 0.55), false, 1.5)

	draw_rect(r, Color(0.35, 0.75, 0.80, 0.85), false, 2.0)


func _to_panel(world: Vector2) -> Vector2:
	return Vector2(
		clampf(world.x / maxf(1.0, field_size.x), 0.0, 1.0) * size.x,
		clampf(world.y / maxf(1.0, field_size.y), 0.0, 1.0) * size.y)
