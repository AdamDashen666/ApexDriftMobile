class_name Car
extends RigidBody3D
# 车辆：四点悬挂射线 + 自写的抓地/漂移/自由旋转控制（从 PC 版移植手感）
# 本地坐标：+X 前、+Y 上、+Z 右，原点在前后轴中点的地面

signal impact(strength: float, pos: Vector3, is_prop: bool)
signal spin_done()

const MASS := 1400.0
const K_SPRING := 46000.0
const C_DAMP := 4600.0
const RAY_TOP := 0.72
const RAY_DROOP := 0.20
const WHEELBASE := 2.8
const MAX_STEER := 0.60      # rad

# ---- 输入
var in_throttle := 0.0
var in_brake := 0.0
var in_steer := 0.0
var in_hand := false
var locked := true

# ---- 状态
var info: Dictionary = {}
var assist := 0              # 0 均衡 1 专业 2 拟真
var grounded := 0
var ground_up := Vector3.UP
var speed := 0.0             # m/s 水平
var kmh := 0.0
var beta := 0.0              # 速度方向相对车头（度，右正）
var slip_deg := 0.0          # 给计分和音效
var steer := 0.0
var steer_vis := 0.0
var drift_on := false
var drift_dir := 1.0
var drift_ang := 0.0
var drift_t := 0.0
var exit_t := 0.0
var power_t := 0.0
var path_rate := 0.0         # 度/秒，右正
var accel_f := 0.0
var sim_free := false
var sim_rate := 0.0
var sim_spin := 0.0
var sim_psi := 0.0
var sim_air := 0.0
var assist_t := 0.0
var reverse := false
var gear := 1
var rpm := 900.0
var shift_t := 0.0
var air_t := 0.0
var flip_t := 0.0
var wheel_comp := PackedFloat32Array([0, 0, 0, 0])
var wheel_hit: Array[Vector3] = [Vector3.ZERO, Vector3.ZERO, Vector3.ZERO, Vector3.ZERO]
var wheel_on := PackedByteArray([0, 0, 0, 0])
var wheel_rot := PackedFloat32Array([0, 0])
var wheel_spin_f := 0.0
var wheel_spin_r := 0.0
var skid := 0.0
var boost := 0.0

var track: Track
var wall_lat := 0.0          # 0 表示没有护墙
var free_roam := false
var bound_half := 0.0
var hint := -1
var wall_hit_cd := 0.0
var last_hit := 0.0

# ---- 自动漂移
var auto: AutoRun = null

# ---- 插值
var _prev := Transform3D.IDENTITY
var _cur := Transform3D.IDENTITY
var _teleport := false
var _pending_xf := Transform3D.IDENTITY
var _pending := false
var _pending_vel := Vector3.ZERO

# ---- 外观
var vis: Node3D
var body_mesh: MeshInstance3D
var wheels: Array[Node3D] = []
var wheel_pivots: Array[Node3D] = []
var mats: Dictionary = {}
var blob: MeshInstance3D
var head_l: SpotLight3D
var _rp := PhysicsRayQueryParameters3D.new()
var _wl: Array[Vector3] = [Vector3(1.45, 0, -0.8), Vector3(1.45, 0, 0.8), Vector3(-1.45, 0, -0.8), Vector3(-1.45, 0, 0.8)]

func _init() -> void:
	mass = MASS
	can_sleep = false
	continuous_cd = true
	linear_damp_mode = RigidBody3D.DAMP_MODE_REPLACE
	angular_damp_mode = RigidBody3D.DAMP_MODE_REPLACE
	linear_damp = 0.0
	angular_damp = 0.0
	center_of_mass_mode = RigidBody3D.CENTER_OF_MASS_MODE_CUSTOM
	center_of_mass = Vector3(0, 0.30, 0)
	inertia = Vector3(1000, 2600, 2500)
	collision_layer = 4
	collision_mask = 1 | 2
	contact_monitor = true
	max_contacts_reported = 6
	var pm := PhysicsMaterial.new()
	pm.friction = 0.05
	pm.bounce = 0.0
	physics_material_override = pm
	var cs := CollisionShape3D.new()
	var bx := BoxShape3D.new()
	bx.size = Vector3(4.1, 0.62, 1.78)
	cs.shape = bx
	cs.position = Vector3(0, 0.62, 0)
	add_child(cs)
	_rp.collision_mask = 1
	_rp.hit_from_inside = false

func _ready() -> void:
	vis = Node3D.new()
	vis.top_level = true
	add_child(vis)
	_cur = global_transform
	_prev = _cur

# ------------------------------------------------------------------ 外观
func set_car(i: int, paint: int) -> void:
	info = GameData.cars[i]
	for c in vis.get_children():
		c.queue_free()
	wheels.clear()
	wheel_pivots.clear()
	mats = Mats.car_mats(paint, info["id"])
	var scn: PackedScene = load("res://assets/cars/%s.glb" % info["id"])
	var root := scn.instantiate()
	var src := {}
	for m in root.find_children("*", "MeshInstance3D", true, false):
		src[String(m.name)] = m.mesh
	root.free()
	body_mesh = MeshInstance3D.new()
	body_mesh.mesh = src["Body"]
	_apply(body_mesh)
	vis.add_child(body_mesh)
	var ws: Array = info["wheels"]
	for w in 4:
		var pos := Vector3(ws[w][0], ws[w][1], ws[w][2])
		_wl[w] = Vector3(pos.x, 0.0, pos.z)
		var pivot := Node3D.new()
		pivot.position = pos
		vis.add_child(pivot)
		var mi := MeshInstance3D.new()
		mi.mesh = src["WheelF"] if w < 2 else src["WheelR"]
		_apply(mi)
		# 模型外侧朝 +Z（右轮）；左轮绕 Y 转 180
		var spin := Node3D.new()
		pivot.add_child(spin)
		if w % 2 == 0:
			mi.rotation.y = PI
		spin.add_child(mi)
		wheel_pivots.append(pivot)
		wheels.append(spin)
	if blob == null:
		blob = MeshInstance3D.new()
		var q := PlaneMesh.new()
		q.size = Vector2(5.6, 3.1)
		blob.mesh = q
		var m := ShaderMaterial.new()
		m.shader = Mats._shader("blob", "shader_type spatial;\nrender_mode unshaded, depth_draw_never, shadows_disabled, blend_mix;\nvoid fragment(){ vec2 q=(UV-0.5)*2.0; q.x*=0.92; float d=length(max(abs(q)-vec2(0.52,0.36),0.0)/vec2(0.48,0.62)); ALBEDO=vec3(0.0); ALPHA=0.62*(1.0-smoothstep(0.0,1.0,d)); }")
		blob.material_override = m
		blob.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		blob.top_level = true
		add_child(blob)
	if head_l == null:
		head_l = SpotLight3D.new()
		head_l.spot_range = 95.0
		head_l.spot_angle = 36.0
		head_l.spot_attenuation = 0.5
		head_l.light_energy = 24.0
		head_l.light_color = Color(1.0, 0.95, 0.86)
		head_l.shadow_enabled = false
		head_l.top_level = true
		head_l.visible = false
		add_child(head_l)

func _apply(mi: MeshInstance3D) -> void:
	for s in mi.mesh.get_surface_count():
		var nm := ""
		var m: Material = mi.mesh.surface_get_material(s)
		if m:
			nm = m.resource_name
		nm = nm.replace("X_", "")
		if nm.begins_with("Tex_"):
			nm = "Tex_" + nm.substr(4).to_lower()
		if mats.has(nm):
			mi.set_surface_override_material(s, mats[nm])
		else:
			mi.set_surface_override_material(s, mats["Dark"])

func set_paint(paint: int) -> void:
	var nm := Mats.car_mats(paint, info["id"])
	for key in nm:
		if mats.has(key):
			var a: StandardMaterial3D = mats[key]
			var b: StandardMaterial3D = nm[key]
			a.albedo_color = b.albedo_color
			a.metallic = b.metallic
			a.roughness = b.roughness

# ------------------------------------------------------------------ 位置
func teleport(pos: Vector3, yaw: float, vel := Vector3.ZERO) -> void:
	var b := Basis(Vector3.UP, -yaw)     # 航向角：0 朝 +X，右转为正
	_pending_xf = Transform3D(b, pos)
	_pending_vel = vel
	_pending = true
	if not is_inside_tree():
		return
	global_transform = _pending_xf
	linear_velocity = vel
	angular_velocity = Vector3.ZERO
	_prev = _pending_xf
	_cur = _pending_xf
	hint = -1
	reset_state()

func reset_state() -> void:
	drift_on = false
	sim_free = false
	sim_rate = 0.0
	sim_spin = 0.0
	path_rate = 0.0
	steer = 0.0
	accel_f = 0.0
	assist_t = 0.0
	air_t = 0.0
	flip_t = 0.0
	reverse = false
	gear = 1

func heading() -> float:
	var f := global_transform.basis.x
	return atan2(f.z, f.x)

func start_auto(a: AutoRun) -> void:
	auto = a
	freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC
	freeze = true
	reset_state()

func stop_auto(keep_speed := true) -> void:
	if auto == null:
		return
	var v := auto.vel
	var xf := auto.xf
	auto = null
	freeze = false
	global_transform = xf
	linear_velocity = v if keep_speed else Vector3.ZERO
	angular_velocity = Vector3.ZERO
	reset_state()
	in_throttle = 0.0
	in_brake = 0.0
	in_steer = 0.0
	in_hand = false
	assist_t = 0.5

# ------------------------------------------------------------------ 物理
static func accel_at(v_kmh: float, a: float, top: float) -> float:
	var kmh2 := v_kmh * 368.0 / maxf(top, 120.0)
	var V := [0.0, 60.0, 110.0, 160.0, 210.0, 260.0, 310.0, 345.0, 368.0]
	var A := [12.0, 12.0, 10.4, 8.6, 6.8, 5.0, 3.2, 1.5, 0.0]
	for i in range(1, 9):
		if kmh2 < V[i]:
			return a * lerpf(A[i - 1], A[i], (kmh2 - V[i - 1]) / (V[i] - V[i - 1]))
	return -0.8

func _physics_process(dt: float) -> void:
	_prev = _cur
	if auto != null:
		auto.step(dt, self)
		global_transform = auto.xf
		_cur = auto.xf
		speed = auto.vel.length()
		kmh = speed * 3.6
		beta = -auto.psi
		slip_deg = absf(wrapf(auto.psi, -180.0, 180.0))
		grounded = 4
		ground_up = auto.xf.basis.y
		steer_vis = clampf(-deg_to_rad(wrapf(auto.psi, -180.0, 180.0)) * 0.8, -0.55, 0.55) if slip_deg < 95.0 else 0.0
		skid = clampf((slip_deg - 8.0) / 30.0, 0.0, 1.0) * clampf(speed / 12.0, 0.0, 1.0)
		in_throttle = auto.throttle
		in_brake = auto.brake
		_wheels_auto(dt)
		_engine(dt)
		return
	_cur = global_transform

func _integrate_forces(st: PhysicsDirectBodyState3D) -> void:
	if auto != null:
		return
	if _pending:
		_pending = false
		st.transform = _pending_xf
		st.linear_velocity = _pending_vel
		st.angular_velocity = Vector3.ZERO
	var dt := minf(st.step, 0.02)
	var xf := st.transform
	var v := st.linear_velocity
	var w := st.angular_velocity
	var up := xf.basis.y
	var space := st.get_space_state()
	# ---- 悬挂
	grounded = 0
	var nsum := Vector3.ZERO
	var fbase := MASS * 9.8 * 0.25
	for i in 4:
		var top := xf * (_wl[i] + Vector3(0, RAY_TOP, 0))
		_rp.from = top
		_rp.to = top - up * (RAY_TOP + RAY_DROOP)
		var h := space.intersect_ray(_rp)
		if h.is_empty():
			wheel_on[i] = 0
			wheel_comp[i] = move_toward(wheel_comp[i], -0.10, dt * 1.2)
			wheel_hit[i] = _rp.to
			continue
		var d: float = top.distance_to(h.position)
		var comp := RAY_TOP - d
		var n: Vector3 = h.normal
		if n.dot(up) < 0.25:
			wheel_on[i] = 0
			continue
		wheel_comp[i] = comp
		wheel_hit[i] = h.position
		var rel: Vector3 = h.position - xf.origin
		var pv := v + w.cross(rel - xf.basis * center_of_mass)
		var cv := pv.dot(n)
		var f := fbase + K_SPRING * comp - C_DAMP * cv
		if comp > 0.15:
			# 触底：压缩时硬、回弹时放掉大半，免得坡口把车弹飞
			f += (comp - 0.15) * (150000.0 if cv < 0.0 else 25000.0)
		f = clampf(f, 0.0, MASS * 26.0)
		if f > 0.0:
			wheel_on[i] = 1
			grounded += 1
			nsum += n
			st.apply_force(n * f, rel)
		else:
			wheel_on[i] = 0
	ground_up = nsum.normalized() if grounded > 0 else up
	# ---- 操控
	v = st.linear_velocity
	w = st.angular_velocity
	var gup := ground_up
	var fwd := xf.basis.x
	fwd = (fwd - gup * fwd.dot(gup)).normalized()
	var right := fwd.cross(gup)
	right = -right if right.dot(xf.basis.z) < 0.0 else right
	var vn := gup * v.dot(gup)
	var vt := v - vn
	speed = vt.length()
	kmh = speed * 3.6
	var vf := vt.dot(fwd)
	var vr := vt.dot(right)
	var forward := vf > 0.0
	beta = rad_to_deg(atan2(vr, vf)) if speed > 2.0 else 0.0
	slip_deg = absf(beta) if (forward or sim_free) else 0.0
	assist_t = maxf(0.0, assist_t - dt)
	wall_hit_cd = maxf(0.0, wall_hit_cd - dt)
	var yaw := -w.dot(gup)       # 右转为正，rad/s

	if locked:
		in_throttle = 0.0
		in_brake = 1.0
		in_steer = 0.0
		in_hand = false
	# 方向平滑
	var returning := absf(in_steer) < absf(steer) or in_steer * steer < 0.0
	var hs := clampf(kmh / 260.0, 0.0, 1.0)
	steer = move_toward(steer, in_steer, dt * float(info.get("agility", 1.0)) * (8.0 if returning else lerpf(5.5, 2.6, hs)))

	if grounded >= 2:
		air_t = 0.0
		_drive(st, dt, v, vn, vt, w, gup, fwd, right, vf, vr, forward, yaw)
	else:
		air_t += dt
		skid = 0.0
		if sim_free:
			sim_air += dt
			if sim_air > 0.35:
				sim_free = false
		# 空中：角速度收敛，机头慢慢跟上速度方向，落地不容易翻
		w *= exp(-3.6 * dt)
		var err := up.cross(Vector3.UP)
		w += err * minf(5.0 * dt, 1.0)
		st.angular_velocity = w
		path_rate = lerpf(path_rate, 0.0, 1.0 - exp(-4.0 * dt))
	_walls(st)
	_contacts(st)
	# 翻车计时
	if xf.basis.y.y < 0.25 and st.linear_velocity.length() < 4.0:
		flip_t += dt
	else:
		flip_t = 0.0
	wheel_spin_f = vf
	wheel_spin_r = lerpf(wheel_spin_r, (0.0 if in_hand and grounded > 0 else vf + (6.0 * in_throttle if (drift_on or sim_free) else 0.0)), 1.0 - exp(-14.0 * dt))
	_engine(dt)

func _drive(st: PhysicsDirectBodyState3D, dt: float, _v: Vector3, vn: Vector3, vt: Vector3, w: Vector3, gup: Vector3, fwd: Vector3, right: Vector3, vf: float, _vr: float, forward: bool, yaw: float) -> void:
	var grip: float = info.get("grip", 1.0)
	var cdrift: float = info.get("drift", 1.0)
	var cacc: float = info.get("accel", 1.0)
	var ctop: float = info.get("top", 360.0)
	var th := in_throttle
	var br := in_brake
	# 重力沿坡面的分量：横向一律抵消，纵向保留
	var gt := Vector3(0, -9.8, 0)
	gt -= gup * gt.dot(gup)
	var sliding := drift_on or sim_free
	if not sliding:
		vt -= right * gt.dot(right) * dt
	# ---- 低速与倒车
	var low := speed < 3.2 and not sliding
	if low or reverse:
		drift_on = false
		sim_free = false
		var a := 0.0
		if reverse:
			if th > 0.05 and vf > -0.6:
				reverse = false
			a = -7.0 * br * clampf(1.0 + vf / 13.0, 0.0, 1.0) + 14.0 * th
			if br < 0.05 and th < 0.05:
				a += clampf(-vf * 2.0, -4.0, 4.0)
		else:
			a = accel_at(kmh, cacc, ctop) * th
			if br > 0.05:
				if vf > 0.4:
					a -= 14.0 * br
				elif not locked:
					reverse = true
				else:
					a -= clampf(vf * 10.0, -14.0, 14.0)
			elif th < 0.05:
				a -= clampf(vf * 1.5, -3.0, 3.0)
		var nv := vf + a * dt
		if th < 0.02 and br < 0.02 and absf(nv) < 0.35:
			nv = 0.0
			vt = Vector3.ZERO
		if locked and absf(nv) < 0.4:
			nv = 0.0
		if not locked and not (th < 0.02 and br < 0.02):
			nv += gt.dot(fwd) * 0.0
		var lat := (vt - fwd * vf) * exp(-10.0 * dt)
		vt = fwd * nv + lat
		var sd := steer * MAX_STEER
		var want := nv * tan(sd) / WHEELBASE
		var ny := lerpf(yaw, want, 1.0 - exp(-14.0 * dt))
		st.angular_velocity = w - gup * (ny - yaw)
		st.linear_velocity = vt + vn
		path_rate = rad_to_deg(ny)
		steer_vis = sd
		skid = clampf(th * 1.5 - 0.6, 0.0, 1.0) * 0.5 if (vf < 3.0 and th > 0.8 and not locked) else 0.0
		return
	var dirv := vt / maxf(speed, 0.01)
	var side := dirv.cross(gup)
	var sim := assist == 2
	var pro := assist == 1
	var b := beta if forward else 0.0
	var ab := absf(b)

	if sim:
		if _sim_slide(st, dt, vn, vt, w, gup, dirv, side, yaw, forward):
			return
	else:
		sim_free = false
	# ---- 进入漂移
	if forward and kmh > 28.0 and not sim:
		var hand_entry := in_hand and absf(in_steer) > 0.18
		if not drift_on:
			var enter := hand_entry
			if not enter and pro:
				var pw := th > 0.85 and absf(in_steer) > 0.8 and kmh > 36.0 and kmh < 105.0 and assist_t <= 0.0
				power_t = power_t + dt if pw else 0.0
				enter = power_t > 0.65
			if enter:
				drift_on = true
				drift_dir = signf(in_steer)
				drift_t = 0.0
				drift_ang = clampf(-b * drift_dir, 8.0, 30.0)
				exit_t = 0.0
				power_t = 0.0
		elif hand_entry and in_steer * drift_dir < -0.3:
			drift_dir = -drift_dir
			drift_t = 0.0
			drift_ang = 12.0
			exit_t = 0.0
	if drift_on:
		drift_t += dt
		var si := in_steer * drift_dir
		var mx := minf((54.0 if pro else 44.0) * cdrift, 57.0)
		var goal := 0.0
		var fall := (42.0 if pro else 50.0) + 1.3 * drift_ang
		if si > 0.12:
			goal = lerpf(24.0 * cdrift, mx, pow(si, 0.8))
		elif si < -0.12:
			fall = 150.0 if pro else 175.0
		if in_hand and si > -0.12:
			goal = maxf(goal, 32.0) + 6.0
		goal *= lerpf(0.30, 1.0, clampf(th * 1.6, 0.0, 1.0))
		goal *= 1.0 - 0.9 * clampf(br * 1.5, 0.0, 1.0)
		goal *= lerpf(1.0, 0.72, clampf((kmh - 130.0) / 110.0, 0.0, 1.0))
		if th < 0.2 or br > 0.3:
			fall = maxf(fall, 95.0)
		goal = clampf(goal, 0.0, mx)
		drift_ang = move_toward(drift_ang, goal, dt * (115.0 if goal > drift_ang else fall))
		var out := goal < 1.0 and drift_ang < 6.0 and not in_hand
		exit_t = exit_t + dt if out else 0.0
		if (out and ab < 11.0) or exit_t > 0.35 or kmh < 18.0 or not forward:
			drift_on = false
			assist_t = maxf(assist_t, 0.35)
	var lat_max := grip * ((14.5 if sim else 16.5) + 5.0 * clampf(pow(speed / 70.0, 2.0), 0.0, 1.3)) * (1.0 - 0.15 * br)
	# 被撞得横过来或调头：车头拧回行进方向
	if not forward and kmh > 25.0 and not in_hand:
		var e := rad_to_deg(atan2(vt.dot(right), vt.dot(fwd)))
		var wantr := deg_to_rad(clampf(e * 3.4, -200.0, 200.0))
		st.angular_velocity = w - gup * ((wantr - yaw) * (1.0 - exp(-9.0 * dt)))
		st.linear_velocity = vt * (1.0 - 0.4 * dt) + vn
		skid = 1.0
		return
	var nspeed := speed
	var tgt_rate := 0.0
	var yaw_want := 0.0
	var stiff := 14.0
	if drift_on:
		var si2 := in_steer * drift_dir
		var bt := -drift_dir * drift_ang
		var closing := ab > drift_ang + 2.0
		var kk := 4.0 if in_hand else (4.8 if closing else 3.2)
		var gain := clampf(ab / 30.0, 0.0, 1.1)
		var lat_a := -signf(b) * 15.6 * lerpf(1.0, grip, 0.6) * gain * (0.84 + 0.30 * maxf(si2, -0.6)) * lerpf(0.72, 1.0, th) * clampf(kmh / 55.0, 0.4, 1.0)
		tgt_rate = rad_to_deg(lat_a / maxf(speed, 6.0))
		path_rate = lerpf(path_rate, tgt_rate, 1.0 - exp(-9.0 * dt))
		yaw_want = clampf(path_rate + kk * (b - bt), -145.0, 145.0)
		stiff = 11.0
		var pa := lerpf(7.0 * cacc, -3.2, clampf((kmh - 60.0) / 130.0, 0.0, 1.0))
		var ta := lerpf(-3.5, pa, th) - br * 9.0 - (2.6 if in_hand else 0.0)
		accel_f = lerpf(accel_f, clampf(ta, -14.0, 13.0), 1.0 - exp(-8.0 * dt))
		nspeed = maxf(0.0, speed + accel_f * dt)
		steer_vis = clampf(deg_to_rad(b) + in_steer * 0.12, -MAX_STEER, MAX_STEER)
		skid = clampf((ab - 6.0) / 22.0, 0.0, 1.0)
	else:
		var mxy := minf(84.0, rad_to_deg(lat_max / maxf(speed, 6.0)))
		# 低速按几何转角
		var geo := rad_to_deg(speed * tan(absf(steer) * MAX_STEER) / WHEELBASE)
		tgt_rate = signf(steer) * minf(absf(steer) * mxy, geo)
		path_rate = lerpf(path_rate, tgt_rate, 1.0 - exp(-(9.0 if assist_t <= 0.0 else 12.0) * dt))
		yaw_want = clampf(path_rate + (6.5 + 3.0 * float(assist_t > 0.0)) * b, -160.0, 160.0)
		stiff = lerpf(16.0, 40.0, clampf((speed - 35.0) / 50.0, 0.0, 1.0))
		var ta2 := 0.0
		if br > 0.05 and vf > 1.0:
			ta2 = -17.0 * br
		elif in_hand:
			ta2 = -7.5
		elif th > 0.05:
			ta2 = accel_at(kmh, cacc, ctop) * th * (1.0 - 0.22 * absf(steer))
			if kmh > ctop:
				ta2 = -2.0
		else:
			ta2 = -1.2 - 0.0009 * speed * speed
		accel_f = lerpf(accel_f, ta2, 1.0 - exp(-14.0 * dt))
		nspeed = maxf(0.0, speed + (accel_f + gt.dot(dirv) * 0.35) * dt)
		var lim := rad_to_deg(atan(WHEELBASE * lat_max / maxf(speed * speed, 1.0))) + 5.5
		steer_vis = steer * deg_to_rad(clampf(lim, 6.0, 34.0))
		skid = clampf((ab - 5.0) / 14.0, 0.0, 1.0)
		if br > 0.8 and kmh > 60.0:
			skid = maxf(skid, 0.25)
		if in_hand and kmh > 20.0:
			skid = maxf(skid, 0.6)
	# 速度方向按 path_rate 转，行进方向右转为正
	var nd := dirv.rotated(gup, -deg_to_rad(path_rate) * dt)
	st.linear_velocity = nd * nspeed + vn
	var ny2 := lerpf(yaw, deg_to_rad(yaw_want), 1.0 - exp(-stiff * dt))
	st.angular_velocity = w - gup * (ny2 - yaw)
	# 下压
	st.apply_central_force(-gup * minf(0.0009 * speed * speed, 6.0) * MASS)

# 拟真档：手刹甩起来后按惯性转，不拉回；松手才自然回正
func _sim_slide(st: PhysicsDirectBodyState3D, dt: float, vn: Vector3, vt: Vector3, w: Vector3, gup: Vector3, dirv: Vector3, _side: Vector3, yaw: float, forward: bool) -> bool:
	var cdrift: float = info.get("drift", 1.0)
	var grip: float = info.get("grip", 1.0)
	var cacc: float = info.get("accel", 1.0)
	var psi := -beta if speed > 2.0 else 0.0     # 车头相对行进方向，右正
	var yd := rad_to_deg(yaw)
	if not sim_free:
		if not (forward and kmh > 30.0 and in_hand and absf(in_steer) > 0.18):
			sim_psi = psi
			return false
		sim_free = true
		sim_rate = clampf(yd - path_rate, -60.0, 60.0)
		sim_spin = 0.0
		sim_psi = psi
		sim_air = 0.0
	sim_air = 0.0
	var pp := sim_psi
	sim_spin += wrapf(psi - pp, -180.0, 180.0)
	sim_psi = psi
	var ap := absf(psi)
	var caught := not in_hand and ap < 60.0 and (pp * psi < 0.0 or (ap < 5.0 and absf(sim_rate) < 30.0))
	if absf(sim_spin) > 325.0 and ap < 45.0:
		sim_spin -= signf(sim_spin) * 360.0
		spin_done.emit()
	if caught or kmh < 12.0:
		sim_free = false
		sim_rate = 0.0
		if caught:
			assist_t = maxf(assist_t, 0.30)
		return false
	var sp := clampf(speed / 13.0, 0.25, 1.0)
	var kk := 515.0 * sp
	var into := steer * psi >= 0.0
	var tq := 0.0
	if in_hand:
		tq = steer * kk * 1.62 * cdrift
	elif into:
		tq = steer * kk * lerpf(0.30, 0.76, in_throttle) * cdrift
	else:
		tq = steer * kk * 0.85
	var al := -kk * sin(deg_to_rad(psi))
	var dm := 1.5 if in_hand else lerpf(3.6, 0.9, clampf((ap - 55.0) / 25.0, 0.0, 1.0))
	sim_rate += (tq + al - dm * sim_rate) * dt
	sim_rate = clampf(sim_rate, -345.0, 345.0)
	if not in_hand and sim_rate * psi < 0.0:
		var cap := 5.2 * ap + 22.0
		sim_rate = clampf(sim_rate, -cap, cap)
	var sinp := sin(deg_to_rad(psi))
	var cosp := cos(deg_to_rad(psi))
	var lat := sinp * lerpf(5.0, 14.0, in_throttle) * lerpf(1.0, grip, 0.6) * clampf(speed / 14.0, 0.3, 1.0)
	path_rate = lerpf(path_rate, rad_to_deg(lat / maxf(speed, 5.0)), 1.0 - exp(-7.0 * dt))
	var tn := in_throttle * cacc * lerpf(8.0, 1.0, clampf((speed - 15.0) / 38.0, 0.0, 1.0)) * maxf(cosp, -0.35) - 1.6 * absf(sinp) - 0.4 - (1.6 if in_hand else 0.0) - in_brake * 9.0 - (1.0 - in_throttle) * 1.5
	accel_f = lerpf(accel_f, clampf(tn, -12.0, 15.0), 1.0 - exp(-8.0 * dt))
	var nd := dirv.rotated(gup, -deg_to_rad(path_rate) * dt)
	st.linear_velocity = nd * maxf(0.0, vt.length() + accel_f * dt) + vn
	var want := deg_to_rad(path_rate + sim_rate)
	st.angular_velocity = w - gup * ((want - yaw) * (1.0 - exp(-30.0 * dt)))
	steer_vis = clampf(deg_to_rad(-psi) + steer * 0.16, -MAX_STEER, MAX_STEER) if ap < 95.0 else steer * 0.4
	skid = clampf((ap - 6.0) / 22.0, 0.0, 1.0)
	st.apply_central_force(-gup * minf(0.0009 * speed * speed, 5.0) * MASS)
	return true

func _walls(st: PhysicsDirectBodyState3D) -> void:
	var xf := st.transform
	if free_roam:
		# 训练场四周
		var lim := bound_half
		if lim <= 0.0:
			return
		var n := Vector3.ZERO
		if absf(xf.origin.x) > lim:
			n.x = -signf(xf.origin.x)
			xf.origin.x = signf(xf.origin.x) * lim
		if absf(xf.origin.z) > lim:
			n.z = -signf(xf.origin.z)
			xf.origin.z = signf(xf.origin.z) * lim
		if n != Vector3.ZERO:
			st.transform = xf
			_wall_response(st, n.normalized(), xf.origin)
		return
	if track == null or wall_lat <= 0.0:
		return
	track.query(xf.origin, hint)
	hint = track.q_i
	# 车身四角离中心线的最大横偏：按车头夹角估
	var f := xf.basis.x
	var rel := Vector2(f.x, f.z)
	var r := Vector2(-track.q_dir.y, track.q_dir.x)
	var ext := absf(rel.dot(r)) * 2.05 + absf(rel.dot(track.q_dir)) * 0.92
	var lim2 := wall_lat - ext
	if absf(track.q_lat) > lim2:
		var sg := signf(track.q_lat)
		var over := absf(track.q_lat) - lim2
		var n2 := Vector3(-r.x * sg, 0, -r.y * sg)
		xf.origin += n2 * over
		st.transform = xf
		_wall_response(st, n2, xf.origin - n2 * ext)

func _wall_response(st: PhysicsDirectBodyState3D, n: Vector3, pos: Vector3) -> void:
	var v := st.linear_velocity
	var vn := v.dot(n)
	if vn >= 0.0:
		return
	v -= n * vn * 1.08
	var hit := -vn
	# 擦墙掉一点速
	v *= 1.0 - clampf(hit * 0.010, 0.0, 0.35)
	st.linear_velocity = v
	if hit > 1.2:
		assist_t = 0.45
		if hit > 5.0:
			drift_on = false
			sim_free = false
		if wall_hit_cd <= 0.0:
			wall_hit_cd = 0.12
			impact.emit(hit, pos, false)
	# 车头顺着墙拧
	var f := st.transform.basis.x
	var t := (f - n * f.dot(n))
	if t.length() > 0.2 and absf(f.dot(n)) > 0.05 and f.dot(n) < 0.0:
		var e := f.cross(t.normalized())
		st.angular_velocity += Vector3(0, e.y, 0) * clampf(hit * 0.35, 0.0, 1.6)

func _contacts(st: PhysicsDirectBodyState3D) -> void:
	var now := Time.get_ticks_msec() * 0.001
	for i in st.get_contact_count():
		var o := st.get_contact_collider_object(i)
		var imp := st.get_contact_impulse(i).length() / MASS
		if o is RigidBody3D:
			if imp > 0.12 and now - last_hit > 0.06:
				last_hit = now
				impact.emit(imp, st.get_contact_collider_position(i), true)
		elif o is StaticBody3D:
			var n := st.get_contact_local_normal(i)
			if absf(n.y) < 0.6 and imp > 0.8:
				assist_t = 0.4
				if imp > 4.0:
					drift_on = false
					sim_free = false
				if wall_hit_cd <= 0.0:
					wall_hit_cd = 0.15
					impact.emit(imp, st.get_contact_collider_position(i), false)

# ------------------------------------------------------------------ 发动机（声音和转速表用）
func _engine(dt: float) -> void:
	var top: float = info.get("top", 360.0)
	var ratios := [0.0, 0.20, 0.34, 0.50, 0.68, 0.85, 1.04]
	shift_t = maxf(0.0, shift_t - dt)
	var r := kmh / top
	if reverse:
		gear = -1
		rpm = lerpf(rpm, 1200.0 + kmh * 110.0, 1.0 - exp(-8.0 * dt))
		return
	if gear < 1:
		gear = 1
	var lo: float = ratios[gear - 1] * 0.82
	var hi: float = ratios[gear]
	if shift_t <= 0.0:
		if r > hi * 0.97 and gear < 6 and (grounded > 0):
			gear += 1
			shift_t = 0.28
		elif r < lo and gear > 1:
			gear -= 1
			shift_t = 0.22
	var t := clampf(r / float(ratios[gear]), 0.0, 1.05)
	var want := lerpf(1500.0, 7800.0, t)
	if gear == 1 and kmh < 20.0:
		want = maxf(want, 1000.0 + in_throttle * 3800.0)
	if drift_on or sim_free:
		want = maxf(want, 5200.0 + 2200.0 * in_throttle)
	if grounded == 0 and in_throttle > 0.3:
		want = 7600.0
	want = maxf(900.0, want - (900.0 if shift_t > 0.15 else 0.0))
	rpm = lerpf(rpm, want, 1.0 - exp(-11.0 * dt))
	boost = lerpf(boost, in_throttle * clampf((rpm - 2400.0) / 5000.0, 0.0, 1.0), 1.0 - exp(-4.0 * dt))

func _wheels_auto(dt: float) -> void:
	var f := auto.xf.basis.x
	var vf := auto.vel.dot(f)
	wheel_spin_f = vf
	wheel_spin_r = lerpf(wheel_spin_r, vf + 8.0 * auto.throttle * skid, 1.0 - exp(-12.0 * dt))
	for i in 4:
		wheel_comp[i] = 0.0
		wheel_on[i] = 1
		wheel_hit[i] = auto.xf * _wl[i]

# ------------------------------------------------------------------ 画面
func visual_xf() -> Transform3D:
	return _prev.interpolate_with(_cur, Engine.get_physics_interpolation_fraction())

func visual_vel() -> Vector3:
	return auto.vel if auto != null else linear_velocity

func _process(dt: float) -> void:
	var xf := visual_xf()
	vis.global_transform = xf
	if wheel_pivots.size() < 4:
		return
	var rf: float = info["rf"]
	var rr: float = info["rr"]
	wheel_rot[0] = fmod(wheel_rot[0] + wheel_spin_f / rf * dt, TAU)
	wheel_rot[1] = fmod(wheel_rot[1] + wheel_spin_r / rr * dt, TAU)
	for i in 4:
		var pv := wheel_pivots[i]
		var base: float = info["wheels"][i][1]
		pv.position.y = lerpf(pv.position.y, base + clampf(wheel_comp[i], -0.09, 0.10), 1.0 - exp(-30.0 * dt))
		if i < 2:
			pv.rotation.y = lerp_angle(pv.rotation.y, -steer_vis, 1.0 - exp(-22.0 * dt))
		wheels[i].rotation.z = -wheel_rot[0 if i < 2 else 1]
	# 车身侧倾、俯仰（纯视觉）
	var roll := clampf(deg_to_rad(path_rate) * speed * 0.0022, -0.045, 0.045)
	var pit := clampf(-accel_f * 0.0016, -0.02, 0.022)
	body_mesh.rotation = body_mesh.rotation.lerp(Vector3(-roll, 0, -pit), 1.0 - exp(-7.0 * dt))
	# 贴地阴影片
	var g := xf.origin
	if grounded > 0:
		blob.visible = true
		var bb := Basis(xf.basis.x, ground_up, xf.basis.x.cross(ground_up)).orthonormalized()
		blob.global_transform = Transform3D(bb, g + ground_up * 0.03)
	else:
		blob.visible = false
	if head_l and head_l.visible:
		head_l.global_transform = Transform3D(xf.basis * Basis(Vector3.UP, -PI * 0.5), xf * Vector3(-0.8, 5.6, 0)) * Transform3D(Basis(Vector3.RIGHT, -0.25), Vector3.ZERO)
	if mats.has("Tail"):
		var e := 2.6 if in_brake > 0.1 and not locked else 0.55
		mats["Tail"].emission_energy_multiplier = lerpf(mats["Tail"].emission_energy_multiplier, e, 1.0 - exp(-20.0 * dt))
