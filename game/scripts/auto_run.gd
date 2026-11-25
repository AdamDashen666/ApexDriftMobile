class_name AutoRun
extends RefCounted
# 自动漂移一圈：开始时一次算好走线、车速、漂移角和 360，运行时按计划走，不含随机数

signal spin_started()

const DS := 3.0
var track: Track
var n := 0
var total := 0.0
var line := PackedVector3Array()
var kap := PackedFloat32Array()
var vplan := PackedFloat32Array()
var psi_base := PackedFloat32Array()
var tt := PackedFloat32Array()        # 到达各点的时间
var spins: Array = []                 # [开始时间, 时长, 方向]
var lap_time := 0.0

var t := 0.0
var s := 0.0
var v := 0.0
var psi := 0.0
var psi_spin := 0.0
var xf := Transform3D.IDENTITY
var vel := Vector3.ZERO
var throttle := 0.0
var brake := 0.0
var done := false
var spin_i := 0
var spins_done := 0
var space: PhysicsDirectSpaceState3D
var _rp := PhysicsRayQueryParameters3D.new()
var _up := Vector3.UP
var _y := 0.0
var drift_frac := 0.0
var vmax := 0.0

func prepare(tr: Track, info: Dictionary, start_pos: Vector3, half: float) -> void:
	track = tr
	track.query(start_pos, -1)
	var s0 := track.q_s
	total = track.length
	n = int(floor(total / DS))
	var ds := total / n
	# 走线：横偏松弛
	var off := PackedFloat32Array()
	off.resize(n)
	var c := PackedVector3Array()
	var r := PackedVector2Array()
	c.resize(n)
	r.resize(n)
	for i in n:
		var ss := s0 + i * ds
		c[i] = track.point(ss, 0.0)
		var c2 := track.point(ss, 1.0)
		r[i] = Vector2(c2.x - c[i].x, c2.z - c[i].z).normalized()
	off[0] = clampf(track.q_lat, -half, half)
	var pin := off[0]
	for it in 130:
		for pas in 2:
			for i in range(pas, n, 2):
				if i < 3 or i > n - 4:
					off[i] = lerpf(off[i], pin, 0.5)
					continue
				var a := c[i - 1]
				var b := c[i + 1]
				var ax := a.x + r[i - 1].x * off[i - 1]
				var az := a.z + r[i - 1].y * off[i - 1]
				var bx := b.x + r[i + 1].x * off[i + 1]
				var bz := b.z + r[i + 1].y * off[i + 1]
				var mx := (ax + bx) * 0.5 - c[i].x
				var mz := (az + bz) * 0.5 - c[i].z
				off[i] = clampf(lerpf(off[i], mx * r[i].x + mz * r[i].y, 1.0), -half, half)
	line.resize(n)
	for i in n:
		line[i] = track.point(s0 + i * ds, off[i])
	# 曲率（平滑）
	kap.resize(n)
	for i in n:
		var a := line[posmod(i - 2, n)]
		var b := line[i]
		var d := line[posmod(i + 2, n)]
		var h0 := atan2(b.z - a.z, b.x - a.x)
		var h1 := atan2(d.z - b.z, d.x - b.x)
		kap[i] = wrapf(h1 - h0, -PI, PI) / (2.0 * ds)
	for it in 6:
		var kk := kap.duplicate()
		for i in n:
			kap[i] = (kk[posmod(i - 1, n)] + kk[i] * 2.0 + kk[posmod(i + 1, n)]) * 0.25
	# 车速
	var grip: float = info["grip"]
	var top: float = info["top"]
	var acc: float = info["accel"]
	vplan.resize(n)
	for i in n:
		var kmax := 0.0
		for q in range(-2, 3):
			kmax = maxf(kmax, absf(kap[posmod(i + q, n)]))
		vplan[i] = minf(sqrt(23.0 * grip / maxf(kmax, 1e-4)), minf(top * 0.80 / 3.6, 80.0))
	vplan[0] = 2.0
	for i in range(1, n):
		var a2 := Car.accel_at(vplan[i - 1] * 3.6, acc, top) * 0.94
		vplan[i] = minf(vplan[i], sqrt(vplan[i - 1] * vplan[i - 1] + 2.0 * a2 * ds))
	for i in range(n - 2, -1, -1):
		vplan[i] = minf(vplan[i], sqrt(vplan[i + 1] * vplan[i + 1] + 2.0 * 14.5 * ds))
	vplan[0] = maxf(vplan[0], 1.5)
	tt.resize(n + 1)
	tt[0] = 0.0
	for i in n:
		var va := maxf(1.0, (vplan[i] + vplan[mini(i + 1, n - 1)]) * 0.5)
		tt[i + 1] = tt[i] + ds / va
	lap_time = tt[n]
	# 漂移角：按侧向需求，提前入弯、晚点出弯
	psi_base.resize(n)
	var raw := PackedFloat32Array()
	raw.resize(n)
	for i in n:
		var ka := absf(kap[i])
		var vv := vplan[i]
		var a := 0.0
		if ka > 1.0 / 190.0 and vv > 11.0:
			a = clampf(24.0 + (ka - 1.0 / 190.0) * 1300.0, 24.0, 52.0) * float(clampf(info["drift"], 0.85, 1.1))
		raw[i] = a * signf(kap[i])
	# 提前 0.35 秒甩出去，再平滑
	for i in n:
		var look := int(vplan[i] * 0.35 / ds)
		psi_base[i] = raw[mini(i + look, n - 1)]
	for it in 10:
		var kk2 := psi_base.duplicate()
		for i in range(1, n - 1):
			psi_base[i] = (kk2[i - 1] + kk2[i] * 2.0 + kk2[i + 1]) * 0.25
	for i in range(0, mini(12, n)):
		psi_base[i] *= i / 12.0
		psi_base[n - 1 - i] *= i / 12.0
	var dn := 0
	for i in n:
		if absf(psi_base[i]) > 12.0:
			dn += 1
	drift_frac = float(dn) / n
	# 360：放在弯与弯之间的直段，尽量在入弯前收完
	spins.clear()
	var i := int(30.0 / ds)
	while i < n - int(40.0 / ds):
		if absf(psi_base[i]) < 4.0:
			var j := i
			while j < n - 1 and absf(psi_base[j]) < 9.0:
				j += 1
			var dur := tt[j] - tt[i]
			var vm := vplan[(i + j) >> 1]
			if dur > 1.9 and vm > 22.0 and j < n - int(30.0 / ds):
				var nx := signf(psi_base[mini(j + int(12.0 / ds), n - 1)])
				var d2 := 1.35
				spins.append([tt[j] - d2 - 0.25, d2, nx if nx != 0.0 else 1.0])
				if dur > 6.5:
					spins.insert(spins.size() - 1, [tt[i] + 1.2, d2, -nx if nx != 0.0 else -1.0])
			i = j + 4
		else:
			i += 2
	for k in n:
		vmax = maxf(vmax, vplan[k])
	t = 0.0
	s = 0.0
	done = false
	_up = Vector3.UP
	_y = line[0].y
	_rp.collision_mask = 1
	_place(0.0)

func _sample(a: PackedFloat32Array, f: float) -> float:
	var i := int(f)
	if i >= n - 1:
		return a[n - 1]
	return lerpf(a[i], a[i + 1], f - i)

func _place(dt: float) -> void:
	var ds := total / n
	var f := clampf(s / ds, 0.0, n - 1.001)
	var i := int(f)
	var u := f - i
	var p0 := line[maxi(i - 1, 0)]
	var p1 := line[i]
	var p2 := line[mini(i + 1, n - 1)]
	var p3 := line[mini(i + 2, n - 1)]
	var pos := p1.cubic_interpolate(p2, p0, p3, u)
	var tan := (p2 - p1).lerp(p3 - p2, u) * 0.5 + (p2 - p0) * 0.25
	tan.y = 0.0
	tan = tan.normalized()
	var up := Vector3.UP
	var y := pos.y
	if space != null:
		_rp.from = Vector3(pos.x, pos.y + 3.0, pos.z)
		_rp.to = Vector3(pos.x, pos.y - 5.0, pos.z)
		var h := space.intersect_ray(_rp)
		if not h.is_empty():
			y = h.position.y
			up = h.normal
	var kk := 1.0 - exp(-18.0 * dt) if dt > 0.0 else 1.0
	_up = _up.lerp(up, kk).normalized()
	_y = lerpf(_y, y, 1.0 - exp(-40.0 * dt)) if dt > 0.0 else y
	pos.y = _y
	psi = _sample(psi_base, f) + psi_spin
	var yaw := atan2(tan.z, tan.x) + deg_to_rad(psi)
	var fwd := Vector3(cos(yaw), 0, sin(yaw))
	fwd = (fwd - _up * fwd.dot(_up)).normalized()
	var right := fwd.cross(_up)
	xf = Transform3D(Basis(fwd, _up, right), pos)
	vel = (tan - _up * tan.dot(_up)).normalized() * v

func step(dt: float, _car: Car) -> void:
	if done:
		return
	t += dt
	var ds := total / n
	var f := s / ds
	var nv := _sample(vplan, f)
	throttle = clampf(0.55 + (nv - v) * 0.6, 0.0, 1.0)
	brake = clampf((v - nv) * 0.5, 0.0, 1.0)
	v = maxf(nv, 1.2)
	s += v * dt
	psi_spin = 0.0
	for k in spins.size():
		var sp: Array = spins[k]
		var u := (t - float(sp[0])) / float(sp[1])
		if u > 0.0 and u < 1.0:
			if spin_i == k:
				spin_i = k + 1
				spin_started.emit()
			var e := u * u * u * (u * (u * 6.0 - 15.0) + 10.0)
			psi_spin = 360.0 * e * float(sp[2])
			throttle = 1.0
	if spin_i > spins_done:
		var sp2: Array = spins[spin_i - 1]
		if t > float(sp2[0]) + float(sp2[1]):
			spins_done = spin_i
	if s >= total - 4.0:
		done = true
		return
	_place(dt)

# 直接跳到第 sec 秒（截图用）
func seek(sec: float) -> void:
	t = sec
	var i := 0
	while i < n and tt[i] < sec:
		i += 1
	s = maxf(0.0, i - 1) * total / n
	v = vplan[clampi(i, 0, n - 1)]
	_y = line[clampi(i, 0, n - 1)].y
	_place(0.0)
