local event = import("goluwa/event.lua")
local commands = import("goluwa/commands.lua")
local render = import("goluwa/render/render.lua")
local system = import("goluwa/system.lua")
local input = import("goluwa/input.lua")
local render2d = import("goluwa/render2d/render2d.lua")
local gfx = import("goluwa/render2d/gfx.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local steam = import("goluwa/steam/steam.lua")
local vulkan_memory = import("goluwa/render/vulkan/internal/memory.lua")
local callstack = import("goluwa/helpers/callstack.lua")
local Visual = import("goluwa/ecs/components/3d/visual.lua").Library
local fonts = import("goluwa/render2d/fonts.lua")
local renderdoc = import("goluwa/bindings/renderdoc.lua")

local function format_bytes(bytes)
	bytes = math.max(0, tonumber(bytes) or 0)

	if bytes >= 1024 * 1024 * 1024 then
		return string.format("%.2f GiB", bytes / 1024 / 1024 / 1024)
	end

	if bytes >= 1024 * 1024 then
		return string.format("%.2f MiB", bytes / 1024 / 1024)
	end

	if bytes >= 1024 then return string.format("%.2f KiB", bytes / 1024) end

	return string.format("%d B", bytes)
end

local function normalize_traceback(traceback)
	traceback = tostring(traceback or "unknown traceback")
	traceback = traceback:trim()

	if traceback == "" then return "unknown traceback" end

	return traceback
end

local function trim_traceback(traceback)
	traceback = normalize_traceback(traceback)
	local lines = callstack.format(traceback)

	if not lines[1] then return traceback end

	local start_index

	for i, line in ipairs(lines) do
		if line:find("goluwa/render/vulkan/internal/buffer.lua:", nil, true) then
			start_index = i

			break
		end
	end

	if not start_index then
		for i, line in ipairs(lines) do
			if line:find("goluwa/render/vulkan/internal/image.lua:", nil, true) then
				start_index = i

				break
			end
		end
	end

	if not start_index then
		for i, line in ipairs(lines) do
			if line:find("goluwa/render/vulkan/internal/", nil, true) then
				start_index = i

				break
			end
		end
	end

	if not start_index then return traceback end

	local end_index = #lines

	for i = start_index, #lines do
		if lines[i]:find("main.lua:", nil, true) then
			end_index = i

			break
		end
	end

	local out = {}

	for i = start_index, end_index do
		list.insert(out, lines[i])

		if i ~= end_index and lines[i] == "stack traceback:" then
			list.insert(out, "")
		end
	end

	if not out[1] then return traceback end

	return table.concat(out, "\n")
end

local function indent_traceback(traceback)
	local out = {}

	for _, line in ipairs(traceback:split("\n")) do
		list.insert(out, "  " .. line)
	end

	return table.concat(out, "\n")
end

commands.Add("dump_vulkan_memory=number[20]", function(limit)
	limit = math.max(1, math.floor(tonumber(limit) or 20))
	local total_bytes = 0
	local allocation_count = 0
	local freed_count = tonumber(vulkan_memory.total_freed_count) or 0
	local freed_bytes = tonumber(vulkan_memory.total_freed_bytes) or 0
	local hotspots = {}

	for _, allocation in pairs(vulkan_memory.Instances) do
		if allocation and allocation.size then
			local size = tonumber(allocation.size) or 0
			local traceback = trim_traceback(allocation.traceback)
			local hotspot = hotspots[traceback]

			if not hotspot then
				hotspot = {
					traceback = traceback,
					count = 0,
					bytes = 0,
				}
				hotspots[traceback] = hotspot
			end

			hotspot.count = hotspot.count + 1
			hotspot.bytes = hotspot.bytes + size
			total_bytes = total_bytes + size
			allocation_count = allocation_count + 1
		end
	end

	local sorted = {}

	for _, hotspot in pairs(hotspots) do
		list.insert(sorted, hotspot)
	end

	table.sort(sorted, function(a, b)
		if a.bytes ~= b.bytes then return a.bytes > b.bytes end

		if a.count ~= b.count then return a.count > b.count end

		return a.traceback < b.traceback
	end)

	logn(
		string.format(
			"Live Vulkan memory allocations: %d objects, %s total | Freed: %d objects, %s total",
			allocation_count,
			format_bytes(total_bytes),
			freed_count,
			format_bytes(freed_bytes)
		)
	)

	if #sorted == 0 then
		logn("No live Vulkan memory allocations tracked.")
		return
	end

	logn(string.format("Top %d Vulkan memory hotspots:", math.min(limit, #sorted)))

	for i = 1, math.min(limit, #sorted) do
		local hotspot = sorted[i]
		logn(
			string.format(
				"[%d] %s across %d allocations",
				i,
				format_bytes(hotspot.bytes),
				hotspot.count
			)
		)
		logn(indent_traceback(hotspot.traceback))
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

function events.Draw2D.debug_shadow_map(cmd, dt)
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
			gfx.DrawRoundedRect(x - panel_padding, y - panel_padding, size + panel_padding * 2, size + 64, 8)
			-- Draw the raw depth preview tinted with the cascade color for quick association
			-- with the in-scene cascade debug colors.
			render2d.SetTexture(depth_texture)
			render2d.SetColor(color[1], color[2], color[3], 1)
			render2d.DrawRect(x, y, size, size)
			render2d.SetTexture(nil)
			render2d.SetColor(color[1], color[2], color[3], 1)
			gfx.DrawOutlinedRect(x - 1, y - 1, size + 2, size + 2, 2, 0)
			-- Draw label with cascade info (use same color as 3D visualization)
			render2d.SetTexture(nil)
			render2d.SetColor(color[1], color[2], color[3], 1)
			fonts.GetFont():DrawText("Cascade " .. i .. " (z<" .. split_dist .. ")", x, y + size + 5)
			render2d.SetColor(0.85, 0.88, 0.92, 1)
			fonts.GetFont():DrawText("raw depth  " .. resolution, x, y + size + 23)
			fonts.GetFont():DrawText("draw calls  " .. draw_calls, x, y + size + 41)
		end
	end
end

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
	gfx.DrawRoundedRect(x - 6, y - 6, size + 12, size + 42, 8)

	if is_valid_texture(texture) then
		render2d.SetTexture(texture)
		render2d.SetColor(1, 1, 1, 1)
		render2d.DrawRect(x, y, size, size)
	else
		render2d.SetTexture(nil)
		render2d.SetColor(0.16, 0.16, 0.18, 1)
		render2d.DrawRect(x, y, size, size)
		render2d.SetColor(0.85, 0.4, 0.4, 1)
		fonts.GetFont():DrawText("missing", x + 8, y + size * 0.5 - 8)
	end

	render2d.SetTexture(nil)
	render2d.SetColor(0.85, 0.88, 0.92, 1)
	fonts.GetFont():DrawText(title, x, y + size + 4)

	if subtitle and subtitle ~= "" then
		render2d.SetColor(0.58, 0.64, 0.70, 1)
		fonts.GetFont():DrawText(subtitle, x, y + size + 20)
	end
end

function events.Draw2D.debug_cry_terrain_textures(cmd, dt)
	if not show_cry_terrain_textures then return end

	local render_data, cache_key, cache_count = get_active_cry_terrain_render_data()
	fonts.SetFont(fonts.GetDefaultFont())

	if not render_data or not render_data.material then
		render2d.SetTexture(nil)
		render2d.SetColor(0.06, 0.07, 0.09, 0.94)
		gfx.DrawRoundedRect(10, 320, 360, 56, 8)
		render2d.SetColor(0.85, 0.88, 0.92, 1)
		fonts.GetFont():DrawText("Cry terrain textures: no active terrain tile cache", 18, 336)
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
	gfx.DrawRoundedRect(start_x - 10, start_y - 28, size * 3 + spacing * 2 + 20, size * 3 + 132, 10)
	render2d.SetColor(0.95, 0.97, 1.0, 1)
	fonts.GetFont():DrawText("Cry Terrain Texture Debug", start_x, start_y - 18)
	render2d.SetColor(0.58, 0.64, 0.70, 1)
	fonts.GetFont():DrawText(
		string.format("cache %s (%d live)", tostring(cache_key), cache_count or 0),
		start_x,
		start_y
	)

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
end

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
	fonts.GetFont():DrawText("SSR Buffer (Half-Res)", x, y + size + 5)
end

function events.KeyInput.render3d_debug(key, press)
	if not press then return end

	if renderdoc.IsInitialized() then
		if key == "f8" then
			renderdoc.CaptureFrame(render.GetRenderDocDevicePointer(), system.GetWindow())
			print("RenderDoc capture queued")
		end

		if key == "f9" then
			local renderdoc_device = render.GetRenderDocDevicePointer()
			local renderdoc_window = system.GetWindow()

			if renderdoc.IsCapturing() then
				local stopped = renderdoc.StopCapture(renderdoc_device, renderdoc_window)
				print(stopped and "RenderDoc capture stopped" or "RenderDoc capture stop failed")
			else
				renderdoc.StartCapture(renderdoc_device, renderdoc_window)
				print("RenderDoc capture started")
			end
		end

		if key == "f11" then
			local last_capture = renderdoc.GetLastCapture()

			if last_capture and last_capture.filename then
				renderdoc.OpenUI(last_capture.filename)
			else
				renderdoc.OpenUI()
			end
		end

		return
	end

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

	if key == "f5" then
		show_cry_terrain_textures = not show_cry_terrain_textures
		print("Cry terrain texture debug: " .. (show_cry_terrain_textures and "ON" or "OFF"))
	end

	if key == "f4" then
		render.stats = not render.stats
		print("Render3D stats: " .. (render3d.stats and "ON" or "OFF"))
	end

	-- Toggle freeze frustum
	if key == "f" then render3d.freeze_culling = not render3d.freeze_culling end

	-- Toggle debug modes
	if key == "h" then print("Debug mode: " .. render3d.CycleDebugMode()) end
end
