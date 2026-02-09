local event = require("event")
local render2d = require("render2d.render2d")
local gfx = require("render2d.gfx")
local Color = require("structs.color")
local window = require("window")
local fonts = require("render2d.fonts")
local gradient_linear = require("render.textures.gradient_linear")
local glow_linear = require("render.textures.glow_linear")
local glow_point = require("render.textures.glow_point")
local blur_color = Color.FromHex("#2374DD")

local function draw_diamond(x, y, size)
	render2d.PushMatrix()
	render2d.Translatef(x, y)
	render2d.Rotate(math.rad(45))
	render2d.DrawRectf(-size / 2, -size / 2, size, size)
	render2d.PopMatrix()
end

local function draw_diamond2(x, y, size)
	local s = size
	draw_diamond(x, y, s / 3)
	render2d.PushOutlineWidth(1)
	draw_diamond(x, y, s)
	render2d.PopOutlineWidth()
end

local function draw_pill_1(x, y, w, h)
	render2d.PushBorderRadius(h)
	render2d.DrawRect(x, y, w, h)
	render2d.SetBorderRadius(h / 2)
	render2d.PushOutlineWidth(1)
	render2d.DrawRect(x, y, w, h)
	render2d.PopOutlineWidth()
	render2d.PopBorderRadius()
	local s = 5
	local offset = 1
	draw_diamond(x, y + h / 2, s)
	draw_diamond(x + w, y + h / 2, s)
end

local function draw_badge(x, y, w, h)
	render2d.PushTexture(gradient_linear)
	render2d.PushUV()
	render2d.SetUV2(-0.1, 0, 0.75, 1)
	render2d.PushBorderRadius(h)
	render2d.DrawRect(x, y, w, h)
	render2d.PopBorderRadius()
	render2d.PopUV()
	render2d.PopTexture()
	render2d.PushColor(1, 1, 1, 1)
	local s = 8
	local offset = -s
	draw_diamond2(x - offset, y + h / 2, s)
	render2d.PopColor()
end

local function draw_arrow(x, y, size)
	local f = size / 2
	render2d.PushBorderRadius(f * 3, f * 2, f * 2, f * 3)
	render2d.PushMatrix()
	render2d.Translatef(x - size / 3, y - size / 3)
	render2d.Scalef(1.6, 0.75)
	render2d.DrawRectf(0, 0, size * 1, size)
	render2d.PopMatrix()
	render2d.PopBorderRadius()
	draw_diamond(x, y + 0.5, size / 2)
end

local function draw_line(x1, y1, x2, y2, thickness)
	local angle = math.atan2(y2 - y1, x2 - x1)
	local length = math.sqrt((x2 - x1) ^ 2 + (y2 - y1) ^ 2)
	local s = thickness * 2
	draw_diamond(x1, y1, s)
	draw_diamond(x2, y2, s)
	render2d.PushMatrix()
	render2d.Translatef(x1, y1)
	render2d.Rotate(angle)
	render2d.DrawRect(0, -thickness / 2, length, thickness)
	render2d.PopMatrix()
end

local function draw_line2(x1, y1, x2, y2, thickness)
	local angle = math.atan2(y2 - y1, x2 - x1)
	local length = math.sqrt((x2 - x1) ^ 2 + (y2 - y1) ^ 2)
	local s = thickness * 4
	render2d.PushMatrix()
	render2d.Translatef(x1, y1 + 1)
	render2d.Rotate(math.pi)
	draw_arrow(0, 0, s)
	render2d.PopMatrix()
	draw_arrow(x2, y2, s)
	render2d.PushMatrix()
	render2d.Translatef(x1, y1)
	render2d.Rotate(angle)
	render2d.DrawRect(0, -thickness / 2, length, thickness)
	render2d.PopMatrix()
end

local Texture = require("render.texture")
local gradient = Texture.New(
	{
		width = 16,
		height = 16,
		format = "r8g8b8a8_unorm",
		sampler = {
			min_filter = "linear",
			mag_filter = "linear",
			wrap_s = "clamp_to_edge",
			wrap_t = "clamp_to_edge",
		},
	}
)
local start = Color.FromHex("#060086")
local stop = Color.FromHex("#04013e")
gradient:Shade(
	[[
	float dist = distance(uv, vec2(0.5));
		return vec4(mix(vec3(]] .. start.r .. ", " .. start.g .. ", " .. start.b .. "), vec3(" .. stop.r .. ", " .. stop.g .. ", " .. stop.b .. [[), -uv.y + 1.0), 1.0);
]]
)

local function frame_tex(options)
	options = options or {}
	local width = options.width or 256
	local height = options.height or 256
	local light_x = options.light_x or -1
	local light_y = options.light_y or -1
	local light_z = options.light_z or 1
	local frame_outer = options.frame_outer or 0.005
	local frame_inner = options.frame_inner or 0.02
	local bevel = options.bevel or 0.015
	local corner_radius = options.corner_radius or 0.03
	local profile_strength = options.profile_strength or 1.5
	local long_curve = options.long_curve or 0.4
	local specular_power = options.specular_power or 80.0
	local specular_strength = options.specular_strength or 0.8
	local ambient = options.ambient or 0.2
	local base_color_r = options.base_color.r or 0.6
	local base_color_g = options.base_color.g or 0.63
	local base_color_b = options.base_color.b or 0.65
	local Texture = require("render.texture")
	local tex = Texture.New(
		{
			width = width,
			height = height,
			format = "r8g8b8a8_unorm",
			mip_map_levels = "auto",
			sampler = {
				min_filter = "linear",
				mag_filter = "linear",
				wrap_s = "clamp_to_edge",
				wrap_t = "clamp_to_edge",
			},
		}
	)

	local function f(v)
		return tostring(v)
	end

	tex:Shade(
		[[
	float frameOuter = ]] .. f(frame_outer) .. [[;
	float frameInner = ]] .. f(frame_inner) .. [[;
	float bevel = ]] .. f(bevel) .. [[;
	float cornerRadius = ]] .. f(corner_radius) .. [[;

	vec2 p = uv - vec2(0.5);
	vec2 halfSize = vec2(0.5 - cornerRadius);
	vec2 d = abs(p) - halfSize;
	float sdRect = length(max(d, vec2(0.0))) + min(max(d.x, d.y), 0.0) - cornerRadius;
	float dEdge = -sdRect;

	float outerMask = smoothstep(frameOuter - bevel, frameOuter, dEdge);
	float innerMask = 1.0 - smoothstep(frameInner - bevel, frameInner, dEdge);
	float frameMask = outerMask * innerMask;

	// SDF gradient for cross-bar bevel direction
	vec2 grad;
	if (d.x > 0.0 && d.y > 0.0) {
		grad = normalize(d) * sign(p);
	} else if (d.x > d.y) {
		grad = vec2(sign(p.x), 0.0);
	} else {
		grad = vec2(0.0, sign(p.y));
	}
	grad = -grad;

	// bevel profile (cross section)
	float frameMid = (frameOuter + frameInner) * 0.5;
	float frameHalf = (frameInner - frameOuter) * 0.5;
	float t = clamp((dEdge - frameMid) / frameHalf, -1.0, 1.0);
	float profileSlope = -t * ]] .. f(profile_strength) .. [[;

	// longitudinal curvature
	vec2 tangent = vec2(-grad.y, grad.x);
	float alongBar = dot(p, tangent);
	float longCurve = alongBar * ]] .. f(long_curve) .. [[;

	vec3 N = normalize(vec3(
		grad * profileSlope + tangent * longCurve,
		1.0
	));

	vec3 L = normalize(vec3(]] .. f(light_x) .. [[, ]] .. f(light_y) .. [[, ]] .. f(light_z) .. [[));
	vec3 V = vec3(0.0, 0.0, 1.0);
	vec3 H = normalize(L + V);

	float NdotL = max(dot(N, L), 0.0);
	float NdotH = max(dot(N, H), 0.0);
	float spec = pow(NdotH, ]] .. f(specular_power) .. [[);

	vec3 baseColor = vec3(]] .. f(base_color_r) .. [[, ]] .. f(base_color_g) .. [[, ]] .. f(base_color_b) .. [[);
	float ambient = ]] .. f(ambient) .. [[;
	vec3 color = baseColor * (ambient + (1.0 - ambient) * NdotL) + vec3(0.9, 0.9, 0.95) * spec * ]] .. f(specular_strength) .. [[;

	return vec4(color, frameMask);
]]
	)
	-- nine patch derived from frame parameters
	local outer_px = math.ceil(frame_outer * width)
	local inner_px = math.ceil(frame_inner * width) - 2
	local corner_px = math.ceil(corner_radius * width)
	local patch_border = math.max(inner_px, corner_px) + 2 -- +2 for safety margin
	tex.nine_patch = {
		x_stretch = {
			{patch_border, width - patch_border},
		},
		y_stretch = {
			{patch_border, height - patch_border},
		},
		x_content = {
			{inner_px, width - inner_px},
		},
		y_content = {
			{inner_px, height - inner_px},
		},
	}
	return tex
end

local metal_frame = frame_tex({
	base_color = Color.FromHex("#8f8b92"),
})

local function draw_classic_frame(x, y, w, h)
	render2d.PushBorderRadius(h * 0.2)
	render2d.SetColor(1, 1, 1, 1)
	render2d.SetTexture(gradient)
	render2d.DrawRect(x, y, w, h)
	render2d.PopBorderRadius()

	do
		render2d.PushOutlineWidth(5)
		render2d.PushEdgeFeather(0.2)
		render2d.SetColor(0, 0, 0, 0.5)
		render2d.SetTexture(nil)
		render2d.DrawRect(x, y, w, h)
		render2d.PopEdgeFeather()
		render2d.PopOutlineWidth()
	end

	x = x - 3
	y = y - 3
	w = w + 6
	h = h + 6

	do
		render2d.SetColor(1, 1, 1, 1)
		render2d.SetNinePatchTable(metal_frame.nine_patch)
		render2d.SetTexture(metal_frame)
		render2d.DrawRect(x, y, w, h)
		render2d.ClearNinePatch()
		render2d.SetTexture(nil)
	end
end

local font = fonts.CreateFont(
	{
		path = "/home/caps/Downloads/Exo_2/static/Exo2-Bold.ttf",
		size = 30,
		padding = 20,
		separate_effects = true,
		effects = {
			{
				type = "shadow",
				dir = -1.5,
				color = Color.FromHex("#0c1721"),
				blur_radius = 0.25,
				blur_passes = 1,
			},
			{
				type = "shadow",
				dir = 0,
				color = blur_color,
				blur_radius = 3,
				blur_passes = 3,
				alpha_pow = 0.6,
			},
		},
	}
)

local function draw_circle(x, y, size, width)
	render2d.PushBorderRadius(size)
	render2d.PushOutlineWidth(width or 1)
	render2d.DrawRect(x - size, y - size, size * 2, size * 2)
	render2d.PopOutlineWidth()
	render2d.PopBorderRadius()
end

local function draw_line_simple(x1, y1, x2, y2, thickness)
	local angle = math.atan2(y2 - y1, x2 - x1)
	local length = math.sqrt((x2 - x1) ^ 2 + (y2 - y1) ^ 2)
	render2d.PushMatrix()
	render2d.Translatef(x1, y1)
	render2d.Rotate(angle)
	render2d.DrawRectf(0, -thickness / 2, length, thickness)
	render2d.PopMatrix()
end

local function draw_magic_circle(x, y, size)
	render2d.PushEdgeFeather(0.02)
	draw_circle(x, y, size, 4)
	draw_circle(x, y, size * 1.5)
	draw_circle(x, y, size * 1.7)
	draw_circle(x, y, size * 3)
	render2d.PopEdgeFeather()

	for i = 1, 8 do
		local angle = (i / 8) * math.pi * 2
		local length = size * 1.35
		local x1 = x + math.cos(angle) * length
		local y1 = y + math.sin(angle) * length
		draw_diamond(x1, y1, 3)
	end

	for i = 1, 16 do
		local angle = (i / 16) * math.pi * 2
		local length = size * 1.35
		local x1 = x + math.cos(angle) * length
		local y1 = y + math.sin(angle) * length
		local x2 = x + math.cos(angle) * length * 1.5
		local y2 = y + math.sin(angle) * length * 1.5
		render2d.SetTexture(glow_linear)
		draw_line_simple(x1, y1, x2, y2, 1)
	end
end

local function draw_glow(x, y, size)
	render2d.PushTexture(glow_point)
	render2d.PushAlphaMultiplier(0.5)
	render2d.DrawRectf(x - size, y - size, size * 2, size * 2)
	render2d.PopAlphaMultiplier()
	render2d.PopTexture()
end

local function draw_frame(x, y, w, h)
	render2d.SetColor(1, 1, 1, 1)
	render2d.SetBlendMode("additive")
	local glow_size = 40
	local diamond_size = 8
	draw_diamond2(x, y, diamond_size)
	draw_glow(x, y, glow_size)
	draw_diamond2(x + w, y, diamond_size)
	draw_glow(x + w, y, glow_size)
	draw_diamond2(x, y + h, diamond_size)
	draw_glow(x, y + h, glow_size)
	draw_diamond2(x + w, y + h, diamond_size)
	draw_glow(x + w, y + h, glow_size)
	render2d.SetTexture(glow_linear)
	local extent_h = -h * 1 * 0.25
	local extent_w = -w * 1 * 0.25
	draw_line_simple(x + extent_w, y, x + w - extent_w, y, 2)
	draw_line_simple(x + extent_w, y + h, x + w - extent_w, y + h, 2)
	draw_line_simple(x, y + extent_h, x, y + h - extent_h, 2)
	draw_line_simple(x + w, y + extent_h, x + w, y + h - extent_h, 2)
	render2d.SetTexture(nil)
	render2d.SetBlendMode("alpha")
end

local Texture = require("render.texture")
local Vec2 = require("structs.vec2")
local render2d = require("render2d.render2d")
local nine_patch_tex = nil

Texture.LoadNinePatch("/home/caps/Pictures/a1b9c72430f0fa4f5611ff0a838bc993.png", function(tex)
	table.print(tex.nine_patch)
	nine_patch_tex = tex
end)

local function frame_tex(options)
	options = options or {}
	local width = options.width or 256
	local height = options.height or 256
	local light_x = options.light_x or -1
	local light_y = options.light_y or -1
	local light_z = options.light_z or 1
	local frame_outer = options.frame_outer or 0.02
	local frame_inner = options.frame_inner or 0.04
	local bevel = options.bevel or 0.015
	local corner_radius = options.corner_radius or 0.03
	local profile_strength = options.profile_strength or 1.5
	local long_curve = options.long_curve or 0.4
	local specular_power = options.specular_power or 80.0
	local specular_strength = options.specular_strength or 0.65
	local ambient = options.ambient or 0.22
	local base_color_r = options.base_color_r or 0.6
	local base_color_g = options.base_color_g or 0.63
	local base_color_b = options.base_color_b or 0.65
	local Texture = require("render.texture")
	local tex = Texture.New(
		{
			width = width,
			height = height,
			format = "r8g8b8a8_unorm",
			mip_map_levels = "auto",
			sampler = {
				min_filter = "linear",
				mag_filter = "linear",
				wrap_s = "clamp_to_edge",
				wrap_t = "clamp_to_edge",
			},
		}
	)

	local function f(v)
		return tostring(v)
	end

	tex:Shade(
		[[
	float frameOuter = ]] .. f(frame_outer) .. [[;
	float frameInner = ]] .. f(frame_inner) .. [[;
	float bevel = ]] .. f(bevel) .. [[;
	float cornerRadius = ]] .. f(corner_radius) .. [[;

	vec2 p = uv - vec2(0.5);
	vec2 halfSize = vec2(0.5 - cornerRadius);
	vec2 d = abs(p) - halfSize;
	float sdRect = length(max(d, vec2(0.0))) + min(max(d.x, d.y), 0.0) - cornerRadius;
	float dEdge = -sdRect;

	float outerMask = smoothstep(frameOuter - bevel, frameOuter, dEdge);
	float innerMask = 1.0 - smoothstep(frameInner - bevel, frameInner, dEdge);
	float frameMask = outerMask * innerMask;

	// SDF gradient for cross-bar bevel direction
	vec2 grad;
	if (d.x > 0.0 && d.y > 0.0) {
		grad = normalize(d) * sign(p);
	} else if (d.x > d.y) {
		grad = vec2(sign(p.x), 0.0);
	} else {
		grad = vec2(0.0, sign(p.y));
	}
	grad = -grad;

	// bevel profile (cross section)
	float frameMid = (frameOuter + frameInner) * 0.5;
	float frameHalf = (frameInner - frameOuter) * 0.5;
	float t = clamp((dEdge - frameMid) / frameHalf, -1.0, 1.0);
	float profileSlope = -t * ]] .. f(profile_strength) .. [[;

	// longitudinal curvature
	vec2 tangent = vec2(-grad.y, grad.x);
	float alongBar = dot(p, tangent);
	float longCurve = alongBar * ]] .. f(long_curve) .. [[;

	vec3 N = normalize(vec3(
		grad * profileSlope + tangent * longCurve,
		1.0
	));

	vec3 L = normalize(vec3(]] .. f(light_x) .. [[, ]] .. f(light_y) .. [[, ]] .. f(light_z) .. [[));
	vec3 V = vec3(0.0, 0.0, 1.0);
	vec3 H = normalize(L + V);

	float NdotL = max(dot(N, L), 0.0);
	float NdotH = max(dot(N, H), 0.0);
	float spec = pow(NdotH, ]] .. f(specular_power) .. [[);

	vec3 baseColor = vec3(]] .. f(base_color_r) .. [[, ]] .. f(base_color_g) .. [[, ]] .. f(base_color_b) .. [[);
	float ambient = ]] .. f(ambient) .. [[;
	vec3 color = baseColor * (ambient + (1.0 - ambient) * NdotL) + vec3(0.9, 0.9, 0.95) * spec * ]] .. f(specular_strength) .. [[;

	return vec4(color, frameMask);
]]
	)
	-- nine patch derived from frame parameters
	local outer_px = math.ceil(frame_outer * width)
	local inner_px = math.ceil(frame_inner * width) - 2
	local corner_px = math.ceil(corner_radius * width)
	local patch_border = math.max(inner_px, corner_px) + 2 -- +2 for safety margin
	tex.nine_patch = {
		x_stretch = {
			{patch_border, width - patch_border},
		},
		y_stretch = {
			{patch_border, height - patch_border},
		},
		x_content = {
			{inner_px, width - inner_px},
		},
		y_content = {
			{inner_px, height - inner_px},
		},
	}
	return tex
end

local metal_frame = frame_tex()

local function draw_ninepatch_debug(nine_patch_tex)
	local x, y, w, h = 100, 100, 400, 200
	local n = nine_patch_tex.nine_patch
	-- draw frame content
	render2d.SetColor(1, 1, 1, 1)
	render2d.SetNinePatchTable(n)
	render2d.SetTexture(nine_patch_tex)
	render2d.DrawRect(x, y, w, h)
	render2d.ClearNinePatch()
	-- draw content example
	render2d.SetTexture(nil)
	render2d.SetColor(1, 0, 0, 0.25)
	local xc = n.x_content[1]
	local yc = n.y_content[1]
	local padding_left = xc[1]
	local padding_top = yc[1]
	local padding_right = nine_patch_tex:GetWidth() - xc[2]
	local padding_bottom = nine_patch_tex:GetHeight() - yc[2]
	render2d.DrawRect(
		x + padding_left,
		y + padding_top,
		w - padding_left - padding_right,
		h - padding_top - padding_bottom
	)
end

event.AddListener("Draw2D", "ui_details", function()
	render2d.SetColor(1, 1, 1, 1)
	render2d.SetTexture(nil)
	local x, y = 500, 200 --gfx.GetMousePosition()
	local w, h = 600, 30
	font:DrawText("Custom Font Rendering", x, y - 40)
	draw_classic_frame(x, y, 60, 40)
	x = x + 80
	draw_frame(x, y, 100, 60)
	x = x - 80
	y = y + 80
	render2d.SetColor(0, 0, 0, 1)
	draw_pill_1(x, y, w, h)
	y = y + 50
	draw_badge(x, y, w, h)
	y = y + 50
	draw_diamond(x, y, 20)
	x = x + 50
	render2d.PushOutlineWidth(1)
	draw_diamond(x, y, 20)
	render2d.PopOutlineWidth()
	render2d.SetColor(1, 1, 1, 1)
	x = x + 50
	draw_arrow(x, y, 40)
	x = x - 100
	y = y + 50
	render2d.SetTexture(nil)
	draw_line(x + 20, y, x + w - 40, y, 3)
	y = y + 20
	draw_line2(x + 20, y, x + w - 40, y, 3)
	y = y + 20
	draw_diamond2(x, y, 10)
	y = y + 20
	render2d.SetColor(1, 1, 1, 1)
	y = y + 20
	draw_magic_circle(x - 100, y, 30)
end)
