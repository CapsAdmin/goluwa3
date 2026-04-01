local event = import("goluwa/event.lua")
local render = import("goluwa/render/render.lua")
local render2d = import("goluwa/render2d/render2d.lua")
local fonts = import("goluwa/render2d/fonts.lua")
local Color = import("goluwa/structs/color.lua")
local title_font = fonts.New{Path = fonts.GetDefaultSystemFontPath(), Size = 32}
local label_font = fonts.New{Path = fonts.GetDefaultSystemFontPath(), Size = 18}
local body_font = fonts.New{Path = fonts.GetDefaultSystemFontPath(), Size = 14}
local warm_gradient = render2d.CreateGradient{
	mode = "linear",
	angle = 0,
	stops = {
		{pos = 0.0, color = Color(1.0, 0.45, 0.2, 1.0)},
		{pos = 1.0, color = Color(1.0, 0.85, 0.2, 1.0)},
	},
}
local cool_gradient = render2d.CreateGradient{
	mode = "linear",
	angle = 90,
	stops = {
		{pos = 0.0, color = Color(0.2, 0.75, 1.0, 1.0)},
		{pos = 1.0, color = Color(0.25, 0.35, 1.0, 1.0)},
	},
}

local function draw_label(text, x, y, color)
	render2d.PushColor(color[1], color[2], color[3], color[4] or 1)
	label_font:DrawText(text, x, y)
	render2d.PopColor()
end

local function draw_body(text, x, y, color)
	render2d.PushColor(color[1], color[2], color[3], color[4] or 1)
	body_font:DrawText(text, x, y)
	render2d.PopColor()
end

local function draw_background(w, h)
	render2d.SetTexture(nil)
	render2d.PushColor(0.05, 0.06, 0.09, 1)
	render2d.DrawRect(0, 0, w, h)
	render2d.PopColor()
	render2d.PushColor(1, 1, 1, 0.08)
	render2d.PushSDFGradientTexture(cool_gradient)
	render2d.PushBorderRadius(28)
	render2d.DrawRect(32, 32, w - 64, h - 64)
	render2d.PopBorderRadius()
	render2d.PopSDFGradientTexture()
	render2d.PopColor()
end

local function draw_panel(x, y, w, h, title, subtitle)
	render2d.PushColor(0.08, 0.1, 0.16, 0.92)
	render2d.PushBorderRadius(18)
	render2d.DrawRect(x, y, w, h)
	render2d.PopBorderRadius()
	render2d.PopColor()
	render2d.PushColor(1, 1, 1, 0.1)
	render2d.PushOutlineWidth(1.25)
	render2d.PushBorderRadius(18)
	render2d.DrawRect(x, y, w, h)
	render2d.PopBorderRadius()
	render2d.PopOutlineWidth()
	render2d.PopColor()
	draw_label(title, x + 16, y + 14, {0.96, 0.97, 0.98, 1})
	draw_body(subtitle, x + 16, y + 42, {0.7, 0.76, 0.84, 1})
end

local function draw_source_shape(x, y, size, phase)
	render2d.PushColor(1.0, 0.45, 0.25, 0.72)
	render2d.PushBorderRadius(18)
	render2d.DrawRect(x, y, size, size)
	render2d.PopBorderRadius()
	render2d.PopColor()
	render2d.PushColor(1.0, 0.92, 0.35, 0.85)
	render2d.PushBlur(14)
	render2d.DrawRect(x + 12, y + 18 + math.sin(phase) * 6, size - 24, size - 36)
	render2d.PopBlur()
	render2d.PopColor()
end

local function draw_destination_shape(x, y, size, phase)
	render2d.PushColor(0.18, 0.8, 1.0, 0.68)
	render2d.PushBorderRadius(28)
	render2d.DrawRect(x + 36 + math.cos(phase * 0.75) * 12, y + 26, size, size)
	render2d.PopBorderRadius()
	render2d.PopColor()
	render2d.PushColor(0.3, 0.45, 1.0, 0.9)
	render2d.PushSDFGradientTexture(warm_gradient)
	render2d.PushBorderRadius(22)
	render2d.DrawRect(x + 56, y + 48, size - 16, size - 30)
	render2d.PopBorderRadius()
	render2d.PopSDFGradientTexture()
	render2d.PopColor()
end

local function draw_blend_preview(x, y, w, h, blend_mode, phase)
	local preview_x = x + 16
	local preview_y = y + 74
	local preview_w = w - 32
	local preview_h = h - 96
	render2d.PushColor(0.03, 0.04, 0.07, 1)
	render2d.PushBorderRadius(14)
	render2d.DrawRect(preview_x, preview_y, preview_w, preview_h)
	render2d.PopBorderRadius()
	render2d.PopColor()
	render2d.PushColor(1, 1, 1, 0.06)
	render2d.PushOutlineWidth(1)
	render2d.PushBorderRadius(14)
	render2d.DrawRect(preview_x, preview_y, preview_w, preview_h)
	render2d.PopBorderRadius()
	render2d.PopOutlineWidth()
	render2d.PopColor()
	draw_destination_shape(preview_x + 10, preview_y + 8, 88, phase)
	render2d.PushBlendMode(blend_mode)
	draw_source_shape(preview_x + 30, preview_y + 18, 92, phase)
	render2d.PopBlendMode()
end

local examples = {
	{
		title = "alpha",
		subtitle = "Source alpha over destination",
		blend = "alpha",
		description = "src_alpha / one_minus_src_alpha",
	},
	{
		title = "additive",
		subtitle = "Glow and bloom accumulation",
		blend = "additive",
		description = "src_alpha / one",
	},
	{
		title = "multiply",
		subtitle = "Darkens through destination color",
		blend = "multiply",
		description = "dst_color / zero",
	},
	{
		title = "screen",
		subtitle = "Brightens while preserving contrast",
		blend = "screen",
		description = "one / one_minus_src_color",
	},
	{
		title = "custom",
		subtitle = "Explicit Vulkan blend equation",
		blend = {
			blend = true,
			src_color_blend_factor = "src_alpha",
			dst_color_blend_factor = "one",
			color_blend_op = "max",
			src_alpha_blend_factor = "one",
			dst_alpha_blend_factor = "one",
			alpha_blend_op = "add",
		},
		description = "max(src, dst) with additive alpha",
	},
	{
		title = "subtract",
		subtitle = "Reverse subtract for punchy contrast",
		blend = "subtract",
		description = "reverse_subtract",
	},
}

event.AddListener("Draw2D", "render2d_blend_showcase", function()
	local width = render.GetWidth()
	local height = render.GetHeight()
	local phase = os.clock() * 1.4
	local panel_w = 270
	local panel_h = 210
	local gap = 24
	local origin_x = math.max(48, math.floor((width - (panel_w * 3 + gap * 2)) * 0.5))
	local origin_y = 120
	draw_background(width, height)
	render2d.PushColor(0.98, 0.99, 1.0, 1)
	title_font:DrawText("render2d blend mode showcase", origin_x, 42)
	render2d.PopColor()
	draw_body(
		"Preset states now share the same path as explicit Vulkan factors and ops.",
		origin_x,
		78,
		{0.74, 0.8, 0.88, 1}
	)

	for i, info in ipairs(examples) do
		local col = (i - 1) % 3
		local row = math.floor((i - 1) / 3)
		local x = origin_x + col * (panel_w + gap)
		local y = origin_y + row * (panel_h + gap)
		draw_panel(x, y, panel_w, panel_h, info.title, info.subtitle)
		draw_blend_preview(x, y, panel_w, panel_h, info.blend, phase + i * 0.45)
		draw_body(info.description, x + 16, y + panel_h - 24, {0.96, 0.76, 0.45, 1})
	end
end)
