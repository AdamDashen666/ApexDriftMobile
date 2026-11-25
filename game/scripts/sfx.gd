class_name Sfx
extends Node
# 发动机三段循环按转速交叉淡入，轮胎、风噪、一次性音效

var car: Car
var loops: Dictionary = {}
var shots: Array[AudioStreamPlayer] = []
var si := 0
var enabled := true
var master := 1.0
var engine_on := false
const ENG := [["SFX_Engine_On_2500", 2500.0], ["SFX_Engine_On_4500", 4500.0], ["SFX_Engine_On_6500", 6500.0]]
var cache: Dictionary = {}

func _stream(n: String) -> AudioStream:
	if not cache.has(n):
		var p := "res://assets/audio/%s.wav" % n
		cache[n] = load(p) if ResourceLoader.exists(p) else null
	return cache[n]

func _loop(n: String) -> AudioStreamPlayer:
	var p := AudioStreamPlayer.new()
	var s: AudioStream = _stream(n)
	if s is AudioStreamWAV:
		var w: AudioStreamWAV = s.duplicate()
		w.loop_mode = AudioStreamWAV.LOOP_FORWARD
		w.loop_begin = 0
		w.loop_end = int(w.get_length() * w.mix_rate) - 1
		s = w
	p.stream = s
	p.volume_db = -80.0
	add_child(p)
	return p

func _ready() -> void:
	for e in ENG:
		loops[e[0]] = _loop(e[0])
	loops["off"] = _loop("SFX_Engine_Off_2000")
	loops["tire"] = _loop("SFX_Tire_Screech_Dry")
	loops["wind"] = _loop("SFX_Wind_Rush")
	for i in 6:
		var p := AudioStreamPlayer.new()
		add_child(p)
		shots.append(p)

func play(n: String, vol := 0.0, pitch := 1.0) -> void:
	if not enabled:
		return
	var s := _stream(n)
	if s == null:
		return
	var p := shots[si]
	si = (si + 1) % shots.size()
	p.stream = s
	p.volume_db = vol + linear_to_db(maxf(master, 0.001))
	p.pitch_scale = pitch
	p.play()

func set_engine(on: bool) -> void:
	engine_on = on
	for k in loops:
		var p: AudioStreamPlayer = loops[k]
		if on and enabled:
			if not p.playing:
				p.play()
		else:
			p.stop()

func _set(k: String, v: float, pitch := 1.0) -> void:
	var p: AudioStreamPlayer = loops[k]
	p.volume_db = linear_to_db(maxf(v * master, 0.0001))
	p.pitch_scale = clampf(pitch, 0.2, 3.0)

func _process(_dt: float) -> void:
	if not engine_on or car == null or car.info.is_empty():
		return
	var r := car.rpm
	var load_v := 0.35 + 0.65 * car.in_throttle
	var pit: float = car.info["pitch"]
	var vol: float = float(car.info["vol"]) * 0.5
	for i in ENG.size():
		var c: float = ENG[i][1]
		var w := 0.0
		if i == 0:
			w = clampf(1.0 - (r - 2500.0) / 2000.0, 0.0, 1.0)
		elif i == ENG.size() - 1:
			w = clampf((r - 4500.0) / 2000.0, 0.0, 1.0)
		else:
			w = clampf(1.0 - absf(r - c) / 2000.0, 0.0, 1.0)
		_set(ENG[i][0], w * load_v * vol, r / c * pit)
	_set("off", (1.0 - car.in_throttle) * 0.22 * vol * 2.0, clampf(r / 2000.0, 0.5, 2.6) * pit)
	_set("tire", car.skid * 0.42 if car.grounded >= 2 else 0.0, 0.85 + 0.2 * clampf(car.kmh / 160.0, 0.0, 1.0))
	_set("wind", clampf((car.kmh - 60.0) / 240.0, 0.0, 1.0) * 0.35, 0.9 + car.kmh / 600.0)
