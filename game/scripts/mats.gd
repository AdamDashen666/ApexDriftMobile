class_name Mats
extends RefCounted
# 全部材质。少纹理、少采样：一条路面 2 次采样、地形 2 次采样、其余基本是顶点色

static var cache: Dictionary = {}

static func reset() -> void:
	cache.clear()

static func _shader(name: String, code: String) -> Shader:
	if not cache.has("sh_" + name):
		var s := Shader.new()
		s.code = code
		cache["sh_" + name] = s
	return cache["sh_" + name]

static func tex(name: String) -> Texture2D:
	return load("res://assets/tex/" + name)

const ROAD := """
shader_type spatial;
render_mode diffuse_lambert, specular_schlick_ggx;
uniform sampler2D detail : filter_linear_mipmap, repeat_enable;
uniform sampler2D macro_t : filter_linear_mipmap, repeat_enable;
uniform float wet = 0.0;
uniform float center_dash = 1.0;
uniform vec3 line_col = vec3(0.62, 0.62, 0.60);
void fragment() {
	float lat = (UV.x - 0.5) * 15.0;
	float s = UV.y * 15.0;
	float al = abs(lat);
	float d = texture(detail, UV * vec2(2.6, 2.6)).r;
	float m = texture(macro_t, UV * vec2(0.31, 0.43)).r;
	vec3 c = vec3(0.082, 0.083, 0.088) * (0.30 + d * 1.4) * (0.62 + m * 0.76);
	float rut = exp(-pow((al - 1.9) / 0.6, 2.0)) + exp(-pow((al - 4.6) / 0.6, 2.0));
	c *= 1.0 - rut * 0.10;
	c *= mix(1.0, 0.86, smoothstep(5.8, 7.4, al));
	float w = fwidth(lat) + 0.012;
	float edge = smoothstep(0.085 + w, 0.085, abs(al - 6.75));
	float dash = step(fract(s / 10.0), 0.5) * smoothstep(0.07 + w, 0.07, al) * center_dash;
	float yel = smoothstep(0.07 + w, 0.07, al) * (1.0 - center_dash);
	float wear = clamp(0.35 + d * 1.1, 0.0, 1.0);
	c = mix(c, line_col, clamp(edge + dash, 0.0, 1.0) * wear * 0.92);
	c = mix(c, vec3(0.62, 0.36, 0.05), yel * wear * 0.9);
	float pud = smoothstep(0.50, 0.62, m) * wet;
	float ww = clamp(wet * 0.55 + pud, 0.0, 1.0);
	ALBEDO = c * mix(1.0, 0.5, ww);
	ROUGHNESS = mix(mix(0.82, 0.92, d), 0.10, pud);
	ROUGHNESS = mix(ROUGHNESS, ROUGHNESS * 0.6, wet);
	SPECULAR = mix(0.32, 0.5, ww);
}
"""

const SHOULDER := """
shader_type spatial;
render_mode diffuse_lambert, specular_disabled;
uniform sampler2D detail : filter_linear_mipmap, repeat_enable;
uniform vec3 tint : source_color = vec3(0.44, 0.55, 0.22);
void fragment() {
	float al = abs((UV.x - 0.5) * 15.0);
	float d = texture(detail, UV * 5.0).r;
	vec3 conc = vec3(0.30, 0.295, 0.285) * (0.55 + d * 0.9);
	vec3 grav = vec3(0.23, 0.215, 0.185) * (0.45 + d * 1.1);
	vec3 gr = tint * (0.45 + d * 1.1);
	vec3 c = mix(conc, grav, smoothstep(8.3, 8.7, al));
	c = mix(c, gr, smoothstep(9.2, 10.2, al + (d - 0.5) * 1.6));
	ALBEDO = c;
	ROUGHNESS = 1.0;
}
"""

const TERRAIN := """
shader_type spatial;
render_mode diffuse_lambert, specular_disabled;
uniform sampler2D ground : source_color, filter_linear_mipmap, repeat_disable;
uniform sampler2D detail : filter_linear_mipmap, repeat_enable;
uniform float gain = 1.0;
varying vec3 wp;
void vertex() { wp = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz; }
void fragment() {
	vec3 g = texture(ground, UV).rgb;
	float d = texture(detail, wp.xz * 0.23).r;
	float f = clamp(1.0 - length(VERTEX) / 140.0, 0.0, 1.0);
	ALBEDO = g * gain * mix(1.0, 0.25 + d * 1.5, f * 0.85 + 0.1);
	ROUGHNESS = 1.0;
}
"""

const PAD := """
shader_type spatial;
render_mode diffuse_lambert, specular_schlick_ggx;
uniform sampler2D detail : filter_linear_mipmap, repeat_enable;
uniform sampler2D macro_t : filter_linear_mipmap, repeat_enable;
void fragment() {
	// UV = 世界坐标 / 10
	float d = texture(detail, UV * 1.9).r;
	float m = texture(macro_t, UV * 0.27).r;
	float b = texture(macro_t, UV.yx * 0.061).r;
	vec3 c = vec3(0.128, 0.130, 0.136) * (0.34 + d * 1.32) * (0.68 + m * 0.64) * (0.72 + b * 0.56);
	vec2 q = (0.5 - abs(fract(UV) - 0.5)) * 10.0;
	float px = fwidth(UV.x) * 10.0 + fwidth(UV.y) * 10.0;
	float seam = clamp(1.3 - min(q.x, q.y) / (0.012 + px * 0.6), 0.0, 1.0) * clamp(0.03 / max(px, 0.03), 0.0, 1.0);
	ALBEDO = c * (1.0 - 0.45 * seam);
	ROUGHNESS = 0.86;
	SPECULAR = 0.3;
}
"""

const VCOL := """
shader_type spatial;
render_mode diffuse_lambert, specular_schlick_ggx;
uniform float rough = 0.7;
uniform float spec = 0.35;
uniform float emit = 0.0;
uniform float raw = 0.0;
void fragment() {
	// glTF 顶点色导入时被编码成 sRGB，这里解回线性；代码里建的网格 raw=1
	vec3 c = mix(pow(COLOR.rgb, vec3(2.2)), COLOR.rgb, raw);
	ALBEDO = c;
	ROUGHNESS = rough;
	SPECULAR = spec;
	EMISSION = c * (1.0 - COLOR.a) * emit;
}
"""

const VCOL_FLAT := """
shader_type spatial;
render_mode diffuse_lambert, specular_disabled;
void fragment() { ALBEDO = pow(COLOR.rgb, vec3(2.2)); ROUGHNESS = 1.0; }
"""

const RAIL := """
shader_type spatial;
render_mode diffuse_lambert, specular_schlick_ggx, cull_disabled;
void fragment() { ALBEDO = pow(COLOR.rgb, vec3(2.2)); METALLIC = 0.35; ROUGHNESS = 0.45; SPECULAR = 0.4; }
"""

const MARKS := """
shader_type spatial;
render_mode diffuse_lambert, specular_disabled;
uniform sampler2D detail : filter_linear_mipmap, repeat_enable;
varying vec3 wp;
void vertex() { wp = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz; }
void fragment() { ALBEDO = max(pow(COLOR.rgb, vec3(2.2)), vec3(0.058)) * (0.62 + texture(detail, wp.xz * 0.25).r * 0.75); ROUGHNESS = 0.9; }
"""

const WATER := """
shader_type spatial;
render_mode diffuse_lambert, specular_schlick_ggx;
uniform vec3 deep = vec3(0.012, 0.055, 0.085);
varying vec3 wp;
void vertex() { wp = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz; }
void fragment() {
	float dist = length(VERTEX);
	float f = 1.0 / (1.0 + dist * 0.012);
	vec2 q = wp.xz;
	vec2 g = vec2(0.0);
	g += vec2(0.8, 0.6) * cos(dot(q, vec2(0.8, 0.6)) * 0.55 + TIME * 1.1) * 0.35;
	g += vec2(-0.5, 0.86) * cos(dot(q, vec2(-0.5, 0.86)) * 1.1 + TIME * 1.6) * 0.35;
	g += vec2(0.95, -0.3) * cos(dot(q, vec2(0.95, -0.3)) * 2.3 - TIME * 2.3) * 0.30;
	vec3 n = normalize(vec3(-g.x * 0.16 * f, 1.0, -g.y * 0.16 * f));
	NORMAL = normalize((VIEW_MATRIX * vec4(n, 0.0)).xyz);
	ALBEDO = deep;
	ROUGHNESS = mix(0.06, 0.22, clamp(dist / 900.0, 0.0, 1.0));
	SPECULAR = 0.6;
}
"""

const LEAF := """
shader_type spatial;
render_mode cull_disabled, diffuse_lambert_wrap, specular_disabled;
uniform sampler2D tex : source_color, filter_linear_mipmap, repeat_disable;
uniform float wind = 1.0;
varying vec3 tint;
void vertex() {
	tint = INSTANCE_CUSTOM.r > 0.0 ? INSTANCE_CUSTOM.rgb : vec3(1.0);
	vec3 w = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	float s = sin(TIME * 1.7 + w.x * 0.35 + w.z * 0.27) + 0.5 * sin(TIME * 3.1 + w.z * 0.8);
	VERTEX.xz += vec2(s, s * 0.6) * 0.055 * COLOR.a * wind;
}
void fragment() {
	vec4 t = texture(tex, UV);
	ALBEDO = t.rgb * tint * COLOR.rgb;
	if (!FRONT_FACING) NORMAL = -NORMAL;
	ALPHA = t.a * (1.0 + max(0.0, 0.5 * log2(max(dot(dFdx(UV) * vec2(textureSize(tex, 0)), dFdx(UV) * vec2(textureSize(tex, 0))), 0.0001))) * 0.22);
	ALPHA_SCISSOR_THRESHOLD = 0.42;
	ROUGHNESS = 1.0;
	BACKLIGHT = t.rgb * tint * 0.25;
}
"""

const IMPOSTOR := """
shader_type spatial;
render_mode cull_disabled, diffuse_lambert_wrap, specular_disabled;
uniform sampler2D tex : source_color, filter_linear_mipmap, repeat_disable;
uniform float gain = 1.18;
void vertex() {
	vec4 r = INSTANCE_CUSTOM;
	UV = r.xy + vec2((UV.x * 0.5 + UV2.x * 0.5) * r.z, UV.y * r.w);
}
void fragment() {
	vec4 t = texture(tex, UV);
	ALBEDO = t.rgb * gain * COLOR.rgb;
	if (!FRONT_FACING) NORMAL = -NORMAL;
	ALPHA = t.a * (1.0 + max(0.0, 0.5 * log2(max(dot(dFdx(UV) * vec2(textureSize(tex, 0)), dFdx(UV) * vec2(textureSize(tex, 0))), 0.0001))) * 0.25);
	ALPHA_SCISSOR_THRESHOLD = 0.38;
	ROUGHNESS = 1.0;
}
"""

const GRASS := """
shader_type spatial;
render_mode cull_disabled, diffuse_lambert_wrap, specular_disabled;
uniform vec3 base : source_color = vec3(0.30, 0.42, 0.14);
uniform vec3 tip : source_color = vec3(0.55, 0.68, 0.28);
void vertex() {
	vec3 w = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	float h = COLOR.r;
	VERTEX.xz += vec2(sin(TIME * 2.1 + w.x * 0.8 + w.z * 0.6)) * 0.07 * h * h;
	NORMAL = vec3(0.0, 1.0, 0.0);
}
void fragment() {
	if (!FRONT_FACING) NORMAL = -NORMAL;
	ALBEDO = mix(base, tip, COLOR.r);
	ROUGHNESS = 1.0;
}
"""

const SMOKE := """
shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, shadows_disabled, blend_mix;
uniform sampler2D tex : filter_linear_mipmap, repeat_disable;
uniform vec3 lit : source_color = vec3(0.86, 0.88, 0.92);
varying float fade;
void vertex() {
	// 实例自定义：图格号, 透明度, 旋转, 大小
	vec4 c = INSTANCE_CUSTOM;
	float cell = floor(c.x);
	UV = (UV + vec2(mod(cell, 4.0), floor(cell / 4.0))) * 0.25;
	float a = c.z;
	vec2 q = VERTEX.xy * c.w;
	q = vec2(q.x * cos(a) - q.y * sin(a), q.x * sin(a) + q.y * cos(a));
	vec3 ctr = (MODEL_MATRIX * vec4(0.0, 0.0, 0.0, 1.0)).xyz;
	vec3 v = (VIEW_MATRIX * vec4(ctr, 1.0)).xyz + vec3(q, 0.0);
	POSITION = PROJECTION_MATRIX * vec4(v, 1.0);
	// 深度往镜头方向挪，插进路面的那半截不会切出硬边
	vec4 nearer = PROJECTION_MATRIX * vec4(v.xy, min(v.z + c.w * 0.9, -0.3), 1.0);
	POSITION.z = nearer.z / nearer.w * POSITION.w;
	fade = c.y;
}
void fragment() {
	vec4 t = texture(tex, UV);
	ALBEDO = lit * (0.62 + 0.5 * t.r);
	ALPHA = t.a * fade;
}
"""

const SKID := """
shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, shadows_disabled, blend_mix;
void fragment() {
	float e = smoothstep(0.0, 0.18, UV.x) * smoothstep(1.0, 0.82, UV.x);
	float tread = 0.8 + 0.2 * step(0.5, fract(UV.x * 5.0));
	ALBEDO = vec3(0.012);
	ALPHA = COLOR.a * e * tread;
}
"""

const SKY := """
shader_type sky;
uniform sampler2D hi : filter_linear, repeat_enable;
uniform sampler2D lo : filter_linear, repeat_enable;
uniform float k = 1.0;
uniform float gain = 1.0;
uniform float sun_az = 0.0;
uniform vec3 horizon : source_color = vec3(0.6, 0.75, 0.95);
uniform float haze = 0.10;
uniform float haze_k = 0.75;
uniform float warm = 0.0;
void sky() {
	float az = atan(EYEDIR.z, EYEDIR.x);
	float u = fract(0.5 + (az - sun_az) / 6.2831853);
	float v = acos(clamp(EYEDIR.y, -1.0, 1.0)) / 3.14159265;
	if (AT_CUBEMAP_PASS) {
		COLOR = textureLod(lo, vec2(fract(u + 0.25), v), 0.0).rgb * gain;
	} else {
		vec3 c = textureLod(hi, vec2(u, min(v / 0.56, 0.995)), 0.0).rgb;
		c = pow(c, vec3(2.2)) * k * gain;
		float g = (0.5 + 0.5 * cos(az - sun_az));
		g = g * g * smoothstep(0.62, 0.0, EYEDIR.y) + 0.35 * smoothstep(0.25, 0.0, EYEDIR.y);
		float l = max(dot(c, vec3(0.3, 0.6, 0.1)), 0.30);
		c = mix(c, vec3(1.55, 0.78, 0.36) * l, clamp(g * warm, 0.0, 0.85));
		float h = smoothstep(haze, -0.02, EYEDIR.y);
		COLOR = mix(c, horizon, h * haze_k);
	}
}
"""

static func make(name: String, code: String, params: Dictionary = {}) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = _shader(name, code)
	for key in params:
		m.set_shader_parameter(key, params[key])
	return m

static func car_mats(paint: int, car_id: String) -> Dictionary:
	var pt: Array = GameData.PAINTS[paint]
	var d := {}
	d["Paint"] = std(pt[1], pt[2], pt[3], 0.6)
	d["Accent"] = std(Color(0.018, 0.018, 0.020), 0.1, 0.3, 0.5)
	d["Dark"] = std(Color(0.016, 0.016, 0.017), 0.0, 0.65, 0.3)
	d["Carbon"] = std(Color(0.010, 0.010, 0.011), 0.1, 0.28, 0.5)
	d["Metal"] = std(Color(0.55, 0.55, 0.57), 1.0, 0.28, 0.5)
	d["Rim"] = std(Color(0.16, 0.165, 0.175), 0.9, 0.32, 0.5)
	d["Glass"] = std(Color(0.006, 0.008, 0.010), 0.0, 0.04, 0.7)
	d["Tire"] = std(Color(0.012, 0.012, 0.012), 0.0, 0.88, 0.25)
	d["Caliper"] = std(Color(0.55, 0.03, 0.02), 0.2, 0.4, 0.5)
	d["Plate"] = std(Color(0.72, 0.72, 0.70), 0.0, 0.5, 0.4)
	var h := std(Color(0.85, 0.88, 0.92), 0.0, 0.2, 0.5)
	h.emission_enabled = true
	h.emission = Color(1.0, 0.97, 0.9)
	h.emission_energy_multiplier = 0.8
	d["Head"] = h
	var t := std(Color(0.35, 0.01, 0.01), 0.0, 0.25, 0.5)
	t.emission_enabled = true
	t.emission = Color(1.0, 0.05, 0.03)
	t.emission_energy_multiplier = 0.5
	d["Tail"] = t
	for s in ["bake", "notbake", "chassis", "motor", "top", "wheels"]:
		var f := "res://assets/tex/car_%s_%s.jpg" % [car_id.to_lower(), s]
		if ResourceLoader.exists(f):
			var m := std(Color(1, 1, 1), 0.25, 0.5, 0.5)
			m.albedo_texture = load(f)
			d["Tex_" + s] = m
	if d.has("Tex_top"):
		var m2: StandardMaterial3D = d["Tex_top"].duplicate()
		var c: Color = pt[1]
		m2.albedo_color = Color(minf(1.0, c.r * 1.5 + 0.10), minf(1.0, c.g * 1.5 + 0.10), minf(1.0, c.b * 1.5 + 0.10))
		d["Tex_toppaint"] = m2
	return d

static func std(c: Color, metal: float, rough: float, spec: float) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c.linear_to_srgb()
	m.metallic = metal
	m.roughness = rough
	m.metallic_specular = spec
	m.vertex_color_use_as_albedo = true
	m.vertex_color_is_srgb = true
	return m
