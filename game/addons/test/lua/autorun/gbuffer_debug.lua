local event = require("event")
local render = require("render.render")
local render2d = require("render2d.render2d")
local gfx = require("render2d.gfx")
local render3d = require("render3d.render3d")
local window = require("render.window")
local show_gbuffer = false

event.AddListener("Draw2D", "debug_gbuffer", function(cmd, dt)
	if not show_gbuffer then return end

	if not render3d.gbuffer then return end

	local size = 256
	local x = 0
	local y = 0
	local wnd_size = window:GetSize()
	render2d.SetColor(1, 1, 1, 1)
	local target_names = {
		"Albedo",
		"Normal",
		"MRA (Met, Rou, AO)",
		"Emissive",
	}

	-- Draw color textures
	for i, tex in ipairs(render3d.gbuffer.color_textures) do
		render2d.PushUV()
		render2d.SetUV2(0, 1, 1, 0)
		render2d.SetTexture(tex)
		render2d.DrawRect(x, y, size, size)
		render2d.PopUV()
		-- Draw label
		render2d.SetTexture(nil)
		render2d.SetColor(0, 0, 0, 0.5)
		render2d.DrawRect(x, y, 150, 20)
		render2d.SetColor(1, 1, 1, 1)
		gfx.DrawText(target_names[i] or ("Target " .. i), x + 5, y + 5)
		x = x + size

		if x + size > wnd_size.x then
			x = 0
			y = y + size
		end
	end

	-- Draw depth texture
	if render3d.gbuffer.depth_texture then
		render2d.PushUV()
		render2d.SetUV2(0, 1, 1, 0)
		render2d.SetTexture(render3d.gbuffer.depth_texture)
		render2d.DrawRect(x, y, size, size)
		render2d.PopUV()
		-- Draw label
		render2d.SetTexture(nil)
		render2d.SetColor(0, 0, 0, 0.5)
		render2d.DrawRect(x, y, 100, 20)
		render2d.SetColor(1, 1, 1, 1)
		gfx.DrawText("Depth", x + 5, y + 5)
	end
end)

event.AddListener("KeyInput", "debug_gbuffer_toggle", function(key, press)
	if not press then return end

	if key == "g" then
		show_gbuffer = not show_gbuffer
		print("G-buffer debug: " .. (show_gbuffer and "ON" or "OFF"))
	end
end)
