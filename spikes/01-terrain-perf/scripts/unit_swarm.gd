class_name UnitSwarm
extends MultiMeshInstance3D
## Placeholder units, drawn as one MultiMesh.
##
## Movement is deliberately naive — seek a wandering goal, slide off
## impassable ground. This is NOT the pathfinding question; that is Spike B.
## The units exist here only to put a realistic per-frame CPU and draw load
## alongside the terrain work.

const MAX_UNITS := 600

var field: DeformField
var impassable_below := 0.26
var rough_speed_mul := 0.55

var _pos: PackedVector2Array = PackedVector2Array()
var _goal: PackedVector2Array = PackedVector2Array()
var _speed: PackedFloat32Array = PackedFloat32Array()
var _rng := RandomNumberGenerator.new()
var _count := 0

var last_update_ms := 0.0


func setup(p_field: DeformField, count: int, p_seed: int) -> void:
	field = p_field
	_rng.seed = p_seed

	var mesh := CapsuleMesh.new()
	mesh.radius = 0.35
	mesh.height = 1.4
	mesh.radial_segments = 6
	mesh.rings = 2

	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.31, 0.89, 0.76)
	mat.roughness = 0.8
	mesh.material = mat

	multimesh = MultiMesh.new()
	multimesh.transform_format = MultiMesh.TRANSFORM_3D
	multimesh.mesh = mesh
	multimesh.instance_count = MAX_UNITS
	# Units cast: 600 shadow casters is part of what the soak must measure.
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON

	_pos.resize(MAX_UNITS)
	_goal.resize(MAX_UNITS)
	_speed.resize(MAX_UNITS)
	for i in MAX_UNITS:
		_pos[i] = _random_point()
		_goal[i] = _random_point()
		_speed[i] = _rng.randf_range(3.0, 5.0)
	set_count(count)


func set_count(count: int) -> void:
	_count = clampi(count, 0, MAX_UNITS)
	multimesh.visible_instance_count = _count


func get_count() -> int:
	return _count


func _random_point() -> Vector2:
	var e := field.extent_m()
	return Vector2(_rng.randf() * e.x, _rng.randf() * e.y)


func update(delta: float) -> void:
	var t0 := Time.get_ticks_usec()
	for i in _count:
		var p := _pos[i]
		var g := _goal[i]
		if p.distance_to(g) < 2.0:
			g = _random_point()
			_goal[i] = g

		var dir := (g - p).normalized()
		var mul := 1.0 if field.height_at(p) >= 0.38 else rough_speed_mul
		var step := dir * _speed[i] * mul * delta
		var next := p + step

		# Naive slide, exactly like the JS prototype. Units WILL get stuck in
		# a U-trench. That is expected and is Spike B's problem, not this one.
		if field.is_passable(next, impassable_below):
			p = next
		else:
			var side := Vector2(-dir.y, dir.x) * _speed[i] * mul * delta
			if field.is_passable(p + side, impassable_below):
				p = p + side
			elif field.is_passable(p - side, impassable_below):
				p = p - side
			else:
				_goal[i] = _random_point()

		var e := field.extent_m()
		p.x = clampf(p.x, 0.0, e.x)
		p.y = clampf(p.y, 0.0, e.y)
		_pos[i] = p

		var y := field.world_height_at(p) + 0.7
		multimesh.set_instance_transform(i,
			Transform3D(Basis.IDENTITY, Vector3(p.x, y, p.y)))

	last_update_ms = (Time.get_ticks_usec() - t0) / 1000.0
