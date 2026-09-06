local ffi = require("ffi")
local event = import("goluwa/event.lua")
local commands = import("goluwa/cli/commands.lua")
local render = import("goluwa/render/render.lua")
local render2d = import("goluwa/render2d/render2d.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local Camera3D = import("goluwa/render3d/camera3d.lua")
local ibl = import("goluwa/render3d/ibl.lua")
local Texture = import("goluwa/render/texture.lua")
local Color = import("goluwa/structs/color.lua")
local Matrix44 = import("goluwa/structs/matrix44.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Rect = import("goluwa/structs/rect.lua")
local system = import("goluwa/system.lua")
local atmosphere = import("goluwa/render3d/atmosphere.lua")
local screen_reconstruct = import("goluwa/render3d/screen_reconstruct.lua")
local envprobe = library()

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

envprobe.TYPE_ENVIRONMENT = "environment" -- Sky only, re-rendered when the sun moves
envprobe.TYPE_REFLECTION = "reflection" -- Renders geometry
envprobe.UPDATE_DYNAMIC = "dynamic" -- Re-captured continuously
envprobe.UPDATE_STATIC = "static" -- Captured once, and again when the sun moves
envprobe.UPDATE_MANUAL = "manual" -- Captured only when marked dirty
envprobe.ENVIRONMENT_SIZE = 512
envprobe.REFLECTION_SIZE = 128
envprobe.IRRADIANCE_SIZE = 32 -- Sky irradiance cubemap face size
envprobe.IRRADIANCE_SOURCE_SIZE = 16 -- Source mip face size the irradiance convolution integrates over
envprobe.REFLECTION_RADIUS = envprobe.REFLECTION_RADIUS or 24
envprobe.REFLECTION_MIN_SPACING = envprobe.REFLECTION_MIN_SPACING or 4
envprobe.FACES_PER_FRAME = envprobe.FACES_PER_FRAME or 2
envprobe.DYNAMIC_INTERVAL = envprobe.DYNAMIC_INTERVAL or 0.25 -- seconds between captures of a dynamic probe
envprobe.SUN_CHANGE_DEGREES = envprobe.SUN_CHANGE_DEGREES or 1
envprobe.MAX_UPLOADED_PROBES = 64 -- shader array size in ssr.lua
envprobe.enabled = envprobe.enabled ~= false
envprobe.reflection_probes_enabled = envprobe.reflection_probes_enabled ~= false
envprobe.capture_pipeline_flags = envprobe.capture_pipeline_flags or {
	ssr = false,
	ocean = true,
}
envprobe.auto_placement_enabled = envprobe.auto_placement_enabled ~= false
envprobe.AUTO_PLACEMENT_SPACING = envprobe.AUTO_PLACEMENT_SPACING or 48
envprobe.AUTO_PLACEMENT_RADIUS_CELLS = envprobe.AUTO_PLACEMENT_RADIUS_CELLS or 2
envprobe.AUTO_PLACEMENT_INTERVAL = envprobe.AUTO_PLACEMENT_INTERVAL or 1
envprobe.probes = envprobe.probes or {}
envprobe.auto_grid = envprobe.auto_grid or {} -- grid key -> auto-placed probe
envprobe.auto_last_update = envprobe.auto_last_update or 0
envprobe.current_probe = envprobe.current_probe or nil -- reflection probe currently being captured
envprobe.current_face = envprobe.current_face or 0
envprobe.inv_projection_view = envprobe.inv_projection_view or Matrix44()
envprobe.debug = envprobe.debug or {}
envprobe.debug.draw_enabled = envprobe.debug.draw_enabled == true
envprobe.debug.labels_enabled = envprobe.debug.labels_enabled ~= false
envprobe.debug.focus_index = envprobe.debug.focus_index or 0
envprobe.debug.show_environment = envprobe.debug.show_environment == true
envprobe.debug.last_overlay_probe_count = envprobe.debug.last_overlay_probe_count or 0
envprobe.debug.grid_enabled = envprobe.debug.grid_enabled == true
envprobe.debug.grid_show_depth = envprobe.debug.grid_show_depth == true
envprobe.debug.grid_tile_size = envprobe.debug.grid_tile_size or 88
envprobe.debug.grid_margin = envprobe.debug.grid_margin or 12
envprobe.debug.grid_limit = envprobe.debug.grid_limit or 4
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
	envprobe.inv_projection_view:CopyToFloatPointer(block.inv_projection_view)
	return block
end

local function transition_cube_to_shader_read(cmd, texture)
	if not texture then return end

	render.TransitionResourceTo(
		texture,
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
			level_count = texture.mip_map_levels,
		}
	)
end

local function initialize_probe_layouts(cmd, probe)
	if not probe then return end

	transition_cube_to_shader_read(cmd, probe.source_cubemap)
	transition_cube_to_shader_read(cmd, probe.cubemap)
	transition_cube_to_shader_read(cmd, probe.depth_cubemap)
	transition_cube_to_shader_read(cmd, probe.irradiance_cubemap)
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

local function remove_views(views)
	if not views then return end

	for _, view in pairs(views) do
		if view and view.Remove then view:Remove() end
	end
end

local function remove_probe_resources(probe)
	if not probe then return end

	remove_views(probe.source_face_views)
	remove_views(probe.depth_face_views)
	remove_views(probe.irradiance_face_views)

	if probe.mip_face_views then
		for _, views in pairs(probe.mip_face_views) do
			remove_views(views)
		end
	end

	for _, key in ipairs{"irradiance_cubemap", "cubemap", "source_cubemap", "depth_cubemap"} do
		if probe[key] and probe[key].Remove then probe[key]:Remove() end

		probe[key] = nil
	end

	probe.debug_face_textures = nil
end

local function create_cubemap(size, format, mip_map_levels)
	return Texture.New{
		width = size,
		height = size,
		format = format,
		mip_map_levels = mip_map_levels,
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
end

local function create_face_views(texture, mip_level)
	local views = {}

	for j = 0, 5 do
		views[j] = texture:GetImage():CreateView{
			view_type = "2d",
			base_array_layer = j,
			layer_count = 1,
			base_mip_level = mip_level or 0,
			level_count = 1,
		}
	end

	return views
end

local function CreateProbeTextures(size, with_irradiance)
	local probe = {}
	probe.cubemap = create_cubemap(size, "b10g11r11_ufloat_pack32", "auto")
	probe.source_cubemap = create_cubemap(size, "b10g11r11_ufloat_pack32", "auto")
	probe.depth_cubemap = create_cubemap(size, "r32_sfloat", 1)
	probe.source_face_views = create_face_views(probe.source_cubemap)
	probe.depth_face_views = create_face_views(probe.depth_cubemap)
	probe.mip_face_views = {}

	for m = 0, probe.cubemap.mip_map_levels - 1 do
		probe.mip_face_views[m] = create_face_views(probe.cubemap, m)
	end

	if with_irradiance then
		probe.irradiance_cubemap = create_cubemap(envprobe.IRRADIANCE_SIZE, "b10g11r11_ufloat_pack32", 1)
		probe.irradiance_face_views = create_face_views(probe.irradiance_cubemap)
	end

	return probe
end

function envprobe.CreateEnvironmentProbe(position)
	local probe = CreateProbeTextures(envprobe.ENVIRONMENT_SIZE, true)
	probe.type = envprobe.TYPE_ENVIRONMENT
	probe.update_mode = envprobe.UPDATE_DYNAMIC
	probe.position = position or Vec3(0, 0, 0)
	probe.size = envprobe.ENVIRONMENT_SIZE
	probe.needs_update = true
	probe.last_rendered = 0
	envprobe.environment_probe = probe
	return probe
end

function envprobe.CreateReflectionProbe(position, radius, update_mode)
	local probe = CreateProbeTextures(envprobe.REFLECTION_SIZE, false)
	probe.type = envprobe.TYPE_REFLECTION
	probe.update_mode = update_mode or envprobe.UPDATE_STATIC
	probe.position = position:Copy()
	probe.radius = radius or envprobe.REFLECTION_RADIUS
	probe.size = envprobe.REFLECTION_SIZE
	probe.needs_update = true
	probe.last_rendered = 0
	table.insert(envprobe.probes, probe)
	initialize_probe_layouts_now(probe)
	return probe
end

local function remove_from_auto_grid(probe)
	if not probe.auto_grid_key then return end

	if envprobe.auto_grid[probe.auto_grid_key] == probe then
		envprobe.auto_grid[probe.auto_grid_key] = nil
	end
end

function envprobe.RemoveReflectionProbe(probe)
	for i, other in ipairs(envprobe.probes) do
		if other == probe then
			table.remove(envprobe.probes, i)

			if envprobe.current_probe == probe then
				envprobe.current_probe = nil
				envprobe.current_face = 0
			end

			remove_from_auto_grid(probe)
			remove_probe_resources(probe)
			return true
		end
	end

	return false
end

function envprobe.ClearReflectionProbes()
	for _, probe in ipairs(envprobe.probes) do
		remove_probe_resources(probe)
	end

	envprobe.probes = {}
	envprobe.auto_grid = {}
	envprobe.current_probe = nil
	envprobe.current_face = 0
	envprobe.ClearDebugOverlay()
end

function envprobe.FindNearestReflectionProbe(position, max_distance)
	local nearest_probe
	local nearest_distance = math.huge

	for _, probe in ipairs(envprobe.probes) do
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

function envprobe.EnsureReflectionProbe(position, radius, update_mode, min_spacing)
	min_spacing = min_spacing or envprobe.REFLECTION_MIN_SPACING
	local probe, distance = envprobe.FindNearestReflectionProbe(position, min_spacing)

	if probe then
		if radius and radius > (probe.radius or 0) then probe.radius = radius end

		if update_mode and probe.update_mode ~= update_mode then
			probe.update_mode = update_mode
			probe.needs_update = true
		end

		return probe, false, distance
	end

	return envprobe.CreateReflectionProbe(position, radius, update_mode),
	true,
	distance
end

local function auto_grid_key(cx, cy, cz)
	return cx .. "," .. cy .. "," .. cz
end

function envprobe.UpdateAutoPlacement(camera_position)
	if not envprobe.auto_placement_enabled then return end

	local now = system.GetTime()

	if now - envprobe.auto_last_update < envprobe.AUTO_PLACEMENT_INTERVAL then return end

	envprobe.auto_last_update = now
	local spacing = envprobe.AUTO_PLACEMENT_SPACING
	local radius_cells = envprobe.AUTO_PLACEMENT_RADIUS_CELLS
	local cx = math.floor(camera_position.x / spacing + 0.5)
	local cy = math.floor(camera_position.y / spacing + 0.5)
	local cz = math.floor(camera_position.z / spacing + 0.5)
	local wanted = {}

	for x = -radius_cells, radius_cells do
		for z = -radius_cells, radius_cells do
			local gx, gz = cx + x, cz + z
			local key = auto_grid_key(gx, cy, gz)
			wanted[key] = true

			if not envprobe.auto_grid[key] then
				local position = Vec3(gx * spacing, cy * spacing, gz * spacing)
				local probe = envprobe.CreateReflectionProbe(position, spacing * 0.75, envprobe.UPDATE_STATIC)
				probe.auto = true
				probe.auto_grid_key = key
				envprobe.auto_grid[key] = probe
			end
		end
	end

	for key, probe in pairs(envprobe.auto_grid) do
		if not wanted[key] then
			envprobe.RemoveReflectionProbe(probe)
			envprobe.auto_grid[key] = nil
		end
	end
end

function envprobe.SetAutoPlacementEnabled(enabled)
	envprobe.auto_placement_enabled = enabled ~= false

	if not envprobe.auto_placement_enabled then
		for key, probe in pairs(envprobe.auto_grid) do
			envprobe.RemoveReflectionProbe(probe)
			envprobe.auto_grid[key] = nil
		end
	else
		envprobe.auto_last_update = 0
	end
end

local nearest_probe_sort_position

local function nearest_probe_comparator(a, b)
	return (a.position - nearest_probe_sort_position):GetLengthSquared() <
		(b.position - nearest_probe_sort_position):GetLengthSquared()
end

function envprobe.GetProbesNear(position, limit)
	limit = limit or envprobe.MAX_UPLOADED_PROBES
	local probes = envprobe.probes

	if #probes <= limit then return probes end

	local sorted = {}

	for i, probe in ipairs(probes) do
		sorted[i] = probe
	end

	nearest_probe_sort_position = position
	table.sort(sorted, nearest_probe_comparator)
	nearest_probe_sort_position = nil

	for i = #sorted, limit + 1, -1 do
		sorted[i] = nil
	end

	return sorted
end

function envprobe.GetProbeBlockLayout()
	return {
		{"probe_color_textures", "int", envprobe.MAX_UPLOADED_PROBES},
		{"probe_depth_textures", "int", envprobe.MAX_UPLOADED_PROBES},
		{"probe_positions", "vec4", envprobe.MAX_UPLOADED_PROBES},
	}
end

function envprobe.WriteProbeBlock(self, block, camera_position)
	local max_probes = envprobe.MAX_UPLOADED_PROBES

	for i = 0, max_probes - 1 do
		block.probe_color_textures[i] = -1
		block.probe_depth_textures[i] = -1
		block.probe_positions[i][0] = 0
		block.probe_positions[i][1] = 0
		block.probe_positions[i][2] = 0
		block.probe_positions[i][3] = 0
	end

	if
		not (
			envprobe.IsEnabled() and
			envprobe.AreReflectionProbesEnabled() and
			render3d.ShouldUseProbeReflections()
		)
	then
		return block
	end

	camera_position = camera_position or render3d.GetRenderCamera():GetPosition()
	local probes = envprobe.GetProbesNear(camera_position, max_probes)

	for i = 0, max_probes - 1 do
		local probe = probes[i + 1]

		if probe then
			if probe.cubemap then
				block.probe_color_textures[i] = self:GetCubeMapTextureIndex(probe.cubemap)
			end

			if probe.depth_cubemap then
				block.probe_depth_textures[i] = self:GetCubeMapTextureIndex(probe.depth_cubemap)
			end

			block.probe_positions[i][0] = probe.position.x
			block.probe_positions[i][1] = probe.position.y
			block.probe_positions[i][2] = probe.position.z
			block.probe_positions[i][3] = probe.radius or envprobe.REFLECTION_RADIUS
		end
	end

	return block
end

local function get_debug_draw_module()
	return import.loaded["goluwa/debug_draw.lua"] or import("goluwa/debug_draw.lua")
end

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
		string.format("envprobe_%s_face_%s", cache_key, face_names[face_index + 1])
	)
	cache[face_index] = tex
	return tex
end

local function get_probe_overlay_id(kind, index)
	return string.format("envprobe_debug_%s_%d", kind, index)
end

local function should_draw_probe(index)
	local focus_index = envprobe.debug.focus_index or 0
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

function envprobe.ClearDebugOverlay()
	local debug_draw = import.loaded["goluwa/debug_draw.lua"]

	if not debug_draw then return end

	debug_draw.Remove(get_probe_overlay_id("sphere", 0))
	debug_draw.Remove(get_probe_overlay_id("text", 0))

	for i = 1, math.max(envprobe.debug.last_overlay_probe_count or 0, #envprobe.probes) do
		debug_draw.Remove(get_probe_overlay_id("sphere", i))
		debug_draw.Remove(get_probe_overlay_id("text", i))
	end

	envprobe.debug.last_overlay_probe_count = #envprobe.probes
end

function envprobe.SetDebugDrawEnabled(enabled)
	envprobe.debug.draw_enabled = enabled == true

	if not envprobe.debug.draw_enabled then envprobe.ClearDebugOverlay() end
end

function envprobe.SetDebugLabelsEnabled(enabled)
	envprobe.debug.labels_enabled = enabled ~= false

	if not envprobe.debug.labels_enabled then
		local debug_draw = import.loaded["goluwa/debug_draw.lua"]

		if debug_draw then
			debug_draw.Remove(get_probe_overlay_id("text", 0))

			for i = 1, math.max(envprobe.debug.last_overlay_probe_count or 0, #envprobe.probes) do
				debug_draw.Remove(get_probe_overlay_id("text", i))
			end
		end
	end
end

function envprobe.SetDebugFocus(index)
	envprobe.debug.focus_index = math.max(math.floor(index or 0), 0)
end

function envprobe.SetDebugShowEnvironment(enabled)
	envprobe.debug.show_environment = enabled == true

	if not envprobe.debug.show_environment then
		local debug_draw = import.loaded["goluwa/debug_draw.lua"]

		if debug_draw then
			debug_draw.Remove(get_probe_overlay_id("sphere", 0))
			debug_draw.Remove(get_probe_overlay_id("text", 0))
		end
	end
end

function envprobe.DrawDebugOverlay()
	if not envprobe.debug.draw_enabled then return end

	local debug_draw = get_debug_draw_module()
	local probe_count = #envprobe.probes
	local previous_count = envprobe.debug.last_overlay_probe_count or 0

	if
		envprobe.debug.show_environment and
		envprobe.environment_probe and
		should_draw_probe(0)
	then
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

		if envprobe.debug.labels_enabled then
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

			if envprobe.debug.labels_enabled then
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

	envprobe.debug.last_overlay_probe_count = probe_count
end

function envprobe.SetDebugGridEnabled(enabled)
	envprobe.debug.grid_enabled = enabled == true
end

function envprobe.SetDebugGridShowDepth(enabled)
	envprobe.debug.grid_show_depth = enabled == true
end

local function draw_probe_grid_tile(debug_draw, x, y, tile_size, probe, probe_index, face_index)
	local texture = get_probe_face_texture(probe, face_index, envprobe.debug.grid_show_depth)
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
				envprobe.debug.grid_show_depth and "depth" or "src",
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

function envprobe.DrawDebugGrid()
	if not envprobe.debug.grid_enabled then return end

	local debug_draw = get_debug_draw_module()
	local tile_size = math.max(math.floor(envprobe.debug.grid_tile_size or 88), 32)
	local margin = math.max(math.floor(envprobe.debug.grid_margin or 12), 4)
	local screen_w, screen_h = render2d.GetSize()
	local visible_limit = math.max(math.floor(envprobe.debug.grid_limit or 4), 1)
	local probes_to_draw = {}
	local focus_index = envprobe.debug.focus_index or 0

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
			draw_probe_grid_tile(debug_draw, tile_x, tile_y, tile_size, entry.probe, entry.index, face_index)
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

function envprobe.DumpProbeFaces(index)
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

function envprobe.ExportProbeDepth(index)
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

function envprobe.Dump(limit)
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

function envprobe.MarkAllReflectionProbesDirty(update_mode)
	local marked = 0

	for _, probe in ipairs(envprobe.probes) do
		probe.needs_update = true

		if update_mode and probe.update_mode ~= update_mode then
			probe.update_mode = update_mode
		end

		marked = marked + 1
	end

	return marked
end

function envprobe.Initialize()
	envprobe.CreatePipelines()

	if envprobe.environment_probe and HOTRELOAD then
		remove_probe_resources(envprobe.environment_probe)
		envprobe.environment_probe = nil
	end

	if not envprobe.environment_probe then
		envprobe.CreateEnvironmentProbe(Vec3(0, 0, 0))
	end

	if not envprobe.camera then envprobe.camera = Camera3D.New() end

	envprobe.camera:SetFOV(math.rad(90))
	envprobe.camera:SetViewport(Rect(0, 0, envprobe.ENVIRONMENT_SIZE, envprobe.ENVIRONMENT_SIZE))
	envprobe.camera:SetNearZ(0.1)
	envprobe.camera:SetFarZ(1000)
	envprobe.environment_probe.needs_update = true
	render3d.SetEnvironmentTexture(envprobe.environment_probe.cubemap, envprobe.environment_probe.irradiance_cubemap)
	envprobe.MarkAllReflectionProbesDirty()
	envprobe.InitializeCubemapLayouts()
end

event.AddListener("Render3DInitialized", "envprobe", function()
	envprobe.Initialize()
end)

event.AddListener("SpawnProbe", "envprobe", function(position, radius, update_mode, min_spacing)
	envprobe.EnsureReflectionProbe(position, radius, update_mode or envprobe.UPDATE_STATIC, min_spacing)
end)

event.AddListener("Update", "envprobe_debug_overlay", function()
	envprobe.DrawDebugOverlay()
end)

event.AddListener("Update", "envprobe_auto_placement", function()
	if not envprobe.enabled or not envprobe.reflection_probes_enabled then return end

	local camera = render3d.GetRenderCamera()

	if not camera then return end

	envprobe.UpdateAutoPlacement(camera:GetPosition())
end)

event.AddListener("Draw2D", "envprobe_debug_grid", function()
	envprobe.DrawDebugGrid()
end)

function envprobe.InitializeCubemapLayouts()
	local cmd = render.GetCommandPool():AllocateCommandBuffer()
	cmd:Begin()
	initialize_probe_layouts(cmd, envprobe.environment_probe)

	for _, probe in ipairs(envprobe.probes) do
		initialize_probe_layouts(cmd, probe)
	end

	cmd:End()
	render.SubmitAndWait(cmd)
	cmd:Remove()
end

local fullscreen_direction_vertex = {
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
}

function envprobe.CreatePipelines()
	local EasyPipeline = import("goluwa/render/easy_pipeline.lua")

	for _, key in ipairs{
		"sky_pipeline",
		"prefilter_pipeline",
		"irradiance_pipeline",
		"capture_copy_pipeline",
		"capture_depth_pipeline",
	} do
		local pipeline = envprobe[key]

		if pipeline then pipeline:Remove() end

		envprobe[key] = nil
	end

	if envprobe.capture_bundles then
		for _, bundle in pairs(envprobe.capture_bundles) do
			render3d.RemovePipelineBundle(bundle)
		end

		envprobe.capture_bundles = nil
	end

	envprobe.sky_pipeline = EasyPipeline.New{
		ColorFormat = {
			{"b10g11r11_ufloat_pack32", {"color", "rgba"}},
			{"r32_sfloat", {"linear_depth", "r"}},
		},
		RasterizationSamples = "1",
		Blend = false,
		ColorWriteMask = "rgba",
		vertex = fullscreen_direction_vertex,
		fragment = {
			push_constants = {
				{
					name = "fragment",
					block = {
						{"sun_direction", "vec4"},
						{"camera_position", "vec4"},
						{"sun_intensity", "float"},
						unpack(atmosphere.GetBlockLayout()),
					},
					write = function(self, block)
						local sun = get_primary_sun(render3d.GetLights())
						local sun_direction = get_primary_sun_direction()
						sun_direction:CopyToFloatPointer(block.sun_direction)
						block.sun_direction[3] = 0
						block.sun_intensity = sun and sun.Intensity or atmosphere.GetSunIntensity()
						envprobe.camera:GetPosition():CopyToFloatPointer(block.camera_position)
						atmosphere.WriteBlock(self, block, envprobe.camera:GetPosition(), sun_direction)
						return block
					end,
				},
			},
			custom_declarations = [[
				layout(location = 0) in vec3 in_direction;
				]] .. atmosphere.GetGLSLDefines("fragment", "fragment.sun_intensity") .. atmosphere.GetGLSLCode() .. [[
			]],
			shader = [[
				void main() {
					vec3 sky_color_output;
					]] .. atmosphere.GetGLSLMainCode(
					"in_direction",
					"fragment.sun_direction.xyz",
					"fragment.camera_position.xyz",
					{include_sun_disc = false}
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
					set_linear_depth(1000.0);
				}
			]],
		},
		CullMode = "none",
		DepthTest = false,
		DepthWrite = false,
	}
	envprobe.capture_copy_pipeline = EasyPipeline.New{
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
						block.source_tex = self:GetTextureIndex(envprobe.current_capture_source_texture)
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
	envprobe.capture_depth_pipeline = EasyPipeline.New{
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
						block.depth_tex = self:GetTextureIndex(envprobe.current_capture_depth_texture)
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
	envprobe.prefilter_pipeline = EasyPipeline.New{
		ColorFormat = {{"b10g11r11_ufloat_pack32", {"color", "rgba"}}},
		RasterizationSamples = "1",
		CullMode = "none",
		DepthTest = false,
		DepthWrite = false,
		vertex = fullscreen_direction_vertex,
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
						local probe = envprobe.current_prefilter_probe
						block.roughness = envprobe.current_roughness or 0
						block.input_texture_index = self:GetCubeMapTextureIndex(probe.source_cubemap)
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
	envprobe.irradiance_pipeline = EasyPipeline.New{
		ColorFormat = {{"b10g11r11_ufloat_pack32", {"color", "rgba"}}},
		RasterizationSamples = "1",
		CullMode = "none",
		DepthTest = false,
		DepthWrite = false,
		vertex = fullscreen_direction_vertex,
		fragment = {
			push_constants = {
				{
					name = "fragment",
					block = {
						{"input_texture_index", "int"},
						{"source_lod", "float"},
					},
					write = function(self, block)
						local probe = envprobe.current_prefilter_probe
						block.input_texture_index = self:GetCubeMapTextureIndex(probe.source_cubemap)
						block.source_lod = math.max(math.log(probe.size / envprobe.IRRADIANCE_SOURCE_SIZE) / math.log(2), 0)
						return block
					end,
				},
			},
			custom_declarations = [[
				layout(location = 0) in vec3 in_direction;
				const int IRRADIANCE_SOURCE_SIZE = ]] .. envprobe.IRRADIANCE_SOURCE_SIZE .. [[;
			]],
			shader = [[
				vec3 get_cube_texel_direction(int face, vec2 uv) {
					if (face == 0) return vec3(1.0, uv.y, uv.x);
					if (face == 1) return vec3(-1.0, uv.y, uv.x);
					if (face == 2) return vec3(uv.x, 1.0, uv.y);
					if (face == 3) return vec3(uv.x, -1.0, uv.y);
					if (face == 4) return vec3(uv.x, uv.y, 1.0);
					return vec3(uv.x, uv.y, -1.0);
				}

				void main() {
					vec3 N = normalize(in_direction);
					vec3 irradiance = vec3(0.0);
					float texel_size = 2.0 / float(IRRADIANCE_SOURCE_SIZE);

					for (int face = 0; face < 6; face++) {
						for (int y = 0; y < IRRADIANCE_SOURCE_SIZE; y++) {
							for (int x = 0; x < IRRADIANCE_SOURCE_SIZE; x++) {
								vec2 uv = (vec2(float(x), float(y)) + 0.5) * texel_size - 1.0;
								vec3 texel_dir = get_cube_texel_direction(face, uv);
								float length_sq = dot(texel_dir, texel_dir);
								float NoL = dot(N, texel_dir) * inversesqrt(length_sq);

								if (NoL <= 0.0) continue;

								float solid_angle = texel_size * texel_size / (length_sq * sqrt(length_sq));
								vec3 radiance = min(textureLod(CUBEMAP(fragment.input_texture_index), texel_dir, fragment.source_lod).rgb, vec3(65504.0));
								irradiance += radiance * (NoL * solid_angle);
							}
						}
					}

					set_color(vec4(irradiance / 3.14159265359, 1.0));
				}
			]],
		},
	}
end

local pvm_cached = Matrix44()

function envprobe.GetProjectionViewWorldMatrix()
	render3d.GetWorldMatrix():GetMultiplied(envprobe.camera:BuildViewMatrix(), pvm_cached)
	pvm_cached:GetMultiplied(envprobe.camera:BuildProjectionMatrix(), pvm_cached)
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
	envprobe.capture_bundles = envprobe.capture_bundles or {}
	local bundle = envprobe.capture_bundles[size]

	if bundle then return bundle end

	bundle = render3d.CreatePipelineBundle{
		framebuffer_size = {x = size, y = size},
		filter = function(name)
			return name:find("^gbuffer") ~= nil or
				name == "ssr" or
				name == "lighting" or
				name == "ocean" or
				name == "voxel_gi_irradiance" or
				name == "voxel_gi_upsample"
		end,
	}
	envprobe.capture_bundles[size] = bundle
	return bundle
end

local function get_probe_capture_context()
	return {
		debug_mode = 1,
		allow_envprobe = false,
		allow_probe_reflections = false,
		allow_last_frame_history = false,
		pipeline_flags = {
			ssr = envprobe.capture_pipeline_flags.ssr == true,
			ocean = envprobe.capture_pipeline_flags.ocean ~= false,
		},
	}
end

local function get_probe_capture_source_texture(bundle)
	local current_idx = system.GetFrameNumber() % 2 + 1

	if
		envprobe.capture_pipeline_flags.ocean ~= false and
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

function envprobe.HasSunDirectionChanged()
	local sun = get_primary_sun(render3d.GetLights())

	if not sun then return false end

	local current_sun_dir = sun.Owner.transform:GetRotation():GetBackward()

	if not envprobe.last_sun_direction then
		envprobe.last_sun_direction = current_sun_dir:Copy()
		return true
	end

	local cos_angle = current_sun_dir:GetDot(envprobe.last_sun_direction)

	if cos_angle < math.cos(math.rad(envprobe.SUN_CHANGE_DEGREES)) then
		envprobe.last_sun_direction = current_sun_dir:Copy()
		return true
	end

	return false
end

local function transition_face(cmd, texture, face_idx, to_attachment)
	if to_attachment then
		render.TransitionResourceTo(
			texture,
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
	else
		render.TransitionResourceFrom(
			texture,
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
	end
end

local function draw_fullscreen(cmd, pipeline, size)
	cmd:SetViewport(0, 0, size, size)
	cmd:SetScissor(0, 0, size, size)
	cmd:SetCullMode("none")
	pipeline:UploadConstants()
	pipeline:Bind(cmd)
	cmd:Draw(3, 1, 0, 0)
end

function envprobe.RenderProbeFaces(cmd, probe, num_faces, render_geometry)
	if not envprobe.enabled then return end

	if not envprobe.sky_pipeline then return end

	num_faces = num_faces or 1
	render.PushCommandBuffer(cmd)
	local SIZE = probe.size
	envprobe.camera:SetPosition(probe.position)
	envprobe.camera:SetViewport(Rect(0, 0, SIZE, SIZE))

	for _ = 1, num_faces do
		local face_idx = envprobe.current_face
		envprobe.camera:SetAngles(face_angles[face_idx + 1])
		local proj = envprobe.camera:BuildProjectionMatrix()
		local view = envprobe.camera:BuildViewMatrix():Copy()
		view.m30, view.m31, view.m32 = 0, 0, 0
		local proj_view = view * proj
		proj_view:GetInverse(envprobe.inv_projection_view)

		if render_geometry then
			local bundle = get_probe_capture_bundle(SIZE)
			local capture_context = get_probe_capture_context()
			render3d.PushCamera(envprobe.camera)
			render3d.RunPipelineBundle(bundle, cmd, capture_context)
			render3d.PopCamera()
			envprobe.current_capture_source_texture = get_probe_capture_source_texture(bundle)
			envprobe.current_capture_depth_texture = get_probe_capture_depth_texture(bundle)
			transition_face(cmd, probe.source_cubemap, face_idx, true)
			transition_face(cmd, probe.depth_cubemap, face_idx, true)
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
			draw_fullscreen(cmd, envprobe.capture_copy_pipeline, SIZE)
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
			draw_fullscreen(cmd, envprobe.capture_depth_pipeline, SIZE)
			cmd:EndRendering()
		else
			transition_face(cmd, probe.source_cubemap, face_idx, true)
			transition_face(cmd, probe.depth_cubemap, face_idx, true)
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
			draw_fullscreen(cmd, envprobe.sky_pipeline, SIZE)
			cmd:EndRendering()
		end

		transition_face(cmd, probe.source_cubemap, face_idx, false)
		transition_face(cmd, probe.depth_cubemap, face_idx, false)
		envprobe.current_face = (envprobe.current_face + 1) % 6
	end

	render.PopCommandBuffer()
end

local function render_cube_faces(cmd, pipeline, texture, face_views, size, mip_level)
	for face = 0, 5 do
		envprobe.camera:SetAngles(face_angles[face + 1])
		local proj = envprobe.camera:BuildProjectionMatrix()
		local view = envprobe.camera:BuildViewMatrix():Copy()
		view.m30, view.m31, view.m32 = 0, 0, 0
		local proj_view = view * proj
		proj_view:GetInverse(envprobe.inv_projection_view)
		render.TransitionResourceTo(
			texture,
			"color_attachment_optimal",
			{
				cmd = cmd,
				srcStage = "fragment_shader",
				srcAccess = "shader_read",
				dstStage = "color_attachment_output",
				dstAccess = "color_attachment_write",
				base_array_layer = face,
				layer_count = 1,
				base_mip_level = mip_level,
				level_count = 1,
			}
		)
		cmd:BeginRendering{
			color_image_view = face_views[face],
			w = size,
			h = size,
			clear_color = {0, 0, 0, 1},
		}
		draw_fullscreen(cmd, pipeline, size)
		cmd:EndRendering()
		render.TransitionResourceFrom(
			texture,
			"shader_read_only_optimal",
			{
				cmd = cmd,
				srcStage = "color_attachment_output",
				srcAccess = "color_attachment_write",
				dstStage = "fragment_shader",
				dstAccess = "shader_read",
				base_array_layer = face,
				layer_count = 1,
				base_mip_level = mip_level,
				level_count = 1,
			}
		)
	end
end

function envprobe.PrefilterProbe(cmd, probe)
	if not envprobe.prefilter_pipeline then return end

	render.PushCommandBuffer(cmd)
	local SIZE = probe.size
	local num_mips = probe.cubemap.mip_map_levels
	envprobe.current_prefilter_probe = probe
	probe.source_cubemap:GenerateMipmaps("shader_read_only_optimal")
	local roughest_mip = math.max(math.min(ibl.GetPrefilterMipCount(SIZE), num_mips) - 1, 1)

	for m = 0, num_mips - 1 do
		envprobe.current_roughness = math.min(m / roughest_mip, 1)
		local mip_size = math.max(1, math.floor(SIZE / (2 ^ m)))
		render_cube_faces(
			cmd,
			envprobe.prefilter_pipeline,
			probe.cubemap,
			probe.mip_face_views[m],
			mip_size,
			m
		)
	end

	if probe.irradiance_cubemap then
		render_cube_faces(
			cmd,
			envprobe.irradiance_pipeline,
			probe.irradiance_cubemap,
			probe.irradiance_face_views,
			envprobe.IRRADIANCE_SIZE,
			0
		)
	end

	render.PopCommandBuffer()
end

function envprobe.UpdateEnvironmentProbe(cmd, sun_changed)
	if not envprobe.environment_probe then return end

	local env_probe = envprobe.environment_probe
	sun_changed = sun_changed == nil and envprobe.HasSunDirectionChanged() or sun_changed

	if not sun_changed and not env_probe.needs_update then return end

	local own_cmd
	cmd, own_cmd = acquire_probe_command_buffer(cmd)
	local saved_face = envprobe.current_face
	envprobe.current_face = 0
	envprobe.RenderProbeFaces(cmd, env_probe, 6, false)
	envprobe.PrefilterProbe(cmd, env_probe)
	envprobe.current_face = saved_face
	env_probe.needs_update = false
	env_probe.last_rendered = system.GetTime()
	submit_probe_command_buffer(cmd, own_cmd)
end

function envprobe.GetProbes()
	return envprobe.probes
end

function envprobe.SetEnabled(enabled)
	envprobe.enabled = enabled
end

function envprobe.IsEnabled()
	return envprobe.enabled
end

function envprobe.SetReflectionProbesEnabled(enabled)
	local value = enabled ~= false

	if envprobe.reflection_probes_enabled == value then return end

	envprobe.reflection_probes_enabled = value

	if value then envprobe.MarkAllReflectionProbesDirty() end
end

function envprobe.AreReflectionProbesEnabled()
	return envprobe.reflection_probes_enabled
end

function envprobe.SetStarsTexture(texture)
	atmosphere.SetStarsTexture(texture)
end

function envprobe.GetStarsTexture()
	return atmosphere.GetStarsTexture()
end

local function is_probe_in_list(probe)
	for _, other in ipairs(envprobe.probes) do
		if other == probe then return true end
	end

	return false
end
local function select_probe_to_capture(now, camera_position)
	local current = envprobe.current_probe

	if current and envprobe.current_face > 0 and is_probe_in_list(current) then
		return current
	end

	local best
	local best_score = -math.huge

	for _, probe in ipairs(envprobe.probes) do
		local score

		if probe.needs_update then
			score = 1e9 - (probe.position - camera_position):GetLength()
		elseif
			probe.update_mode == envprobe.UPDATE_DYNAMIC and
			now - (
				probe.last_rendered or
				0
			) >= envprobe.DYNAMIC_INTERVAL
		then
			score = (
					now - (
						probe.last_rendered or
						0
					)
				) * 100 - (
					probe.position - camera_position
				):GetLength()
		end

		if score and score > best_score then
			best_score = score
			best = probe
		end
	end

	return best
end

event.AddListener("PreRenderPass", "envprobe_update", function()
	if not envprobe.enabled then return end

	if not envprobe.sky_pipeline then return end

	local cmd, own_cmd = acquire_probe_command_buffer()
	local sun_changed = envprobe.HasSunDirectionChanged()

	if sun_changed then envprobe.MarkAllReflectionProbesDirty() end

	envprobe.UpdateEnvironmentProbe(cmd, sun_changed)

	if envprobe.reflection_probes_enabled and #envprobe.probes > 0 then
		local now = system.GetTime()
		local probe = select_probe_to_capture(now, render3d.GetRenderCamera():GetPosition())

		if probe then
			if probe ~= envprobe.current_probe then
				envprobe.current_probe = probe
				envprobe.current_face = 0
			end

			local faces = math.max(math.floor(envprobe.FACES_PER_FRAME), 1)
			faces = math.min(faces, 6 - envprobe.current_face)
			envprobe.RenderProbeFaces(cmd, probe, faces, true)

			if envprobe.current_face == 0 then
				envprobe.PrefilterProbe(cmd, probe)
				probe.needs_update = false
				probe.last_rendered = now
				envprobe.current_probe = nil
			end
		end
	end

	submit_probe_command_buffer(cmd, own_cmd)
end)

commands.Add("envprobe_dump=number|nil", function(limit)
	envprobe.Dump(limit)
end)

commands.Add("envprobe_reflection_probes=boolean[true]", function(enabled)
	envprobe.SetReflectionProbesEnabled(enabled)
	logf("[envprobe] reflection probes %s\n", enabled and "enabled" or "disabled")
end)

commands.Add("envprobe_auto_placement=boolean[true]", function(enabled)
	envprobe.SetAutoPlacementEnabled(enabled)
	logf("[envprobe] auto placement %s\n", enabled and "enabled" or "disabled")
end)

commands.Add("envprobe_spawn=number|nil,string|nil", function(radius, update_mode)
	if update_mode == "" then update_mode = nil end

	local position = render3d.GetRenderCamera():GetPosition()
	local probe, created = envprobe.EnsureReflectionProbe(position, radius, update_mode or envprobe.UPDATE_STATIC)
	envprobe.SetReflectionProbesEnabled(true)
	logf(
		"[envprobe] %s reflection probe at (%.1f %.1f %.1f) radius %.1f\n",
		created and "spawned" or "reused",
		probe.position.x,
		probe.position.y,
		probe.position.z,
		probe.radius
	)
end)

commands.Add("envprobe_clear", function()
	envprobe.ClearReflectionProbes()
	logf("[envprobe] removed all reflection probes\n")
end)

commands.Add("envprobe_debug_draw=boolean[true]", function(enabled)
	envprobe.SetDebugDrawEnabled(enabled)
	logf("[envprobe] debug overlay %s\n", enabled and "enabled" or "disabled")
end)

commands.Add("envprobe_debug_labels=boolean[true]", function(enabled)
	envprobe.SetDebugLabelsEnabled(enabled)
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

	envprobe.SetDebugFocus(index)

	if index > 0 then
		logf("[envprobe] focusing probe %d\n", index)
	else
		logf("[envprobe] focus cleared\n")
	end
end)

commands.Add("envprobe_debug_environment=boolean[true]", function(enabled)
	envprobe.SetDebugShowEnvironment(enabled)
	logf("[envprobe] environment overlay %s\n", enabled and "enabled" or "disabled")
end)

commands.Add("envprobe_debug_grid=boolean[true]", function(enabled)
	envprobe.SetDebugGridEnabled(enabled)
	logf("[envprobe] debug grid %s\n", enabled and "enabled" or "disabled")
end)

commands.Add("envprobe_debug_grid_depth=boolean[true]", function(enabled)
	envprobe.SetDebugGridShowDepth(enabled)
	logf("[envprobe] debug grid mode %s\n", enabled and "depth" or "source")
end)

commands.Add("envprobe_dump_faces=number", function(index)
	envprobe.DumpProbeFaces(index)
end)

commands.Add("envprobe_export_depth=number", function(index)
	envprobe.ExportProbeDepth(index)
end)

commands.Add("envprobe_rebuild=string|nil", function(update_mode)
	if update_mode == "" then update_mode = nil end

	if update_mode then
		assert(
			update_mode == envprobe.UPDATE_STATIC or
				update_mode == envprobe.UPDATE_DYNAMIC or
				update_mode == envprobe.UPDATE_MANUAL,
			"envprobe_rebuild expects static, dynamic, or manual"
		)
	end

	local marked = envprobe.MarkAllReflectionProbesDirty(update_mode)
	logf(
		"[envprobe] marked %d reflection probes dirty%s\n",
		marked,
		update_mode and (" mode=" .. update_mode) or ""
	)
end)

if
	not render3d.initializing and
	render3d and
	render3d.pipelines and
	render3d.pipelines.gbuffer
then
	envprobe.Initialize()
end

return envprobe
