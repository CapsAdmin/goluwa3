local ffi = require("ffi")
local event = import("goluwa/event.lua")
local commands = import("goluwa/cli/commands.lua")
local render2d = import("goluwa/render2d/render2d.lua")
local system = import("goluwa/system.lua")
local Color = import("goluwa/structs/color.lua")
local debug_draw = import("goluwa/debug_draw.lua")
local envprobe = import("goluwa/render3d/envprobe.lua")
local face_names = {"px", "nx", "py", "ny", "pz", "nz"}
local draw_enabled = false
local labels_enabled = true
local focus_index = 0
local show_environment = false
local last_overlay_probe_count = 0
local grid_enabled = false
local grid_show_depth = false
local grid_tile_size = 88
local grid_margin = 12
local grid_limit = 4
local probe_face_textures = setmetatable({}, {__mode = "k"})

local function get_reflection_probe(index)
	index = math.floor(index or 0)

	if index < 1 then return nil end

	return envprobe.probes[index]
end

local function create_face_texture_wrapper(texture, view, debug_name)
	return {
		debug_name = debug_name,
		GetView = function()
			return view
		end,
		GetImage = function()
			return texture:GetImage()
		end,
		GetSamplerConfig = function()
			return texture:GetSamplerConfig()
		end,
		IsCubemap = function()
			return false
		end,
	}
end

local function get_probe_face_texture(probe, face_index, show_depth)
	local cache = probe_face_textures[probe]

	if not cache then
		cache = {source = {}, depth = {}}
		probe_face_textures[probe] = cache
	end

	local cache_key = show_depth and "depth" or "source"
	local bucket = cache[cache_key]
	local tex = bucket[face_index]

	if tex then return tex end

	local source_texture = show_depth and probe.depth_cubemap or probe.source_cubemap
	local view = show_depth and
		probe.depth_face_views[face_index] or
		probe.source_face_views[face_index]
	tex = create_face_texture_wrapper(
		source_texture,
		view,
		string.format("envprobe_%s_face_%s", cache_key, face_names[face_index + 1])
	)
	bucket[face_index] = tex
	return tex
end

local function get_probe_overlay_id(kind, index)
	return string.format("envprobe_debug_%s_%d", kind, index)
end

local function should_draw_probe(index)
	return focus_index <= 0 or focus_index == index
end

local function get_probe_debug_color(index, probe)
	if probe.type == envprobe.TYPE_ENVIRONMENT then
		return Color(0.35, 0.65, 1.0, 0.16)
	end

	if probe == envprobe.current_probe then
		return Color(1.0, 0.55, 0.2, 0.22)
	end

	if probe.needs_update then return Color(1.0, 0.86, 0.2, 0.18) end

	if probe.update_mode == envprobe.UPDATE_DYNAMIC then
		return Color(0.35, 1.0, 0.45, 0.18)
	end

	if probe.update_mode == envprobe.UPDATE_MANUAL then
		return Color(0.95, 0.35, 1.0, 0.18)
	end

	return Color(0.25, 0.9, 1.0, 0.16)
end

local function build_probe_debug_lines(index, probe)
	local lines = {}
	local now = system.GetTime()
	local last_rendered = probe.last_rendered or 0
	local age = last_rendered > 0 and (now - last_rendered) or nil
	local role = probe.type == envprobe.TYPE_ENVIRONMENT and "env" or ("probe " .. index)
	lines[1] = string.format("%s %s", role, probe.update_mode or "unknown")
	lines[2] = string.format(
		"r %.1f size %d dirty %s",
		probe.radius or 0,
		probe.size or 0,
		tostring(probe.needs_update == true)
	)

	if probe == envprobe.current_probe then
		lines[3] = string.format("capturing face %d", envprobe.current_face)
	elseif age then
		lines[3] = string.format("last %.2fs ago", age)
	else
		lines[3] = "last never"
	end

	return lines
end

local function clear_debug_overlay()
	debug_draw.Remove(get_probe_overlay_id("sphere", 0))
	debug_draw.Remove(get_probe_overlay_id("text", 0))

	for i = 1, math.max(last_overlay_probe_count, #envprobe.probes) do
		debug_draw.Remove(get_probe_overlay_id("sphere", i))
		debug_draw.Remove(get_probe_overlay_id("text", i))
	end

	last_overlay_probe_count = #envprobe.probes
end

local function set_debug_draw_enabled(enabled)
	draw_enabled = enabled == true

	if not draw_enabled then clear_debug_overlay() end
end

local function set_debug_labels_enabled(enabled)
	labels_enabled = enabled ~= false

	if not labels_enabled then
		debug_draw.Remove(get_probe_overlay_id("text", 0))

		for i = 1, math.max(last_overlay_probe_count, #envprobe.probes) do
			debug_draw.Remove(get_probe_overlay_id("text", i))
		end
	end
end

local function set_debug_focus(index)
	focus_index = math.max(math.floor(index or 0), 0)
end

local function set_debug_show_environment(enabled)
	show_environment = enabled == true

	if not show_environment then
		debug_draw.Remove(get_probe_overlay_id("sphere", 0))
		debug_draw.Remove(get_probe_overlay_id("text", 0))
	end
end

local function draw_debug_overlay()
	if not draw_enabled then return end

	local probe_count = #envprobe.probes
	local previous_count = last_overlay_probe_count

	if show_environment and envprobe.environment_probe and should_draw_probe(0) then
		local env_probe = envprobe.environment_probe
		debug_draw.DrawSphere{
			id = get_probe_overlay_id("sphere", 0),
			position = env_probe.position,
			radius = env_probe.radius or env_probe.size * 0.25,
			color = get_probe_debug_color(0, env_probe),
			ignore_z = true,
			double_sided = true,
			translucent = true,
			time = 0.25,
		}

		if labels_enabled then
			debug_draw.DrawText{
				id = get_probe_overlay_id("text", 0),
				position = env_probe.position,
				lines = build_probe_debug_lines(0, env_probe),
				offset = {14, -10},
				background_alpha = 0.45,
				time = 0.25,
			}
		end
	else
		debug_draw.Remove(get_probe_overlay_id("sphere", 0))
		debug_draw.Remove(get_probe_overlay_id("text", 0))
	end

	for i, probe in ipairs(envprobe.probes) do
		if should_draw_probe(i) then
			debug_draw.DrawSphere{
				id = get_probe_overlay_id("sphere", i),
				position = probe.position,
				radius = probe.radius or envprobe.REFLECTION_RADIUS,
				color = get_probe_debug_color(i, probe),
				ignore_z = true,
				double_sided = true,
				translucent = true,
				time = 0.25,
			}

			if labels_enabled then
				debug_draw.DrawText{
					id = get_probe_overlay_id("text", i),
					position = probe.position,
					lines = build_probe_debug_lines(i, probe),
					offset = {14, -10},
					background_alpha = 0.45,
					time = 0.25,
				}
			else
				debug_draw.Remove(get_probe_overlay_id("text", i))
			end
		else
			debug_draw.Remove(get_probe_overlay_id("sphere", i))
			debug_draw.Remove(get_probe_overlay_id("text", i))
		end
	end

	if previous_count > probe_count then
		for i = probe_count + 1, previous_count do
			debug_draw.Remove(get_probe_overlay_id("sphere", i))
			debug_draw.Remove(get_probe_overlay_id("text", i))
		end
	end

	last_overlay_probe_count = probe_count
end

local function set_debug_grid_enabled(enabled)
	grid_enabled = enabled == true
end

local function set_debug_grid_show_depth(enabled)
	grid_show_depth = enabled == true
end

local function draw_probe_grid_tile(x, y, tile_size, probe, probe_index, face_index)
	local texture = get_probe_face_texture(probe, face_index, grid_show_depth)
	render2d.SetColor(0.08, 0.08, 0.08, 0.92)
	render2d.SetTexture(nil)
	render2d.DrawRect(x - 1, y - 1, tile_size + 2, tile_size + 2)
	render2d.SetColor(1, 1, 1, 1)
	render2d.SetTexture(texture)
	render2d.DrawRect(x, y, tile_size, tile_size)
	render2d.SetTexture(nil)
	debug_draw.DrawTextBlock(
		{
			string.format(
				"%s  p%d f%s",
				grid_show_depth and "depth" or "src",
				probe_index,
				face_names[face_index + 1]
			),
		},
		x + 4,
		y + tile_size - 18,
		{
			padding = 4,
			line_gap = 0,
			background_alpha = 0.45,
		}
	)
end

local function draw_debug_grid()
	if not grid_enabled then return end

	local tile_size = math.max(math.floor(grid_tile_size), 32)
	local margin = math.max(math.floor(grid_margin), 4)
	local screen_w, screen_h = render2d.GetSize()
	local visible_limit = math.max(math.floor(grid_limit), 1)
	local probes_to_draw = {}

	if focus_index > 0 then
		local probe = get_reflection_probe(focus_index)

		if probe then probes_to_draw[1] = {index = focus_index, probe = probe} end
	else
		for i, probe in ipairs(envprobe.probes) do
			probes_to_draw[#probes_to_draw + 1] = {index = i, probe = probe}

			if #probes_to_draw >= visible_limit then break end
		end
	end

	if #probes_to_draw == 0 then
		debug_draw.DrawTextBlock(
			{"envprobe grid", "no reflection probes"},
			margin,
			margin,
			{background_alpha = 0.6}
		)
		return
	end

	local x = margin
	local y = margin
	local stride_x = tile_size + margin
	local probe_block_w = stride_x * 6
	local probe_block_h = tile_size + 38

	for _, entry in ipairs(probes_to_draw) do
		if x + probe_block_w > screen_w - margin then
			x = margin
			y = y + probe_block_h + margin
		end

		if y + probe_block_h > screen_h - margin then break end

		debug_draw.DrawTextBlock(
			{
				string.format("probe %d  %s", entry.index, entry.probe.update_mode or "unknown"),
				string.format(
					"dirty=%s last=%s",
					tostring(entry.probe.needs_update == true),
					(
							entry.probe.last_rendered or
							0
						) > 0 and
						string.format("%.2fs", system.GetTime() - entry.probe.last_rendered) or
						"never"
				),
			},
			x,
			y,
			{background_alpha = 0.58}
		)
		local tile_y = y + 34

		for face_index = 0, 5 do
			local tile_x = x + face_index * stride_x
			draw_probe_grid_tile(tile_x, tile_y, tile_size, entry.probe, entry.index, face_index)
		end

		x = x + probe_block_w + margin
	end

	if focus_index <= 0 and #envprobe.probes > #probes_to_draw then
		debug_draw.DrawTextBlock(
			{string.format("showing %d / %d probes", #probes_to_draw, #envprobe.probes)},
			margin,
			screen_h - 34,
			{background_alpha = 0.55}
		)
	end
end

local function get_depth_face_stats(texture, face_index)
	local downloaded = texture:Download{base_array_layer = face_index}
	local pixels = ffi.cast("float*", downloaded.pixels)
	local count = downloaded.width * downloaded.height
	local min_depth = math.huge
	local max_depth = -math.huge
	local sum_depth = 0
	local geometry_pixels = 0
	local nonzero_pixels = 0

	for i = 0, count - 1 do
		local value = pixels[i]

		if value < min_depth then min_depth = value end

		if value > max_depth then max_depth = value end

		sum_depth = sum_depth + value

		if value > 0.0001 then nonzero_pixels = nonzero_pixels + 1 end

		if value > 0.0001 and value < 999 then geometry_pixels = geometry_pixels + 1 end
	end

	return {
		min_depth = min_depth,
		max_depth = max_depth,
		avg_depth = sum_depth / math.max(count, 1),
		geometry_pixels = geometry_pixels,
		nonzero_pixels = nonzero_pixels,
		pixel_count = count,
	}
end

local function dump_probe_faces(index)
	local probe = get_reflection_probe(index)

	if not probe then
		logf(
			"[envprobe] no reflection probe at index %s (have %d)\n",
			tostring(index),
			#envprobe.probes
		)
		return nil
	end

	if (probe.last_rendered or 0) == 0 then
		logf(
			"[envprobe] probe %d has never rendered; face contents may still be undefined\n",
			index
		)
	end

	for face_index = 0, 5 do
		local stats = get_depth_face_stats(probe.depth_cubemap, face_index)
		logf(
			"[envprobe] probe=%d face=%s depth[min=%.3f avg=%.3f max=%.3f nonzero=%.2f%% geometry=%.2f%%]\n",
			index,
			face_names[face_index + 1],
			stats.min_depth,
			stats.avg_depth,
			stats.max_depth,
			stats.nonzero_pixels / math.max(stats.pixel_count, 1) * 100,
			stats.geometry_pixels / math.max(stats.pixel_count, 1) * 100
		)
	end

	return true
end

local function export_probe_depth(index)
	local probe = get_reflection_probe(index)

	if not probe then
		logf(
			"[envprobe] no reflection probe at index %s (have %d)\n",
			tostring(index),
			#envprobe.probes
		)
		return nil
	end

	local fs = import("goluwa/filesystem/fs.lua")
	local dir = "tmp/envprobe/"
	assert(fs.create_directory_recursive(dir))

	for face_index = 0, 5 do
		local path = string.format("%sprobe_%02d_depth_%s.png", dir, index, face_names[face_index + 1])
		probe.depth_cubemap:Download{base_array_layer = face_index}:Save(path)
		logf("[envprobe] saved %s\n", path)
	end

	return true
end

local function dump_envprobe(limit)
	limit = math.max(math.floor(limit or #envprobe.probes), 0)
	logf(
		"[envprobe] enabled=%s reflection_probes=%s count=%d current_face=%d\n",
		tostring(envprobe.enabled == true),
		tostring(envprobe.reflection_probes_enabled == true),
		#envprobe.probes,
		envprobe.current_face or 0
	)

	if envprobe.environment_probe then
		local probe = envprobe.environment_probe
		logf(
			"[envprobe] env pos=(%.1f %.1f %.1f) size=%d dirty=%s mode=%s\n",
			probe.position.x,
			probe.position.y,
			probe.position.z,
			probe.size or 0,
			tostring(probe.needs_update == true),
			tostring(probe.update_mode)
		)
	end

	for i = 1, math.min(#envprobe.probes, limit) do
		local probe = envprobe.probes[i]
		local last_rendered = probe.last_rendered or 0
		local age_text = last_rendered > 0 and
			string.format("%.2f", system.GetTime() - last_rendered) or
			"never"
		logf(
			"[envprobe] #%d pos=(%.1f %.1f %.1f) radius=%.1f size=%d dirty=%s mode=%s age=%s current=%s\n",
			i,
			probe.position.x,
			probe.position.y,
			probe.position.z,
			probe.radius or 0,
			probe.size or 0,
			tostring(probe.needs_update == true),
			tostring(probe.update_mode),
			age_text,
			tostring(probe == envprobe.current_probe)
		)
	end

	if limit < #envprobe.probes then
		logf("[envprobe] ... %d more probes omitted\n", #envprobe.probes - limit)
	end
end

event.AddListener("Update", "envprobe_debug_overlay", function()
	draw_debug_overlay()
end)

event.AddListener("Draw2D", "envprobe_debug_grid", function()
	draw_debug_grid()
end)

commands.Add("envprobe_dump=number|nil", function(limit)
	dump_envprobe(limit)
end)

commands.Add("envprobe_debug_draw=boolean[true]", function(enabled)
	set_debug_draw_enabled(enabled)
	logf("[envprobe] debug overlay %s\n", enabled and "enabled" or "disabled")
end)

commands.Add("envprobe_debug_labels=boolean[true]", function(enabled)
	set_debug_labels_enabled(enabled)
	logf("[envprobe] debug labels %s\n", enabled and "enabled" or "disabled")
end)

commands.Add("envprobe_debug_focus=number[0]", function(index)
	index = math.max(math.floor(index or 0), 0)

	if index > 0 and not get_reflection_probe(index) then
		logf(
			"[envprobe] no reflection probe at index %d (have %d)\n",
			index,
			#envprobe.probes
		)
		return
	end

	set_debug_focus(index)

	if index > 0 then
		logf("[envprobe] focusing probe %d\n", index)
	else
		logf("[envprobe] focus cleared\n")
	end
end)

commands.Add("envprobe_debug_environment=boolean[true]", function(enabled)
	set_debug_show_environment(enabled)
	logf("[envprobe] environment overlay %s\n", enabled and "enabled" or "disabled")
end)

commands.Add("envprobe_debug_grid=boolean[true]", function(enabled)
	set_debug_grid_enabled(enabled)
	logf("[envprobe] debug grid %s\n", enabled and "enabled" or "disabled")
end)

commands.Add("envprobe_debug_grid_depth=boolean[true]", function(enabled)
	set_debug_grid_show_depth(enabled)
	logf("[envprobe] debug grid mode %s\n", enabled and "depth" or "source")
end)

commands.Add("envprobe_dump_faces=number", function(index)
	dump_probe_faces(index)
end)

commands.Add("envprobe_export_depth=number", function(index)
	export_probe_depth(index)
end)
