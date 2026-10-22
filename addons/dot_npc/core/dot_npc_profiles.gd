class_name DotNpcProfiles
extends RefCounted

## Loads [DotNpcDef] from `npc` profiles (cfg/addons/dot-npc/npc, cfg/game/<game>/npc, cfg/server/npc).

const ADDON := "dot-npc"
const KIND := "npc"
const WEIGHTS := ["trivial", "light", "normal", "heavy", "boss"]


## The common keys. Anything else a brain needs goes under `extra:`.
static func schema() -> Array:
	var f := DotProfileSet.field
	return [
		f.call("name", "string", ""),
		f.call("category", "string", "npc"),
		f.call("faction", "string", "hostile"),
		f.call("scene", "string", ""),
		f.call("brain", "string", ""),
		f.call("content", "string", ""),
		f.call("weight", "string", "normal", {"enum": WEIGHTS}),
		f.call("cost", "int", 1, {"min": 1, "max": 100}),
		f.call("health", "float", 100.0, {"min": 1.0, "max": 100000.0}),
		f.call("speed", "float", 3.0, {"min": 0.0, "max": 100.0}),
		f.call("sight", "float", 30.0, {"min": 0.0, "max": 500.0}),
		f.call("sight_angle", "float", 60.0, {"min": 0.0, "max": 180.0}),
		f.call("hearing", "float", 12.0, {"min": 0.0, "max": 500.0}),
		f.call("los", "bool", true),
		f.call("eye", "float", 1.5, {"min": 0.0, "max": 20.0}),
		f.call("nav_exclude", "int", 0, {"min": 0}),
		f.call("permission", "string", ""),
		f.call("enabled", "bool", true),
		f.call("meta", "dict", {}),
		f.call("menu", "dict", {}),
	]


## Kind to schema for tools that validate profiles without a game (dot-core profile_check).
static func profile_schemas() -> Dictionary:
	return {"npc": {"schema": schema(), "children": {}}}


## A profile set for NPCs of [param game]; [param roots] overrides the config roots (tests).
static func make_set(game: String, roots: PackedStringArray = PackedStringArray()) -> DotProfileSet:
	var s := DotProfileSet.create(ADDON, game, KIND, schema())
	s.roots = roots
	return s


## NPC ids found on disk, sorted; opens no file.
static func list_ids(profiles: DotProfileSet) -> PackedStringArray:
	return profiles.list_ids()


## Loads one profile into a validated [DotNpcDef]; the value of the result.
static func load_def(profiles: DotProfileSet, id: String) -> DotResult:
	var res := profiles.load_profile(id)
	if not res.ok:
		return res
	var def := DotNpcDef.from_profile(res.value)
	var checked := def.validate()
	if not checked.ok:
		return checked
	return DotResult.success(def)


## Menu entries `{id, category, icon, sort, hidden}` for the visible NPCs, sorted by sort then id.
## Loads each profile's yml but never its scene.
static func menu_entries(profiles: DotProfileSet, include_hidden: bool = false) -> Array:
	var out: Array = []
	for id in profiles.list_ids():
		var res := profiles.load_profile(id)
		if not res.ok:
			continue
		var m: Dictionary = res.value.get_value("menu", {})
		var hidden := bool(m.get("hidden", false))
		if hidden and not include_hidden:
			continue
		var category := str(m.get("category", ""))
		out.append({
			"id": id,
			"category": category if category != "" else str(res.value.get_value("category", "npc")),
			"icon": str(m.get("icon", "")),
			"sort": int(m.get("sort", 0)),
			"hidden": hidden,
		})
	out.sort_custom(func(a, b): return a["sort"] < b["sort"] or (a["sort"] == b["sort"] and a["id"] < b["id"]))
	return out


## Every loadable profile as a [DotNpcCatalogue]; failures are appended to [param errors].
static func to_catalogue(profiles: DotProfileSet, errors: PackedStringArray = PackedStringArray()) -> DotNpcCatalogue:
	var cat := DotNpcCatalogue.new()
	for id in profiles.list_ids():
		var res := load_def(profiles, id)
		if res.ok:
			cat.add(res.value)
		else:
			errors.append("%s: %s" % [id, res.error.message])
	return cat
