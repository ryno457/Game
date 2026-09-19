class_name BloodBurst
extends RefCounted
## Alien blood, as a burst of glowing droplets that leave trails.
##
##     _blood = BloodBurst.new(self, 240)
##     _blood.burst(where, colour, 16)      # on death
##     _blood.step(delta)                   # from _process
##
## THE SUPPLIED GUIDE IS 2D AND THIS IS NOT. docs/reference/shader-guides/
## glowing-trails-alien-blood.pdf builds droplets out of Sprite2D and their
## trails out of Line2D, on a CanvasItemMaterial set to additive. None of those
## exist for 3D geometry. What survives the translation is its reasoning, which
## is sound:
##
##   * bake the glow rather than paying for a bloom pass
##   * cap the trail and drop old points
##   * kill the droplets on a timer, not when they leave the screen
##   * at thirty droplets an explosion, do less work per droplet per frame
##
## TWO OF ITS FOUR INGREDIENTS CANNOT BE USED HERE, and both for the same
## reason. Additive blending and alpha fade are exactly the combination that
## _flat_mesh in proto_main.gd records as submitting perfectly and rasterising
## to NOTHING on the Forward Mobile renderer — the drone scan lost four rounds
## to it and the health bars lost some before that. So:
##
##   * the glow is an OPAQUE EMISSIVE material, as the health bars ended up
##   * droplets fade by SHRINKING to nothing, not by going transparent
##
## AND THE TRAIL IS THE DROPLET. Rather than a second node per droplet holding
## a line of past positions — which is what Line2D was doing and is the
## expensive half of the guide — each droplet is a quad STRETCHED ALONG ITS OWN
## VELOCITY. A fast droplet is a streak and a slow one is a dot, which is what a
## trail looks like, for one transform write instead of a node and a growing
## array. There is no trail_length to tune because there is no trail to store.

## A hard cap on droplets in the air at once. Past this, new bursts overwrite
## the oldest droplets rather than growing the MultiMesh — a wave of sixty
## aliens dying at once must not resize a buffer sixty times.
var _cap: int
var _mmi: MultiMeshInstance3D
var _mm: MultiMesh

# Parallel arrays rather than an array of objects: this is touched every frame
# for every live droplet and a Dictionary per droplet is the kind of thing that
# shows up on a mid-range phone under thermal throttle.
var _pos := PackedVector3Array()
var _vel := PackedVector3Array()
var _life := PackedFloat32Array()      # seconds remaining
var _span := PackedFloat32Array()      # seconds it started with
var _size := PackedFloat32Array()
var _col := PackedColorArray()
var _next := 0                          # ring cursor
var _live := 0

const GRAVITY := 9.0
## Droplets stop at the floor rather than falling through it. The terrain is a
## heightfield and the caller passes its height in, because BloodBurst has no
## business knowing about the terrain.
var _floor_y := 0.0


func _init(parent: Node, cap := 240) -> void:
	_cap = maxi(8, cap)
	var quad := BoxMesh.new()
	# A unit box, scaled per instance. Not a QuadMesh: a quad is one-sided and
	# these tumble, so half of them would vanish at the wrong angle, and
	# cull_disabled on a transparent-looking material is close to the
	# combination that does not draw here. A box is six triangles and always
	# has something facing the camera.
	quad.size = Vector3.ONE
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	# OPAQUE. See the note above — this is the whole reason the effect looks the
	# way it does rather than the way the guide draws it.
	mat.transparency = BaseMaterial3D.TRANSPARENCY_DISABLED
	mat.vertex_color_use_as_albedo = true
	mat.emission_enabled = true
	mat.emission = Color(1.0, 1.0, 1.0)
	# Emission is modulated per instance through the vertex colour as well, so
	# one material serves every alien's own blood colour.
	mat.emission_operator = BaseMaterial3D.EMISSION_OP_MULTIPLY
	mat.emission_energy_multiplier = 1.8
	quad.material = mat

	_mm = MultiMesh.new()
	_mm.transform_format = MultiMesh.TRANSFORM_3D
	_mm.use_colors = true
	_mm.mesh = quad
	_mm.instance_count = _cap
	_mm.visible_instance_count = 0

	_mmi = MultiMeshInstance3D.new()
	_mmi.multimesh = _mm
	_mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# NO custom_aabb. The scan streaks were culled for a whole session because
	# theirs was pinned to the node's origin while the instances carried world
	# positions; MultiMesh recomputes its own bounds from the transforms and
	# every effect here that renders leaves it alone.
	parent.add_child(_mmi)

	_pos.resize(_cap)
	_vel.resize(_cap)
	_life.resize(_cap)
	_span.resize(_cap)
	_size.resize(_cap)
	_col.resize(_cap)


func set_floor(y: float) -> void:
	_floor_y = y


## Throw `count` droplets out of `at`. Upward-biased so the burst reads as
## something bursting rather than something leaking.
func burst(at: Vector3, colour: Color, count := 14, speed := 4.2,
		size := 0.16, secs := 1.4) -> void:
	for i in count:
		var dir := Vector3(randf_range(-1.0, 1.0), randf_range(0.15, 1.0),
			randf_range(-1.0, 1.0)).normalized()
		var k := _next
		_next = (_next + 1) % _cap
		if _life[k] <= 0.0:
			_live += 1
		_pos[k] = at
		_vel[k] = dir * speed * randf_range(0.55, 1.35)
		var s := secs * randf_range(0.7, 1.25)
		_life[k] = s
		_span[k] = s
		_size[k] = size * randf_range(0.6, 1.4)
		_col[k] = colour
	_mm.visible_instance_count = _cap


## Integrate and write the transforms. Call once per frame.
func step(delta: float) -> void:
	if _live <= 0:
		if _mm.visible_instance_count != 0:
			_mm.visible_instance_count = 0
		return
	var alive := 0
	for i in _cap:
		var t := _life[i]
		if t <= 0.0:
			# A dead droplet still occupies an instance slot, so it has to be
			# scaled to nothing rather than simply skipped — a stale transform
			# leaves a frozen streak on the map.
			_mm.set_instance_transform(i, Transform3D(Basis().scaled(
				Vector3.ZERO), Vector3.ZERO))
			continue
		t -= delta
		_life[i] = t
		if t <= 0.0:
			_live -= 1
			_mm.set_instance_transform(i, Transform3D(Basis().scaled(
				Vector3.ZERO), Vector3.ZERO))
			continue
		alive += 1
		var v := _vel[i]
		v.y -= GRAVITY * delta
		var p: Vector3 = _pos[i] + v * delta
		if p.y <= _floor_y:
			p.y = _floor_y
			# Splat: kill the vertical, keep a little slide, and let the timer
			# finish it. Bouncing looked like rubber.
			v = Vector3(v.x * 0.25, 0.0, v.z * 0.25)
		_vel[i] = v
		_pos[i] = p

		# STRETCHED ALONG THE VELOCITY — this is the trail. Length scales with
		# speed, so a droplet decelerating into the floor pulls itself back into
		# a dot on its own.
		var sp := v.length()
		var stretch: float = clampf(1.0 + sp * 0.28, 1.0, 5.0)
		var k: float = _size[i] * clampf(t / maxf(_span[i], 0.001), 0.0, 1.0)
		var basis := Basis().scaled(Vector3(k, k * stretch, k))
		if sp > 0.05:
			var dir := v / sp
			var up := Vector3(0.0, 1.0, 0.0)
			var axis := up.cross(dir)
			if axis.length_squared() > 1.0e-6:
				basis = Basis(axis.normalized(), up.angle_to(dir)) * basis
		_mm.set_instance_transform(i, Transform3D(basis, p))
		_mm.set_instance_color(i, _col[i])
	_live = alive
