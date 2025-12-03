local event = require("event")
local render = require("graphics.render")
local system = require("system")
local input = require("input")
local render2d = require("graphics.render2d")
local gfx = require("graphics.gfx")
local render3d = require("graphics.render3d")
-- Debug: Show camera info
local show_camera_info = true

event.AddListener("Draw2D", "debug_camera_info", function(cmd, dt)
	if not show_camera_info then return end

	local cam = render3d.cam

	if not cam then return end

	local pos = cam:GetPosition()
	local ang = cam:GetAngles()
	local y = 10
	local x = 10
	render2d.SetTexture(nil)
	render2d.SetColor(1, 1, 1, 1)
	gfx.DrawText(string.format("Pos: X=%.1f  Y=%.1f  Z=%.1f", pos.x, pos.y, pos.z), x, y)
	y = y + 20
	gfx.DrawText(string.format("Ang: P=%.1f  Y=%.1f  R=%.1f", ang.p, ang.y, ang.r), x, y)
	y = y + 20
	-- Also show which direction each axis points based on Source convention
	render2d.SetColor(0.7, 0.7, 0.7, 1)
	gfx.DrawText("(X=forward, Y=left, Z=up | P=pitch, Y=yaw, R=roll)", x, y)
end)

event.AddListener("KeyInput", "toggle_camera_info", function(key, press)
	if not press then return end

	if key == "f10" then
		show_camera_info = not show_camera_info
		print("Camera info: " .. (show_camera_info and "ON" or "OFF"))
	end
end)

-- Debug: Draw shadow map as picture-in-picture
local show_shadow_map = false
-- Cascade colors for reference (matching shader)
local cascade_colors = {
	{1.0, 0.2, 0.2, 1.0}, -- Red for cascade 1
	{0.2, 1.0, 0.2, 1.0}, -- Green for cascade 2
	{0.2, 0.2, 1.0, 1.0}, -- Blue for cascade 3
	{1.0, 1.0, 0.2, 1.0}, -- Yellow for cascade 4
}

event.AddListener("Draw2D", "debug_shadow_map", function(cmd, dt)
	if not show_shadow_map then return end

	local sun = render3d.GetSunLight()

	if not sun or not sun:HasShadows() then return end

	local shadow_map = sun:GetShadowMap()

	if not shadow_map then return end

	-- Draw all cascade shadow maps
	local cascade_count = shadow_map:GetCascadeCount()
	local cascade_splits = shadow_map:GetCascadeSplits()
	local size = 200
	local margin = 10
	local spacing = 10

	for i = 1, cascade_count do
		local depth_texture = shadow_map:GetDepthTexture(i)

		if depth_texture then
			local x = margin + (i - 1) * (size + spacing)
			local y = margin
			-- Draw shadow map depth texture
			render2d.SetTexture(depth_texture)
			render2d.SetColor(1, 1, 1, 1)
			render2d.DrawRect(x, y, size, size)
			-- Draw label with cascade info (use same color as 3D visualization)
			render2d.SetTexture(nil)
			local color = cascade_colors[i] or {1, 1, 0, 1}
			render2d.SetColor(color[1], color[2], color[3], 1)
			local split_dist = cascade_splits[i] and string.format("%.1f", cascade_splits[i]) or "?"
			gfx.DrawText("Cascade " .. i .. " (z<" .. split_dist .. ")", x, y + size + 5)
		end
	end
end)

event.AddListener("KeyInput", "renderdoc", function(key, press)
	if not press then return end

	--if key == "f8" then render.renderdoc.CaptureFrame() end
	if key == "f11" then render.renderdoc.OpenUI() end

	-- Toggle shadow map debug view
	if key == "f9" then
		show_shadow_map = not show_shadow_map
		-- Also toggle cascade color visualization in the shader
		render3d.SetDebugCascadeColors(show_shadow_map)
		print("Shadow map debug: " .. (show_shadow_map and "ON" or "OFF"))
	end

	if key == "c" and input.IsKeyDown("left_control") then system.ShutDown(0) end
end)
