class_name Track
extends RefCounted
# 赛道中心线：3m 一个采样。x 北、y 上、z 东；行进方向右侧为 +lat

var n := 0
var length := 0.0
var p := PackedVector3Array()
var r2 := PackedVector2Array()     # 右方向（x,z）
var bank := PackedFloat32Array()
var k := PackedFloat32Array()      # 曲率 1/m，右弯为正
var s := PackedFloat32Array()
var zones: Array = []

# query() 的结果
var q_i := 0
var q_s := 0.0
var q_lat := 0.0
var q_dir := Vector2.RIGHT
var q_y := 0.0
var q_dist := 0.0

func setup(d: Dictionary) -> void:
	n = int(d["n"])
	length = float(d["len"])
	var pp: Array = d["p"]
	var rr: Array = d["r"]
	p.resize(n)
	r2.resize(n)
	bank.resize(n)
	k.resize(n)
	s.resize(n)
	var acc := 0.0
	for i in n:
		p[i] = Vector3(pp[i * 3], pp[i * 3 + 1], pp[i * 3 + 2])
		r2[i] = Vector2(rr[i * 2], rr[i * 2 + 1])
		bank[i] = d["bank"][i]
		k[i] = d["k"][i]
		s[i] = acc
		acc += p[i].distance_to(Vector3(pp[((i + 1) % n) * 3], pp[((i + 1) % n) * 3 + 1], pp[((i + 1) % n) * 3 + 2]))
	length = acc
	zones = d.get("zones", [])

func dir_at(i: int) -> Vector2:
	var r := r2[posmod(i, n)]
	return Vector2(r.y, -r.x)    # 右=(−t.y, t.x) 的逆

func nearest(pos: Vector3, hint: int) -> int:
	var best := -1
	var bd := 1e18
	if hint >= 0:
		for o in range(-24, 25):
			var i := posmod(hint + o, n)
			var dx := p[i].x - pos.x
			var dz := p[i].z - pos.z
			var d := dx * dx + dz * dz
			if d < bd:
				bd = d
				best = i
		if bd < 900.0:
			return best
	bd = 1e18
	for i in range(0, n, 2):
		var dx := p[i].x - pos.x
		var dz := p[i].z - pos.z
		var d := dx * dx + dz * dz
		if d < bd:
			bd = d
			best = i
	return best

func query(pos: Vector3, hint: int) -> void:
	var i := nearest(pos, hint)
	var a := p[i]
	var d := dir_at(i)
	var along := (pos.x - a.x) * d.x + (pos.z - a.z) * d.y
	var j := posmod(i + 1, n) if along >= 0.0 else posmod(i - 1, n)
	var b := p[j]
	var seg := Vector2(b.x - a.x, b.z - a.z)
	var l2 := maxf(seg.length_squared(), 1e-4)
	var t := clampf(((pos.x - a.x) * seg.x + (pos.z - a.z) * seg.y) / l2, 0.0, 1.0)
	var r := r2[i].lerp(r2[j], t).normalized()
	var cx := a.x + seg.x * t
	var cz := a.z + seg.y * t
	q_i = i
	q_lat = (pos.x - cx) * r.x + (pos.z - cz) * r.y
	q_dir = Vector2(r.y, -r.x)
	var bk := lerpf(bank[i], bank[j], t)
	q_y = lerpf(a.y, b.y, t) - sin(bk) * q_lat
	var ds := sqrt(l2) * t
	q_s = fposmod(s[i] + (ds if along >= 0.0 else -ds), length)
	q_dist = Vector2(pos.x - cx, pos.z - cz).length()

# 沿线 s 米处、横偏 lat 的世界点
func point(ss: float, lat: float) -> Vector3:
	var f := fposmod(ss, length) / length * n
	var i := int(f) % n
	# s 基本等距，线性取样足够
	var j := (i + 1) % n
	var t := f - floorf(f)
	var r := r2[i].lerp(r2[j], t).normalized()
	var c := p[i].lerp(p[j], t)
	var bk := lerpf(bank[i], bank[j], t)
	return Vector3(c.x + r.x * lat, c.y - sin(bk) * lat, c.z + r.y * lat)

func zone_at(ss: float) -> Dictionary:
	for z in zones:
		var a: float = z["a"]
		var b: float = z["b"]
		if (a <= b and ss >= a and ss <= b) or (a > b and (ss >= a or ss <= b)):
			return z
	return {}
