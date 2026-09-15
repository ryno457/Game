class_name BuildOption
extends Resource
## One thing the module can spend mass to become.

@export var id: StringName = &""
@export var display_name: String = ""
@export var mass_cost: float = 10.0
@export_multiline var description: String = ""

@export_group("Form")
## Cosmetic/behavioural grouping only. EVERYTHING the module builds travels
## with it — the caravan is total. The only permanent mark the player leaves on
## the world is dug terrain, which is what makes a trench a real commitment
## rather than another thing that follows you around.
@export var is_structure: bool = false
## Where this keeps station in the convoy, in metres from the module. Heavier
## things sit further out so they meet trouble first.
@export var escort_radius_m: float = 6.0
@export var escort_speed_mps: float = 7.0
@export var max_hp: float = 100.0
@export var radius_m: float = 0.8
@export var speed_mps: float = 0.0
@export var colour: Color = Color(0.31, 0.89, 0.76)
## glTF in res://models/ to use for this, without extension. Empty falls back
## to a coloured box, so a missing model degrades rather than breaks.
@export var model: String = ""
## Child node to spin toward a target (turret_head, radar_dish). Empty for none.
@export var aim_node: String = ""

@export_group("Function")
@export var damage: float = 0.0
@export var range_m: float = 0.0
@export var cooldown_s: float = 1.0
## Radius this reveals through fog. 0 means it reveals nothing of its own.
@export var reveal_m: float = 0.0

@export_group("Machine")
## A customised machine: a chassis plus the parts fitted to it. When this is
## set it OVERRIDES every flat number above — mass, hp, speed and weapons all
## come from the parts instead. The flat fields stay for things that are not
## machines (a pylon is a lump of mass, not a frame with hardpoints).
@export var loadout: MachineLoadout


## The numbers the sim fights with, whether they came from a loadout or from
## the flat fields on this option. Everything downstream reads this, so a
## hand-tuned option and a player-assembled machine are the same shape.
func spec(rules: MachineRules = null) -> MachineSpec:
	if loadout != null:
		var s := LoadoutResolver.resolve(loadout, rules)
		if s.display_name == "":
			s.display_name = display_name
		s.id = id
		return s

	var flat := MachineSpec.new()
	flat.id = id
	flat.display_name = display_name
	flat.mass = mass_cost
	flat.max_hp = max_hp
	flat.radius_m = radius_m
	flat.speed_mps = speed_mps
	flat.reveal_m = reveal_m
	flat.escort_radius_m = escort_radius_m
	flat.escort_speed_mps = escort_speed_mps
	flat.colour = colour
	flat.model = model
	if damage > 0.0:
		flat.weapons.append({
			"family": MachinePart.Family.RANGED,
			"damage": damage,
			"range_m": range_m,
			"min_range_m": 0.0,
			"cooldown_s": cooldown_s,
			"splash_m": 0.0,
			"source": id,
			"socket": "",
			"aims": aim_node != "",
			"model": "",
		})
	return flat
