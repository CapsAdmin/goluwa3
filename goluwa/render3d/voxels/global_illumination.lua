local ffi = require("ffi")
local commands = import("goluwa/cli/commands.lua")
local system = import("goluwa/system.lua")
local render = import("goluwa/render/render.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local Texture = import("goluwa/render/texture.lua")
local Buffer = import("goluwa/render/vulkan/internal/buffer.lua")
local EasyPipeline = import("goluwa/render/easy_pipeline.lua")
local scene_lights = import("goluwa/render3d/scene_lights.lua")
local directional_shadows = import("goluwa/render3d/directional_shadows.lua")
local light_occlusion = import("goluwa/render3d/light_occlusion.lua")
local scene_bvh = import("goluwa/render3d/scene_bvh.lua")
local ibl = import("goluwa/render3d/ibl.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Quat = import("goluwa/structs/quat.lua")
local voxel_gi = library()
voxel_gi.CASCADE_COUNT = 4
voxel_gi.PROBE_COUNT_X = 24
voxel_gi.PROBE_COUNT_Y = 12
voxel_gi.PROBE_COUNT_Z = 24
voxel_gi.CASCADE_SPACINGS = {1, 2, 4, 8}
voxel_gi.FORWARD_BIAS = 0.3
voxel_gi.RAYS_PER_PROBE = 64
voxel_gi.PROBES_PER_FRAME = 1024
voxel_gi.CASCADE_UPDATE_DIVISORS = {1, 2, 4, 4}
voxel_gi.MAX_TRACE_STEPS = 128
voxel_gi.IRRADIANCE_OCT_SIZE = 8
voxel_gi.VISIBILITY_OCT_SIZE = 16
voxel_gi.HYSTERESIS_TAU = 0.25
voxel_gi.HYSTERESIS_MIN = 0.1
voxel_gi.MAX_PROBE_AGE = 64
voxel_gi.BACKFACE_HYSTERESIS = 0.85
voxel_gi.BACKFACE_DISABLE = 0.25
voxel_gi.BACKFACE_ENABLE = 0.1
voxel_gi.enabled = voxel_gi.enabled ~= false
voxel_gi.occlusion_enabled = voxel_gi.occlusion_enabled ~= false
voxel_gi.OCCLUSION_MAX_STEPS = 24
voxel_gi.visibility_enabled = voxel_gi.visibility_enabled ~= false
voxel_gi.MAX_SAMPLE_CASCADES = voxel_gi.MAX_SAMPLE_CASCADES or voxel_gi.CASCADE_COUNT
voxel_gi.OCCLUSION_MAX_CASCADE = voxel_gi.OCCLUSION_MAX_CASCADE or voxel_gi.CASCADE_COUNT
voxel_gi.OCCLUSION_STEP_VOXELS = voxel_gi.OCCLUSION_STEP_VOXELS or 0.5
voxel_gi.SCREEN_SCALE = voxel_gi.SCREEN_SCALE or 0.5
voxel_gi.BILINEAR_IRRADIANCE = voxel_gi.BILINEAR_IRRADIANCE ~= false
voxel_gi.BILINEAR_VISIBILITY = voxel_gi.BILINEAR_VISIBILITY ~= false
voxel_gi.MIN_PROBE_WEIGHT = voxel_gi.MIN_PROBE_WEIGHT or 0.001
-- trace probe rays against the scene bvh instead of the voxel clipmaps. the
-- clipmaps cannot represent a wall thinner than a voxel of whichever clipmap
-- the cascade starts at, so coarse cascades shoot straight through walls
voxel_gi.BVH_TRACE = voxel_gi.BVH_TRACE ~= false
-- weights below this get pushed toward zero cubically instead of clipped, so a
-- barely-visible probe fades out rather than surviving the renormalization
voxel_gi.WEIGHT_CRUSH = voxel_gi.WEIGHT_CRUSH or 0.2
voxel_gi.MIN_CONFIDENCE = voxel_gi.MIN_CONFIDENCE or 0.25
-- take probes out of the gather while their storage slot holds a cell they no
-- longer represent, instead of letting them serve the previous occupant's
-- irradiance until the round robin gets to them
voxel_gi.SCROLL_INVALIDATE = voxel_gi.SCROLL_INVALIDATE ~= false
-- trace probes that have no history with the unrotated ray set, so their first
-- estimate is smooth across neighbours instead of independently noisy
voxel_gi.STABLE_FIRST_SAMPLE = voxel_gi.STABLE_FIRST_SAMPLE ~= false
-- nudge probes that land inside geometry out to the nearest open spot
voxel_gi.RELOCATE = voxel_gi.RELOCATE ~= false
voxel_gi.cascades = voxel_gi.cascades or {}
voxel_gi.resolved = voxel_gi.resolved or {}
voxel_gi.frame = voxel_gi.frame or 0
local PROBES_PER_CASCADE = voxel_gi.PROBE_COUNT_X * voxel_gi.PROBE_COUNT_Y * voxel_gi.PROBE_COUNT_Z
local MAX_CLIPMAPS = 3
local MAX_CASCADES = 4
local INVALIDATE_LOCAL_SIZE = 64
assert(voxel_gi.CASCADE_COUNT <= MAX_CASCADES, "voxel_gi.CASCADE_COUNT exceeds MAX_CASCADES")
local BINDING_UNIFORM = 0
local BINDING_VOLUME_0 = 1
local BINDING_NORMAL_VOLUME_0 = BINDING_VOLUME_0 + MAX_CLIPMAPS
local BINDING_IRRADIANCE_0 = BINDING_NORMAL_VOLUME_0 + MAX_CLIPMAPS
local BINDING_VISIBILITY_0 = BINDING_IRRADIANCE_0 + MAX_CASCADES
local BINDING_INFO_0 = BINDING_VISIBILITY_0 + MAX_CASCADES
local BINDING_METADATA = BINDING_INFO_0 + MAX_CASCADES
local BINDING_OCCLUSION_MAP = BINDING_METADATA + 1
local BINDING_BVH_NODES = BINDING_OCCLUSION_MAP + 1
local BINDING_BVH_TRIANGLES = BINDING_BVH_NODES + 1

local function get_cascade_probes_per_frame(index)
	return math.min(
		math.max(
			math.floor(voxel_gi.PROBES_PER_FRAME / math.max(voxel_gi.CASCADE_UPDATE_DIVISORS[index] or 1, 1)),
			1
		),
		PROBES_PER_CASCADE
	)
end

local function get_cascade_hysteresis(index)
	local sweep_frames = math.ceil(PROBES_PER_CASCADE / get_cascade_probes_per_frame(index))
	local interval = system.GetFrameTime() * sweep_frames
	local retention = math.exp(-interval / math.max(voxel_gi.HYSTERESIS_TAU, 1e-4))
	return math.clamp(retention, voxel_gi.HYSTERESIS_MIN, 0.99)
end

local function transition_array_to_shader_read(cmd, texture, layer_count, src_stage, src_access, dst_stage)
	render.TransitionResourceFrom(
		texture,
		"shader_read_only_optimal",
		{
			cmd = cmd,
			srcStage = src_stage,
			srcAccess = src_access,
			dstStage = dst_stage or "compute",
			dstAccess = "shader_read",
			base_array_layer = 0,
			layer_count = layer_count,
			base_mip_level = 0,
			level_count = 1,
		}
	)
end

local function create_atlas(width, height, format, name)
	local texture = Texture.New{
		width = width,
		height = height,
		format = format,
		mip_map_levels = 1,
		image = {
			array_layers = 1,
			usage = {"sampled", "storage", "transfer_dst", "transfer_src"},
		},
		view = {
			view_type = "2d",
		},
		sampler = {
			min_filter = "nearest",
			mag_filter = "nearest",
			wrap_s = "clamp_to_edge",
			wrap_t = "clamp_to_edge",
		},
	}
	texture:SetDebugName(name)
	return texture
end

local function clear_and_initialize_textures(textures)
	local cmd = render.GetCommandPool():AllocateCommandBuffer()
	cmd:Begin()

	for _, texture in ipairs(textures) do
		render.TransitionResourceTo(
			texture,
			"transfer_dst_optimal",
			{
				cmd = cmd,
				srcStage = "top_of_pipe",
				srcAccess = "none",
				dstStage = "transfer",
				dstAccess = "transfer_write",
			}
		)
		cmd:ClearColorImage{
			image = texture:GetImage(),
			color = {0, 0, 0, 0},
		}
		render.TransitionResourceFrom(
			texture,
			"shader_read_only_optimal",
			{
				cmd = cmd,
				srcStage = "transfer",
				srcAccess = "transfer_write",
				dstStage = "fragment_shader",
				dstAccess = "shader_read",
			}
		)
	end

	cmd:End()
	render.SubmitAndWait(cmd)
	cmd:Remove()
end

local function remove_texture(texture)
	if texture and texture.Remove then texture:Remove() end
end

function voxel_gi.RemoveResources()
	for _, cascade in pairs(voxel_gi.cascades) do
		remove_texture(cascade.irradiance)
		remove_texture(cascade.visibility)
		remove_texture(cascade.info)
	end

	voxel_gi.cascades = {}

	for _, resolved in pairs(voxel_gi.resolved) do
		if resolved.sample_view and resolved.sample_view.Remove then
			resolved.sample_view:Remove()
		end

		if resolved.normal_sample_view and resolved.normal_sample_view.Remove then
			resolved.normal_sample_view:Remove()
		end

		if resolved.sampler and resolved.sampler.Remove then
			resolved.sampler:Remove()
		end

		remove_texture(resolved.texture)
		remove_texture(resolved.normal_texture)
		remove_texture(resolved.occupancy)
	end

	voxel_gi.resolved = {}

	if voxel_gi.fallback_volume then
		voxel_gi.fallback_volume.sample_view:Remove()
		voxel_gi.fallback_volume.sampler:Remove()
		remove_texture(voxel_gi.fallback_volume.texture)
		voxel_gi.fallback_volume = nil
	end

	if voxel_gi.metadata_buffer then
		voxel_gi.metadata_buffer:Remove()
		voxel_gi.metadata_buffer = nil
	end

	for _, key in ipairs({"resolve_pipeline", "update_pipeline", "invalidate_pipeline"}) do
		if voxel_gi[key] then
			voxel_gi[key]:Remove()
			voxel_gi[key] = nil
		end
	end
end

local function ensure_cascade_resources()
	if voxel_gi.cascades[1] then return end

	local irradiance_size = voxel_gi.IRRADIANCE_OCT_SIZE
	local visibility_size = voxel_gi.VISIBILITY_OCT_SIZE
	local created = {}

	for i = 1, voxel_gi.CASCADE_COUNT do
		local cascade = {
			spacing = voxel_gi.CASCADE_SPACINGS[i] or
				(
					voxel_gi.CASCADE_SPACINGS[#voxel_gi.CASCADE_SPACINGS] * 3 ^ (
						i - #voxel_gi.CASCADE_SPACINGS
					)
				),
			grid_origin = Vec3(0, 0, 0),
			probe_base = 0,
		}
		cascade.irradiance = create_atlas(
			voxel_gi.PROBE_COUNT_X * irradiance_size,
			voxel_gi.PROBE_COUNT_Y * voxel_gi.PROBE_COUNT_Z * irradiance_size,
			"r16g16b16a16_sfloat",
			"voxel gi irradiance " .. i
		)
		cascade.visibility = create_atlas(
			voxel_gi.PROBE_COUNT_X * visibility_size,
			voxel_gi.PROBE_COUNT_Y * voxel_gi.PROBE_COUNT_Z * visibility_size,
			"r16g16_sfloat",
			"voxel gi visibility " .. i
		)
		-- per probe: xyz = relocation offset from the grid position, w = 1
		-- when the probe is enabled
		cascade.info = create_atlas(
			voxel_gi.PROBE_COUNT_X,
			voxel_gi.PROBE_COUNT_Y * voxel_gi.PROBE_COUNT_Z,
			"r16g16b16a16_sfloat",
			"voxel gi probe info " .. i
		)
		created[#created + 1] = cascade.irradiance
		created[#created + 1] = cascade.visibility
		created[#created + 1] = cascade.info
		voxel_gi.cascades[i] = cascade
	end

	clear_and_initialize_textures(created)
	local metadata_size = ffi.sizeof("int32_t") * 4 * PROBES_PER_CASCADE * voxel_gi.CASCADE_COUNT
	voxel_gi.metadata_buffer = Buffer.New{
		device = render.GetDevice(),
		size = metadata_size,
		usage = {"storage_buffer"},
		properties = {"host_visible", "host_coherent"},
		name = "voxel gi probe metadata",
	}
	ffi.fill(voxel_gi.metadata_buffer:Map(), metadata_size, 0)
	voxel_gi.metadata_buffer:Unmap()
end

local function create_volume(resolution, format, name)
	local texture = Texture.New{
		width = resolution,
		height = resolution,
		format = format,
		mip_map_levels = 1,
		image = {
			array_layers = resolution,
			usage = {"sampled", "storage", "transfer_dst", "transfer_src"},
		},
		view = {
			view_type = "2d_array",
			layer_count = resolution,
		},
		sampler = {
			min_filter = "nearest",
			mag_filter = "nearest",
			wrap_s = "clamp_to_edge",
			wrap_t = "clamp_to_edge",
			wrap_r = "clamp_to_edge",
		},
	}
	texture:SetDebugName(name)
	local view = texture:GetImage():CreateView{
		view_type = "2d_array",
		base_array_layer = 0,
		layer_count = resolution,
		base_mip_level = 0,
		level_count = 1,
	}
	return texture, view
end

local function ensure_resolved_volume(clipmap_index, resolution)
	local resolved = voxel_gi.resolved[clipmap_index]

	if resolved and resolved.resolution == resolution then return resolved end

	if resolved then
		if resolved.sample_view then resolved.sample_view:Remove() end

		if resolved.normal_sample_view then resolved.normal_sample_view:Remove() end

		if resolved.sampler then resolved.sampler:Remove() end

		remove_texture(resolved.texture)
		remove_texture(resolved.normal_texture)
		remove_texture(resolved.occupancy)
	end

	local texture, sample_view = create_volume(resolution, "r16g16b16a16_sfloat", "voxel gi resolved volume " .. clipmap_index)
	local normal_texture, normal_sample_view = create_volume(resolution, "r8g8b8a8_unorm", "voxel gi resolved normals " .. clipmap_index)
	-- occupancy flattened into a plain 2d texture (layer z at tile z) so
	-- graphics passes can reach it through the bindless texture array
	local tiles_x = math.ceil(math.sqrt(resolution))
	local tiles_y = math.ceil(resolution / tiles_x)
	local occupancy = create_atlas(
		resolution * tiles_x,
		resolution * tiles_y,
		"r8_unorm",
		"voxel gi occupancy " .. clipmap_index
	)
	resolved = {
		texture = texture,
		normal_texture = normal_texture,
		occupancy = occupancy,
		tiles_x = tiles_x,
		resolution = resolution,
		sample_view = sample_view,
		normal_sample_view = normal_sample_view,
		sampler = render.CreateSampler(texture:GetSamplerConfig()),
		version = -1,
		origin = Vec3(math.huge, math.huge, math.huge),
		valid = false,
	}
	voxel_gi.resolved[clipmap_index] = resolved
	return resolved
end

local function ensure_fallback_volume()
	if voxel_gi.fallback_volume then return voxel_gi.fallback_volume end

	local texture, sample_view = create_volume(1, "r16g16b16a16_sfloat", "voxel gi fallback volume")
	clear_and_initialize_textures({texture})
	voxel_gi.fallback_volume = {
		texture = texture,
		sample_view = sample_view,
		sampler = render.CreateSampler(texture:GetSamplerConfig()),
	}
	return voxel_gi.fallback_volume
end

function voxel_gi.GetMaxClipmapCount()
	return MAX_CLIPMAPS
end

-- the resolved volumes are 2d array views, which the bindless texture array
-- cannot hold, so passes that trace the clipmaps bind them directly
function voxel_gi.GetVolumeDescriptor(index, normals)
	local resolved = voxel_gi.resolved[index]
	local info = voxel_gi.clip_info and voxel_gi.clip_info[index]

	if resolved and info and info.valid then
		return {
			normals and
			resolved.normal_sample_view or
			resolved.sample_view,
			resolved.sampler,
		}
	end

	local fallback = ensure_fallback_volume()
	return {fallback.sample_view, fallback.sampler}
end

function voxel_gi.GetClipmapInfo(index)
	return voxel_gi.clip_info and voxel_gi.clip_info[index]
end

function voxel_gi.GetBlockLayout()
	return {
		{"gi_enabled", "int"},
		{"gi_debug", "int"},
		{"gi_cascade_count", "int"},
		{"gi_probe_counts", "vec4"},
		{"gi_cascade_origin", "vec4", MAX_CASCADES},
		{"gi_irradiance_tex", "int", MAX_CASCADES},
		{"gi_visibility_tex", "int", MAX_CASCADES},
		{"gi_info_tex", "int", MAX_CASCADES},
		{"gi_occlusion", "int"},
		{"gi_clip_origin", "vec4", MAX_CLIPMAPS},
		{"gi_clip_params", "vec4", MAX_CLIPMAPS},
		{"gi_occupancy_tex", "int", MAX_CLIPMAPS},
	}
end

function voxel_gi.IsActive()
	return voxel_gi.enabled and voxel_gi.cascades[1] ~= nil and voxel_gi.has_data == true
end

function voxel_gi.WriteBlock(self, block)
	local active = voxel_gi.IsActive()
	block.gi_enabled = active and 1 or 0
	block.gi_debug = voxel_gi.debug_mode or 0
	block.gi_cascade_count = voxel_gi.CASCADE_COUNT
	block.gi_probe_counts[0] = voxel_gi.PROBE_COUNT_X
	block.gi_probe_counts[1] = voxel_gi.PROBE_COUNT_Y
	block.gi_probe_counts[2] = voxel_gi.PROBE_COUNT_Z
	block.gi_probe_counts[3] = voxel_gi.visibility_enabled and 1 or 0
	block.gi_occlusion = voxel_gi.occlusion_enabled and 1 or 0

	for i = 0, MAX_CLIPMAPS - 1 do
		local info = voxel_gi.clip_info and voxel_gi.clip_info[i + 1]
		local resolved = voxel_gi.resolved[i + 1]

		if active and info and info.valid and resolved and resolved.occupancy then
			block.gi_clip_origin[i][0] = info.origin.x
			block.gi_clip_origin[i][1] = info.origin.y
			block.gi_clip_origin[i][2] = info.origin.z
			block.gi_clip_origin[i][3] = info.voxel_size
			block.gi_clip_params[i][0] = info.resolution
			block.gi_clip_params[i][1] = resolved.tiles_x
			block.gi_clip_params[i][2] = info.world_span * 0.5
			block.gi_clip_params[i][3] = 1
			block.gi_occupancy_tex[i] = self:GetTextureIndex(resolved.occupancy)
		else
			block.gi_clip_origin[i][0] = 0
			block.gi_clip_origin[i][1] = 0
			block.gi_clip_origin[i][2] = 0
			block.gi_clip_origin[i][3] = 1
			block.gi_clip_params[i][0] = 0
			block.gi_clip_params[i][1] = 1
			block.gi_clip_params[i][2] = 0
			block.gi_clip_params[i][3] = 0
			block.gi_occupancy_tex[i] = -1
		end
	end

	-- the grid geometry is always written, the update pass needs it before
	-- the first frame of data exists
	for i = 0, MAX_CASCADES - 1 do
		local cascade = voxel_gi.cascades[i + 1]

		if cascade then
			block.gi_cascade_origin[i][0] = cascade.grid_origin.x
			block.gi_cascade_origin[i][1] = cascade.grid_origin.y
			block.gi_cascade_origin[i][2] = cascade.grid_origin.z
			block.gi_cascade_origin[i][3] = cascade.spacing
		else
			block.gi_cascade_origin[i][0] = 0
			block.gi_cascade_origin[i][1] = 0
			block.gi_cascade_origin[i][2] = 0
			block.gi_cascade_origin[i][3] = 1
		end

		if cascade and active then
			block.gi_irradiance_tex[i] = self:GetTextureIndex(cascade.irradiance)
			block.gi_visibility_tex[i] = self:GetTextureIndex(cascade.visibility)
			block.gi_info_tex[i] = self:GetTextureIndex(cascade.info)
		else
			block.gi_irradiance_tex[i] = -1
			block.gi_visibility_tex[i] = -1
			block.gi_info_tex[i] = -1
		end
	end

	return block
end

local function select_image(fn, ret, image, swizzle)
	local lines = {ret .. " " .. fn .. "(int c, ivec2 texel) {"}

	for i = 0, MAX_CASCADES - 2 do
		lines[#lines + 1] = "\tif (c == " .. i .. ") return imageLoad(" .. image .. "_" .. i .. ", texel)" .. swizzle .. ";"
	end

	lines[#lines + 1] = "\treturn imageLoad(" .. image .. "_" .. (
			MAX_CASCADES - 1
		) .. ", texel)" .. swizzle .. ";"
	lines[#lines + 1] = "}"
	return table.concat(lines, "\n")
end

function voxel_gi.GetGLSLCode(block_name, options)
	options = options or {}
	local fetch

	if options.storage then
		fetch = select_image("voxel_gi_fetch_irradiance", "vec4", "gi_irradiance_image", "") .. "\n" .. select_image("voxel_gi_fetch_visibility", "vec2", "gi_visibility_image", ".xy") .. "\n" .. select_image("voxel_gi_fetch_info", "vec4", "gi_info_image", "") .. [[

			// the update pass has no bindless access, the occlusion march is skipped there
			#define VOXEL_GI_HAS_OCCLUSION 0
			float voxel_gi_fetch_occupancy(int k, ivec2 texel) { return 0.0; }
		]]
	else
		fetch = [[
			vec4 voxel_gi_fetch_irradiance(int c, ivec2 texel) {
				int tex = VOXEL_GI_BLOCK.gi_irradiance_tex[c];
				if (tex < 0) return vec4(0.0);
				return texelFetch(TEXTURE(tex), texel, 0);
			}

			vec2 voxel_gi_fetch_visibility(int c, ivec2 texel) {
				int tex = VOXEL_GI_BLOCK.gi_visibility_tex[c];
				if (tex < 0) return vec2(0.0);
				return texelFetch(TEXTURE(tex), texel, 0).xy;
			}

			vec4 voxel_gi_fetch_info(int c, ivec2 texel) {
				int tex = VOXEL_GI_BLOCK.gi_info_tex[c];
				if (tex < 0) return vec4(0.0);
				return texelFetch(TEXTURE(tex), texel, 0);
			}

			#define VOXEL_GI_HAS_OCCLUSION 1
			float voxel_gi_fetch_occupancy(int k, ivec2 texel) {
				int tex = VOXEL_GI_BLOCK.gi_occupancy_tex[k];
				if (tex < 0) return 0.0;
				return texelFetch(TEXTURE(tex), texel, 0).r;
			}
		]]
	end

	return [[
		#define VOXEL_GI_BLOCK ]] .. block_name .. [[

		const int VOXEL_GI_IRRADIANCE_SIZE = ]] .. voxel_gi.IRRADIANCE_OCT_SIZE .. [[;
		const int VOXEL_GI_VISIBILITY_SIZE = ]] .. voxel_gi.VISIBILITY_OCT_SIZE .. [[;
]] .. "#define VOXEL_GI_BILINEAR_IRRADIANCE " .. (
			not options.storage and
			voxel_gi.BILINEAR_IRRADIANCE and
			1 or
			0
		) .. "\n" .. "#define VOXEL_GI_BILINEAR_VISIBILITY " .. (
			not options.storage and
			voxel_gi.BILINEAR_VISIBILITY and
			1 or
			0
		) .. "\n" .. [[

		vec2 voxel_gi_oct_encode(vec3 n) {
			n /= (abs(n.x) + abs(n.y) + abs(n.z));
			vec2 p = n.xy;
			if (n.z < 0.0) {
				p = (1.0 - abs(n.yx)) * vec2(n.x >= 0.0 ? 1.0 : -1.0, n.y >= 0.0 ? 1.0 : -1.0);
			}
			return p * 0.5 + 0.5;
		}

		vec3 voxel_gi_oct_decode(vec2 uv) {
			vec2 p = uv * 2.0 - 1.0;
			vec3 n = vec3(p.x, p.y, 1.0 - abs(p.x) - abs(p.y));
			if (n.z < 0.0) {
				n.xy = (1.0 - abs(n.yx)) * vec2(p.x >= 0.0 ? 1.0 : -1.0, p.y >= 0.0 ? 1.0 : -1.0);
			}
			return normalize(n);
		}

		const ivec3 VOXEL_GI_PROBE_COUNTS = ivec3(
			]] .. voxel_gi.PROBE_COUNT_X .. [[,
			]] .. voxel_gi.PROBE_COUNT_Y .. [[,
			]] .. voxel_gi.PROBE_COUNT_Z .. [[
		);

		ivec3 voxel_gi_probe_counts() {
			return VOXEL_GI_PROBE_COUNTS;
		}

		ivec3 voxel_gi_grid_origin(int c) {
			return ivec3(floor(VOXEL_GI_BLOCK.gi_cascade_origin[c].xyz + 0.5));
		}

		float voxel_gi_spacing(int c) {
			return VOXEL_GI_BLOCK.gi_cascade_origin[c].w;
		}

		// world grid coordinate -> storage slot (toroidal addressing)
		ivec3 voxel_gi_storage_coord(ivec3 g) {
			ivec3 n = voxel_gi_probe_counts();
			return ((g % n) + n) % n;
		}

		ivec2 voxel_gi_tile_origin(ivec3 s, int tile_size) {
			ivec3 n = voxel_gi_probe_counts();
			return ivec2(s.x, s.y * n.z + s.z) * tile_size;
		}


		// octahedral texel wrap for a coordinate that stepped outside the tile
		ivec2 voxel_gi_wrap_oct_texel(ivec2 t, int size) {
			if (t.x < 0) { t.x = -t.x - 1; t.y = size - 1 - t.y; }
			if (t.x >= size) { t.x = 2 * size - t.x - 1; t.y = size - 1 - t.y; }
			if (t.y < 0) { t.y = -t.y - 1; t.x = size - 1 - t.x; }
			if (t.y >= size) { t.y = 2 * size - t.y - 1; t.x = size - 1 - t.x; }
			return clamp(t, ivec2(0), ivec2(size - 1));
		}

		]] .. fetch .. [[

		// xyz = relocation offset applied to the grid position, w = enabled
		vec4 voxel_gi_probe_info(int c, ivec3 s) {
			return voxel_gi_fetch_info(c, voxel_gi_tile_origin(s, 1));
		}

		vec4 voxel_gi_sample_irradiance(int c, ivec3 s, vec3 dir) {
			ivec2 tile = voxel_gi_tile_origin(s, VOXEL_GI_IRRADIANCE_SIZE);
			vec2 uv = voxel_gi_oct_encode(dir) * float(VOXEL_GI_IRRADIANCE_SIZE) - 0.5;
			ivec2 base = ivec2(floor(uv));
#if VOXEL_GI_BILINEAR_IRRADIANCE
			vec2 f = uv - vec2(base);
			vec4 result = vec4(0.0);

			for (int i = 0; i < 4; i++) {
				ivec2 offset = ivec2(i & 1, i >> 1);
				float w = (offset.x == 0 ? 1.0 - f.x : f.x) * (offset.y == 0 ? 1.0 - f.y : f.y);
				ivec2 texel = voxel_gi_wrap_oct_texel(base + offset, VOXEL_GI_IRRADIANCE_SIZE);
				result += voxel_gi_fetch_irradiance(c, tile + texel) * w;
			}

			return result;
#else
			ivec2 texel = voxel_gi_wrap_oct_texel(ivec2(round(uv)), VOXEL_GI_IRRADIANCE_SIZE);
			return voxel_gi_fetch_irradiance(c, tile + texel);
#endif
		}

		vec2 voxel_gi_sample_visibility(int c, ivec3 s, vec3 dir) {
			ivec2 tile = voxel_gi_tile_origin(s, VOXEL_GI_VISIBILITY_SIZE);
			vec2 uv = voxel_gi_oct_encode(dir) * float(VOXEL_GI_VISIBILITY_SIZE) - 0.5;
			ivec2 base = ivec2(floor(uv));
#if VOXEL_GI_BILINEAR_VISIBILITY
			vec2 f = uv - vec2(base);
			vec2 result = vec2(0.0);

			for (int i = 0; i < 4; i++) {
				ivec2 offset = ivec2(i & 1, i >> 1);
				float w = (offset.x == 0 ? 1.0 - f.x : f.x) * (offset.y == 0 ? 1.0 - f.y : f.y);
				ivec2 texel = voxel_gi_wrap_oct_texel(base + offset, VOXEL_GI_VISIBILITY_SIZE);
				result += voxel_gi_fetch_visibility(c, tile + texel) * w;
			}

			return result;
#else
			ivec2 texel = voxel_gi_wrap_oct_texel(ivec2(round(uv)), VOXEL_GI_VISIBILITY_SIZE);
			return voxel_gi_fetch_visibility(c, tile + texel);
#endif
		}

		const int VOXEL_GI_OCCLUSION_MAX_STEPS = ]] .. voxel_gi.OCCLUSION_MAX_STEPS .. [[;
		const float VOXEL_GI_OCCLUSION_STEP_VOXELS = ]] .. (
			"%.4f"
		):format(voxel_gi.OCCLUSION_STEP_VOXELS) .. [[;
		const int VOXEL_GI_OCCLUSION_MAX_CASCADE = ]] .. voxel_gi.OCCLUSION_MAX_CASCADE .. [[;
		const int VOXEL_GI_MAX_SAMPLE_CASCADES = ]] .. voxel_gi.MAX_SAMPLE_CASCADES .. [[;
		const float VOXEL_GI_MIN_PROBE_WEIGHT = ]] .. (
			"%.6f"
		):format(voxel_gi.MIN_PROBE_WEIGHT) .. [[;
		const float VOXEL_GI_WEIGHT_CRUSH = ]] .. (
			"%.6f"
		):format(voxel_gi.WEIGHT_CRUSH) .. [[;
		// the surviving trilinear weight at which a cascade counts as fully
		// confident. below it the cascade's contribution is faded out, so a
		// point whose probes are all occluded goes dark instead of averaging
		// eight probes that cannot see it
		const float VOXEL_GI_MIN_CONFIDENCE = ]] .. (
			"%.6f"
		):format(voxel_gi.MIN_CONFIDENCE) .. [[;

		bool voxel_gi_clip_contains(int k, vec3 p) {
			vec4 params = VOXEL_GI_BLOCK.gi_clip_params[k];
			if (params.w <= 0.0) return false;
			vec4 origin = VOXEL_GI_BLOCK.gi_clip_origin[k];
			vec3 d = abs(p - origin.xyz);
			float limit = params.z - origin.w;
			return all(lessThan(d, vec3(limit)));
		}

		float voxel_gi_occupancy_at(int k, vec3 p) {
			vec4 origin = VOXEL_GI_BLOCK.gi_clip_origin[k];
			vec4 params = VOXEL_GI_BLOCK.gi_clip_params[k];
			int res = int(params.x + 0.5);
			int tiles_x = int(params.y + 0.5);
			ivec3 v = ivec3(floor((p - origin.xyz) / origin.w + float(res) * 0.5));
			if (any(lessThan(v, ivec3(0))) || any(greaterThanEqual(v, ivec3(res)))) return 0.0;
			ivec2 texel = ivec2((v.z % tiles_x) * res + v.x, (v.z / tiles_x) * res + v.y);
			return voxel_gi_fetch_occupancy(k, texel);
		}

		float voxel_gi_probe_occlusion(vec3 pos, vec3 N, vec3 probe_pos) {
#if VOXEL_GI_HAS_OCCLUSION
			if (VOXEL_GI_BLOCK.gi_occlusion == 0) return 1.0;

			for (int k = 0; k < ]] .. MAX_CLIPMAPS .. [[; k++) {
				if (!voxel_gi_clip_contains(k, pos) || !voxel_gi_clip_contains(k, probe_pos)) continue;

				vec4 origin = VOXEL_GI_BLOCK.gi_clip_origin[k];
				vec4 params = VOXEL_GI_BLOCK.gi_clip_params[k];
				int tex = VOXEL_GI_BLOCK.gi_occupancy_tex[k];
				if (tex < 0) return 1.0;
				int res = int(params.x + 0.5);
				int tiles_x = int(params.y + 0.5);
				float voxel = origin.w;
				float inv_voxel = 1.0 / voxel;
				vec3 grid_base = vec3(res) * 0.5 - origin.xyz * inv_voxel;

				vec3 start = pos + N * voxel;
				vec3 seg = probe_pos - start;
				float len = length(seg);
				float march = len - voxel * 0.5;
				if (march <= 0.0) return 1.0;
				int steps = min(
					int(ceil(march / (voxel * VOXEL_GI_OCCLUSION_STEP_VOXELS))),
					VOXEL_GI_OCCLUSION_MAX_STEPS
				);
				vec3 step = seg / len * (march / float(steps));
				vec3 p = start;

				for (int i = -1; i < steps; i++) {
					ivec3 v = ivec3(floor(p * inv_voxel + grid_base));

					if (all(greaterThanEqual(v, ivec3(0))) && all(lessThan(v, ivec3(res)))) {
						ivec2 texel = ivec2((v.z % tiles_x) * res + v.x, (v.z / tiles_x) * res + v.y);

						if (texelFetch(TEXTURE(tex), texel, 0).r > 0.5) return i < 0 ? 1.0 : 0.0;
					}

					p += step;
				}

				return 1.0;
			}
#endif

			return 1.0;
		}

		float voxel_gi_cascade_fade(int c, vec3 pos) {
			vec3 grid_pos = pos / voxel_gi_spacing(c) - vec3(voxel_gi_grid_origin(c));
			vec3 counts = vec3(voxel_gi_probe_counts());
			vec3 edge = min(grid_pos, counts - 1.0 - grid_pos);
			float e = min(edge.x, min(edge.y, edge.z));
			return clamp(e - 0.5, 0.0, 1.0);
		}

		float voxel_gi_voxel_size_at(vec3 pos, float spacing) {
			for (int k = 0; k < ]] .. MAX_CLIPMAPS .. [[; k++) {
				if (voxel_gi_clip_contains(k, pos)) return VOXEL_GI_BLOCK.gi_clip_origin[k].w;
			}
			return spacing * 0.5;
		}

		vec3 voxel_gi_sample_cascade(int c, vec3 pos, vec3 bias_pos, vec3 N, bool march_occlusion, out float total_weight) {
			float spacing = voxel_gi_spacing(c);
			float vis_slack = 0.5 * voxel_gi_voxel_size_at(pos, spacing);
			ivec3 origin = voxel_gi_grid_origin(c);
			ivec3 counts = voxel_gi_probe_counts();
			vec3 grid_pos = bias_pos / spacing - vec3(origin);
			ivec3 base = ivec3(floor(grid_pos));
			vec3 alpha = clamp(grid_pos - vec3(base), 0.0, 1.0);
			total_weight = 0.0;

			if (any(lessThan(base, ivec3(0))) || any(greaterThanEqual(base + 1, counts))) {
				return vec3(0.0);
			}

			vec3 sum = vec3(0.0);

			for (int i = 0; i < 8; i++) {
				ivec3 offset = ivec3(i & 1, (i >> 1) & 1, (i >> 2) & 1);
				ivec3 g = origin + base + offset;
				ivec3 s = voxel_gi_storage_coord(g);
				vec3 tri = mix(1.0 - alpha, alpha, vec3(offset));
				float w = tri.x * tri.y * tri.z;
				if (w < VOXEL_GI_MIN_PROBE_WEIGHT) continue;
				vec4 info = voxel_gi_probe_info(c, s);
				if (info.w <= 0.0) continue;
				vec3 probe_pos = vec3(g) * spacing + info.xyz;
				w *= info.w;
				vec3 to_probe = normalize(probe_pos - pos);
				float wrap = (dot(to_probe, N) + 1.0) * 0.5;
				w *= wrap * wrap + 0.2;
				if (w < VOXEL_GI_MIN_PROBE_WEIGHT) continue;
				vec3 probe_to_point = bias_pos - probe_pos;
				float dist = length(probe_to_point);
				vec3 dir = probe_to_point / max(dist, 1e-5);
				if (VOXEL_GI_BLOCK.gi_probe_counts.w > 0.5) {
					vec2 vis = voxel_gi_sample_visibility(c, s, dir);
					float mean = vis.x;

					if (dist > mean + vis_slack) {
						float variance = abs(vis.y - mean * mean) + 1e-4;
						float d = dist - mean - vis_slack;
						float cheb = variance / (variance + d * d);
						// no floor here. a floor lets a probe the surface cannot
						// see keep a slice of the weight, and since the result is
						// renormalized by total_weight, eight fully occluded
						// probes still average out to their full radiance -- which
						// is how daylight ends up inside a sealed room
						w *= cheb * cheb * cheb;
					}
				}

				// crush the tail so near-zero contributors fall off smoothly to
				// nothing instead of surviving renormalization
				if (w < VOXEL_GI_WEIGHT_CRUSH) {
					w *= (w * w) / (VOXEL_GI_WEIGHT_CRUSH * VOXEL_GI_WEIGHT_CRUSH);
				}

				if (w < VOXEL_GI_MIN_PROBE_WEIGHT) continue;

				if (march_occlusion) w *= voxel_gi_probe_occlusion(pos, N, probe_pos);

				if (w < VOXEL_GI_MIN_PROBE_WEIGHT) continue;

				vec4 irr = voxel_gi_sample_irradiance(c, s, N);
				sum += irr.rgb * w;
				total_weight += w;
			}

			if (total_weight <= 1e-6) return vec3(0.0);

			return sum / total_weight;
		}

		vec3 sample_voxel_gi_irradiance(vec3 pos, vec3 N, vec3 V, vec3 fallback, out float sky_visibility) {
			vec3 sum = vec3(0.0);
			// how much of the sample is still ungathered, and separately how much
			// of it sits outside every cascade's coverage. they are not the same:
			// a point inside a cascade whose probes are all occluded has no
			// radiance to gather, but it is still indoors, so it must go dark
			// rather than fall back to the sky
			float transmittance = 1.0;
			float coverage_left = 1.0;
			int cascade_count = min(VOXEL_GI_BLOCK.gi_cascade_count, VOXEL_GI_MAX_SAMPLE_CASCADES);

			for (int c = 0; c < cascade_count; c++) {
				float spacing = voxel_gi_spacing(c);
				vec3 bias_pos = pos + (N * 0.6 + V * 0.4) * spacing * 0.25;
				float fade = voxel_gi_cascade_fade(c, bias_pos);
				if (fade <= 0.0) continue;

				coverage_left *= 1.0 - fade;
				float weight;
				vec3 irr = voxel_gi_sample_cascade(
					c,
					pos,
					bias_pos,
					N,
					c < VOXEL_GI_OCCLUSION_MAX_CASCADE,
					weight
				);
				// the finest covering cascade always claims its share, even when
				// its probes are all occluded. letting it hand the sample on to
				// the next, coarser one instead sounds friendlier but is strictly
				// worse: the coarser probes are further away and more likely to
				// be on the other side of the wall, so a room whose own probes
				// correctly see nothing would get filled in from outside
				sum += irr * fade * smoothstep(0.0, VOXEL_GI_MIN_CONFIDENCE, weight) * transmittance;
				transmittance *= 1.0 - fade;

				if (transmittance <= 1e-3) break;
			}

			sky_visibility = coverage_left;
			return sum + fallback * coverage_left;
		}
	]]
end

local function build_update_pipeline()
	local frame_span = math.max(render.GetSwapchainImageCount() or 1, 1)
	local declarations = {}

	for i = 0, MAX_CLIPMAPS - 1 do
		declarations[#declarations + 1] = "layout(set = 0, binding = " .. (
				BINDING_VOLUME_0 + i
			) .. ") uniform sampler2DArray gi_voxel_volume_" .. i .. ";"
		declarations[#declarations + 1] = "layout(set = 0, binding = " .. (
				BINDING_NORMAL_VOLUME_0 + i
			) .. ") uniform sampler2DArray gi_voxel_normal_" .. i .. ";"
	end

	for i = 0, MAX_CASCADES - 1 do
		declarations[#declarations + 1] = "layout(set = 0, binding = " .. (
				BINDING_IRRADIANCE_0 + i
			) .. ", rgba16f) uniform image2D gi_irradiance_image_" .. i .. ";"
		declarations[#declarations + 1] = "layout(set = 0, binding = " .. (
				BINDING_VISIBILITY_0 + i
			) .. ", rg16f) uniform image2D gi_visibility_image_" .. i .. ";"
		declarations[#declarations + 1] = "layout(set = 0, binding = " .. (
				BINDING_INFO_0 + i
			) .. ", rgba16f) uniform image2D gi_info_image_" .. i .. ";"
	end

	declarations[#declarations + 1] = "layout(std430, set = 0, binding = " .. BINDING_METADATA .. ") buffer GIProbeMetadata { ivec4 gi_probe_meta[]; };"
	declarations[#declarations + 1] = light_occlusion.GetDeclarationGLSL(BINDING_OCCLUSION_MAP)
	declarations[#declarations + 1] = scene_bvh.GetDeclarationsGLSL(BINDING_BVH_NODES, BINDING_BVH_TRIANGLES)

	-- per cascade image selection for stores
	for _, entry in ipairs{
		{"voxel_gi_store_irradiance", "gi_irradiance_image"},
		{"voxel_gi_store_visibility", "gi_visibility_image"},
		{"voxel_gi_store_info", "gi_info_image"},
	} do
		declarations[#declarations + 1] = "void " .. entry[1] .. "(int c, ivec2 coord, vec4 value) {"

		for i = 0, MAX_CASCADES - 1 do
			declarations[#declarations + 1] = "\tif (c == " .. i .. ") { imageStore(" .. entry[2] .. "_" .. i .. ", coord, value); return; }"
		end

		declarations[#declarations + 1] = "}"
	end

	declarations = table.concat(declarations, "\n")
	local descriptor_sets = {}

	for i = 0, MAX_CLIPMAPS - 1 do
		descriptor_sets[#descriptor_sets + 1] = {
			type = "combined_image_sampler",
			binding_index = BINDING_VOLUME_0 + i,
			stageFlags = "compute",
			set_index = 0,
		}
		descriptor_sets[#descriptor_sets + 1] = {
			type = "combined_image_sampler",
			binding_index = BINDING_NORMAL_VOLUME_0 + i,
			stageFlags = "compute",
			set_index = 0,
		}
	end

	for i = 0, MAX_CASCADES - 1 do
		descriptor_sets[#descriptor_sets + 1] = {
			type = "storage_image",
			binding_index = BINDING_IRRADIANCE_0 + i,
			stageFlags = "compute",
			set_index = 0,
		}
		descriptor_sets[#descriptor_sets + 1] = {
			type = "storage_image",
			binding_index = BINDING_VISIBILITY_0 + i,
			stageFlags = "compute",
			set_index = 0,
		}
		descriptor_sets[#descriptor_sets + 1] = {
			type = "storage_image",
			binding_index = BINDING_INFO_0 + i,
			stageFlags = "compute",
			set_index = 0,
		}
	end

	descriptor_sets[#descriptor_sets + 1] = {
		type = "storage_buffer",
		binding_index = BINDING_METADATA,
		stageFlags = "compute",
		set_index = 0,
	}
	descriptor_sets[#descriptor_sets + 1] = {
		type = "storage_buffer",
		binding_index = BINDING_BVH_NODES,
		stageFlags = "compute",
		set_index = 0,
	}
	descriptor_sets[#descriptor_sets + 1] = {
		type = "storage_buffer",
		binding_index = BINDING_BVH_TRIANGLES,
		stageFlags = "compute",
		set_index = 0,
	}
	return EasyPipeline.Compute{
		name = "voxel_gi_update",
		DescriptorSetCount = frame_span * voxel_gi.CASCADE_COUNT,
		LocalSize = {x = voxel_gi.RAYS_PER_PROBE, y = 1, z = 1},
		descriptor_sets = descriptor_sets,
		block = {
			{"cascade", "int"},
			{"probe_base", "int"},
			{"min_clipmap", "int"},
			{"hysteresis", "float"},
			{"bvh_ready", "int"},
			{"stable_first_sample", "int"},
			{"relocate_enabled", "int"},
			write = function(self, block)
				block.cascade = voxel_gi.current_cascade - 1
				block.probe_base = voxel_gi.cascades[voxel_gi.current_cascade].probe_base
				block.min_clipmap = math.min(voxel_gi.current_cascade, voxel_gi.clipmap_count or 1) - 1
				block.hysteresis = get_cascade_hysteresis(voxel_gi.current_cascade)
				block.bvh_ready = (voxel_gi.BVH_TRACE and scene_bvh.IsReady()) and 1 or 0
				block.stable_first_sample = voxel_gi.STABLE_FIRST_SAMPLE and 1 or 0
				block.relocate_enabled = voxel_gi.RELOCATE and 1 or 0
				return block
			end,
		},
		sampled_images = {
			{
				binding_index = BINDING_OCCLUSION_MAP,
				get_texture = function()
					return light_occlusion.GetOcclusionTexture()
				end,
			},
		},
		uniform_buffers = {
			{
				name = "gi_data",
				binding_index = BINDING_UNIFORM,
				block = {
					render3d.camera_block,
					{"lights", scene_lights.BuildLightsBlockLayout(), scene_lights.MAX_LIGHTS},
					{"light_count", "int"},
					{"shadows", scene_lights.BuildShadowsBlockLayout()},
					light_occlusion.GetBlockLayout(),
					{"sun_direction", "vec4"},
					{"sun_radiance", "vec4"},
					{"ray_rotation", "mat4"},
					{"env_tex", "int"},
					{"env_irradiance_tex", "int"},
					{"max_steps", "int"},
					{"clipmap_count", "int"},
					{"clip_origin", "vec4", MAX_CLIPMAPS},
					{"clip_params", "vec4", MAX_CLIPMAPS},
					voxel_gi.GetBlockLayout(),
				},
				write = function(self, block)
					render3d.WriteCameraBlock(self, block)
					local lights, light_instance_indices = scene_lights.GetVisibleLights()
					block.light_count = math.min(#lights, scene_lights.MAX_LIGHTS)
					scene_lights.WriteLightsBlock(block.lights, lights)
					scene_lights.WriteShadowBlock(self, block.shadows, lights)
					light_occlusion.WriteOcclusionBlock(block, lights, light_instance_indices)
					local sun_dir = directional_shadows.GetPrimarySunDirection(lights)
					local sun_color = directional_shadows.GetPrimarySunColor(lights)
					local sun_illuminance = directional_shadows.GetPrimarySunIlluminance(lights)
					sun_dir:CopyToFloatPointer(block.sun_direction)
					block.sun_direction[3] = 0
					block.sun_radiance[0] = sun_color.x * sun_illuminance
					block.sun_radiance[1] = sun_color.y * sun_illuminance
					block.sun_radiance[2] = sun_color.z * sun_illuminance
					block.sun_radiance[3] = 0
					voxel_gi.ray_rotation:CopyToFloatPointer(block.ray_rotation)
					block.env_tex = self:GetTextureIndex(render3d.GetEnvironmentTexture())
					block.env_irradiance_tex = self:GetTextureIndex(render3d.GetEnvironmentIrradianceTexture())
					block.max_steps = voxel_gi.MAX_TRACE_STEPS
					block.clipmap_count = voxel_gi.clipmap_count or 0

					for i = 0, MAX_CLIPMAPS - 1 do
						local info = voxel_gi.clip_info and voxel_gi.clip_info[i + 1]

						if info and info.valid then
							block.clip_origin[i][0] = info.origin.x
							block.clip_origin[i][1] = info.origin.y
							block.clip_origin[i][2] = info.origin.z
							block.clip_origin[i][3] = info.voxel_size
							block.clip_params[i][0] = info.world_span
							block.clip_params[i][1] = info.resolution
							block.clip_params[i][2] = 1
							block.clip_params[i][3] = 0
						else
							block.clip_origin[i][0] = 0
							block.clip_origin[i][1] = 0
							block.clip_origin[i][2] = 0
							block.clip_origin[i][3] = 1
							block.clip_params[i][0] = 0
							block.clip_params[i][1] = 0
							block.clip_params[i][2] = 0
							block.clip_params[i][3] = 0
						end
					end

					-- the sampling code reads the atlases through storage
					-- images here, the bindless indices are unused
					voxel_gi.WriteBlock(self, block)
					block.gi_enabled = 1
					return block
				end,
			},
		},
		custom_declarations = declarations,
		shader = [[
			]] .. ibl.GetBRDFGLSLCode() .. ibl.GetEnvironmentGLSLCode() .. [[
			]] .. voxel_gi.GetGLSLCode("gi_data", {storage = true}) .. [[
			]] .. directional_shadows.GetSurfaceDirectionalShadowGLSL("gi_data", "calculateShadow") .. [[

			]] .. scene_lights.GetLightGLSLCode() .. [[
			]] .. directional_shadows.GetLocalDirectionalShadowGLSL("gi_data") .. [[
			]] .. scene_lights.GetPointShadowGLSL("gi_data") .. [[
			]] .. light_occlusion.GetSamplingGLSL("gi_data") .. [[
			]] .. scene_bvh.GetTraversalGLSL() .. [[

			const int PROBES_PER_CASCADE = ]] .. PROBES_PER_CASCADE .. [[;
			const int RAYS_PER_PROBE = ]] .. voxel_gi.RAYS_PER_PROBE .. [[;
			const float BACKFACE_HYSTERESIS = ]] .. (
				"%.4f"
			):format(voxel_gi.BACKFACE_HYSTERESIS) .. [[;
			const float BACKFACE_DISABLE = ]] .. (
				"%.4f"
			):format(voxel_gi.BACKFACE_DISABLE) .. [[;
			const float BACKFACE_ENABLE = ]] .. (
				"%.4f"
			):format(voxel_gi.BACKFACE_ENABLE) .. [[;
			const int MAX_PROBE_AGE = ]] .. voxel_gi.MAX_PROBE_AGE .. [[;

			shared vec4 s_ray[RAYS_PER_PROBE];
			shared vec3 s_dir[RAYS_PER_PROBE];
			shared float s_vis_dist[RAYS_PER_PROBE];
			shared vec4 s_relocate[RAYS_PER_PROBE];
			shared vec4 s_relocation;

			vec3 clip_origin(int c) { return gi_data.clip_origin[c].xyz; }
			float clip_voxel_size(int c) { return gi_data.clip_origin[c].w; }
			float clip_span(int c) { return gi_data.clip_params[c].x; }
			int clip_resolution(int c) { return int(gi_data.clip_params[c].y + 0.5); }
			bool clip_valid(int c) { return c >= 0 && c < gi_data.clipmap_count && gi_data.clip_params[c].z > 0.5; }

			bool clip_contains(int c, vec3 p) {
				if (!clip_valid(c)) return false;
				vec3 d = abs(p - clip_origin(c));
				float half_span = clip_span(c) * 0.5 - clip_voxel_size(c) * 0.01;
				return all(lessThan(d, vec3(half_span)));
			}

			int find_clipmap(vec3 p, int min_clip) {
				for (int c = max(min_clip, 0); c < gi_data.clipmap_count; c++) {
					if (clip_contains(c, p)) return c;
				}
				return -1;
			}

			vec4 fetch_voxel(int c, ivec3 v) {
				if (c == 0) return texelFetch(gi_voxel_volume_0, v, 0);
				if (c == 1) return texelFetch(gi_voxel_volume_1, v, 0);
				return texelFetch(gi_voxel_volume_2, v, 0);
			}

			vec3 fetch_voxel_normal(int c, ivec3 v) {
				vec3 n;
				if (c == 0) n = texelFetch(gi_voxel_normal_0, v, 0).xyz;
				else if (c == 1) n = texelFetch(gi_voxel_normal_1, v, 0).xyz;
				else n = texelFetch(gi_voxel_normal_2, v, 0).xyz;
				n = n * 2.0 - 1.0;
				float len = length(n);
				return len > 1e-3 ? n / len : vec3(0.0);
			}

			bool voxel_solid(int c, ivec3 v) {
				return fetch_voxel(c, v).a >= 0.5;
			}

			bool point_solid(vec3 p) {
				int c = find_clipmap(p, 0);
				if (c < 0) return false;
				vec3 min_corner = clip_origin(c) - vec3(clip_span(c) * 0.5);
				ivec3 v = ivec3(floor((p - min_corner) / clip_voxel_size(c)));
				return voxel_solid(c, v);
			}

			vec4 relocate_probe(vec3 probe_pos, float spacing) {
				int ray = int(gl_LocalInvocationID.x);
				int c = find_clipmap(probe_pos, 0);
				bool solid = c >= 0 && point_solid(probe_pos);

				// with relocation off a probe stuck in a wall stays there and
				// gets switched off by the backface count instead, which is the
				// cheapest way to tell whether relocation is what is moving
				if (!solid || compute.relocate_enabled == 0) {
					return vec4(0.0, 0.0, 0.0, 1.0);
				}

				// The candidate offsets are probe relative and keyed off the
				// cascade spacing, never off the clipmap lattice.
				//
				// Anchoring the search to the clipmap made a world static
				// question -- where is the nearest open spot next to this probe
				// -- depend on where the viewer happens to be standing, because
				// clipmap origins snap to the camera. Every re-snap moved every
				// candidate by up to a voxel, so a probe embedded in a wall
				// would hop to the far side, carry the room's own light out into
				// the world with it, and hop back at the next snap. Slow
				// movement separates those events and they read as periodic
				// flashing. Selecting the clipmap per candidate rather than once
				// for the probe removes the other half of it: a probe drifting
				// across a clipmap boundary no longer resizes its whole search.
				float step_size = spacing * 0.375;
				float max_reach = spacing * 0.75;
				vec4 best = vec4(0.0, 0.0, 0.0, 1e9);

				for (int k = ray; k < 125; k += RAYS_PER_PROBE) {
					ivec3 o = ivec3(k % 5, (k / 5) % 5, k / 25) - ivec3(2);
					if (all(equal(o, ivec3(0)))) continue;
					vec3 offset = vec3(o) * step_size;
					float d = length(offset);
					if (d > max_reach || d >= best.w) continue;
					vec3 candidate = probe_pos + offset;
					int cc = find_clipmap(candidate, 0);
					// no voxel data there: leave the probe alone rather than
					// relocate it into a region nothing has been voxelized into
					if (cc < 0) continue;
					vec3 cmin = clip_origin(cc) - vec3(clip_span(cc) * 0.5);
					ivec3 v = ivec3(floor((candidate - cmin) / clip_voxel_size(cc)));
					if (any(lessThan(v, ivec3(0))) || any(greaterThanEqual(v, ivec3(clip_resolution(cc))))) continue;
					if (voxel_solid(cc, v)) continue;
					best = vec4(offset, d);
				}

				s_relocate[ray] = best;
				barrier();

				if (ray == 0) {
					vec4 chosen = s_relocate[0];

					for (int i = 1; i < RAYS_PER_PROBE; i++) {
						if (s_relocate[i].w < chosen.w) chosen = s_relocate[i];
					}

					s_relocation = chosen.w < 1e8 ? vec4(chosen.xyz, 1.0) : vec4(0.0);
				}

				barrier();
				return s_relocation;
			}

			bool trace_voxels(vec3 origin, vec3 dir, int min_clip, out vec3 hit_pos, out vec3 hit_normal, out vec4 hit_voxel, out float hit_dist, out bool backface) {
				int c = find_clipmap(origin, min_clip);
				backface = false;
				vec3 safe_dir = mix(dir, vec3(1e-5), lessThan(abs(dir), vec3(1e-5)));
				vec3 inv_dir = 1.0 / safe_dir;
				vec3 dir_sign = mix(vec3(-1.0), vec3(1.0), greaterThanEqual(dir, vec3(0.0)));
				float t = 0.0;
				vec3 normal = -dir;
				hit_pos = origin;
				hit_normal = normal;
				hit_voxel = vec4(0.0);
				hit_dist = 0.0;

				for (int step = 0; step < gi_data.max_steps; step++) {
					if (c < 0) return false;
					vec3 pos = origin + dir * t;
					float vs = clip_voxel_size(c);
					int res = clip_resolution(c);
					vec3 min_corner = clip_origin(c) - vec3(clip_span(c) * 0.5);
					vec3 local_pos = (pos - min_corner) / vs;
					ivec3 v = ivec3(floor(local_pos));

					if (any(lessThan(v, ivec3(0))) || any(greaterThanEqual(v, ivec3(res)))) {
						c = find_clipmap(pos, c + 1);
						continue;
					}

					vec4 voxel = fetch_voxel(c, v);

					if (voxel.a >= 0.5) {
						hit_pos = pos;
						hit_voxel = voxel;
						vec3 hit_cell_min = min_corner + vec3(v) * vs;
						vec3 hit_boundary = hit_cell_min + mix(vec3(0.0), vec3(vs), greaterThanEqual(dir, vec3(0.0)));
						vec3 hit_tt = max((hit_boundary - pos) * inv_dir, vec3(0.0));
						hit_dist = t + 0.5 * min(hit_tt.x, min(hit_tt.y, hit_tt.z));
						vec3 stored = fetch_voxel_normal(c, v);
						bool has_stored = dot(stored, stored) > 0.5;
						float facing = has_stored ? dot(stored, dir) : -1.0;
						backface = facing > 0.3;
						hit_normal = has_stored && facing <= 0.0 ? stored : normal;
						return true;
					}

					vec3 cell_min = min_corner + vec3(v) * vs;
					vec3 boundary = cell_min + mix(vec3(0.0), vec3(vs), greaterThanEqual(dir, vec3(0.0)));
					vec3 tt = (boundary - pos) * inv_dir;
					tt = max(tt, vec3(0.0));
					float t_step = min(tt.x, min(tt.y, tt.z));
					int axis = tt.x <= tt.y && tt.x <= tt.z ? 0 : (tt.y <= tt.z ? 1 : 2);
					normal = vec3(0.0);
					normal[axis] = -dir_sign[axis];
					t += t_step + vs * 1e-3;
				}

				return false;
			}

			vec3 fibonacci_direction(int i, int n) {
				float phi = 2.399963229728653 * float(i);
				float z = 1.0 - (2.0 * float(i) + 1.0) / float(n);
				float r = sqrt(max(1.0 - z * z, 0.0));
				return vec3(r * cos(phi), r * sin(phi), z);
			}

			float luminance(vec3 c) {
				return dot(c, vec3(0.2126, 0.7152, 0.0722));
			}

			// the bvh gives exact geometry but carries no material, so the
			// clipmap volumes still supply albedo and emissive at the hit
			vec4 sample_surface_voxel(vec3 p, vec3 n) {
				for (int c = 0; c < gi_data.clipmap_count; c++) {
					if (!clip_contains(c, p)) continue;

					float vs = clip_voxel_size(c);
					vec3 min_corner = clip_origin(c) - vec3(clip_span(c) * 0.5);
					ivec3 v = ivec3(floor((p - n * (vs * 0.5) - min_corner) / vs));

					if (any(lessThan(v, ivec3(0))) || any(greaterThanEqual(v, ivec3(clip_resolution(c))))) {
						continue;
					}

					vec4 voxel = fetch_voxel(c, v);

					if (voxel.a >= 0.5) return voxel;
				}

				return vec4(0.5, 0.5, 0.5, 1.0);
			}

			// One probe ray.
			//
			// The voxel dda cannot see a wall thinner than a voxel of whichever
			// clipmap the cascade is told to start at, and the coarse cascades
			// start coarse. A ray that passes through a wall poisons the probe
			// twice over: its radiance becomes whatever is outside (usually the
			// sky), and its visibility moments record "nothing in that
			// direction", so the Chebyshev test downstream cannot gate the bad
			// radiance away either. Tracing the bvh instead is exact at every
			// cascade, which is what keeps a sealed room sealed.
			bool trace_probe_ray(
				vec3 origin,
				vec3 dir,
				float t_max,
				out vec3 hit_pos,
				out vec3 hit_normal,
				out vec4 hit_voxel,
				out float hit_dist,
				out bool backface
			) {
				if (compute.bvh_ready == 0) {
					return trace_voxels(origin, dir, compute.min_clipmap, hit_pos, hit_normal, hit_voxel, hit_dist, backface);
				}

				scene_bvh_hit traced;
				backface = false;

				if (!scene_bvh_trace(origin, dir, 0.0, t_max, traced)) return false;

				hit_pos = traced.position;
				hit_normal = traced.normal;
				hit_dist = traced.distance;
				vec4 voxel = sample_surface_voxel(traced.position, traced.normal);
				vec3 emissive = clamp(voxel.rgb * traced.emissive, vec3(0.0), vec3(1.0));
				hit_voxel = vec4(voxel.rgb, 1.0 + luminance(emissive));
				// scene_bvh_trace flips the normal toward the ray, so the stored
				// voxel normal is what tells us we hit the inside of a surface --
				// the signal the probe uses to switch itself off
				int c = find_clipmap(traced.position, 0);

				if (c >= 0) {
					float vs = clip_voxel_size(c);
					vec3 min_corner = clip_origin(c) - vec3(clip_span(c) * 0.5);
					ivec3 v = ivec3(floor((traced.position - min_corner) / vs));

					if (
						all(greaterThanEqual(v, ivec3(0))) &&
						all(lessThan(v, ivec3(clip_resolution(c))))
					) {
						vec3 stored = fetch_voxel_normal(c, v);

						if (dot(stored, stored) > 0.5 && dot(stored, dir) > 0.3) backface = true;
					}
				}

				return true;
			}

			vec3 shade_hit(vec3 hit_pos, vec3 N, vec4 voxel, int c) {
				// Offset off the surface before the shadow and light lookups.
				// Half a voxel is up to 0.66m at the coarse clipmaps, which pushes
				// the shading point clean through any wall thinner than that and
				// shades the *outside* of the room -- in full sunlight. Only the
				// voxel trace needs an offset that large, because only it
				// quantises the hit to a voxel; the bvh hit is exact.
				float vs = clip_voxel_size(max(c, 0));
				vec3 surface_pos = hit_pos + N * (compute.bvh_ready != 0 ? 0.02 : vs * 0.5);
				vec3 L = normalize(gi_data.sun_direction.xyz);
				float NoL = max(dot(N, L), 0.0);
				float shadow = gi_data.shadows.shadow_map_indices[0] >= 0 ? 1.0 : 0.0;

				if (NoL > 0.0 && gi_data.shadows.shadow_map_indices[0] >= 0) {
					shadow = calculateShadow(surface_pos, N, L);
				}


				vec3 albedo = voxel.rgb;
				vec3 direct = gi_data.sun_radiance.rgb * (NoL * shadow / 3.14159265359);

				for (int i = 0; i < gi_data.light_count; i++) {
					lights_t light = gi_data.lights[i];
					int light_type = get_light_type(light);

					if (light_type == 0) continue;

					vec3 light_to_surface;
					float light_attenuation;

					if (!get_light_vector_and_attenuation(light, surface_pos, light_to_surface, light_attenuation)) {
						continue;
					}

					float light_NoL = max(dot(N, light_to_surface), 0.0);

					if (light_NoL <= 0.0) continue;

					float light_shadow = 1.0;

					if (light_type == 2) {
						if (
							i == gi_data.shadows.local_directional_shadow_light_index &&
							gi_data.shadows.local_directional_shadow_map_index >= 0
						) {
							light_shadow = calculateLocalDirectionalShadow(surface_pos, N, light_to_surface);
						}
					} else {
						int point_shadow_slot = getPointShadowSlot(i);

						if (point_shadow_slot >= 0) {
							light_shadow = calculatePointShadow(point_shadow_slot, surface_pos, N, light_to_surface);
						}

						light_shadow *= light_oct_shadow_factor(
							gi_data.bvh_oct_slot[i],
							light.position.xyz,
							light.params.x,
							surface_pos
						);
					}

					if (light_shadow > 0.0) {
						direct += light.color.rgb * light.color.a * light_attenuation * light_shadow *
							(light_NoL / 3.14159265359);
					}
				}

				vec3 sky = sample_environment_irradiance(gi_data.env_irradiance_tex, N);
				float unused_sky_visibility;
				vec3 bounce = sample_voxel_gi_irradiance(surface_pos, N, N, sky, unused_sky_visibility);
				float emissive_luma = max(voxel.a - 1.0, 0.0) * 4.0;
				float lit_scale = clamp((luminance(albedo) - emissive_luma) / max(luminance(albedo), 1e-3), 0.0, 1.0);
				return albedo * lit_scale * (direct + bounce) + albedo * (1.0 - lit_scale);
			}

			void main() {
				int c = compute.cascade;
				ivec3 counts = voxel_gi_probe_counts();
				int slot = (compute.probe_base + int(gl_WorkGroupID.x)) % PROBES_PER_CASCADE;
				ivec3 s = ivec3(slot % counts.x, slot / (counts.x * counts.z), (slot / counts.x) % counts.z);
				ivec3 origin = voxel_gi_grid_origin(c);
				ivec3 g = origin + ((s - origin) % counts + counts) % counts;
				float spacing = voxel_gi_spacing(c);
				vec3 probe_pos = vec3(g) * spacing;
				int meta_index = c * PROBES_PER_CASCADE + slot;
				ivec4 meta = gi_probe_meta[meta_index];
				bool history_valid = meta.xyz == g && meta.w != 0;
				int age = history_valid ? meta.w : 0;
				float hysteresis = min(compute.hysteresis, float(age) / float(age + 1));
				int ray = int(gl_LocalInvocationID.x);

				vec4 relocation = relocate_probe(probe_pos, spacing);
				vec3 ray_origin = probe_pos + relocation.xyz;
				bool enabled = relocation.w > 0.0;

				// The ray set is randomly rotated every frame, which trades bias
				// for noise and relies on the hysteresis blend to average the
				// noise away. A probe with no history has no blend to average
				// into: hysteresis is 0 at age 0, so it takes a single 64 ray
				// estimate, and each neighbour takes an independently rotated
				// one, so a freshly scrolled slab of probes lands as noise
				// rather than as a smooth field. Worse, the next refinement is a
				// whole round robin sweep away -- 7 frames at cascade 0, 27 at
				// the coarse ones -- so it boils for a third of a second.
				//
				// Dropping back to the unrotated Fibonacci set for those probes
				// gives a biased but deterministic estimate, and the bias is the
				// same for every probe, so the slab reads as smooth. Once there
				// is history to average into, the rotation earns its keep again.
				vec3 base_dir = fibonacci_direction(ray, RAYS_PER_PROBE);
				vec3 dir = (compute.stable_first_sample != 0 && !history_valid) ?
					normalize(base_dir) :
					normalize((gi_data.ray_rotation * vec4(base_dir, 0.0)).xyz);
				vec3 radiance = vec3(0.0);
				float dist = spacing * 4.0;

				if (enabled) {
					vec3 hit_pos;
					vec3 hit_normal;
					vec4 hit_voxel;
					float hit_dist;
					bool backface;

					if (trace_probe_ray(ray_origin, dir, max(spacing * 32.0, 32.0), hit_pos, hit_normal, hit_voxel, hit_dist, backface)) {
						if (backface) {
							dist = -max(hit_dist, 1e-4);
						} else {
							radiance = shade_hit(hit_pos, hit_normal, hit_voxel, find_clipmap(hit_pos, compute.min_clipmap));
							dist = hit_dist;
						}
					} else {
						radiance = textureLod(TEXTURE(gi_data.env_tex), dir_to_equirect_uv(correct_environment_lookup_dir(dir)), 1.0).rgb;
						dist = 1e6;
					}
				}

				radiance = clamp(radiance, vec3(0.0), vec3(65504.0));
				float max_dist = spacing * 1.5;
				s_ray[ray] = vec4(radiance, dist);
				s_dir[ray] = dir;
				s_vis_dist[ray] = dist < 0.0 ? min(-dist * 0.2, max_dist) : min(dist, max_dist);
				barrier();

				ivec2 tile = voxel_gi_tile_origin(s, VOXEL_GI_IRRADIANCE_SIZE);
				int irr_texel_count = VOXEL_GI_IRRADIANCE_SIZE * VOXEL_GI_IRRADIANCE_SIZE;

				for (int k = ray; k < irr_texel_count; k += RAYS_PER_PROBE) {
					ivec2 texel = ivec2(k % VOXEL_GI_IRRADIANCE_SIZE, k / VOXEL_GI_IRRADIANCE_SIZE);
					vec3 texel_dir = voxel_gi_oct_decode((vec2(texel) + 0.5) / float(VOXEL_GI_IRRADIANCE_SIZE));
					vec3 sum = vec3(0.0);
					float weight_sum = 0.0;

					for (int r = 0; r < RAYS_PER_PROBE; r++) {
						if (s_ray[r].a < 0.0) continue;

						float w = max(dot(texel_dir, s_dir[r]), 0.0);
						sum += s_ray[r].rgb * w;
						weight_sum += w;
					}

					vec3 result = weight_sum > 0.0 ? sum / weight_sum : vec3(0.0);
					ivec2 coord = tile + texel;
					vec4 previous = voxel_gi_fetch_irradiance(c, coord);

					if (history_valid && previous.a > 0.0) {
						result = mix(result, previous.rgb, hysteresis);
					}

					voxel_gi_store_irradiance(c, coord, vec4(result, enabled ? 1.0 : 0.0));
				}

				ivec2 vis_tile = voxel_gi_tile_origin(s, VOXEL_GI_VISIBILITY_SIZE);
				int vis_texel_count = VOXEL_GI_VISIBILITY_SIZE * VOXEL_GI_VISIBILITY_SIZE;

				for (int k = ray; k < vis_texel_count; k += RAYS_PER_PROBE) {
					ivec2 vt = ivec2(k % VOXEL_GI_VISIBILITY_SIZE, k / VOXEL_GI_VISIBILITY_SIZE);
					vec3 vdir = voxel_gi_oct_decode((vec2(vt) + 0.5) / float(VOXEL_GI_VISIBILITY_SIZE));
					float m = 0.0;
					float m2 = 0.0;
					float wsum = 0.0;

					for (int r = 0; r < RAYS_PER_PROBE; r++) {
						float w = max(dot(vdir, s_dir[r]), 0.0);
						float w2 = w * w;
						float w4 = w2 * w2;
						float w8 = w4 * w4;
						float w16 = w8 * w8;
						w = w16 * w16 * w16 * w2;
						float d = s_vis_dist[r];
						m += d * w;
						m2 += d * d * w;
						wsum += w;
					}

					vec2 vis = wsum > 0.0 ? vec2(m, m2) / wsum : vec2(max_dist, max_dist * max_dist);
					ivec2 vcoord = vis_tile + vt;

					if (history_valid) {
						vis = mix(vis, voxel_gi_fetch_visibility(c, vcoord), hysteresis);
					}

					voxel_gi_store_visibility(c, vcoord, vec4(vis, 0.0, 0.0));
				}

				if (ray == 0) {
					gi_probe_meta[meta_index] = ivec4(g, min(age + 1, MAX_PROBE_AGE));
					int backface_count = 0;

					for (int r = 0; r < RAYS_PER_PROBE; r++) {
						if (s_ray[r].a < 0.0) backface_count++;
					}

					ivec2 info_coord = voxel_gi_tile_origin(s, 1);
					float validity = clamp(
						(BACKFACE_DISABLE - float(backface_count) / float(RAYS_PER_PROBE)) /
						(BACKFACE_DISABLE - BACKFACE_ENABLE),
						0.0,
						1.0
					);

					if (history_valid) {
						validity = mix(validity, voxel_gi_fetch_info(c, info_coord).w, min(BACKFACE_HYSTERESIS, float(age) / float(age + 1)));
					}

					if (!enabled) validity = 0.0;

					voxel_gi_store_info(c, info_coord, vec4(relocation.xyz, validity));
				}
			}
		]],
	}
end

local function build_resolve_pipeline()
	local frame_span = math.max(render.GetSwapchainImageCount() or 1, 1)
	return EasyPipeline.Compute{
		name = "voxel_gi_resolve",
		DescriptorSetCount = frame_span * MAX_CLIPMAPS,
		LocalSize = {x = 4, y = 4, z = 4},
		descriptor_sets = {
			{
				type = "storage_image",
				binding_index = 0,
				stageFlags = "compute",
				set_index = 0,
			},
			{
				type = "combined_image_sampler",
				binding_index = 1,
				stageFlags = "compute",
				set_index = 0,
			},
			{
				type = "combined_image_sampler",
				binding_index = 2,
				stageFlags = "compute",
				set_index = 0,
			},
			{
				type = "combined_image_sampler",
				binding_index = 3,
				stageFlags = "compute",
				set_index = 0,
			},
			{
				type = "combined_image_sampler",
				binding_index = 4,
				stageFlags = "compute",
				set_index = 0,
			},
			{
				type = "combined_image_sampler",
				binding_index = 5,
				stageFlags = "compute",
				set_index = 0,
			},
			{
				type = "combined_image_sampler",
				binding_index = 6,
				stageFlags = "compute",
				set_index = 0,
			},
			{
				type = "storage_image",
				binding_index = 7,
				stageFlags = "compute",
				set_index = 0,
			},
			{
				type = "storage_image",
				binding_index = 8,
				stageFlags = "compute",
				set_index = 0,
			},
		},
		block = {
			{"resolution", "int"},
			{"tiles_x", "int"},
			write = function(self, block)
				block.resolution = voxel_gi.current_resolve_resolution or 1
				block.tiles_x = voxel_gi.current_resolve_tiles_x or 1
				return block
			end,
		},
		custom_declarations = [[
			layout(set = 0, binding = 0, rgba16f) uniform writeonly image2DArray out_volume;
			layout(set = 0, binding = 1) uniform sampler2DArray axis_x;
			layout(set = 0, binding = 2) uniform sampler2DArray axis_y;
			layout(set = 0, binding = 3) uniform sampler2DArray axis_z;
			layout(set = 0, binding = 4) uniform sampler2DArray normal_x;
			layout(set = 0, binding = 5) uniform sampler2DArray normal_y;
			layout(set = 0, binding = 6) uniform sampler2DArray normal_z;
			layout(set = 0, binding = 7, rgba8) uniform writeonly image2DArray out_normal;
			layout(set = 0, binding = 8, r8) uniform writeonly image2D out_occupancy;
		]],
		shader = [[
			void main() {
				ivec3 v = ivec3(gl_GlobalInvocationID.xyz);
				int res = compute.resolution;
				if (any(greaterThanEqual(v, ivec3(res)))) return;
				int m = res - 1;
				ivec3 cx = ivec3(m - v.z, m - v.y, v.x);
				ivec3 cy = ivec3(m - v.x, v.z, v.y);
				ivec3 cz = ivec3(m - v.x, m - v.y, v.z);
				const float OCCUPANCY_EPS = 4.0 / 255.0;
				const float OCCUPANCY_THRESHOLD = 0.5 - OCCUPANCY_EPS;
				vec4 sx = texelFetch(axis_x, cx, 0);
				vec4 sy = texelFetch(axis_y, cy, 0);
				vec4 sz = texelFetch(axis_z, cz, 0);
				float occupancy = max(sx.a, max(sy.a, sz.a));
				vec3 color = vec3(0.0);
				vec3 normal = vec3(0.0);
				float contributors = 0.0;

				if (sx.a >= OCCUPANCY_THRESHOLD) { color += sx.rgb; normal += texelFetch(normal_x, cx, 0).xyz * 2.0 - 1.0; contributors += 1.0; }
				if (sy.a >= OCCUPANCY_THRESHOLD) { color += sy.rgb; normal += texelFetch(normal_y, cy, 0).xyz * 2.0 - 1.0; contributors += 1.0; }
				if (sz.a >= OCCUPANCY_THRESHOLD) { color += sz.rgb; normal += texelFetch(normal_z, cz, 0).xyz * 2.0 - 1.0; contributors += 1.0; }

				if (contributors > 0.0) color /= contributors;

				float normal_length = length(normal);
				normal = normal_length > 1e-3 ? normal / normal_length : vec3(0.0);
				bool occupied = occupancy >= OCCUPANCY_THRESHOLD;
				float emissive_luma = occupied && occupancy > 0.5 + OCCUPANCY_EPS ? (occupancy - 0.5) * 8.0 : 0.0;
				imageStore(out_volume, v, vec4(color, occupied ? 1.0 + emissive_luma : 0.0));
				imageStore(out_normal, v, vec4(normal * 0.5 + 0.5, occupied ? 1.0 : 0.0));
				ivec2 occupancy_texel = ivec2((v.z % compute.tiles_x) * res + v.x, (v.z / compute.tiles_x) * res + v.y);
				imageStore(out_occupancy, occupancy_texel, vec4(occupied ? 1.0 : 0.0));
			}
		]],
	}
end

-- Disable probes whose storage slot has scrolled onto a new world cell.
--
-- The probe textures are toroidal: when the grid origin steps by one, the
-- trailing slab of slots is remapped to cells on the opposite face of the
-- volume, up to a whole volume away. The update shader notices (meta.xyz != g)
-- and refuses to blend history into them, but the texture still holds the
-- previous occupant's irradiance, and the sampler has no way to tell -- it only
-- checks info.w, which means "backface disabled", not "stale". So until the
-- round robin happens to reach that slot (7 frames at cascade 0, 27 at cascade
-- 3) every lookup that lands there reads radiance gathered somewhere else
-- entirely, which is the one frame leak flash you get when the grid snaps.
--
-- Zeroing info.w here is enough to take them out of the gather, because the
-- update pass rewrites info unconditionally and skips the history mix while
-- meta.xyz still disagrees.
local function build_invalidate_pipeline()
	local frame_span = math.max(render.GetSwapchainImageCount() or 1, 1)
	return EasyPipeline.Compute{
		name = "voxel_gi_invalidate",
		DescriptorSetCount = frame_span * voxel_gi.CASCADE_COUNT,
		LocalSize = {x = INVALIDATE_LOCAL_SIZE, y = 1, z = 1},
		descriptor_sets = {
			{
				type = "storage_image",
				binding_index = 0,
				stageFlags = "compute",
				set_index = 0,
			},
			{
				type = "storage_buffer",
				binding_index = 1,
				stageFlags = "compute",
				set_index = 0,
			},
		},
		block = {
			{"cascade", "int"},
			{"origin_x", "int"},
			{"origin_y", "int"},
			{"origin_z", "int"},
			write = function(self, block)
				local index = voxel_gi.current_cascade
				local cascade = voxel_gi.cascades[index]
				block.cascade = index - 1
				block.origin_x = cascade.grid_origin.x
				block.origin_y = cascade.grid_origin.y
				block.origin_z = cascade.grid_origin.z
				return block
			end,
		},
		custom_declarations = [[
			layout(set = 0, binding = 0, rgba16f) uniform writeonly image2D gi_info_image;
			layout(std430, set = 0, binding = 1) buffer GIProbeMetadata { ivec4 gi_probe_meta[]; };
		]],
		shader = [[
			const int PROBES_PER_CASCADE = ]] .. PROBES_PER_CASCADE .. [[;
			const ivec3 PROBE_COUNTS = ivec3(]] .. voxel_gi.PROBE_COUNT_X .. [[, ]] .. voxel_gi.PROBE_COUNT_Y .. [[, ]] .. voxel_gi.PROBE_COUNT_Z .. [[);

			void main() {
				int slot = int(gl_GlobalInvocationID.x);

				if (slot >= PROBES_PER_CASCADE) return;

				ivec3 counts = PROBE_COUNTS;
				// same slot -> storage coord -> world cell chain the update pass
				// walks, so the two agree on which cell a slot currently holds
				ivec3 s = ivec3(slot % counts.x, slot / (counts.x * counts.z), (slot / counts.x) % counts.z);
				ivec3 origin = ivec3(compute.origin_x, compute.origin_y, compute.origin_z);
				ivec3 g = origin + ((s - origin) % counts + counts) % counts;
				ivec4 meta = gi_probe_meta[compute.cascade * PROBES_PER_CASCADE + slot];

				if (meta.xyz == g && meta.w != 0) return;

				// relocation is recomputed from the clipmaps on every update, so
				// there is nothing in xyz worth preserving
				imageStore(gi_info_image, ivec2(s.x, s.y * counts.z + s.z), vec4(0.0));
			}
		]],
	}
end

local function ensure_pipelines()
	if not voxel_gi.update_pipeline then
		voxel_gi.update_pipeline = build_update_pipeline()
	end

	if not voxel_gi.resolve_pipeline then
		voxel_gi.resolve_pipeline = build_resolve_pipeline()
	end

	if not voxel_gi.invalidate_pipeline then
		voxel_gi.invalidate_pipeline = build_invalidate_pipeline()
	end
end

local function get_descriptor_slot(index, per_frame)
	local frame = render.GetCurrentFrame() or 1
	local frame_span = math.max(render.GetSwapchainImageCount() or 1, 1)
	frame = ((frame - 1) % frame_span) + 1
	return (frame - 1) * per_frame + index
end

local function get_clipmap_content_version(clipmap)
	if clipmap.build_scroll_ready then return clipmap.build_content_version or 0 end

	return clipmap.active_content_version or 0
end

local function resolve_clipmaps(cmd, voxelizer)
	local clipmap_count = math.min(voxelizer.clipmap_count or 0, MAX_CLIPMAPS)
	voxel_gi.clipmap_count = clipmap_count
	voxel_gi.clip_info = voxel_gi.clip_info or {}

	for i = 1, MAX_CLIPMAPS do
		local clipmap = i <= clipmap_count and voxelizer.GetClipmap(i) or nil
		local info = voxel_gi.clip_info[i] or {origin = Vec3(0, 0, 0)}
		voxel_gi.clip_info[i] = info
		info.valid = false

		if clipmap and clipmap.has_valid_data then
			local target_x = voxelizer.GetClipmapLightingAxisTarget(i, "x")
			local target_y = voxelizer.GetClipmapLightingAxisTarget(i, "y")
			local target_z = voxelizer.GetClipmapLightingAxisTarget(i, "z")
			local origin = voxelizer.GetClipmapLightingOrigin(i) or clipmap.origin

			if target_x and target_y and target_z and origin then
				local resolved = ensure_resolved_volume(i, clipmap.resolution)
				local version = get_clipmap_content_version(clipmap)
				local target_key = tostring(target_x.texture)

				if
					resolved.version ~= version or
					resolved.target_key ~= target_key or
					resolved.origin.x ~= origin.x or
					resolved.origin.y ~= origin.y or
					resolved.origin.z ~= origin.z
				then
					local slot = get_descriptor_slot(i, MAX_CLIPMAPS)
					local pipeline = voxel_gi.resolve_pipeline
					render.TransitionResourceToComputeStorage(
						resolved.texture,
						{
							cmd = cmd,
							dstAccess = "shader_write",
							base_array_layer = 0,
							layer_count = clipmap.resolution,
							base_mip_level = 0,
							level_count = 1,
						}
					)
					render.TransitionResourceToComputeStorage(
						resolved.normal_texture,
						{
							cmd = cmd,
							dstAccess = "shader_write",
							base_array_layer = 0,
							layer_count = clipmap.resolution,
							base_mip_level = 0,
							level_count = 1,
						}
					)
					pipeline:UpdateDescriptorSet("storage_image", slot, 0, 0, resolved.texture:GetView())
					pipeline:UpdateDescriptorSet("combined_image_sampler", slot, 1, 0, target_x.sample_view, target_x.sampler)
					pipeline:UpdateDescriptorSet("combined_image_sampler", slot, 2, 0, target_y.sample_view, target_y.sampler)
					pipeline:UpdateDescriptorSet("combined_image_sampler", slot, 3, 0, target_z.sample_view, target_z.sampler)
					pipeline:UpdateDescriptorSet(
						"combined_image_sampler",
						slot,
						4,
						0,
						target_x.normal_sample_view,
						target_x.sampler
					)
					pipeline:UpdateDescriptorSet(
						"combined_image_sampler",
						slot,
						5,
						0,
						target_y.normal_sample_view,
						target_y.sampler
					)
					pipeline:UpdateDescriptorSet(
						"combined_image_sampler",
						slot,
						6,
						0,
						target_z.normal_sample_view,
						target_z.sampler
					)
					pipeline:UpdateDescriptorSet("storage_image", slot, 7, 0, resolved.normal_texture:GetView())
					render.TransitionResourceToComputeStorage(resolved.occupancy, {cmd = cmd, dstAccess = "shader_write"})
					pipeline:UpdateDescriptorSet("storage_image", slot, 8, 0, resolved.occupancy:GetView())
					voxel_gi.current_resolve_resolution = clipmap.resolution
					voxel_gi.current_resolve_tiles_x = resolved.tiles_x
					pipeline:DispatchForSize(cmd, clipmap.resolution, clipmap.resolution, clipmap.resolution, slot)
					transition_array_to_shader_read(cmd, resolved.texture, clipmap.resolution, "compute", "shader_write", "compute")
					transition_array_to_shader_read(cmd, resolved.occupancy, 1, "compute", "shader_write", "fragment_shader")
					transition_array_to_shader_read(
						cmd,
						resolved.normal_texture,
						clipmap.resolution,
						"compute",
						"shader_write",
						"compute"
					)
					resolved.version = version
					resolved.target_key = target_key
					resolved.origin.x = origin.x
					resolved.origin.y = origin.y
					resolved.origin.z = origin.z
					resolved.valid = true
				end

				if resolved.valid then
					info.valid = true
					info.origin.x = origin.x
					info.origin.y = origin.y
					info.origin.z = origin.z
					info.voxel_size = clipmap.voxel_size
					info.world_span = clipmap.world_span
					info.resolution = clipmap.resolution
				end
			end
		end
	end
end

-- brings the clipmap volumes up to date for whoever traces them first this
-- frame, the resolve itself is skipped when the clipmap content is unchanged
function voxel_gi.EnsureResolvedClipmaps(cmd)
	local voxelizer = render3d.GetSceneVoxelizer()

	if not voxelizer or not voxelizer.IsEnabled() then return false end

	ensure_pipelines()
	resolve_clipmaps(cmd, voxelizer)

	for i = 1, MAX_CLIPMAPS do
		local info = voxel_gi.clip_info[i]

		if info and info.valid then return true end
	end

	return false
end

local function update_cascade_origins(camera_position, camera_forward)
	local fx, fz = camera_forward.x, camera_forward.z
	local len = math.sqrt(fx * fx + fz * fz)

	if len > 1e-3 then fx, fz = fx / len, fz / len else fx, fz = 0, 0 end

	local bias = voxel_gi.FORWARD_BIAS or 0

	for i, cascade in ipairs(voxel_gi.cascades) do
		local spacing = cascade.spacing
		local shift_x = math.floor(fx * bias * voxel_gi.PROBE_COUNT_X * 0.5 + 0.5)
		local shift_z = math.floor(fz * bias * voxel_gi.PROBE_COUNT_Z * 0.5 + 0.5)
		cascade.grid_origin.x = math.floor(camera_position.x / spacing + 0.5) - math.floor(voxel_gi.PROBE_COUNT_X / 2) + shift_x
		cascade.grid_origin.y = math.floor(camera_position.y / spacing + 0.5) - math.floor(voxel_gi.PROBE_COUNT_Y / 2)
		cascade.grid_origin.z = math.floor(camera_position.z / spacing + 0.5) - math.floor(voxel_gi.PROBE_COUNT_Z / 2) + shift_z
	end
end

local function random_rotation_matrix()
	local u1, u2, u3 = math.random(), math.random(), math.random()
	local r1 = math.sqrt(1 - u1)
	local r2 = math.sqrt(u1)
	local t1 = math.pi * 2 * u2
	local t2 = math.pi * 2 * u3
	return Quat(r1 * math.sin(t1), r1 * math.cos(t1), r2 * math.sin(t2), r2 * math.cos(t2)):GetMatrix()
end

-- Runs before the update dispatches, so a slot that is both stale and scheduled
-- this frame still ends up with fresh data rather than disabled: the barrier
-- below orders the two, and the update pass writes info unconditionally.
local function invalidate_scrolled_probes(cmd)
	local pipeline = voxel_gi.invalidate_pipeline

	if not pipeline or not voxel_gi.metadata_buffer then return end

	local groups = math.ceil(PROBES_PER_CASCADE / INVALIDATE_LOCAL_SIZE)
	local barriers = {}

	for i, cascade in ipairs(voxel_gi.cascades) do
		local slot = get_descriptor_slot(i, voxel_gi.CASCADE_COUNT)
		pipeline:UpdateDescriptorSet("storage_image", slot, 0, 0, cascade.info:GetView())
		pipeline:UpdateDescriptorSet(
			"storage_buffer",
			slot,
			1,
			0,
			voxel_gi.metadata_buffer,
			voxel_gi.metadata_buffer:GetSize()
		)
		voxel_gi.current_cascade = i
		pipeline:Dispatch(cmd, groups, 1, 1, slot)
		barriers[#barriers + 1] = {
			image = cascade.info:GetImage(),
			oldLayout = "general",
			newLayout = "general",
			srcAccessMask = "shader_write",
			dstAccessMask = {"shader_read", "shader_write"},
		}
	end

	-- the update pass samples every cascade's info for its bounce term as well as
	-- rewriting the slots it owns, so it has to observe these stores
	cmd:PipelineBarrier{srcStage = "compute", dstStage = "compute", imageBarriers = barriers}
end

function voxel_gi.Draw(cmd)
	voxel_gi.has_data = false

	if not voxel_gi.enabled then return end

	local voxelizer = render3d.GetSceneVoxelizer()

	if not voxelizer or not voxelizer.IsEnabled() then return end

	ensure_cascade_resources()

	if not voxel_gi.EnsureResolvedClipmaps(cmd) then return end

	local camera = render3d.GetRenderCamera()
	update_cascade_origins(camera:GetPosition(), camera:GetRotation():GetForward())
	voxel_gi.ray_rotation = random_rotation_matrix()
	voxel_gi.frame = voxel_gi.frame + 1
	local pipeline = voxel_gi.update_pipeline

	for _, cascade in ipairs(voxel_gi.cascades) do
		render.TransitionResourceToComputeStorage(cascade.irradiance, {cmd = cmd, dstAccess = "shader_write"})
		render.TransitionResourceToComputeStorage(cascade.visibility, {cmd = cmd, dstAccess = "shader_write"})
		render.TransitionResourceToComputeStorage(cascade.info, {cmd = cmd, dstAccess = "shader_write"})
	end

	local oct_view, oct_sampler = table.unpack(light_occlusion.GetOcclusionDescriptor())

	if voxel_gi.BVH_TRACE then scene_bvh.EnsureBuilt() end

	if voxel_gi.SCROLL_INVALIDATE then invalidate_scrolled_probes(cmd) end

	for i, cascade in ipairs(voxel_gi.cascades) do
		local slot = get_descriptor_slot(i, voxel_gi.CASCADE_COUNT)
		pipeline:UpdateDescriptorSet(
			"combined_image_sampler",
			slot,
			BINDING_OCCLUSION_MAP,
			0,
			oct_view,
			oct_sampler
		)

		for clip = 0, MAX_CLIPMAPS - 1 do
			local resolved = voxel_gi.resolved[clip + 1]
			local info = voxel_gi.clip_info[clip + 1]

			if not (resolved and info and info.valid) then
				resolved = voxel_gi.resolved[1] or voxel_gi.resolved[2] or voxel_gi.resolved[3]
			end

			pipeline:UpdateDescriptorSet(
				"combined_image_sampler",
				slot,
				BINDING_VOLUME_0 + clip,
				0,
				resolved.sample_view,
				resolved.sampler
			)
			pipeline:UpdateDescriptorSet(
				"combined_image_sampler",
				slot,
				BINDING_NORMAL_VOLUME_0 + clip,
				0,
				resolved.normal_sample_view,
				resolved.sampler
			)
		end

		for j = 0, MAX_CASCADES - 1 do
			local other = voxel_gi.cascades[j + 1] or cascade
			pipeline:UpdateDescriptorSet("storage_image", slot, BINDING_IRRADIANCE_0 + j, 0, other.irradiance:GetView())
			pipeline:UpdateDescriptorSet("storage_image", slot, BINDING_VISIBILITY_0 + j, 0, other.visibility:GetView())
			pipeline:UpdateDescriptorSet("storage_image", slot, BINDING_INFO_0 + j, 0, other.info:GetView())
		end

		pipeline:UpdateDescriptorSet(
			"storage_buffer",
			slot,
			BINDING_METADATA,
			0,
			voxel_gi.metadata_buffer,
			voxel_gi.metadata_buffer:GetSize()
		)

		-- the bindings must be filled even when the bvh has no geometry yet, or
		-- the descriptor set is incomplete; the shader gates on compute.bvh_ready
		if scene_bvh.node_buffer and scene_bvh.triangle_buffer then
			scene_bvh.BindBuffers(pipeline, slot, BINDING_BVH_NODES, BINDING_BVH_TRIANGLES)
		end

		voxel_gi.current_cascade = i
		local probes_per_frame = get_cascade_probes_per_frame(i)
		pipeline:Dispatch(cmd, probes_per_frame, 1, 1, slot)
		cascade.probe_base = (cascade.probe_base + probes_per_frame) % PROBES_PER_CASCADE
	end

	for _, cascade in ipairs(voxel_gi.cascades) do
		for _, texture in ipairs{cascade.irradiance, cascade.visibility, cascade.info} do
			render.TransitionResourceFrom(
				texture,
				"shader_read_only_optimal",
				{
					cmd = cmd,
					srcStage = "compute",
					srcAccess = "shader_write",
					dstStage = "compute",
					dstAccess = "shader_read",
				}
			)
		end
	end

	voxel_gi.has_data = true
end

function voxel_gi.SetEnabled(enabled)
	voxel_gi.enabled = enabled ~= false
end

function voxel_gi.Invalidate()
	if not voxel_gi.metadata_buffer then return end

	local size = voxel_gi.metadata_buffer:GetSize()
	ffi.fill(voxel_gi.metadata_buffer:Map(), size, 0)
	voxel_gi.metadata_buffer:Unmap()

	for _, resolved in pairs(voxel_gi.resolved) do
		resolved.version = -1
	end
end

commands.Add("voxel_gi=boolean[true]", function(enabled)
	voxel_gi.SetEnabled(enabled)
	logf("[voxel_gi] %s\n", enabled and "enabled" or "disabled")
end)

commands.Add("voxel_gi_debug=boolean[true]", function(enabled)
	voxel_gi.debug_mode = enabled ~= false and 1 or 0
	logf(
		"[voxel_gi] gi only debug view %s\n",
		voxel_gi.debug_mode == 1 and "enabled" or "disabled"
	)
end)

commands.Add("voxel_gi_occlusion=boolean[true]", function(enabled)
	voxel_gi.occlusion_enabled = enabled ~= false
	logf(
		"[voxel_gi] probe occlusion %s\n",
		voxel_gi.occlusion_enabled and "enabled" or "disabled"
	)
end)

commands.Add("voxel_gi_bvh=boolean[true]", function(enabled)
	voxel_gi.BVH_TRACE = enabled ~= false
	logf(
		"[voxel_gi] probe rays trace %s\n",
		voxel_gi.BVH_TRACE and "the scene bvh" or "the voxel clipmaps"
	)
end)

commands.Add("voxel_gi_relocate=boolean[true]", function(enabled)
	voxel_gi.RELOCATE = enabled ~= false
	logf(
		"[voxel_gi] probes inside geometry are %s\n",
		voxel_gi.RELOCATE and "nudged to the nearest open spot" or "left in place"
	)
end)

commands.Add("voxel_gi_stable_first_sample=boolean[true]", function(enabled)
	voxel_gi.STABLE_FIRST_SAMPLE = enabled ~= false
	logf(
		"[voxel_gi] probes with no history trace %s ray set\n",
		voxel_gi.STABLE_FIRST_SAMPLE and "the unrotated" or "a randomly rotated"
	)
end)

commands.Add("voxel_gi_scroll_invalidate=boolean[true]", function(enabled)
	voxel_gi.SCROLL_INVALIDATE = enabled ~= false
	logf(
		"[voxel_gi] probes whose slot scrolled onto a new cell are %s\n",
		voxel_gi.SCROLL_INVALIDATE and "dropped until re-traced" or "sampled as-is"
	)
end)

commands.Add("voxel_gi_visibility=boolean[true]", function(enabled)
	voxel_gi.visibility_enabled = enabled ~= false
	logf(
		"[voxel_gi] probe visibility weighting %s\n",
		voxel_gi.visibility_enabled and "enabled" or "disabled"
	)
end)

voxel_gi.SAMPLE_QUALITY_PRESETS = {
	high = {
		SCREEN_SCALE = 1,
		MAX_SAMPLE_CASCADES = 4,
		OCCLUSION_MAX_CASCADE = 4,
		OCCLUSION_MAX_STEPS = 24,
		OCCLUSION_STEP_VOXELS = 0.5,
		BILINEAR_IRRADIANCE = true,
		BILINEAR_VISIBILITY = true,
	},
	medium = {
		SCREEN_SCALE = 0.5,
		MAX_SAMPLE_CASCADES = 3,
		OCCLUSION_MAX_CASCADE = 2,
		OCCLUSION_MAX_STEPS = 12,
		OCCLUSION_STEP_VOXELS = 0.75,
		BILINEAR_IRRADIANCE = true,
		BILINEAR_VISIBILITY = true,
	},
	low = {
		SCREEN_SCALE = 0.5,
		MAX_SAMPLE_CASCADES = 2,
		OCCLUSION_MAX_CASCADE = 1,
		OCCLUSION_MAX_STEPS = 6,
		OCCLUSION_STEP_VOXELS = 1.0,
		BILINEAR_IRRADIANCE = true,
		BILINEAR_VISIBILITY = false,
	},
	lowest = {
		SCREEN_SCALE = 0.5,
		MAX_SAMPLE_CASCADES = 2,
		OCCLUSION_MAX_CASCADE = 0,
		OCCLUSION_MAX_STEPS = 0,
		OCCLUSION_STEP_VOXELS = 1.0,
		BILINEAR_IRRADIANCE = false,
		BILINEAR_VISIBILITY = false,
	},
}

function voxel_gi.SetSampleQuality(name)
	local preset = voxel_gi.SAMPLE_QUALITY_PRESETS[name]

	if not preset then
		error("unknown voxel gi sample quality: " .. tostring(name), 2)
	end

	for key, value in pairs(preset) do
		voxel_gi[key] = value
	end

	voxel_gi.sample_quality = name
	return preset
end

commands.Add("voxel_gi_quality=string[medium]", function(name)
	voxel_gi.SetSampleQuality(name)
	logf("[voxel_gi] sample quality %s, rebuilding pipelines\n", name)
	render3d.Initialize()
end)

commands.Add("voxel_gi_probe_rate=number[1024]", function(count)
	voxel_gi.PROBES_PER_FRAME = math.floor(count)
	logf("[voxel_gi] %d probes per frame\n", voxel_gi.PROBES_PER_FRAME)
end)

commands.Add("voxel_gi_invalidate", function()
	voxel_gi.Invalidate()
end)

if HOTRELOAD then voxel_gi.RemoveResources() end

return voxel_gi
