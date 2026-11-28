class_name Save
extends RefCounted
# 存档：user://apex.cfg

static var map := 0
static var car := 0
static var paints: Array = [0, 5, 6, 3, 2, 4, 7]
static var weather: Array = [0, 0, 0, 0]
static var mode := 0
static var assist := 0
static var steer_mode := 0       # 0 滑动 1 按键 2 重力感应
static var steer_sens := 1.0
static var auto_throttle := false
static var quality := 1
static var show_fps := true
static var sound := true
static var haptics := true
static var director := true
static var best: Dictionary = {}
static var path := "user://apex.cfg"
static var persist := true

static func load_cfg() -> void:
	var c := ConfigFile.new()
	if c.load(path) != OK:
		return
	map = clampi(c.get_value("g", "map", map), 0, GameData.MAPS.size() - 1)
	car = clampi(c.get_value("g", "car", car), 0, GameData.cars.size() - 1)
	var p: Array = c.get_value("g", "paints", paints)
	if p.size() == GameData.cars.size():
		paints = p
	var w: Array = c.get_value("g", "weather", weather)
	if w.size() == GameData.MAPS.size():
		weather = w
	mode = clampi(c.get_value("g", "mode", mode), 0, 1)
	assist = clampi(c.get_value("s", "assist", assist), 0, 2)
	steer_mode = clampi(c.get_value("s", "steer_mode", steer_mode), 0, 2)
	steer_sens = clampf(c.get_value("s", "steer_sens", steer_sens), 0.5, 2.0)
	auto_throttle = c.get_value("s", "auto_throttle", auto_throttle)
	quality = clampi(c.get_value("s", "quality", quality), 0, 2)
	show_fps = c.get_value("s", "show_fps", show_fps)
	sound = c.get_value("s", "sound", sound)
	haptics = c.get_value("s", "haptics", haptics)
	director = c.get_value("s", "director", director)
	best = c.get_value("g", "best", best)

static func store() -> void:
	if not persist:
		return
	var c := ConfigFile.new()
	c.set_value("g", "map", map)
	c.set_value("g", "car", car)
	c.set_value("g", "paints", paints)
	c.set_value("g", "weather", weather)
	c.set_value("g", "mode", mode)
	c.set_value("s", "assist", assist)
	c.set_value("s", "steer_mode", steer_mode)
	c.set_value("s", "steer_sens", steer_sens)
	c.set_value("s", "auto_throttle", auto_throttle)
	c.set_value("s", "quality", quality)
	c.set_value("s", "show_fps", show_fps)
	c.set_value("s", "sound", sound)
	c.set_value("s", "haptics", haptics)
	c.set_value("s", "director", director)
	c.set_value("g", "best", best)
	c.save(path)

static func record(key: String, v: float, lower_better := false) -> bool:
	var old: float = best.get(key, 0.0)
	if v <= 0.0:
		return false
	if old <= 0.0 or (v < old if lower_better else v > old):
		best[key] = v
		store()
		return true
	return false
