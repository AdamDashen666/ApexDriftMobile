extends Node3D
# 主流程

enum St { BOOT, MENU, COUNT, PLAY, PAUSE, RESULT }

var st: int = St.BOOT
var world: World
var car: Car
var cam: Cam
var fx: Fx
var sfx: Sfx
var ui: Ui
var perf: Perf
var score := Score.new()
var count := 0.0
var last_count := 0
var auto_pending := false
var last_reset := -10.0
var drift_prev := false
var loaded_map := -1
var auto_cache: Dictionary = {}
var testing := false
var external := false        # 测试脚本直接控车

func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	GameData.load_all()
	testing = args.size() > 0
	Save.persist = not testing
	if not testing:
		Save.load_cfg()
	print("[APEX] method=%s driver=%s adapter=%s refresh=%.1f max_fps=%d size=%s" % [
		RenderingServer.get_current_rendering_method(), RenderingServer.get_current_rendering_driver_name(), RenderingServer.get_video_adapter_name(),
		DisplayServer.screen_get_refresh_rate(), Engine.max_fps, str(DisplayServer.window_get_size())])
	perf = Perf.new()
	add_child(perf)
	perf.setup(Save.quality)
	car = Car.new()
	add_child(car)
	cam = Cam.new()
	cam.car = car
	cam.near = 0.15
	cam.far = 22000.0
	add_child(cam)
	fx = Fx.new()
	fx.car = car
	add_child(fx)
	sfx = Sfx.new()
	sfx.car = car
	sfx.enabled = Save.sound
	add_child(sfx)
	var layer := CanvasLayer.new()
	add_child(layer)
	ui = Ui.new()
	ui.main = self
	layer.add_child(ui)
	ui.action.connect(_on_action)
	car.impact.connect(_on_impact)
	car.spin_done.connect(func(): score.spin())
	score.callout.connect(func(s: String, k: int): ui.show_callout(s, k))
	score.cue.connect(func(n: String): sfx.play(n, -6.0))
	car.set_car(Save.car, int(Save.paints[Save.car]))
	get_tree().root.size_changed.connect(func(): ui._safe())
	for a in args:
		if a == "--autotest":
			_autotest()
			return
		if a == "--bench":
			_bench()
			return
		if a.begins_with("--shots="):
			_shots(a.substr(8))
			return
	await get_tree().process_frame
	await get_tree().process_frame
	load_map(Save.map)
	goto_menu()
	Save.store()

func free_map() -> bool:
	return world != null and world.meta.get("free", false)

func load_map(i: int) -> void:
	if world != null and loaded_map == i:
		world.set_weather(int(Save.weather[i]))
		_light_fx()
		return
	if world != null:
		world.queue_free()
		remove_child(world)
		world = null
	Save.map = i
	world = World.new()
	world.quality = Save.quality
	add_child(world)
	world.load_map(GameData.MAPS[i]["id"])
	world.set_weather(int(Save.weather[i]))
	world.set_quality(Save.quality)
	loaded_map = i
	car.track = world.track
	car.wall_lat = float(world.meta.get("wall", 0.0))
	car.free_roam = free_map()
	car.bound_half = 484.0 if free_map() else 0.0
	ui.set_map(world.track, world.meta)
	ui.accent = GameData.MAPS[i]["accent"]
	_light_fx()
	fx.clear()
	place_at_start()

func _light_fx() -> void:
	var n: bool = world.wx["night"]
	fx.set_light(Color(0.40, 0.42, 0.48) if n else Color(0.90, 0.91, 0.94).lerp(world.wx["color"], 0.4))
	if car.head_l:
		car.head_l.visible = n
	if car.mats.has("Head"):
		car.mats["Head"].emission_energy_multiplier = 3.5 if n else 0.8

func place_at_start() -> void:
	if car.auto != null:
		car.stop_auto(false)
	var s: Array = world.meta["start"]
	car.teleport(Vector3(s[0], float(s[1]) + 0.06, s[2]), float(world.meta["start_yaw"]))
	cam.snap()

func goto_menu() -> void:
	st = St.MENU
	ui.screen = "menu"
	car.locked = true
	place_at_start()
	score.reset()
	if world.dyn_bodies.size() > 0:
		_reset_props()
	fx.clear()
	cam.orbit = true
	sfx.set_engine(false)
	Engine.time_scale = 1.0
	get_tree().paused = false

func start_race(auto: bool) -> void:
	st = St.COUNT
	ui.screen = "play"
	cam.orbit = false
	cam.director = false
	Engine.time_scale = 1.0
	place_at_start()
	if world.dyn_bodies.size() > 0:
		_reset_props()
	fx.clear()
	score.reset()
	car.assist = Save.assist
	car.locked = true
	auto_pending = auto
	count = 3.0
	last_count = 4
	ui.touches.clear()
	ui.hint_t = 0.0
	sfx.set_engine(Save.sound)
	if auto:
		_plan_auto()

func _plan_auto() -> AutoRun:
	var key := "%d_%d" % [Save.map, Save.car]
	var a := AutoRun.new()
	var s: Array = world.meta["start"]
	a.space = get_world_3d().direct_space_state
	if auto_cache.has(key):
		var o: AutoRun = auto_cache[key]
		for f in ["track", "n", "total", "line", "kap", "vplan", "psi_base", "tt", "spins", "lap_time", "drift_frac", "vmax"]:
			a.set(f, o.get(f))
		a._rp.collision_mask = 1
		a._y = a.line[0].y
		a._place(0.0)
	else:
		a.prepare(world.track, car.info, Vector3(s[0], s[1], s[2]), 4.4)
		auto_cache[key] = a
	a.spin_started.connect(func(): score.spin())
	return a

func begin_auto() -> void:
	var a := _plan_auto()
	car.start_auto(a)
	cam.director = Save.director
	cam.snap()

func _physics_process(dt: float) -> void:
	if world == null:
		return
	match st:
		St.COUNT:
			count -= dt
			var n := int(ceil(count))
			if n != last_count and n >= 1 and n <= 3:
				last_count = n
				sfx.play("SFX_UI_Countdown", -6.0)
			if count <= 0.0:
				count = 0.0
				st = St.PLAY
				ui.go_t = 0.0
				sfx.play("SFX_UI_Go", -4.0)
				car.locked = false
				if auto_pending:
					auto_pending = false
					begin_auto()
		St.PLAY:
			if not external:
				_drive_input()
			score.update(dt, car, world.track, free_map())
			if car.auto != null and car.auto.done:
				_auto_finished()
			if Save.mode == 1 and car.auto == null and score.time >= 180.0 and not testing:
				_finish()
			if car.flip_t > 2.2 and not external:
				reset_car()
			if car.global_position.y < world.track.q_y - 40.0 or car.global_position.y < -60.0 and free_map():
				place_at_start()
			_drift_haptic()
	if ui:
		ui.count = count if st == St.COUNT else 0.0

func _drive_input() -> void:
	if car.auto != null:
		if ui.any_drive_input() and car.auto.t > 0.6:
			car.stop_auto(true)
			cam.director = false
			ui.show_callout("已接管，自动漂移取消", 0)
		return
	car.in_throttle = ui.thr_out
	car.in_brake = ui.brk_out
	car.in_steer = ui.steer_out
	car.in_hand = ui.hand_out

func _drift_haptic() -> void:
	if car.drift_on and not drift_prev and Save.haptics and not testing:
		Input.vibrate_handheld(18)
	drift_prev = car.drift_on

func _auto_finished() -> void:
	var lap := car.auto.t
	var sp := car.auto.spins_done
	car.stop_auto(false)
	cam.director = false
	place_at_start()
	if world.dyn_bodies.size() > 0:
		_reset_props()
	score.reset()
	ui.show_callout("自动漂移完成 %s · 360° x%d" % [Score.fmt_time(lap), sp], 1)

func _finish() -> void:
	score.bank()
	st = St.RESULT
	var key := "%s_%d" % [GameData.MAPS[Save.map]["id"], Save.mode]
	var rec := Save.record(key, float(score.total))
	ui.result = {"total": score.total, "best": score.best, "peak": score.peak, "record": rec}
	ui.screen = "result"
	car.locked = true
	sfx.set_engine(false)

# 车可能正压在道具上：先复位一次，等车真正挪走（两个物理帧）再复位一次
func _reset_props() -> void:
	var w := world
	w.reset_props()
	await get_tree().physics_frame
	await get_tree().physics_frame
	if is_instance_valid(w) and w == world:
		w.reset_props()

func reset_car() -> void:
	var now := Time.get_ticks_msec() * 0.001
	if car.auto != null:
		car.stop_auto(false)
		cam.director = false
	score.bank()
	if free_map():
		if now - last_reset < 1.2:
			last_reset = -10.0
			place_at_start()
			_reset_props()
			return
		last_reset = now
		var p := car.global_position
		var q := PhysicsRayQueryParameters3D.create(p + Vector3(0, 2.5, 0), p - Vector3(0, 200, 0), 1)
		var h := get_world_3d().direct_space_state.intersect_ray(q)
		var y: float = h.position.y if not h.is_empty() else p.y
		car.teleport(Vector3(p.x, y + 0.1, p.z), car.heading())
	else:
		world.track.query(car.global_position, car.hint)
		var tr := world.track
		var pt := tr.point(tr.q_s, clampf(tr.q_lat, -4.0, 4.0))
		car.teleport(pt + Vector3(0, 0.1, 0), atan2(tr.q_dir.y, tr.q_dir.x))
	cam.snap()

func _on_impact(strength: float, pos: Vector3, is_prop: bool) -> void:
	if is_prop:
		sfx.play("SFX_Impact_Graze", clampf(-16.0 + strength * 6.0, -18.0, -4.0), randf_range(0.9, 1.15))
		score.prop_hit()
		if Save.haptics and strength > 0.6 and not testing:
			Input.vibrate_handheld(12)
		return
	score.wall(strength)
	sfx.play("SFX_Impact_Heavy" if strength > 6.0 else "SFX_Impact_Graze", clampf(-14.0 + strength * 1.4, -14.0, 0.0))
	fx.burst(pos, strength)
	cam.kick(clampf(strength * 0.08, 0.0, 0.8))
	if Save.haptics and strength > 1.5 and not testing:
		Input.vibrate_handheld(int(clampf(15.0 + strength * 5.0, 15.0, 70.0)))

func _process(_dt: float) -> void:
	if world != null and car != null:
		world.follow(car.visual_xf().origin)

func _set_paused(p: bool) -> void:
	if p:
		st = St.PAUSE
		ui.screen = "pause"
		Engine.time_scale = 0.0
		sfx.set_engine(false)
	else:
		Engine.time_scale = 1.0
		st = St.COUNT if count > 0.0 else St.PLAY
		ui.screen = "play"
		ui.touches.clear()
		sfx.set_engine(Save.sound)

func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_PAUSED or what == NOTIFICATION_APPLICATION_FOCUS_OUT:
		if ui != null and not testing and (st == St.PLAY or st == St.COUNT):
			_set_paused(true)
	elif what == NOTIFICATION_WM_GO_BACK_REQUEST:
		if ui != null and (st == St.PLAY or st == St.COUNT):
			_set_paused(true)

func _on_action(id: String) -> void:
	sfx.play("SFX_UI_Click", -10.0)
	var p := id.split(":")
	var v := int(p[1]) if p.size() > 1 else 0
	match p[0]:
		"start": start_race(false)
		"auto": start_race(true)
		"map":
			if v != Save.map or loaded_map != v:
				Save.map = v
				ui.accent = GameData.MAPS[v]["accent"]
				ui.msg = "正在载入 " + String(GameData.MAPS[v]["name"])
				ui.screen = "loading"
				await get_tree().process_frame
				await get_tree().process_frame
				load_map(v)
				goto_menu()
				Save.store()
		"weather":
			Save.weather[Save.map] = v
			world.set_weather(v)
			_light_fx()
			Save.store()
		"mode":
			Save.mode = v
			Save.store()
		"assist":
			Save.assist = v
			Save.store()
		"car":
			Save.car = posmod(Save.car + v, GameData.cars.size())
			car.set_car(Save.car, int(Save.paints[Save.car]))
			_light_fx()
			Save.store()
		"paint":
			Save.paints[Save.car] = v
			car.set_paint(v)
			Save.store()
		"settings":
			ui.back_to = ui.screen
			ui.screen = "settings"
		"help":
			ui.back_to = ui.screen
			ui.screen = "help"
		"back": ui.screen = ui.back_to
		"credits": ui.screen = "credits"
		"back2": ui.screen = "settings"
		"pause": _set_paused(true)
		"resume": _set_paused(false)
		"restart": start_race(false)
		"menu": goto_menu()
		"reset":
			if st == St.PLAY:
				reset_car()
		"cam": cam.mode = (cam.mode + 1) % 3
		"director":
			Save.director = not Save.director
			cam.director = Save.director
			Save.store()
		"set_steer":
			Save.steer_mode = v
			Save.store()
		"set_gas":
			Save.auto_throttle = v == 1
			Save.store()
		"set_q":
			Save.quality = v
			world.set_quality(v)
			world._petals()
			perf.setup(v)
			Save.store()
		"set_fps":
			Save.show_fps = v == 1
			Save.store()
		"set_snd":
			Save.sound = v == 1
			sfx.enabled = Save.sound
			if st == St.PLAY or st == St.COUNT:
				sfx.set_engine(Save.sound)
			Save.store()
		"set_hap":
			Save.haptics = v == 1
			Save.store()

# ------------------------------------------------------------------ 自动测试（CI，无界面）
var fails := 0

func _ck(ok: bool, msg: String) -> void:
	print(("  ok   " if ok else "  FAIL ") + msg)
	if not ok:
		fails += 1

func ticks(n: int) -> void:
	for i in n:
		await get_tree().physics_frame

func hold(sec: float, th: float, br: float, steer: float, hand: bool) -> void:
	car.in_throttle = th
	car.in_brake = br
	car.in_steer = steer
	car.in_hand = hand
	await ticks(int(sec * 120.0))

func _autotest() -> void:
	external = true
	Save.sound = false
	sfx.enabled = false
	await ticks(3)
	for mi in GameData.MAPS.size():
		var t0 := Time.get_ticks_msec()
		load_map(mi)
		print("== ", GameData.MAPS[mi]["id"], " 载入 ", Time.get_ticks_msec() - t0, "ms 节点 ", world.get_child_count())
		st = St.PLAY
		car.locked = true
		place_at_start()
		await ticks(150)
		world.track.query(car.global_position, -1)
		_ck(car.grounded == 4 and absf(car.global_position.y - world.track.q_y) < 0.25 and car.speed < 0.3, "静置：着地 %d 高差 %.3f 车速 %.2f" % [car.grounded, car.global_position.y - world.track.q_y, car.speed])
		car.locked = false
		# 自动漂移整圈
		var ta := Time.get_ticks_msec()
		score.reset()
		begin_auto()
		var plan_ms := Time.get_ticks_msec() - ta
		var a := car.auto
		var maxlat := 0.0
		var bad := false
		var ymin := 1e9
		var gap := 0.0
		for i in 120 * 200:
			await get_tree().physics_frame
			if car.auto == null or a.done:
				break
			if i % 4 == 0:
				world.track.query(a.xf.origin, -1 if i % 40 == 0 else car.hint)
				maxlat = maxf(maxlat, absf(world.track.q_lat))
				gap = maxf(gap, absf(a.xf.origin.y - world.track.q_y))
				if not a.xf.origin.is_finite() or not a.xf.basis.is_finite():
					bad = true
		_ck(not bad and a.done and maxlat < 6.5 and gap < 0.6, "自动一圈：完成=%s 用时 %.1fs 最高 %.0fkm/h 漂移占比 %d%% 360=%d/%d 最大横偏 %.1fm 高差 %.2f 规划 %dms 得分 %d" % [a.done, a.t, a.vmax * 3.6, int(a.drift_frac * 100), a.spins_done, a.spins.size(), maxlat, gap, plan_ms, score.total + int(score.current)])
		_ck(a.spins.size() >= 2, "自动 360 次数 %d" % a.spins.size())
		await ticks(30)
		_ck(car.auto == null and car.speed < 1.0, "自动跑完复位：车速 %.2f" % car.speed)
		# 起步直线
		place_at_start()
		await ticks(30)
		await hold(3.0, 1, 0, 0, false)
		_ck(car.kmh > 85.0, "3 秒加速到 %.0f" % car.kmh)
		# 撞墙：满舵开 6 秒，不出护墙、不翻、不 NaN
		await hold(6.0, 1, 0, 1, false)
		world.track.query(car.global_position, -1)
		_ck(car.global_position.is_finite() and (free_map() or absf(world.track.q_lat) < 9.2) and car.global_transform.basis.y.y > 0.5, "乱开：横偏 %.1f 竖直 %.2f 车速 %.0f" % [world.track.q_lat, car.global_transform.basis.y.y, car.kmh])
	# ---- 操控（训练场平地）
	for asst in 3:
		for ci in [0, 2, 6]:
			car.set_car(ci, 0)
			car.assist = asst
			var tag := "%s/%s" % [GameData.ASSISTS[asst], car.info["name"]]
			car.teleport(Vector3(-290, 0.1, -345), 0.0, Vector3(30, 0, 0))
			await hold(0.3, 1, 0, 0, false)
			var mx := 0.0
			for i in 120:
				car.in_steer = -0.3
				car.in_throttle = 0.8
				await get_tree().physics_frame
				mx = maxf(mx, absf(car.beta))
			_ck(mx < 5.0, "%s 小舵量最大侧滑 %.1f°" % [tag, mx])
			await hold(0.8, 1, 0, 0, false)
			_ck(absf(car.beta) < 2.0, "%s 松方向后侧滑 %.1f°" % [tag, car.beta])
			car.teleport(Vector3(-290, 0.1, -345), 0.0, Vector3(34, 0, 0))
			await hold(0.2, 1, 0, 0, false)
			if asst < 2:
				await hold(0.35, 1, 0, -1, true)
				var mxd := 0.0
				for i in 240:
					car.in_steer = -0.8
					car.in_throttle = 1.0
					car.in_hand = false
					await get_tree().physics_frame
					mxd = maxf(mxd, car.slip_deg)
				var on := car.drift_on
				var tz := 0.0
				while tz < 3.0:
					car.in_steer = 0.0
					await get_tree().physics_frame
					tz += 1.0 / 120.0
					if absf(car.beta) < 3.0 and not car.drift_on:
						break
				_ck(on and mxd > 22.0 and mxd < 70.0 and tz < 1.6, "%s 漂移角 %.0f° 保持=%s 松方向 %.2fs 回正 车速 %.0f" % [tag, mxd, on, tz, car.kmh])
			else:
				var spun := 0.0
				var pv := car.heading()
				for i in 108:
					car.in_steer = 1.0
					car.in_throttle = 1.0
					car.in_hand = true
					await get_tree().physics_frame
					spun += rad_to_deg(wrapf(car.heading() - pv, -PI, PI))
					pv = car.heading()
				var tz2 := 0.0
				car.in_hand = false
				car.in_steer = 0.0
				while tz2 < 4.0:
					await get_tree().physics_frame
					spun += rad_to_deg(wrapf(car.heading() - pv, -PI, PI))
					pv = car.heading()
					tz2 += 1.0 / 120.0
					if absf(car.beta) < 4.0 and not car.sim_free:
						break
				_ck(spun > 270.0 and tz2 < 3.5, "%s 手刹 0.9s 车头转过 %.0f°，松手 %.2fs 收正" % [tag, spun, tz2])
	car.set_car(0, 0)
	car.assist = 0
	# 倒车
	car.teleport(Vector3(-300, 0.1, 20), 0.0)
	await ticks(60)
	await hold(1.5, 0, 1, 0, false)
	_ck(car.reverse and car.linear_velocity.x < -2.0, "倒车 %.1f m/s" % car.linear_velocity.x)
	await hold(1.2, 1, 0, 0, false)
	_ck(car.linear_velocity.x > 1.0, "倒车后前进 %.1f m/s" % car.linear_velocity.x)
	# 坡道
	for r in [["08 度", -190.0, 330.0, 0.0, 160.0, 5.0], ["20 度", -190.0, 270.0, 0.0, 150.0, 6.0], ["28 度", -190.0, 240.0, 0.0, 140.0, 6.5], ["断桥", -190.0, 180.0, 0.0, 110.0, 5.5], ["波浪", -190.0, 150.0, 0.0, 100.0, 6.0], ["超级跳台", -260.0, -265.0, 0.0, 190.0, 8.0], ["金字塔", -112.0, -170.0, 90.0, 90.0, 5.0], ["立交桥", 78.0, -110.0, 90.0, 100.0, 6.0]]:
		var yaw := deg_to_rad(r[3])
		var v := Vector3(cos(yaw), 0, sin(yaw)) * float(r[4]) / 3.6
		car.teleport(Vector3(r[1], 0.1, r[2]), yaw, v)
		var air := 0.0
		var top := 0.0
		var minup := 1.0
		for i in int(float(r[5]) * 120.0):
			car.in_throttle = 1.0 if car.kmh < float(r[4]) else 0.3
			car.in_steer = clampf(wrapf(yaw - car.heading(), -PI, PI) * 3.0, -0.5, 0.5)
			await get_tree().physics_frame
			if car.grounded < 2:
				air += 1.0 / 120.0
			top = maxf(top, car.global_position.y)
			minup = minf(minup, car.global_transform.basis.y.y)
		_ck(minup > 0.35 and car.global_transform.basis.y.y > 0.8 and car.global_position.y > -0.6, "坡道 %s：腾空 %.2fs 最高 %.1fm 最小竖直 %.2f 结束竖直 %.2f 车速 %.0f" % [r[0], air, top, minup, car.global_transform.basis.y.y, car.kmh])
	# 撞道具
	world.reset_props()
	await ticks(60)
	var still := world.moved_props()
	car.teleport(Vector3(60, 0.1, -10), 0.0, Vector3(38, 0, 0))
	await hold(3.0, 1, 0, 0, false)
	var mv := world.moved_props()
	_ck(still == 0 and mv >= 6 and car.global_transform.basis.y.y > 0.8, "撞箱墙：静置移动 %d，撞动 %d，车速 %.0f 竖直 %.2f" % [still, mv, car.kmh, car.global_transform.basis.y.y])
	# 车还压在箱堆里，走真实的“连按两次复位”
	car.teleport(Vector3(125, 0.1, -10), 0.0)
	await ticks(30)
	st = St.PLAY
	_on_action("reset")
	await ticks(4)
	_on_action("reset")
	await ticks(60)
	_ck(world.moved_props() == 0, "连按两次复位：道具复原 %d" % world.moved_props())
	_ck(car.global_position.distance_to(Vector3(125, 0.1, -10)) > 20.0, "连按两次复位：回到起点 %s" % str(car.global_position))
	# 存档写读一遍（平时测试不落盘）
	var keep := [Save.map, Save.car, Save.paints.duplicate(), Save.weather.duplicate(), Save.best.duplicate(), Save.steer_sens]
	Save.persist = true
	Save.path = "user://apex_test.cfg"
	Save.map = 2
	Save.car = 3
	Save.paints[3] = 6
	Save.weather[2] = 1
	Save.steer_sens = 1.35
	Save.best = {"FujiSakura_0": 12345.0}
	Save.store()
	Save.map = 0
	Save.car = 0
	Save.paints = [0, 0, 0, 0, 0, 0, 0]
	Save.weather = [0, 0, 0, 0]
	Save.best = {}
	Save.steer_sens = 1.0
	Save.load_cfg()
	_ck(Save.map == 2 and Save.car == 3 and int(Save.paints[3]) == 6 and int(Save.weather[2]) == 1 and is_equal_approx(Save.steer_sens, 1.35) and is_equal_approx(float(Save.best.get("FujiSakura_0", 0.0)), 12345.0), "存档写读")
	Save.persist = false
	Save.map = keep[0]
	Save.car = keep[1]
	Save.paints = keep[2]
	Save.weather = keep[3]
	Save.best = keep[4]
	Save.steer_sens = keep[5]
	# 界面：所有按钮走一遍
	external = false
	for sid in ["help", "back", "settings", "credits", "back2", "set_steer:1", "set_steer:2", "set_steer:0", "set_gas:1", "set_gas:0", "set_q:0", "set_q:2", "set_q:1", "set_fps:0", "set_fps:1", "set_hap:0", "set_hap:1", "back", "car:1", "car:-1", "paint:3", "mode:1", "mode:0", "assist:2", "assist:0", "weather:1", "weather:2", "weather:0"]:
		_on_action(sid)
		await ticks(2)
	_on_action("map:0")
	await ticks(8)
	_ck(st == St.MENU and loaded_map == 0, "菜单换图 %d" % loaded_map)
	_on_action("start")
	await ticks(120 * 4)
	_ck(st == St.PLAY and not car.locked, "开赛倒计时")
	_on_action("pause")
	await get_tree().process_frame
	_ck(st == St.PAUSE, "暂停")
	_on_action("resume")
	await ticks(10)
	_ck(st == St.PLAY, "继续")
	# 触控：按油门 + 左滑
	var e := InputEventScreenTouch.new()
	e.index = 0
	e.pressed = true
	e.position = ui._rects()["gas"][0]
	ui._input(e)
	var e2 := InputEventScreenTouch.new()
	e2.index = 1
	e2.pressed = true
	e2.position = Vector2(200, 400)
	ui._input(e2)
	var d := InputEventScreenDrag.new()
	d.index = 1
	d.position = Vector2(280, 400)
	ui._input(d)
	await ticks(60)
	_ck(ui.thr_out > 0.9 and ui.steer_out > 0.6 and car.in_throttle > 0.9, "触控：油门 %.1f 方向 %.2f" % [ui.thr_out, ui.steer_out])
	e.pressed = false
	ui._input(e)
	e2.pressed = false
	ui._input(e2)
	await ticks(4)
	_ck(ui.thr_out < 0.1 and absf(ui.steer_out) < 0.05, "松手归零")
	_on_action("auto")
	await ticks(120 * 3 + 200)
	_ck(car.auto != null, "菜单启动自动漂移")
	e.pressed = true
	ui._input(e)
	await ticks(10)
	_ck(car.auto == null, "碰油门接管")
	e.pressed = false
	ui._input(e)
	_on_action("menu")
	await ticks(5)
	print("AUTOTEST %s fails=%d" % ["PASS" if fails == 0 else "FAIL", fails])
	get_tree().quit(0 if fails == 0 else 1)

# ------------------------------------------------------------------ 截图（CI，软件 Vulkan）
func _cap(dir: String, name: String, frames := 6) -> void:
	for i in frames:
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_jpg("%s/%s.jpg" % [dir, name], 0.9)
	print("[APEX] shot ", name, " draws=", Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME), " prims=", Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME), " objs=", Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME))

# 实时跑分（CI 的 macOS，Metal + Mobile 渲染器，关垂直同步）：看每帧 CPU / GPU 耗时
func _bench() -> void:
	external = true
	sfx.enabled = false
	Save.sound = false
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	# 3D 像素数对齐 iPhone 均衡档（约 1731x800）
	var ws := DisplayServer.window_get_size()
	perf.fixed_scale = clampf(sqrt(1385000.0 / float(ws.x * ws.y)), 0.5, 2.0)
	perf.apply()
	var rid := get_viewport().get_viewport_rid()
	RenderingServer.viewport_set_measure_render_time(rid, true)
	for mi in 4:
		load_map(mi)
		goto_menu()
		st = St.PLAY
		ui.screen = "play"
		cam.orbit = false
		car.locked = false
		ui.count = 0.0
		begin_auto()
		for i in 90:
			await get_tree().process_frame
		var dts: Array[float] = []
		var rc := 0.0
		var rg := 0.0
		var t0 := Time.get_ticks_usec()
		var last := t0
		while Time.get_ticks_usec() - t0 < 15000000:
			await get_tree().process_frame
			var now := Time.get_ticks_usec()
			dts.append((now - last) / 1000.0)
			last = now
			rc += RenderingServer.viewport_get_measured_render_time_cpu(rid) + RenderingServer.get_frame_setup_time_cpu()
			rg += RenderingServer.viewport_get_measured_render_time_gpu(rid)
		var n := dts.size()
		var sum := 0.0
		for d in dts:
			sum += d
		dts.sort()
		print("[BENCH] %s 帧数 %d 平均 %.2fms(%.0ffps) 中位 %.2f 99%% %.2f 最差 %.1f | 渲染CPU %.2f GPU %.2f | 窗口 %s 3D 比例 %.2f draws %d" % [GameData.MAPS[mi]["id"], n, sum / n, 1000.0 * n / sum, dts[n / 2], dts[int(n * 0.99)], dts[n - 1], rc / n, rg / n, str(DisplayServer.window_get_size()), perf.fixed_scale, int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME))])
		car.stop_auto(false)
	get_tree().quit(0)

func _shots(dir: String) -> void:
	external = true
	sfx.enabled = false
	Save.sound = false
	perf.fixed_scale = 1.0
	perf.apply()
	await get_tree().process_frame
	var plan := [[0, 0, [9.0, 22.0, 40.0]], [1, 0, [8.0, 30.0]], [2, 0, [12.0, 34.0]], [3, 0, [3.0, 20.0]]]
	for pl in plan:
		var mi: int = pl[0]
		var t0 := Time.get_ticks_msec()
		Save.car = [0, 5, 4, 1][mi]
		car.set_car(Save.car, int(Save.paints[Save.car]))
		load_map(mi)
		print("[APEX] load ", GameData.MAPS[mi]["id"], " ", Time.get_ticks_msec() - t0, "ms")
		goto_menu()
		cam.orbit_yaw = 2.4
		await _cap(dir, "menu_%d" % mi, 8)
		st = St.PLAY
		ui.screen = "play"
		cam.orbit = false
		car.locked = false
		ui.count = 0.0
		begin_auto()
		cam.director = false
		var k := 0
		for sec in pl[2]:
			car.auto.seek(sec)
			cam.snap()
			score.drifting = true
			score.current = 18650.0
			score.mult = 3.5
			await _cap(dir, "map%d_%d" % [mi, k], 26)
			k += 1
		car.stop_auto(false)
		if mi == 3:
			# 坡道与道具
			car.assist = 2
			for c in [[-100.0, 270.0, 0.0, 40.0], [-110.0, -265.0, 0.0, 45.0], [125.0, -10.0, 0.0, 34.0], [-60.0, 402.0, 0.0, 10.0]]:
				car.teleport(Vector3(c[0], 0.1, c[1]), c[2], Vector3(c[3], 0, 0))
				cam.snap()
				car.in_throttle = 1.0
				car.in_steer = 0.0
				await _cap(dir, "train_%d" % int(c[0] + 500), 30)
			# 手动漂移 + 触控 HUD
			car.assist = 0
			car.teleport(Vector3(-290, 0.1, -345), 0.0, Vector3(33, 0, 0))
			cam.snap()
			ui.thr_out = 1.0
			ui.steer_out = -0.8
			for q in 70:
				car.in_throttle = 1.0
				car.in_steer = -1.0 if q < 14 else -0.8
				car.in_hand = q < 14
				ui.touches[0] = {"pos": ui._rects()["gas"][0], "start": ui._rects()["gas"][0], "role": "gas"}
				ui.touches[1] = {"pos": Vector2(150, 470), "start": Vector2(220, 470), "role": "steer"}
				await get_tree().physics_frame
			await _cap(dir, "hud_drift", 2)
			ui.touches.clear()
		if mi < 3:
			for wi in [1, 2]:
				Save.weather[mi] = wi
				world.set_weather(wi)
				_light_fx()
				begin_auto()
				cam.director = false
				car.auto.seek(10.0)
				cam.snap()
				await _cap(dir, "map%d_w%d" % [mi, wi], 22)
				car.stop_auto(false)
		else:
			for wi in [1, 2]:
				Save.weather[mi] = wi
				world.set_weather(wi)
				_light_fx()
				car.teleport(Vector3(-100, 0.1, 285), 0.0, Vector3(20, 0, 0))
				cam.snap()
				await _cap(dir, "map%d_w%d" % [mi, wi], 22)
	ui.back_to = "menu"
	ui.screen = "settings"
	await _cap(dir, "ui_settings", 3)
	ui.screen = "help"
	await _cap(dir, "ui_help", 3)
	ui.screen = "credits"
	await _cap(dir, "ui_credits", 3)
	ui.screen = "pause"
	await _cap(dir, "ui_pause", 3)
	get_tree().quit(0)
