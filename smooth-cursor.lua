-- Smooth Cursor для OBS Studio (Windows).
-- Фильтр для «Захвата экрана»: рисует сглаженный курсор вместо системного
-- и приближает картинку, следуя за курсором (в духе Screen Studio).

obs = obslua
local ffi = require("ffi")
local bit = require("bit")

local SCRIPT_DIR = script_path()
local FILTER_ID = "smooth_cursor_filter"
local HOTKEY_NAME = "smooth_cursor.toggle_zoom"

-- Хотспоты заданы в пикселях холста 128x128, см. tools/gen-cursors.ps1
local CURSORS = {
	arrow = { files = { [0] = "arrow-dark.png", [1] = "arrow-light.png" }, hot = { 30 / 128, 12 / 128 } },
	hand = { files = { [0] = "hand.png", [1] = "hand.png" }, hot = { 57.5 / 128, 12 / 128 } },
	ibeam = { files = { [0] = "ibeam.png", [1] = "ibeam.png" }, hot = { 0.5, 0.5 } },
}

-- Ключ настройки «захватывать курсор» у источников, которые умеет прятать фильтр
local CURSOR_SETTING = {
	monitor_capture = "capture_cursor",
	window_capture = "cursor",
	game_capture = "capture_cursor",
}

pcall(ffi.cdef, [[
typedef struct { long x, y; } SC_POINT;
typedef struct { long left, top, right, bottom; } SC_RECT;
typedef struct { unsigned long cbSize, flags; void *hCursor; SC_POINT pos; } SC_CURSORINFO;
typedef int (__stdcall *SC_MONITORENUMPROC)(void *, void *, SC_RECT *, intptr_t);
int GetCursorInfo(SC_CURSORINFO *);
int GetCursorPos(SC_POINT *);
void *LoadCursorW(void *, uintptr_t);
short GetAsyncKeyState(int);
int EnumDisplayMonitors(void *, const SC_RECT *, SC_MONITORENUMPROC, intptr_t);
]])
local user32 = ffi.load("user32")

local H_IBEAM = user32.LoadCursorW(nil, 32513)
local H_HAND = user32.LoadCursorW(nil, 32649)

local EFFECT = [[
uniform float4x4 ViewProj;
uniform texture2d image;
uniform texture2d cursor_tex;

uniform float2 src_size;
uniform float2 cam_center;
uniform float cam_scale;

uniform float2 cursor_px;
uniform float cursor_size;
uniform float2 cursor_hot;
uniform float2 cursor_rot;
uniform float2 blur_px;
uniform float cursor_alpha;
uniform float reject_r;

sampler_state linear_clamp {
	Filter = Linear;
	AddressU = Clamp;
	AddressV = Clamp;
};

struct VertData {
	float4 pos : POSITION;
	float2 uv : TEXCOORD0;
};

VertData VSDefault(VertData v_in)
{
	VertData vert_out;
	vert_out.pos = mul(float4(v_in.pos.xyz, 1.0), ViewProj);
	vert_out.uv = v_in.uv;
	return vert_out;
}

float4 PSDraw(VertData v_in) : TARGET
{
	float2 uv = (v_in.uv - 0.5) * cam_scale + cam_center;
	float4 base = image.Sample(linear_clamp, uv);
	float2 d0 = uv * src_size - cursor_px;
	float4 acc = float4(0.0, 0.0, 0.0, 0.0);

	if (cursor_alpha > 0.0 && dot(d0, d0) < reject_r * reject_r) {
		// 16 выборок: вдоль вектора движения (motion blur) + сетка 2x2 внутри пикселя (сглаживание)
		for (int i = 0; i < 16; i++) {
			float fi = float(i);
			float t = (fi + 0.5) / 16.0 - 0.5;
			float2 jit = float2(fmod(fi, 2.0) - 0.5, fmod(floor(fi * 0.5), 2.0) - 0.5) * 0.5 * cam_scale;
			float2 d = d0 + jit + blur_px * t;
			float2 r = float2(d.x * cursor_rot.x + d.y * cursor_rot.y, d.y * cursor_rot.x - d.x * cursor_rot.y);
			float2 c = r / cursor_size + cursor_hot;
			float inside = step(0.0, c.x) * step(c.x, 1.0) * step(0.0, c.y) * step(c.y, 1.0);
			float4 s = cursor_tex.SampleLevel(linear_clamp, c, 0);
			s.a *= inside;
			acc.rgb += s.rgb * s.a;
			acc.a += s.a;
		}
		acc *= cursor_alpha / 16.0;
	}

	return float4(base.rgb * (1.0 - acc.a) + acc.rgb, base.a);
}

technique Draw
{
	pass
	{
		vertex_shader = VSDefault(v_in);
		pixel_shader = PSDraw(v_in);
	}
}
]]

local PARAM_NAMES = {
	"cursor_tex", "src_size", "cam_center", "cam_scale", "cursor_px", "cursor_size",
	"cursor_hot", "cursor_rot", "blur_px", "cursor_alpha", "reject_r",
}

local g_manual_zoom = false
local g_hotkey_id = nil

local function clamp(v, lo, hi)
	if lo > hi then return (lo + hi) * 0.5 end
	if v < lo then return lo end
	if v > hi then return hi end
	return v
end

local function new_spring(p)
	return { p = p, v = 0 }
end

-- Пружина с демпфированием; шаг дробится, чтобы не разваливаться на просадках FPS
local function spring_step(s, target, k, c, dt)
	local n = math.max(1, math.ceil(dt / 0.004))
	local h = dt / n
	for _ = 1, n do
		s.v = s.v + (-k * (s.p - target) - c * s.v) * h
		s.p = s.p + s.v * h
	end
end

local function critical(k)
	return 2 * math.sqrt(k)
end

local function enum_monitors()
	local list = {}
	local cb = ffi.cast("SC_MONITORENUMPROC", function(_, _, rc, _)
		list[#list + 1] = { x = rc.left, y = rc.top, w = rc.right - rc.left, h = rc.bottom - rc.top }
		return 1
	end)
	user32.EnumDisplayMonitors(nil, nil, cb, 0)
	cb:free()
	return list
end
-- ffi-колбэк нельзя вызывать из JIT-скомпилированного кода
jit.off(enum_monitors)

local function pick_monitor(data, w, h)
	local list = data.monitors
	if list[data.monitor] then return list[data.monitor] end
	local primary
	for _, m in ipairs(list) do
		if m.w == w and m.h == h then return m end
		if m.x == 0 and m.y == 0 then primary = m end
	end
	return primary or { x = 0, y = 0, w = w, h = h }
end

local cursor_info = ffi.new("SC_CURSORINFO")
local cursor_point = ffi.new("SC_POINT")

local function key_down(vk)
	return bit.band(user32.GetAsyncKeyState(vk), 0x8000) ~= 0
end

-- Возвращает x, y (экранные), visible, kind, down
local function poll_cursor()
	local x, y, visible, kind = 0, 0, true, "arrow"
	cursor_info.cbSize = ffi.sizeof(cursor_info)
	if user32.GetCursorInfo(cursor_info) ~= 0 then
		x, y = cursor_info.pos.x, cursor_info.pos.y
		visible = bit.band(cursor_info.flags, 1) ~= 0
		if cursor_info.hCursor == H_HAND then
			kind = "hand"
		elseif cursor_info.hCursor == H_IBEAM then
			kind = "ibeam"
		end
	elseif user32.GetCursorPos(cursor_point) ~= 0 then
		x, y = cursor_point.x, cursor_point.y
	else
		return nil
	end
	return x, y, visible, kind, key_down(0x01) or key_down(0x02)
end

local function free_images(data)
	obs.obs_enter_graphics()
	for _, img in pairs(data.images) do
		obs.gs_image_file_free(img)
	end
	obs.obs_leave_graphics()
	data.images = {}
end

local function load_images(data, style)
	free_images(data)
	for kind, def in pairs(CURSORS) do
		local path = SCRIPT_DIR .. "cursors/" .. def.files[style]
		local img = obs.gs_image_file()
		obs.gs_image_file_init(img, path)
		obs.obs_enter_graphics()
		obs.gs_image_file_init_texture(img)
		obs.obs_leave_graphics()
		if img.loaded then
			data.images[kind] = img
		else
			obs.blog(obs.LOG_WARNING, "[smooth-cursor] не удалось загрузить " .. path)
		end
	end
	data.loaded_style = style
end

-- Прячет/возвращает системный курсор в источнике, на котором висит фильтр
local function apply_system_cursor(data)
	if data.hide_system == data.hide_applied then return end
	local parent = obs.obs_filter_get_parent(data.source)
	if parent == nil then return end
	local key = CURSOR_SETTING[obs.obs_source_get_unversioned_id(parent)]
	if key then
		local s = obs.obs_data_create()
		obs.obs_data_set_bool(s, key, not data.hide_system)
		obs.obs_source_update(parent, s)
		obs.obs_data_release(s)
	end
	data.hide_applied = data.hide_system
end

local source_info = {}
source_info.id = FILTER_ID
source_info.type = obs.OBS_SOURCE_TYPE_FILTER
source_info.output_flags = obs.OBS_SOURCE_VIDEO

source_info.get_name = function()
	return "Плавный курсор (Smooth Cursor)"
end

source_info.create = function(settings, source)
	local data = {
		source = source,
		width = 0,
		height = 0,
		images = {},
		params = {},
		vec = obs.vec2(),
		time = 0,
		started = false,
		cur = { x = new_spring(0), y = new_spring(0) },
		press = new_spring(1),
		zoom = new_spring(1),
		cam = { x = new_spring(0), y = new_spring(0) },
		cam_tx = 0,
		cam_ty = 0,
		zoom_on = false,
		last_click = nil,
		alpha = 0,
		angle = 0,
		kind = "arrow",
		monitors = nil,
		monitors_age = 0,
		hide_applied = false,
		frame = nil,
	}

	obs.obs_enter_graphics()
	data.effect = obs.gs_effect_create(EFFECT, "smooth_cursor_effect", nil)
	obs.obs_leave_graphics()
	if data.effect == nil then
		obs.blog(obs.LOG_ERROR, "[smooth-cursor] не удалось скомпилировать шейдер")
		return nil
	end
	for _, name in ipairs(PARAM_NAMES) do
		data.params[name] = obs.gs_effect_get_param_by_name(data.effect, name)
	end

	source_info.update(data, settings)
	return data
end

source_info.destroy = function(data)
	free_images(data)
	if data.effect ~= nil then
		obs.obs_enter_graphics()
		obs.gs_effect_destroy(data.effect)
		obs.obs_leave_graphics()
		data.effect = nil
	end
end

source_info.get_width = function(data)
	return data.width
end

source_info.get_height = function(data)
	return data.height
end

source_info.get_defaults = function(settings)
	obs.obs_data_set_default_int(settings, "cursor_style", 0)
	obs.obs_data_set_default_int(settings, "cursor_size", 64)
	obs.obs_data_set_default_double(settings, "tension", 170)
	obs.obs_data_set_default_double(settings, "friction", 26)
	obs.obs_data_set_default_double(settings, "click_scale", 0.8)
	obs.obs_data_set_default_double(settings, "blur", 0.8)
	obs.obs_data_set_default_double(settings, "tilt", 0)
	obs.obs_data_set_default_bool(settings, "hide_system", true)
	obs.obs_data_set_default_double(settings, "zoom_level", 2.0)
	obs.obs_data_set_default_bool(settings, "auto_zoom", true)
	obs.obs_data_set_default_double(settings, "zoom_hold", 2.5)
	obs.obs_data_set_default_double(settings, "zoom_speed", 100)
	obs.obs_data_set_default_double(settings, "follow_speed", 50)
	obs.obs_data_set_default_double(settings, "dead_zone", 0.4)
	obs.obs_data_set_default_int(settings, "monitor", 0)
end

source_info.get_properties = function()
	local props = obs.obs_properties_create()

	local style = obs.obs_properties_add_list(props, "cursor_style", "Стиль курсора",
		obs.OBS_COMBO_TYPE_LIST, obs.OBS_COMBO_FORMAT_INT)
	obs.obs_property_list_add_int(style, "Тёмный (как в macOS)", 0)
	obs.obs_property_list_add_int(style, "Светлый (как в Windows)", 1)

	obs.obs_properties_add_int_slider(props, "cursor_size", "Размер курсора, px", 24, 256, 1)
	obs.obs_properties_add_float_slider(props, "tension", "Жёсткость пружины (выше — быстрее догоняет)", 20, 600, 1)
	obs.obs_properties_add_float_slider(props, "friction", "Трение (ниже — больше инерции)", 5, 60, 0.5)
	obs.obs_properties_add_float_slider(props, "click_scale", "Сжатие при клике", 0.5, 1.0, 0.01)
	obs.obs_properties_add_float_slider(props, "blur", "Размытие в движении", 0, 2, 0.05)
	obs.obs_properties_add_float_slider(props, "tilt", "Наклон при движении, °", 0, 30, 0.5)
	obs.obs_properties_add_bool(props, "hide_system", "Скрыть системный курсор в источнике")

	obs.obs_properties_add_float_slider(props, "zoom_level", "Приближение, x (1 — выключено)", 1, 5, 0.05)
	obs.obs_properties_add_bool(props, "auto_zoom", "Приближать автоматически при клике")
	obs.obs_properties_add_float_slider(props, "zoom_hold", "Держать приближение после клика, с", 0.5, 10, 0.1)
	obs.obs_properties_add_float_slider(props, "zoom_speed", "Скорость приближения", 20, 300, 1)
	obs.obs_properties_add_float_slider(props, "follow_speed", "Скорость следования камеры", 10, 300, 1)
	obs.obs_properties_add_float_slider(props, "dead_zone", "Мёртвая зона камеры (доля кадра)", 0, 0.9, 0.01)

	local mon = obs.obs_properties_add_list(props, "monitor", "Монитор",
		obs.OBS_COMBO_TYPE_LIST, obs.OBS_COMBO_FORMAT_INT)
	obs.obs_property_list_add_int(mon, "Авто (по размеру источника)", 0)
	for i, m in ipairs(enum_monitors()) do
		obs.obs_property_list_add_int(mon, string.format("%d: %dx%d @ %d,%d", i, m.w, m.h, m.x, m.y), i)
	end

	return props
end

source_info.update = function(data, settings)
	data.cursor_size = obs.obs_data_get_int(settings, "cursor_size")
	data.tension = obs.obs_data_get_double(settings, "tension")
	data.friction = obs.obs_data_get_double(settings, "friction")
	data.click_scale = obs.obs_data_get_double(settings, "click_scale")
	data.blur = obs.obs_data_get_double(settings, "blur")
	data.tilt = math.rad(obs.obs_data_get_double(settings, "tilt"))
	data.hide_system = obs.obs_data_get_bool(settings, "hide_system")
	data.zoom_level = obs.obs_data_get_double(settings, "zoom_level")
	data.auto_zoom = obs.obs_data_get_bool(settings, "auto_zoom")
	data.zoom_hold = obs.obs_data_get_double(settings, "zoom_hold")
	data.zoom_speed = obs.obs_data_get_double(settings, "zoom_speed")
	data.follow_speed = obs.obs_data_get_double(settings, "follow_speed")
	data.dead_zone = obs.obs_data_get_double(settings, "dead_zone")
	data.monitor = obs.obs_data_get_int(settings, "monitor")
	data.monitors = nil

	local style = obs.obs_data_get_int(settings, "cursor_style")
	if style ~= data.loaded_style then
		load_images(data, style)
	end
end

source_info.video_tick = function(data, seconds)
	data.frame = nil

	local target = obs.obs_filter_get_target(data.source)
	if target == nil then return end
	local w = obs.obs_source_get_base_width(target)
	local h = obs.obs_source_get_base_height(target)
	if w == 0 or h == 0 then return end
	if w ~= data.width or h ~= data.height then
		data.width, data.height = w, h
		data.started = false
	end

	apply_system_cursor(data)

	local dt = math.min(seconds, 0.1)
	data.time = data.time + dt

	data.monitors_age = data.monitors_age + dt
	if data.monitors == nil or data.monitors_age > 3 then
		data.monitors = enum_monitors()
		data.monitors_age = 0
	end
	local mon = pick_monitor(data, w, h)

	local sx, sy, visible, kind, down = poll_cursor()
	if sx == nil then return end
	local tx = (sx - mon.x) * w / mon.w
	local ty = (sy - mon.y) * h / mon.h
	local inside = tx >= 0 and ty >= 0 and tx < w and ty < h

	local cur, cam = data.cur, data.cam
	if not data.started then
		cur.x.p, cur.y.p, cur.x.v, cur.y.v = tx, ty, 0, 0
		cam.x.p, cam.y.p, cam.x.v, cam.y.v = w / 2, h / 2, 0, 0
		data.cam_tx, data.cam_ty = w / 2, h / 2
		data.started = true
	end

	-- курсор
	spring_step(cur.x, tx, data.tension, data.friction, dt)
	spring_step(cur.y, ty, data.tension, data.friction, dt)

	local pressed = down and inside
	if pressed then data.last_click = data.time end
	spring_step(data.press, pressed and data.click_scale or 1, 500, 26, dt)

	if visible then data.kind = kind end
	local alpha_target = (visible and inside) and 1 or 0
	data.alpha = data.alpha + (alpha_target - data.alpha) * math.min(1, dt * 14)

	local tilt_target = clamp(cur.x.v / 1800, -1, 1) * data.tilt
	data.angle = data.angle + (tilt_target - data.angle) * math.min(1, dt * 10)

	-- камера
	local zoom_on = data.zoom_level > 1 and (g_manual_zoom or
		(data.auto_zoom and data.last_click ~= nil and data.time - data.last_click < data.zoom_hold))
	if zoom_on then
		local vw, vh = w / data.zoom_level, h / data.zoom_level
		if not data.zoom_on then
			data.cam_tx, data.cam_ty = tx, ty
		end
		-- камера двигается, только когда курсор выходит из мёртвой зоны в центре кадра
		local dzx, dzy = vw * data.dead_zone * 0.5, vh * data.dead_zone * 0.5
		data.cam_tx = clamp(clamp(data.cam_tx, tx - dzx, tx + dzx), vw / 2, w - vw / 2)
		data.cam_ty = clamp(clamp(data.cam_ty, ty - dzy, ty + dzy), vh / 2, h - vh / 2)
	end
	data.zoom_on = zoom_on

	spring_step(data.zoom, zoom_on and data.zoom_level or 1, data.zoom_speed, critical(data.zoom_speed), dt)
	spring_step(cam.x, data.cam_tx, data.follow_speed, critical(data.follow_speed), dt)
	spring_step(cam.y, data.cam_ty, data.follow_speed, critical(data.follow_speed), dt)

	-- параметры кадра для шейдера
	local scale = 1 / math.max(1, data.zoom.p)
	local half_w, half_h = 0.5 * scale * w, 0.5 * scale * h
	local size = data.cursor_size * data.press.p

	local bx, by = cur.x.v * data.blur * 0.016, cur.y.v * data.blur * 0.016
	local blur_len = math.sqrt(bx * bx + by * by)
	local blur_max = size * 1.5
	if blur_len > blur_max then
		bx, by = bx * blur_max / blur_len, by * blur_max / blur_len
		blur_len = blur_max
	end

	data.frame = {
		scale = scale,
		cam_u = clamp(cam.x.p, half_w, w - half_w) / w,
		cam_v = clamp(cam.y.p, half_h, h - half_h) / h,
		cursor_x = cur.x.p,
		cursor_y = cur.y.p,
		size = size,
		blur_x = bx,
		blur_y = by,
		reject_r = size * 1.5 + blur_len * 0.5 + 2,
		cos = math.cos(data.angle),
		sin = math.sin(data.angle),
	}
end

local function set_vec2(data, name, x, y)
	obs.vec2_set(data.vec, x, y)
	obs.gs_effect_set_vec2(data.params[name], data.vec)
end

source_info.video_render = function(data)
	local f = data.frame
	if f == nil or data.effect == nil then
		obs.obs_source_skip_video_filter(data.source)
		return
	end
	if not obs.obs_source_process_filter_begin(data.source, obs.GS_RGBA, obs.OBS_NO_DIRECT_RENDERING) then
		return
	end

	local params = data.params
	local img = data.images[data.kind] or data.images.arrow
	local alpha = data.alpha
	if img ~= nil then
		if obs.gs_get_linear_srgb() then
			obs.gs_effect_set_texture_srgb(params.cursor_tex, img.texture)
		else
			obs.gs_effect_set_texture(params.cursor_tex, img.texture)
		end
	else
		alpha = 0
	end
	local hot = (data.images[data.kind] and CURSORS[data.kind] or CURSORS.arrow).hot

	set_vec2(data, "src_size", data.width, data.height)
	set_vec2(data, "cam_center", f.cam_u, f.cam_v)
	obs.gs_effect_set_float(params.cam_scale, f.scale)
	set_vec2(data, "cursor_px", f.cursor_x, f.cursor_y)
	obs.gs_effect_set_float(params.cursor_size, f.size)
	set_vec2(data, "cursor_hot", hot[1], hot[2])
	set_vec2(data, "cursor_rot", f.cos, f.sin)
	set_vec2(data, "blur_px", f.blur_x, f.blur_y)
	obs.gs_effect_set_float(params.cursor_alpha, alpha)
	obs.gs_effect_set_float(params.reject_r, f.reject_r)

	obs.obs_source_process_filter_end(data.source, data.effect, data.width, data.height)
end

local function on_zoom_hotkey(pressed)
	if pressed then
		g_manual_zoom = not g_manual_zoom
	end
end

function script_description()
	return [[<b>Smooth Cursor</b> — плавный курсор и приближение за курсором, как в Screen Studio.<br><br>
1. Источник «Захват экрана» → Фильтры → «+» → «Плавный курсор (Smooth Cursor)».<br>
2. Все настройки — в самом фильтре.<br>
3. Горячая клавиша: Настройки → Горячие клавиши → «Smooth Cursor: приближение вкл/выкл».]]
end

function script_load(settings)
	obs.obs_register_source(source_info)

	g_hotkey_id = obs.obs_hotkey_register_frontend(HOTKEY_NAME, "Smooth Cursor: приближение вкл/выкл", on_zoom_hotkey)
	local saved = obs.obs_data_get_array(settings, HOTKEY_NAME)
	obs.obs_hotkey_load(g_hotkey_id, saved)
	obs.obs_data_array_release(saved)
end

function script_save(settings)
	local saved = obs.obs_hotkey_save(g_hotkey_id)
	obs.obs_data_set_array(settings, HOTKEY_NAME, saved)
	obs.obs_data_array_release(saved)
end
