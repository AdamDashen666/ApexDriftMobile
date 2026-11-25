extends Node3D
# 探针版：确认渲染器、刷新率、导出链路

var shots := ""
var t := 0.0
var n := 0

func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--shots="):
			shots = a.substr(8)
		if a == "--autotest":
			print("AUTOTEST PASS")
			get_tree().quit(0)
			return
	print("[APEX] method=%s driver=%s adapter=%s api=%s refresh=%.1f max_fps=%d vsync=%d size=%s" % [
		RenderingServer.get_current_rendering_method(), RenderingServer.get_current_rendering_driver_name(),
		RenderingServer.get_video_adapter_name(), RenderingServer.get_video_adapter_api_version(),
		DisplayServer.screen_get_refresh_rate(), Engine.max_fps, DisplayServer.window_get_vsync_mode(), str(DisplayServer.window_get_size())])
	var env := WorldEnvironment.new()
	env.environment = Environment.new()
	env.environment.background_mode = Environment.BG_COLOR
	env.environment.background_color = Color(0.45, 0.62, 0.85)
	env.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.environment.ambient_light_color = Color(0.6, 0.7, 0.8)
	add_child(env)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-45, 40, 0)
	sun.shadow_enabled = true
	add_child(sun)
	var cam := Camera3D.new()
	cam.position = Vector3(-6, 2.6, 3.5)
	add_child(cam)
	cam.look_at(Vector3(0, 0.5, 0))
	var g := MeshInstance3D.new()
	g.mesh = PlaneMesh.new()
	g.mesh.size = Vector2(60, 60)
	add_child(g)
	var car: Node3D = load("res://assets/cars/HeroCar.glb").instantiate()
	add_child(car)
	for c in car.find_children("*", "MeshInstance3D"):
		print("[APEX] mesh ", c.name, " surfaces ", c.mesh.get_surface_count(), " aabb ", c.mesh.get_aabb())

func _process(d: float) -> void:
	t += d
	n += 1
	if n == 30 and shots != "":
		await RenderingServer.frame_post_draw
		get_viewport().get_texture().get_image().save_png(shots + "/probe.png")
		print("[APEX] shot saved fps=", Engine.get_frames_per_second())
		get_tree().quit(0)
