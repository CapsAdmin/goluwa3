local event = require("event")
local render = require("render.render")
local system = require("system")
local input = require("input")
local render2d = require("render2d.render2d")
local gfx = require("render2d.gfx")
local render3d = require("render3d.render3d")
local Model = require("components.model")
local window = require("window")
-- Debug: Show debug info
local show_debug_info = false

-- Debug: Freeze frustum for culling
function events.Draw2D.debug_info(dt)
	if not show_debug_info then return end

	local y = 50
	local x = 10
	render2d.SetTexture(nil)
	-- Camera info
	local cam = render3d.GetCamera()
	local pos = cam:GetPosition()
	local rot = cam:GetRotation()
	render2d.SetColor(1, 1, 1, 1)
	gfx.DrawText(string.format("Camera Pos: X=%.1f  Y=%.1f  Z=%.1f", pos.x, pos.y, pos.z), x, y)
	y = y + 20
	gfx.DrawText(
		string.format("Camera Rot: X=%.1f  Y=%.1f  Z=%.1f W=%.1f", rot.x, rot.y, rot.z, rot.w),
		x,
		y
	)
	y = y + 20
	-- Separator
	y = y + 10
	-- Frustum culling status
	local frustum_status = Model.noculling and "DISABLED" or "ENABLED"
	local frustum_color = Model.noculling and {1.0, 0.2, 0.2} or {0.2, 1.0, 0.2}
	render2d.SetColor(frustum_color[1], frustum_color[2], frustum_color[3], 1)
	gfx.DrawText(string.format("Frustum Culling: %s", frustum_status), x, y)
	y = y + 20

	-- Freeze culling status
	if Model.freeze_culling then
		render2d.SetColor(1, 1, 0, 1)
		gfx.DrawText("CULLING FROZEN (Press F to unfreeze)", x, y)
		y = y + 20
		render2d.SetColor(0.8, 0.8, 0.5, 1)
		gfx.DrawText("  (Occlusion queries not updating)", x, y)
		y = y + 20
	end

	-- Separator
	y = y + 10
	-- Occlusion culling info
	local stats = Model.GetOcclusionStats()
	render2d.SetColor(1, 1, 1, 1)
	gfx.DrawText(
		string.format("Models: %d total, %d with occlusion", stats.total, stats.with_occlusion),
		x,
		y
	)
	y = y + 20
	-- Frustum culling results
	local visible_after_frustum = stats.total - stats.frustum_culled
	render2d.SetColor(0.7, 0.7, 0.7, 1)
	gfx.DrawText(
		string.format("  Frustum culled: %d (%d visible)", stats.frustum_culled, visible_after_frustum),
		x,
		y
	)
	y = y + 20
	local occlusion_status = stats.occlusion_enabled and "ENABLED" or "DISABLED"
	local occlusion_color = stats.occlusion_enabled and {0.2, 1.0, 0.2} or {1.0, 0.2, 0.2}
	render2d.SetColor(occlusion_color[1], occlusion_color[2], occlusion_color[3], 1)
	y = y + 20

	if stats.occlusion_enabled then
		render2d.SetColor(0.7, 0.7, 0.7, 1)
		gfx.DrawText(
			string.format("  Conditional rendering: %d models", stats.submitted_with_conditional),
			x,
			y
		)
		y = y + 20
		render2d.SetColor(1, 1, 0.5, 1)
		gfx.DrawText("  (GPU decides actual visibility)", x, y)
		y = y + 20
	end
end

function events.KeyInput.toggle_debug_info(key, press)
	if not press then return end

	if key == "f10" then
		show_debug_info = not show_debug_info
		print("Debug info: " .. (show_debug_info and "ON" or "OFF"))
	end
end

-- Debug: Draw shadow map as picture-in-picture
local show_shadow_map = false
-- Cascade colors for reference (matching shader)
local cascade_colors = {
	{1.0, 0.2, 0.2, 1.0}, -- Red for cascade 1
	{0.2, 1.0, 0.2, 1.0}, -- Green for cascade 2
	{0.2, 0.2, 1.0, 1.0}, -- Blue for cascade 3
	{1.0, 1.0, 0.2, 1.0}, -- Yellow for cascade 4
}

function events.Draw2D.debug_shadow_map(cmd, dt)
	if not show_shadow_map then return end

	local sun = render3d.GetLights()[1]

	if not sun or not sun:GetCastShadows() then return end

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
end

-- Debug: Draw SSR buffer
local show_ssr_buffer = false

function events.Draw2D.debug_ssr_buffer(cmd, dt)
	if not show_ssr_buffer then return end

	if not render3d.ssr_fb then return end

	local tex = render3d.ssr_fb:GetAttachment(1)

	if not tex then return end

	local size = 400
	local margin = 10
	local x = window:GetSize().x - size - margin
	local y = margin
	render2d.SetTexture(tex)
	render2d.SetColor(1, 1, 1, 1)
	render2d.DrawRect(x, y, size, size)
	render2d.SetTexture(nil)
	render2d.SetColor(1, 1, 1, 1)
	gfx.DrawText("SSR Buffer (Half-Res)", x, y + size + 5)
end

function events.KeyInput.render3d_debug(key, press)
	if not press then return end

	--if key == "f8" then render.renderdoc.CaptureFrame() end
	--if key == "f11" then render.renderdoc.OpenUI() end
	-- Toggle shadow map debug view
	if key == "f9" then
		show_shadow_map = not show_shadow_map
		-- Also toggle cascade color visualization in the shader
		render3d.SetDebugCascadeColors(show_shadow_map)
		print("Shadow map debug: " .. (show_shadow_map and "ON" or "OFF"))
	end

	-- Toggle SSR buffer debug view
	if key == "f7" then
		show_ssr_buffer = not show_ssr_buffer
		print("SSR buffer debug: " .. (show_ssr_buffer and "ON" or "OFF"))
	end

	-- Toggle frustum culling
	if key == "f8" then
		Model.noculling = not Model.noculling
		print("Frustum culling: " .. (Model.noculling and "DISABLED" or "ENABLED"))
	end

	-- Toggle occlusion culling
	if key == "f6" then
		Model.SetOcclusionCulling(not Model.IsOcclusionCullingEnabled())
		print(
			"Occlusion culling: " .. (
					Model.IsOcclusionCullingEnabled() and
					"ENABLED" or
					"DISABLED"
				)
		)
	end

	-- Toggle freeze frustum
	if key == "f" then render3d.freeze_culling = not render3d.freeze_culling end

	-- Toggle debug modes
	if key == "h" then print("Debug mode: " .. render3d.CycleDebugMode()) end

	if key == "c" and input.IsKeyDown("left_control") then system.ShutDown(0) end
end
