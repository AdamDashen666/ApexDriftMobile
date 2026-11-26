class_name Droid
extends RefCounted
# 安卓专用的系统调用，经 Godot 自带的 AndroidRuntime 插件和 JavaClassWrapper 直接调 Java。
# 其他平台（iOS、桌面、CI）上 active 为 false，所有函数都是空操作。
#
# 高刷新率：Godot 4.7 自己不向系统声明想要的帧率，Android 15 起系统默认把游戏压在 60Hz，
# 必须对渲染用的 Surface 调 setFrameRate() 才会切到 90/120/144Hz（官方说明：
# developer.android.com/games/optimize/display-refresh-rate-change）。
# Godot 自带的 Swappy 帧节奏库会按“启动那一刻”的刷新率定死交换间隔并投票，启动时若是 60Hz 就一直 60，
# 所以 project.godot 里关掉了 Swappy（display/window/frame_pacing/android/enable_frame_pacing=false），由这里投票。
# 每个 Java 方法调用前都先 has_java_method 检查：方法不存在时直接调用会让整个函数报错中断。

static var active := false       # 在安卓上并且拿到了 Activity
static var sdk := 0              # Build.VERSION.SDK_INT
static var max_hz := 0.0         # 当前分辨率下屏幕支持的最高刷新率，拿不到为 0
static var vote_hz := 0.0        # 最近一次成功申请的刷新率，0 表示没申请成功
static var _act = null           # android.app.Activity（JavaObject）
static var _vote_t := -100.0
static var _tries := 0


static func init() -> void:
	if OS.get_name() != "Android" or not Engine.has_singleton("AndroidRuntime"):
		return
	var rt = Engine.get_singleton("AndroidRuntime")
	_act = rt.getActivity()
	if _act == null:
		return
	active = true
	var ver = JavaClassWrapper.wrap("android.os.Build$VERSION")
	if ver != null:
		sdk = int(_num(ver.get("SDK_INT")))
	max_hz = _max_refresh()
	print("[APEX] android sdk=%d 屏幕最高 %.1fHz 当前 %.1fHz" % [sdk, max_hz, DisplayServer.screen_get_refresh_rate()])


static func _num(v) -> float:
	return float(v) if (v is float or v is int) else 0.0


static func _has(o, m: String) -> bool:
	return o != null and o is Object and o.has_method("has_java_method") and o.has_java_method(m)


# 当前显示器（同一分辨率下）支持的最高刷新率；拿不到就返回 0
static func _max_refresh() -> float:
	if sdk < 30 or not _has(_act, "getDisplay"):
		return 0.0
	var d = _act.getDisplay()
	if not _has(d, "getSupportedModes"):
		return 0.0
	var best := _num(d.getRefreshRate())
	var cur = d.getMode()
	var modes = d.getSupportedModes()
	if _has(cur, "getPhysicalWidth") and modes is Array:
		var cw := int(_num(cur.getPhysicalWidth()))
		var ch := int(_num(cur.getPhysicalHeight()))
		for m in modes:
			if _has(m, "getRefreshRate") and int(_num(m.getPhysicalWidth())) == cw and int(_num(m.getPhysicalHeight())) == ch:
				best = maxf(best, _num(m.getRefreshRate()))
	_ok()
	return best


# 向系统申请屏幕最高刷新率。启动后、回到前台时强制申请；其余由 Perf 在刷新率偏低时调，
# 前 3 次间隔 3 秒，之后 30 秒一次（用户锁了 60Hz 时别一直刷日志）。
static func request_max_refresh(force := false) -> void:
	if not active or sdk < 30 or max_hz < 1.0:
		return
	var now := Time.get_ticks_msec() * 0.001
	if force:
		_tries = 0
	elif now - _vote_t < (3.0 if _tries < 3 else 30.0):
		return
	_tries += 1
	_vote_t = now
	var g = _act.getGodot() if _has(_act, "getGodot") else null
	var rv = g.getRenderView() if _has(g, "getRenderView") else null
	var sv = rv.getView() if _has(rv, "getView") else null
	if sv == null:
		print("[APEX] android 申请刷新率失败：拿不到渲染用的 SurfaceView")
		return
	var ok := false
	# 1) 直接对 Surface 投票（Android 11+；12 起第三个参数允许非无缝切换）
	var holder = sv.getHolder() if _has(sv, "getHolder") else null
	var surf = holder.getSurface() if _has(holder, "getSurface") else null
	if _has(surf, "setFrameRate") and surf.isValid():
		if sdk >= 31:
			surf.setFrameRate(max_hz, 0, 1)    # FRAME_RATE_COMPATIBILITY_DEFAULT, CHANGE_FRAME_RATE_ALWAYS
		else:
			surf.setFrameRate(max_hz, 0)
		ok = _ok()
	# 2) 再对 SurfaceView 的图层投一次（子图层继承），防第一种拿不到 Surface
	var sc = sv.getSurfaceControl() if _has(sv, "getSurfaceControl") else null
	if _has(sc, "isValid") and sc.isValid():
		var tcls = JavaClassWrapper.wrap("android.view.SurfaceControl$Transaction")
		var tr = tcls.call("SurfaceControl$Transaction") if tcls != null else null
		if _has(tr, "setFrameRate"):
			if sdk >= 31:
				tr.setFrameRate(sc, max_hz, 0, 1)
			else:
				tr.setFrameRate(sc, max_hz, 0)
			tr.apply()
			ok = _ok() or ok
	vote_hz = max_hz if ok else 0.0
	print("[APEX] android 申请 %.0fHz %s，当前 %.1fHz" % [max_hz, "成功" if ok else "失败", DisplayServer.screen_get_refresh_rate()])


# 看最近一次 Java 调用有没有抛异常（并清掉），正常返回 true
static func _ok() -> bool:
	var ex = JavaClassWrapper.get_exception()
	if ex != null:
		print("[APEX] android Java 异常：", ex)
		return false
	return true
