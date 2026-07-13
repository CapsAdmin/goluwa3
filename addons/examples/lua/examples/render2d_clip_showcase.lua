local event = import("goluwa/event.lua")
local render = import("goluwa/render/render.lua")
local render2d = import("goluwa/render2d/render2d.lua")
local fonts = import("goluwa/render2d/fonts.lua")
local Texture = import("goluwa/render/texture.lua")
local Color = import("goluwa/structs/color.lua")
local title_font = fonts.New{Path = fonts.GetDefaultSystemFontPath(), Size = 34}
local label_font = fonts.New{Path = fonts.GetDefaultSystemFontPath(), Size = 17}
local note_font = fonts.New{Path = fonts.GetDefaultSystemFontPath(), Size = 13}
local warm_gradient = render2d.CreateGradient{
	mode = "linear",
	angle = -15,
	stops = {
		{pos = 0.0, color = Color(1.0, 0.58, 0.24, 1.0)},
		{pos = 1.0, color = Color(1.0, 0.9, 0.36, 1.0)},
	},
}
local cool_gradient = render2d.CreateGradient{
	mode = "linear",
	angle = 90,
	stops = {
		{pos = 0.0, color = Color(0.2, 0.86, 1.0, 1.0)},
		{pos = 1.0, color = Color(0.2, 0.34, 1.0, 1.0)},
	},
}
local pattern_texture = Texture.New{
	width = 96,
	height = 96,
	format = "r8g8b8a8_unorm",
	mip_map_levels = 1,
	sampler = {
		min_filter = "nearest",
		mag_filter = "nearest",
		wrap_s = "repeat",
		wrap_t = "repeat",
	},
}
local shape_clip_mask_context = {
	x = 0,
	y = 0,
}
pattern_texture:Shade([[
		vec2 grid = floor(uv * 8.0);
		float checker = mod(grid.x + grid.y, 2.0);
		vec3 base = mix(vec3(0.12, 0.15, 0.26), vec3(0.76, 0.84, 1.0), checker);
		float stripe = smoothstep(0.42, 0.58, abs(sin((uv.x * 1.2 + uv.y) * 22.0)));
		base = mix(base, vec3(1.0, 0.48, 0.22), stripe * 0.34);
		return vec4(base, 1.0);
]])

local function with_rect_batch_mode(mode, callback)
	local old_mode = render2d.GetRectBatchMode()
	local ok, err
	render2d.SetRectBatchMode(mode)
	ok, err = xpcall(callback, debug.traceback)
	render2d.SetRectBatchMode(old_mode)

	if not ok then error(err, 0) end
end

local function draw_text(font, text, x, y, color)
	render2d.PushColor(color[1], color[2], color[3], color[4] or 1)

	with_rect_batch_mode("replay", function()
		font:DrawText(text, x, y)
	end)

	render2d.PopColor()
end

local function draw_title(text, x, y, color)
	draw_text(title_font, text, x, y, color)
end

local function draw_label(text, x, y, color)
	draw_text(label_font, text, x, y, color)
end

local function draw_note(text, x, y, color)
	draw_text(note_font, text, x, y, color)
end

local function draw_background(w, h)
	render2d.PushColor(0.04, 0.05, 0.08, 1)
	render2d.DrawRect(0, 0, w, h)
	render2d.PopColor()
	render2d.PushColor(1, 1, 1, 0.05)
	render2d.PushSDFGradientTexture(cool_gradient)
	render2d.PushBorderRadius(32)
	render2d.DrawRect(28, 28, w - 56, h - 56)
	render2d.PopBorderRadius()
	render2d.PopSDFGradientTexture()
	render2d.PopColor()
end

local function draw_card(x, y, w, h, title, note)
	render2d.PushColor(0.075, 0.09, 0.14, 0.96)
	render2d.PushBorderRadius(20)
	render2d.DrawRect(x, y, w, h)
	render2d.PopBorderRadius()
	render2d.PopColor()
	render2d.PushColor(1, 1, 1, 0.09)
	render2d.PushOutlineWidth(1)
	render2d.PushBorderRadius(20)
	render2d.DrawRect(x, y, w, h)
	render2d.PopBorderRadius()
	render2d.PopOutlineWidth()
	render2d.PopColor()
	draw_label(title, x + 16, y + 14, {0.96, 0.97, 0.99, 1})
	draw_note(note, x + 16, y + 38, {0.66, 0.74, 0.84, 1})
end

local function draw_preview_frame(x, y, w, h)
	render2d.PushColor(0.1, 0.12, 0.18, 1)
	render2d.PushBorderRadius(16)
	render2d.DrawRect(x, y, w, h)
	render2d.PopBorderRadius()
	render2d.PopColor()
	render2d.PushColor(1, 1, 1, 0.08)
	render2d.PushOutlineWidth(1)
	render2d.PushBorderRadius(16)
	render2d.DrawRect(x, y, w, h)
	render2d.PopBorderRadius()
	render2d.PopOutlineWidth()
	render2d.PopColor()
end

local function draw_axis_clip(x, y, w, h, phase)
	draw_preview_frame(x, y, w, h)
	render2d.PushClipRect(x, y, w, h)
	render2d.PushColor(1, 1, 1, 0.12)
	render2d.PushSDFGradientTexture(cool_gradient)
	render2d.DrawRect(x - 18, y - 10, w + 36, h + 20)
	render2d.PopSDFGradientTexture()
	render2d.PopColor()
	render2d.PushColor(0.18, 0.78, 1.0, 0.72)
	render2d.PushBlur(14)
	render2d.DrawRect(x - 18 + math.sin(phase) * 34, y + 12, 96, h - 24)
	render2d.PopBlur()
	render2d.PopColor()
	render2d.PushColor(1.0, 0.52, 0.24, 0.92)
	render2d.PushBorderRadius(18)
	render2d.DrawRect(x + 76 + math.cos(phase * 0.8) * 30, y + 16, 92, h - 32)
	render2d.PopBorderRadius()
	render2d.PopColor()
	render2d.PopClip()
end

local function draw_nested_clip(x, y, w, h, phase)
	draw_preview_frame(x, y, w, h)
	render2d.PushClipRect(x, y, w, h)
	render2d.PushColor(1, 1, 1, 0.08)
	render2d.PushSDFGradientTexture(warm_gradient)
	render2d.DrawRect(x - 10, y - 6, w + 20, h + 12)
	render2d.PopSDFGradientTexture()
	render2d.PopColor()
	render2d.PushColor(1, 1, 1, 0.1)
	render2d.PushOutlineWidth(1)
	render2d.PushBorderRadius(12)
	render2d.DrawRect(x + 18, y + 12, w - 36, h - 24)
	render2d.PopBorderRadius()
	render2d.PopOutlineWidth()
	render2d.PopColor()
	render2d.PushClipRect(x + 18, y + 12, w - 36, h - 24)
	render2d.PushTexture(pattern_texture)
	render2d.PushColor(1, 1, 1, 0.88)
	render2d.PushUV(phase * 16, phase * 10, 96, 96, 96, 96)
	render2d.DrawRect(x - 8 + math.cos(phase) * 18, y + 2, w, h)
	render2d.PopUV()
	render2d.PopColor()
	render2d.PopTexture()
	render2d.PushColor(0.08, 0.12, 0.2, 0.5)
	render2d.PushBorderRadius(10)
	render2d.DrawRect(x + 52, y + 22 + math.sin(phase * 1.4) * 10, 86, 42)
	render2d.PopBorderRadius()
	render2d.PopColor()
	render2d.PopClip()
	render2d.PopClip()
end

local function draw_rounded_clip(x, y, w, h, phase)
	draw_preview_frame(x, y, w, h)
	render2d.PushClipRoundedRect(x, y, w, h, 24)
	render2d.PushColor(1, 1, 1, 0.16)
	render2d.PushSDFGradientTexture(cool_gradient)
	render2d.DrawRect(x - 12, y - 12, w + 24, h + 24)
	render2d.PopSDFGradientTexture()
	render2d.PopColor()
	render2d.PushColor(1.0, 0.53, 0.26, 0.9)
	render2d.PushBorderRadius(20)
	render2d.DrawRect(x + 18, y + 14 + math.sin(phase * 1.2) * 12, w - 62, 40)
	render2d.PopBorderRadius()
	render2d.PopColor()
	render2d.PushTexture(pattern_texture)
	render2d.PushColor(1, 1, 1, 0.68)
	render2d.PushUV(phase * 10, phase * 6, 96, 96, 96, 96)
	render2d.DrawRect(x + 86 + math.cos(phase) * 12, y + 28, 88, 58)
	render2d.PopUV()
	render2d.PopColor()
	render2d.PopTexture()
	render2d.PopClip()
end

local function draw_rotated_clip(x, y, w, h, phase)
	draw_preview_frame(x, y, w, h)
	render2d.PushMatrix()
	render2d.Translate(x + w * 0.5, y + h * 0.5)
	render2d.Rotate(math.sin(phase * 0.8) * 0.55)
	render2d.PushClipRect(-58, -38, 116, 76)
	render2d.PushColor(1, 1, 1, 0.12)
	render2d.PushSDFGradientTexture(warm_gradient)
	render2d.DrawRect(-84, -56, 168, 112)
	render2d.PopSDFGradientTexture()
	render2d.PopColor()
	render2d.PushTexture(pattern_texture)
	render2d.PushColor(1, 1, 1, 0.82)
	render2d.PushUV(phase * 12, phase * 8, 96, 96, 96, 96)
	render2d.DrawRect(-94 + math.sin(phase) * 20, -50, 150, 100)
	render2d.PopUV()
	render2d.PopColor()
	render2d.PopTexture()
	render2d.PushColor(0.18, 0.82, 1.0, 0.88)
	render2d.PushBorderRadius(14)
	render2d.DrawRect(-28, -18, 76, 34)
	render2d.PopBorderRadius()
	render2d.PopColor()
	render2d.PopClip()
	render2d.PopMatrix()
end

local function draw_shape_clip_mask()
	local x = shape_clip_mask_context.x
	local y = shape_clip_mask_context.y
	render2d.PushBorderRadius(18)
	render2d.DrawRect(x + 8, y + 10, 44, 34)
	render2d.DrawRect(x + 28, y + 36, 92, 32)
	render2d.DrawRect(x + 82, y + 4, 46, 52)
	render2d.PopBorderRadius()
end

local function draw_shape_clip(x, y, w, h, phase)
	draw_preview_frame(x, y, w, h)
	shape_clip_mask_context.x = x + 26
	shape_clip_mask_context.y = y + 22
	render2d.PushClipShape(draw_shape_clip_mask)
	render2d.PushColor(1, 1, 1, 0.14)
	render2d.PushSDFGradientTexture(cool_gradient)
	render2d.DrawRect(x, y, w, h)
	render2d.PopSDFGradientTexture()
	render2d.PopColor()
	render2d.PushTexture(pattern_texture)
	render2d.PushColor(1, 1, 1, 0.92)
	render2d.PushUV(phase * 12, phase * 7, 96, 96, 96, 96)
	render2d.DrawRect(x + 10, y + 6, w + 16, h + 12)
	render2d.PopUV()
	render2d.PopColor()
	render2d.PopTexture()
	render2d.PushColor(1.0, 0.55, 0.24, 0.9)
	render2d.PushBlur(10)
	render2d.DrawRect(x + 18 + math.sin(phase * 1.2) * 24, y + 18, 84, 28)
	render2d.PopBlur()
	render2d.PopColor()
	render2d.PopClip()
	render2d.PushColor(1, 1, 1, 0.18)
	render2d.PushOutlineWidth(1.25)
	draw_shape_clip_mask()
	render2d.PopOutlineWidth()
	render2d.PopColor()
end

event.AddListener("Draw2D", "render2d_clip_showcase", function()
	local width = render.GetWidth()
	local height = render.GetHeight()
	local phase = os.clock() * 1.3
	local panel_w = 252
	local panel_h = 172
	local gap = 22
	local origin_x = math.max(34, math.floor((width - (panel_w * 3 + gap * 2)) * 0.5))
	local origin_y = 130
	draw_background(width, height)
	draw_title("render2d clip showcase", origin_x, 38, {0.98, 0.99, 1.0, 1})
	draw_note(
		"A single clip API covers hard-edge panels, nested windows, rounded masks, rotated content, and custom silhouettes.",
		origin_x,
		80,
		{0.73, 0.8, 0.88, 1}
	)
	draw_note(
		"The backend stays internal; the clip semantics stay stable.",
		origin_x,
		98,
		{0.58, 0.78, 0.95, 1}
	)
	local cards = {
		{
			"clip rect",
			"hard-edge viewport with animated overflow",
			function(x, y)
				draw_axis_clip(x, y, panel_w - 32, 88, phase)
			end,
		},
		{
			"nested rects",
			"outer frame and inner viewport share one API",
			function(x, y)
				draw_nested_clip(x, y, panel_w - 32, 88, phase)
			end,
		},
		{
			"rounded rect",
			"content follows the visible corner profile",
			function(x, y)
				draw_rounded_clip(x, y, panel_w - 32, 88, phase)
			end,
		},
		{
			"rotated clip",
			"same rect API still clips after transforms",
			function(x, y)
				draw_rotated_clip(x, y, panel_w - 32, 88, phase)
			end,
		},
		{
			"custom shape",
			"arbitrary mask shapes clip moving content",
			function(x, y)
				draw_shape_clip(x, y, panel_w - 32, 88, phase)
			end,
		},
	}

	for i, info in ipairs(cards) do
		local col = (i - 1) % 3
		local row = math.floor((i - 1) / 3)
		local x = origin_x + col * (panel_w + gap)
		local y = origin_y + row * (panel_h + gap)
		local preview_x = x + 16
		local preview_y = y + 70
		draw_card(x, y, panel_w, panel_h, info[1], info[2])
		info[3](preview_x, preview_y)
	end

	if height > origin_y + panel_h * 2 + gap then
		draw_note(
			"Low-level stencil and scissor controls still exist, but the main draw path can stay on semantic clips.",
			origin_x,
			origin_y + panel_h * 2 + gap + 18,
			{0.7, 0.76, 0.84, 1}
		)
	end
end)
