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

# ---- 拟真档的轮胎模型：与 Windows 版（ApexDriftVehiclePawn.cpp 的 namespace ApexSim / UpdateSimPhysics）同一套参数。
# 车身坐标 x 向前、y 向右（= 本地 +Z），米；横摆角速度向右转为正。所有车共用同一个物理底盘（轮位、齿比）
const SIM_G := 9.81
const SIM_PX := [1.4975, 1.4975, -1.4175, -1.4175]   # 轮位相对质心（质心在前后轴中点后 4cm）
const SIM_PY := [-0.8177, 0.8177, -0.9066, 0.9066]
const SIM_A := 1.4975        # 质心到前轴
const SIM_B := 1.4175        # 质心到后轴
const SIM_L := 2.915
const SIM_TRACK_F := 1.6354
const SIM_TRACK_R := 1.8132
const SIM_COMH := 0.34       # 算载荷转移用的质心高度
const SIM_ROLL_F := 0.64     # 横向载荷转移由前轴扛的比例：到极限先推头
const SIM_MU_LAT_F := 1.32
const SIM_MU_LAT_R := 1.50
const SIM_MU_LONG_F := 1.40
const SIM_MU_LONG_R := 1.55
const SIM_PEAK_AF := 0.150   # tan(前轮峰值侧偏角约 8.5°)
const SIM_PEAK_AR := 0.105   # tan(后轮峰值侧偏角约 6°)：后轮比前轮“硬”
const SIM_PEAK_K := 0.11     # 峰值滑移率
const SIM_SLIDE_LAT_F := 0.80
const SIM_SLIDE_LAT_R := 0.72
const SIM_SLIDE_LONG := 0.86
const SIM_DECAY := 1.4
const SIM_LOAD_SENS := 0.16
const SIM_YAW_K := 1.50      # 横摆转动惯量 Iz = 质量 × 1.5 m2
const SIM_REAR_INERTIA := 45.0
const SIM_BRAKE_ACCEL := 13.0
const SIM_BRAKE_FRONT := 0.78
const SIM_REAR_BRAKE_CAP := 0.60
const SIM_REAR_RADIUS := 0.347
const SIM_TO_RPM := 60.0 / (TAU * SIM_REAR_RADIUS)   # 胎面速度 m/s × 总传动比 → 发动机转速
const SIM_DRAG := 0.95       # 风阻和车身阻力 N/(m/s)²（Windows 版 Chaos 实测值；驱动力里等量补回）
# 牵引力控制与关掉时的空转上限（v2.8）
const SIM_TCS_SLIP := 0.3    # 后轮已横着滑时仍只许 0.3 倍峰值滑移率的空转
const SIM_TCS_HAND := 0.1    # 松手刹 0.1 秒后恢复
const SIM_SPIN_BASE := 1.2
const SIM_SPIN_GAIN := 0.7
const SIM_SPIN_GAIN_HAND := 2.0
# 变速箱（Windows 版 Chaos 的设置）：自动挡按后轮实际转速换挡，换挡空挡 0.1 秒
const SIM_GEARS := [3.60, 2.40, 1.75, 1.36, 1.08, 0.86]
const SIM_FINAL := 3.10
const SIM_REV_RATIO := 3.40
const SIM_REDLINE := 7800.0
const SIM_UP_RPM := 6600.0
const SIM_DOWN_RPM := 3900.0
const SIM_SHIFT_TIME := 0.10

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

# ---- 拟真档（轮胎物理）
var tcs := true              # 牵引力控制（设置里开关，默认开）；只在拟真档起作用
var sim_on := false          # 这一帧由轮胎模型驱动
var sim_free := false        # 车身横着滑（只统计：给计分、小地图，不干预）
var sim_spin := 0.0
var sim_psi := 0.0
var sim_calm := 0.0
var sim_ws := 0.0            # 后轮胎面速度 m/s（两轮共用，限滑差速）
var sim_thr := 0.0
var sim_prev_ok := false
var sim_prev_vx := 0.0
var sim_prev_vy := 0.0
var sim_ax := 0.0            # 车身坐标加速度（低通），算载荷转移
var sim_ay := 0.0
var sim_gear := 1            # 当前挡：-1 倒挡、0 换挡中、1..6
var sim_target := 1
var sim_shift_cut := 0.0
var sim_shift_t := 0.0
var sim_hand_t := 9.0        # 松开手刹多久
var sim_hand_slide := false  # 拉手刹起的横滑（空转上限放宽）
var sim_rear_lat := 0.0      # 后轮侧向附着占用
var sim_rpm := 900.0
var sim_steer_lim := 38.0
var sim_tcs_cap := -1.0      # 调试：这一帧牵引力控制给的驱动力上限（N），-1 = 没限
var sim_skid := PackedFloat32Array([0, 0, 0, 0])
var _fz := PackedFloat32Array([0, 0, 0, 0])
var _vlr := PackedFloat32Array([0, 0])
var _vtr := PackedFloat32Array([0, 0])
var _cxr := PackedFloat32Array([0, 0])
var _cyr := PackedFloat32Array([0, 0])
var _rfl := PackedFloat32Array([0, 0])
var _rft := PackedFloat32Array([0, 0])
var _rs := PackedFloat32Array([0, 0])
var _d_ratio := 0.0
var _d_gear := 1
var _d_thr := 0.0
var _d_wsmax := 0.0
var _d_vx := 0.0
var _d_acc := 1.0
var _d_top := 360.0

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

# 复位 / 传送 / 交还控制：清掉动态状态。设置（assist、tcs、车）不在这里动——
# Windows 版 v2.6 修过“复位后设置被换回默认”，这里设置只由外面改；拟真档下一帧按当前车速重新起步（_sim_begin）
func reset_state() -> void:
	drift_on = false
	sim_on = false
	sim_free = false
	sim_spin = 0.0
	sim_calm = 0.0
	sim_ws = 0.0
	sim_thr = 0.0
	sim_prev_ok = false
	sim_ax = 0.0
	sim_ay = 0.0
	sim_gear = 1
	sim_target = 1
	sim_shift_cut = 0.0
	sim_shift_t = 0.0
	sim_hand_t = 9.0
	sim_hand_slide = false
	sim_rear_lat = 0.0
	for i in 4:
		sim_skid[i] = 0.0
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

	# 拟真档：整套交给轮胎模型（倒计时 / 菜单锁车时仍走下面的低速保持）
	var sim_now := assist == 2 and not locked
	if sim_now != sim_on:
		if sim_now:
			_sim_begin(vf)
		else:
			_sim_end()
	if grounded >= 2:
		air_t = 0.0
		if not sim_on:
			_drive(st, dt, v, vn, vt, w, gup, fwd, right, vf, vr, forward, yaw)
	else:
		air_t += dt
		skid = 0.0
		# 空中：角速度收敛（Windows 版空中角阻尼 2.6），机身慢慢摆平，落地不容易翻
		w *= exp(-3.6 * dt)
		var err := up.cross(Vector3.UP)
		w += err * minf(5.0 * dt, 1.0)
		st.angular_velocity = w
		path_rate = lerpf(path_rate, 0.0, 1.0 - exp(-4.0 * dt))
	if sim_on:
		_sim(st, dt, gup, fwd, right, vt, vf, vr)
	_walls(st)
	_contacts(st)
	# 翻车计时
	if xf.basis.y.y < 0.25 and st.linear_velocity.length() < 4.0:
		flip_t += dt
	else:
		flip_t = 0.0
	wheel_spin_f = vf
	if sim_on:
		wheel_spin_r = sim_ws
	else:
		wheel_spin_r = lerpf(wheel_spin_r, (0.0 if in_hand and grounded > 0 else vf + (6.0 * in_throttle if drift_on else 0.0)), 1.0 - exp(-14.0 * dt))
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
	var sim := assist == 2      # 拟真档平时走 _sim()；到这里只会是锁车时
	var pro := assist == 1
	var b := beta if forward else 0.0
	var ab := absf(b)
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

# ------------------------------------------------------------------ 拟真档：轮胎物理
# 与 Windows 版 v2.8 同一套模型（ApexDriftVehiclePawn.cpp 的 UpdateSimPhysics）：四个轮胎各按接地点速度算侧偏角 / 滑移率，
# 按载荷（车重 + 下压 + 纵 / 横向载荷转移）算附着，纵向和侧向共用摩擦圆，越过峰值变成滑动摩擦；后轮另有胎面速度状态
# （油门大于附着就空转、手刹抱死）。车身的力和横摆全部来自这四个轮胎，抓地、漂移、横过来、倒着滑是同一套公式，
# 没有任何把车头拉回 / 摆正的东西：甩出去要自己反打、收油，倒着滑也能一直倒着滑。
# 悬挂、碰撞、护墙仍由上面的射线悬挂和 _walls 负责（Windows 版是 Chaos 只管悬架、碰撞）。

# 合成滑移 S（峰值处为 1）对应的附着利用率：峰值前正弦上升，越过峰值衰减到滑动摩擦
static func _curve(s: float, slide: float) -> float:
	return sin(PI * 0.5 * s) if s <= 1.0 else slide + (1.0 - slide) * exp(-(s - 1.0) * SIM_DECAY)

# 一个轮胎的纵向 / 侧向力（N）和合成滑移：sx 胎面比路面快多少（驱动为正、抱死为负），sy 接地点侧向速度（右正），
# vl 接地点沿轮胎方向的速度。按峰值归一的合成滑移算大小、按滑移方向分配。返回 (纵向, 侧向, S)
static func _tire(sx: float, sy: float, vl: float, capx: float, capy: float, peak_a: float, slide_lat: float) -> Vector3:
	var vref := maxf(absf(vl), 3.0)
	var kn := sx / vref / SIM_PEAK_K
	var an := sy / vref / peak_a
	var s := sqrt(kn * kn + an * an)
	if s < 1e-4:
		return Vector3(0.0, 0.0, s)
	var f := _curve(s, lerpf(SIM_SLIDE_LONG, slide_lat, (an * an) / (s * s))) / s
	return Vector3(capx * f * kn, -capy * f * an, s)

static func _sim_ratio(g: int) -> float:
	if g > 0:
		var r: float = SIM_GEARS[g - 1]
		return r * SIM_FINAL
	if g < 0:
		return SIM_REV_RATIO * SIM_FINAL
	return 0.0

# 进入拟真档（开赛、复位、传送、自动漂移交还控制后的第一帧）：后轮按当前车速滚动，挑一个不超过升挡转速的挡
func _sim_begin(vf: float) -> void:
	sim_on = true
	sim_free = false
	sim_spin = 0.0
	sim_calm = 0.0
	sim_prev_ok = false
	drift_on = false
	sim_thr = in_throttle
	sim_ws = maxf(0.0, vf)
	sim_gear = 1
	for g in range(1, 7):
		sim_gear = g
		if sim_ws * _sim_ratio(g) * SIM_TO_RPM < SIM_UP_RPM:
			break
	sim_target = sim_gear
	sim_shift_cut = 0.0
	sim_shift_t = 0.0
	reverse = false

func _sim_end() -> void:
	sim_on = false
	sim_free = false
	reverse = false
	for i in 4:
		sim_skid[i] = 0.0

# 换挡：立即（起步、挂倒挡）或经过 0.1 秒空挡（自动升降挡，和 Chaos 一样）
func _sim_shift(g: int, immediate: bool) -> void:
	sim_target = g
	if immediate:
		sim_gear = g
		sim_shift_cut = 0.0
	else:
		sim_gear = 0
		sim_shift_cut = SIM_SHIFT_TIME

# 发动机给后轮胎面的驱动力（N），ws = 胎面速度。倒挡时刹车键是油门
func _sim_drive(ws: float) -> float:
	if _d_ratio <= 0.0:
		return 0.0
	var dir := 1.0 if _d_gear > 0 else -1.0
	var wd := ws * dir
	var f := 0.0
	if _d_thr > 0.02:
		if _d_gear > 0:
			# 与其他档同一条全油门加速度曲线（按后轮胎面速度取值，空转越快劲越小）+ 抵消风阻
			f = MASS * accel_at(maxf(wd, 0.0) * 3.6, _d_acc, _d_top) + SIM_DRAG * _d_vx * _d_vx
			f *= clampf((_d_wsmax - wd) / 1.5, 0.0, 1.0)     # 红线断油
		else:
			f = MASS * 4.5 * clampf((12.0 - wd) / 1.5, 0.0, 1.0)   # 倒车最快约 43km/h
		f *= _d_thr
	else:
		f = -MASS * 0.9 * sqrt(_d_ratio / 11.16) * clampf(wd / 8.0, -1.0, 1.0)   # 松油：发动机制动，挡越高越弱
	return f * dir

# 两个后轮在胎面速度 ws 下的纵向力之和；keep 时把每个轮的纵向 / 侧向力和滑移存进 _rfl / _rft / _rs
func _sim_rear_long(ws: float, keep: bool) -> float:
	var sum := 0.0
	for j in 2:
		var fl := 0.0
		var ft := 0.0
		var s := 0.0
		if _fz[2 + j] > 0.0:
			var t := _tire(ws - _vlr[j], _vtr[j], _vlr[j], _cxr[j], _cyr[j], SIM_PEAK_AR, SIM_SLIDE_LAT_R)
			fl = t.x
			ft = t.y
			s = t.z
		if keep:
			_rfl[j] = fl
			_rft[j] = ft
			_rs[j] = s
		sum += fl
	return sum

func _sim(st: PhysicsDirectBodyState3D, dt: float, gup: Vector3, fwd: Vector3, right: Vector3, vt: Vector3, vx: float, vy: float) -> void:
	var grip: float = info.get("grip", 1.0)
	var agil: float = info.get("agility", 1.0)
	var r := -st.angular_velocity.dot(gup)          # 横摆角速度 rad/s，右转为正
	var iz := MASS * SIM_YAW_K / clampf(agil, 0.6, 1.6)
	var v := Vector2(vx, vy).length()
	# 风阻（驱动力里等量补回，全油门直线和其他档一样快；松油时它和发动机制动让车慢下来）
	st.apply_central_force(-vt * SIM_DRAG * speed)

	# 触屏 / 键盘油门是 0/1：0.25 秒推满，松得更快（只是输入平滑，不限制出力）
	sim_thr = move_toward(sim_thr, in_throttle, dt * (4.0 if in_throttle > sim_thr else 8.0))
	# 车身坐标加速度（含转动项），低通后算载荷转移
	if sim_prev_ok:
		var ax := (vx - sim_prev_vx) / dt - r * vy
		var ay := (vy - sim_prev_vy) / dt + r * vx
		var kf := 1.0 - exp(-dt / 0.07)
		sim_ax += (clampf(ax, -25.0, 25.0) - sim_ax) * kf
		sim_ay += (clampf(ay, -25.0, 25.0) - sim_ay) * kf
	sim_prev_vx = vx
	sim_prev_vy = vy
	sim_prev_ok = true

	# ---- 换挡状态（换挡中是空挡）
	if sim_shift_cut > 0.0:
		sim_shift_cut -= dt
		if sim_shift_cut <= 0.0:
			sim_gear = sim_target
	var gear_now := sim_gear

	# ---- 只统计不干预：车头相对行进方向的角度、是否横着滑、转满一圈记 360
	var psi := -beta if speed > 2.0 else 0.0
	var apsi := absf(psi)
	if sim_free:
		sim_spin += wrapf(psi - sim_psi, -180.0, 180.0)
	sim_psi = psi
	var reversing := gear_now < 0 and vx < 0.5     # 挂倒挡倒车不算滑
	if v > 4.0 and apsi > (10.0 if sim_free else 22.0) and not reversing:
		sim_free = true
		sim_calm = 0.0
	elif sim_free:
		sim_calm += dt
		if sim_calm > 0.4 or v < 3.0 or reversing:
			sim_free = false
			sim_spin = 0.0
	if absf(sim_spin) > 325.0 and apsi < 45.0:
		sim_spin -= signf(sim_spin) * 360.0
		spin_done.emit()

	# ---- 方向：只按玩家输入。车速越高可用转角越小（满舵也不至于一下打过轮胎极限）；
	#      车已经横过来时，往前轴实际行进的方向打（反打）可以打到前轮对准行进方向再多一点，但绝不自己反打
	var max_wheel := 38.0
	var vs := maxf(v, 1.0)
	var brk_term := in_throttle if gear_now < 0 else in_brake
	var margin := lerpf(7.0, 3.0, clampf((v - 25.0) / 45.0, 0.0, 1.0)) if v < 70.0 else lerpf(3.0, 2.0, clampf((v - 70.0) / 25.0, 0.0, 1.0))
	margin *= lerpf(1.0, 0.6, clampf(brk_term * clampf((v - 15.0) / 25.0, 0.0, 1.0), 0.0, 1.0))
	var lim := clampf(rad_to_deg(atan(SIM_L * SIM_MU_LAT_F * grip * SIM_G / (vs * vs))) + margin, 1.5, max_wheel)
	if vx > 0.5:
		var front_ang := rad_to_deg(atan2(vy + SIM_A * r, vx))   # 前轴往哪走（相对车头，右正）
		if steer * front_ang > 0.0:
			lim = maxf(lim, minf(absf(front_ang) + 8.0, max_wheel))
	else:
		lim = max_wheel * 0.8       # 倒车、倒着滑：方向随便打
	sim_steer_lim = lim
	var steer_deg := steer * lim

	# ---- 传动：停住按住刹车挂倒挡，倒挡里按油门挂回一挡，空挡起步挂一挡
	if gear_now >= 0 and absf(vx) < 1.0 and in_brake > 0.3 and in_throttle < 0.1:
		_sim_shift(-1, true)
	elif gear_now < 0 and in_throttle > 0.3 and vx > -1.0:
		_sim_shift(1, true)
	elif gear_now == 0 and sim_target == 0 and in_throttle > 0.1 and in_brake < 0.3:
		_sim_shift(1, true)
	# 自动挡：按后轮实际转速（空转时比车速快）升降挡，和真车的自动挡一样漂移时会升挡
	sim_shift_t += dt
	if gear_now > 0:
		var rpm_now := absf(sim_ws) * _sim_ratio(gear_now) * SIM_TO_RPM
		if sim_shift_t > 0.35 and rpm_now > SIM_UP_RPM and gear_now < SIM_GEARS.size():
			_sim_shift(gear_now + 1, false)
			sim_shift_t = 0.0
		elif sim_shift_t > 0.6 and sim_hand_t > 0.5 and gear_now > 1 and rpm_now < SIM_DOWN_RPM and rpm_now * _sim_ratio(gear_now - 1) / _sim_ratio(gear_now) < SIM_REDLINE * 0.9:
			_sim_shift(gear_now - 1, false)
			sim_shift_t = 0.0
	var ratio := _sim_ratio(gear_now)
	var to_rpm := ratio * SIM_TO_RPM
	_d_ratio = ratio
	_d_gear = gear_now
	_d_wsmax = SIM_REDLINE / to_rpm if ratio > 0.0 else 0.0
	_d_thr = in_brake if gear_now < 0 else sim_thr
	_d_vx = maxf(vx, 0.0)
	_d_acc = info.get("accel", 1.0)
	_d_top = info.get("top", 360.0)
	var brake_f := MASS * SIM_BRAKE_ACCEL * (in_throttle if gear_now < 0 else in_brake)
	var rpm_ratio := ratio if ratio > 0.0 else _sim_ratio(sim_target)

	# ---- 载荷：车重 + 下压按静态比例分配，再加纵向 / 横向载荷转移；离地的轮子不出力
	var nin := 0
	for i in 4:
		nin += 1 if wheel_on[i] != 0 else 0
	if nin == 0:
		# 四轮离地：后轮照样被油门带着转、被手刹停住，车身不受轮胎力
		sim_ws = 0.0 if in_hand else sim_ws + dt * _sim_drive(sim_ws) / SIM_REAR_INERTIA
		sim_rpm = clampf(absf(sim_ws) * rpm_ratio * SIM_TO_RPM, 900.0, SIM_REDLINE)
		for i in 4:
			sim_skid[i] = 0.0
		_sim_out(steer_deg)
		return
	var down := minf(0.0009 * v * v, 6.0)
	var n := MASS * (SIM_G + down) * (1.0 if nin >= 3 else (0.85 if nin == 2 else 0.5))
	var ld_scale := n / (MASS * SIM_G)
	var dlong := MASS * sim_ax * SIM_COMH / SIM_L * ld_scale                 # 加速时后轴加载
	var dlatf := MASS * sim_ay * SIM_COMH / SIM_TRACK_F * SIM_ROLL_F * ld_scale  # 右转时左侧（外侧）加载
	var dlatr := MASS * sim_ay * SIM_COMH / SIM_TRACK_R * (1.0 - SIM_ROLL_F) * ld_scale
	_fz[0] = n * SIM_B / SIM_L * 0.5 - dlong * 0.5 + dlatf
	_fz[1] = n * SIM_B / SIM_L * 0.5 - dlong * 0.5 - dlatf
	_fz[2] = n * SIM_A / SIM_L * 0.5 + dlong * 0.5 + dlatr
	_fz[3] = n * SIM_A / SIM_L * 0.5 + dlong * 0.5 - dlatr
	var masked := 0.0
	for i in 4:
		_fz[i] = maxf(_fz[i], 0.02 * n) if wheel_on[i] != 0 else 0.0
		masked += _fz[i]
	for i in 4:
		_fz[i] *= n / maxf(masked, 1.0)

	var fx := 0.0
	var fy := 0.0
	var mz := 0.0
	var inv_m := 1.0 / MASS

	# ---- 前轮：自由滚动，带 ABS 的刹车按摩擦圆分走纵向附着
	var delta := deg_to_rad(steer_deg)
	var cd := cos(delta)
	var sd := sin(delta)
	for i in 2:
		sim_skid[i] = 0.0
		if _fz[i] <= 0.0:
			continue
		var px: float = SIM_PX[i]
		var py: float = SIM_PY[i]
		var wx := vx - r * py
		var wy := vy + r * px
		var vl := wx * cd + wy * sd
		var vtt := -wx * sd + wy * cd
		var sens := clampf(1.0 - SIM_LOAD_SENS * (_fz[i] / (MASS * SIM_G * SIM_B / SIM_L * 0.5) - 1.0), 0.75, 1.15)
		var capx := SIM_MU_LONG_F * grip * sens * _fz[i]
		var capy := SIM_MU_LAT_F * grip * sens * _fz[i]
		var t := _tire(0.0, vtt, vl, capx, capy, SIM_PEAK_AF, SIM_SLIDE_LAT_F)
		var flong := t.x
		var flat := t.y
		if brake_f > 0.0 and absf(vl) > 0.05:
			var u := minf(brake_f * SIM_BRAKE_FRONT * 0.5 / maxf(capx, 1.0), 0.95)
			flong = _stop_clamp(-signf(vl) * u * capx, vl, py, dt, inv_m, iz)
			flat *= sqrt(1.0 - u * u)
		flat = _stop_clamp(flat, vtt, px, dt, inv_m, iz)
		sim_skid[i] = clampf((t.z - 1.2) / 2.0, 0.0, 1.0)
		var fxw := flong * cd - flat * sd
		var fyw := flong * sd + flat * cd
		fx += fxw
		fy += fyw
		mz += px * fyw - py * fxw

	# ---- 后轮：两轮共用一个胎面速度（限滑差速），按发动机、刹车和地面反力积分；手刹抱死
	for j in 2:
		var i: int = 2 + j
		var px2: float = SIM_PX[i]
		var py2: float = SIM_PY[i]
		_vlr[j] = vx - r * py2
		_vtr[j] = vy + r * px2
		var sens2 := clampf(1.0 - SIM_LOAD_SENS * (_fz[i] / (MASS * SIM_G * SIM_A / SIM_L * 0.5) - 1.0), 0.75, 1.15)
		_cxr[j] = SIM_MU_LONG_R * grip * sens2 * _fz[i]
		_cyr[j] = SIM_MU_LAT_R * grip * sens2 * _fz[i]
	var nsub := clampi(ceili(dt / 0.0015), 4, 16)
	var h := dt / float(nsub)
	var rear_brake := minf(brake_f * (1.0 - SIM_BRAKE_FRONT), SIM_REAR_BRAKE_CAP * (_cxr[0] + _cxr[1]) * sqrt(maxf(0.1, 1.0 - sim_rear_lat * sim_rear_lat)))
	# 牵引力控制（像地平线默认那样）：只限油门，从不转车头。按后轮实际的侧偏角算附着圆里还剩多少纵向，
	# 驱动力只给到合成滑移为峰值 90% 的那么多；后轮已经横着滑时也不放开，只许一点空转（SIM_TCS_SLIP × 峰值滑移率）。
	# 拉手刹起的横滑（玩家自己要漂、要原地转圈）不限（v2.9）：从拉手刹起，直到车身不再横滑后再过 1 秒（sim_hand_slide），
	# 这段时间油门照“关掉牵引力控制”处理，可以用油门续漂；出弯给油、压路肩、被撞歪这种不是自己要的横滑照样限
	sim_hand_t = 0.0 if in_hand else sim_hand_t + dt
	if in_hand:
		sim_hand_slide = true
	elif not sim_free and sim_hand_t > 1.0:
		sim_hand_slide = false
	var use_tcs := tcs and sim_hand_t > SIM_TCS_HAND and gear_now > 0 and not sim_hand_slide
	var tcs_cap := 1e9
	if use_tcs:
		tcs_cap = 0.0
		for j in 2:
			if _fz[2 + j] <= 0.0:
				continue
			var an := absf(_vtr[j]) / maxf(absf(_vlr[j]), 3.0) / SIM_PEAK_AR
			var kn := maxf(sqrt(maxf(0.0, 0.81 - an * an)), SIM_TCS_SLIP)
			var s := sqrt(kn * kn + an * an)
			tcs_cap += _cxr[j] * _curve(s, lerpf(SIM_SLIDE_LONG, SIM_SLIDE_LAT_R, an * an / (s * s))) * kn / s
	sim_tcs_cap = tcs_cap if use_tcs else -1.0
	# 关掉牵引力控制时后轮空转的上限：车身正着时只许中等空转，车尾横得越多许得越多（油门照样能甩尾、保持漂移）。
	# 拉手刹起的横滑（玩家自己要漂、要原地转圈）许得多；出弯给油、被撞歪这种不是自己要的横滑许得少，能救回来
	var gain := SIM_SPIN_GAIN_HAND if sim_hand_slide else SIM_SPIN_GAIN
	var ws_lim := 1e9
	if not use_tcs and gear_now > 0 and not in_hand:
		ws_lim = -1e9
		for j in 2:
			if _fz[2 + j] <= 0.0:
				continue
			var vref := maxf(absf(_vlr[j]), 3.0)
			var an2 := absf(_vtr[j]) / vref / SIM_PEAK_AR
			ws_lim = maxf(ws_lim, _vlr[j] + (SIM_SPIN_BASE + gain * an2) * SIM_PEAK_K * vref)
		if ws_lim < -1e8:
			ws_lim = 1e9
	var ws := sim_ws
	var acc_fl0 := 0.0
	var acc_fl1 := 0.0
	var acc_ft0 := 0.0
	var acc_ft1 := 0.0
	var max_s0 := 0.0
	var max_s1 := 0.0
	for k in nsub:
		if in_hand:
			ws = 0.0
		var fl_sum := _sim_rear_long(ws, true)
		acc_fl0 += _rfl[0] / float(nsub)
		acc_fl1 += _rfl[1] / float(nsub)
		acc_ft0 += _rft[0] / float(nsub)
		acc_ft1 += _rft[1] / float(nsub)
		max_s0 = maxf(max_s0, _rs[0])
		max_s1 = maxf(max_s1, _rs[1])
		if in_hand:
			continue
		# 半隐式：按当地刚度放大惯量，低速时轮胎很“硬”也不会来回震荡
		var stiff := maxf(0.0, (_sim_rear_long(ws + 0.05, false) - fl_sum) / 0.05)
		var drive := minf(_sim_drive(ws), tcs_cap)
		if ws >= ws_lim and drive > 0.0:
			drive = 0.0          # 超过空转上限就断油，让地面把轮子拖回来
		var wn := ws + h * (drive - fl_sum) / (SIM_REAR_INERTIA + h * stiff)
		if rear_brake > 0.0:
			var dec := h * rear_brake / SIM_REAR_INERTIA
			wn = maxf(0.0, wn - dec) if wn > 0.0 else minf(0.0, wn + dec)   # 刹车只让轮子停下，不会倒转
		if ws < ws_lim and wn > ws_lim:
			wn = ws_lim
		ws = wn
	sim_ws = 0.0 if in_hand else ws
	sim_rear_lat = clampf(maxf(absf(acc_ft0) / maxf(_cyr[0], 1.0), absf(acc_ft1) / maxf(_cyr[1], 1.0)), 0.0, 1.0)
	# 差速器左右等分扭矩（按载荷分时稍一转弯外侧推得更狠，车会越转越急）
	if not in_hand and _fz[2] > 0.0 and _fz[3] > 0.0:
		acc_fl0 = 0.5 * (acc_fl0 + acc_fl1)
		acc_fl1 = acc_fl0
	for j in 2:
		var i: int = 2 + j
		var px3: float = SIM_PX[i]
		var py3: float = SIM_PY[i]
		var ms := max_s0 if j == 0 else max_s1
		var fl2 := acc_fl0 if j == 0 else acc_fl1
		var ft2 := acc_ft0 if j == 0 else acc_ft1
		if _fz[i] <= 0.0:
			sim_skid[i] = 0.0
			continue
		sim_skid[i] = 1.0 if (in_hand and v > 5.0) else clampf((ms - 1.2) / 2.0, 0.0, 1.0)
		if in_hand:
			fl2 = _stop_clamp(fl2, _vlr[j], py3, dt, inv_m, iz)
		ft2 = _stop_clamp(ft2, _vtr[j], px3, dt, inv_m, iz)
		fx += fl2
		fy += ft2
		mz += px3 * ft2 - py3 * fl2
	sim_rpm = clampf(absf(sim_ws) * rpm_ratio * SIM_TO_RPM, 900.0, SIM_REDLINE)

	# ---- 施力：平移力加在质心，横摆按轮胎力矩积分（不覆盖碰撞等带来的角速度）
	st.apply_central_force(fwd * fx + right * fy)
	st.angular_velocity = st.angular_velocity - gup * (mz / iz * dt)
	# 高速下压（与其他档一致），过坡不发飘
	st.apply_central_force(-gup * minf(0.0009 * v * v, 6.0) * MASS)
	_sim_out(steer_deg)

# 数值稳定：一帧内一个轮子的力不超过把它接地点相对速度刹停所需（低速、静止时不抖）
static func _stop_clamp(f: float, vrel: float, lever: float, dt: float, inv_m: float, iz: float) -> float:
	var lim := 0.22 * absf(vrel) / (dt * (inv_m + lever * lever / iz))
	return clampf(f, -lim, lim)

# 给画面、声音、计分用的量
func _sim_out(steer_deg: float) -> void:
	steer_vis = deg_to_rad(steer_deg)
	path_rate = rad_to_deg(sim_ay / maxf(speed, 5.0))
	accel_f = sim_ax
	var sk := 0.0
	for i in 4:
		sk = maxf(sk, sim_skid[i])
	skid = sk
	reverse = sim_gear < 0 or (sim_gear == 0 and sim_target < 0)

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
	if sim_on:
		# 拟真档：挡位和转速来自轮胎模型（后轮空转时转速跟着冲高）
		gear = -1 if reverse else maxi(1, sim_target if sim_gear == 0 else sim_gear)
		var want := sim_rpm - (900.0 if sim_shift_cut > 0.0 else 0.0)
		rpm = lerpf(rpm, maxf(900.0, want), 1.0 - exp(-14.0 * dt))
		boost = lerpf(boost, in_throttle * clampf((rpm - 2400.0) / 5000.0, 0.0, 1.0), 1.0 - exp(-4.0 * dt))
		return
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
