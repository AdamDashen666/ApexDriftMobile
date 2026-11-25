class_name Fx
extends Node3D
# 烟雾与胎痕：各一个 MultiMesh，CPU 端环形缓冲，不产生节点

const SMOKE_N := 110
const SKID_N := 1400

var car: Car
var smoke := MultiMesh.new()
var skid := MultiMesh.new()
var smat: ShaderMaterial
var s_pos := PackedVector3Array()
var s_vel := PackedVector3Array()
var s_age := PackedFloat32Array()
var s_life := PackedFloat32Array()
var s_size := PackedFloat32Array()
var s_rot := PackedFloat32Array()
var s_cell := PackedFloat32Array()
var s_a := PackedFloat32Array()
var s_head := 0
var emit_acc := 0.0
var k_head := 0
var last := [Vector3.INF, Vector3.INF, Vector3.INF, Vector3.INF]
var lastw := [Vector3.ZERO, Vector3.ZERO, Vector3.ZERO, Vector3.ZERO]
var amount := 1.0
var rng := RandomNumberGenerator.new()
var alive := 0

func _ready() -> void:
	rng.seed = 3
	smoke.transform_format = MultiMesh.TRANSFORM_3D
	smoke.use_custom_data = true
	var q := QuadMesh.new()
	q.size = Vector2(1, 1)
	smat = Mats.make("smoke", Mats.SMOKE, {"tex": Mats.tex("smoke.png")})
	q.material = smat
	smoke.mesh = q
	smoke.instance_count = SMOKE_N
	smoke.visible_instance_count = 0
	var mi := MultiMeshInstance3D.new()
	mi.multimesh = smoke
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.custom_aabb = AABB(Vector3(-6000, -300, -6000), Vector3(12000, 1500, 12000))
	mi.sorting_offset = 10.0
	add_child(mi)
	for a in [s_pos, s_vel]:
		pass
	s_pos.resize(SMOKE_N)
	s_vel.resize(SMOKE_N)
	s_age.resize(SMOKE_N)
	s_life.resize(SMOKE_N)
	s_size.resize(SMOKE_N)
	s_rot.resize(SMOKE_N)
	s_cell.resize(SMOKE_N)
	s_a.resize(SMOKE_N)
	for i in SMOKE_N:
		s_age[i] = 99.0
		s_life[i] = 1.0
	skid.transform_format = MultiMesh.TRANSFORM_3D
	skid.use_colors = true
	var pm := PlaneMesh.new()
	pm.size = Vector2(1, 1)
	pm.material = Mats.make("skid", Mats.SKID)
	skid.mesh = pm
	skid.instance_count = SKID_N
	for i in SKID_N:
		skid.set_instance_transform(i, Transform3D(Basis.from_scale(Vector3(0.0001, 0.0001, 0.0001)), Vector3(0, -500, 0)))
		skid.set_instance_color(i, Color(0, 0, 0, 0))
	var mk := MultiMeshInstance3D.new()
	mk.multimesh = skid
	mk.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mk.custom_aabb = AABB(Vector3(-6000, -300, -6000), Vector3(12000, 1500, 12000))
	mk.sorting_offset = -5.0
	add_child(mk)

func clear() -> void:
	for i in SMOKE_N:
		s_age[i] = 99.0
	for i in SKID_N:
		skid.set_instance_color(i, Color(0, 0, 0, 0))
	for i in 4:
		last[i] = Vector3.INF

func puff(pos: Vector3, vel: Vector3, size: float, life: float, a: float) -> void:
	var i := s_head
	s_head = (s_head + 1) % SMOKE_N
	s_pos[i] = pos
	s_vel[i] = vel
	s_age[i] = 0.0
	s_life[i] = life
	s_size[i] = size
	s_rot[i] = rng.randf() * TAU
	s_cell[i] = rng.randi() % 16
	s_a[i] = a

func set_light(c: Color) -> void:
	smat.set_shader_parameter("lit", c)

func _process(dt: float) -> void:
	if car == null:
		return
	var vel := car.visual_vel()
	var xf := car.visual_xf()
	# ---- 生成烟
	if car.skid > 0.12 and car.grounded >= 2 and amount > 0.0:
		emit_acc += dt * (16.0 + 44.0 * car.skid) * amount
		while emit_acc >= 1.0:
			emit_acc -= 1.0
			var side := 1.0 if rng.randf() < 0.5 else -1.0
			var wl: Vector3 = car._wl[3] if side > 0.0 else car._wl[2]
			var pos := xf * (wl + Vector3(-0.15, 0.12, 0)) + Vector3(rng.randf_range(-0.2, 0.2), 0, rng.randf_range(-0.2, 0.2))
			var v := vel * rng.randf_range(0.10, 0.30) + xf.basis.z * side * rng.randf_range(0.2, 1.4) + Vector3(0, rng.randf_range(0.4, 1.1), 0)
			puff(pos, v, rng.randf_range(0.8, 1.3), rng.randf_range(0.8, 1.6), 0.16 + 0.34 * car.skid)
	else:
		emit_acc = 0.0
	# ---- 更新烟
	var n := 0
	for i in SMOKE_N:
		var ag := s_age[i] + dt
		if ag >= s_life[i]:
			s_age[i] = 99.0
			continue
		s_age[i] = ag
		var u := ag / s_life[i]
		var v := s_vel[i] * exp(-1.6 * dt)
		v.y += 0.35 * dt
		s_vel[i] = v
		var p := s_pos[i] + v * dt
		s_pos[i] = p
		var sz := s_size[i] * (1.0 + 3.4 * sqrt(u))
		var a := s_a[i] * minf(1.0, u * 9.0) * (1.0 - u) * (1.0 - u)
		smoke.set_instance_transform(n, Transform3D(Basis.IDENTITY, p))
		smoke.set_instance_custom_data(n, Color(s_cell[i] + 0.01, a, s_rot[i] + u * 0.6, sz))
		n += 1
	alive = n
	smoke.visible_instance_count = n
	# ---- 胎痕
	var on := car.skid > 0.10 and car.grounded >= 2
	for w in 4:
		if not on or (w < 2 and car.skid < 0.45):
			last[w] = Vector3.INF
			continue
		var p2 := xf * Vector3(car._wl[w].x, 0.0, car._wl[w].z)
		var up := xf.basis.y
		p2 += up * 0.022
		if last[w] == Vector3.INF:
			last[w] = p2
			continue
		var d: Vector3 = p2 - last[w]
		var l := d.length()
		if l < 0.45:
			continue
		if l > 6.0:
			last[w] = p2
			continue
		var dirn := d / l
		var right := dirn.cross(up).normalized()
		var wd := 0.24 if w < 2 else 0.30
		var b := Basis(right * wd, up, dirn * -(l + 0.06))
		skid.set_instance_transform(k_head, Transform3D(b, (p2 + last[w]) * 0.5))
		skid.set_instance_color(k_head, Color(1, 1, 1, clampf(0.18 + 0.5 * car.skid, 0.0, 0.62)))
		k_head = (k_head + 1) % SKID_N
		last[w] = p2

func burst(pos: Vector3, strength: float) -> void:
	var c := clampi(int(strength * 1.5), 2, 10)
	for i in c:
		puff(pos + Vector3(rng.randf_range(-0.4, 0.4), 0.2, rng.randf_range(-0.4, 0.4)), Vector3(rng.randf_range(-1, 1), rng.randf_range(0.5, 1.5), rng.randf_range(-1, 1)), 0.5, 0.7, 0.35)
