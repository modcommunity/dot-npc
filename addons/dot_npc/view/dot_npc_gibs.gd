class_name DotNpcGibs
extends RefCounted

## What a severed limb looks like: the limb's own triangles as a tumbling body, a raw stump on what is left,
## and blood. Drawn only; the server decides what came off ([DotNpcLimbs]). No game knowledge.
##
## The limb is cut out of the model by vertex weight, not by scaling bones on a second copy: scaled-away bones
## leave stretched slivers across the cut. The skinned body hides the limb by collapsing its root bone.

const MAX_GIBS := 24
const GROUP := &"dot_npc_gibs"

static var _mesh_cache: Dictionary = {}


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


## Collapses [param root]'s bone and drops every triangle of the drawn body that the collapse would drag into a
## sheet (its longest edge grows past [param grow] times and by a visible amount). Skin weighted partly to the
## collapsed bone (entrails, a belly flap) would otherwise stretch toward the joint. Each body gets its own copy
## of the mesh, so the shared resource stays whole.
static func collapse_bone(sk: Skeleton3D, model: Node, root: int, grow := 2.0) -> void:
	var meshes: Array = []
	for m in model.find_children("*", "MeshInstance3D", true, false):
		var mi := m as MeshInstance3D
		if mi.mesh is ArrayMesh and mi.skin != null:
			var before := []
			for s in mi.mesh.get_surface_count():
				before.append(skinned(sk, mi, mi.mesh.surface_get_arrays(s)))
			meshes.append([mi, before])
	sk.set_bone_pose_scale(root, Vector3.ONE * 0.001)
	for entry in meshes:
		var mi: MeshInstance3D = entry[0]
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


## The limb's triangles in skeleton space, centred on its joint, or null when it has none.
static func limb_mesh(sk: Skeleton3D, model: Node, root: int, key: String) -> ArrayMesh:
	if _mesh_cache.has(key):
		return _mesh_cache[key]
	var in_limb := subtree(sk, root)
	var centre := sk.get_bone_global_rest(root).origin
	var mesh := ArrayMesh.new()
	for m in model.find_children("*", "MeshInstance3D", true, false):
		var mi := m as MeshInstance3D
		if mi.mesh == null:
			continue
		for s in mi.mesh.get_surface_count():
			var arrays := mi.mesh.surface_get_arrays(s)
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
				mat = mi.mesh.surface_get_material(s)
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
	p.amount = 28 if burst else 8
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
	drop.radius = 0.018
	drop.height = 0.036
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
	var live := world.get_tree().get_nodes_in_group(GROUP)
	while live.size() >= MAX_GIBS:
		live[0].queue_free()
		live.remove_at(0)

	var gib := RigidBody3D.new()
	gib.name = "Gib_%s" % limb
	gib.add_to_group(GROUP)
	gib.collision_layer = 0
	gib.collision_mask = 1
	gib.mass = float(d.get("gib_mass", 20.0))
	world.add_child(gib)
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
	var cap := cut_face(float(d.get("radius", 0.3)) * 0.42, -out.normalized() if out.length() > 0.001 else Vector3.DOWN)
	gib.add_child(cap)
	gib.linear_velocity = impulse + Vector3(randf_range(-1.0, 1.0), 2.5, randf_range(-1.0, 1.0))
	gib.angular_velocity = Vector3(randf_range(-4.0, 4.0), randf_range(-4.0, 4.0), randf_range(-4.0, 4.0))
	var spray := blood(true, impulse)
	gib.add_child(spray)
	spray.emitting = true
	var life := float(d.get("gib_seconds", 14.0))
	gib.get_tree().create_timer(life).timeout.connect(func(): if is_instance_valid(gib): gib.queue_free())
	return gib


## A raw cut on the part left behind, riding the parent bone: a flat-capped collar of flesh facing along the
## limb, a ring of pale muscle, a bone disc with a dark marrow dot, and a drip for a few seconds.
static func add_stump(sk: Skeleton3D, root: int, d: Dictionary) -> Node3D:
	if not drawn():
		return null
	var parent := sk.get_bone_parent(root)
	if parent < 0:
		return null
	var att := BoneAttachment3D.new()
	att.name = "Stump_%s" % sk.get_bone_name(root)
	sk.add_child(att)
	att.bone_idx = parent
	var at := sk.get_bone_global_rest(parent).affine_inverse() * sk.get_bone_global_rest(root).origin
	var r := float(d.get("radius", 0.3)) * 0.42
	var dir := at.normalized() if at.length() > 0.001 else Vector3.UP
	var cut := cut_face(r, dir)
	cut.position = at + dir * r * 0.3
	att.add_child(cut)
	var drip := blood(false, Vector3.ZERO)
	drip.position = at
	att.add_child(drip)
	drip.emitting = true
	sk.get_tree().create_timer(4.0).timeout.connect(func(): if is_instance_valid(drip): drip.emitting = false)
	return att


## The flat cut itself at the origin, facing [param dir]: flesh collar behind it, a ring of muscle, a bone disc
## and a dark marrow dot.
static func cut_face(r: float, dir: Vector3) -> Node3D:
	var cut := Node3D.new()
	cut.transform = Transform3D(Basis(Quaternion(Vector3.UP, dir)), Vector3.ZERO)
	cut.add_child(_disc(r, r * 1.1, -r * 0.55, flesh_material()))
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
static func sever(sk: Skeleton3D, model: Node, key: String, limb: StringName, d: Dictionary, impulse: Vector3) -> Vector3:
	var bones: Array = d.get("bones", [])
	var root := sk.find_bone(String(bones[0])) if not bones.is_empty() else -1
	if root < 0:
		return Vector3.INF
	var joint := sk.global_transform * sk.get_bone_global_pose(root).origin
	spawn_gib(sk, model, key, root, limb, d, joint, impulse)
	collapse_bone(sk, model, root)
	add_stump(sk, root, d)
	return joint
