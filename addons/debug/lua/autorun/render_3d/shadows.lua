local event = import("goluwa/event.lua")
local render2d = import("goluwa/render2d/render2d.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local steam = import("goluwa/steam/steam.lua")
local Visual = import("goluwa/entities/components/visual.lua").Library
local Color = import("goluwa/structs/color.lua")
-- Debug: Draw shadow map as picture-in-picture
local show_shadow_map = false
-- Cascade colors for reference (matching shader)
local cascade_colors = {
	Color(1.0, 0.2, 0.2, 1.0), -- Red for cascade 1
	Color(0.2, 1.0, 0.2, 1.0), -- Green for cascade 2
	Color(0.2, 0.2, 1.0, 1.0), -- Blue for cascade 3
	Color(1.0, 1.0, 0.2, 1.0), -- Yellow for cascade 4
}

event.AddListener("Draw2D", "debug_shadow_map", function(cmd, dt)
	if not show_shadow_map then return end

	local sun = render3d.GetLights()[1]

	if not sun or not sun:GetCastShadows() then return end

	local shadow_map = sun:GetShadowMap()

	if not shadow_map then return end

	-- Draw all cascade shadow maps
	local cascade_count = shadow_map:GetCascadeCount()
	local cascade_splits = shadow_map:GetCascadeSplits()
	local cascade_draw_calls = Visual.GetShadowDrawCallStats(shadow_map) or {}
	local size = 200
	local margin = 10
	local spacing = 10
	local panel_padding = 8

	for i = 1, cascade_count do
		local depth_texture = shadow_map:GetDepthTexture(i)

		if not depth_texture then continue end

		local x = margin + (i - 1) * (size + spacing)
		local y = margin
		local color = cascade_colors[i] or Color(1, 1, 0, 1)
		local tex_size = depth_texture:GetSize()
		local resolution = string.format("%dx%d", tex_size.x, tex_size.y)
		local split_dist = cascade_splits[i] and string.format("%.1f", cascade_splits[i]) or "?"
		local draw_calls = cascade_draw_calls[i] or 0
		-- Dark backdrop so far-clear depth does not look like a missing cascade.
		render2d.SetTexture(nil)
		render2d.SetColor(0.06, 0.07, 0.09, 0.92)
		render2d.DrawRoundedRect(x - panel_padding, y - panel_padding, size + panel_padding * 2, size + 64, 8)
		-- Draw the raw depth preview tinted with the cascade color for quick association
		-- with the in-scene cascade debug colors.
		render2d.SetTexture(depth_texture)
		render2d.SetColor(color:Unpack())
		render2d.DrawRect(x, y, size, size)
		render2d.SetTexture(nil)
		render2d.SetColor(color:Unpack())
		render2d.DrawOutlinedRect(x - 1, y - 1, size + 2, size + 2, 2, 0)
		-- Draw label with cascade info (use same color as 3D visualization)
		render2d.SetTexture(nil)
		render2d.DrawText{
			text = "Cascade " .. i .. " (z<" .. split_dist .. ")",
			x = x,
			y = y + size + 5,
			foreground_color = Color(color:Unpack()),
		}
		local muted_color = Color(0.85, 0.88, 0.92, 1)
		render2d.DrawText{
			text = "raw depth  " .. resolution,
			x = x,
			y = y + size + 23,
			foreground_color = muted_color,
		}
		render2d.DrawText{
			text = "draw calls  " .. draw_calls,
			x = x,
			y = y + size + 41,
			foreground_color = muted_color,
		}
	end
end)

event.AddListener("KeyInput", "shadow_debug", function(key, press)
	if not press then return end

	if key == "j" then show_shadow_map = not show_shadow_map end
end)
