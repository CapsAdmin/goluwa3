local Texture = require("render.texture")
local event = require("event")
local render2d = require("render2d.render2d")
local nine_patch_tex

Texture.LoadNinePatch("/home/caps/Pictures/a1b9c72430f0fa4f5611ff0a838bc993.png", function(tex)
	table.print(tex.nine_patch)
	nine_patch_tex = tex
end)

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
	draw_ninepatch_debug(nine_patch_tex)
end)
