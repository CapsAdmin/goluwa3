local event = import("goluwa/event.lua")
local render2d = import("goluwa/render2d/render2d.lua")
local Color = import("goluwa/structs/color.lua")
-- Showcase for the procedural SDF shape paths (circle / rounded / chamfered)
-- alongside the original sd_rect path, via DrawShape's shape field.
local modes = {
	{name = "rect", color = Color(1, 1, 1, 1)},
	{name = "circle", color = Color(1, 0.72, 0.18, 1)},
	{name = "ellipse", color = Color(0.5, 1, 0.5, 1)},
	{name = "rounded", color = Color(0.3, 0.8, 1, 1)},
	{name = "chamfered", color = Color(0.5, 1, 0.5, 1)},
}
local size = 100
local col_x = {410, 710, 1010, 1310, 1610}

local function draw_shape(mode, x, y, w, h, opts)
	opts = opts or {}
	render2d.DrawShape{
		shape = mode.name,
		color = mode.color,
		border_radius = opts.border_radius,
		outline_width = opts.outline_width,
		outline_color = opts.outline_color,
		x = x,
		y = y,
		w = w,
		h = h,
	}
	render2d.DrawText{
		x = x + w / 2,
		y = y + h + 12,
		align_x = 0.5,
		text = opts.label or mode.name,
		foreground_color = Color(0.85, 0.85, 0.85, 1),
		size = 20,
	}
end

local function draw_row(y, header, opts, w, h)
	w = w or size
	h = h or size
	render2d.DrawText{
		x = 70,
		y = y + h / 2,
		align_y = 0.5,
		text = header,
		foreground_color = Color(0.55, 0.55, 0.55, 1),
		size = 22,
	}

	for i, mode in ipairs(modes) do
		draw_shape(mode, col_x[i], y, w, h, opts)
	end
end

local gradient_tex = render2d.CreateGradient{
	width = 256,
	height = 1,
	mode = "linear",
	angle = 90,
	stops = {
		{pos = 0, color = Color(1, 0.2, 0.3, 1)},
		{pos = 0.3, color = Color(1, 0.6, 0.1, 1)},
		{pos = 0.6, color = Color(0.3, 1, 0.2, 1)},
		{pos = 1, color = Color(0.2, 0.4, 1, 1)},
	},
}

event.AddListener("Draw2D", "sdf_shape_modes", function()
	local w, h = render2d.GetSize()
	render2d.DrawText{
		x = w / 2,
		y = 44,
		align_x = 0.5,
		text = "render2d SDF shape modes  (DrawShape shape field)",
		foreground_color = Color(1, 1, 1, 1),
		size = 34,
	}
	draw_row(120, "uniform radius 40", {border_radius = 20})
	draw_row(380, "tl=80 tr=20 br=80 bl=20", {border_radius = {40, 10, 40, 10}})
	draw_row(
		640,
		"outline 8, radius 10",
		{
			border_radius = 10,
			outline_width = 8,
			outline_color = Color(1, 1, 0.4, 1),
		}
	)
	draw_row(890, "w=200 h=140 (circle uses width)", {border_radius = 30}, 100, 80)
end)
