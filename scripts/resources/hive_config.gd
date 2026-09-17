class_name HiveConfig
extends Resource
## What wakes the aliens, and how many come.
##
## THE HIVE IS ASLEEP BY DEFAULT. Two large creatures roam the map in the open
## and everything else is underground until something calls it up. That is the
## whole shape of the encounter design: the map is quiet, the player chooses
## when it stops being quiet, and every fight is traceable to a thing they did.
##
## Four ways to wake it, and each one has an OFF SWITCH the player can reach:
##
##   1. DIG a large debris piece      stops when the piece comes free
##   2. WALK NEAR an alien plant      stops when the plant is destroyed
##   3. STEP ON a burrow patch        one group, then that patch is spent
##   4. APPROACH a roaming creature   stops when the creature is killed
##
## A trigger with no off switch is a timer wearing a costume — the player
## cannot answer it, only outlast it, and the brief is explicit that waves
## arriving on a clock is what v1 got wrong.

@export var display_name: String = ""

@export_group("The two that roam")
## How many large creatures walk the map in the open. Two: one is a landmark,
## three is a patrol pattern, and two is a decision about which way to go.
@export_range(0, 8) var roamer_count: int = 2
@export var roamer_hp: float = 260.0
@export var roamer_speed_mps: float = 2.1
## How far from its birthplace one will wander. They are territory, not threats
## that hunt you across the map.
@export var roamer_wander_m: float = 26.0
## It broods only once the player is this close. A creature spawning escorts on
## the far side of the map is a tax, not an encounter.
@export var roamer_notice_m: float = 30.0
@export var roamer_brood_interval_s: float = 9.0
@export_range(1, 12) var roamer_brood_count: int = 3
@export var roamer_brood_radius_m: float = 4.5

@export_group("The plants")
## How many of the map's alien plants are nests. Chosen from the dressing's own
## flora_brain placements, so a nest is always something the player can see and
## walk up to rather than an invisible box that happens to sit near a plant.
@export_range(0, 24) var plant_nest_count: int = 5
@export var plant_hp: float = 120.0
## Walk inside this and it wakes. It stays awake until it is killed.
@export var plant_notice_m: float = 11.0
@export var plant_brood_interval_s: float = 7.0
@export_range(1, 12) var plant_brood_count: int = 2
@export var plant_brood_radius_m: float = 3.0

@export_group("The buried patches")
## Small unmarked ground that has something under it. One group each, then
## spent — these are the cost of exploring carelessly, not a standing threat.
@export_range(0, 60) var patch_count: int = 14
@export var patch_notice_m: float = 6.0
@export_range(1, 12) var patch_count_min: int = 3
@export_range(1, 12) var patch_count_max: int = 4
@export var patch_brood_radius_m: float = 3.5
## No two patches closer together than this, or a single step trips three.
@export var patch_spacing_m: float = 18.0

@export_group("Coming up")
## How long a spawned alien spends climbing out before it can move. THE REASON
## THIS EXISTS: an alien that appears at full speed reads as spawned, and an
## alien that heaves itself out of the ground reads as having been there all
## along. It is also the player's warning — a second and a half to react.
@export var emerge_s: float = 1.5
## The debris wave comes up through burrows near the module rather than walking
## in from the map edge. Beyond this from the module there is no burrow close
## enough and it falls back to the old spawn ring.
@export var burrow_reach_m: float = 26.0
