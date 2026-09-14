extends SceneTree
func _initialize() -> void:
	var cfg: TerrainConfig = load("res://data/terrain/biodome_01.tres")
	var hf := Heightfield.new(cfg)
	print("Heightfield built: ", hf.heights.size(), " cells")
	hf.deform(Vector2(40, 40), 2.0, -0.3)   # this emits on EventBus
	print("deform OK, h=", hf.height_at(Vector2(40, 40)))
	quit(0)
