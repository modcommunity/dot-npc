@tool
class_name DotNpcCatalogue
extends Resource

## Every NPC kind a server offers, and the file an operator edits.
##
## Same shape and the same reasoning as [code]DotPropCatalogue[/code] and
## [code]DotMapCatalogue[/code]: plain JSON, because the person maintaining it on a
## community server is a person with a text editor; one bad entry does not condemn the
## file; an exact id match wins a search.

const CHANNEL := "npc.catalogue"

const FORMAT_VERSION := 1

@export var npcs: Array[DotNpcDef] = []

@export var meta: Dictionary = {}

var _by_id: Dictionary = {}


func add(npc: DotNpcDef) -> DotResult:
	if npc == null:
		return DotResult.fail(DotError.CODE_INVALID, "No NPC to add.")

	var valid := npc.validate()

	if not valid.ok:
		return valid

	if _by_id.size() != npcs.size():
		_reindex()

	if _by_id.has(npc.id):
		var existing: DotNpcDef = _by_id[npc.id]
		npcs[npcs.find(existing)] = npc
		_by_id[npc.id] = npc
		return DotResult.success(npc)

	npcs.append(npc)
	_by_id[npc.id] = npc

	return DotResult.success(npc)


## Download every pack this catalogue's NPCs live in.
##
## [b]Nothing used to fetch these.[/b] A DotNpcDef has carried a `content_id` since it was
## written and it is serialised onto the wire, but no code anywhere asked dot-cloud for
## one — so a delivered NPC was refused with "that NPC's content is not loaded",
## forever, on a server that had configured it perfectly. The refusal is correct and
## that is what made it invisible: it reads as a missing pack rather than as a fetch
## that never happens.
##
## [b]At load, not on demand.[/b] A spawn request is a player's, and turning one into a
## download would let a player make this machine fetch — repeatedly, from whatever a
## manifest names — by asking for something that is not there. The catalogue is known
## before anyone connects, so this is a boot-time cost paid once. It also keeps the
## spawn path synchronous, which is what every caller of it already assumes.
##
## Non-fatal by construction: a pack that will not download leaves that NPC
## unspawnable and everything else working. See [method DotContent.ensure_all] for the
## shape of the answer.
func ensure_content() -> DotResult:
	if _by_id.size() != npcs.size():
		_reindex()

	var ids := PackedStringArray()

	for entry in npcs:
		if entry != null and String(entry.content_id) != "":
			ids.append(String(entry.content_id))

	return await DotContent.ensure_all(ids)


func get_npc(id: StringName) -> DotNpcDef:
	if _by_id.size() != npcs.size():
		_reindex()

	var found: Variant = _by_id.get(id)
	return found if found is DotNpcDef else null


func has(id: StringName) -> bool:
	return get_npc(id) != null


func size() -> int:
	return npcs.size()


func remove(id: StringName) -> bool:
	_reindex()

	if not _by_id.has(id):
		return false

	npcs.erase(_by_id[id])
	_by_id.erase(id)

	return true


func _reindex() -> void:
	_by_id.clear()

	for npc in npcs:
		_by_id[npc.id] = npc


## Every category, in alphabetical order. For a spawn menu's tabs.
func categories() -> PackedStringArray:
	var seen := {}

	for npc in npcs:
		if npc.enabled:
			seen[String(npc.category)] = true

	var out := PackedStringArray(seen.keys())
	out.sort()

	return out


func in_category(category: StringName) -> Array[DotNpcDef]:
	var out: Array[DotNpcDef] = []

	for npc in npcs:
		if npc.enabled and npc.category == category:
			out.append(npc)

	return out


func in_faction(faction: StringName) -> Array[DotNpcDef]:
	var out: Array[DotNpcDef] = []

	for npc in npcs:
		if npc.enabled and npc.faction == faction:
			out.append(npc)

	return out


## NPCs whose id or name contains [param text]. An exact id wins outright.
func search(text: String, limit: int = 30) -> Array[DotNpcDef]:
	var needle := text.strip_edges().to_lower()
	var out: Array[DotNpcDef] = []

	if needle == "":
		return out

	var exact := get_npc(StringName(needle))

	if exact != null:
		out.append(exact)
		return out

	for npc in npcs:
		if out.size() >= limit:
			break
		if String(npc.id).to_lower().contains(needle) \
				or npc.display_name.to_lower().contains(needle):
			out.append(npc)

	return out


func to_dictionary() -> Dictionary:
	var entries: Array = []

	for npc in npcs:
		entries.append(npc.to_dictionary())

	return {
		"format": FORMAT_VERSION,
		"npcs": entries,
		"meta": meta.duplicate(true),
	}


## Reads a catalogue, keeping the good entries and reporting the bad ones.
##
## [b]One bad entry does not condemn the file.[/b] A community server's catalogue is
## hand-edited, and refusing to boot because entry forty is missing a scene path means
## the operator has no NPCs at all rather than thirty-nine.
static func from_dictionary(data: Dictionary, rejected: PackedStringArray = PackedStringArray()) -> DotNpcCatalogue:
	var cat := DotNpcCatalogue.new()
	var rejected_before := rejected.size()

	var raw: Variant = data.get("npcs", [])

	if raw is Array:
		for entry in (raw as Array):
			if not (entry is Dictionary):
				rejected.append("not an object")
				continue

			var npc := DotNpcDef.from_dictionary(entry as Dictionary)
			var added := cat.add(npc)

			if not added.ok:
				rejected.append(added.error.message if added.error != null else "invalid")

	# Said here, whatever the caller does with [param rejected], because the person who
	# can fix entry forty is the operator with the text editor, and a dropped NPC
	# otherwise surfaces as "that NPC does not exist" from a spawn much later. WARN, and
	# the same line DotPropCatalogue and DotMapCatalogue write for the same reason.
	if rejected.size() > rejected_before:
		DotLog.warn(CHANNEL, "some npc entries were dropped", {
			"count": rejected.size() - rejected_before,
			"entries": ", ".join(rejected.slice(rejected_before)),
		})

	var meta_value: Variant = data.get("meta", {})
	cat.meta = (
		(meta_value as Dictionary).duplicate(true) if meta_value is Dictionary else {}
	)

	return cat


func describe() -> Dictionary:
	return {
		"npcs": npcs.size(),
		"categories": categories().size(),
	}
