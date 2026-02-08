local event = require("event")
local render2d = require("render2d.render2d")
local gfx = require("render2d.gfx")
local Color = require("structs.color")
local window = require("window")
local fonts = require("render2d.fonts")
local gradient_linear = require("render.textures.gradient_linear")

local function draw_diamond(x, y, size)
	render2d.PushMatrix()
	render2d.Translatef(x, y)
	render2d.Rotate(math.rad(45))
	render2d.DrawRectf(-size / 2, -size / 2, size, size)
	render2d.PopMatrix()
end

local function draw_pill_1(x, y, w, h)
	render2d.PushBorderRadius(h)
	render2d.DrawRect(x, y, w, h)
	render2d.SetBorderRadius(h / 2)
	render2d.PushOutlineWidth(1)
	render2d.DrawRect(x, y, w, h)
	local s = 5
	local offset = 1
	render2d.SetOutlineWidth(0)
	render2d.SetBorderRadius(1)
	draw_diamond(x, y + h / 2, s)
	draw_diamond(x + w, y + h / 2, s)
	--render2d.DrawRect(x, y + h / 2 - (s / 2) - offset, s, s, math.rad(45))
	--render2d.DrawRect(x + w, y + h / 2 - (s / 2) - offset, s, s, math.rad(45))
	render2d.PopOutlineWidth()
	render2d.PopBorderRadius()
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
	--render2d.DrawRect(x, y, h - (h / 4) - 2, h - (h / 4) - 2, math.rad(45))
	render2d.PushOutlineWidth(1)
	render2d.PushColor(1, 1, 1, 1)
	local s = 8
	local offset = -s
	--render2d.DrawRect(x - s / 2, y + h / 2 - (s / 2) - 2, s, s, math.rad(45))
	draw_diamond(x - offset, y + h / 2, s)
	local s = 4
	render2d.SetOutlineWidth(0)
	--render2d.DrawRect(x - s, y + h / 2 - (s) + 1, s, s, math.rad(45))
	draw_diamond(x - offset, y + h / 2, s)
	render2d.PopOutlineWidth()
	render2d.PopColor()
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

local function draw_arrow(x, y, size)
	local f = size / 2
	render2d.PushBorderRadius(f * 3, f * 2, f * 2, f * 3)
	render2d.PushMatrix()
	render2d.Translatef(x, y)
	render2d.Scalef(2, 0.75)
	render2d.DrawRect(0, 0, size * 1, size)
	render2d.PopMatrix()
	render2d.PopBorderRadius()
end

local function draw_frame(x, y, w, h)
	render2d.PushBorderRadius(30)
	render2d.PushOutlineWidth(10)
	render2d.DrawRect(x - 8, y - 8, w + 16, h + 16)
	render2d.PopOutlineWidth()
	render2d.PopBorderRadius()
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
				color = Color.FromHex("#2a75c0"),
				blur_radius = 3,
				blur_passes = 3,
				alpha_pow = 0.6,
			},
		},
	}
)
table.print(font:GetShadingInfo())

event.AddListener("Draw2D", "ui_details", function()
	local x, y = 500, 200 --gfx.GetMousePosition()
	local w, h = 600, 30
	render2d.SetColor(0, 0, 1, 0.5)
	render2d.SetTexture(nil)
	draw_frame(x, y, w, h * 7)
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
	x = x - 50
	y = y + 50
	draw_line(x, y, x + w, y + h, 3)
	y = y + 50
	render2d.SetColor(1, 1, 1, 1)
	font:DrawText("Custom Font Rendering", x, y)
end)
