class_name Ui
extends Control
# 全部界面：自绘（HUD、触控、菜单、设置、暂停、结算）。坐标按 616 高设计，宽度随屏幕

signal action(id: String)

var main: Node
var f_zh: Font
var f_num: Font
var f_num2: Font
var f_body: Font
var screen := "loading"      # loading menu play settings pause result help
var back_to := "menu"
var accent := Color(1, 0.5, 0.2)
var msg := "正在载入"
var btns: Array = []         # [id, Rect2]
var press_id := ""
var press_idx := -1
var touches: Dictionary = {}
var safe_l := 20.0
var safe_r := 20.0
var safe_b := 10.0
var t := 0.0
var callout := ""
var callout_k := 0
var callout_t := 9.0
var count := 0.0
var go_t := 9.0
var hint_t := 99.0
var steer_out := 0.0
var thr_out := 0.0
var brk_out := 0.0
var hand_out := false
var steer_disp := 0.0
var result: Dictionary = {}
var thumbs: Array = []
var map_pts := PackedVector2Array()
var map_min := Vector2.ZERO
var map_scale := 1.0
var mm: Control
var redraw_acc := 0.0
var drag_slider := ""

const INK := Color(0.04, 0.04, 0.055)
const PAPER := Color(0.97, 0.95, 0.91)

func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	mm = Control.new()
	mm.mouse_filter = Control.MOUSE_FILTER_IGNORE
	mm.draw.connect(_draw_mm)
	add_child(mm)
	f_zh = load("res://assets/fonts/SmileySans-Oblique.ttf")
	f_num = load("res://assets/fonts/BarlowCondensed-ExtraBoldItalic.ttf")
	f_num2 = load("res://assets/fonts/BarlowCondensed-SemiBoldItalic.ttf")
	f_body = load("res://assets/fonts/NotoSansSC-Bold-Subset.otf")
	for m in GameData.MAPS:
		var p := "res://assets/ui/%s.jpg" % m["id"]
		thumbs.append(load(p) if ResourceLoader.exists(p) else null)
	_safe()

func _safe() -> void:
	var win := DisplayServer.window_get_size()
	var sa := DisplayServer.get_display_safe_area()
	if win.x <= 0 or sa.size.x <= 0 or size.x <= 0.0:
		return
	var k := size.x / float(win.x)
	var wp := DisplayServer.window_get_position()
	safe_l = maxf(18.0, (sa.position.x - wp.x) * k + 6.0)
	safe_r = maxf(18.0, (win.x - (sa.position.x - wp.x + sa.size.x)) * k + 6.0)
	if safe_l > size.x * 0.2 or safe_r > size.x * 0.2:
		safe_l = 20.0
		safe_r = 20.0
	safe_b = clampf((win.y - (sa.position.y - wp.y + sa.size.y)) * k, 6.0, 30.0)

func set_map(tr: Track, _meta: Dictionary) -> void:
	map_pts = PackedVector2Array()
	var mn := Vector2(1e9, 1e9)
	var mx := -mn
	for i in range(0, tr.n, maxi(1, tr.n / 220)):
		var p := Vector2(tr.p[i].z, -tr.p[i].x)
		map_pts.append(p)
		mn = mn.min(p)
		mx = mx.max(p)
	map_min = (mn + mx) * 0.5
	map_scale = 1.0 / maxf(mx.x - mn.x, mx.y - mn.y)
	if mm:
		mm.queue_redraw()

func show_callout(s: String, k: int) -> void:
	callout = s
	callout_k = k
	callout_t = 0.0

func _process(dt: float) -> void:
	t += dt
	callout_t += dt
	go_t += dt
	hint_t += dt
	if size.x < 10.0:
		set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	if screen == "play":
		_read_controls(dt)
	mm.visible = screen == "play"
	# 触控每帧读，画面 60Hz 重画就够
	redraw_acc += dt
	if redraw_acc >= 0.0155:
		redraw_acc = 0.0
		queue_redraw()

# ------------------------------------------------------------------ 输入
func _rects() -> Dictionary:
	var w := size.x
	var h := size.y
	var r := w - safe_r
	return {"gas": [Vector2(r - 84, h - 108 - safe_b), 66.0], "brake": [Vector2(r - 226, h - 76 - safe_b), 50.0], "hand": [Vector2(r - 210, h - 198 - safe_b), 50.0],
		"left": [Vector2(safe_l + 78, h - 104 - safe_b), 60.0], "right": [Vector2(safe_l + 214, h - 104 - safe_b), 60.0]}

func _pedal_at(p: Vector2) -> String:
	var rc := _rects()
	var best := ""
	var bd := 1e9
	for k in ["gas", "brake", "hand"]:
		var c: Array = rc[k]
		var d: float = p.distance_to(c[0]) - float(c[1])
		if d < 34.0 and d < bd:
			bd = d
			best = k
	return best

func _input(ev: InputEvent) -> void:
	if ev is InputEventScreenTouch:
		var e: InputEventScreenTouch = ev
		if e.pressed:
			_down(e.index, e.position)
		else:
			_up(e.index, e.position)
	elif ev is InputEventScreenDrag:
		var d: InputEventScreenDrag = ev
		if touches.has(d.index):
			var tt: Dictionary = touches[d.index]
			tt["pos"] = d.position
			if tt["role"] in ["gas", "brake", "hand"]:
				var k := _pedal_at(d.position)
				if k != "":
					tt["role"] = k
			elif tt["role"] == "left" or tt["role"] == "right":
				var rc := _rects()
				var mid: float = (rc["left"][0].x + rc["right"][0].x) * 0.5
				tt["role"] = "left" if d.position.x < mid else "right"
			elif tt["role"] == "slider":
				_slide(d.position)

func _down(i: int, p: Vector2) -> void:
	for k in range(btns.size() - 1, -1, -1):
		var b: Array = btns[k]
		if (b[1] as Rect2).grow(6.0).has_point(p):
			press_id = b[0]
			press_idx = i
			touches[i] = {"pos": p, "start": p, "role": "btn"}
			if String(b[0]).begins_with("slider:"):
				touches[i]["role"] = "slider"
				drag_slider = String(b[0]).substr(7)
				_slide(p)
			return
	if screen != "play":
		touches[i] = {"pos": p, "start": p, "role": ""}
		return
	var ped := _pedal_at(p)
	if ped != "":
		touches[i] = {"pos": p, "start": p, "role": ped}
		return
	if p.x < size.x * 0.47:
		if Save.steer_mode == 1:
			var rc := _rects()
			var mid: float = (rc["left"][0].x + rc["right"][0].x) * 0.5
			touches[i] = {"pos": p, "start": p, "role": "left" if p.x < mid else "right"}
		else:
			touches[i] = {"pos": p, "start": p, "role": "steer"}
	else:
		touches[i] = {"pos": p, "start": p, "role": ""}

func _up(i: int, p: Vector2) -> void:
	if press_idx == i and press_id != "":
		for b in btns:
			if b[0] == press_id and (b[1] as Rect2).grow(14.0).has_point(p) and not String(press_id).begins_with("slider:"):
				action.emit(press_id)
				break
		press_id = ""
		press_idx = -1
	if drag_slider != "" and touches.has(i) and touches[i]["role"] == "slider":
		drag_slider = ""
		Save.store()
	touches.erase(i)

func _slide(p: Vector2) -> void:
	for b in btns:
		if b[0] == "slider:" + drag_slider:
			var r: Rect2 = b[1]
			var u := clampf((p.x - r.position.x) / r.size.x, 0.0, 1.0)
			if drag_slider == "sens":
				Save.steer_sens = snappedf(lerpf(0.5, 2.0, u), 0.05)

func _read_controls(dt: float) -> void:
	var st := 0.0
	var th := 0.0
	var br := 0.0
	var hd := false
	for i in touches:
		var tt: Dictionary = touches[i]
		match tt["role"]:
			"gas": th = 1.0
			"brake": br = 1.0
			"hand": hd = true
			"left": st -= 1.0
			"right": st += 1.0
			"steer":
				if Save.steer_mode == 0:
					var dx: float = (tt["pos"].x - tt["start"].x) / (96.0 / Save.steer_sens)
					# 起点跟着手指走，反打更快
					if absf(dx) > 1.15:
						tt["start"].x = tt["pos"].x - signf(dx) * 1.15 * 96.0 / Save.steer_sens
					dx = clampf(dx, -1.0, 1.0)
					st = signf(dx) * pow(maxf(0.0, absf(dx) - 0.05) / 0.95, 1.15)
	if Save.steer_mode == 2:
		var g := Input.get_gravity()
		if g.length() < 1.0:
			g = Input.get_accelerometer()
		if g.length() > 1.0:
			var v := clampf(g.x / 9.8 * 2.3 * Save.steer_sens, -1.0, 1.0)
			st = signf(v) * maxf(0.0, absf(v) - 0.04) / 0.96
	# 键盘 / 手柄
	var kx := 0.0
	if Input.is_physical_key_pressed(KEY_A) or Input.is_physical_key_pressed(KEY_LEFT): kx -= 1.0
	if Input.is_physical_key_pressed(KEY_D) or Input.is_physical_key_pressed(KEY_RIGHT): kx += 1.0
	if kx != 0.0: st = kx
	if Input.is_physical_key_pressed(KEY_W) or Input.is_physical_key_pressed(KEY_UP): th = 1.0
	if Input.is_physical_key_pressed(KEY_S) or Input.is_physical_key_pressed(KEY_DOWN): br = 1.0
	if Input.is_physical_key_pressed(KEY_SPACE): hd = true
	for j in Input.get_connected_joypads():
		var ax := Input.get_joy_axis(j, JOY_AXIS_LEFT_X)
		if absf(ax) > 0.12: st = ax
		th = maxf(th, Input.get_joy_axis(j, JOY_AXIS_TRIGGER_RIGHT))
		br = maxf(br, Input.get_joy_axis(j, JOY_AXIS_TRIGGER_LEFT))
		if Input.is_joy_button_pressed(j, JOY_BUTTON_A) or Input.is_joy_button_pressed(j, JOY_BUTTON_RIGHT_SHOULDER): hd = true
	if Save.auto_throttle and br < 0.1:
		th = 1.0
	steer_out = clampf(st, -1.0, 1.0)
	thr_out = th
	brk_out = br
	hand_out = hd
	steer_disp = lerpf(steer_disp, steer_out, 1.0 - exp(-25.0 * dt))

func any_drive_input() -> bool:
	for i in touches:
		if touches[i]["role"] in ["gas", "brake", "hand", "left", "right", "steer"]:
			return true
	return absf(steer_out) > 0.3 and Save.steer_mode != 2 or brk_out > 0.2 or hand_out or (thr_out > 0.2 and not Save.auto_throttle)

# ------------------------------------------------------------------ 画
func _b(id: String, r: Rect2) -> bool:
	btns.append([id, r])
	return press_id == id

func _txt(f: Font, s: String, p: Vector2, sz: int, c: Color, al := HORIZONTAL_ALIGNMENT_LEFT, w := -1.0) -> void:
	var x := p.x
	var ol := Color(0, 0, 0, 0.55 * c.a) if screen == "play" and c.v > 0.4 else Color(0, 0, 0, 0)
	if w < 0.0 and al != HORIZONTAL_ALIGNMENT_LEFT:
		var tw := f.get_string_size(s, HORIZONTAL_ALIGNMENT_LEFT, -1, sz).x
		x = p.x - (tw if al == HORIZONTAL_ALIGNMENT_RIGHT else tw * 0.5)
	if ol.a > 0.0:
		draw_string_outline(f, Vector2(x, p.y), s, HORIZONTAL_ALIGNMENT_LEFT, -1, sz, 5, ol)
	draw_string(f, Vector2(x, p.y), s, HORIZONTAL_ALIGNMENT_LEFT, -1, sz, c)

func _skew(r: Rect2, c: Color, k := 0.18) -> void:
	var d := r.size.y * k
	draw_colored_polygon(PackedVector2Array([r.position + Vector2(d, 0), Vector2(r.end.x + d, r.position.y), Vector2(r.end.x - d * 0.0, r.end.y), Vector2(r.position.x, r.end.y)]), c)

func _skew_line(r: Rect2, c: Color, w := 1.5, k := 0.18) -> void:
	var d := r.size.y * k
	draw_polyline(PackedVector2Array([r.position + Vector2(d, 0), Vector2(r.end.x + d, r.position.y), r.end, Vector2(r.position.x, r.end.y), r.position + Vector2(d, 0)]), c, w, true)

func _draw() -> void:
	btns.clear()
	match screen:
		"loading": _draw_loading()
		"menu": _draw_menu()
		"play": _draw_hud()
		"settings": _draw_settings()
		"pause": _draw_pause()
		"result": _draw_result()
		"help": _draw_help()

func _draw_loading() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), Color(0.03, 0.03, 0.04))
	var c := size * 0.5
	for k in 3:
		_skew(Rect2(c.x - 250 + k * 20, c.y - 46, 10, 52), Color(accent, 1.0 - 0.3 * k), 0.34)
	_txt(f_num, "APEX DRIFT", c + Vector2(-180, 4), 72, PAPER)
	_txt(f_zh, msg + "…", c + Vector2(0, 60), 24, Color(PAPER, 0.75), HORIZONTAL_ALIGNMENT_CENTER)

func _draw_hud() -> void:
	var w := size.x
	var h := size.y
	var car: Car = main.car
	var sc: Score = main.score
	var rx := w - safe_r
	# 顶部按钮
	var bx := safe_l
	for b in [["pause", "pause"], ["reset", "reset"], ["cam", "cam"]]:
		var r := Rect2(bx, 14, 54, 46)
		var dn := _b(b[0], r)
		_skew(r, Color(INK, 0.62) if not dn else Color(accent, 0.9), 0.2)
		_icon(b[1], r.get_center() + Vector2(4, 0), PAPER)
		bx += 68
	# 模式与总分
	var auto_on: bool = car.auto != null
	_txt(f_zh, "自动漂移" if auto_on else GameData.MODES[Save.mode], Vector2(bx + 14, 32), 18, Color(PAPER, 0.8))
	_txt(f_num, Score.fmt_num(sc.total), Vector2(bx + 14, 64), 34, PAPER)
	if Save.mode == 1 and not auto_on and not main.free_map():
		pass
	if Save.mode == 1 and not auto_on:
		var left := maxf(0.0, 180.0 - sc.time)
		_txt(f_num, "%d:%02d" % [int(left) / 60, int(left) % 60], Vector2(bx + 190, 64), 34, Color(1, 0.4, 0.3) if left < 15.0 else PAPER)
	# 当前漂移
	if sc.drifting:
		var c := Vector2(w * 0.5, 66)
		_txt(f_num, Score.fmt_num(int(sc.current)), c + Vector2(0, 18), 58, PAPER, HORIZONTAL_ALIGNMENT_CENTER)
		var mr := Rect2(c.x - 34, c.y + 26, 62, 24)
		_skew(mr, accent)
		_txt(f_num, "x%.1f" % sc.mult, mr.get_center() + Vector2(4, 8), 22, INK, HORIZONTAL_ALIGNMENT_CENTER)
		_txt(f_num2, "%d°" % int(minf(sc.angle, 180.0)), c + Vector2(64, 44), 22, Color(PAPER, 0.85))
		if sc.grace > 0.05:
			var u := 1.0 - sc.grace / Score.GRACE
			draw_rect(Rect2(c.x - 80, c.y + 56, 160 * u, 4), Color(1, 0.6, 0.2))
	if callout_t < 1.7 and callout != "":
		var a := clampf((1.7 - callout_t) / 0.4, 0.0, 1.0)
		var k := 1.0 + 0.25 * exp(-callout_t * 9.0)
		var col: Color = [Color(1, 0.8, 0.35), Color(1, 0.62, 0.2), Color(1, 0.35, 0.3)][callout_k]
		_txt(f_zh, callout, Vector2(w * 0.5, 152), int(30 * k), Color(col, a), HORIZONTAL_ALIGNMENT_CENTER)
	if sc.zone != "":
		_txt(f_zh, sc.zone, Vector2(safe_l + 8, 96), 20, Color(accent, 0.95))
	if sc.wrong and not auto_on:
		_txt(f_zh, "逆行", Vector2(w * 0.5, 200), 40, Color(1, 0.3, 0.25, 0.6 + 0.4 * sin(t * 8.0)), HORIZONTAL_ALIGNMENT_CENTER)
	# 小地图
	_minimap(Vector2(rx - 64, 78), 58.0, car)
	if Save.show_fps:
		var p: Perf = main.perf
		var fc := Color(0.5, 0.95, 0.5) if p.fps > p.target * 0.95 else (Color(1, 0.8, 0.3) if p.fps > 55 else Color(1, 0.35, 0.3))
		_txt(f_num, "%d" % int(round(p.fps)), Vector2(rx - 150, 34), 28, fc, HORIZONTAL_ALIGNMENT_RIGHT)
		_txt(f_num2, "FPS  %d%%" % int(p.scale * 100.0 + 0.5), Vector2(rx - 146, 54), 14, Color(PAPER, 0.6), HORIZONTAL_ALIGNMENT_RIGHT)
	# 车速
	_speedo(Vector2(w * 0.5, h - 74 - safe_b), car)
	# 触控
	if not auto_on:
		_draw_touch()
	else:
		var r2 := Rect2(safe_l, h - 64 - safe_b, 372, 36)
		_skew(r2, Color(INK, 0.6))
		_txt(f_zh, "自动漂移中 · 碰任意驾驶键接管 · 跑完复位", r2.get_center() + Vector2(4, 8), 18, PAPER, HORIZONTAL_ALIGNMENT_CENTER)
		draw_rect(Rect2(r2.position.x, r2.end.y + 5, 366.0 * clampf(car.auto.s / maxf(car.auto.total, 1.0), 0.0, 1.0), 3), accent)
		_draw_touch(0.35)
		var rd := Rect2(rx - 330, 14, 96, 36)
		_skew(rd, Color(accent, 0.9) if Save.director else Color(INK, 0.6))
		_txt(f_zh, "运镜", rd.get_center() + Vector2(4, 8), 20, INK if Save.director else PAPER, HORIZONTAL_ALIGNMENT_CENTER)
		_b("director", rd)
	if main.free_map() and hint_t < 8.0 and not auto_on:
		var a2 := clampf((8.0 - hint_t), 0.0, 1.0)
		_txt(f_zh, "随便开 · 复位键原地扶正 · 连按两次回起点并复原道具", Vector2(w * 0.5, h - 190), 19, Color(PAPER, a2 * 0.9), HORIZONTAL_ALIGNMENT_CENTER)
	if count > 0.0:
		var n := int(ceil(count))
		var fr := 1.0 - (count - floorf(count))
		var sz := int(150 * (1.0 + 0.5 * exp(-fr * 8.0)))
		_txt(f_num, str(n), Vector2(w * 0.5, h * 0.5 + 40), sz, Color(PAPER, clampf(1.2 - fr, 0.0, 1.0)), HORIZONTAL_ALIGNMENT_CENTER)
	elif go_t < 0.9:
		_txt(f_num, "GO!", Vector2(w * 0.5, h * 0.5 + 40), int(150 + go_t * 40), Color(accent, 1.0 - go_t / 0.9), HORIZONTAL_ALIGNMENT_CENTER)

func _icon(k: String, c: Vector2, col: Color) -> void:
	match k:
		"pause":
			draw_rect(Rect2(c.x - 8, c.y - 9, 5, 18), col)
			draw_rect(Rect2(c.x + 3, c.y - 9, 5, 18), col)
		"reset":
			draw_arc(c, 9, 0.6, TAU - 0.5, 22, col, 2.6, true)
			draw_colored_polygon(PackedVector2Array([c + Vector2(13, -9), c + Vector2(13, 2), c + Vector2(3, -2)]), col)
		"cam":
			draw_rect(Rect2(c.x - 11, c.y - 7, 15, 14), col)
			draw_colored_polygon(PackedVector2Array([c + Vector2(5, 0), c + Vector2(12, -7), c + Vector2(12, 7)]), col)

func _circle_btn(c: Vector2, r: float, label: String, on: bool, col: Color, al: float) -> void:
	draw_circle(c, r, Color(INK, (0.42 if not on else 0.15) * al))
	if on:
		draw_circle(c, r, Color(col, 0.72 * al))
	draw_arc(c, r, 0, TAU, 48, Color(PAPER if not on else col, 0.75 * al), 2.2, true)
	_txt(f_zh, label, c + Vector2(0, 9), 24, Color(INK if on else PAPER, (1.0 if on else 0.92) * al), HORIZONTAL_ALIGNMENT_CENTER)

func _draw_touch(al := 1.0) -> void:
	var rc := _rects()
	_circle_btn(rc["gas"][0], rc["gas"][1], "自动" if Save.auto_throttle else "油门", thr_out > 0.5, Color(0.5, 0.95, 0.45), al)
	_circle_btn(rc["brake"][0], rc["brake"][1], "刹车", brk_out > 0.5, Color(1, 0.4, 0.32), al)
	_circle_btn(rc["hand"][0], rc["hand"][1], "手刹", hand_out, accent, al)
	if main.car.auto != null:
		return
	if Save.steer_mode == 1:
		for k in ["left", "right"]:
			var c: Vector2 = rc[k][0]
			var on := (steer_out < -0.5) if k == "left" else (steer_out > 0.5)
			var r: float = rc[k][1]
			draw_circle(c, r, Color(accent, 0.7 * al) if on else Color(INK, 0.42 * al))
			draw_arc(c, r, 0, TAU, 48, Color(PAPER, 0.75 * al), 2.2, true)
			var s := -1.0 if k == "left" else 1.0
			draw_colored_polygon(PackedVector2Array([c + Vector2(s * 24, 0), c + Vector2(-s * 14, -24), c + Vector2(-s * 14, 24)]), Color(INK if on else PAPER, 0.95 * al))
	elif Save.steer_mode == 0:
		var c2 := Vector2(safe_l + 150, size.y - 104 - safe_b)
		for i in touches:
			if touches[i]["role"] == "steer":
				c2 = touches[i]["start"]
		draw_arc(c2, 78, PI * 1.12, PI * 1.88, 40, Color(PAPER, 0.5 * al), 3.0, true)
		draw_arc(c2, 78, PI * 0.12, PI * 0.88, 40, Color(PAPER, 0.2 * al), 2.0, true)
		var kx := c2 + Vector2(steer_disp * 70.0, 0)
		draw_circle(kx, 34, Color(accent, 0.75 * al) if absf(steer_disp) > 0.03 else Color(INK, 0.45 * al))
		draw_arc(kx, 34, 0, TAU, 40, Color(PAPER, 0.8 * al), 2.2, true)
		_txt(f_zh, "方向", kx + Vector2(0, 7), 18, Color(PAPER, 0.95 * al), HORIZONTAL_ALIGNMENT_CENTER)
	else:
		var c3 := Vector2(safe_l + 120, size.y - 70 - safe_b)
		draw_rect(Rect2(c3.x - 90, c3.y - 4, 180, 8), Color(INK, 0.5 * al))
		draw_rect(Rect2(c3.x, c3.y - 4, steer_disp * 90.0, 8) if steer_disp > 0.0 else Rect2(c3.x + steer_disp * 90.0, c3.y - 4, -steer_disp * 90.0, 8), Color(accent, al))
		_txt(f_zh, "左右倾斜手机转向", c3 + Vector2(0, -16), 17, Color(PAPER, 0.7 * al), HORIZONTAL_ALIGNMENT_CENTER)

func _speedo(c: Vector2, car: Car) -> void:
	draw_circle(c, 74, Color(INK, 0.42))
	var a0 := PI * 0.80
	var a1 := PI * 2.20
	draw_arc(c, 66, a0, a1, 48, Color(PAPER, 0.18), 6.0, true)
	var u := clampf((car.rpm - 900.0) / 7200.0, 0.0, 1.0)
	draw_arc(c, 66, a0, lerpf(a0, a1, u), 48, accent if u < 0.93 else Color(1, 0.3, 0.25), 6.0, true)
	_txt(f_num, "%d" % int(car.kmh), c + Vector2(0, 14), 52, PAPER, HORIZONTAL_ALIGNMENT_CENTER)
	_txt(f_num2, "km/h", c + Vector2(0, 33), 16, Color(PAPER, 0.7), HORIZONTAL_ALIGNMENT_CENTER)
	var g := "R" if car.gear < 0 else str(car.gear)
	var r := Rect2(c.x - 18, c.y + 38, 32, 30)
	_skew(r, PAPER)
	_txt(f_num, g, r.get_center() + Vector2(3, 10), 28, INK, HORIZONTAL_ALIGNMENT_CENTER)

func _draw_mm() -> void:
	mm.draw_circle(Vector2.ZERO, 62.0, Color(INK, 0.5))
	if map_pts.is_empty():
		return
	var pts := PackedVector2Array()
	for p in map_pts:
		pts.append((p - map_min) * 58.0 * 1.62 * map_scale)
	pts.append(pts[0])
	mm.draw_polyline(pts, Color(PAPER, 0.75), 2.4, true)

func _minimap(c: Vector2, r: float, car: Car) -> void:
	if mm.position != c:
		mm.position = c
	if map_pts.is_empty():
		return
	var k := r * 1.62 * map_scale
	var pos := car.global_position
	var m := c + (Vector2(pos.z, -pos.x) - map_min) * k
	if m.distance_to(c) < r + 6.0:
		draw_circle(m, 5.0, INK)
		draw_circle(m, 3.8, accent)

# ------------------------------------------------------------------ 菜单
func _panel(r: Rect2, al := 0.62) -> void:
	draw_rect(r, Color(INK, al))

func _seg(id: String, items: Array, sel: int, r: Rect2, gap := 8.0) -> void:
	var n := items.size()
	var w := (r.size.x - gap * (n - 1)) / n
	for i in n:
		var q := Rect2(r.position.x + i * (w + gap), r.position.y, w, r.size.y)
		var dn := _b("%s:%d" % [id, i], q)
		_skew(q, PAPER if i == sel else Color(1, 1, 1, 0.22 if dn else 0.10), 0.16)
		_txt(f_zh, items[i], q.get_center() + Vector2(3, 7), 19, INK if i == sel else PAPER, HORIZONTAL_ALIGNMENT_CENTER)

func _draw_menu() -> void:
	var w := size.x
	var h := size.y
	var m: Dictionary = GameData.MAPS[Save.map]
	# 压暗
	draw_polygon(PackedVector2Array([Vector2(0, 0), Vector2(w * 0.5, 0), Vector2(w * 0.34, h), Vector2(0, h)]), PackedColorArray([Color(INK, 0.78), Color(INK, 0.0), Color(INK, 0.0), Color(INK, 0.78)]))
	draw_polygon(PackedVector2Array([Vector2(0, h - 290), Vector2(w, h - 290), Vector2(w, h), Vector2(0, h)]), PackedColorArray([Color(INK, 0.0), Color(INK, 0.0), Color(INK, 0.92), Color(INK, 0.92)]))
	draw_polygon(PackedVector2Array([Vector2(w - 420, 0), Vector2(w, 0), Vector2(w, h), Vector2(w - 360, h)]), PackedColorArray([Color(INK, 0.0), Color(INK, 0.72), Color(INK, 0.72), Color(INK, 0.0)]))
	var x := safe_l + 6
	for k in 3:
		_skew(Rect2(x + k * 11, 20, 6, 32), Color(accent, 1.0 - 0.3 * k), 0.34)
	_txt(f_num, "APEX DRIFT", Vector2(x + 48, 50), 40, PAPER)
	_txt(f_zh, "移动特供版", Vector2(x + 238, 47), 18, Color(PAPER, 0.7))
	# 地图标题
	_txt(f_zh, m["name"], Vector2(x, 128), 58, PAPER)
	_txt(f_num2, m["en"], Vector2(x + 4, 156), 22, accent)
	_txt(f_body, m["tag"], Vector2(x + 2, 186), 16, Color(PAPER, 0.85))
	var bk := "%s_%d" % [m["id"], Save.mode]
	var bs: float = Save.best.get(bk, 0.0)
	_txt(f_body, "全长 %s km   最佳 %s" % [m["km"], Score.fmt_num(int(bs)) if bs > 0 else "暂无"], Vector2(x + 2, 212), 15, Color(PAPER, 0.65))
	# 右上
	var rx := w - safe_r
	var rs := Rect2(rx - 108, 16, 96, 40)
	_skew(rs, Color(1, 1, 1, 0.28 if _b("settings", rs) else 0.12))
	_txt(f_zh, "设置", rs.get_center() + Vector2(4, 8), 21, PAPER, HORIZONTAL_ALIGNMENT_CENTER)
	var rh := Rect2(rx - 222, 16, 96, 40)
	_skew(rh, Color(1, 1, 1, 0.28 if _b("help", rh) else 0.12))
	_txt(f_zh, "操作", rh.get_center() + Vector2(4, 8), 21, PAPER, HORIZONTAL_ALIGNMENT_CENTER)
	# 车
	var c: Dictionary = GameData.cars[Save.car]
	var px := rx - 300
	_txt(f_num, c["name"], Vector2(px, 112), 44, PAPER)
	_txt(f_zh, c["cls"], Vector2(px + 2, 136), 19, accent)
	_txt(f_body, c["tag"], Vector2(px + 2, 160), 14, Color(PAPER, 0.8))
	var stats := [["极速", (float(c["top"]) - 250.0) / 135.0], ["加速", (float(c["accel"]) - 0.70) / 0.50], ["抓地", (float(c["grip"]) - 0.65) / 0.48], ["漂移", (float(c["drift"]) - 0.68) / 0.54]]
	for i in 4:
		var y := 184.0 + i * 22.0
		_txt(f_body, stats[i][0], Vector2(px + 2, y + 6), 14, Color(PAPER, 0.7))
		draw_rect(Rect2(px + 46, y - 4, 230, 8), Color(1, 1, 1, 0.14))
		draw_rect(Rect2(px + 46, y - 4, 230.0 * clampf(stats[i][1], 0.1, 1.0), 8), accent)
	for k in 2:
		var q := Rect2(px + k * 146, 274, 136, 42)
		var dn := _b("car:%d" % (-1 if k == 0 else 1), q)
		_skew(q, Color(1, 1, 1, 0.3 if dn else 0.12))
		_txt(f_zh, "‹ 上一辆" if k == 0 else "下一辆 ›", q.get_center() + Vector2(4, 8), 20, PAPER, HORIZONTAL_ALIGNMENT_CENTER)
	var np := GameData.PAINTS.size()
	for i in np:
		var pc := Vector2(px + 14 + i * 35.0, 344)
		draw_circle(pc, 13, GameData.PAINTS[i][4])
		if int(Save.paints[Save.car]) == i:
			draw_arc(pc, 17, 0, TAU, 32, PAPER, 2.5, true)
		_b("paint:%d" % i, Rect2(pc.x - 17, pc.y - 20, 34, 40))
	# 底部：地图卡
	var cw := minf(178.0, (w - safe_l - safe_r - 330.0 - 36.0) / 4.0)
	var cy := h - 128.0 - safe_b
	for i in GameData.MAPS.size():
		var r := Rect2(x + i * (cw + 12), cy, cw, 112)
		var sel := i == Save.map
		var dn := _b("map:%d" % i, r)
		if thumbs[i]:
			var tx: Texture2D = thumbs[i]
			var ar := r.size.x / r.size.y
			var ts := tx.get_size()
			var sw := ts.y * ar
			draw_texture_rect_region(tx, r, Rect2((ts.x - sw) * 0.5, 0, sw, ts.y), Color(1, 1, 1) if sel else Color(0.62, 0.62, 0.62))
		else:
			draw_rect(r, Color(GameData.MAPS[i]["accent"], 0.4))
		draw_polygon(PackedVector2Array([r.position + Vector2(0, 50), Vector2(r.end.x, r.position.y + 50), r.end, Vector2(r.position.x, r.end.y)]), PackedColorArray([Color(INK, 0), Color(INK, 0), Color(INK, 0.9), Color(INK, 0.9)]))
		_txt(f_zh, GameData.MAPS[i]["name"], Vector2(r.position.x + 10, r.end.y - 12), 23, PAPER)
		draw_rect(r, GameData.MAPS[i]["accent"] if sel else Color(1, 1, 1, 0.35 if dn else 0.16), false, 3.5 if sel else 1.5)
	# 选项
	var ow := 4 * cw + 36
	var oy := cy - 56
	_seg("weather", m["weathers"], Save.weather[Save.map], Rect2(x, oy, ow * 0.46, 40))
	_seg("mode", GameData.MODES, Save.mode, Rect2(x + ow * 0.49, oy, ow * 0.23, 40))
	_seg("assist", GameData.ASSISTS, Save.assist, Rect2(x + ow * 0.75, oy, ow * 0.25, 40))
	_txt(f_body, "天气", Vector2(x, oy - 8), 13, Color(PAPER, 0.6))
	_txt(f_body, "模式", Vector2(x + ow * 0.49, oy - 8), 13, Color(PAPER, 0.6))
	_txt(f_body, "操控手感", Vector2(x + ow * 0.75, oy - 8), 13, Color(PAPER, 0.6))
	# 开始
	var sr := Rect2(rx - 300, h - 128 - safe_b, 278, 72)
	var sd := _b("start", sr)
	_skew(sr, accent.lightened(0.25) if sd else accent)
	_txt(f_zh, "开始", sr.get_center() + Vector2(6, 14), 40, INK, HORIZONTAL_ALIGNMENT_CENTER)
	var ar2 := Rect2(rx - 300, h - 186 - safe_b, 278, 46)
	var ad := _b("auto", ar2)
	_skew(ar2, Color(PAPER, 0.95) if ad else Color(1, 1, 1, 0.16))
	_txt(f_zh, "自动漂移一圈", ar2.get_center() + Vector2(4, 9), 24, INK if ad else PAPER, HORIZONTAL_ALIGNMENT_CENTER)
	_txt(f_num2, "%d Hz" % int(main.perf.target), Vector2(rx - 22, h - 14 - safe_b), 15, Color(PAPER, 0.5), HORIZONTAL_ALIGNMENT_RIGHT)

func _row(y: float, title: String, desc: String, x: float) -> void:
	_txt(f_zh, title, Vector2(x, y + 22), 24, PAPER)
	_txt(f_body, desc, Vector2(x, y + 44), 13, Color(PAPER, 0.55))

func _draw_settings() -> void:
	var w := size.x
	var h := size.y
	draw_rect(Rect2(Vector2.ZERO, size), Color(0.02, 0.02, 0.03, 0.88))
	var x := maxf(safe_l + 20, w * 0.5 - 520)
	_txt(f_zh, "设置", Vector2(x, 62), 44, PAPER)
	_skew(Rect2(x, 74, 120, 4), accent, 0.5)
	var cx := x + 320
	var cw := 480.0
	var y := 96.0
	_row(y, "转向方式", "滑动：左半屏按住左右拖；重力：倾斜手机", x)
	_seg("set_steer", ["滑动", "按键", "重力"], Save.steer_mode, Rect2(cx, y, cw, 42))
	y += 62
	_row(y, "转向灵敏度", "%.2f" % Save.steer_sens, x)
	var sr := Rect2(cx, y + 6, cw, 30)
	_b("slider:sens", sr)
	draw_rect(Rect2(sr.position.x, sr.position.y + 12, sr.size.x, 6), Color(1, 1, 1, 0.18))
	var u := (Save.steer_sens - 0.5) / 1.5
	draw_rect(Rect2(sr.position.x, sr.position.y + 12, sr.size.x * u, 6), accent)
	draw_circle(Vector2(sr.position.x + sr.size.x * u, sr.position.y + 15), 14, PAPER)
	y += 62
	_row(y, "自动油门", "一直给油，只管方向、刹车和手刹", x)
	_seg("set_gas", ["关", "开"], int(Save.auto_throttle), Rect2(cx, y, cw * 0.6, 42))
	y += 62
	_row(y, "画质", "流畅最省电；动态分辨率会自动保住帧率", x)
	_seg("set_q", ["流畅", "均衡", "精致"], Save.quality, Rect2(cx, y, cw, 42))
	y += 62
	_row(y, "显示帧率", "右上角显示实时帧率和渲染分辨率", x)
	_seg("set_fps", ["关", "开"], int(Save.show_fps), Rect2(cx, y, cw * 0.6, 42))
	y += 62
	_row(y, "声音", "发动机、轮胎和提示音", x)
	_seg("set_snd", ["关", "开"], int(Save.sound), Rect2(cx, y, cw * 0.6, 42))
	y += 62
	_row(y, "震动", "撞击和漂移时震动", x)
	_seg("set_hap", ["关", "开"], int(Save.haptics), Rect2(cx, y, cw * 0.6, 42))
	var br := Rect2(x, h - 62 - safe_b, 160, 46)
	_skew(br, accent if _b("back", br) else PAPER)
	_txt(f_zh, "返回", br.get_center() + Vector2(4, 9), 24, INK, HORIZONTAL_ALIGNMENT_CENTER)
	var p: Perf = main.perf
	_txt(f_body, "屏幕刷新率 %d Hz · 不限制帧率 · 当前渲染分辨率 %d%%" % [int(p.target), int(p.scale * 100.0 + 0.5)], Vector2(w - safe_r - 20, h - 34 - safe_b), 14, Color(PAPER, 0.6), HORIZONTAL_ALIGNMENT_RIGHT)

func _big(id: String, label: String, r: Rect2, hot := false) -> void:
	var dn := _b(id, r)
	_skew(r, accent if (hot or dn) else Color(1, 1, 1, 0.14))
	_txt(f_zh, label, r.get_center() + Vector2(4, 10), 27, INK if (hot or dn) else PAPER, HORIZONTAL_ALIGNMENT_CENTER)

func _draw_pause() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), Color(0.02, 0.02, 0.03, 0.72))
	var c := size * 0.5
	_txt(f_zh, "暂停", c + Vector2(0, -170), 64, PAPER, HORIZONTAL_ALIGNMENT_CENTER)
	var ids := [["resume", "继续"], ["restart", "重新开始"], ["auto", "自动漂移一圈"], ["settings", "设置"], ["menu", "返回菜单"]]
	for i in ids.size():
		_big(ids[i][0], ids[i][1], Rect2(c.x - 170, c.y - 130 + i * 62, 330, 52), i == 0)

func _draw_result() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), Color(0.02, 0.02, 0.03, 0.78))
	var c := size * 0.5
	_txt(f_zh, "挑战结束", c + Vector2(0, -190), 46, PAPER, HORIZONTAL_ALIGNMENT_CENTER)
	_txt(f_num, Score.fmt_num(int(result.get("total", 0))), c + Vector2(0, -80), 110, accent, HORIZONTAL_ALIGNMENT_CENTER)
	if result.get("record", false):
		_txt(f_zh, "新纪录", c + Vector2(0, -40), 28, Color(1, 0.85, 0.3), HORIZONTAL_ALIGNMENT_CENTER)
	_txt(f_body, "最佳单次 %s    最大角度 %d°" % [Score.fmt_num(int(result.get("best", 0))), int(result.get("peak", 0))], c + Vector2(0, 6), 20, Color(PAPER, 0.85), HORIZONTAL_ALIGNMENT_CENTER)
	_big("restart", "再来一次", Rect2(c.x - 300, c.y + 60, 280, 60), true)
	_big("menu", "返回菜单", Rect2(c.x + 20, c.y + 60, 280, 60))

func _draw_help() -> void:
	var h := size.y
	draw_rect(Rect2(Vector2.ZERO, size), Color(0.02, 0.02, 0.03, 0.9))
	var x := maxf(safe_l + 20, size.x * 0.5 - 520)
	_txt(f_zh, "操作", Vector2(x, 62), 44, PAPER)
	_skew(Rect2(x, 74, 120, 4), accent, 0.5)
	var lines := ["左半屏：转向（滑动 / 按键 / 重力，可在设置里改）", "右半屏：油门、刹车（停住后再按是倒车）、手刹",
		"起漂：车速 30 以上，打方向 + 点一下手刹，然后踩住油门、方向继续往弯里打", "收漂：松开方向或反打，马上回正；连漂：反方向 + 再点手刹",
		"拟真手感：手刹 + 满方向按住就一直转，360°、720° 都行；松手自然收正", "自动漂移：每个弯都漂、带 360°，碰任意驾驶键接管，跑完一圈复位",
		"训练场：复位键原地扶正，1 秒内连按两次回起点并复原所有道具", "支持蓝牙手柄：左摇杆转向，RT 油门，LT 刹车，A 手刹"]
	for i in lines.size():
		_skew(Rect2(x, 112 + i * 48, 8, 22), accent, 0.3)
		_txt(f_body, lines[i], Vector2(x + 24, 130 + i * 48), 18, PAPER)
	var br := Rect2(x, h - 62 - safe_b, 160, 46)
	_skew(br, accent if _b("back", br) else PAPER)
	_txt(f_zh, "返回", br.get_center() + Vector2(4, 9), 24, INK, HORIZONTAL_ALIGNMENT_CENTER)
