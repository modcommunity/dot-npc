@tool
class_name DotNpcDef
extends Resource

## One kind of NPC a game can spawn.
## A definition, not a scene: a director must price four more zombies without loading four scenes.
## The brain is named by path, never class_name: a pack mounted at runtime cannot register a global class.

## How much of the world's simulation budget one of these is worth.
## Not a mass or poly count: what an NPC costs to think and to move.
enum Weight {
	TRIVIAL,
	LIGHT,
	NORMAL,
	HEAVY,
	BOSS,
}

@export_group("Identity")

## Stable id. What a spawn request names and what a cap is keyed on.
@export var id: StringName = &""

@export var display_name: String = ""

## Menu and director grouping: [code]"zombie/common"[/code], [code]"critter"[/code].
@export var category: StringName = &"npc"

## Who this NPC counts as. Two NPCs of the same faction do not fight.
## A StringName, not an enum: the set is the game's, and an enum would force a fork.
@export var faction: StringName = &"hostile"

@export_group("Content")

## The scene instantiated on spawn.
## May live in a dot-cloud pack, which the game must mount first.
@export var scene_path: String = ""

## The brain script, by path. Empty for an NPC the scene scripts itself.
## Never a class_name: a mounted pack cannot register one.
@export var brain_script_path: String = ""

## The dot-cloud content id this NPC lives in, or empty when it ships in the build.
@export var content_id: StringName = &""

@export_group("Simulation")

@export var weight: Weight = Weight.NORMAL

## What one of these costs against a population budget. See [DotNpcLimits].
## Separate from [member weight] so one kind can be made expensive without reclassifying it.
@export_range(1, 100, 1) var cost: int = 1

@export_range(1.0, 100000.0, 1.0) var max_health: float = 100.0

## Metres per second on the ground. Advisory: the brain owns the actual motion.
@export_range(0.0, 100.0, 0.1) var move_speed: float = 3.0

@export_group("Perception")

## How far it can see, in metres.
@export_range(0.0, 500.0, 0.5) var sight_range: float = 30.0

## Half-angle of the sight cone, in degrees. 180 is all-round vision.
@export_range(0.0, 180.0, 1.0) var sight_half_angle_deg: float = 60.0

## How far it can hear, in metres. Hearing ignores the cone and facing.
## Separate from sight and usually smaller, or an NPC could never be approached from behind.
@export_range(0.0, 500.0, 0.5) var hearing_range: float = 12.0

## Whether a target must be in line of sight, not merely in the cone.
## Off for a cheap critter: a raycast per candidate per NPC per tick is the costliest thing here.
@export var require_line_of_sight: bool = true

## How far above its feet the NPC looks from, in metres: where the sight line starts.
## Not zero: a ray that starts on the floor it stands on hits it at distance zero, so the
## NPC was blind with line of sight on and nothing said so.
@export_range(0.0, 20.0, 0.05) var eye_height: float = 1.5

@export_group("Navigation")

## Navigation flags this kind of NPC cannot traverse. See [enum DotNpcNavData.Flag].
## On the definition, not the graph: whether a crouch tunnel is a way through depends on the
## walker, and one graph serves every NPC. Zero goes anywhere the graph goes.
@export_flags(
	"Crouch:1", "Jump:2", "Avoid:4", "Stop:8", "Walk:16", "Door:32"
) var nav_exclude_flags: int = 0

@export_group("Permission")

## An admin permission required to spawn one by hand. Empty for anybody.
@export var permission: String = ""

## Whether this kind may be spawned at all right now.
@export var enabled: bool = true

@export var meta: Dictionary = {}

@export_group("Profile")

## Keys a brain reads that the schema does not know: the `extra:` block of a profile.
@export var extra: Dictionary = {}

## Spawn-menu hints from a profile's `menu:` block: `icon`, `sort`, `hidden`.
@export var menu: Dictionary = {}


static func make(p_id: StringName, p_scene: String) -> DotNpcDef:
	var npc := DotNpcDef.new()
	npc.id = p_id
	npc.scene_path = p_scene
	npc.display_name = String(p_id).capitalize()
	return npc


func name_or_id() -> String:
	return display_name if display_name != "" else String(id)


func is_local() -> bool:
	return content_id == &""


## The sight cone half-angle in radians. Cached nowhere: it is one multiply.
func sight_half_angle() -> float:
	return deg_to_rad(sight_half_angle_deg)


func validate() -> DotResult:
	if id == &"":
		return DotResult.fail(DotError.CODE_INVALID, "An NPC needs an id.")

	if scene_path == "":
		return DotResult.fail(
			DotError.CODE_INVALID, "An NPC needs a scene path.", String(id)
		)

	if brain_script_path != "" and not brain_script_path.ends_with(".gd"):
		# Caught here rather than at spawn, because a catalogue is loaded once at boot
		# and a spawn happens in the middle of a round.
		return DotResult.fail(
			DotError.CODE_INVALID,
			"brain_script_path must be a path to a .gd script, not a class name.",
			"%s: %s" % [String(id), brain_script_path]
		)

	if max_health <= 0.0:
		return DotResult.fail(
			DotError.CODE_INVALID, "max_health must be positive.", String(id)
		)

	return DotResult.success(null)


func to_dictionary() -> Dictionary:
	var out := {
		"id": String(id),
		"scene": scene_path,
		"category": String(category),
		"faction": String(faction),
		"weight": weight,
		"cost": cost,
		"health": max_health,
		"speed": move_speed,
		"sight": sight_range,
		"sight_angle": sight_half_angle_deg,
		"hearing": hearing_range,
	}

	if display_name != "":
		out["name"] = display_name
	if brain_script_path != "":
		out["brain"] = brain_script_path
	if content_id != &"":
		out["content"] = String(content_id)
	if not require_line_of_sight:
		out["los"] = false
	if eye_height != 1.5:
		out["eye"] = eye_height
	if nav_exclude_flags != 0:
		out["nav_exclude"] = nav_exclude_flags
	if permission != "":
		out["permission"] = permission
	if not enabled:
		out["enabled"] = false
	if not extra.is_empty():
		out["extra"] = extra.duplicate(true)
	if not menu.is_empty():
		out["menu"] = menu.duplicate(true)
	if not meta.is_empty():
		# Duplicated: a Dictionary is a reference in GDScript, so handing this one out
		# lets whoever serialises an NPC edit the shared definition.
		out["meta"] = meta.duplicate(true)

	return out


static func from_dictionary(data: Dictionary) -> DotNpcDef:
	var npc := DotNpcDef.new()

	npc.id = StringName(str(data.get("id", "")))
	npc.scene_path = str(data.get("scene", ""))
	npc.display_name = str(data.get("name", ""))
	npc.category = StringName(str(data.get("category", "npc")))
	npc.faction = StringName(str(data.get("faction", "hostile")))
	npc.brain_script_path = str(data.get("brain", ""))
	npc.content_id = StringName(str(data.get("content", "")))
	npc.weight = _to_weight(data.get("weight", Weight.NORMAL))
	npc.cost = clampi(int(data.get("cost", 1)), 1, 100)
	npc.max_health = maxf(float(data.get("health", 100.0)), 1.0)
	npc.move_speed = maxf(float(data.get("speed", 3.0)), 0.0)
	npc.sight_range = maxf(float(data.get("sight", 30.0)), 0.0)
	npc.sight_half_angle_deg = clampf(float(data.get("sight_angle", 60.0)), 0.0, 180.0)
	npc.hearing_range = maxf(float(data.get("hearing", 12.0)), 0.0)
	npc.require_line_of_sight = bool(data.get("los", true))
	npc.eye_height = clampf(float(data.get("eye", 1.5)), 0.0, 20.0)
	npc.nav_exclude_flags = maxi(int(data.get("nav_exclude", 0)), 0)
	npc.permission = str(data.get("permission", ""))
	npc.enabled = bool(data.get("enabled", true))

	var meta_value: Variant = data.get("meta", {})
	npc.meta = (
		(meta_value as Dictionary).duplicate(true) if meta_value is Dictionary else {}
	)

	var extra_value: Variant = data.get("extra", {})
	npc.extra = (extra_value as Dictionary).duplicate(true) if extra_value is Dictionary else {}
	var menu_value: Variant = data.get("menu", {})
	npc.menu = (menu_value as Dictionary).duplicate(true) if menu_value is Dictionary else {}

	return npc


## Builds a definition from a loaded `npc` [DotProfile] (see [DotNpcProfiles]).
static func from_profile(profile: DotProfile) -> DotNpcDef:
	var data := profile.values.duplicate(true)
	data["id"] = profile.id
	data["extra"] = profile.extra
	var menu_data: Dictionary = data.get("menu", {})
	if str(menu_data.get("category", "")) != "":
		data["category"] = menu_data["category"]
	var weight_name := str(data.get("weight", "normal")).to_upper()
	data["weight"] = maxi(Weight.keys().find(weight_name), 0)
	return from_dictionary(data)


static func _to_weight(value: Variant) -> Weight:
	var raw := int(value)
	return raw as Weight if raw >= 0 and raw < Weight.size() else Weight.NORMAL


func describe() -> Dictionary:
	return {
		"id": String(id),
		"category": String(category),
		"faction": String(faction),
		"weight": Weight.keys()[weight],
		"cost": cost,
		"health": "%.0f" % max_health,
		"sight": "%.0fm / %.0f deg" % [sight_range, sight_half_angle_deg],
		"hearing": "%.0fm" % hearing_range,
	}


func _to_string() -> String:
	return "DotNpcDef(%s)" % String(id)
