local ffi = require("ffi")
local event = import("goluwa/event.lua")
local commands = import("goluwa/commands.lua")
local render = import("goluwa/render/render.lua")
local render2d = import("goluwa/render2d/render2d.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local assets = import("goluwa/assets.lua")
local Camera3D = import("goluwa/render3d/camera3d.lua")
local ibl = import("goluwa/render3d/ibl.lua")
local Texture = import("goluwa/render/texture.lua")
local Framebuffer = import("goluwa/render/framebuffer.lua")
local Color = import("goluwa/structs/color.lua")
local Matrix44 = import("goluwa/structs/matrix44.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Rect = import("goluwa/structs/rect.lua")
local system = import("goluwa/system.lua")
local atmosphere = import("goluwa/render3d/atmosphere.lua")
local screen_reconstruct = import("goluwa/render3d/screen_reconstruct.lua")
local lightprobes = library()

local function get_primary_sun(lights)
	lights = lights or render3d.GetLights()

	for _, light in ipairs(lights) do
		if light.LightType == "sun" then return light end
	end

	return nil
end

local function get_primary_sun_direction()
	local lights = render3d.GetLights()
	local sun_dir = Vec3(0, 1, 0)
	local sun = get_primary_sun(lights)

	if sun then sun_dir = sun.Owner.transform:GetRotation():GetBackward() end

	return sun_dir
end

-- Probe types
lightprobes.TYPE_ENVIRONMENT = "environment" -- Sky-only, dynamic, updated based on sun
lightprobes.TYPE_SCENE = "scene" -- Renders geometry, typically static
-- Update modes
lightprobes.UPDATE_DYNAMIC = "dynamic" -- Update every frame (or on sun change for environment)
lightprobes.UPDATE_STATIC = "static" -- Update once on creation
lightprobes.UPDATE_MANUAL = "manual" -- Update only when requested
-- Configuration
lightprobes.ENVIRONMENT_SIZE = 512 -- Larger size for environment probe
lightprobes.SCENE_SIZE = 128 -- Smaller size for scene probes
lightprobes.SCENE_RADIUS = lightprobes.SCENE_RADIUS or 48
lightprobes.SCENE_MIN_SPACING = lightprobes.SCENE_MIN_SPACING or 24
lightprobes.GRID_SPACING = lightprobes.GRID_SPACING or 192
lightprobes.UPDATE_FACES_PER_FRAME = 1 -- How many faces to update each frame
lightprobes.enabled = lightprobes.enabled ~= false
lightprobes.scene_probes_enabled = false
lightprobes.capture_pipeline_flags = lightprobes.capture_pipeline_flags or {
	ssr = true,
	ocean = true,
}
-- State
lightprobes.probes = lightprobes.probes or {}
lightprobes.current_scene_probe_index = lightprobes.current_scene_probe_index or 1 -- Current scene probe being updated (1-based, skips environment)
lightprobes.current_face = lightprobes.current_face or 0
lightprobes.inv_projection_view = lightprobes.inv_projection_view or Matrix44()
lightprobes.debug = lightprobes.debug or {}
lightprobes.debug.draw_enabled = lightprobes.debug.draw_enabled == true
lightprobes.debug.labels_enabled = lightprobes.debug.labels_enabled ~= false
lightprobes.debug.focus_index = lightprobes.debug.focus_index or 0
lightprobes.debug.show_environment = lightprobes.debug.show_environment == true
lightprobes.debug.last_overlay_probe_count = lightprobes.debug.last_overlay_probe_count or 0
lightprobes.debug.grid_enabled = lightprobes.debug.grid_enabled == true
lightprobes.debug.grid_show_depth = lightprobes.debug.grid_show_depth == true
lightprobes.debug.grid_tile_size = lightprobes.debug.grid_tile_size or 88
lightprobes.debug.grid_margin = lightprobes.debug.grid_margin or 12
lightprobes.debug.grid_limit = lightprobes.debug.grid_limit or 4
-- Face rotation angles for cubemap rendering
local face_angles = {
	Deg3(0, -90 + 180, 0), -- +X
	Deg3(0, 90 + 180, 0), -- -X
	Deg3(90, 0 + 180, 0), -- +Y
	Deg3(-90, 0 + 180, 0), -- -Y
	Deg3(0, 0 + 180, 0), -- +Z
	Deg3(0, 180 + 180, 0), -- -Z
}
local face_names = {"px", "nx", "py", "ny", "pz", "nz"}

local function write_sky_vertex_constants(self, block)
	lightprobes.inv_projection_view:CopyToFloatPointer(block.inv_projection_view)
	return block
end

local function initialize_probe_layouts(cmd, probe)
	if not probe then return end

	render.TransitionResourceTo(
		probe.source_cubemap,
		"shader_read_only_optimal",
		{
			cmd = cmd,
			srcStage = "top_of_pipe",
			srcAccess = "none",
			dstStage = "fragment_shader",
			dstAccess = "shader_read",
			base_array_layer = 0,
			layer_count = 6,
			base_mip_level = 0,
			level_count = probe.source_cubemap.mip_map_levels,
		}
	)
	render.TransitionResourceTo(
		probe.cubemap,
		"shader_read_only_optimal",
		{
			cmd = cmd,
			srcStage = "top_of_pipe",
			srcAccess = "none",
			dstStage = "fragment_shader",
			dstAccess = "shader_read",
			base_array_layer = 0,
			layer_count = 6,
			base_mip_level = 0,
			level_count = probe.cubemap.mip_map_levels,
		}
	)
	render.TransitionResourceTo(
		probe.depth_cubemap,
		"shader_read_only_optimal",
		{
			cmd = cmd,
			srcStage = "top_of_pipe",
			srcAccess = "none",
			dstStage = "fragment_shader",
			dstAccess = "shader_read",
			base_array_layer = 0,
			layer_count = 6,
			base_mip_level = 0,
			level_count = 1,
		}
	)
end

local function initialize_probe_layouts_now(probe)
	if not probe or not render.GetDevice() then return end

	local cmd = render.GetCommandBuffer()
	local own_cmd = false

	if not cmd then
		cmd = render.GetCommandPool():AllocateCommandBuffer()
		cmd:Begin()
		own_cmd = true
	end

	initialize_probe_layouts(cmd, probe)

	if own_cmd then
		cmd:End()
		render.SubmitAndWait(cmd)
		cmd:Remove()
	end
end

local function remove_probe_resources(probe)
	if not probe then return end

	if probe.source_face_views then
		for _, view in pairs(probe.source_face_views) do
			if view and view.Remove then view:Remove() end
		end
	end

	if probe.depth_face_views then
		for _, view in pairs(probe.depth_face_views) do
			if view and view.Remove then view:Remove() end
		end
	end

	if probe.mip_face_views then
		for _, views in pairs(probe.mip_face_views) do
			for _, view in pairs(views) do
				if view and view.Remove then view:Remove() end
			end
		end
	end

	if probe.cubemap and probe.cubemap.Remove then probe.cubemap:Remove() end

	if probe.source_cubemap and probe.source_cubemap.Remove then
		probe.source_cubemap:Remove()
	end

	if probe.depth_cubemap and probe.depth_cubemap.Remove then
		probe.depth_cubemap:Remove()
	end
end

-- Create a probe with given configuration
local function CreateProbeTextures(size)
	local probe = {}
	-- Create the output cubemap (prefiltered, used for rendering)
	probe.cubemap = Texture.New{
		width = size,
		height = size,
		format = "b10g11r11_ufloat_pack32",
		mip_map_levels = "auto",
		image = {
			array_layers = 6,
			flags = {"cube_compatible"},
			usage = {"color_attachment", "sampled", "transfer_src", "transfer_dst"},
		},
		view = {
			view_type = "cube",
			layer_count = 6,
		},
	}
	-- Create source cubemap (raw scene render, before prefiltering)
	probe.source_cubemap = Texture.New{
		width = size,
		height = size,
		format = "b10g11r11_ufloat_pack32",
		mip_map_levels = "auto",
		image = {
			array_layers = 6,
			flags = {"cube_compatible"},
			usage = {"color_attachment", "sampled", "transfer_src", "transfer_dst"},
		},
		view = {
			view_type = "cube",
			layer_count = 6,
		},
	}
	-- Create depth cubemap (linear depth for parallax correction) - only for scene probes
	probe.depth_cubemap = Texture.New{
		width = size,
		height = size,
		format = "r32_sfloat",
		mip_map_levels = 1,
		image = {
			array_layers = 6,
			flags = {"cube_compatible"},
			usage = {"color_attachment", "sampled", "transfer_src", "transfer_dst"},
		},
		view = {
			view_type = "cube",
			layer_count = 6,
		},
	}
	-- Create per-face views for source cubemap
	probe.source_face_views = {}

	for j = 0, 5 do
		probe.source_face_views[j] = probe.source_cubemap:GetImage():CreateView{
			view_type = "2d",
			base_array_layer = j,
			layer_count = 1,
			base_mip_level = 0,
			level_count = 1,
		}
	end

	-- Create per-face views for depth cubemap
	probe.depth_face_views = {}

	for j = 0, 5 do
		probe.depth_face_views[j] = probe.depth_cubemap:GetImage():CreateView{
			view_type = "2d",
			base_array_layer = j,
			layer_count = 1,
			base_mip_level = 0,
			level_count = 1,
		}
	end

	-- Create per-mip per-face views for output cubemap
	local num_mips = probe.cubemap.mip_map_levels
	probe.mip_face_views = {}

	for m = 0, num_mips - 1 do
		probe.mip_face_views[m] = {}

		for j = 0, 5 do
			probe.mip_face_views[m][j] = probe.cubemap:GetImage():CreateView{
				view_type = "2d",
				base_array_layer = j,
				layer_count = 1,
				base_mip_level = m,
				level_count = 1,
			}
		end
	end

	return probe
end

-- Create the environment probe (index 0)
function lightprobes.CreateEnvironmentProbe(position)
	local probe = CreateProbeTextures(lightprobes.ENVIRONMENT_SIZE)
	probe.type = lightprobes.TYPE_ENVIRONMENT
	probe.update_mode = lightprobes.UPDATE_DYNAMIC
	probe.position = position or Vec3(0, 0, 0)
	probe.size = lightprobes.ENVIRONMENT_SIZE
	probe.needs_update = true
	probe.last_rendered = 0
	lightprobes.environment_probe = probe
	return probe
end

-- Create a scene probe
function lightprobes.CreateSceneProbe(position, update_mode, radius)
	local probe = CreateProbeTextures(lightprobes.SCENE_SIZE)
	probe.type = lightprobes.TYPE_SCENE
	probe.update_mode = update_mode or lightprobes.UPDATE_DYNAMIC
	probe.position = position
	probe.radius = radius or lightprobes.SCENE_RADIUS
	probe.size = lightprobes.SCENE_SIZE
	probe.needs_update = true
	probe.last_rendered = 0
	table.insert(lightprobes.probes, probe)
	initialize_probe_layouts_now(probe)
	return probe
end

function lightprobes.FindNearestSceneProbe(position, max_distance)
	local nearest_probe
	local nearest_distance = math.huge

	for _, probe in ipairs(lightprobes.probes) do
		local distance = (probe.position - position):GetLength()

		if distance < nearest_distance then
			nearest_distance = distance
			nearest_probe = probe
		end
	end

	if max_distance and nearest_distance > max_distance then
		return nil, nearest_distance
	end

	return nearest_probe, nearest_distance
end

function lightprobes.EnsureSceneProbe(position, update_mode, radius, min_spacing)
	min_spacing = min_spacing or lightprobes.SCENE_MIN_SPACING
	local probe, distance = lightprobes.FindNearestSceneProbe(position, min_spacing)

	if probe then
		if radius and radius > (probe.radius or 0) then probe.radius = radius end

		if update_mode and probe.update_mode ~= update_mode then
			probe.update_mode = update_mode
			probe.needs_update = true
		end

		return probe, false, distance
	end

	return lightprobes.CreateSceneProbe(position, update_mode, radius),
	true,
	distance
end

function lightprobes.BuildProbeGrid(min_pos, max_pos, spacing, update_mode, radius, y_step)
	spacing = spacing or lightprobes.GRID_SPACING
	update_mode = update_mode or lightprobes.UPDATE_STATIC
	radius = radius or math.max(spacing * 0.75, lightprobes.SCENE_RADIUS)
	y_step = y_step or math.max(max_pos.y - min_pos.y, 1)
	local created = {}

	for y = min_pos.y, max_pos.y, y_step do
		for z = min_pos.z, max_pos.z, spacing do
			for x = min_pos.x, max_pos.x, spacing do
				local probe, did_create = lightprobes.EnsureSceneProbe(Vec3(x, y, z), update_mode, radius, spacing * 0.35)

				if did_create then list.insert(created, probe) end
			end
		end
	end

	return created
end

local function get_debug_draw_module()
	return import.loaded["goluwa/render3d/debug_draw.lua"] or
		import("goluwa/render3d/debug_draw.lua")
end

local function get_scene_probe(index)
	index = math.floor(index or 0)

	if index < 1 then return nil end

	return lightprobes.probes[index]
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
	probe.debug_face_textures = probe.debug_face_textures or {source = {}, depth = {}}
	local cache_key = show_depth and "depth" or "source"
	local cache = probe.debug_face_textures[cache_key]
	local tex = cache[face_index]

	if tex then return tex end

	local source_texture = show_depth and probe.depth_cubemap or probe.source_cubemap
	local view = show_depth and
		probe.depth_face_views[face_index] or
		probe.source_face_views[face_index]
	tex = create_face_texture_wrapper(
		source_texture,
		view,
		string.format("lightprobe_%s_face_%s", cache_key, face_names[face_index + 1])
	)
	cache[face_index] = tex
	return tex
end

local function get_probe_overlay_id(kind, index)
	return string.format("lightprobe_debug_%s_%d", kind, index)
end

local function should_draw_probe(index)
	local focus_index = lightprobes.debug.focus_index or 0
	return focus_index <= 0 or focus_index == index
end

local function get_probe_debug_color(index, probe)
	if probe.type == lightprobes.TYPE_ENVIRONMENT then
		return Color(0.35, 0.65, 1.0, 0.16)
	end

	local is_current = index == lightprobes.current_scene_probe_index

	if
		is_current and
		(
			probe.needs_update or
			probe.update_mode == lightprobes.UPDATE_DYNAMIC
		)
	then
		return Color(1.0, 0.55, 0.2, 0.22)
	end

	if probe.needs_update then return Color(1.0, 0.86, 0.2, 0.18) end

	if probe.update_mode == lightprobes.UPDATE_DYNAMIC then
		return Color(0.35, 1.0, 0.45, 0.18)
	end

	if probe.update_mode == lightprobes.UPDATE_MANUAL then
		return Color(0.95, 0.35, 1.0, 0.18)
	end

	return Color(0.25, 0.9, 1.0, 0.16)
end

local function build_probe_debug_lines(index, probe)
	local lines = {}
	local now = system.GetTime()
	local last_rendered = probe.last_rendered or 0
	local age = last_rendered > 0 and (now - last_rendered) or nil
	local role = probe.type == lightprobes.TYPE_ENVIRONMENT and "env" or ("probe " .. index)
	lines[1] = string.format("%s %s", role, probe.update_mode or "unknown")
	lines[2] = string.format(
		"r %.1f size %d dirty %s",
		probe.radius or 0,
		probe.size or 0,
		tostring(probe.needs_update == true)
	)

	if
		index == lightprobes.current_scene_probe_index and
		probe.type == lightprobes.TYPE_SCENE
	then
		lines[3] = string.format("updating face %d", lightprobes.current_face)
	elseif age then
		lines[3] = string.format("last %.2fs ago", age)
	else
		lines[3] = "last never"
	end

	return lines
end

function lightprobes.ClearDebugOverlay()
	local debug_draw = import.loaded["goluwa/render3d/debug_draw.lua"]

	if not debug_draw then return end

	debug_draw.Remove(get_probe_overlay_id("sphere", 0))
	debug_draw.Remove(get_probe_overlay_id("text", 0))

	for i = 1, math.max(lightprobes.debug.last_overlay_probe_count or 0, #lightprobes.probes) do
		debug_draw.Remove(get_probe_overlay_id("sphere", i))
		debug_draw.Remove(get_probe_overlay_id("text", i))
	end

	lightprobes.debug.last_overlay_probe_count = #lightprobes.probes
end

function lightprobes.SetDebugDrawEnabled(enabled)
	lightprobes.debug.draw_enabled = enabled == true

	if not lightprobes.debug.draw_enabled then lightprobes.ClearDebugOverlay() end
end

function lightprobes.SetDebugLabelsEnabled(enabled)
	lightprobes.debug.labels_enabled = enabled ~= false

	if not lightprobes.debug.labels_enabled then
		local debug_draw = import.loaded["goluwa/render3d/debug_draw.lua"]

		if debug_draw then
			debug_draw.Remove(get_probe_overlay_id("text", 0))

			for i = 1, math.max(lightprobes.debug.last_overlay_probe_count or 0, #lightprobes.probes) do
				debug_draw.Remove(get_probe_overlay_id("text", i))
			end
		end
	end
end

function lightprobes.SetDebugFocus(index)
	lightprobes.debug.focus_index = math.max(math.floor(index or 0), 0)
end

function lightprobes.SetDebugShowEnvironment(enabled)
	lightprobes.debug.show_environment = enabled == true

	if not lightprobes.debug.show_environment then
		local debug_draw = import.loaded["goluwa/render3d/debug_draw.lua"]

		if debug_draw then
			debug_draw.Remove(get_probe_overlay_id("sphere", 0))
			debug_draw.Remove(get_probe_overlay_id("text", 0))
		end
	end
end

function lightprobes.DrawDebugOverlay()
	if not lightprobes.debug.draw_enabled then return end

	local debug_draw = get_debug_draw_module()
	local scene_probe_count = #lightprobes.probes
	local previous_count = lightprobes.debug.last_overlay_probe_count or 0

	if
		lightprobes.debug.show_environment and
		lightprobes.environment_probe and
		should_draw_probe(0)
	then
		local env_probe = lightprobes.environment_probe
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

		if lightprobes.debug.labels_enabled then
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

	for i, probe in ipairs(lightprobes.probes) do
		if should_draw_probe(i) then
			debug_draw.DrawSphere{
				id = get_probe_overlay_id("sphere", i),
				position = probe.position,
				radius = probe.radius or lightprobes.SCENE_RADIUS,
				color = get_probe_debug_color(i, probe),
				ignore_z = true,
				double_sided = true,
				translucent = true,
				time = 0.25,
			}

			if lightprobes.debug.labels_enabled then
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

	if previous_count > scene_probe_count then
		for i = scene_probe_count + 1, previous_count do
			debug_draw.Remove(get_probe_overlay_id("sphere", i))
			debug_draw.Remove(get_probe_overlay_id("text", i))
		end
	end

	lightprobes.debug.last_overlay_probe_count = scene_probe_count
end

function lightprobes.SetDebugGridEnabled(enabled)
	lightprobes.debug.grid_enabled = enabled == true
end

function lightprobes.SetDebugGridShowDepth(enabled)
	lightprobes.debug.grid_show_depth = enabled == true
end

local function draw_probe_grid_tile(debug_draw, x, y, tile_size, probe, probe_index, face_index)
	local texture = get_probe_face_texture(probe, face_index, lightprobes.debug.grid_show_depth)
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
				lightprobes.debug.grid_show_depth and "depth" or "src",
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

function lightprobes.DrawDebugGrid()
	if not lightprobes.debug.grid_enabled then return end

	local debug_draw = get_debug_draw_module()
	local tile_size = math.max(math.floor(lightprobes.debug.grid_tile_size or 88), 32)
	local margin = math.max(math.floor(lightprobes.debug.grid_margin or 12), 4)
	local screen_w, screen_h = render2d.GetSize()
	local visible_limit = math.max(math.floor(lightprobes.debug.grid_limit or 4), 1)
	local probes_to_draw = {}
	local focus_index = lightprobes.debug.focus_index or 0

	if focus_index > 0 then
		local probe = get_scene_probe(focus_index)

		if probe then probes_to_draw[1] = {index = focus_index, probe = probe} end
	else
		for i, probe in ipairs(lightprobes.probes) do
			probes_to_draw[#probes_to_draw + 1] = {index = i, probe = probe}

			if #probes_to_draw >= visible_limit then break end
		end
	end

	if #probes_to_draw == 0 then
		debug_draw.DrawTextBlock(
			{"lightprobes grid", "no visible scene probes"},
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
			draw_probe_grid_tile(debug_draw, tile_x, tile_y, tile_size, entry.probe, entry.index, face_index)
		end

		x = x + probe_block_w + margin
	end

	if focus_index <= 0 and #lightprobes.probes > #probes_to_draw then
		debug_draw.DrawTextBlock(
			{string.format("showing %d / %d probes", #probes_to_draw, #lightprobes.probes)},
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

function lightprobes.DumpProbeFaces(index)
	local probe = get_scene_probe(index)

	if not probe then
		logf(
			"[lightprobes] no scene probe at index %s (have %d)\n",
			tostring(index),
			#lightprobes.probes
		)
		return nil
	end

	if not probe.depth_cubemap then
		logf("[lightprobes] probe %d has no depth cubemap\n", index)
		return nil
	end

	if (probe.last_rendered or 0) == 0 then
		logf(
			"[lightprobes] probe %d has never rendered; face contents may still be undefined\n",
			index
		)
	end

	for face_index = 0, 5 do
		local stats = get_depth_face_stats(probe.depth_cubemap, face_index)
		logf(
			"[lightprobes] probe=%d face=%s depth[min=%.3f avg=%.3f max=%.3f nonzero=%.2f%% geometry=%.2f%%]\n",
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

function lightprobes.ExportProbeDepth(index)
	local probe = get_scene_probe(index)

	if not probe then
		logf(
			"[lightprobes] no scene probe at index %s (have %d)\n",
			tostring(index),
			#lightprobes.probes
		)
		return nil
	end

	local fs = import("goluwa/fs.lua")
	local dir = "tmp/lightprobes/"
	assert(fs.create_directory_recursive(dir))

	for face_index = 0, 5 do
		local path = string.format("%sprobe_%02d_depth_%s.png", dir, index, face_names[face_index + 1])
		probe.depth_cubemap:Download{base_array_layer = face_index}:SaveAs(path)
		logf("[lightprobes] saved %s\n", path)
	end

	return true
end

function lightprobes.Dump(limit)
	limit = math.max(math.floor(limit or #lightprobes.probes), 0)
	logf(
		"[lightprobes] enabled=%s scene_probes=%d current_scene_probe_index=%d current_face=%d\n",
		tostring(lightprobes.enabled == true),
		#lightprobes.probes,
		lightprobes.current_scene_probe_index or 0,
		lightprobes.current_face or 0
	)

	if lightprobes.environment_probe then
		local probe = lightprobes.environment_probe
		logf(
			"[lightprobes] env pos=(%.1f %.1f %.1f) size=%d dirty=%s mode=%s\n",
			probe.position.x,
			probe.position.y,
			probe.position.z,
			probe.size or 0,
			tostring(probe.needs_update == true),
			tostring(probe.update_mode)
		)
	end

	for i = 1, math.min(#lightprobes.probes, limit) do
		local probe = lightprobes.probes[i]
		local last_rendered = probe.last_rendered or 0
		local age_text = last_rendered > 0 and
			string.format("%.2f", system.GetTime() - last_rendered) or
			"never"
		logf(
			"[lightprobes] #%d pos=(%.1f %.1f %.1f) radius=%.1f size=%d dirty=%s mode=%s age=%s current=%s\n",
			i,
			probe.position.x,
			probe.position.y,
			probe.position.z,
			probe.radius or 0,
			probe.size or 0,
			tostring(probe.needs_update == true),
			tostring(probe.update_mode),
			age_text,
			tostring(i == lightprobes.current_scene_probe_index)
		)
	end

	if limit < #lightprobes.probes then
		logf("[lightprobes] ... %d more probes omitted\n", #lightprobes.probes - limit)
	end
end

function lightprobes.MarkAllSceneProbesDirty(update_mode)
	local marked = 0

	for _, probe in ipairs(lightprobes.probes) do
		probe.needs_update = true

		if update_mode and probe.update_mode ~= update_mode then
			probe.update_mode = update_mode
		end

		marked = marked + 1
	end

	return marked
end

function lightprobes.Initialize()
	lightprobes.CreatePipelines()

	if lightprobes.environment_probe and HOTRELOAD then
		remove_probe_resources(lightprobes.environment_probe)
		lightprobes.environment_probe = nil
	end

	do
		if not lightprobes.environment_probe then
			lightprobes.CreateEnvironmentProbe(Vec3(0, 0, 0))
		end

		if not lightprobes.camera then lightprobes.camera = Camera3D.New() end

		lightprobes.camera:SetFOV(math.rad(90))
		lightprobes.camera:SetViewport(Rect(0, 0, lightprobes.ENVIRONMENT_SIZE, lightprobes.ENVIRONMENT_SIZE))
		lightprobes.camera:SetNearZ(0.1)
		lightprobes.camera:SetFarZ(1000)
		lightprobes.environment_probe.needs_update = true
		render3d.SetEnvironmentTexture(lightprobes.environment_probe.cubemap)
	end

	lightprobes.InitializeCubemapLayouts()
end

event.AddListener("SpawnProbe", "lightprobes", function(position, update_mode, radius, min_spacing)
	lightprobes.EnsureSceneProbe(position, update_mode or lightprobes.UPDATE_STATIC, radius, min_spacing)
end)

event.AddListener("Update", "lightprobes_debug_overlay", function()
	lightprobes.DrawDebugOverlay()
end)

event.AddListener("Draw2D", "lightprobes_debug_grid", function()
	lightprobes.DrawDebugGrid()
end)

-- Initialize all cubemap faces to shader_read_only_optimal layout
function lightprobes.InitializeCubemapLayouts()
	local cmd = render.GetCommandPool():AllocateCommandBuffer()
	cmd:Begin()
	initialize_probe_layouts(cmd, lightprobes.environment_probe)

	for index, probe in pairs(lightprobes.probes) do
		initialize_probe_layouts(cmd, probe)
	end

	cmd:End()
	render.SubmitAndWait(cmd)
	cmd:Remove()
end

function lightprobes.CreatePipelines()
	local EasyPipeline = import("goluwa/render/easy_pipeline.lua")
	local ibl = import.loaded["goluwa/render3d/ibl.lua"] or import("goluwa/render3d/ibl.lua")
	local orientation = import("goluwa/render3d/orientation.lua")
	local Material = import("goluwa/render3d/material.lua")
	local Light = import("goluwa/ecs/components/3d/light.lua")

	for _, key in ipairs{
		"sky_pipeline",
		"prefilter_pipeline",
		"capture_copy_pipeline",
		"capture_depth_pipeline",
	} do
		local pipeline = lightprobes[key]

		if pipeline then pipeline:Remove() end

		lightprobes[key] = nil
	end

	if lightprobes.capture_bundles then
		for _, bundle in pairs(lightprobes.capture_bundles) do
			render3d.RemovePipelineBundle(bundle)
		end

		lightprobes.capture_bundles = nil
	end

	-- Sky-only pipeline (for environment probe and scene probe backgrounds)
	lightprobes.sky_pipeline = EasyPipeline.New{
		ColorFormat = {
			{"b10g11r11_ufloat_pack32", {"color", "rgba"}},
			{"r32_sfloat", {"linear_depth", "r"}},
		},
		RasterizationSamples = "1",
		Blend = false,
		ColorWriteMask = {"r", "g", "b", "a"},
		vertex = {
			push_constants = {
				{
					name = "vertex",
					block = {
						{"inv_projection_view", "mat4"},
					},
					write = write_sky_vertex_constants,
				},
			},
			custom_declarations = [[
                layout(location = 0) out vec3 out_direction;
            ]],
			shader = [[
                vec2 positions[3] = vec2[](
                    vec2(-1.0, -1.0),
                    vec2( 3.0, -1.0),
                    vec2(-1.0,  3.0)
                );

                void main() {
                    vec2 pos = positions[gl_VertexIndex];
                    gl_Position = vec4(pos, 1.0, 1.0);
					vec4 world_pos = vertex.inv_projection_view * vec4(pos, 1.0, 1.0);
					out_direction = world_pos.xyz / world_pos.w;
                }
            ]],
		},
		fragment = {
			push_constants = {
				{
					name = "fragment",
					block = {
						{"stars_texture_index", "int"},
						{"atmosphere_transmittance_texture_index", "int"},
						{"atmosphere_sky_view_texture_index", "int"},
						{"sun_direction", "vec4"},
						{"camera_position", "vec4"},
					},
					write = function(self, block)
						block.stars_texture_index = self:GetTextureIndex(atmosphere.GetStarsTexture())
						block.atmosphere_transmittance_texture_index = self:GetTextureIndex(atmosphere.GetTransmittanceTexture())
						block.atmosphere_sky_view_texture_index = self:GetTextureIndex(atmosphere.GetSkyViewTexture(lightprobes.camera:GetPosition(), get_primary_sun_direction()))
						local sun = get_primary_sun(render3d.GetLights())

						if sun then
							sun.Owner.transform:GetRotation():GetBackward():CopyToFloatPointer(block.sun_direction)
						else
							block.sun_direction[0] = 0
							block.sun_direction[1] = 1
							block.sun_direction[2] = 0
							block.sun_direction[3] = 0
						end

						lightprobes.camera:GetPosition():CopyToFloatPointer(block.camera_position)
						return block
					end,
				},
			},
			custom_declarations = [[
                layout(location = 0) in vec3 in_direction;
                ]] .. atmosphere.GetGLSLCode() .. [[
            ]],
			shader = [[
                void main() {
					vec3 sky_color_output;
					]] .. atmosphere.GetGLSLMainCode(
					"in_direction",
					"fragment.sun_direction.xyz",
					"fragment.camera_position.xyz",
					"fragment.stars_texture_index",
					"fragment.atmosphere_sky_view_texture_index",
					"fragment.atmosphere_transmittance_texture_index"
				) .. [[
					vec3 probe_ray_dir = normalize(in_direction);
					vec3 probe_sun_dir = length(fragment.sun_direction.xyz) > 0.0001
						? normalize(fragment.sun_direction.xyz)
						: vec3(0.0, 1.0, 0.0);
					sky_color_output = apply_scenery_fog_ray(
						sky_color_output,
						probe_ray_dir,
						probe_sun_dir,
						fragment.camera_position.xyz,
						-1.0,
						get_fog_sun_horizon_visibility(probe_sun_dir)
					);
				    sky_color_output = clamp(sky_color_output, vec3(0.0), vec3(65504.0));
				    set_color(vec4(sky_color_output, 1.0));
                    // Sky is at infinite distance
                    set_linear_depth(1000.0);
                }
            ]],
		},
		CullMode = "none",
		DepthTest = false,
		DepthWrite = false,
	}
	lightprobes.capture_copy_pipeline = EasyPipeline.New{
		ColorFormat = {{"b10g11r11_ufloat_pack32", {"color", "rgba"}}},
		dont_create_framebuffers = true,
		CullMode = "none",
		DepthTest = false,
		DepthWrite = false,
		fragment = {
			push_constants = {
				{
					name = "probe_capture_copy",
					block = {
						{"source_tex", "int"},
					},
					write = function(self, block)
						block.source_tex = self:GetTextureIndex(lightprobes.current_capture_source_texture)
						return block
					end,
				},
			},
			shader = [[
				void main() {
					if (probe_capture_copy.source_tex == -1) {
						set_color(vec4(0.0, 0.0, 0.0, 1.0));
						return;
					}

					set_color(texture(TEXTURE(probe_capture_copy.source_tex), in_uv));
				}
			]],
		},
	}
	lightprobes.capture_depth_pipeline = EasyPipeline.New{
		ColorFormat = {{"r32_sfloat", {"linear_depth", "r"}}},
		dont_create_framebuffers = true,
		CullMode = "none",
		DepthTest = false,
		DepthWrite = false,
		fragment = {
			uniform_buffers = {
				{
					name = "probe_depth_data",
					binding_index = 3,
					block = {
						render3d.camera_block,
						{"depth_tex", "int"},
					},
					write = function(self, block)
						render3d.WriteCameraBlock(self, block)
						block.depth_tex = self:GetTextureIndex(lightprobes.current_capture_depth_texture)
						return block
					end,
				},
			},
			shader = [[
			]] .. screen_reconstruct.GetWorldPosFromUVGLSL("probe_depth_data") .. [[
				void main() {
					if (probe_depth_data.depth_tex == -1) {
						set_linear_depth(1000.0);
						return;
					}

					float depth = texture(TEXTURE(probe_depth_data.depth_tex), in_uv).r;

					if (depth >= 0.999999) {
						set_linear_depth(1000.0);
						return;
					}

					vec3 world_pos = get_world_pos(in_uv, depth);
					float radial_depth = length(world_pos - probe_depth_data.camera_position.xyz);
					set_linear_depth(radial_depth);
				}
			]],
		},
	}
	-- Prefilter pipeline for IBL
	lightprobes.prefilter_pipeline = EasyPipeline.New{
		ColorFormat = {{"b10g11r11_ufloat_pack32", {"color", "rgba"}}},
		RasterizationSamples = "1",
		CullMode = "none",
		DepthTest = false,
		DepthWrite = false,
		vertex = {
			push_constants = {
				{
					name = "vertex",
					block = {
						{"inv_projection_view", "mat4"},
					},
					write = write_sky_vertex_constants,
				},
			},
			custom_declarations = [[
                layout(location = 0) out vec3 out_direction;
            ]],
			shader = [[
                vec2 positions[3] = vec2[](
                    vec2(-1.0, -1.0),
                    vec2( 3.0, -1.0),
                    vec2(-1.0,  3.0)
                );

                void main() {
                    vec2 pos = positions[gl_VertexIndex];
                    gl_Position = vec4(pos, 1.0, 1.0);
					vec4 world_pos = vertex.inv_projection_view * vec4(pos, 1.0, 1.0);
					out_direction = world_pos.xyz / world_pos.w;
                }
            ]],
		},
		fragment = {
			push_constants = {
				{
					name = "fragment",
					block = {
						{"roughness", "float"},
						{"input_texture_index", "int"},
						{"resolution", "float"},
					},
					write = function(self, block)
						local probe = lightprobes.current_prefilter_probe
						block.roughness = lightprobes.current_roughness or 0
						block.input_texture_index = self:GetTextureIndex(probe.source_cubemap)
						block.resolution = probe.size
						return block
					end,
				},
			},
			custom_declarations = [[
                layout(location = 0) in vec3 in_direction;
            ]] .. ibl.GetBRDFGLSLCode() .. [[
            ]],
			shader = [[
                void main() {
                    vec3 N = normalize(in_direction);
                    vec3 R = N;
                    vec3 V = R;

                    const uint SAMPLE_COUNT = 512u;
                    float totalWeight = 0.0;
                    vec3 prefilteredColor = vec3(0.0);
                    float roughness = clamp(fragment.roughness, 0.0, 1.0);

                    if (roughness < 0.001) {
						prefilteredColor = textureLod(CUBEMAP(fragment.input_texture_index), N, 0.0).rgb;
                        set_color(vec4(prefilteredColor, 1.0));
                        return;
                    }

                    for(uint i = 0u; i < SAMPLE_COUNT; ++i) {
                        vec2 Xi = Hammersley(i, SAMPLE_COUNT);
                        vec3 H  = ImportanceSampleGGX(Xi, N, roughness);
                        vec3 L  = normalize(2.0 * dot(V, H) * H - V);

                        float NoL = max(dot(N, L), 0.0);
                        if(NoL > 0.0) {
                            float NoH = max(dot(N, H), 0.0);
                            float VoH = max(dot(V, H), 0.0001);
							float D = D_GGXPerceptual(roughness, NoH);
                            float pdf = max((D * NoH / (4.0 * VoH)), 0.0001);

                            float resolution = fragment.resolution;
                            float saSample = 1.0 / (float(SAMPLE_COUNT) * pdf);
                            float saTexel  = 4.0 * BRDF_PI / (6.0 * resolution * resolution);

                            float mipBias = max(saSample / saTexel, 1.0);
                            float lod = clamp(0.5 * log2(mipBias), 0.0, 8.0);

							vec3 sampledColor = textureLod(CUBEMAP(fragment.input_texture_index), L, lod).rgb;
                            sampledColor = min(sampledColor, vec3(65504.0));
                            
                            prefilteredColor += sampledColor * NoL;
                            totalWeight      += NoL;
                        }
                    }
                    
                    if (totalWeight > 0.0001) {
                        prefilteredColor /= totalWeight;
                    } else {
						prefilteredColor = textureLod(CUBEMAP(fragment.input_texture_index), N, 0.0).rgb;
                    }
                    
                    prefilteredColor = clamp(prefilteredColor, vec3(0.0), vec3(65504.0));
                    set_color(vec4(prefilteredColor, 1.0));
                }
            ]],
		},
	}
end

-- Projection-view-world matrix for probe rendering
local pvm_cached = Matrix44()

function lightprobes.GetProjectionViewWorldMatrix()
	render3d.GetWorldMatrix():GetMultiplied(lightprobes.camera:BuildViewMatrix(), pvm_cached)
	pvm_cached:GetMultiplied(lightprobes.camera:BuildProjectionMatrix(), pvm_cached)
	return pvm_cached
end

local function acquire_probe_command_buffer(cmd)
	if cmd then return cmd, false end

	cmd = render.GetCommandBuffer()

	if cmd then return cmd, false end

	cmd = render.GetCommandPool():AllocateCommandBuffer()
	cmd:Begin()
	return cmd, true
end

local function submit_probe_command_buffer(cmd, own_cmd)
	if not own_cmd then return end

	cmd:End()
	render.SubmitAndWait(cmd)
	cmd:Remove()
end

local function get_probe_capture_bundle(size)
	lightprobes.capture_bundles = lightprobes.capture_bundles or {}
	local bundle = lightprobes.capture_bundles[size]

	if bundle then return bundle end

	bundle = render3d.CreatePipelineBundle{
		framebuffer_size = {x = size, y = size},
		filter = function(name)
			return name:find("^gbuffer") ~= nil or
				name == "ssr" or
				name == "lighting" or
				name == "ocean"
		end,
	}
	lightprobes.capture_bundles[size] = bundle
	return bundle
end

local function get_probe_capture_context()
	return {
		debug_mode = 1,
		allow_lightprobes = false,
		allow_probe_reflections = false,
		allow_last_frame_history = false,
		pipeline_flags = {
			ssr = lightprobes.capture_pipeline_flags.ssr ~= false,
			ocean = lightprobes.capture_pipeline_flags.ocean ~= false,
		},
	}
end

local function get_probe_capture_source_texture(bundle)
	local current_idx = system.GetFrameNumber() % 2 + 1

	if
		lightprobes.capture_pipeline_flags.ocean ~= false and
		bundle.pipelines.ocean and
		bundle.pipelines.ocean.framebuffers
	then
		return bundle.pipelines.ocean:GetFramebuffer(current_idx):GetAttachment(1)
	end

	if bundle.pipelines.lighting and bundle.pipelines.lighting.framebuffers then
		return bundle.pipelines.lighting:GetFramebuffer(current_idx):GetAttachment(1)
	end

	return nil
end

local function get_probe_capture_depth_texture(bundle)
	if not bundle.pipelines.gbuffer then return nil end

	local framebuffer = bundle.pipelines.gbuffer:GetFramebuffer()
	return framebuffer and framebuffer:GetDepthTexture() or nil
end

-- Check if sun direction has changed significantly
function lightprobes.HasSunDirectionChanged()
	local sun = get_primary_sun(render3d.GetLights())

	if not sun then return false end

	local current_sun_dir = sun.Owner.transform:GetRotation():GetBackward()

	if not lightprobes.last_sun_direction then
		lightprobes.last_sun_direction = current_sun_dir:Copy()
		return true
	end

	local diff = (current_sun_dir - lightprobes.last_sun_direction):GetLength()

	if diff > 0.001 then
		lightprobes.last_sun_direction = current_sun_dir:Copy()
		return true
	end

	return false
end

-- Render faces for a specific probe
function lightprobes.RenderProbeFaces(cmd, probe, num_faces, render_geometry)
	if not lightprobes.enabled then return end

	if not lightprobes.sky_pipeline then return end

	num_faces = num_faces or 1
	render.PushCommandBuffer(cmd)
	local SIZE = probe.size
	lightprobes.camera:SetPosition(probe.position)
	lightprobes.camera:SetViewport(Rect(0, 0, SIZE, SIZE))

	for _ = 1, num_faces do
		local face_idx = lightprobes.current_face
		-- Set camera rotation for this face
		lightprobes.camera:SetAngles(face_angles[face_idx + 1])
		-- Calculate inverse projection-view for sky rendering
		local proj = lightprobes.camera:BuildProjectionMatrix()
		local view = lightprobes.camera:BuildViewMatrix():Copy()
		view.m30, view.m31, view.m32 = 0, 0, 0
		local proj_view = view * proj
		proj_view:GetInverse(lightprobes.inv_projection_view)

		if render_geometry then
			local bundle = get_probe_capture_bundle(SIZE)
			local capture_context = get_probe_capture_context()
			render3d.PushCamera(lightprobes.camera)
			render3d.RunPipelineBundle(bundle, cmd, capture_context)
			render3d.PopCamera()
			lightprobes.current_capture_source_texture = get_probe_capture_source_texture(bundle)
			lightprobes.current_capture_depth_texture = get_probe_capture_depth_texture(bundle)
			render.TransitionResourceTo(
				probe.source_cubemap,
				"color_attachment_optimal",
				{
					cmd = cmd,
					srcStage = "fragment_shader",
					srcAccess = "shader_read",
					dstStage = "color_attachment_output",
					dstAccess = "color_attachment_write",
					base_array_layer = face_idx,
					layer_count = 1,
					base_mip_level = 0,
					level_count = 1,
				}
			)
			render.TransitionResourceTo(
				probe.depth_cubemap,
				"color_attachment_optimal",
				{
					cmd = cmd,
					srcStage = "fragment_shader",
					srcAccess = "shader_read",
					dstStage = "color_attachment_output",
					dstAccess = "color_attachment_write",
					base_array_layer = face_idx,
					layer_count = 1,
					base_mip_level = 0,
					level_count = 1,
				}
			)
			cmd:BeginRendering{
				color_attachments = {
					{
						color_image_view = probe.source_face_views[face_idx],
						clear_color = {0, 0, 0, 1},
						load_op = "clear",
						store_op = "store",
					},
				},
				w = SIZE,
				h = SIZE,
			}
			cmd:SetViewport(0, 0, SIZE, SIZE)
			cmd:SetScissor(0, 0, SIZE, SIZE)
			cmd:SetCullMode("none")
			lightprobes.capture_copy_pipeline:UploadConstants()
			lightprobes.capture_copy_pipeline:Bind(cmd)
			cmd:Draw(3, 1, 0, 0)
			cmd:EndRendering()
			cmd:BeginRendering{
				color_attachments = {
					{
						color_image_view = probe.depth_face_views[face_idx],
						clear_color = {1000, 0, 0, 0},
						load_op = "clear",
						store_op = "store",
					},
				},
				w = SIZE,
				h = SIZE,
			}
			cmd:SetViewport(0, 0, SIZE, SIZE)
			cmd:SetScissor(0, 0, SIZE, SIZE)
			cmd:SetCullMode("none")
			lightprobes.capture_depth_pipeline:UploadConstants()
			lightprobes.capture_depth_pipeline:Bind(cmd)
			cmd:Draw(3, 1, 0, 0)
			cmd:EndRendering()
		else
			-- Transition source face to color attachment
			render.TransitionResourceTo(
				probe.source_cubemap,
				"color_attachment_optimal",
				{
					cmd = cmd,
					srcStage = "fragment_shader",
					srcAccess = "shader_read",
					dstStage = "color_attachment_output",
					dstAccess = "color_attachment_write",
					base_array_layer = face_idx,
					layer_count = 1,
					base_mip_level = 0,
					level_count = 1,
				}
			)
			-- Transition depth face to color attachment
			render.TransitionResourceTo(
				probe.depth_cubemap,
				"color_attachment_optimal",
				{
					cmd = cmd,
					srcStage = "fragment_shader",
					srcAccess = "shader_read",
					dstStage = "color_attachment_output",
					dstAccess = "color_attachment_write",
					base_array_layer = face_idx,
					layer_count = 1,
					base_mip_level = 0,
					level_count = 1,
				}
			)
			-- First render sky background
			cmd:BeginRendering{
				color_attachments = {
					{
						color_image_view = probe.source_face_views[face_idx],
						clear_color = {0, 0, 0, 1},
						load_op = "clear",
						store_op = "store",
					},
					{
						color_image_view = probe.depth_face_views[face_idx],
						clear_color = {1000, 0, 0, 0},
						load_op = "clear",
						store_op = "store",
					},
				},
				w = SIZE,
				h = SIZE,
			}
			cmd:SetViewport(0, 0, SIZE, SIZE)
			cmd:SetScissor(0, 0, SIZE, SIZE)
			cmd:SetCullMode("none")
			lightprobes.sky_pipeline:UploadConstants()
			lightprobes.sky_pipeline:Bind(cmd)
			cmd:Draw(3, 1, 0, 0)
			cmd:EndRendering()
		end

		-- Transition source face to shader read
		render.TransitionResourceFrom(
			probe.source_cubemap,
			"shader_read_only_optimal",
			{
				cmd = cmd,
				srcStage = "color_attachment_output",
				srcAccess = "color_attachment_write",
				dstStage = "fragment_shader",
				dstAccess = "shader_read",
				base_array_layer = face_idx,
				layer_count = 1,
				base_mip_level = 0,
				level_count = 1,
			}
		)
		-- Transition depth face to shader read
		render.TransitionResourceFrom(
			probe.depth_cubemap,
			"shader_read_only_optimal",
			{
				cmd = cmd,
				srcStage = "color_attachment_output",
				srcAccess = "color_attachment_write",
				dstStage = "fragment_shader",
				dstAccess = "shader_read",
				base_array_layer = face_idx,
				layer_count = 1,
				base_mip_level = 0,
				level_count = 1,
			}
		)
		lightprobes.current_face = (lightprobes.current_face + 1) % 6
	end

	render.PopCommandBuffer()
end

-- Prefilter the source cubemap into the output cubemap with roughness mips
function lightprobes.PrefilterProbe(cmd, probe)
	if not lightprobes.prefilter_pipeline then return end

	render.PushCommandBuffer(cmd)
	local SIZE = probe.size
	local num_mips = probe.cubemap.mip_map_levels
	-- Set current probe for prefiltering
	lightprobes.current_prefilter_probe = probe
	-- Generate mipmaps for source cubemap
	probe.source_cubemap:GenerateMipmaps("shader_read_only_optimal")

	-- For each mip level, render prefiltered version
	for m = 0, num_mips - 1 do
		local perceptual_roughness = m / math.max(num_mips - 1, 1)
		lightprobes.current_roughness = perceptual_roughness
		local mip_size = math.max(1, math.floor(SIZE / (2 ^ m)))

		for face = 0, 5 do
			lightprobes.camera:SetAngles(face_angles[face + 1])
			local proj = lightprobes.camera:BuildProjectionMatrix()
			local view = lightprobes.camera:BuildViewMatrix():Copy()
			view.m30, view.m31, view.m32 = 0, 0, 0
			local proj_view = view * proj
			proj_view:GetInverse(lightprobes.inv_projection_view)
			-- Transition output face/mip to color attachment
			render.TransitionResourceTo(
				probe.cubemap,
				"color_attachment_optimal",
				{
					cmd = cmd,
					srcStage = "fragment_shader",
					srcAccess = "shader_read",
					dstStage = "color_attachment_output",
					dstAccess = "color_attachment_write",
					base_array_layer = face,
					layer_count = 1,
					base_mip_level = m,
					level_count = 1,
				}
			)
			cmd:BeginRendering{
				color_image_view = probe.mip_face_views[m][face],
				w = mip_size,
				h = mip_size,
				clear_color = {0, 0, 0, 1},
			}
			cmd:SetViewport(0, 0, mip_size, mip_size)
			cmd:SetScissor(0, 0, mip_size, mip_size)
			cmd:SetCullMode("none")
			lightprobes.prefilter_pipeline:UploadConstants()
			lightprobes.prefilter_pipeline:Bind(cmd)
			cmd:Draw(3, 1, 0, 0)
			cmd:EndRendering()
			-- Transition to shader read
			render.TransitionResourceFrom(
				probe.cubemap,
				"shader_read_only_optimal",
				{
					cmd = cmd,
					srcStage = "color_attachment_output",
					srcAccess = "color_attachment_write",
					dstStage = "fragment_shader",
					dstAccess = "shader_read",
					base_array_layer = face,
					layer_count = 1,
					base_mip_level = m,
					level_count = 1,
				}
			)
		end
	end

	render.PopCommandBuffer()
end

-- Update the environment probe (called every frame if sun changed)
function lightprobes.UpdateEnvironmentProbe(cmd, sun_changed)
	if not lightprobes.environment_probe then return end

	local env_probe = lightprobes.environment_probe
	sun_changed = sun_changed == nil and lightprobes.HasSunDirectionChanged() or sun_changed

	if not sun_changed and not env_probe.needs_update then return end

	local own_cmd
	cmd, own_cmd = acquire_probe_command_buffer(cmd)
	-- Save current face and render all 6 faces for environment
	local saved_face = lightprobes.current_face
	lightprobes.current_face = 0
	-- Environment probe only renders sky (no geometry)
	lightprobes.RenderProbeFaces(cmd, env_probe, 6, false)
	-- Prefilter the environment probe
	lightprobes.PrefilterProbe(cmd, env_probe)
	lightprobes.current_face = saved_face
	env_probe.needs_update = false
	submit_probe_command_buffer(cmd, own_cmd)
end

function lightprobes.GetProbes()
	return lightprobes.probes
end

function lightprobes.SetEnabled(enabled)
	lightprobes.enabled = enabled
end

function lightprobes.IsEnabled()
	return lightprobes.enabled
end

function lightprobes.SetSceneProbesEnabled(enabled)
	local value = enabled ~= false

	if lightprobes.scene_probes_enabled == value then return end

	lightprobes.scene_probes_enabled = value

	if value then lightprobes.MarkAllSceneProbesDirty() end
end

function lightprobes.AreSceneProbesEnabled()
	return lightprobes.scene_probes_enabled
end

-- Compatibility with old skybox API
function lightprobes.SetStarsTexture(texture)
	atmosphere.SetStarsTexture(texture)
end

function lightprobes.GetStarsTexture()
	return atmosphere.GetStarsTexture()
end

event.AddListener("Render3DInitialized", "lightprobes", function()
	lightprobes.Initialize()
end)

event.AddListener("PreRenderPass", "lightprobes_update", function()
	if not lightprobes.enabled then return end

	if not lightprobes.sky_pipeline then return end

	local cmd, own_cmd = acquire_probe_command_buffer()
	local sun_changed = lightprobes.HasSunDirectionChanged()

	if sun_changed then lightprobes.MarkAllSceneProbesDirty() end

	lightprobes.UpdateEnvironmentProbe(cmd, sun_changed)

	if lightprobes.scene_probes_enabled then
		local scene_probe_index = lightprobes.current_scene_probe_index
		local scene_probe = lightprobes.probes[scene_probe_index]

		if scene_probe and scene_probe.type == lightprobes.TYPE_SCENE then
			-- Only update if the probe needs it (static probes only update once)
			if
				scene_probe.needs_update or
				scene_probe.update_mode == lightprobes.UPDATE_DYNAMIC
			then
				local t = system.GetTime()

				if (t - scene_probe.last_rendered) > 1 / 10 then
					lightprobes.RenderProbeFaces(cmd, scene_probe, lightprobes.UPDATE_FACES_PER_FRAME, true)

					-- When we complete a full cycle (back to face 0), prefilter and move to next probe
					if lightprobes.current_face == 0 then
						lightprobes.PrefilterProbe(cmd, scene_probe)
						scene_probe.needs_update = false

						-- Move to next scene probe
						repeat
							scene_probe_index = scene_probe_index + 1

							if scene_probe_index > #lightprobes.probes then
								scene_probe_index = 1
							end						
						until lightprobes.probes[scene_probe_index] or scene_probe_index == lightprobes.current_scene_probe_index

						lightprobes.current_scene_probe_index = scene_probe_index
					end

					scene_probe.last_rendered = t
				end
			end
		end
	end

	submit_probe_command_buffer(cmd, own_cmd)
end)

commands.Add("lightprobes_dump=number|nil", function(limit)
	lightprobes.Dump(limit)
end)

commands.Add("lightprobes_scene_probes=boolean[true]", function(enabled)
	lightprobes.SetSceneProbesEnabled(enabled)
	logf("[lightprobes] scene probes %s\n", enabled and "enabled" or "disabled")
end)

commands.Add("lightprobes_debug_draw=boolean[true]", function(enabled)
	lightprobes.SetDebugDrawEnabled(enabled)
	logf("[lightprobes] debug overlay %s\n", enabled and "enabled" or "disabled")
end)

commands.Add("lightprobes_debug_labels=boolean[true]", function(enabled)
	lightprobes.SetDebugLabelsEnabled(enabled)
	logf("[lightprobes] debug labels %s\n", enabled and "enabled" or "disabled")
end)

commands.Add("lightprobes_debug_focus=number[0]", function(index)
	index = math.max(math.floor(index or 0), 0)

	if index > 0 and not get_scene_probe(index) then
		logf(
			"[lightprobes] no scene probe at index %d (have %d)\n",
			index,
			#lightprobes.probes
		)
		return
	end

	lightprobes.SetDebugFocus(index)

	if index > 0 then
		logf("[lightprobes] focusing probe %d\n", index)
	else
		logf("[lightprobes] focus cleared\n")
	end
end)

commands.Add("lightprobes_debug_environment=boolean[true]", function(enabled)
	lightprobes.SetDebugShowEnvironment(enabled)
	logf("[lightprobes] environment overlay %s\n", enabled and "enabled" or "disabled")
end)

commands.Add("lightprobes_debug_grid=boolean[true]", function(enabled)
	lightprobes.SetDebugGridEnabled(enabled)
	logf("[lightprobes] debug grid %s\n", enabled and "enabled" or "disabled")
end)

commands.Add("lightprobes_debug_grid_depth=boolean[true]", function(enabled)
	lightprobes.SetDebugGridShowDepth(enabled)
	logf("[lightprobes] debug grid mode %s\n", enabled and "depth" or "source")
end)

commands.Add("lightprobes_dump_faces=number", function(index)
	lightprobes.DumpProbeFaces(index)
end)

commands.Add("lightprobes_export_depth=number", function(index)
	lightprobes.ExportProbeDepth(index)
end)

commands.Add("lightprobes_rebuild=string|nil", function(update_mode)
	if update_mode == "" then update_mode = nil end

	if update_mode then
		assert(
			update_mode == lightprobes.UPDATE_STATIC or
				update_mode == lightprobes.UPDATE_DYNAMIC or
				update_mode == lightprobes.UPDATE_MANUAL,
			"lightprobes_rebuild expects static, dynamic, or manual"
		)
	end

	local marked = lightprobes.MarkAllSceneProbesDirty(update_mode)
	logf(
		"[lightprobes] marked %d scene probes dirty%s\n",
		marked,
		update_mode and (" mode=" .. update_mode) or ""
	)
end)

-- Initialize immediately only when render3d is already stable. During
-- render3d hotreload the module is imported before the new Initialize()
-- call finishes, and the persistent render3d table still holds the old
-- pipeline table, which would otherwise double-create these pipelines.
if
	not render3d.initializing and
	render3d and
	render3d.pipelines and
	render3d.pipelines.gbuffer
then
	lightprobes.Initialize()
end

return lightprobes
