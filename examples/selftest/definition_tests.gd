extends "res://examples/selftest/harness.gd"
## Definitions, catalogue, profiles and limits sections.

func _test_definitions() -> void:
	_section("definitions")

	var walker := DotNpcDef.make(&"walker", BODY)
	_check(walker.validate().ok, "a definition validates")
	_check(walker.is_local(), "and ships in the build when it has no content id")

	var nameless := DotNpcDef.new()
	_check(not nameless.validate().ok, "one with no id is refused")

	var by_class := DotNpcDef.make(&"walker", BODY)
	by_class.brain_script_path = "ZombieBrain"
	_check(
		not by_class.validate().ok,
		"a brain named by class rather than by path is refused"
	)

	var round_tripped := DotNpcDef.from_dictionary(walker.to_dictionary())
	_check(round_tripped.id == walker.id, "a definition survives a round trip")
	_check(
		round_tripped.sight_half_angle_deg == walker.sight_half_angle_deg,
		"including its perception"
	)

	walker.meta = {"speed": 4.0}
	var copied := walker.to_dictionary()
	(copied["meta"] as Dictionary)["speed"] = 99.0
	_check(
		float(walker.meta["speed"]) == 4.0,
		"and its meta is copied out, not handed out",
		"a Dictionary is a reference; this is the aliasing bug dot-timer had five of"
	)
	_done()


func _test_catalogue() -> void:
	_section("catalogue")

	var cat := _catalogue()
	_check(cat.size() == 5, "a catalogue holds what was added", "%d" % cat.size())
	_check(cat.get_npc(&"walker") != null, "and finds by id")
	_check(cat.get_npc(&"nothing") == null, "and answers null for what is not there")
	var categories := cat.categories()
	_check(
		categories.size() == 4 and categories[0] == "npc" and categories[3] == "zombie",
		"categories are the enabled ones, sorted",
		str(categories)
	)
	_check(cat.in_faction(&"neutral").size() == 1, "and a faction can be listed")

	var rejected := PackedStringArray()
	var reloaded := DotNpcCatalogue.from_dictionary({
		"npcs": [
			{"id": "good", "scene": BODY},
			{"id": "", "scene": BODY},
			{"id": "also_good", "scene": BODY},
		]
	}, rejected)

	_check(
		reloaded.size() == 2 and rejected.size() == 1,
		"one bad entry does not condemn the file",
		"%d kept, %d rejected" % [reloaded.size(), rejected.size()]
	)
	_done()


const PROFILE_BASE := "user://npc_profile_selftest"


func _pw(rel: String, text: String) -> void:
	var path := PROFILE_BASE.path_join(rel)
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(text)
	f.close()


func _rm(dir: String) -> void:
	if not DirAccess.dir_exists_absolute(dir):
		return
	for f in DirAccess.get_files_at(dir):
		DirAccess.remove_absolute(dir.path_join(f))
	for d in DirAccess.get_directories_at(dir):
		_rm(dir.path_join(d))
	DirAccess.remove_absolute(dir)


func _test_profiles() -> void:
	_section("profiles")
	_rm(PROFILE_BASE)
	DotLog.set_level(DotLog.Level.FATAL)
	_pw("addons/dot-npc/npc/walker.yml", "name: Walker\nscene: %s\nbrain: %s\ncategory: zombie\nhealth: 100\nhearing: 10\nlos: false\nmeta:\n  speed: 4.0\nextra:\n  groan:\n    pitch: 0.8\nmenu:\n  sort: 2\n  icon: res://walker.png\n" % [BODY, BRAIN])
	_pw("addons/dot-npc/npc/brute.yml", "extends: walker\ncost: 8\nhealth: 400\nweight: heavy\nmenu:\n  sort: 1\n  category: zombie/big\n")
	_pw("addons/dot-npc/npc/ghost.yml", "extends: walker\nmenu:\n  hidden: true\n")
	_pw("game/mygame/npc/walker.yml", "health: 150\nextra:\n  groan:\n    volume: 3\n")
	_pw("addons/dot-npc/npc/broken.yml", "scene: [unclosed\n  : x: :\n")
	var roots := PackedStringArray([PROFILE_BASE])

	var addon_only := DotNpcProfiles.make_set("", roots)
	var res := DotNpcProfiles.load_def(addon_only, "walker")
	var def: DotNpcDef = res.value if res.ok else null
	var ref: DotNpcDef = _catalogue().get_npc(&"walker")
	_check(def != null, "a profile loads into a definition", "" if res.ok else res.error.message)
	if def == null:
		return
	_check(
		def.to_dictionary() == ref.to_dictionary().merged({"extra": {"groan": {"pitch": 0.8}}, "menu": {"sort": 2, "icon": "res://walker.png"}}),
		"and equals the code-built definition apart from extra and menu",
		str(def.to_dictionary())
	)
	_check(def.id == &"walker" and def.category == &"zombie" and def.validate().ok, "its id is the file name")

	var game_set := DotNpcProfiles.make_set("mygame", roots)
	var over := DotNpcProfiles.load_def(game_set, "walker").value as DotNpcDef
	_check(over.max_health == 150.0 and over.hearing_range == 10.0, "a game overrides a key and keeps the addon's others")
	_check(over.extra["groan"]["pitch"] == 0.8 and over.extra["groan"]["volume"] == 3, "extra is merged and handed to the brain")
	_check(def.max_health == 100.0, "and another set still sees the addon value")

	var brute := DotNpcProfiles.load_def(game_set, "brute").value as DotNpcDef
	_check(brute.weight == DotNpcDef.Weight.HEAVY and brute.cost == 8 and brute.max_health == 400.0, "extends and weight by name")
	_check(brute.category == &"zombie/big", "menu.category sets the category")

	var ids := game_set.list_ids()
	_check(ids == PackedStringArray(["broken", "brute", "ghost", "walker"]), "ids are listed from the directories", str(ids))
	var entries := DotNpcProfiles.menu_entries(game_set)
	_check(entries.size() == 2 and entries[0]["id"] == "brute" and entries[1]["id"] == "walker", "the menu is sorted and skips hidden and broken", str(entries))
	_check(entries[0]["category"] == "zombie/big" and entries[1]["icon"] == "res://walker.png", "with category and icon")
	_check(DotNpcProfiles.menu_entries(game_set, true).size() == 3, "hidden ones can be asked for")

	var bad := DotNpcProfiles.load_def(game_set, "broken")
	_check(not bad.ok and bad.error.code == DotError.CODE_PARSE, "a bad yml is a parse error", "" if bad.ok else bad.error.code)
	_check(not bad.ok and "broken" in bad.error.message, "that names the file")
	_pw("game/mygame/npc/typo.yml", "scene: x\nhealht: 5\n")
	var typo := DotNpcProfiles.load_def(game_set, "typo")
	_check(not typo.ok and typo.error.code == DotError.CODE_INVALID, "an unknown key is refused")
	game_set.clear_cache()
	var errors := PackedStringArray()
	var cat := DotNpcProfiles.to_catalogue(game_set, errors)
	_check(cat.size() == 3 and errors.size() == 2, "a catalogue keeps the good ones and reports the bad", "%d kept, %d errors" % [cat.size(), errors.size()])

	var plain := DotNpcDef.from_dictionary({"id": "old", "scene": BODY, "health": 20})
	_check(plain.extra.is_empty() and plain.menu.is_empty() and plain.max_health == 20.0, "a dictionary without extra still loads")
	_check(not plain.to_dictionary().has("extra") and not plain.to_dictionary().has("menu"), "and serialises without the new keys")
	var rt := DotNpcDef.from_dictionary(def.to_dictionary())
	_check(rt.extra == def.extra and rt.menu == def.menu, "extra survives a round trip")
	var coded := DotNpcDef.make(&"c", BODY)
	_check(coded.validate().ok and coded.extra.is_empty(), "code-built definitions are untouched")
	_check(_catalogue().size() == 5, "and the catalogue built from code is intact")
	_check(DotNpcProfiles.schema().size() == 20, "the schema lists the common keys")
	_check(DotNpcProfiles.profile_schemas()["npc"]["schema"].size() == 20, "profile_schemas names the npc kind for the validator")
	# A set and its cached profiles point at each other; clear them or they leak at exit.
	for set_to_clear in [addon_only, game_set]:
		set_to_clear.clear_cache()
	DotLog.set_level(DotLog.Level.ERROR)
	_rm(PROFILE_BASE)
	_done()


func _test_limits() -> void:
	_section("limits")

	var limits := DotNpcLimits.new()
	_check(limits.validate().ok, "the defaults are usable")

	limits.per_kind_cap = 500
	limits.world_budget = 96
	_check(
		not limits.validate().ok,
		"a per-kind cap above the world budget is refused",
		"it could never be reached, which reads as the cap being ignored"
	)

	var configured := DotNpcLimits.new()
	configured.apply_dictionary({"world_budget": 12})
	_check(
		configured.world_budget == 12,
		"and it is a DotConfig, so a file or a command line can retune it"
	)
	_done()
