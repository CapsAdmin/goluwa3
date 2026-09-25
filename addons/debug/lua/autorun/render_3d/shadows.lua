local ffi = require("ffi")
local event = import("goluwa/event.lua")
local system = import("goluwa/system.lua")
local render2d = import("goluwa/render2d/render2d.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local ShadowMap = import("goluwa/render3d/shadow_map.lua")
local Texture = import("goluwa/render/texture.lua")
local debug_draw = import("goluwa/debug_draw.lua")
local Visual = import("goluwa/entities/components/visual.lua").Library
local Color = import("goluwa/structs/color.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
--[[
	Sun shadow debug view, toggled with "j" (or _G.SHADOW_DEBUG_VIEW = true).

	Per cascade: a contrast stretched depth preview (the raw maps are nearly
	flat because a whole slice sits in a narrow depth band), the split range,
	resolution and texel size, how many frames ago it was rendered, how many
	shadow batches survived culling, and for the farthest cascade how close
	the camera is to forcing a refit. Each cascade's projection box is drawn in
	the world in its color so a stale or badly fitted cascade is obvious.
]]
local show_shadow_map = false
local PREVIEW_SIZE = 256
local PREVIEW_REFRESH_FRAMES = 30
local cascade_colors = {
	Color(1.0, 0.2, 0.2, 1.0),
	Color(0.2, 1.0, 0.2, 1.0),
	Color(0.2, 0.2, 1.0, 1.0),
	Color(1.0, 1.0, 0.2, 1.0),
}
local inset_color = Color(1.0, 0.5, 1.0, 1.0)
local previews = setmetatable({}, {__mode = "k"})

local function get_preview(shadow_map, cascade_index)
	local per_map = previews[shadow_map]

	if not per_map then
		per_map = {}
		previews[shadow_map] = per_map
	end

	local preview = per_map[cascade_index]

	if not preview then
		preview = {
			pixels = ffi.new("uint8_t[?]", PREVIEW_SIZE * PREVIEW_SIZE * 4),
			texture = Texture.New{
				width = PREVIEW_SIZE,
				height = PREVIEW_SIZE,
				format = "r8g8b8a8_unorm",
				buffer = ffi.new("uint8_t[?]", PREVIEW_SIZE * PREVIEW_SIZE * 4),
				sampler = {min_filter = "nearest", mag_filter = "nearest"},
			},
			last_frame = -math.huge,
			min_depth = 0,
			max_depth = 1,
		}
		per_map[cascade_index] = preview
	end

	return preview
end

local function refresh_preview(preview, depth_texture)
	local downloaded = depth_texture:Download()
	local width = downloaded.width
	local height = downloaded.height
	local pixels = preview.pixels
	local is_d16 = downloaded.format == "d16_unorm"
	local d16 = is_d16 and ffi.cast("uint16_t*", downloaded.pixels) or nil
	local d32 = not is_d16 and ffi.cast("float*", downloaded.pixels) or nil
	local sampled = ffi.new("float[?]", PREVIEW_SIZE * PREVIEW_SIZE)
	local min_depth, max_depth = math.huge, -math.huge

	for y = 0, PREVIEW_SIZE - 1 do
		local src_y = math.floor((y + 0.5) * height / PREVIEW_SIZE)

		for x = 0, PREVIEW_SIZE - 1 do
			local src_x = math.floor((x + 0.5) * width / PREVIEW_SIZE)
			local depth = d16 and d16[src_y * width + src_x] / 65535 or d32[src_y * width + src_x]
			sampled[y * PREVIEW_SIZE + x] = depth

			if depth < 0.9999 then
				if depth < min_depth then min_depth = depth end

				if depth > max_depth then max_depth = depth end
			end
		end
	end

	if min_depth > max_depth then min_depth, max_depth = 0, 1 end

	local range = math.max(max_depth - min_depth, 1e-6)

	for i = 0, PREVIEW_SIZE * PREVIEW_SIZE - 1 do
		local depth = sampled[i]
		local value = depth >= 0.9999 and
			0 or
			255 - math.floor(math.clamp((depth - min_depth) / range, 0, 1) * 215)
		pixels[i * 4] = value
		pixels[i * 4 + 1] = value
		pixels[i * 4 + 2] = value
		pixels[i * 4 + 3] = 255
	end

	preview.texture:Upload(pixels)
	preview.min_depth = min_depth
	preview.max_depth = max_depth
	preview.last_frame = system.GetFrameNumber()
end

local function draw_cascade_box(shadow_map, cascade_index, color, id)
	local cascade = shadow_map.cascade[cascade_index]
	local aabb = cascade.projection_aabb

	if not aabb then return end

	local light_to_world = cascade.view_matrix:GetInverse()
	local corners = {}

	for i, corner in ipairs{
		Vec3(aabb.min_x, aabb.min_y, aabb.min_z),
		Vec3(aabb.max_x, aabb.min_y, aabb.min_z),
		Vec3(aabb.max_x, aabb.max_y, aabb.min_z),
		Vec3(aabb.min_x, aabb.max_y, aabb.min_z),
		Vec3(aabb.min_x, aabb.min_y, aabb.max_z),
		Vec3(aabb.max_x, aabb.min_y, aabb.max_z),
		Vec3(aabb.max_x, aabb.max_y, aabb.max_z),
		Vec3(aabb.min_x, aabb.max_y, aabb.max_z),
	} do
		corners[i] = light_to_world:TransformVector(corner)
	end

	for i, edge in ipairs{
		{1, 2},
		{2, 3},
		{3, 4},
		{4, 1},
		{5, 6},
		{6, 7},
		{7, 8},
		{8, 5},
		{1, 5},
		{2, 6},
		{3, 7},
		{4, 8},
	} do
		debug_draw.DrawLine{
			id = id .. "_edge_" .. i,
			from = corners[edge[1]],
			to = corners[edge[2]],
			color = color,
			width = 2,
			ignore_z = true,
			time = 2,
		}
	end
end

local function draw_panel(shadow_map, cascade_index, x, y, size, color, title, extra_lines, panel_id)
	local cascade = shadow_map.cascade[cascade_index]
	local depth_texture = shadow_map:GetDepthTexture(cascade_index)
	local preview = get_preview(shadow_map, cascade_index)
	local frame = system.GetFrameNumber()

	if
		frame - preview.last_frame >= PREVIEW_REFRESH_FRAMES and
		cascade.last_rendered_frame
	then
		refresh_preview(preview, depth_texture)
	end

	local lines = {
		title,
		(
			"%dx%d %s  texel %.2f u"
		):format(
			depth_texture:GetWidth(),
			depth_texture:GetHeight(),
			cascade.format or shadow_map.format,
			cascade.texel_world_size or 0
		),
		(
			"rendered %s frames ago"
		):format(
			cascade.last_rendered_frame and
				tostring(frame - cascade.last_rendered_frame) or
				"never"
		),
		(
			"depth %.3f .. %.3f"
		):format(preview.min_depth, preview.max_depth),
	}

	for _, line in ipairs(extra_lines) do
		lines[#lines + 1] = line
	end

	local padding = 8
	local line_height = 18
	local panel_width = math.max(size, 250)
	render2d.SetTexture(nil)
	render2d.SetColor(0.06, 0.07, 0.09, 0.92)
	render2d.DrawRoundedRect(
		x - padding,
		y - padding,
		panel_width + padding * 2,
		size + padding * 2 + #lines * line_height,
		8
	)
	render2d.SetTexture(preview.texture)
	render2d.SetColor(color.r, color.g, color.b, 1)
	render2d.DrawRect(x, y, size, size)
	render2d.SetTexture(nil)
	render2d.DrawOutlinedRect(x - 1, y - 1, size + 2, size + 2, 2, 0)

	for i, line in ipairs(lines) do
		render2d.DrawText{
			text = line,
			x = x,
			y = y + size + 4 + (i - 1) * line_height,
			foreground_color = i == 1 and color or Color(0.85, 0.88, 0.92, 1),
		}
	end

	draw_cascade_box(shadow_map, cascade_index, color, panel_id)
end

event.AddListener("Draw2D", "debug_shadow_map", function(cmd, dt)
	if not show_shadow_map and not rawget(_G, "SHADOW_DEBUG_VIEW") then return end

	local sun = _G.SUN_ENTITY

	if not sun then return end

	local shadow_maps = {}

	for _, shadow_map in ipairs(ShadowMap.GetActiveMaps()) do
		if shadow_map.enabled and shadow_map.light == sun then
			shadow_maps[#shadow_maps + 1] = shadow_map
		end
	end

	if #shadow_maps == 0 then return end

	local policy = shadow_maps[1].policy
	local size = 200
	local margin = 12
	local spacing = 14
	local camera = render3d.GetCamera()
	local panel_index = 0

	for _, shadow_map in ipairs(shadow_maps) do
		local is_inset = shadow_map.role == "inset"
		local cascade_count = shadow_map:GetCascadeCount()
		local splits = shadow_map:GetCascadeSplits()
		local cull_stats = Visual.GetShadowGPUCullingStats(shadow_map) or {}
		local previous_split = 0

		for i = 1, cascade_count do
			panel_index = panel_index + 1
			local cascade = shadow_map.cascade[i]
			local stats = cull_stats[i] or {}
			local extra = {
				(
					"batches %s/%s  fallback %s"
				):format(
					tostring(stats.gpu_active_batch_count or "?"),
					tostring(stats.gpu_total_batch_count or "?"),
					tostring(stats.fallback_visible_entry_count or "?")
				),
			}

			if
				not is_inset and
				cascade_count > 1 and
				i == cascade_count and
				policy.farthest_cascade_update_mode == "world_changed"
			then
				local moved = cascade.last_camera_position and
					camera and
					camera:GetPosition():Distance(cascade.last_camera_position) or
					0
				local turned = 0

				if cascade.last_camera_forward and camera then
					turned = math.deg(
						math.acos(math.clamp(camera:GetRotation():GetForward():Dot(cascade.last_camera_forward), -1, 1))
					)
				end

				extra[#extra + 1] = (
					"refit when moved %.0f/%d u"
				):format(moved, policy.farthest_cascade_camera_position_threshold or 0)
				extra[#extra + 1] = (
					"or turned %.1f/%d deg or world changes"
				):format(turned, policy.farthest_cascade_camera_rotation_threshold or 5)
			end

			draw_panel(
				shadow_map,
				i,
				margin + (panel_index - 1) * (250 + spacing + 16),
				margin,
				size,
				is_inset and inset_color or cascade_colors[i] or Color(1, 1, 0, 1),
				is_inset and
					(
						"Inset  0 .. %.0f"
					):format(splits[i] or 0) or
					(
						"Cascade %d  %.0f .. %.0f"
					):format(i, previous_split, splits[i] or 0),
				extra,
				"shadow_debug_map_" .. panel_index
			)
			previous_split = splits[i] or previous_split
		end
	end
end)

event.AddListener("KeyInput", "shadow_debug", function(key, press)
	if not press then return end

	if key == "j" then show_shadow_map = not show_shadow_map end
end)
