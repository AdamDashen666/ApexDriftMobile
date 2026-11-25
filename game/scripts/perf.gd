class_name Perf
extends Node
# 动态分辨率：盯着屏幕刷新率，掉帧先降 3D 分辨率，稳定一段时间再试着升回来。
# 不设帧率上限：Engine.max_fps = 0，iOS 由 CADisplayLink 按屏幕最高刷新率驱动。

var target := 120.0
var scale := 1.0
var lo := 0.45
var hi := 1.0
var fixed_scale := 0.0       # >0 表示手动
var fps := 0.0
var low_fps := 0.0
var _acc := 0.0
var _n := 0
var _slow := 0
var _good := 0.0
var _cool := 2.0
var _cap := 1.0              # 升过头掉帧后，记住上限一段时间
var _cap_t := 0.0
var _worst := 0.0
var quality := 1
var native := 120.0         # 屏幕最高刷新率
var _lock := 0.0
var step := 0                # 兜底档：1 关抗锯齿 2 再降分辨率 3 关阴影
var _stuck := 0.0
signal step_changed

func setup(q: int) -> void:
	quality = q
	var r := DisplayServer.screen_get_refresh_rate()
	target = r if r > 20.0 and r < 500.0 else 60.0
	native = target
	Engine.max_fps = 0
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_ENABLED)
	var h := float(DisplayServer.window_get_size().y)
	# 起步分辨率：按画质给目标行数
	var rows: float = [640.0, 800.0, 1080.0][q]
	hi = clampf(rows / maxf(h, 1.0), 0.40, 1.0)
	lo = clampf([430.0, 520.0, 640.0][q] / maxf(h, 1.0), 0.30, hi)
	scale = hi
	_cap = hi
	_cool = 2.0
	step = 0
	_stuck = 0.0
	step_changed.emit()
	apply()

func apply() -> void:
	var vp := get_viewport()
	vp.scaling_3d_mode = Viewport.SCALING_3D_MODE_BILINEAR
	vp.scaling_3d_scale = fixed_scale if fixed_scale > 0.0 else scale
	vp.msaa_3d = Viewport.MSAA_DISABLED if step >= 1 else [Viewport.MSAA_DISABLED, Viewport.MSAA_2X, Viewport.MSAA_4X][quality]

func _process(dt: float) -> void:
	if dt <= 0.0:
		return
	_acc += dt
	_n += 1
	_worst = maxf(_worst, dt)
	if dt > 1.35 / target:
		_slow += 1
	if _acc >= 0.5:
		fps = _n / _acc
		low_fps = 1.0 / _worst
		_decide()
		_acc = 0.0
		_n = 0
		_slow = 0
		_worst = 0.0

func _decide() -> void:
	if fixed_scale > 0.0:
		return
	# 低电量模式会把高刷屏锁在 60：降到最低分辨率还是稳稳 60，就按 60 跑、把画质还回来
	if target > 100.0 and scale <= lo + 0.01 and absf(fps - 60.0) < 1.5 and low_fps > 48.0:
		_lock += 0.5
		if _lock >= 3.0:
			target = 60.0
			_lock = 0.0
			_cap_t = 0.0
			_cap = hi
	else:
		_lock = 0.0
	# 最低分辨率还掉帧：逐级关掉贵的东西，保帧率
	var steady60 := absf(fps - 60.0) < 1.5 and low_fps > 48.0
	if scale <= lo + 0.01 and fps < target * 0.93 and not (steady60 and target > 100.0):
		_stuck += 0.5
		if _stuck >= 3.0 and step < 3:
			_stuck = 0.0
			step += 1
			if step == 2:
				lo *= 0.8
			step_changed.emit()
			apply()
	else:
		_stuck = maxf(0.0, _stuck - 0.5)
	if target < native and fps > target * 1.2:
		target = native
	_cool -= 0.5
	_cap_t = maxf(0.0, _cap_t - 0.5)
	if _cap_t <= 0.0:
		_cap = hi
	if _cool > 0.0:
		return
	if fps < target * 0.93:
		_good = 0.0
		if scale > lo + 0.01:
			_cap = maxf(lo, scale - 0.02)
			_cap_t = 25.0
			scale = maxf(lo, scale - (0.10 if fps < target * 0.75 else 0.05))
			_cool = 1.0
			apply()
	elif fps > target * 0.975 and _slow <= 1:
		_good += 0.5
		if _good >= 4.0 and scale < _cap - 0.01:
			scale = minf(_cap, scale + 0.04)
			_good = 0.0
			_cool = 1.0
			apply()
	else:
		_good = 0.0
