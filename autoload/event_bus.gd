extends Node
## Global signal hub. Systems emit here; they never call each other directly.
##
## Adding a signal is cheap. Adding a direct reference between two systems is
## not — it is the thing this file exists to prevent.

# --- chassis & modules ------------------------------------------------------
signal module_attached(module_id: StringName, bay: int)
signal module_detached(module_id: StringName, bay: int, world_pos: Vector3)
signal module_recalled(module_id: StringName, bay: int)
signal chassis_damaged(amount: float, remaining: float)
signal chassis_destroyed()

# --- terrain ----------------------------------------------------------------
## Emitted after the heightfield changes so pathfinding can rebuild the
## affected chunks. `world_aabb` is the XZ region touched.
signal terrain_deformed(world_aabb: AABB)

# --- economy & mission ------------------------------------------------------
signal salvage_changed(total: int)
signal fragment_recovered(count: int, required: int)
signal teleporter_charging(seconds: float)
signal mission_ended(won: bool)

# --- waves & adaptation -----------------------------------------------------
signal wave_started(index: int, hostile_count: int)
## `adaptation_id` is empty when the hive could not read the player this wave.
signal hive_adapted(adaptation_id: StringName, stacks: int)
signal reliance_sampled(shares: Dictionary)
