class_name Score
extends RefCounted
# 漂移计分：角度 x 车速，连击到 x5，断 2.2 秒入账

signal callout(text: String, kind: int)      # kind 0 普通 1 大 2 失败
signal cue(name: String)

var total := 0
var best := 0
var current := 0.0
var mult := 1.0
var chain := 0.0
var drifting := false
var grace := 0.0
var peak := 0.0
var angle := 0.0
var zone := ""
var time := 0.0
var lap_t := 0.0
var best_lap := 0.0
var half_passed := false
var last_s := 0.0
var wrong := false
var wall_cd := 0.0
const GRACE := 2.2

func reset() -> void:
	total = 0
	best = 0
	current = 0.0
	mult = 1.0
	chain = 0.0
	drifting = false
	grace = 0.0
	peak = 0.0
	time = 0.0
	lap_t = 0.0
	best_lap = 0.0
	half_passed = false
	wrong = false

func update(dt: float, car: Car, track: Track, free: bool) -> void:
	time += dt
	lap_t += dt
	wall_cd = maxf(0.0, wall_cd - dt)
	zone = ""
	var vel := car.visual_vel()
	if track != null:
		track.query(car.global_position, car.hint)
		car.hint = track.q_i
		var off := free and absf(track.q_lat) > 11.5
		wrong = not free and car.kmh > 25.0 and (vel.x * track.q_dir.x + vel.z * track.q_dir.y) < -0.35 * car.speed
		var pr := track.q_s / track.length
		if off:
			half_passed = false
		elif pr > 0.4 and pr < 0.7:
			half_passed = true
		if half_passed and not off and last_s > track.length * 0.75 and track.q_s < track.length * 0.25:
			half_passed = false
			if lap_t > 15.0:
				if best_lap <= 0.0 or lap_t < best_lap:
					best_lap = lap_t
					callout.emit("最快圈 %s" % fmt_time(lap_t), 1)
				lap_t = 0.0
		last_s = track.q_s
		if not off:
			var z := track.zone_at(track.q_s)
			if not z.is_empty():
				zone = z["name"]
	angle = car.slip_deg
	var ok := car.grounded >= 2 and not wrong and car.kmh >= 24.0 and angle >= 12.5
	if ok:
		if not drifting:
			drifting = true
			current = 0.0
			chain = 0.0
			mult = 1.0
		grace = 0.0
		peak = maxf(peak, minf(angle, 90.0))
		var af := clampf((minf(angle, 90.0) - 10.0) / 38.0, 0.25, 1.65)
		var sf := clampf(car.kmh / 85.0, 0.35, 2.1)
		var pts := 520.0 * af * sf * (1.25 if zone != "" else 1.0) * dt
		chain += pts
		current += pts * mult
		var m := clampf(1.0 + floorf(chain / 950.0) * 0.5, 1.0, 5.0)
		if m > mult:
			mult = m
			cue.emit("SFX_UI_ComboUp")
			if mult >= 4.0:
				callout.emit("极限连漂", 1)
			elif angle >= 38.0:
				callout.emit("大角度横滑", 0)
	elif drifting:
		grace += dt
		if grace >= GRACE:
			bank()

func spin() -> void:
	if drifting:
		current += 1500.0 * mult
	else:
		total += 1500
	callout.emit("360° 旋转漂移", 1)
	cue.emit("SFX_UI_ComboUp")

func wall(strength: float) -> void:
	if not drifting:
		return
	if strength > 8.0:
		drifting = false
		current = 0.0
		mult = 1.0
		chain = 0.0
		callout.emit("撞墙，连击中断", 2)
		cue.emit("SFX_UI_ComboLost")
	elif strength > 1.6 and wall_cd <= 0.0:
		wall_cd = 2.0
		current += 500.0 * mult
		callout.emit("擦墙 +500", 0)

func prop_hit() -> void:
	total += 50

func bank() -> void:
	if not drifting:
		return
	var b := int(round(current))
	if b >= 100:
		total += b
		best = maxi(best, b)
		callout.emit("+%s" % fmt_num(b), 0)
		cue.emit("SFX_UI_DriftBank")
	drifting = false
	current = 0.0
	mult = 1.0
	chain = 0.0
	grace = 0.0

static func fmt_time(t: float) -> String:
	return "%d:%05.2f" % [int(t) / 60, fmod(t, 60.0)]

static func fmt_num(v: int) -> String:
	var s := str(v)
	var o := ""
	var c := 0
	for i in range(s.length() - 1, -1, -1):
		o = s[i] + o
		c += 1
		if c % 3 == 0 and i > 0:
			o = "," + o
	return o
