class_name Cam
extends Camera3D
# 追车 / 远景 / 引擎盖 / 菜单环绕 / 自动运镜

var car: Car
var mode := 0
var orbit := false
var orbit_yaw := 2.5
var director := false
var _yaw := 0.0
var _init_done := false
var _fov := 62.0
var _pos := Vector3.ZERO
var _look := Vector3.ZERO
var _dir_t := 0.0
var _shot := 0
var _shake := 0.0
var _y := 0.0
var _base_fov := 62.0

func snap() -> void:
	_init_done = false

func kick(s: float) -> void:
	_shake = minf(1.0, _shake + s)

func _process(dt: float) -> void:
	if car == null:
		return
	var xf := car.visual_xf()
	var vel := car.visual_vel()
	var pos := xf.origin
	if orbit:
		orbit_yaw += dt * 0.16
		var r := 6.4
		var c := pos + Vector3(0, 0.62, 0)
		global_position = c + Vector3(cos(orbit_yaw) * r, 1.25, sin(orbit_yaw) * r)
		look_at(c + Vector3(0, 0.15, 0), Vector3.UP)
		# 给右侧面板让位
		h_offset = 0.0
		fov = 46.0
		_init_done = false
		return
	h_offset = 0.0
	var f := xf.basis.x
	var hy := atan2(f.z, f.x)
	var sp := Vector2(vel.x, vel.z).length()
	var vy := atan2(vel.z, vel.x) if sp > 3.0 else hy
	# 镜头朝向：以行进方向为主，混一点车头；漂移时能看到车侧
	var rev := f.dot(vel) < -1.5 and absf(wrapf(vy - hy, -PI, PI)) > 2.6 and car.reverse
	var tgt := hy
	if not rev:
		var d := wrapf(hy - vy, -PI, PI)
		var k := clampf(sp / 9.0, 0.0, 1.0)
		var mixv := 0.30
		if absf(d) > 1.2:
			mixv = 0.0
		tgt = lerp_angle(hy, vy + d * mixv, k)
	if not _init_done:
		_init_done = true
		_yaw = tgt
		_fov = _base_fov
		_y = pos.y
	_yaw = lerp_angle(_yaw, tgt, 1.0 - exp(-(6.5 + sp * 0.05) * dt))
	_y = lerpf(_y, pos.y, 1.0 - exp(-14.0 * dt))
	var spd := clampf(sp / 75.0, 0.0, 1.0)
	var back := Vector3(-cos(_yaw), 0, -sin(_yaw))
	var dist := 5.1 + 1.0 * spd
	var height := 1.72 + 0.20 * spd
	var look_h := 0.95
	if mode == 1:
		dist = 7.6 + 1.2 * spd
		height = 2.7
	var base := Vector3(pos.x, _y, pos.z)
	if mode == 2 and car.auto == null:
		var hd: Array = car.info["hood"]
		global_transform = Transform3D(xf.basis * Basis(Vector3.UP, -PI * 0.5), xf * Vector3(float(hd[0]) - 0.9, float(hd[1]) + 0.12, 0.0))
		fov = lerpf(66.0, 82.0, spd)
		return
	if director and car.auto != null:
		_director(dt, base, vel, sp)
		return
	var want := base + back * dist + Vector3(0, height, 0)
	var look := base + Vector3(0, look_h, 0) - back * (2.2 + 2.5 * spd)
	_shake = maxf(0.0, _shake - dt * 2.5)
	if _shake > 0.0:
		var t := Time.get_ticks_msec() * 0.001
		want += Vector3(sin(t * 47.0), sin(t * 61.0), sin(t * 53.0)) * 0.06 * _shake
	global_position = want
	look_at(look, Vector3.UP)
	_fov = lerpf(_fov, _base_fov + 20.0 * spd, 1.0 - exp(-4.0 * dt))
	fov = _fov

func _director(dt: float, base: Vector3, vel: Vector3, sp: float) -> void:
	_dir_t -= dt
	var a := car.auto
	var spinning := absf(a.psi_spin) > 1.0
	if _dir_t <= 0.0 and not spinning:
		_shot = (_shot + 1) % 4
		_dir_t = [4.5, 3.2, 4.0, 3.0][_shot]
	var vy := atan2(vel.z, vel.x)
	var off := 0.0
	var dist := 5.8
	var h := 1.7
	var side := signf(a.psi) if absf(a.psi) > 6.0 else 1.0
	match _shot:
		0:
			off = 0.0
		1:
			off = 0.75 * side
			dist = 6.2
			h = 1.1
		2:
			off = 0.15
			dist = 8.4
			h = 3.2
		3:
			off = -0.55 * side
			dist = 5.6
			h = 0.95
	var ty := vy + off
	_yaw = lerp_angle(_yaw, ty, 1.0 - exp(-3.2 * dt))
	var back := Vector3(-cos(_yaw), 0, -sin(_yaw))
	var want := base + back * dist + Vector3(0, h, 0)
	_pos = want if _pos.distance_to(want) > 30.0 else _pos.lerp(want, 1.0 - exp(-12.0 * dt))
	# 高速时别被甩开
	_pos = _pos.lerp(want, clampf(sp * 0.006, 0.0, 0.6))
	global_position = _pos
	look_at(base + Vector3(0, 0.75, 0) - back * 1.2, Vector3.UP)
	fov = lerpf(fov, 60.0 + 14.0 * clampf(sp / 75.0, 0.0, 1.0), 1.0 - exp(-4.0 * dt))
