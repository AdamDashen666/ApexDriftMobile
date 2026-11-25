class_name World
extends Node3D
# 载入一张地图：网格+材质、植被 MultiMesh、碰撞、天空与光

var map_id := ""
var meta: Dictionary = {}
var track := Track.new()
var env_node: WorldEnvironment
var env: Environment
var sun: DirectionalLight3D
var wx: Dictionary = {}
var dyn_bodies: Array[RigidBody3D] = []
var dyn_home: Array[Transform3D] = []
var lamps: Array[OmniLight3D] = []
var mats: Dictionary = {}
var quality := 1            # 0 流畅 1 均衡 2 精致
var petals: GPUParticles3D
var tree_lod0: Array[MultiMeshInstance3D] = []
var grass_nodes: Array[MultiMeshInstance3D] = []
var _qm: Dictionary = {}

func _init() -> void:
	env = Environment.new()
	env_node = WorldEnvironment.new()
	env_node.environment = env
	add_child(env_node)
	sun = DirectionalLight3D.new()
	sun.shadow_enabled = true
	sun.directional_shadow_mode = DirectionalLight3D.SHADOW_ORTHOGONAL
	sun.directional_shadow_max_distance = 46.0
	sun.directional_shadow_fade_start = 0.75
	sun.shadow_bias = 0.04
	sun.shadow_normal_bias = 1.2
	sun.light_angular_distance = 0.0
	add_child(sun)

func load_map(id: String) -> void:
	map_id = id
	var dir := "res://assets/maps/%s/" % id
	meta = GameData._json(dir + "map.json")
	track.setup(meta)
	_make_mats(dir)
	var scn: PackedScene = load(dir + "map.glb")
	var root := scn.instantiate()
	var road_faces := PackedVector3Array()
	var solids: Array = []
	for node in root.find_children("*", "MeshInstance3D", true, false):
		var mi: MeshInstance3D = node
		var nm := String(mi.name)
		for s in mi.mesh.get_surface_count():
			var m: Material = mi.mesh.surface_get_material(s)
			var key := (m.resource_name if m else "X_Prop").replace("X_", "")
			mi.set_surface_override_material(s, mats.get(key, mats["Prop"]))
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		if nm.begins_with("Road_"):
			road_faces.append_array(mi.mesh.get_faces())
		elif nm.begins_with("Solid_"):
			solids.append(mi)
			mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
		elif nm.begins_with("Rail_"):
			mi.visibility_range_end = 420.0
		elif nm.begins_with("Marks_"):
			mi.sorting_offset = 1.0
		mi.owner = null
		mi.get_parent().remove_child(mi)
		add_child(mi)
	root.free()
	_collision(road_faces, solids)
	_trees(dir)
	_clutter(dir)
	_props()
	if meta.has("dyn"):
		_dynamic(dir)

func _make_mats(dir: String) -> void:
	var det: Texture2D = Mats.tex("asphalt.jpg")
	var mac: Texture2D = Mats.tex("macro.jpg")
	var gr: Texture2D = Mats.tex("grass.jpg")
	var tint := Color(0.40, 0.50, 0.20)
	if map_id == "MomijiTouge":
		tint = Color(0.56, 0.47, 0.22)
	elif map_id == "KuroshioCircuit":
		tint = Color(0.42, 0.46, 0.24)
	mats["Road"] = Mats.make("road", Mats.ROAD, {"detail": det, "macro_t": mac, "center_dash": 0.0 if map_id == "MomijiTouge" else 1.0})
	mats["Shoulder"] = Mats.make("shoulder", Mats.SHOULDER, {"detail": gr, "tint": tint})
	mats["Terrain"] = Mats.make("terrain", Mats.TERRAIN, {"ground": load(dir + "ground.jpg"), "detail": gr})
	mats["Pad"] = Mats.make("pad", Mats.PAD, {"detail": det, "macro_t": mac})
	mats["Paint"] = Mats.make("vcol", Mats.VCOL, {"rough": 0.5, "spec": 0.45})
	mats["Marks"] = Mats.make("marks", Mats.MARKS, {"detail": det})
	mats["Prop"] = Mats.make("vcol", Mats.VCOL, {"rough": 0.8, "spec": 0.25, "emit": 0.0})
	mats["Far"] = Mats.make("vcolf", Mats.VCOL_FLAT)
	mats["Rail"] = Mats.make("rail", Mats.RAIL)
	mats["Water"] = Mats.make("water", Mats.WATER)

func _collision(road: PackedVector3Array, solids: Array) -> void:
	var body := StaticBody3D.new()
	body.collision_layer = 1
	body.collision_mask = 0
	var pm := PhysicsMaterial.new()
	pm.friction = 0.15
	body.physics_material_override = pm
	add_child(body)
	if road.size() > 0:
		var cs := CollisionShape3D.new()
		var sh := ConcavePolygonShape3D.new()
		sh.set_faces(road)
		cs.shape = sh
		body.add_child(cs)
	if meta.get("free", false):
		var cs2 := CollisionShape3D.new()
		var bx := BoxShape3D.new()
		bx.size = Vector3(1004, 4, 1004)
		cs2.shape = bx
		cs2.position = Vector3(0, -2, 0)
		body.add_child(cs2)
		for mi in solids:
			var cs3 := CollisionShape3D.new()
			var sh3 := ConcavePolygonShape3D.new()
			sh3.backface_collision = true
			sh3.set_faces(mi.mesh.get_faces())
			cs3.shape = sh3
			body.add_child(cs3)

# ------------------------------------------------------------------ 植被
func _bin(path: String) -> PackedFloat32Array:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return PackedFloat32Array()
	return f.get_buffer(f.get_length()).to_float32_array()

static func _cross_mesh() -> ArrayMesh:
	var v := PackedVector3Array()
	var nrm := PackedVector3Array()
	var uv := PackedVector2Array()
	var uv2 := PackedVector2Array()
	var idx := PackedInt32Array()
	for q in 2:
		var b := v.size()
		var ax := Vector3(0.5, 0, 0) if q == 0 else Vector3(0, 0, 0.5)
		for c in [[-1, 0], [1, 0], [1, 1], [-1, 1]]:
			v.append(ax * float(c[0]) + Vector3(0, float(c[1]), 0))
			var side := ax.normalized() * float(c[0]) * 0.55
			nrm.append((Vector3(0, 0.85, 0) + side).normalized())
			uv.append(Vector2(0.0 if c[0] < 0 else 1.0, 1.0 - float(c[1])))
			uv2.append(Vector2(q, 0))
		idx.append_array(PackedInt32Array([b, b + 1, b + 2, b, b + 2, b + 3]))
	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = v
	arr[Mesh.ARRAY_NORMAL] = nrm
	arr[Mesh.ARRAY_TEX_UV] = uv
	arr[Mesh.ARRAY_TEX_UV2] = uv2
	arr[Mesh.ARRAY_INDEX] = idx
	var m := ArrayMesh.new()
	m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	return m

static func _leaf_tex(sp: String) -> String:
	if sp.contains("Sakura"): return "leaf_sakura.png"
	if sp.contains("Maple"): return "leaf_maple.png"
	if sp.contains("Cedar"): return "leaf_cedar.png"
	if sp.contains("Pine"): return "leaf_pine.png"
	if sp.contains("Bamboo"): return "leaf_bamboo.png"
	if sp.contains("Azalea"): return "leaf_azalea.png"
	if sp.contains("Flower"): return "leaf_flower.png"
	return "leaf_bush.png"

static func _tint(sp: int, variant: int, hash_v: float) -> Color:
	var c := Color(1, 1, 1)
	var sp_name: String = GameData.TREE_ORDER[sp]
	if sp_name.contains("Sakura"):
		c = Color(1.22, 0.98, 1.06)
	elif sp_name.contains("Maple"):
		# 原贴图是红叶；橙、金靠抬绿通道
		c = [Color(1.0, 1.0, 1.0), Color(1.15, 2.1, 1.0), Color(1.25, 3.6, 1.2)][variant]
	var l := 0.88 + 0.24 * hash_v
	return Color(c.r * l, c.g * l, c.b * l)

func _tree_mesh(sp: String) -> Mesh:
	if _qm.has(sp):
		return _qm[sp]
	var scn: PackedScene = load("res://assets/flora/%s.glb" % sp)
	var root := scn.instantiate()
	var mi: MeshInstance3D = root.find_children("*", "MeshInstance3D", true, false)[0]
	var m: Mesh = mi.mesh.duplicate()
	root.free()
	for s in m.get_surface_count():
		var nm: String = m.surface_get_material(s).resource_name if m.surface_get_material(s) else "X_Leaf"
		if nm.contains("Bark"):
			var bk := "sakura"
			for k in ["Maple", "Cedar", "Pine", "Bamboo"]:
				if sp.contains(k):
					bk = k.to_lower()
			var sm := StandardMaterial3D.new()
			sm.albedo_texture = Mats.tex("bark_%s.jpg" % bk)
			sm.vertex_color_use_as_albedo = true
			sm.vertex_color_is_srgb = true
			sm.roughness = 1.0
			sm.metallic_specular = 0.1
			m.surface_set_material(s, sm)
		else:
			m.surface_set_material(s, Mats.make("leaf", Mats.LEAF, {"tex": Mats.tex(_leaf_tex(sp))}))
	_qm[sp] = m
	return m

func _trees(dir: String) -> void:
	var cross := _cross_mesh()
	var imp := Mats.make("imp", Mats.IMPOSTOR, {"tex": Mats.tex("trees_atlas.png")})
	cross.surface_set_material(0, imp)
	mats["Impostor"] = imp
	var rect: Array = []
	for a in GameData.atlas:
		rect.append([float(a["w"]), float(a["h"]), Color(a["uv"][0], a["uv"][1], a["uv"][2], a["uv"][3])])
	# 近处树：64m 一格，近用低模、远用 impostor
	var near := _bin(dir + "trees_near.bin")
	var cells := {}
	for i in range(0, near.size(), 7):
		var key := Vector2i(floori(near[i] / 64.0), floori(near[i + 1] / 64.0))
		if not cells.has(key):
			cells[key] = []
		cells[key].append(i)
	var lod_dist := 92.0
	for key in cells:
		var ids: Array = cells[key]
		var ctr := Vector3((key.x + 0.5) * 64.0, 0, (key.y + 0.5) * 64.0)
		_imp_mm(near, ids, cross, rect, ctr, lod_dist, 900.0)
		var by := {}
		for i in ids:
			var sp := int(near[i + 5])
			if not by.has(sp):
				by[sp] = []
			by[sp].append(i)
		for sp in by:
			var l: Array = by[sp]
			var mm := MultiMesh.new()
			mm.transform_format = MultiMesh.TRANSFORM_3D
			mm.use_custom_data = true
			mm.mesh = _tree_mesh(GameData.TREE_ORDER[sp])
			mm.instance_count = l.size()
			for q in l.size():
				var i: int = l[q]
				var pos := Vector3(near[i], near[i + 2], near[i + 1]) - ctr
				var sc := near[i + 4]
				mm.set_instance_transform(q, Transform3D(Basis(Vector3.UP, -near[i + 3]).scaled(Vector3(sc, sc, sc)), pos))
				mm.set_instance_custom_data(q, _tint(sp, int(near[i + 6]), fposmod(near[i] * 0.37 + near[i + 1] * 0.71, 1.0)))
			var mi := MultiMeshInstance3D.new()
			mi.multimesh = mm
			mi.position = ctr
			mi.visibility_range_end = lod_dist
			mi.visibility_range_end_margin = 4.0
			mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			add_child(mi)
			tree_lod0.append(mi)
	# 远处树：192m 一格，只有 impostor
	var far := _bin(dir + "trees_far.bin")
	var cells2 := {}
	for i in range(0, far.size(), 7):
		var key := Vector2i(floori(far[i] / 192.0), floori(far[i + 1] / 192.0))
		if not cells2.has(key):
			cells2[key] = []
		cells2[key].append(i)
	for key in cells2:
		_imp_mm(far, cells2[key], cross, rect, Vector3((key.x + 0.5) * 192.0, 0, (key.y + 0.5) * 192.0), 0.0, 1500.0)

func _imp_mm(data: PackedFloat32Array, ids: Array, mesh: Mesh, rect: Array, ctr: Vector3, begin: float, end: float) -> void:
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.use_custom_data = true
	mm.mesh = mesh
	mm.instance_count = ids.size()
	for q in ids.size():
		var i: int = ids[q]
		var sp := int(data[i + 5])
		var r: Array = rect[sp]
		var sc := data[i + 4]
		var pos := Vector3(data[i], data[i + 2] - 0.05, data[i + 1]) - ctr
		var b := Basis(Vector3.UP, -data[i + 3]) * Basis.from_scale(Vector3(r[0] * sc, r[1] * sc, r[0] * sc))
		mm.set_instance_transform(q, Transform3D(b, pos))
		mm.set_instance_color(q, _tint(sp, int(data[i + 6]), fposmod(data[i] * 0.37 + data[i + 1] * 0.71, 1.0)))
		mm.set_instance_custom_data(q, r[2])
	var mi := MultiMeshInstance3D.new()
	mi.multimesh = mm
	mi.position = ctr
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	if begin > 0.0:
		mi.visibility_range_begin = begin
		mi.visibility_range_begin_margin = 4.0
	mi.visibility_range_end = end
	add_child(mi)

static func _tuft(blades: int, h: float, spread: float) -> ArrayMesh:
	var v := PackedVector3Array()
	var nrm := PackedVector3Array()
	var col := PackedColorArray()
	var rng := RandomNumberGenerator.new()
	rng.seed = 11
	for i in blades:
		var a := rng.randf() * TAU
		var o := Vector3(cos(a), 0, sin(a)) * spread * sqrt(rng.randf())
		var d := rng.randf() * TAU
		var w := Vector3(cos(d), 0, sin(d)) * 0.035
		var lean := Vector3(cos(a), 0, sin(a)) * 0.16 * rng.randf_range(0.3, 1.2)
		var hh := h * rng.randf_range(0.6, 1.1)
		for p in [o - w, o + w, o + lean + Vector3(0, hh, 0)]:
			v.append(p)
			nrm.append(Vector3.UP)
		col.append_array(PackedColorArray([Color(0, 0, 0), Color(0, 0, 0), Color(1, 1, 1)]))
	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = v
	arr[Mesh.ARRAY_NORMAL] = nrm
	arr[Mesh.ARRAY_COLOR] = col
	var m := ArrayMesh.new()
	m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	return m

func _clutter(dir: String) -> void:
	for key in ["SM_Grass_Clump", "SM_Grass_Tall", "SM_Flower_Patch_01", "SM_Flower_Patch_02", "SM_Azalea", "SM_Bush"]:
		var d := _bin(dir + key + ".bin")
		if d.is_empty():
			continue
		var mesh: Mesh
		var grass: bool = key.begins_with("SM_Grass")
		var rng_end := 46.0
		if grass:
			mesh = _tuft(9, 0.34 if key == "SM_Grass_Clump" else 1.1, 0.34 if key == "SM_Grass_Clump" else 0.4)
			var b := Color(0.30, 0.42, 0.14)
			var t := Color(0.56, 0.68, 0.30)
			if map_id == "MomijiTouge":
				b = Color(0.42, 0.36, 0.14)
				t = Color(0.78, 0.66, 0.34)
			if key == "SM_Grass_Tall":
				t = Color(0.86, 0.78, 0.55)
				rng_end = 70.0
			mesh.surface_set_material(0, Mats.make("grass", Mats.GRASS, {"base": b, "tip": t}))
		else:
			var sp: String = key if key.begins_with("SM_Flower") else key + "_01"
			mesh = _tree_mesh(sp)
			rng_end = 130.0 if key.begins_with("SM_Flower") else 100.0
		var cell := 48.0 if grass else 64.0
		var cells := {}
		for i in range(0, d.size(), 5):
			var k2 := Vector2i(floori(d[i] / cell), floori(d[i + 1] / cell))
			if not cells.has(k2):
				cells[k2] = []
			cells[k2].append(i)
		for k2 in cells:
			var ids: Array = cells[k2]
			var ctr := Vector3((k2.x + 0.5) * cell, 0, (k2.y + 0.5) * cell)
			var mm := MultiMesh.new()
			mm.transform_format = MultiMesh.TRANSFORM_3D
			mm.mesh = mesh
			mm.instance_count = ids.size()
			for q in ids.size():
				var i: int = ids[q]
				var sc := d[i + 4]
				mm.set_instance_transform(q, Transform3D(Basis(Vector3.UP, -d[i + 3]).scaled(Vector3(sc, sc, sc)), Vector3(d[i], d[i + 2], d[i + 1]) - ctr))
			var mi := MultiMeshInstance3D.new()
			mi.multimesh = mm
			mi.position = ctr
			mi.visibility_range_end = rng_end + cell * 0.5
			mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			add_child(mi)
			if grass:
				grass_nodes.append(mi)

# ------------------------------------------------------------------ 道具
func _prop_mesh(name: String) -> Mesh:
	var p := "res://assets/props/%s.glb" % name
	if not ResourceLoader.exists(p):
		return null
	var root: Node = (load(p) as PackedScene).instantiate()
	var mi: MeshInstance3D = root.find_children("*", "MeshInstance3D", true, false)[0]
	var m: Mesh = mi.mesh
	root.free()
	for s in m.get_surface_count():
		m.surface_set_material(s, mats["Prop"])
	return m

func _multi(mesh: Mesh, xfs: Array, cell: float, end: float, shadow := false, colors: Array = []) -> void:
	var cells := {}
	for i in xfs.size():
		var o: Vector3 = xfs[i].origin
		var k := Vector2i(floori(o.x / cell), floori(o.z / cell))
		if not cells.has(k):
			cells[k] = []
		cells[k].append(i)
	for k in cells:
		var ids: Array = cells[k]
		var ctr := Vector3((k.x + 0.5) * cell, 0, (k.y + 0.5) * cell)
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.use_colors = not colors.is_empty()
		mm.mesh = mesh
		mm.instance_count = ids.size()
		for q in ids.size():
			var x: Transform3D = xfs[ids[q]]
			x.origin -= ctr
			mm.set_instance_transform(q, x)
			if not colors.is_empty():
				mm.set_instance_color(q, colors[ids[q]])
		var mi := MultiMeshInstance3D.new()
		mi.multimesh = mm
		mi.position = ctr
		mi.visibility_range_end = end + cell * 0.5
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if shadow else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(mi)

func _props() -> void:
	var pr: Dictionary = meta.get("props", {})
	for name in pr:
		var m := _prop_mesh(name)
		if m == null:
			continue
		var xfs: Array = []
		for r in pr[name]:
			xfs.append(Transform3D(Basis(Vector3.UP, -float(r[3])).scaled(Vector3.ONE * float(r[4])), Vector3(r[0], r[1], r[2])))
		var big: bool = name.contains("Pagoda") or name.contains("Torii_L") or name.contains("StartArch") or name.contains("Minka") or name.contains("Shrine") or name.contains("Grandstand")
		_multi(m, xfs, 4000.0 if pr[name].size() < 3 else 220.0, 2500.0 if big else 260.0, big)
	# 弯道导向牌
	var sg: Array = meta.get("signs", [])
	if sg.size() > 0:
		var m2 := _sign_mesh()
		var xfs2: Array = []
		for r in sg:
			var yaw := float(r[3])
			var b := Basis(Vector3.UP, -yaw)
			if float(r[4]) < 0.0:
				b = b * Basis.from_scale(Vector3(1, 1, -1))
			xfs2.append(Transform3D(b, Vector3(r[0], r[1], r[2])))
		_multi(m2, xfs2, 160.0, 260.0)
	# 集装箱
	var ct: Array = meta.get("containers", [])
	if ct.size() > 0:
		var pal := [Color(0.45, 0.06, 0.03), Color(0.03, 0.13, 0.32), Color(0.05, 0.25, 0.12), Color(0.62, 0.30, 0.03), Color(0.35, 0.36, 0.37)]
		var xfs3: Array = []
		var cols: Array = []
		for r in ct:
			xfs3.append(Transform3D(Basis(Vector3.UP, -float(r[3])), Vector3(r[0], r[1], r[2])))
			cols.append(pal[int(r[4])])
		_multi(_container_mesh(), xfs3, 200.0, 600.0, true, cols)

func _quad(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, d: Vector3, n: Vector3, col: Color) -> void:
	for tri in [[a, b, c], [a, c, d]]:
		var nn: Vector3 = (tri[1] - tri[0]).cross(tri[2] - tri[0])
		var o: Array = tri if nn.dot(n) < 0.0 else [tri[0], tri[2], tri[1]]   # Godot 顺时针为正面
		for v in o:
			st.set_normal(n)
			st.set_color(col)
			st.add_vertex(v)

func _sign_mesh() -> Mesh:
	# 面向 -X（迎着来车），箭头指向 +Z（右弯）
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var y0 := 0.55
	var y1 := 1.25
	var w := 0.42
	var n := Vector3(-1, 0, 0)
	_quad(st, Vector3(0, y0, -w), Vector3(0, y0, w), Vector3(0, y1, w), Vector3(0, y1, -w), n, Color(0.72, 0.04, 0.03))
	_quad(st, Vector3(0.02, y0, -w), Vector3(0.02, y0, w), Vector3(0.02, y1, w), Vector3(0.02, y1, -w), -n, Color(0.4, 0.4, 0.4))
	var ym := (y0 + y1) * 0.5
	for k in 2:
		var z := -0.28 + 0.34 * k
		for sg in [-1.0, 1.0]:
			_quad(st, Vector3(-0.012, ym, z + 0.26), Vector3(-0.012, ym, z + 0.10), Vector3(-0.012, ym + sg * 0.27, z - 0.08), Vector3(-0.012, ym + sg * 0.27, z + 0.08), n, Color(0.95, 0.95, 0.93))
	for z in [-0.3, 0.3]:
		_quad(st, Vector3(0.01, -0.3, z - 0.03), Vector3(0.01, -0.3, z + 0.03), Vector3(0.01, y0, z + 0.03), Vector3(0.01, y0, z - 0.03), n, Color(0.4, 0.4, 0.4))
	var m := st.commit()
	var mt := Mats.make("signs", "shader_type spatial;\nrender_mode cull_disabled, diffuse_lambert, specular_disabled;\nvoid fragment(){ ALBEDO=COLOR.rgb; ROUGHNESS=1.0; EMISSION=COLOR.rgb*0.12; }")
	m.surface_set_material(0, mt)
	return m

func _container_mesh() -> Mesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var hx := 3.03
	var hz := 1.22
	var h := 2.6
	for sg in [-1.0, 1.0]:
		var n := Vector3(0, 0, sg)
		var cnt := 11
		for i in cnt:
			var x0 := -hx + 2.0 * hx * i / cnt
			var x1 := -hx + 2.0 * hx * (i + 1) / cnt
			var z := hz if i % 2 == 0 else hz - 0.05
			_quad(st, Vector3(x0, 0, sg * z), Vector3(x1, 0, sg * z), Vector3(x1, h, sg * z), Vector3(x0, h, sg * z), n, Color(1, 1, 1) if i % 2 == 0 else Color(0.6, 0.6, 0.6))
		_quad(st, Vector3(sg * hx, 0, -hz), Vector3(sg * hx, 0, hz), Vector3(sg * hx, h, hz), Vector3(sg * hx, h, -hz), Vector3(sg, 0, 0), Color(0.85, 0.85, 0.85))
	_quad(st, Vector3(-hx, h, -hz), Vector3(hx, h, -hz), Vector3(hx, h, hz), Vector3(-hx, h, hz), Vector3.UP, Color(0.9, 0.9, 0.9))
	var m := st.commit()
	m.surface_set_material(0, Mats.make("vcol", Mats.VCOL, {"rough": 0.6, "spec": 0.35, "raw": 1.0}))
	return m

# ------------------------------------------------------------------ 可撞飞道具
func _dynamic(dir: String) -> void:
	var root: Node = (load(dir + "dyn.glb") as PackedScene).instantiate()
	var meshes := {}
	for node in root.find_children("*", "MeshInstance3D", true, false):
		var m: Mesh = node.mesh
		m.surface_set_material(0, mats["Paint"])
		meshes[String(node.name)] = m
	root.free()
	var kinds: Dictionary = meta["kinds"]
	var shapes := {}
	for k in kinds:
		var d: Dictionary = kinds[k]
		var off := Vector3.ZERO
		var sh: Shape3D
		match d["shape"]:
			"box":
				var b := BoxShape3D.new()
				b.size = Vector3(d["size"][0], d["size"][2], d["size"][1])
				sh = b
				off.y = b.size.y * 0.5
			"sphere":
				var s := SphereShape3D.new()
				s.radius = d["r"]
				sh = s
				off.y = s.radius
			"cyl":
				var c := CylinderShape3D.new()
				c.radius = d["r"]
				c.height = d["h"]
				sh = c
				off.y = c.height * 0.5
			_:
				var cv := ConvexPolygonShape3D.new()
				var pts := PackedVector3Array()
				var r: float = d["r"]
				var h: float = d["h"]
				for q in 8:
					var a := TAU * q / 8.0
					pts.append(Vector3(cos(a) * r * 0.85, 0, sin(a) * r * 0.85))
					pts.append(Vector3(cos(a) * r, h * 0.3, sin(a) * r))
					pts.append(Vector3(cos(a) * r * 0.25, h, sin(a) * r * 0.25))
				cv.points = pts
				sh = cv
		shapes[k] = [sh, off]
	var pm := PhysicsMaterial.new()
	pm.friction = 0.7
	pm.bounce = 0.15
	for k in meta["dyn"]:
		for r in meta["dyn"][k]:
			var rb := RigidBody3D.new()
			rb.mass = kinds[k]["mass"]
			rb.collision_layer = 2
			rb.collision_mask = 1 | 2 | 4
			rb.physics_material_override = pm
			rb.linear_damp = 0.15
			rb.angular_damp = 0.5
			rb.can_sleep = true
			var cs := CollisionShape3D.new()
			cs.shape = shapes[k][0]
			cs.position = shapes[k][1]
			rb.add_child(cs)
			var mi := MeshInstance3D.new()
			mi.mesh = meshes[k]
			mi.visibility_range_end = 260.0
			rb.add_child(mi)
			var xf := Transform3D(Basis(Vector3.UP, -float(r[3])), Vector3(r[0], r[1], r[2]))
			rb.transform = xf
			rb.sleeping = true
			add_child(rb)
			dyn_bodies.append(rb)
			dyn_home.append(xf)

func reset_props() -> void:
	for i in dyn_bodies.size():
		var rb := dyn_bodies[i]
		var rid := rb.get_rid()
		PhysicsServer3D.body_set_state(rid, PhysicsServer3D.BODY_STATE_LINEAR_VELOCITY, Vector3.ZERO)
		PhysicsServer3D.body_set_state(rid, PhysicsServer3D.BODY_STATE_ANGULAR_VELOCITY, Vector3.ZERO)
		PhysicsServer3D.body_set_state(rid, PhysicsServer3D.BODY_STATE_TRANSFORM, dyn_home[i])
		rb.global_transform = dyn_home[i]
		rb.linear_velocity = Vector3.ZERO
		rb.angular_velocity = Vector3.ZERO
		rb.sleeping = true

func moved_props() -> int:
	var c := 0
	for i in dyn_bodies.size():
		if dyn_bodies[i].global_position.distance_to(dyn_home[i].origin) > 1.0:
			c += 1
	return c

# ------------------------------------------------------------------ 天气
func set_weather(idx: int) -> void:
	wx = GameData.weather(map_id, idx)
	var p := deg_to_rad(wx["pitch"])
	var y := deg_to_rad(wx["yaw"])
	var dir := Vector3(cos(p) * cos(y), sin(p), cos(p) * sin(y))
	sun.look_at_from_position(Vector3.ZERO, dir, Vector3.UP)
	sun.light_color = wx["color"]
	sun.light_energy = 0.92 * float(wx["energy"])
	var si: Dictionary = GameData.sky_info[wx["sky"]]
	var sm := ShaderMaterial.new()
	sm.shader = Mats._shader("sky", Mats.SKY)
	sm.set_shader_parameter("hi", load("res://assets/sky/%s.jpg" % wx["sky"]))
	sm.set_shader_parameter("lo", load("res://assets/sky/%s.hdr" % wx["sky"]))
	sm.set_shader_parameter("k", float(si["k"]))
	sm.set_shader_parameter("gain", float(wx["sky_gain"]))
	sm.set_shader_parameter("sun_az", y + PI)
	sm.set_shader_parameter("horizon", wx["fog"])
	var sky := Sky.new()
	sky.sky_material = sm
	sky.radiance_size = Sky.RADIANCE_SIZE_128
	sky.process_mode = Sky.PROCESS_MODE_QUALITY
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_sky_contribution = 1.0
	env.ambient_light_energy = 0.78 * float(wx["ambient"])
	env.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
	env.tonemap_mode = Environment.TONE_MAPPER_ACES
	env.tonemap_exposure = 0.80 * float(wx["exposure"])
	env.tonemap_white = 6.0
	env.fog_enabled = true
	env.fog_light_color = wx["fog"]
	env.fog_light_energy = 1.0
	env.fog_sun_scatter = 0.0
	env.fog_density = wx["fog_d"]
	env.fog_aerial_perspective = 0.0
	env.fog_sky_affect = 0.0
	env.adjustment_enabled = false
	env.glow_enabled = false
	for nm in ["Road"]:
		mats[nm].set_shader_parameter("wet", float(wx["wet"]))
	mats["Prop"].set_shader_parameter("emit", 2.2 if wx["night"] else 0.35)
	_lamps()
	_petals()

func _lamps() -> void:
	for l in lamps:
		l.queue_free()
	lamps.clear()
	if not wx["night"]:
		return
	var ls: Array = meta.get("lights", [])
	# 夜间只放少量大范围无阴影点光
	var cnt := 0
	for q in ls:
		if map_id != "TrainingPark" and cnt >= 60:
			break
		var o := OmniLight3D.new()
		o.position = Vector3(q[0], q[1], q[2])
		o.shadow_enabled = false
		if map_id == "TrainingPark":
			o.omni_range = 260.0
			o.light_energy = 11.0
			o.omni_attenuation = 0.8
			o.light_color = Color(0.96, 0.97, 1.0)
		else:
			o.omni_range = 20.0
			o.light_energy = 3.4
			o.omni_attenuation = 1.0
			o.light_color = Color(1.0, 0.84, 0.62)
		o.distance_fade_enabled = map_id != "TrainingPark"
		o.distance_fade_begin = 110.0
		o.distance_fade_length = 40.0
		add_child(o)
		lamps.append(o)
		cnt += 1

func _petals() -> void:
	if petals:
		petals.queue_free()
		petals = null
	if float(wx["petals"]) < 0.1 or quality < 1:
		return
	petals = GPUParticles3D.new()
	petals.amount = int(70 * float(wx["petals"]))
	petals.lifetime = 5.0
	petals.preprocess = 4.0
	petals.visibility_aabb = AABB(Vector3(-30, -20, -30), Vector3(60, 40, 60))
	var pm := ParticleProcessMaterial.new()
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	pm.emission_box_extents = Vector3(24, 7, 24)
	pm.direction = Vector3(1, -0.4, 0.3)
	pm.spread = 30.0
	pm.initial_velocity_min = 0.8
	pm.initial_velocity_max = 2.2
	pm.gravity = Vector3(0.5, -0.55, 0.2)
	pm.angular_velocity_min = -160.0
	pm.angular_velocity_max = 160.0
	pm.scale_min = 0.6
	pm.scale_max = 1.2
	petals.process_material = pm
	var q := QuadMesh.new()
	q.size = Vector2(0.085, 0.06)
	var sm := StandardMaterial3D.new()
	sm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	sm.cull_mode = BaseMaterial3D.CULL_DISABLED
	sm.albedo_color = Color(0.80, 0.30, 0.10) if map_id == "MomijiTouge" else Color(0.98, 0.80, 0.87)
	sm.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	q.material = sm
	petals.draw_pass_1 = q
	petals.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(petals)

func follow(pos: Vector3) -> void:
	if petals:
		petals.global_position = pos + Vector3(0, 5, 0)

func set_quality(q: int) -> void:
	quality = q
	sun.directional_shadow_max_distance = [34.0, 46.0, 70.0][q]
	for g in grass_nodes:
		g.visible = q >= 1
	for tnode in tree_lod0:
		tnode.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if q >= 2 else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
