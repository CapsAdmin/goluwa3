local event = import("goluwa/event.lua")
local render2d = import("goluwa/render2d/render2d.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local steam = import("goluwa/steam/steam.lua")
local Visual = import("goluwa/entities/components/visual.lua").Library
local Color = import("goluwa/structs/color.lua")
local renderdoc = import("goluwa/bindings/renderdoc.lua")
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

		if depth_texture then
			local x = margin + (i - 1) * (size + spacing)
			local y = margin
			local color = cascade_colors[i] or {1, 1, 0, 1}
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
			render2d.SetColor(color[1], color[2], color[3], 1)
			render2d.DrawRect(x, y, size, size)
			render2d.SetTexture(nil)
			render2d.SetColor(color[1], color[2], color[3], 1)
			render2d.DrawOutlinedRect(x - 1, y - 1, size + 2, size + 2, 2, 0)
			-- Draw label with cascade info (use same color as 3D visualization)
			render2d.SetTexture(nil)
			render2d.DrawText{
				text = "Cascade " .. i .. " (z<" .. split_dist .. ")",
				x = x,
				y = y + size + 5,
				foreground_color = Color(color[1], color[2], color[3], 1),
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
	end
end)

-- Debug: Draw SSR buffer
local show_ssr_buffer = false
local show_cry_terrain_textures = false

local function is_valid_texture(texture)
	return texture and texture.IsValid and texture:IsValid()
end

local function get_active_cry_terrain_render_data()
	local renderer = steam.active_cry_terrain_renderer

	if not renderer then return nil end

	local keys = {}

	for _, tile in pairs(renderer.ActiveTiles or {}) do
		local cache_key = tile.render_cache_key

		if cache_key and renderer.TileRenderCache and renderer.TileRenderCache[cache_key] then
			keys[cache_key] = true
		end
	end

	if
		renderer.FarState and
		renderer.FarState.render_cache_key and
		renderer.TileRenderCache[renderer.FarState.render_cache_key]
	then
		keys[renderer.FarState.render_cache_key] = true
	end

	local sorted = {}

	for cache_key in pairs(keys) do
		list.insert(sorted, cache_key)
	end

	if not sorted[1] then
		for cache_key in pairs(renderer.TileRenderCache or {}) do
			list.insert(sorted, cache_key)
		end
	end

	table.sort(sorted)

	if not sorted[1] then return nil end

	local cache_key = sorted[1]
	return renderer.TileRenderCache[cache_key], cache_key, #sorted, renderer
end

local function draw_texture_preview(texture, title, subtitle, x, y, size)
	render2d.SetTexture(nil)
	render2d.SetColor(0.06, 0.07, 0.09, 0.94)
	render2d.DrawRoundedRect(x - 6, y - 6, size + 12, size + 42, 8)

	if is_valid_texture(texture) then
		render2d.SetTexture(texture)
		render2d.SetColor(1, 1, 1, 1)
		render2d.DrawRect(x, y, size, size)
	else
		render2d.SetTexture(nil)
		render2d.SetColor(0.16, 0.16, 0.18, 1)
		render2d.DrawRect(x, y, size, size)
		render2d.DrawText{
			text = "missing",
			x = x + 8,
			y = y + size * 0.5 - 8,
			foreground_color = Color(0.85, 0.4, 0.4, 1),
		}
	end

	render2d.SetTexture(nil)
	render2d.DrawText{
		text = title,
		x = x,
		y = y + size + 4,
		foreground_color = Color(0.85, 0.88, 0.92, 1),
	}

	if subtitle and subtitle ~= "" then
		render2d.DrawText{
			text = subtitle,
			x = x,
			y = y + size + 20,
			foreground_color = Color(0.58, 0.64, 0.70, 1),
		}
	end
end

event.AddListener("Draw2D", "debug_cry_terrain_textures", function(cmd, dt)
	if not show_cry_terrain_textures then return end

	local render_data, cache_key, cache_count = get_active_cry_terrain_render_data()

	if not render_data or not render_data.material then
		render2d.SetTexture(nil)
		render2d.SetColor(0.06, 0.07, 0.09, 0.94)
		render2d.DrawRoundedRect(10, 320, 360, 56, 8)
		render2d.DrawText{
			text = "Cry terrain textures: no active terrain tile cache",
			x = 18,
			y = 336,
			foreground_color = Color(0.85, 0.88, 0.92, 1),
		}
		return
	end

	local material = render_data.material
	local size = 144
	local spacing = 14
	local start_x = 10
	local start_y = 320
	local titles = {
		{"weights", material:GetTerrainMaterialTexture(), "tile weights"},
		{"baked albedo", render_data.albedo_texture, "macro baked color"},
		{"baked normal", render_data.normal_texture, "tile normal"},
		{
			render_data.terrain_layer_names and
			render_data.terrain_layer_names[1] or
			"layer 1",
			material:GetTerrainLayer1Texture(),
			render_data.terrain_layer_slots and
			render_data.terrain_layer_slots[1] and
			(
				"slot " .. render_data.terrain_layer_slots[1]
			)
			or
			"",
		},
		{
			render_data.terrain_layer_names and
			render_data.terrain_layer_names[2] or
			"layer 2",
			material:GetTerrainLayer2Texture(),
			render_data.terrain_layer_slots and
			render_data.terrain_layer_slots[2] and
			(
				"slot " .. render_data.terrain_layer_slots[2]
			)
			or
			"",
		},
		{
			render_data.terrain_layer_names and
			render_data.terrain_layer_names[3] or
			"layer 3",
			material:GetTerrainLayer3Texture(),
			render_data.terrain_layer_slots and
			render_data.terrain_layer_slots[3] and
			(
				"slot " .. render_data.terrain_layer_slots[3]
			)
			or
			"",
		},
		{
			render_data.terrain_layer_names and
			render_data.terrain_layer_names[4] or
			"layer 4",
			material:GetTerrainLayer4Texture(),
			render_data.terrain_layer_slots and
			render_data.terrain_layer_slots[4] and
			(
				"slot " .. render_data.terrain_layer_slots[4]
			)
			or
			"",
		},
	}
	render2d.SetTexture(nil)
	render2d.SetColor(0.06, 0.07, 0.09, 0.90)
	render2d.DrawRoundedRect(start_x - 10, start_y - 28, size * 3 + spacing * 2 + 20, size * 3 + 132, 10)
	render2d.DrawText{
		text = "Cry Terrain Texture Debug",
		x = start_x,
		y = start_y - 18,
		foreground_color = Color(0.95, 0.97, 1.0, 1),
	}
	render2d.DrawText{
		text = string.format("cache %s (%d live)", tostring(cache_key), cache_count or 0),
		x = start_x,
		y = start_y,
		foreground_color = Color(0.58, 0.64, 0.70, 1),
	}

	for i, entry in ipairs(titles) do
		local column = (i - 1) % 3
		local row = math.floor((i - 1) / 3)
		draw_texture_preview(
			entry[2],
			entry[1],
			entry[3],
			start_x + column * (size + spacing),
			start_y + 22 + row * (size + 54),
			size
		)
	end
end)

event.AddListener("Draw2D", "debug_ssr_buffer", function(cmd, dt)
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
	render2d.DrawText{text = "SSR Buffer (Half-Res)", x = x, y = y + size + 5}
end)
