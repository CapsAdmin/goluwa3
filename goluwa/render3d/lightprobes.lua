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
local lightprobes = library()

-- Cubemap probes for specular reflections.
--
-- The environment probe renders the sky only and provides the global
-- specular environment plus the sky irradiance cubemap that diffuse lighting
-- falls back to outside the voxel gi volumes (see global_illumination.lua, which owns
-- diffuse global illumination).
--
-- Reflection probes capture the scene into a prefiltered cubemap plus a
-- radial depth cubemap for parallax correction, and are meant for glossy
-- surfaces that screen space reflections cannot cover. Captures are spread
-- over frames, nearest dirty probes first.
--
-- Placement is a horizontal grid recentered on the camera every
-- AUTO_PLACEMENT_INTERVAL seconds (UpdateAutoPlacement) - it doesn't query
-- scene geometry, so probes just blanket the area on a fixed spacing and
-- some will end up embedded in walls or floating in open air. Probes can
-- also be placed explicitly (CreateReflectionProbe, or the SpawnProbe event
-- that map loaders emit for their cubemap entities); those aren't touched
-- by the auto-placement grid's cleanup.
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
lightprobes.TYPE_ENVIRONMENT = "environment" -- Sky only, re-rendered when the sun moves
lightprobes.TYPE_REFLECTION = "reflection" -- Renders geometry
-- Update modes
lightprobes.UPDATE_DYNAMIC = "dynamic" -- Re-captured continuously
lightprobes.UPDATE_STATIC = "static" -- Captured once, and again when the sun moves
lightprobes.UPDATE_MANUAL = "manual" -- Captured only when marked dirty
-- Configuration
lightprobes.ENVIRONMENT_SIZE = 512
lightprobes.REFLECTION_SIZE = 128
lightprobes.IRRADIANCE_SIZE = 32 -- Sky irradiance cubemap face size
lightprobes.IRRADIANCE_SOURCE_SIZE = 16 -- Source mip face size the irradiance convolution integrates over
lightprobes.REFLECTION_RADIUS = lightprobes.REFLECTION_RADIUS or 24
lightprobes.REFLECTION_MIN_SPACING = lightprobes.REFLECTION_MIN_SPACING or 4
lightprobes.FACES_PER_FRAME = lightprobes.FACES_PER_FRAME or 2
lightprobes.DYNAMIC_INTERVAL = lightprobes.DYNAMIC_INTERVAL or 0.25 -- seconds between captures of a dynamic probe
lightprobes.SUN_CHANGE_DEGREES = lightprobes.SUN_CHANGE_DEGREES or 1
lightprobes.MAX_UPLOADED_PROBES = 64 -- shader array size in ssr.lua
lightprobes.enabled = lightprobes.enabled ~= false
lightprobes.reflection_probes_enabled = lightprobes.reflection_probes_enabled ~= false
lightprobes.capture_pipeline_flags = lightprobes.capture_pipeline_flags or {
	ssr = false,
	ocean = true,
}
-- Automatic placement: a horizontal grid of probes recentered on the camera,
-- with no scene geometry queries. Coverage over correctness - some probes
-- will end up embedded in geometry or floating in open air.
lightprobes.auto_placement_enabled = lightprobes.auto_placement_enabled ~= false
lightprobes.AUTO_PLACEMENT_SPACING = lightprobes.AUTO_PLACEMENT_SPACING or 48
lightprobes.AUTO_PLACEMENT_RADIUS_CELLS = lightprobes.AUTO_PLACEMENT_RADIUS_CELLS or 2
lightprobes.AUTO_PLACEMENT_INTERVAL = lightprobes.AUTO_PLACEMENT_INTERVAL or 1
-- State
lightprobes.probes = lightprobes.probes or {}
lightprobes.auto_grid = lightprobes.auto_grid or {} -- grid key -> auto-placed probe
lightprobes.auto_last_update = lightprobes.auto_last_update or 0
lightprobes.current_probe = lightprobes.current_probe or nil -- reflection probe currently being captured
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

-- with_irradiance adds the cosine convolved irradiance cubemap, only the
-- environment probe needs it
local function CreateProbeTextures(size, with_irradiance)
	local probe = {}
	-- prefiltered output used for rendering
	probe.cubemap = create_cubemap(size, "b10g11r11_ufloat_pack32", "auto")
	-- raw capture before prefiltering
	probe.source_cubemap = create_cubemap(size, "b10g11r11_ufloat_pack32", "auto")
	-- radial depth for parallax correction
	probe.depth_cubemap = create_cubemap(size, "r32_sfloat", 1)
	probe.source_face_views = create_face_views(probe.source_cubemap)
	probe.depth_face_views = create_face_views(probe.depth_cubemap)
	probe.mip_face_views = {}

	for m = 0, probe.cubemap.mip_map_levels - 1 do
		probe.mip_face_views[m] = create_face_views(probe.cubemap, m)
	end

	if with_irradiance then
		probe.irradiance_cubemap = create_cubemap(lightprobes.IRRADIANCE_SIZE, "b10g11r11_ufloat_pack32", 1)
		probe.irradiance_face_views = create_face_views(probe.irradiance_cubemap)
	end

	return probe
end

function lightprobes.CreateEnvironmentProbe(position)
	local probe = CreateProbeTextures(lightprobes.ENVIRONMENT_SIZE, true)
	probe.type = lightprobes.TYPE_ENVIRONMENT
	probe.update_mode = lightprobes.UPDATE_DYNAMIC
	probe.position = position or Vec3(0, 0, 0)
	probe.size = lightprobes.ENVIRONMENT_SIZE
	probe.needs_update = true
	probe.last_rendered = 0
	lightprobes.environment_probe = probe
	return probe
end

function lightprobes.CreateReflectionProbe(position, radius, update_mode)
	local probe = CreateProbeTextures(lightprobes.REFLECTION_SIZE, false)
	probe.type = lightprobes.TYPE_REFLECTION
	probe.update_mode = update_mode or lightprobes.UPDATE_STATIC
	probe.position = position:Copy()
	probe.radius = radius or lightprobes.REFLECTION_RADIUS
	probe.size = lightprobes.REFLECTION_SIZE
	probe.needs_update = true
	probe.last_rendered = 0
	table.insert(lightprobes.probes, probe)
	initialize_probe_layouts_now(probe)
	return probe
end

local function remove_from_auto_grid(probe)
	if not probe.auto_grid_key then return end

	if lightprobes.auto_grid[probe.auto_grid_key] == probe then
		lightprobes.auto_grid[probe.auto_grid_key] = nil
	end
end

function lightprobes.RemoveReflectionProbe(probe)
	for i, other in ipairs(lightprobes.probes) do
		if other == probe then
			table.remove(lightprobes.probes, i)

			if lightprobes.current_probe == probe then
				lightprobes.current_probe = nil
				lightprobes.current_face = 0
			end

			remove_from_auto_grid(probe)
			remove_probe_resources(probe)
			return true
		end
	end

	return false
end

function lightprobes.ClearReflectionProbes()
	for _, probe in ipairs(lightprobes.probes) do
		remove_probe_resources(probe)
	end

	lightprobes.probes = {}
	lightprobes.auto_grid = {}
	lightprobes.current_probe = nil
	lightprobes.current_face = 0
	lightprobes.ClearDebugOverlay()
end

function lightprobes.FindNearestReflectionProbe(position, max_distance)
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

-- Creates a probe unless one already exists within min_spacing, in which
-- case that probe is returned (and grown to the requested radius).
function lightprobes.EnsureReflectionProbe(position, radius, update_mode, min_spacing)
	min_spacing = min_spacing or lightprobes.REFLECTION_MIN_SPACING
	local probe, distance = lightprobes.FindNearestReflectionProbe(position, min_spacing)

	if probe then
		if radius and radius > (probe.radius or 0) then probe.radius = radius end

		if update_mode and probe.update_mode ~= update_mode then
			probe.update_mode = update_mode
			probe.needs_update = true
		end

		return probe, false, distance
	end

	return lightprobes.CreateReflectionProbe(position, radius, update_mode),
	true,
	distance
end

local function auto_grid_key(cx, cy, cz)
	return cx .. "," .. cy .. "," .. cz
end

-- Recenters a horizontal grid of auto-placed reflection probes on the
-- camera. This has no idea where geometry is - it just blankets the area
-- around the camera with probes on a fixed spacing so that glossy surfaces
-- have *something* nearby to sample, and lets the normal capture/dirty
-- pipeline sort out what actually ends up visible in each one.
function lightprobes.UpdateAutoPlacement(camera_position)
	if not lightprobes.auto_placement_enabled then return end

	local now = system.GetTime()

	if now - lightprobes.auto_last_update < lightprobes.AUTO_PLACEMENT_INTERVAL then return end

	lightprobes.auto_last_update = now
	local spacing = lightprobes.AUTO_PLACEMENT_SPACING
	local radius_cells = lightprobes.AUTO_PLACEMENT_RADIUS_CELLS
	local cx = math.floor(camera_position.x / spacing + 0.5)
	local cy = math.floor(camera_position.y / spacing + 0.5)
	local cz = math.floor(camera_position.z / spacing + 0.5)
	local wanted = {}

	for x = -radius_cells, radius_cells do
		for z = -radius_cells, radius_cells do
			local gx, gz = cx + x, cz + z
			local key = auto_grid_key(gx, cy, gz)
			wanted[key] = true

			if not lightprobes.auto_grid[key] then
				local position = Vec3(gx * spacing, cy * spacing, gz * spacing)
				local probe = lightprobes.CreateReflectionProbe(position, spacing * 0.75, lightprobes.UPDATE_STATIC)
				probe.auto = true
				probe.auto_grid_key = key
				lightprobes.auto_grid[key] = probe
			end
		end
	end

	for key, probe in pairs(lightprobes.auto_grid) do
		if not wanted[key] then
			lightprobes.RemoveReflectionProbe(probe)
			lightprobes.auto_grid[key] = nil
		end
	end
end

function lightprobes.SetAutoPlacementEnabled(enabled)
	lightprobes.auto_placement_enabled = enabled ~= false

	if not lightprobes.auto_placement_enabled then
		for key, probe in pairs(lightprobes.auto_grid) do
			lightprobes.RemoveReflectionProbe(probe)
			lightprobes.auto_grid[key] = nil
		end
	else
		lightprobes.auto_last_update = 0
	end
end

local nearest_probe_sort_position

local function nearest_probe_comparator(a, b)
	return (a.position - nearest_probe_sort_position):GetLengthSquared() <
		(b.position - nearest_probe_sort_position):GetLengthSquared()
end

-- The probes nearest to a position, at most limit of them, for uploading to
-- shaders with a fixed probe array.
function lightprobes.GetProbesNear(position, limit)
	limit = limit or lightprobes.MAX_UPLOADED_PROBES
	local probes = lightprobes.probes

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

-- Uniform block for shaders that sample reflection probes directly (ssr.lua,
-- lighting.lua). Shared here so every consumer uploads probes the same way
-- instead of duplicating the write loop per pass.
function lightprobes.GetProbeBlockLayout()
	return {
		{"probe_color_textures", "int", lightprobes.MAX_UPLOADED_PROBES},
		{"probe_depth_textures", "int", lightprobes.MAX_UPLOADED_PROBES},
		{"probe_positions", "vec4", lightprobes.MAX_UPLOADED_PROBES},
	}
end

function lightprobes.WriteProbeBlock(self, block, camera_position)
	local max_probes = lightprobes.MAX_UPLOADED_PROBES

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
			lightprobes.IsEnabled() and
			lightprobes.AreReflectionProbesEnabled() and
			render3d.ShouldUseProbeReflections()
		)
	then
		return block
	end

	camera_position = camera_position or render3d.GetRenderCamera():GetPosition()
	local probes = lightprobes.GetProbesNear(camera_position, max_probes)

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
			block.probe_positions[i][3] = probe.radius or lightprobes.REFLECTION_RADIUS
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

	if probe == lightprobes.current_probe then
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

	if probe == lightprobes.current_probe then
		lines[3] = string.format("capturing face %d", lightprobes.current_face)
	elseif age then
		lines[3] = string.format("last %.2fs ago", age)
	else
		lines[3] = "last never"
	end

	return lines
end

function lightprobes.ClearDebugOverlay()
	local debug_draw = import.loaded["goluwa/debug_draw.lua"]

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
		local debug_draw = import.loaded["goluwa/debug_draw.lua"]

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
		local debug_draw = import.loaded["goluwa/debug_draw.lua"]

		if debug_draw then
			debug_draw.Remove(get_probe_overlay_id("sphere", 0))
			debug_draw.Remove(get_probe_overlay_id("text", 0))
		end
	end
end

function lightprobes.DrawDebugOverlay()
	if not lightprobes.debug.draw_enabled then return end

	local debug_draw = get_debug_draw_module()
	local probe_count = #lightprobes.probes
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
				radius = probe.radius or lightprobes.REFLECTION_RADIUS,
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

	if previous_count > probe_count then
		for i = probe_count + 1, previous_count do
			debug_draw.Remove(get_probe_overlay_id("sphere", i))
			debug_draw.Remove(get_probe_overlay_id("text", i))
		end
	end

	lightprobes.debug.last_overlay_probe_count = probe_count
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
		local probe = get_reflection_probe(focus_index)

		if probe then probes_to_draw[1] = {index = focus_index, probe = probe} end
	else
		for i, probe in ipairs(lightprobes.probes) do
			probes_to_draw[#probes_to_draw + 1] = {index = i, probe = probe}

			if #probes_to_draw >= visible_limit then break end
		end
	end

	if #probes_to_draw == 0 then
		debug_draw.DrawTextBlock(
			{"lightprobes grid", "no reflection probes"},
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
	local probe = get_reflection_probe(index)

	if not probe then
		logf(
			"[lightprobes] no reflection probe at index %s (have %d)\n",
			tostring(index),
			#lightprobes.probes
		)
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
	local probe = get_reflection_probe(index)

	if not probe then
		logf(
			"[lightprobes] no reflection probe at index %s (have %d)\n",
			tostring(index),
			#lightprobes.probes
		)
		return nil
	end

	local fs = import("goluwa/filesystem/fs.lua")
	local dir = "tmp/lightprobes/"
	assert(fs.create_directory_recursive(dir))

	for face_index = 0, 5 do
		local path = string.format("%sprobe_%02d_depth_%s.png", dir, index, face_names[face_index + 1])
		probe.depth_cubemap:Download{base_array_layer = face_index}:Save(path)
		logf("[lightprobes] saved %s\n", path)
	end

	return true
end

function lightprobes.Dump(limit)
	limit = math.max(math.floor(limit or #lightprobes.probes), 0)
	logf(
		"[lightprobes] enabled=%s reflection_probes=%s count=%d current_face=%d\n",
		tostring(lightprobes.enabled == true),
		tostring(lightprobes.reflection_probes_enabled == true),
		#lightprobes.probes,
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
			tostring(probe == lightprobes.current_probe)
		)
	end

	if limit < #lightprobes.probes then
		logf("[lightprobes] ... %d more probes omitted\n", #lightprobes.probes - limit)
	end
end

function lightprobes.MarkAllReflectionProbesDirty(update_mode)
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

	if not lightprobes.environment_probe then
		lightprobes.CreateEnvironmentProbe(Vec3(0, 0, 0))
	end

	if not lightprobes.camera then lightprobes.camera = Camera3D.New() end

	lightprobes.camera:SetFOV(math.rad(90))
	lightprobes.camera:SetViewport(Rect(0, 0, lightprobes.ENVIRONMENT_SIZE, lightprobes.ENVIRONMENT_SIZE))
	lightprobes.camera:SetNearZ(0.1)
	lightprobes.camera:SetFarZ(1000)
	lightprobes.environment_probe.needs_update = true
	render3d.SetEnvironmentTexture(lightprobes.environment_probe.cubemap, lightprobes.environment_probe.irradiance_cubemap)
	lightprobes.MarkAllReflectionProbesDirty()
	lightprobes.InitializeCubemapLayouts()
end

event.AddListener("Render3DInitialized", "lightprobes", function()
	lightprobes.Initialize()
end)

-- Map loaders emit this for their cubemap entities
event.AddListener("SpawnProbe", "lightprobes", function(position, radius, update_mode, min_spacing)
	lightprobes.EnsureReflectionProbe(position, radius, update_mode or lightprobes.UPDATE_STATIC, min_spacing)
end)

event.AddListener("Update", "lightprobes_debug_overlay", function()
	lightprobes.DrawDebugOverlay()
end)

event.AddListener("Update", "lightprobes_auto_placement", function()
	if not lightprobes.enabled or not lightprobes.reflection_probes_enabled then return end

	local camera = render3d.GetRenderCamera()

	if not camera then return end

	lightprobes.UpdateAutoPlacement(camera:GetPosition())
end)

event.AddListener("Draw2D", "lightprobes_debug_grid", function()
	lightprobes.DrawDebugGrid()
end)

function lightprobes.InitializeCubemapLayouts()
	local cmd = render.GetCommandPool():AllocateCommandBuffer()
	cmd:Begin()
	initialize_probe_layouts(cmd, lightprobes.environment_probe)

	for _, probe in ipairs(lightprobes.probes) do
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

function lightprobes.CreatePipelines()
	local EasyPipeline = import("goluwa/render/easy_pipeline.lua")

	for _, key in ipairs{
		"sky_pipeline",
		"prefilter_pipeline",
		"irradiance_pipeline",
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

	-- Sky only, for the environment probe
	lightprobes.sky_pipeline = EasyPipeline.New{
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
						lightprobes.camera:GetPosition():CopyToFloatPointer(block.camera_position)
						atmosphere.WriteBlock(self, block, lightprobes.camera:GetPosition(), sun_direction)
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
	-- Copies the capture bundle's lit output into a cubemap face
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
	-- Converts the capture's depth buffer into radial distance from the probe
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
	-- GGX prefilter of the source cubemap into the roughness mip chain
	lightprobes.prefilter_pipeline = EasyPipeline.New{
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
						local probe = lightprobes.current_prefilter_probe
						block.roughness = lightprobes.current_roughness or 0
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
	-- Diffuse irradiance: integrates every texel of a small mip of the
	-- source cubemap against the cosine lobe of the output direction. The
	-- result is divided by pi so that multiplying by albedo gives the
	-- outgoing diffuse radiance.
	lightprobes.irradiance_pipeline = EasyPipeline.New{
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
						local probe = lightprobes.current_prefilter_probe
						block.input_texture_index = self:GetCubeMapTextureIndex(probe.source_cubemap)
						block.source_lod = math.max(math.log(probe.size / lightprobes.IRRADIANCE_SOURCE_SIZE) / math.log(2), 0)
						return block
					end,
				},
			},
			custom_declarations = [[
				layout(location = 0) in vec3 in_direction;
				const int IRRADIANCE_SOURCE_SIZE = ]] .. lightprobes.IRRADIANCE_SOURCE_SIZE .. [[;
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
			-- the two voxel gi screen passes come along because lighting reads
			-- its diffuse gi out of their target now; the probe update pass
			-- itself stays out, a capture must not refresh the probe grids
			return name:find("^gbuffer") ~= nil or
				name == "ssr" or
				name == "lighting" or
				name == "ocean" or
				name == "voxel_gi_irradiance" or
				name == "voxel_gi_upsample"
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
			ssr = lightprobes.capture_pipeline_flags.ssr == true,
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

-- True when the sun moved more than SUN_CHANGE_DEGREES since the last check
function lightprobes.HasSunDirectionChanged()
	local sun = get_primary_sun(render3d.GetLights())

	if not sun then return false end

	local current_sun_dir = sun.Owner.transform:GetRotation():GetBackward()

	if not lightprobes.last_sun_direction then
		lightprobes.last_sun_direction = current_sun_dir:Copy()
		return true
	end

	local cos_angle = current_sun_dir:GetDot(lightprobes.last_sun_direction)

	if cos_angle < math.cos(math.rad(lightprobes.SUN_CHANGE_DEGREES)) then
		lightprobes.last_sun_direction = current_sun_dir:Copy()
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

-- Renders num_faces faces of a probe starting at lightprobes.current_face.
-- render_geometry captures the scene, otherwise only the sky is drawn.
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
		lightprobes.camera:SetAngles(face_angles[face_idx + 1])
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
			draw_fullscreen(cmd, lightprobes.capture_copy_pipeline, SIZE)
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
			draw_fullscreen(cmd, lightprobes.capture_depth_pipeline, SIZE)
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
			draw_fullscreen(cmd, lightprobes.sky_pipeline, SIZE)
			cmd:EndRendering()
		end

		transition_face(cmd, probe.source_cubemap, face_idx, false)
		transition_face(cmd, probe.depth_cubemap, face_idx, false)
		lightprobes.current_face = (lightprobes.current_face + 1) % 6
	end

	render.PopCommandBuffer()
end

local function render_cube_faces(cmd, pipeline, texture, face_views, size, mip_level)
	for face = 0, 5 do
		lightprobes.camera:SetAngles(face_angles[face + 1])
		local proj = lightprobes.camera:BuildProjectionMatrix()
		local view = lightprobes.camera:BuildViewMatrix():Copy()
		view.m30, view.m31, view.m32 = 0, 0, 0
		local proj_view = view * proj
		proj_view:GetInverse(lightprobes.inv_projection_view)
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

-- Prefilters the source cubemap into the output mip chain, and builds the
-- irradiance cubemap for probes that have one.
function lightprobes.PrefilterProbe(cmd, probe)
	if not lightprobes.prefilter_pipeline then return end

	render.PushCommandBuffer(cmd)
	local SIZE = probe.size
	local num_mips = probe.cubemap.mip_map_levels
	lightprobes.current_prefilter_probe = probe
	probe.source_cubemap:GenerateMipmaps("shader_read_only_optimal")
	local roughest_mip = math.max(math.min(ibl.GetPrefilterMipCount(SIZE), num_mips) - 1, 1)

	-- Roughness 0..1 maps onto the mips down to the roughest usable face
	-- size; the remaining tiny mips repeat roughness 1 so trilinear lookups
	-- never reach unfiltered data.
	for m = 0, num_mips - 1 do
		lightprobes.current_roughness = math.min(m / roughest_mip, 1)
		local mip_size = math.max(1, math.floor(SIZE / (2 ^ m)))
		render_cube_faces(
			cmd,
			lightprobes.prefilter_pipeline,
			probe.cubemap,
			probe.mip_face_views[m],
			mip_size,
			m
		)
	end

	if probe.irradiance_cubemap then
		render_cube_faces(
			cmd,
			lightprobes.irradiance_pipeline,
			probe.irradiance_cubemap,
			probe.irradiance_face_views,
			lightprobes.IRRADIANCE_SIZE,
			0
		)
	end

	render.PopCommandBuffer()
end

function lightprobes.UpdateEnvironmentProbe(cmd, sun_changed)
	if not lightprobes.environment_probe then return end

	local env_probe = lightprobes.environment_probe
	sun_changed = sun_changed == nil and lightprobes.HasSunDirectionChanged() or sun_changed

	if not sun_changed and not env_probe.needs_update then return end

	local own_cmd
	cmd, own_cmd = acquire_probe_command_buffer(cmd)
	local saved_face = lightprobes.current_face
	lightprobes.current_face = 0
	lightprobes.RenderProbeFaces(cmd, env_probe, 6, false)
	lightprobes.PrefilterProbe(cmd, env_probe)
	lightprobes.current_face = saved_face
	env_probe.needs_update = false
	env_probe.last_rendered = system.GetTime()
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

function lightprobes.SetReflectionProbesEnabled(enabled)
	local value = enabled ~= false

	if lightprobes.reflection_probes_enabled == value then return end

	lightprobes.reflection_probes_enabled = value

	if value then lightprobes.MarkAllReflectionProbesDirty() end
end

function lightprobes.AreReflectionProbesEnabled()
	return lightprobes.reflection_probes_enabled
end

-- Compatibility with old skybox API
function lightprobes.SetStarsTexture(texture)
	atmosphere.SetStarsTexture(texture)
end

function lightprobes.GetStarsTexture()
	return atmosphere.GetStarsTexture()
end

local function is_probe_in_list(probe)
	for _, other in ipairs(lightprobes.probes) do
		if other == probe then return true end
	end

	return false
end

-- Picks the probe to capture next: a capture in progress is finished first,
-- then the nearest dirty probe, then the stalest dynamic probe that is due.
local function select_probe_to_capture(now, camera_position)
	local current = lightprobes.current_probe

	if current and lightprobes.current_face > 0 and is_probe_in_list(current) then
		return current
	end

	local best
	local best_score = -math.huge

	for _, probe in ipairs(lightprobes.probes) do
		local score

		if probe.needs_update then
			score = 1e9 - (probe.position - camera_position):GetLength()
		elseif
			probe.update_mode == lightprobes.UPDATE_DYNAMIC and
			now - (
				probe.last_rendered or
				0
			) >= lightprobes.DYNAMIC_INTERVAL
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

event.AddListener("PreRenderPass", "lightprobes_update", function()
	if not lightprobes.enabled then return end

	if not lightprobes.sky_pipeline then return end

	local cmd, own_cmd = acquire_probe_command_buffer()
	local sun_changed = lightprobes.HasSunDirectionChanged()

	if sun_changed then lightprobes.MarkAllReflectionProbesDirty() end

	lightprobes.UpdateEnvironmentProbe(cmd, sun_changed)

	if lightprobes.reflection_probes_enabled and #lightprobes.probes > 0 then
		local now = system.GetTime()
		local probe = select_probe_to_capture(now, render3d.GetRenderCamera():GetPosition())

		if probe then
			if probe ~= lightprobes.current_probe then
				lightprobes.current_probe = probe
				lightprobes.current_face = 0
			end

			local faces = math.max(math.floor(lightprobes.FACES_PER_FRAME), 1)
			faces = math.min(faces, 6 - lightprobes.current_face)
			lightprobes.RenderProbeFaces(cmd, probe, faces, true)

			if lightprobes.current_face == 0 then
				lightprobes.PrefilterProbe(cmd, probe)
				probe.needs_update = false
				probe.last_rendered = now
				lightprobes.current_probe = nil
			end
		end
	end

	submit_probe_command_buffer(cmd, own_cmd)
end)

commands.Add("lightprobes_dump=number|nil", function(limit)
	lightprobes.Dump(limit)
end)

commands.Add("lightprobes_reflection_probes=boolean[true]", function(enabled)
	lightprobes.SetReflectionProbesEnabled(enabled)
	logf("[lightprobes] reflection probes %s\n", enabled and "enabled" or "disabled")
end)

commands.Add("lightprobes_auto_placement=boolean[true]", function(enabled)
	lightprobes.SetAutoPlacementEnabled(enabled)
	logf("[lightprobes] auto placement %s\n", enabled and "enabled" or "disabled")
end)

commands.Add("lightprobes_spawn=number|nil,string|nil", function(radius, update_mode)
	if update_mode == "" then update_mode = nil end

	local position = render3d.GetRenderCamera():GetPosition()
	local probe, created = lightprobes.EnsureReflectionProbe(position, radius, update_mode or lightprobes.UPDATE_STATIC)
	lightprobes.SetReflectionProbesEnabled(true)
	logf(
		"[lightprobes] %s reflection probe at (%.1f %.1f %.1f) radius %.1f\n",
		created and "spawned" or "reused",
		probe.position.x,
		probe.position.y,
		probe.position.z,
		probe.radius
	)
end)

commands.Add("lightprobes_clear", function()
	lightprobes.ClearReflectionProbes()
	logf("[lightprobes] removed all reflection probes\n")
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

	if index > 0 and not get_reflection_probe(index) then
		logf(
			"[lightprobes] no reflection probe at index %d (have %d)\n",
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

	local marked = lightprobes.MarkAllReflectionProbesDirty(update_mode)
	logf(
		"[lightprobes] marked %d reflection probes dirty%s\n",
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
