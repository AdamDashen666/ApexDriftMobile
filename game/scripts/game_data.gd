class_name GameData
extends RefCounted
# 静态数据：地图、天气、漆色、车辆

static var cars: Array = []
static var atlas: Array = []
static var sky_info: Dictionary = {}

const TREE_ORDER := ["SM_Sakura_01", "SM_Sakura_02", "SM_Sakura_03", "SM_Sakura_04", "SM_Maple_01", "SM_Maple_02", "SM_Maple_03", "SM_Cedar_01", "SM_Cedar_02", "SM_Pine_01", "SM_Pine_02", "SM_Bamboo_Clump_01", "SM_Bamboo_Clump_02"]

const MAPS := [
	{"id": "FujiSakura", "name": "富士樱湖", "en": "FUJI SAKURA LAKE", "tag": "满开樱花大道与湖面上的富士山", "km": "4.1", "diff": 2, "accent": Color(1.0, 0.56, 0.69), "weathers": ["春日晴空", "金色黄昏", "雨后初霁"]},
	{"id": "MomijiTouge", "name": "红枫峠", "en": "MOMIJI TOUGE", "tag": "层林尽染的连续发夹弯", "km": "4.3", "diff": 4, "accent": Color(1.0, 0.48, 0.18), "weathers": ["秋日暖阳", "山谷晨雾", "夕照红叶"]},
	{"id": "KuroshioCircuit", "name": "黑潮港湾", "en": "KUROSHIO HARBOR", "tag": "海岸环道与码头集装箱", "km": "2.8", "diff": 3, "accent": Color(0.25, 0.75, 1.0), "weathers": ["黄金日落", "午夜霓虹", "海岸晴日"]},
	{"id": "TrainingPark", "name": "湖畔训练场", "en": "TRAINING PARK", "tag": "超平坦场地：跳台、碗池、螺旋塔和能撞飞的道具", "km": "3.5", "diff": 1, "accent": Color(0.47, 0.88, 0.35), "weathers": ["晴空万里", "湖畔日落", "夜间灯光"]},
]

# 名称, 线性颜色, 金属感, 粗糙度, 色块
const PAINTS := [
	["富士蓝", Color(0.014, 0.085, 0.380), 0.45, 0.26, Color8(34, 92, 190)],
	["樱霞粉", Color(0.620, 0.180, 0.270), 0.30, 0.28, Color8(232, 140, 168)],
	["朱红", Color(0.520, 0.020, 0.012), 0.18, 0.28, Color8(206, 44, 34)],
	["雪顶白", Color(0.780, 0.785, 0.790), 0.05, 0.30, Color8(238, 240, 242)],
	["液态银", Color(0.480, 0.500, 0.540), 0.75, 0.28, Color8(170, 176, 186)],
	["墨玉绿", Color(0.008, 0.080, 0.052), 0.42, 0.26, Color8(22, 92, 70)],
	["暮光金", Color(0.560, 0.230, 0.035), 0.60, 0.27, Color8(214, 146, 52)],
	["夜幕黑", Color(0.008, 0.008, 0.010), 0.35, 0.22, Color8(24, 25, 30)],
]

const MODES := ["自由漂移", "三分钟挑战"]
const ASSISTS := ["均衡", "专业", "拟真"]

static func _json(path: String) -> Variant:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		push_error("缺文件 " + path)
		return null
	return JSON.parse_string(f.get_as_text())

static func load_all() -> void:
	if not cars.is_empty():
		return
	cars = _json("res://assets/cars/cars.json")
	atlas = _json("res://assets/flora/atlas.json")
	sky_info = _json("res://assets/sky/sky.json")

static func map_index(id: String) -> int:
	for i in MAPS.size():
		if MAPS[i]["id"] == id:
			return i
	return 0

static func weather(map_id: String, idx: int) -> Dictionary:
	# pitch/yaw：太阳光行进方向（度）
	var w := {"pitch": -47.0, "yaw": -80.0, "color": Color(1, 0.955, 0.885), "energy": 1.55, "sky": "FujiClear", "sky_gain": 1.0, "ambient": 1.0, "fog": Color(0.62, 0.78, 1.0), "fog_d": 0.00006, "exposure": 1.0, "wet": 0.0, "night": false, "petals": 1.0, "sat": 1.08}
	match map_id:
		"MomijiTouge":
			match idx:
				1:
					w.merge({"pitch": -20.0, "yaw": 40.0, "color": Color(1.0, 0.86, 0.68), "energy": 1.15, "sky": "MomijiMist", "fog": Color(0.80, 0.84, 0.90), "fog_d": 0.0030, "exposure": 1.0, "wet": 0.35, "petals": 0.4}, true)
				2:
					w.merge({"pitch": -14.0, "yaw": -150.0, "color": Color(1.0, 0.62, 0.34), "energy": 1.5, "sky": "MomijiSunset", "fog": Color(0.62, 0.50, 0.46), "fog_d": 0.00010, "exposure": 1.15, "ambient": 1.15, "petals": 0.8}, true)
				_:
					w.merge({"pitch": -36.0, "yaw": 30.0, "color": Color(1.0, 0.93, 0.82), "energy": 1.6, "sky": "MomijiClear", "fog": Color(0.56, 0.66, 0.82), "fog_d": 0.00007, "petals": 0.7}, true)
		"KuroshioCircuit":
			match idx:
				1:
					w.merge({"pitch": -32.0, "yaw": -45.0, "color": Color(0.45, 0.62, 1.0), "energy": 0.32, "sky": "KuroNight", "sky_gain": 1.0, "ambient": 2.2, "fog": Color(0.05, 0.09, 0.18), "fog_d": 0.0007, "exposure": 1.35, "wet": 0.7, "night": true, "petals": 0.0}, true)
				2:
					w.merge({"pitch": -40.0, "yaw": -110.0, "color": Color(1.0, 0.96, 0.90), "energy": 1.6, "sky": "FujiClear", "fog": Color(0.50, 0.66, 0.88), "fog_d": 0.00008, "petals": 0.0}, true)
				_:
					w.merge({"pitch": -16.0, "yaw": -135.0, "color": Color(1.0, 0.76, 0.50), "energy": 1.5, "sky": "KuroSunset", "fog": Color(0.66, 0.56, 0.54), "fog_d": 0.00009, "ambient": 1.15, "wet": 0.5, "petals": 0.0}, true)
		_:
			match idx:
				1:
					w.merge({"pitch": -11.0, "yaw": 82.0, "color": Color(1.0, 0.64, 0.38), "energy": 1.45, "sky": "FujiSunset", "fog": Color(0.62, 0.52, 0.58), "fog_d": 0.00009, "ambient": 1.15, "exposure": 1.1, "petals": 0.85}, true)
				2:
					if map_id == "TrainingPark":
						w.merge({"pitch": -60.0, "yaw": -45.0, "color": Color(0.86, 0.92, 1.0), "energy": 0.75, "sky": "KuroNight", "ambient": 1.9, "fog": Color(0.05, 0.08, 0.16), "fog_d": 0.0009, "exposure": 1.25, "night": true, "petals": 0.0}, true)
					else:
						w.merge({"pitch": -46.0, "yaw": -68.0, "color": Color(1.0, 0.95, 0.87), "energy": 1.15, "sky": "FujiCloudy", "fog": Color(0.62, 0.70, 0.80), "fog_d": 0.00016, "wet": 0.8, "petals": 0.45}, true)
	return w
