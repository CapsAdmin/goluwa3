local event = require("event")
local fonts = require("render2d.fonts")
local render2d = require("render2d.render2d")
local gfx = require("render2d.gfx")
local fontPath = fonts.GetDefaultSystemFontPath()
local labelFont = fonts.New({Path = fontPath, Size = 10})
local modes = {"none", "rgb", "bgr", "vrgb", "vbgr"}
local amounts = {0, 0.1, 0.3, 0.6, 1.0}
local sizes = {7, 8, 9, 10, 11, 12, 13, 14, 15}
local cached_fonts = {}

--[[
for i, size in ipairs(sizes) do
	sizes[i] = size * 3
end
]]
for _, size in ipairs(sizes) do
	cached_fonts[size] = fonts.New({Path = fontPath, Size = size})
end

event.AddListener("Draw2D", "fonts_subpixel_demo", function()
	local w, h = render2d.GetSize()
	-- Draw Black on White Background
	render2d.SetColor(1, 1, 1, 1)
	render2d.SetTexture(nil)
	render2d.DrawRect(0, 0, w, h)
	local x, y = 20, 20
	local modes = {"none", "rgb", "bgr", "vrgb", "vbgr"}
	local amounts = {0, 0.333, 0.6} -- 0.333 is standard
	local sizes = {7, 8, 9, 10, 11, 12, 13, 14, 15}
	local last_y = y

	for _, mode in ipairs(modes) do
		render2d.PushSubpixelMode(mode)

		for _, amount in ipairs(amounts) do
			if mode == "none" and amount > 0 then break end

			-- Render Label
			render2d.SetColor(0.5, 0.5, 0.5, 1)
			labelFont:DrawText(string.format("Mode: %s, Amount: %.3f", mode:upper(), amount), x, y)
			y = y + 15
			render2d.PushSubpixelAmount(amount)
			-- 1. Black text on White (requires Multiply blending)
			render2d.PushBlendMode("multiply")
			render2d.SetColor(0, 0, 0, 1)
			local current_x = x + 10

			for _, size in ipairs(sizes) do
				local demo_font = cached_fonts[size]
				demo_font:DrawText("The quick brown fox jumps over the lazy dog (" .. size .. "px)", current_x, y)
				y = y + size + 2
			end

			render2d.PopBlendMode()
			y = y + 5
			-- 2. White text on a black bar (requires Additive blending)
			local bar_h = 25
			render2d.SetColor(0, 0, 0, 1)
			render2d.DrawRect(x, y, 350, bar_h)
			render2d.PushBlendMode("additive")
			render2d.SetColor(1, 1, 1, 1)
			labelFont:DrawText("Subpixel light on dark (" .. mode .. ")", x + 10, y + 2)
			render2d.PopBlendMode()
			y = y + bar_h + 15
			render2d.PopSubpixelAmount()

			if y > h - 100 then
				x = x + 400
				y = 20
			end
		end

		render2d.PopSubpixelMode()
	end

	-- Zoom factor to see subpixels
	local zoom = 8
	local mx, my = gfx.GetMousePosition()
	render2d.SetColor(1, 1, 1, 1)
	render2d.SetTexture(nil)
	render2d.DrawRect(w - 260, h - 260, 250, 250)
	render2d.SetColor(0, 0, 0, 1)
	render2d.DrawRect(w - 260, h - 260, 250, 250, 0, 0, 0, -2) -- Border
	-- This part is tricky as we just want to show the pixels near the mouse
	-- But render2d is not a framebuffer we can easily read.
	-- So we just render a label near the bottom to show it in zoom.
	labelFont:DrawText("Move mouse over text to zoom (mental zoom)", w - 250, h - 20)
end)
