class_name DotNpcGibs
extends RefCounted

## What a severed limb looks like: the limb's own triangles as a tumbling body, a raw stump on what is left, and blood.
## Drawn only; the server decides what came off ([DotNpcLimbs]). The limb is cut out of the model by vertex weight,
## not by scaling bones on a copy, which leaves stretched slivers; the skinned body hides it by collapsing its root bone.

## The default cap; the live one is [member DotNpcGore.max_gibs].
const MAX_GIBS := DotNpcGore.DEFAULT_MAX_GIBS
const GROUP := &"dot_npc_gibs"

static var _mesh_cache: Dictionary = {}
## A whole mesh's id and the bone collapsed -> the mesh that cut leaves, or null when it drops nothing.
static var _collapse_cache: Dictionary = {}
const COLLAPSE_CACHE_MAX := 256
const PRISTINE := &"dot_npc_pristine_mesh"
const COLLAPSED := &"dot_npc_collapsed_bones"
const STUMP_PREFIX := "Stump_"
const WOUND_PREFIX := "Wound_"
const WOUND_GROUP := &"dot_npc_wounds"
const POOL_SECONDS := 25.0

static var _blob_mat: StandardMaterial3D = null
static var _blob_mesh: SphereMesh = null
static var _pool_mat: StandardMaterial3D = null
static var _pool_mesh: CylinderMesh = null


static func drawn() -> bool:
	return DisplayServer.get_name() != "headless"


## Bone indices of [param root] and everything below it.
static func subtree(sk: Skeleton3D, root: int) -> Dictionary:
	var out := {root: true}
	var grew := true
	while grew:
		grew = false
		for i in sk.get_bone_count():
			if not out.has(i) and out.has(sk.get_bone_parent(i)):
				out[i] = true
				grew = true
	return out


## Vertices of one surface as the skeleton currently poses them.
static func skinned(sk: Skeleton3D, mi: MeshInstance3D, arrays: Array) -> PackedVector3Array:
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var out := verts.duplicate()
	var bi: Variant = arrays[Mesh.ARRAY_BONES]
	var wi: Variant = arrays[Mesh.ARRAY_WEIGHTS]
	var skin: Skin = mi.skin
	if verts.is_empty() or skin == null or not (bi is PackedInt32Array) or not (wi is PackedFloat32Array):
		return out
	var per := (bi as PackedInt32Array).size() / verts.size()
	var mats := []
	for i in skin.get_bind_count():
		var b := skin.get_bind_bone(i)
		if b < 0:
			b = sk.find_bone(skin.get_bind_name(i))
		mats.append(sk.get_bone_global_pose(b) * skin.get_bind_pose(i) if b >= 0 else Transform3D.IDENTITY)
	for v in verts.size():
		var p := Vector3.ZERO
		var total := 0.0
		for k in per:
			var w: float = (wi as PackedFloat32Array)[v * per + k]
			var bind: int = (bi as PackedInt32Array)[v * per + k]
			if w > 0.0 and bind < mats.size():
				p += (mats[bind] as Transform3D) * verts[v] * w
				total += w
		if total > 0.0:
			out[v] = p / total
	return out


static func _longest_edge(p: PackedVector3Array, a: int, b: int, c: int) -> float:
	return maxf(p[a].distance_to(p[b]), maxf(p[b].distance_to(p[c]), p[c].distance_to(p[a])))


## Collapses [param root]'s bone and drops every triangle of the drawn body the collapse would drag into a sheet
## (its longest edge grows past [param grow] times and by a visible amount). Each body gets its own mesh copy,
## so the shared resource stays whole.
static func collapse_bone(sk: Skeleton3D, model: Node, root: int, grow := 2.0) -> void:
	var meshes: Array = []
	var reused: Array = []
	for m in model.find_children("*", "MeshInstance3D", true, false):
		var mi := m as MeshInstance3D
		if mi.mesh is ArrayMesh and mi.skin != null:
			# A whole body of a kind cuts the same way: the first cut's mesh serves the rest, so a
			# sever stops being two script skinning passes over every vertex (about 8 ms each).
			var key := "" if mi.has_meta(PRISTINE) else "%d|%d" % [mi.mesh.get_instance_id(), root]
			if key != "" and _collapse_cache.has(key):
				reused.append([mi, _collapse_cache[key]])
				continue
			var before := []
			for s in mi.mesh.get_surface_count():
				before.append(skinned(sk, mi, mi.mesh.surface_get_arrays(s)))
			meshes.append([mi, before, key])
	sk.set_bone_pose_scale(root, Vector3.ONE * 0.001)
	var gone: Array = sk.get_meta(COLLAPSED, [])
	gone.append(root)
	sk.set_meta(COLLAPSED, gone)
	for entry in reused:
		var mi: MeshInstance3D = entry[0]
		mi.set_meta(PRISTINE, mi.mesh)
		if entry[1] != null:
			mi.mesh = entry[1]
	for entry in meshes:
		var mi: MeshInstance3D = entry[0]
		if not mi.has_meta(PRISTINE):
			mi.set_meta(PRISTINE, mi.mesh)
		var src := mi.mesh as ArrayMesh
		var dst := ArrayMesh.new()
		var changed := false
		var floor_len := src.get_aabb().get_longest_axis_size() * 0.03
		for s in src.get_surface_count():
			var arrays := src.surface_get_arrays(s)
			var mat := src.surface_get_material(s)
			var after := skinned(sk, mi, arrays)
			var was: PackedVector3Array = entry[1][s]
			var idx: Variant = arrays[Mesh.ARRAY_INDEX]
			var tris: PackedInt32Array = idx if idx is PackedInt32Array else PackedInt32Array(range(after.size()))
			var kept := PackedInt32Array()
			for t in range(0, tris.size() - 2, 3):
				var e0 := _longest_edge(was, tris[t], tris[t + 1], tris[t + 2])
				var e1 := _longest_edge(after, tris[t], tris[t + 1], tris[t + 2])
				if e1 > e0 * grow and e1 - e0 > floor_len:
					continue
				kept.append_array(tris.slice(t, t + 3))
			if kept.size() != tris.size():
				changed = true
			arrays[Mesh.ARRAY_INDEX] = kept if not kept.is_empty() else PackedInt32Array([0, 0, 0])
			dst.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays, [], {}, src.surface_get_format(s) & Mesh.ARRAY_FLAG_USE_8_BONE_WEIGHTS)
			dst.surface_set_material(s, mat)
		if changed:
			mi.mesh = dst
		if entry[2] != "":
			if _collapse_cache.size() >= COLLAPSE_CACHE_MAX:
				_collapse_cache.clear()
			_collapse_cache[entry[2]] = dst if changed else null


## The limb's triangles in skeleton space, centred on its joint, or null when it has none.
static func limb_mesh(sk: Skeleton3D, model: Node, root: int, key: String) -> ArrayMesh:
	if _mesh_cache.has(key):
		return _mesh_cache[key]
	var in_limb := subtree(sk, root)
	var centre := sk.get_bone_global_rest(root).origin
	var mesh := ArrayMesh.new()
	for m in model.find_children("*", "MeshInstance3D", true, false):
		var mi := m as MeshInstance3D
		# The pristine mesh, never one an earlier sever trimmed: the gib is the whole limb.
		var src: Mesh = mi.get_meta(PRISTINE, mi.mesh)
		if src == null:
			continue
		for s in src.get_surface_count():
			var arrays := src.surface_get_arrays(s)
			var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
			var bones: Variant = arrays[Mesh.ARRAY_BONES]
			var weights: Variant = arrays[Mesh.ARRAY_WEIGHTS]
			var idx: Variant = arrays[Mesh.ARRAY_INDEX]
			if verts.is_empty() or not (bones is PackedInt32Array) or not (weights is PackedFloat32Array):
				continue
			var per := (bones as PackedInt32Array).size() / verts.size()
			var skin: Skin = mi.skin
			var inside := PackedByteArray()
			inside.resize(verts.size())
			for v in verts.size():
				var w := 0.0
				for k in per:
					var b: int = (bones as PackedInt32Array)[v * per + k]
					if skin != null and b < skin.get_bind_count():
						var named := skin.get_bind_bone(b)
						b = named if named >= 0 else sk.find_bone(skin.get_bind_name(b))
					if in_limb.has(b):
						w += (weights as PackedFloat32Array)[v * per + k]
				inside[v] = 1 if w >= 0.5 else 0
			var tris: PackedInt32Array = idx if idx is PackedInt32Array else PackedInt32Array(range(verts.size()))
			var remap := {}
			var out := {}
			for key_name in [Mesh.ARRAY_VERTEX, Mesh.ARRAY_NORMAL, Mesh.ARRAY_TEX_UV]:
				out[key_name] = []
			var out_idx := PackedInt32Array()
			var normals: Variant = arrays[Mesh.ARRAY_NORMAL]
			var uvs: Variant = arrays[Mesh.ARRAY_TEX_UV]
			for t in range(0, tris.size() - 2, 3):
				if not (inside[tris[t]] and inside[tris[t + 1]] and inside[tris[t + 2]]):
					continue
				for c in 3:
					var v := tris[t + c]
					if not remap.has(v):
						remap[v] = (out[Mesh.ARRAY_VERTEX] as Array).size()
						(out[Mesh.ARRAY_VERTEX] as Array).append(verts[v] - centre)
						if normals is PackedVector3Array:
							(out[Mesh.ARRAY_NORMAL] as Array).append((normals as PackedVector3Array)[v])
						if uvs is PackedVector2Array:
							(out[Mesh.ARRAY_TEX_UV] as Array).append((uvs as PackedVector2Array)[v])
					out_idx.append(remap[v])
			if out_idx.is_empty():
				continue
			var a: Array = []
			a.resize(Mesh.ARRAY_MAX)
			a[Mesh.ARRAY_VERTEX] = PackedVector3Array(out[Mesh.ARRAY_VERTEX])
			if not (out[Mesh.ARRAY_NORMAL] as Array).is_empty():
				a[Mesh.ARRAY_NORMAL] = PackedVector3Array(out[Mesh.ARRAY_NORMAL])
			if not (out[Mesh.ARRAY_TEX_UV] as Array).is_empty():
				a[Mesh.ARRAY_TEX_UV] = PackedVector2Array(out[Mesh.ARRAY_TEX_UV])
			a[Mesh.ARRAY_INDEX] = out_idx
			mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, a)
			var mat := mi.get_surface_override_material(s)
			if mat == null:
				mat = src.surface_get_material(s)
			if mat != null and drawn():
				mesh.surface_set_material(mesh.get_surface_count() - 1, mat)
	var result: ArrayMesh = mesh if mesh.get_surface_count() > 0 else null
	_mesh_cache[key] = result
	return result


static func world_of(view: Node) -> Node:
	var tree := view.get_tree()
	return tree.current_scene if tree.current_scene != null else tree.root


static func flesh_material() -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(0.42, 0.03, 0.05)
	m.roughness = 0.22
	m.emission_enabled = true
	m.emission = Color(0.25, 0.0, 0.02)
	return m


static func bone_material() -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(0.86, 0.82, 0.7)
	m.roughness = 0.6
	return m


static func blood(burst: bool, dir: Vector3) -> CPUParticles3D:
	var p := CPUParticles3D.new()
	p.amount = int((40 if burst else 10) * DotNpcGore.spray_scale())
	p.lifetime = 0.9 if burst else 0.8
	p.one_shot = burst
	p.explosiveness = 0.95 if burst else 0.0
	p.local_coords = false
	p.direction = dir.normalized() + Vector3.UP * 0.6 if dir.length() > 0.01 else Vector3.UP
	p.spread = 55.0 if burst else 25.0
	p.initial_velocity_min = 2.0 if burst else 0.2
	p.initial_velocity_max = 6.0 if burst else 1.0
	p.gravity = Vector3(0.0, -9.8, 0.0)
	var drop := SphereMesh.new()
	drop.radius = 0.024
	drop.height = 0.048
	drop.radial_segments = 6
	drop.rings = 3
	drop.material = flesh_material()
	p.mesh = drop
	return p


## Spawns the limb as a body in the world, at [param joint_world], and returns it (null headless or with
## nothing to draw).
static func spawn_gib(sk: Skeleton3D, model: Node, key: String, root: int, limb: StringName, d: Dictionary, joint_world: Vector3, impulse: Vector3) -> Node3D:
	if not drawn():
		return null
	var mesh := limb_mesh(sk, model, root, key)
	var world := world_of(sk)
	if not DotNpcGore.gibs_enabled():
		return null
	# At the cap the oldest gib is reused, not freed and rebuilt: a crowd of kills costs no allocation churn.
	# A gib already freed this frame is still in the group: never count or reuse it.
	var live := world.get_tree().get_nodes_in_group(GROUP).filter(func(n: Node) -> bool: return not n.is_queued_for_deletion())
	var gib: RigidBody3D = null
	while live.size() >= DotNpcGore.max_gibs:
		var oldest := live[0] as RigidBody3D
		live.remove_at(0)
		if gib == null and oldest != null:
			gib = oldest
			for c in gib.get_children():
				gib.remove_child(c)
				c.queue_free()
		else:
			live_free(oldest)
	if gib == null:
		gib = RigidBody3D.new()
		gib.add_to_group(GROUP)
		gib.collision_layer = 0
		gib.collision_mask = 1
		world.add_child(gib)
	else:
		world.move_child(gib, -1)
	gib.name = "Gib_%s" % limb
	gib.sleeping = false
	gib.mass = float(d.get("gib_mass", 20.0))
	gib.global_transform = Transform3D(sk.global_transform.basis.orthonormalized(), joint_world)
	if mesh != null:
		var mi := MeshInstance3D.new()
		mi.mesh = mesh
		gib.add_child(mi)
		var box := BoxShape3D.new()
		var aabb := mesh.get_aabb()
		box.size = aabb.size.max(Vector3.ONE * 0.1) * 0.7
		var cs := CollisionShape3D.new()
		cs.shape = box
		cs.position = aabb.get_center()
		gib.add_child(cs)
	var par := sk.get_bone_parent(root)
	var out := sk.get_bone_global_rest(root).origin - sk.get_bone_global_rest(par).origin if par >= 0 else Vector3.UP
	var cap := cut_face(stump_radius(d), -out.normalized() if out.length() > 0.001 else Vector3.DOWN)
	gib.add_child(cap)
	gib.linear_velocity = impulse + Vector3(randf_range(-1.0, 1.0), 2.5, randf_range(-1.0, 1.0))
	gib.angular_velocity = Vector3(randf_range(-4.0, 4.0), randf_range(-4.0, 4.0), randf_range(-4.0, 4.0))
	var spray := blood(true, impulse)
	if DotNpcGore.spray_enabled():
		gib.add_child(spray)
		spray.emitting = true
	else:
		spray.free()
	var life := float(d.get("gib_seconds", 14.0))
	var until := Time.get_ticks_msec() + int(life * 1000.0)
	gib.set_meta(&"dot_npc_gib_until", until)
	gib.get_tree().create_timer(life).timeout.connect(_free_weak.bind(weakref(gib), until))
	return gib


## A raw cut on the part left behind, riding the parent bone: a flat-capped collar of flesh facing along the
## limb, a ring of pale muscle, a bone disc with a dark marrow dot, and a drip for a few seconds.
static func add_stump(sk: Skeleton3D, root: int, d: Dictionary, drip_blood := true) -> Node3D:
	if not drawn():
		return null
	var parent := sk.get_bone_parent(root)
	if parent < 0:
		return null
	var att := BoneAttachment3D.new()
	att.name = "%s%s" % [STUMP_PREFIX, sk.get_bone_name(root)]
	sk.add_child(att)
	att.bone_idx = parent
	var at := sk.get_bone_global_rest(parent).affine_inverse() * sk.get_bone_global_rest(root).origin
	var r := stump_radius(d)
	var dir := at.normalized() if at.length() > 0.001 else Vector3.UP
	var cut := cut_face(r, dir)
	cut.position = at + dir * r * 0.45
	att.add_child(cut)
	if not drip_blood:
		return att
	var drip := blood(false, Vector3.ZERO)
	drip.position = at
	att.add_child(drip)
	drip.emitting = true
	(Engine.get_main_loop() as SceneTree).create_timer(4.0).timeout.connect(_stop_weak.bind(weakref(drip)))
	return att


## Radius of a cut face for a limb whose region is [param d]: wide enough to read as a wound from across a room.
static func stump_radius(d: Dictionary) -> float:
	return clampf(float(d.get("radius", 0.3)) * 0.55, 0.07, 0.2)


## The flat cut itself at the origin, facing [param dir]: flesh collar behind it, a ring of muscle, a bone disc
## and a dark marrow dot.
static func cut_face(r: float, dir: Vector3) -> Node3D:
	var cut := Node3D.new()
	cut.transform = Transform3D(Basis(Quaternion(Vector3.UP, dir)), Vector3.ZERO)
	cut.add_child(_disc(r, r * 1.6, -r * 0.8, flesh_material()))
	cut.add_child(_disc(r * 0.88, r * 0.04, r * 0.02, muscle_material()))
	cut.add_child(_disc(r * 0.34, r * 0.06, r * 0.05, bone_material()))
	cut.add_child(_disc(r * 0.14, r * 0.07, r * 0.055, marrow_material()))
	return cut


static func _disc(radius: float, height: float, y: float, mat: Material) -> MeshInstance3D:
	var c := CylinderMesh.new()
	c.top_radius = radius
	c.bottom_radius = radius * 1.04
	c.height = height
	c.radial_segments = 16
	c.rings = 1
	c.material = mat
	var mi := MeshInstance3D.new()
	mi.mesh = c
	mi.position = Vector3(0.0, y, 0.0)
	return mi


static func muscle_material() -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(0.72, 0.2, 0.2)
	m.roughness = 0.35
	return m


static func marrow_material() -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(0.3, 0.02, 0.03)
	m.roughness = 0.3
	return m


## Takes a limb off a drawn body: throws it as a gib, collapses its root bone and covers the cut. Returns the
## joint in world space, or `Vector3.INF` when the limb names no bone. [param key] names the cached limb mesh
## (definition id plus limb).
static func sever(sk: Skeleton3D, model: Node, key: String, limb: StringName, d: Dictionary, impulse: Vector3, silent := false) -> Vector3:
	var bones: Array = d.get("bones", [])
	var root := sk.find_bone(String(bones[0])) if not bones.is_empty() else -1
	if root < 0:
		return Vector3.INF
	var joint := sk.global_transform * sk.get_bone_global_pose(root).origin
	if not silent:
		spawn_gib(sk, model, key, root, limb, d, joint, impulse)
	collapse_bone(sk, model, root)
	add_stump(sk, root, d, not silent and DotNpcGore.spray_enabled())
	return joint


static func live_free(n: Node) -> void:
	if n != null:
		n.queue_free()


## Undoes every [method sever] on [param sk]: bones back to full scale, the drawn meshes whole, stumps gone.
## [param model] limits the mesh restore to that scene (default: the skeleton's siblings under its parent).
static func restore(sk: Skeleton3D, model: Node = null) -> void:
	for b in sk.get_meta(COLLAPSED, []):
		sk.set_bone_pose_scale(int(b), Vector3.ONE)
	sk.remove_meta(COLLAPSED)
	for c in sk.get_children():
		if c is BoneAttachment3D and (String(c.name).begins_with(STUMP_PREFIX) or String(c.name).begins_with(WOUND_PREFIX)):
			sk.remove_child(c)
			c.queue_free()
	var scope: Node = model if model != null else (sk.owner if sk.owner != null else sk.get_parent())
	if scope == null:
		return
	for m in scope.find_children("*", "MeshInstance3D", true, false):
		if m.has_meta(PRISTINE):
			m.mesh = m.get_meta(PRISTINE)
			m.remove_meta(PRISTINE)


## Timer callbacks hold a WeakRef: a lambda capturing the node itself logs "Lambda capture was freed" when the node is gone first.
static func _free_weak(ref: WeakRef, until := -1) -> void:
	var n := ref.get_ref() as Node
	# A recycled gib carries a later expiry; the timer of its first life must not cut the second short.
	if n != null and (until < 0 or int(n.get_meta(&"dot_npc_gib_until", until)) == until):
		n.queue_free()


static func _stop_weak(ref: WeakRef) -> void:
	var p := ref.get_ref() as CPUParticles3D
	if p != null:
		p.emitting = false


## Frees the oldest wound marks and pools until there is room for one more under [member DotNpcGore.max_wounds].
static func _make_room(tree: SceneTree) -> void:
	var live := tree.get_nodes_in_group(WOUND_GROUP)
	while live.size() >= DotNpcGore.max_wounds and not live.is_empty():
		var oldest := live[0] as Node
		live.remove_at(0)
		oldest.get_parent().remove_child(oldest)
		oldest.queue_free()


## A wet mark on the body where it was hit, riding the nearest bone. Pooled and capped; null headless, with gore
## off, or when no bone is near. [param world_point] is on or near the surface.
static func add_wound(sk: Skeleton3D, world_point: Vector3, size := 0.09) -> Node3D:
	if not drawn() or not DotNpcGore.wounds_enabled() or sk == null or not sk.is_inside_tree():
		return null
	var local := sk.global_transform.affine_inverse() * world_point
	var best := -1
	var best_d := INF
	var gone: Array = sk.get_meta(COLLAPSED, [])
	for i in sk.get_bone_count():
		if gone.has(i):
			continue
		var gap := sk.get_bone_global_pose(i).origin.distance_squared_to(local)
		if gap < best_d:
			best_d = gap
			best = i
	if best < 0:
		return null
	_make_room(sk.get_tree())
	if _blob_mat == null:
		_blob_mat = StandardMaterial3D.new()
		_blob_mat.albedo_color = Color(0.32, 0.01, 0.03)
		_blob_mat.roughness = 0.15
		_blob_mesh = SphereMesh.new()
		_blob_mesh.radius = 1.0
		_blob_mesh.height = 2.0
		_blob_mesh.radial_segments = 8
		_blob_mesh.rings = 4
		_blob_mesh.material = _blob_mat
	var att := BoneAttachment3D.new()
	att.name = "%s%d" % [WOUND_PREFIX, best]
	att.add_to_group(WOUND_GROUP)
	sk.add_child(att)
	att.bone_idx = best
	var mark := MeshInstance3D.new()
	mark.mesh = _blob_mesh
	var bone_local := sk.get_bone_global_pose(best).affine_inverse() * local
	var out := bone_local.normalized() if bone_local.length() > 0.001 else Vector3.UP
	var up := Vector3.UP if absf(out.dot(Vector3.UP)) < 0.95 else Vector3.RIGHT
	var basis := Basis.looking_at(out, up) * Basis.from_scale(Vector3(size, size * 0.8, size * 0.22))
	mark.transform = Transform3D(basis, bone_local)
	att.add_child(mark)
	return att


## A pool of blood on the floor at [param at] (a crawling body's trail): flat, shared mesh and material, capped
## with the wound marks and gone after [constant POOL_SECONDS]. Null headless or with gore off.
static func add_pool(tree: SceneTree, at: Vector3, radius := 0.22) -> Node3D:
	if not drawn() or not DotNpcGore.wounds_enabled() or tree == null:
		return null
	_make_room(tree)
	if _pool_mat == null:
		_pool_mat = StandardMaterial3D.new()
		_pool_mat.albedo_color = Color(0.28, 0.0, 0.02)
		_pool_mat.roughness = 0.1
		_pool_mesh = CylinderMesh.new()
		_pool_mesh.top_radius = 1.0
		_pool_mesh.bottom_radius = 1.0
		_pool_mesh.height = 0.004
		_pool_mesh.radial_segments = 10
		_pool_mesh.rings = 1
		_pool_mesh.material = _pool_mat
	var pool := MeshInstance3D.new()
	pool.mesh = _pool_mesh
	pool.add_to_group(WOUND_GROUP)
	pool.scale = Vector3(radius, 1.0, radius * 0.8)
	pool.rotation.y = randf() * TAU
	pool.position = at + Vector3(0.0, 0.012, 0.0)
	pool.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	(tree.current_scene if tree.current_scene != null else tree.root).add_child(pool)
	tree.create_timer(POOL_SECONDS).timeout.connect(_free_weak.bind(weakref(pool)))
	return pool
