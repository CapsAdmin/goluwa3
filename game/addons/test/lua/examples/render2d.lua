local event = require("event")
local render2d = require("render2d.render2d")
local Color = require("structs.color")
local Vec2 = require("structs.vec2")
local fonts = require("render2d.fonts")
local fontPath = fonts.GetDefaultSystemFontPath()
local font = fonts.New({Path = fontPath, Size = 64})
local gfont = fonts.LoadGoogleFont("Orbitron", "Bold", {Size = 64, Padding = 32})
font.debug = false
font:SetPadding(64)
local blue_gradient = render2d.CreateGradient(
	{
		mode = "linear",
		stops = {
			{pos = 0, color = Color(1, 1, 1, 1)},
			{pos = 1, color = Color(0, 0, 1, 1)},
		},
	}
)
local glassy_gradient = render2d.CreateGradient(
	{
		mode = "linear",
		stops = {
			{pos = 0, color = Color(1, 1, 1, 1)},
			{pos = 1, color = Color(1, 1, 1, 0.05)},
		},
	}
)
local red_gradient = render2d.CreateGradient(
	{
		mode = "linear",
		stops = {
			{pos = 0, color = Color(1, 0, 0, 1)},
			{pos = 1, color = Color(0, 0, 1, 1)},
		},
	}
)

local function DrawRoundedRectGradientShadow(x, y, w, h)
	-- 1. Rounded Rectangle with Gradient and Shadow
	render2d.PushColor(1, 1, 1, 1)
	render2d.PushBorderRadius(20)
	-- Shadow first (Shifted by 5,5)
	render2d.PushColor(0, 0, 0, 0.5)
	render2d.DrawRect(x + 5, y + 5, w, h)
	render2d.PopColor()
	-- Then the Rect with Gradient
	render2d.PushSDFGradientTexture(blue_gradient) -- Blue bottom
	render2d.DrawRect(x, y, w, h)
	render2d.PopSDFGradientTexture()
	render2d.PopBorderRadius()
	render2d.PopColor()
end

local function DrawOutlineRect(x, y, w, h)
	-- 2. Outline only
	render2d.PushColor(1, 0.4, 0.4, 1)
	render2d.PushOutlineWidth(3) -- Multi-pixel outline works perfectly now
	render2d.PushBorderRadius(10, 50, 10, 50)
	render2d.DrawRect(x, y, w, h)
	render2d.PopBorderRadius()
	render2d.PopOutlineWidth()
	render2d.PopColor()
end

local function DrawGlassyPanel(x, y, w, h)
	-- 3. Glassy Panel (Thin Outline + Gradient)
	render2d.PushColor(1, 1, 1, 0.2)
	render2d.PushSDFGradientTexture(glassy_gradient)
	render2d.PushBorderRadius(15)
	render2d.DrawRect(x, y, w, h)
	render2d.PopSDFGradientTexture()
	render2d.PushOutlineWidth(1.5)
	render2d.DrawRect(x, y, w, h)
	render2d.PopOutlineWidth()
	render2d.PopBorderRadius()
	render2d.PopColor()
end

local function DrawUnifiedEffect(x, y, w, h)
	-- 4. Unified effect (Shape + Shadow + Outline)
	render2d.PushColor(0.2, 0.8, 0.2, 1)
	render2d.PushBorderRadius(30, 0, 30, 0)
	-- Shadow
	render2d.PushColor(0, 0, 0, 0.8)
	render2d.DrawRect(x + 10, y + 10, w, h)
	render2d.PopColor()
	-- Rect with Outline
	render2d.PushOutlineWidth(4)
	render2d.DrawRect(x, y, w, h)
	render2d.PopOutlineWidth()
	render2d.PopBorderRadius()
	render2d.PopColor()
end

local function DrawTextOutlineShadow(x, y)
	-- 5. Text with Outline and Shadow
	render2d.PushColor(1, 1, 1, 1) -- Yellow text
	render2d.PushSDFMode(true) -- Enable SDF mode for text
	render2d.PushOutlineWidth(1)
	font:DrawText("SDF", x, y)
	-- You can even do gradients on text now!
	render2d.PushSDFGradientTexture(red_gradient) -- Red gradient
	font:DrawText("Red Gradient", x, y + 100)
	render2d.PopSDFGradientTexture()
	render2d.PopOutlineWidth()
	render2d.PopSDFMode()
	render2d.PopColor()
end

local function DrawGlowingButton(x, y, w, h)
	local P = 20
	local w, h = font:GetTextSize("GLOW")
	x = x - P
	y = y - P
	w = w + P * 2
	h = h + P * 2

	do
		render2d.PushColor(0.4, 0.6, 1.0, 0.8)
		render2d.PushBlur(50)
		render2d.PushBorderRadius(h / 2)
		render2d.SetMargin(nil)
		render2d.PushBlendMode("additive")
		render2d.DrawRect(x, y, w, h)
		render2d.PopBlendMode()
		render2d.PopBorderRadius()
		render2d.PopBlur()
	end

	do
		render2d.PushColor(0.2, 0.4, 1.0, 1)
		render2d.PushBorderRadius(h / 2)
		render2d.DrawRect(x, y, w, h)
		render2d.PopBorderRadius()
		render2d.PopColor()
	end

	render2d.PushColor(1, 1, 1, 1)
	font:DrawText("GLOW", x + P, y + P)
	render2d.PopColor()
end

local function DrawGhostPanel(x, y, w, h)
	-- 7. "Ghost" / Frosted Glass with Edge Blur
	render2d.PushColor(1, 1, 1, 0.1)
	render2d.PushBlur(20) -- absolute pixel blur
	render2d.PushOutlineWidth(2) -- Sharp outline on top of blurry edge
	render2d.PushBorderRadius(50) -- Circle-like
	render2d.DrawRect(x, y, w, h)
	render2d.PopBorderRadius()
	render2d.PopOutlineWidth()
	render2d.PopBlur()
	render2d.PopColor()
end

local function DrawNeonText(x, y)
	render2d.PushColor(1, 1, 1, 1)
	render2d.PushBlur(15) -- SDF Blur for glow
	render2d.PushSDFThreshold(0.2)
	gfont:DrawText("NEON LIGHTS", x, y)
	render2d.PopSDFThreshold()
	render2d.PopBlur()
	render2d.PopColor()

	do
		return
	end

	-- Pink neon color pass
	render2d.PushColor(1, 0.2, 0.8, 1)
	render2d.PushBlur(2)
	font:DrawText("NEON LIGHTS", x, y)
	render2d.PopBlur()
	render2d.PopColor()
	-- Sharper core pass
	render2d.PushColor(1, 1, 1, 1)
	font:DrawText("NEON LIGHTS", x, y)
	render2d.PopColor()
end

local function DrawMultiShadowDrop(x, y, w, h)
	-- 9. Multi-Shadow Drop (Stacking effects)
	render2d.PushBorderRadius(10)
	-- Deep Shadow
	render2d.PushColor(0, 0, 0, 0.4)
	render2d.PushBlur(30)
	render2d.DrawRect(x + 20, y + 20, w, h)
	render2d.PopBlur()
	render2d.PopColor()
	-- Main Box
	render2d.PushColor(0.1, 0.5, 0.1, 1)
	render2d.DrawRect(x, y, w, h)
	render2d.PopColor()
	-- Inner highlight
	render2d.PushColor(1, 1, 1, 0.1)
	render2d.PushBlur(1)
	render2d.DrawRect(x + 3, y + 3, w - 10, h - 10)
	render2d.PopBlur()
	render2d.PopColor()
	render2d.PopBorderRadius()
end

event.AddListener("Draw2D", "render2d_demo", function()
	render2d.SetTexture(nil)
	local x, y = 100, 100
	local w, h = 210, 110
	DrawRoundedRectGradientShadow(x, y, w, h)
	-- 2. Outline only
	x = x + 250
	DrawOutlineRect(x, y, w, h)
	-- 3. Glassy Panel (Thin Outline + Gradient)
	x = 100
	y = y + 150
	DrawGlassyPanel(x, y, w, h)
	-- 4. Unified effect (Shape + Shadow + Outline)
	x = x + 250
	DrawUnifiedEffect(x, y, w, h)
	-- 5. Text with Outline and Shadow
	x = 100
	y = y + 200
	DrawTextOutlineShadow(x, y)
	---------------------------------------------------------
	-- NEW GLOW AND BLUR SHOWCASE
	---------------------------------------------------------
	x = 700
	y = 100
	DrawGlowingButton(x, y, w, h)
	-- 7. "Ghost" / Frosted Glass with Edge Blur
	y = y + 150
	DrawGhostPanel(x, y, w, h)
	-- 8. Neon Text Glow (Pink)
	y = y + 200
	DrawNeonText(x, y)
	-- 9. Multi-Shadow Drop (Stacking effects)
	y = y + 150
	DrawMultiShadowDrop(x, y, w, h)
end)
