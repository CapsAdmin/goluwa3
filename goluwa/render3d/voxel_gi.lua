local ffi = require("ffi")
local commands = import("goluwa/cli/commands.lua")
local event = import("goluwa/event.lua")
local Color = import("goluwa/structs/color.lua")
local render = import("goluwa/render/render.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local Texture = import("goluwa/render/texture.lua")
local Buffer = import("goluwa/render/vulkan/internal/buffer.lua")
local EasyPipeline = import("goluwa/render/easy_pipeline.lua")
local scene_lights = import("goluwa/render3d/scene_lights.lua")
local directional_shadows = import("goluwa/render3d/directional_shadows.lua")
local ibl = import("goluwa/render3d/ibl.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Quat = import("goluwa/structs/quat.lua")
local voxel_gi = library()
-- Diffuse global illumination from the scene voxel clipmaps.
--
-- A camera centered grid of light probes (one grid per cascade, each cascade
-- with a larger spacing) stores cosine convolved radiance in a small
-- octahedral map plus a distance/distance² map for visibility tests. Every
-- frame a slice of the probes is refreshed by tracing rays through the voxel
-- clipmaps built by the voxel_build pass. Ray hits are shaded with the sun
-- (through the cascade shadow maps), emissive voxels and the previous
-- frame's probe irradiance, which gives multiple bounces for free. Rays that
-- leave the voxel volumes return the sky from the environment probe.
--
-- The grids use toroidal addressing so moving the camera never copies any
-- data: a probe that scrolls in simply overwrites the storage slot of the
-- probe that scrolled out, and a small metadata buffer records which world
-- grid coordinate each slot currently holds.
voxel_gi.CASCADE_COUNT = 4
voxel_gi.PROBE_COUNT_X = 24
voxel_gi.PROBE_COUNT_Y = 12
voxel_gi.PROBE_COUNT_Z = 24
voxel_gi.CASCADE_SPACINGS = {1, 2, 4, 8}
-- the grids are shifted ahead of the camera along its horizontal view
-- direction by this fraction of their half extent, so detail reaches
-- further into the view than behind it
voxel_gi.FORWARD_BIAS = 0.3
voxel_gi.RAYS_PER_PROBE = 64 -- must match the workgroup size below
voxel_gi.PROBES_PER_FRAME = 1024 -- per cascade
voxel_gi.MAX_TRACE_STEPS = 128
voxel_gi.IRRADIANCE_OCT_SIZE = 8
voxel_gi.VISIBILITY_OCT_SIZE = 16
voxel_gi.HYSTERESIS = 0.9
voxel_gi.enabled = voxel_gi.enabled ~= false
-- march the voxel occupancy between each shaded point and its 8 probes,
-- dropping probes behind walls before interpolation
voxel_gi.occlusion_enabled = voxel_gi.occlusion_enabled ~= false
voxel_gi.OCCLUSION_MAX_STEPS = 24
-- Chebyshev visibility weighting of probes from their mean distance atlas
voxel_gi.visibility_enabled = voxel_gi.visibility_enabled ~= false
voxel_gi.cascades = voxel_gi.cascades or {}
voxel_gi.resolved = voxel_gi.resolved or {}
voxel_gi.frame = voxel_gi.frame or 0
local PROBES_PER_CASCADE = voxel_gi.PROBE_COUNT_X * voxel_gi.PROBE_COUNT_Y * voxel_gi.PROBE_COUNT_Z
local MAX_CLIPMAPS = 3
-- upper bound baked into the uniform block and the update pass bindings
local MAX_CASCADES = 4
assert(voxel_gi.CASCADE_COUNT <= MAX_CASCADES, "voxel_gi.CASCADE_COUNT exceeds MAX_CASCADES")
local BINDING_UNIFORM = 0
local BINDING_VOLUME_0 = 1
local BINDING_NORMAL_VOLUME_0 = BINDING_VOLUME_0 + MAX_CLIPMAPS
local BINDING_IRRADIANCE_0 = BINDING_NORMAL_VOLUME_0 + MAX_CLIPMAPS
local BINDING_VISIBILITY_0 = BINDING_IRRADIANCE_0 + MAX_CASCADES
local BINDING_INFO_0 = BINDING_VISIBILITY_0 + MAX_CASCADES
local BINDING_METADATA = BINDING_INFO_0 + MAX_CASCADES

function voxel_gi.GetProbesPerCascade()
	return PROBES_PER_CASCADE
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

	if voxel_gi.metadata_buffer then
		voxel_gi.metadata_buffer:Remove()
		voxel_gi.metadata_buffer = nil
	end

	for _, key in ipairs({"resolve_pipeline", "update_pipeline"}) do
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

-- Uniform block fields shared by every shader that samples the probe grids.
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
		-- per clipmap: xyz center, w voxel size
		{"gi_clip_origin", "vec4", MAX_CLIPMAPS},
		-- per clipmap: resolution, occupancy tiles per row, half world span, valid
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

-- GLSL for sampling the probe grids. options.storage = true reads the
-- atlases through the storage images bound by the update pass instead of
-- the bindless texture indices in the block.
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

		ivec3 voxel_gi_probe_counts() {
			return ivec3(VOXEL_GI_BLOCK.gi_probe_counts.xyz + 0.5);
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
			vec2 f = uv - vec2(base);
			vec4 result = vec4(0.0);

			for (int i = 0; i < 4; i++) {
				ivec2 offset = ivec2(i & 1, i >> 1);
				float w = (offset.x == 0 ? 1.0 - f.x : f.x) * (offset.y == 0 ? 1.0 - f.y : f.y);
				ivec2 texel = voxel_gi_wrap_oct_texel(base + offset, VOXEL_GI_IRRADIANCE_SIZE);
				result += voxel_gi_fetch_irradiance(c, tile + texel) * w;
			}

			return result;
		}

		vec2 voxel_gi_sample_visibility(int c, ivec3 s, vec3 dir) {
			ivec2 tile = voxel_gi_tile_origin(s, VOXEL_GI_VISIBILITY_SIZE);
			vec2 uv = voxel_gi_oct_encode(dir) * float(VOXEL_GI_VISIBILITY_SIZE) - 0.5;
			ivec2 base = ivec2(floor(uv));
			vec2 f = uv - vec2(base);
			vec2 result = vec2(0.0);

			for (int i = 0; i < 4; i++) {
				ivec2 offset = ivec2(i & 1, i >> 1);
				float w = (offset.x == 0 ? 1.0 - f.x : f.x) * (offset.y == 0 ? 1.0 - f.y : f.y);
				ivec2 texel = voxel_gi_wrap_oct_texel(base + offset, VOXEL_GI_VISIBILITY_SIZE);
				result += voxel_gi_fetch_visibility(c, tile + texel) * w;
			}

			return result;
		}

		const int VOXEL_GI_OCCLUSION_MAX_STEPS = ]] .. voxel_gi.OCCLUSION_MAX_STEPS .. [[;

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

		// 1 when no occupied voxel lies between the surface point and the
		// probe, 0 when the probe is behind geometry. Uses the finest clipmap
		// that contains both ends. The march starts one voxel off the surface
		// because thin walls occupy the cells on both sides of their faces.
		float voxel_gi_probe_occlusion(vec3 pos, vec3 N, vec3 probe_pos) {
			if (VOXEL_GI_HAS_OCCLUSION == 0 || VOXEL_GI_BLOCK.gi_occlusion == 0) return 1.0;

			for (int k = 0; k < ]] .. MAX_CLIPMAPS .. [[; k++) {
				if (!voxel_gi_clip_contains(k, pos) || !voxel_gi_clip_contains(k, probe_pos)) continue;
				float voxel = VOXEL_GI_BLOCK.gi_clip_origin[k].w;
				vec3 start = pos + N * voxel;
				// wedged into a corner, nothing to judge from
				if (voxel_gi_occupancy_at(k, start) > 0.5) return 1.0;
				vec3 seg = probe_pos - start;
				float len = length(seg);
				// stop half a voxel short of the probe, its own cell is free by construction
				float march = len - voxel * 0.5;
				if (march <= 0.0) return 1.0;
				int steps = min(int(ceil(march / (voxel * 0.5))), VOXEL_GI_OCCLUSION_MAX_STEPS);
				vec3 step = seg / len * (march / float(steps));
				vec3 p = start;

				for (int i = 0; i < steps; i++) {
					p += step;
					if (voxel_gi_occupancy_at(k, p) > 0.5) return 0.0;
				}

				return 1.0;
			}

			return 1.0;
		}

		// 0 outside the cascade, 1 when at least one probe away from its edge
		float voxel_gi_cascade_fade(int c, vec3 pos) {
			vec3 grid_pos = pos / voxel_gi_spacing(c) - vec3(voxel_gi_grid_origin(c));
			vec3 counts = vec3(voxel_gi_probe_counts());
			vec3 edge = min(grid_pos, counts - 1.0 - grid_pos);
			float e = min(edge.x, min(edge.y, edge.z));
			return clamp(e - 0.5, 0.0, 1.0);
		}

		// voxel size of the finest clipmap holding pos, falls back to a
		// fraction of the probe spacing when no clipmap data is bound
		float voxel_gi_voxel_size_at(vec3 pos, float spacing) {
			for (int k = 0; k < ]] .. MAX_CLIPMAPS .. [[; k++) {
				if (voxel_gi_clip_contains(k, pos)) return VOXEL_GI_BLOCK.gi_clip_origin[k].w;
			}
			return spacing * 0.5;
		}

		vec3 voxel_gi_sample_cascade(int c, vec3 pos, vec3 bias_pos, vec3 N, out float total_weight) {
			float spacing = voxel_gi_spacing(c);
			// distances are measured through voxels, allow half a voxel of
			// error before a probe counts as blocked
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
			// fallback when every probe is judged occluded
			vec3 open_sum = vec3(0.0);
			float open_weight = 0.0;

			for (int i = 0; i < 8; i++) {
				ivec3 offset = ivec3(i & 1, (i >> 1) & 1, (i >> 2) & 1);
				ivec3 g = origin + base + offset;
				ivec3 s = voxel_gi_storage_coord(g);
				vec4 info = voxel_gi_probe_info(c, s);
				if (info.w <= 0.0) continue;
				vec3 probe_pos = vec3(g) * spacing + info.xyz;
				vec3 tri = mix(1.0 - alpha, alpha, vec3(offset));
				float w = tri.x * tri.y * tri.z;
				vec3 to_probe = normalize(probe_pos - pos);
				float wrap = (dot(to_probe, N) + 1.0) * 0.5;
				w *= wrap * wrap + 0.2;
				vec3 probe_to_point = bias_pos - probe_pos;
				float dist = length(probe_to_point);
				vec3 dir = probe_to_point / max(dist, 1e-5);
				vec2 vis = voxel_gi_sample_visibility(c, s, dir);
				float mean = vis.x;

				if (VOXEL_GI_BLOCK.gi_probe_counts.w > 0.5 && dist > mean + vis_slack) {
					float variance = abs(vis.y - mean * mean) + 1e-4;
					float d = dist - mean - vis_slack;
					float cheb = variance / (variance + d * d);
					// squared with a higher floor: a gentle dimming instead of a hard flip
					w *= max(cheb * cheb, 0.1);
				}

				vec4 irr = voxel_gi_sample_irradiance(c, s, N);
				open_sum += irr.rgb * w;
				open_weight += w;
				w *= voxel_gi_probe_occlusion(pos, N, probe_pos);
				sum += irr.rgb * w;
				total_weight += w;
			}

			if (total_weight <= 1e-6) {
				total_weight = open_weight;
				sum = open_sum;
			}

			if (total_weight <= 1e-6) return vec3(0.0);

			return sum / total_weight;
		}

		// Cosine convolved radiance (irradiance / pi) at a surface point.
		// Multiply by albedo for the diffuse outgoing radiance. fallback is
		// used outside every cascade, typically the sky irradiance.
		vec3 sample_voxel_gi_irradiance(vec3 pos, vec3 N, vec3 V, vec3 fallback) {
			vec3 result = fallback;

			for (int c = VOXEL_GI_BLOCK.gi_cascade_count - 1; c >= 0; c--) {
				float spacing = voxel_gi_spacing(c);
				vec3 bias_pos = pos + (N * 0.6 + V * 0.4) * spacing * 0.25;
				float fade = voxel_gi_cascade_fade(c, bias_pos);
				if (fade <= 0.0) continue;
				float weight;
				vec3 irr = voxel_gi_sample_cascade(c, pos, bias_pos, N, weight);
				if (weight <= 1e-6) continue;
				result = mix(result, irr, fade);
			}

			return result;
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
	return EasyPipeline.Compute{
		name = "voxel_gi_update",
		DescriptorSetCount = frame_span * voxel_gi.CASCADE_COUNT,
		LocalSize = {x = voxel_gi.RAYS_PER_PROBE, y = 1, z = 1},
		descriptor_sets = descriptor_sets,
		block = {
			{"cascade", "int"},
			{"probe_base", "int"},
			{"min_clipmap", "int"},
			write = function(self, block)
				block.cascade = voxel_gi.current_cascade - 1
				block.probe_base = voxel_gi.cascades[voxel_gi.current_cascade].probe_base
				block.min_clipmap = math.min(voxel_gi.current_cascade, voxel_gi.clipmap_count or 1) - 1
				return block
			end,
		},
		uniform_buffers = {
			{
				name = "gi_data",
				binding_index = BINDING_UNIFORM,
				block = {
					render3d.camera_block,
					{"shadows", scene_lights.BuildShadowsBlockLayout()},
					{"sun_direction", "vec4"},
					{"sun_radiance", "vec4"},
					{"ray_rotation", "mat4"},
					{"env_tex", "int"},
					{"env_irradiance_tex", "int"},
					{"hysteresis", "float"},
					{"max_steps", "int"},
					{"clipmap_count", "int"},
					{"clip_origin", "vec4", MAX_CLIPMAPS},
					{"clip_params", "vec4", MAX_CLIPMAPS},
					voxel_gi.GetBlockLayout(),
				},
				write = function(self, block)
					render3d.WriteCameraBlock(self, block)
					local lights = render3d.GetLights()
					scene_lights.WriteShadowBlock(self, block.shadows, lights)
					local sun_dir = directional_shadows.GetPrimarySunDirection(lights)
					local sun_color = directional_shadows.GetPrimarySunColor(lights)
					local sun_intensity = directional_shadows.GetPrimarySunIntensity(lights)
					sun_dir:CopyToFloatPointer(block.sun_direction)
					block.sun_direction[3] = 0
					block.sun_radiance[0] = sun_color.x * sun_intensity
					block.sun_radiance[1] = sun_color.y * sun_intensity
					block.sun_radiance[2] = sun_color.z * sun_intensity
					block.sun_radiance[3] = 0
					voxel_gi.ray_rotation:CopyToFloatPointer(block.ray_rotation)
					block.env_tex = self:GetCubeMapTextureIndex(render3d.GetEnvironmentTexture())
					block.env_irradiance_tex = self:GetCubeMapTextureIndex(render3d.GetEnvironmentIrradianceTexture())
					block.hysteresis = voxel_gi.HYSTERESIS
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
			]] .. directional_shadows.GetSurfaceDirectionalShadowGLSL("gi_data", "calculateShadow", {use_receiver_plane_bias = false}) .. [[

			const int PROBES_PER_CASCADE = ]] .. PROBES_PER_CASCADE .. [[;
			const int RAYS_PER_PROBE = ]] .. voxel_gi.RAYS_PER_PROBE .. [[;

			shared vec4 s_ray[RAYS_PER_PROBE];
			shared vec3 s_dir[RAYS_PER_PROBE];
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

			// Probes that fall inside geometry move to the closest free voxel
			// center within reach. Every thread tests a share of a 5x5x5
			// voxel stencil and the result is reduced through shared memory.
			// Returns xyz = offset, w = 1 when a free spot was found.
			vec4 relocate_probe(vec3 probe_pos, float spacing) {
				int ray = int(gl_LocalInvocationID.x);
				int c = find_clipmap(probe_pos, 0);
				bool solid = c >= 0 && point_solid(probe_pos);

				if (!solid) {
					return vec4(0.0, 0.0, 0.0, 1.0);
				}

				float vs = clip_voxel_size(c);
				vec3 min_corner = clip_origin(c) - vec3(clip_span(c) * 0.5);
				ivec3 center = ivec3(floor((probe_pos - min_corner) / vs));
				float max_reach = spacing * 0.75;
				vec4 best = vec4(0.0, 0.0, 0.0, 1e9);

				for (int k = ray; k < 125; k += RAYS_PER_PROBE) {
					ivec3 o = ivec3(k % 5, (k / 5) % 5, k / 25) - ivec3(2);
					if (all(equal(o, ivec3(0)))) continue;
					ivec3 v = center + o;
					vec3 candidate = min_corner + (vec3(v) + 0.5) * vs;
					vec3 offset = candidate - probe_pos;
					float d = length(offset);
					if (d > max_reach || d >= best.w) continue;
					if (any(lessThan(v, ivec3(0))) || any(greaterThanEqual(v, ivec3(clip_resolution(c))))) continue;
					if (voxel_solid(c, v)) continue;
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

			// Walks voxel cells along the ray, switching to coarser clipmaps
			// when leaving the current one. Returns false when the ray leaves
			// every clipmap without hitting anything.
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
						// the surface lies somewhere inside the cell, report the
						// distance to its middle so the stored mean is unbiased
						vec3 hit_cell_min = min_corner + vec3(v) * vs;
						vec3 hit_boundary = hit_cell_min + mix(vec3(0.0), vec3(vs), greaterThanEqual(dir, vec3(0.0)));
						vec3 hit_tt = max((hit_boundary - pos) * inv_dir, vec3(0.0));
						hit_dist = t + 0.5 * min(hit_tt.x, min(hit_tt.y, hit_tt.z));
						// the voxel stores the surface normal, the face normal
						// from the walk is the fallback when it is missing
						vec3 stored = fetch_voxel_normal(c, v);
						bool has_stored = dot(stored, stored) > 0.5;
						float facing = has_stored ? dot(stored, dir) : -1.0;
						// a clear backface means the ray started inside the
						// object; grazing disagreements come from voxels that
						// hold several surface orientations and are kept
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

			vec3 shade_hit(vec3 hit_pos, vec3 N, vec4 voxel, int c) {
				float vs = clip_voxel_size(max(c, 0));
				vec3 surface_pos = hit_pos + N * vs * 0.5;
				vec3 L = normalize(gi_data.sun_direction.xyz);
				float NoL = max(dot(N, L), 0.0);
				float shadow = 1.0;

				if (NoL > 0.0 && gi_data.shadows.shadow_map_indices[0] >= 0) {
					shadow = calculateShadow(surface_pos, N, L);
				}

				vec3 albedo = clamp(voxel.rgb, vec3(0.0), vec3(1.0));
				vec3 direct = gi_data.sun_radiance.rgb * (NoL * shadow / 3.14159265359);
				vec3 sky = sample_environment_irradiance(gi_data.env_irradiance_tex, N);
				vec3 bounce = sample_voxel_gi_irradiance(surface_pos, N, N, sky);
				float emissive_luma = max(voxel.a - 1.0, 0.0) * 4.0;
				vec3 emissive = voxel.rgb * (emissive_luma / max(luminance(voxel.rgb), 1e-3));
				return albedo * (direct + bounce) + emissive;
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
				int ray = int(gl_LocalInvocationID.x);

				// probes inside geometry trace from a nearby free voxel
				vec4 relocation = relocate_probe(probe_pos, spacing);
				vec3 ray_origin = probe_pos + relocation.xyz;
				bool enabled = relocation.w > 0.0;

				vec3 dir = normalize((gi_data.ray_rotation * vec4(fibonacci_direction(ray, RAYS_PER_PROBE), 0.0)).xyz);
				vec3 radiance = vec3(0.0);
				// negative distance marks a backface hit: the ray started
				// inside geometry, so it contributes no radiance
				float dist = spacing * 4.0;

				if (enabled) {
					vec3 hit_pos;
					vec3 hit_normal;
					vec4 hit_voxel;
					float hit_dist;
					bool backface;

					if (trace_voxels(ray_origin, dir, compute.min_clipmap, hit_pos, hit_normal, hit_voxel, hit_dist, backface)) {
						if (backface) {
							dist = -max(hit_dist, 1e-4);
						} else {
							radiance = shade_hit(hit_pos, hit_normal, hit_voxel, find_clipmap(hit_pos, compute.min_clipmap));
							dist = hit_dist;
						}
					} else {
						radiance = textureLod(CUBEMAP(gi_data.env_tex), correct_environment_lookup_dir(dir), 1.0).rgb;
						dist = 1e6;
					}
				}

				radiance = clamp(radiance, vec3(0.0), vec3(65504.0));
				s_ray[ray] = vec4(radiance, dist);
				s_dir[ray] = dir;
				barrier();

				// a probe whose rays mostly start inside geometry is disabled
				int backface_count = 0;

				for (int r = 0; r < RAYS_PER_PROBE; r++) {
					if (s_ray[r].a < 0.0) backface_count++;
				}

				if (backface_count * 4 > RAYS_PER_PROBE) enabled = false;

				// irradiance: one octahedral texel per thread
				ivec2 tile = voxel_gi_tile_origin(s, VOXEL_GI_IRRADIANCE_SIZE);
				ivec2 texel = ivec2(ray % VOXEL_GI_IRRADIANCE_SIZE, ray / VOXEL_GI_IRRADIANCE_SIZE);
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
					result = mix(result, previous.rgb, gi_data.hysteresis);
				}

				vec4 irradiance_value = vec4(result, enabled ? 1.0 : 0.0);
				voxel_gi_store_irradiance(c, coord, irradiance_value);

				// visibility: mean distance and mean squared distance
				float max_dist = spacing * 1.5;
				ivec2 vis_tile = voxel_gi_tile_origin(s, VOXEL_GI_VISIBILITY_SIZE);
				int vis_texel_count = VOXEL_GI_VISIBILITY_SIZE * VOXEL_GI_VISIBILITY_SIZE;

				for (int k = ray; k < vis_texel_count; k += RAYS_PER_PROBE) {
					ivec2 vt = ivec2(k % VOXEL_GI_VISIBILITY_SIZE, k / VOXEL_GI_VISIBILITY_SIZE);
					vec3 vdir = voxel_gi_oct_decode((vec2(vt) + 0.5) / float(VOXEL_GI_VISIBILITY_SIZE));
					float m = 0.0;
					float m2 = 0.0;
					float wsum = 0.0;

					for (int r = 0; r < RAYS_PER_PROBE; r++) {
						float w = pow(max(dot(vdir, s_dir[r]), 0.0), 50.0);
						float d = s_ray[r].a < 0.0 ? min(-s_ray[r].a * 0.2, max_dist) : min(s_ray[r].a, max_dist);
						m += d * w;
						m2 += d * d * w;
						wsum += w;
					}

					vec2 vis = wsum > 0.0 ? vec2(m, m2) / wsum : vec2(max_dist, max_dist * max_dist);
					ivec2 vcoord = vis_tile + vt;

					if (history_valid) {
						vis = mix(vis, voxel_gi_fetch_visibility(c, vcoord), gi_data.hysteresis);
					}

					voxel_gi_store_visibility(c, vcoord, vec4(vis, 0.0, 0.0));
				}

				if (ray == 0) {
					gi_probe_meta[meta_index] = ivec4(g, 1);
					ivec2 info_coord = voxel_gi_tile_origin(s, 1);
					// w > 0 enabled, the fraction above 1 (or below 0 when
					// disabled) is the backface ray fraction for debugging
					float backface_fraction = float(backface_count) / float(RAYS_PER_PROBE);
					vec4 info = vec4(relocation.xyz, enabled ? 1.0 + backface_fraction : -backface_fraction - 0.001);
					voxel_gi_store_info(c, info_coord, info);
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
				vec4 sx = texelFetch(axis_x, cx, 0);
				vec4 sy = texelFetch(axis_y, cy, 0);
				vec4 sz = texelFetch(axis_z, cz, 0);
				float occupancy = max(sx.a, max(sy.a, sz.a));
				vec3 color = vec3(0.0);
				vec3 normal = vec3(0.0);
				float contributors = 0.0;

				// axis normals are signed sums of the faces in the voxel
				if (sx.a >= 0.5) { color += sx.rgb; normal += texelFetch(normal_x, cx, 0).xyz; contributors += 1.0; }
				if (sy.a >= 0.5) { color += sy.rgb; normal += texelFetch(normal_y, cy, 0).xyz; contributors += 1.0; }
				if (sz.a >= 0.5) { color += sz.rgb; normal += texelFetch(normal_z, cz, 0).xyz; contributors += 1.0; }

				if (contributors > 0.0) color /= contributors;

				float normal_length = length(normal);
				normal = normal_length > 1e-3 ? normal / normal_length : vec3(0.0);
				// alpha: 0 empty, 1 + emissive luminance when occupied
				float emissive_luma = occupancy >= 0.5 ? (occupancy - 0.5) * 8.0 : 0.0;
				imageStore(out_volume, v, vec4(color, occupancy >= 0.5 ? 1.0 + emissive_luma : 0.0));
				imageStore(out_normal, v, vec4(normal * 0.5 + 0.5, occupancy >= 0.5 ? 1.0 : 0.0));
				ivec2 occupancy_texel = ivec2((v.z % compute.tiles_x) * res + v.x, (v.z / compute.tiles_x) * res + v.y);
				imageStore(out_occupancy, occupancy_texel, vec4(occupancy >= 0.5 ? 1.0 : 0.0));
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

local function update_cascade_origins(camera_position, camera_forward)
	-- horizontal view direction, the grid is only pushed sideways
	local fx, fz = camera_forward.x, camera_forward.z
	local len = math.sqrt(fx * fx + fz * fz)

	if len > 1e-3 then fx, fz = fx / len, fz / len else fx, fz = 0, 0 end

	local bias = voxel_gi.FORWARD_BIAS or 0

	for i, cascade in ipairs(voxel_gi.cascades) do
		local spacing = cascade.spacing
		-- snapped to whole probes so a small camera turn does not shift the grid
		local shift_x = math.floor(fx * bias * voxel_gi.PROBE_COUNT_X * 0.5 + 0.5)
		local shift_z = math.floor(fz * bias * voxel_gi.PROBE_COUNT_Z * 0.5 + 0.5)
		cascade.grid_origin.x = math.floor(camera_position.x / spacing + 0.5) - math.floor(voxel_gi.PROBE_COUNT_X / 2) + shift_x
		cascade.grid_origin.y = math.floor(camera_position.y / spacing + 0.5) - math.floor(voxel_gi.PROBE_COUNT_Y / 2)
		cascade.grid_origin.z = math.floor(camera_position.z / spacing + 0.5) - math.floor(voxel_gi.PROBE_COUNT_Z / 2) + shift_z
	end
end

local function random_rotation_matrix()
	local q = Quat():SetAngles(Deg3(math.random() * 360, math.random() * 360, math.random() * 360))
	return q:GetMatrix()
end

function voxel_gi.Draw(cmd)
	voxel_gi.has_data = false

	if not voxel_gi.enabled then return end

	local voxelizer = render3d.GetSceneVoxelizer()

	if not voxelizer or not voxelizer.IsEnabled() then return end

	ensure_cascade_resources()
	ensure_pipelines()
	resolve_clipmaps(cmd, voxelizer)
	local any_clip = false

	for i = 1, MAX_CLIPMAPS do
		if voxel_gi.clip_info[i] and voxel_gi.clip_info[i].valid then
			any_clip = true
		end
	end

	if not any_clip then return end

	local camera = render3d.GetRenderCamera()
	update_cascade_origins(camera:GetPosition(), camera:GetRotation():GetForward())
	voxel_gi.ray_rotation = random_rotation_matrix()
	voxel_gi.frame = voxel_gi.frame + 1
	local pipeline = voxel_gi.update_pipeline
	local probes_per_frame = math.min(voxel_gi.PROBES_PER_FRAME, PROBES_PER_CASCADE)

	for _, cascade in ipairs(voxel_gi.cascades) do
		render.TransitionResourceToComputeStorage(cascade.irradiance, {cmd = cmd, dstAccess = "shader_write"})
		render.TransitionResourceToComputeStorage(cascade.visibility, {cmd = cmd, dstAccess = "shader_write"})
		render.TransitionResourceToComputeStorage(cascade.info, {cmd = cmd, dstAccess = "shader_write"})
	end

	for i, cascade in ipairs(voxel_gi.cascades) do
		local slot = get_descriptor_slot(i, voxel_gi.CASCADE_COUNT)

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
		voxel_gi.current_cascade = i
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

function voxel_gi.IsEnabled()
	return voxel_gi.enabled
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

function voxel_gi.Dump()
	logf(
		"[voxel_gi] enabled=%s active=%s occlusion=%s frame=%d clipmaps=%d\n",
		tostring(voxel_gi.enabled),
		tostring(voxel_gi.IsActive()),
		tostring(voxel_gi.occlusion_enabled),
		voxel_gi.frame,
		voxel_gi.clipmap_count or 0
	)

	for i, cascade in ipairs(voxel_gi.cascades) do
		logf(
			"[voxel_gi] cascade %d spacing=%.2f origin=(%d %d %d) probe_base=%d\n",
			i,
			cascade.spacing,
			cascade.grid_origin.x,
			cascade.grid_origin.y,
			cascade.grid_origin.z,
			cascade.probe_base
		)
	end

	for i, info in ipairs(voxel_gi.clip_info or {}) do
		logf(
			"[voxel_gi] clipmap %d valid=%s origin=(%.1f %.1f %.1f) voxel=%.2f span=%.1f res=%d\n",
			i,
			tostring(info.valid),
			info.origin.x,
			info.origin.y,
			info.origin.z,
			info.voxel_size or 0,
			info.world_span or 0,
			info.resolution or 0
		)
	end
end

local function half_to_float(h)
	local sign = bit.band(bit.rshift(h, 15), 1)
	local exponent = bit.band(bit.rshift(h, 10), 31)
	local mantissa = bit.band(h, 1023)
	local value

	if exponent == 0 then
		value = mantissa * 2 ^ -24
	elseif exponent == 31 then
		value = math.huge
	else
		value = (1 + mantissa / 1024) * 2 ^ (exponent - 15)
	end

	return sign == 1 and -value or value
end

local function oct_encode(x, y, z)
	local l = math.abs(x) + math.abs(y) + math.abs(z)
	x, y, z = x / l, y / l, z / l
	local px, py = x, y

	if z < 0 then
		px = (1 - math.abs(y)) * (x >= 0 and 1 or -1)
		py = (1 - math.abs(x)) * (y >= 0 and 1 or -1)
	end

	return px * 0.5 + 0.5, py * 0.5 + 0.5
end

-- Reads back a cascade's atlases and returns a function that decodes one
-- probe: offset, enabled, mean radiance and the visibility mean toward a
-- direction. Slow, for debugging only.
function voxel_gi.ReadProbes(cascade_index)
	local cascade = voxel_gi.cascades[cascade_index or 1]

	if not cascade then return nil end

	local irradiance = cascade.irradiance:Download()
	local visibility = cascade.visibility:Download()
	local info = cascade.info:Download()
	local irr_pixels = ffi.cast("uint16_t*", irradiance.pixels)
	local vis_pixels = ffi.cast("uint16_t*", visibility.pixels)
	local info_pixels = ffi.cast("uint16_t*", info.pixels)
	local tile = voxel_gi.IRRADIANCE_OCT_SIZE
	local vis_tile = voxel_gi.VISIBILITY_OCT_SIZE
	local counts = {voxel_gi.PROBE_COUNT_X, voxel_gi.PROBE_COUNT_Y, voxel_gi.PROBE_COUNT_Z}

	return function(gx, gy, gz)
		local sx, sy, sz = gx % counts[1], gy % counts[2], gz % counts[3]
		local tile_x, tile_y = sx, sy * counts[3] + sz
		local info_index = (tile_y * info.width + tile_x) * 4
		local probe = {
			grid = Vec3(gx, gy, gz),
			position = Vec3(gx * cascade.spacing, gy * cascade.spacing, gz * cascade.spacing),
			offset = Vec3(
				half_to_float(info_pixels[info_index]),
				half_to_float(info_pixels[info_index + 1]),
				half_to_float(info_pixels[info_index + 2])
			),
			enabled = half_to_float(info_pixels[info_index + 3]) > 0.0,
			backface_fraction = math.abs(
				half_to_float(info_pixels[info_index + 3]) > 0 and
					half_to_float(info_pixels[info_index + 3]) - 1 or
					half_to_float(info_pixels[info_index + 3])
			),
		}
		local r, g, b = 0, 0, 0

		for ty = 0, tile - 1 do
			for tx = 0, tile - 1 do
				local index = ((tile_y * tile + ty) * irradiance.width + tile_x * tile + tx) * 4
				r = r + half_to_float(irr_pixels[index])
				g = g + half_to_float(irr_pixels[index + 1])
				b = b + half_to_float(irr_pixels[index + 2])
			end
		end

		probe.mean_radiance = Vec3(r / (tile * tile), g / (tile * tile), b / (tile * tile))

		function probe.irradiance(x, y, z)
			local u, v = oct_encode(x, y, z)
			local tx = math.min(math.floor(u * tile), tile - 1)
			local ty = math.min(math.floor(v * tile), tile - 1)
			local index = ((tile_y * tile + ty) * irradiance.width + tile_x * tile + tx) * 4
			return Vec3(
				half_to_float(irr_pixels[index]),
				half_to_float(irr_pixels[index + 1]),
				half_to_float(irr_pixels[index + 2])
			)
		end

		function probe.visibility(x, y, z)
			local u, v = oct_encode(x, y, z)
			local tx = math.min(math.floor(u * vis_tile), vis_tile - 1)
			local ty = math.min(math.floor(v * vis_tile), vis_tile - 1)
			local index = ((tile_y * vis_tile + ty) * visibility.width + tile_x * vis_tile + tx) * 2
			return half_to_float(vis_pixels[index]), half_to_float(vis_pixels[index + 1])
		end

		return probe
	end
end

-- Prints the resolved voxel color and normal around a world position
-- (clipmap 1, a column of voxels along y). Debugging only.
function voxel_gi.DumpVoxelColumn(position, half_height)
	local info = voxel_gi.clip_info and voxel_gi.clip_info[1]
	local resolved = voxel_gi.resolved[1]

	if not info or not info.valid or not resolved then return end

	local vs = info.voxel_size
	local min_x = info.origin.x - info.world_span * 0.5
	local min_y = info.origin.y - info.world_span * 0.5
	local min_z = info.origin.z - info.world_span * 0.5
	local vx = math.floor((position.x - min_x) / vs)
	local vz = math.floor((position.z - min_z) / vs)
	local y0 = math.floor((position.y - half_height - min_y) / vs)
	local y1 = math.floor((position.y + half_height - min_y) / vs)
	-- the resolved volume stores voxel (x, y, z) at pixel (x, y) of layer z
	local color = resolved.texture:Download{base_array_layer = vz}
	local normal = resolved.normal_texture:Download{base_array_layer = vz}
	local cp = ffi.cast("uint16_t*", color.pixels)
	local np = ffi.cast("uint8_t*", normal.pixels)
	-- occupancy is the flattened 2d copy the lighting pass marches through
	local occupancy = resolved.occupancy and resolved.occupancy:Download()
	local op = occupancy and ffi.cast("uint8_t*", occupancy.pixels)
	local tiles_x = resolved.tiles_x or 1

	for vy = y0, y1 do
		if vy >= 0 and vy < info.resolution then
			local ci = (vy * color.width + vx) * 4
			local ni = (vy * normal.width + vx) * 4
			local occ = -1

			if op then
				local ox = (vz % tiles_x) * info.resolution + vx
				local oy = math.floor(vz / tiles_x) * info.resolution + vy
				occ = op[oy * occupancy.width + ox] / 255
			end

			logf(
				"[voxel_gi] voxel (%d %d %d) y=[%.2f %.2f) occupancy=%.2f color=(%.2f %.2f %.2f a=%.2f) normal=(%.2f %.2f %.2f a=%.2f)\n",
				vx,
				vy,
				vz,
				min_y + vy * vs,
				min_y + (vy + 1) * vs,
				occ,
				half_to_float(cp[ci]),
				half_to_float(cp[ci + 1]),
				half_to_float(cp[ci + 2]),
				half_to_float(cp[ci + 3]),
				np[ni] / 255 * 2 - 1,
				np[ni + 1] / 255 * 2 - 1,
				np[ni + 2] / 255 * 2 - 1,
				np[ni + 3] / 255
			)
		end
	end
end

function voxel_gi.DumpProbesNear(position, radius, cascade_index)
	cascade_index = cascade_index or 1
	local cascade = voxel_gi.cascades[cascade_index]
	local read = voxel_gi.ReadProbes(cascade_index)

	if not read then return end

	local spacing = cascade.spacing
	local origin = cascade.grid_origin
	local counts = {voxel_gi.PROBE_COUNT_X, voxel_gi.PROBE_COUNT_Y, voxel_gi.PROBE_COUNT_Z}

	for y = 0, counts[2] - 1 do
		for z = 0, counts[3] - 1 do
			for x = 0, counts[1] - 1 do
				local gx, gy, gz = origin.x + x, origin.y + y, origin.z + z
				local p = Vec3(gx * spacing, gy * spacing, gz * spacing)

				if (p - position):GetLength() <= radius then
					local probe = read(gx, gy, gz)
					local up = probe.irradiance(0, 1, 0)
					local down_mean = probe.visibility(0, -1, 0)
					local x_mean = probe.visibility(1, 0, 0)
					logf(
						"[voxel_gi] probe (%d %d %d) pos=(%.1f %.1f %.1f) offset=(%.2f %.2f %.2f) enabled=%s backface=%.2f mean=(%.3f %.3f %.3f) up=(%.3f %.3f %.3f) vis_down=%.2f vis_x=%.2f\n",
						gx,
						gy,
						gz,
						p.x,
						p.y,
						p.z,
						probe.offset.x,
						probe.offset.y,
						probe.offset.z,
						tostring(probe.enabled),
						probe.backface_fraction,
						probe.mean_radiance.x,
						probe.mean_radiance.y,
						probe.mean_radiance.z,
						up.x,
						up.y,
						up.z,
						down_mean,
						x_mean
					)
				end
			end
		end
	end
end

-- Draws a small sphere per probe near the camera, colored by the probe's
-- mean stored radiance. Disabled probes are drawn dark red.
function voxel_gi.DrawDebugProbes()
	if not voxel_gi.debug_probes or not voxel_gi.IsActive() then return end

	local debug_draw = import("goluwa/debug_draw.lua")
	local cascade_index = voxel_gi.debug_probes_cascade or 1
	local cascade = voxel_gi.cascades[cascade_index]

	if not cascade then return end

	voxel_gi.debug_probe_frame = (voxel_gi.debug_probe_frame or 0) + 1

	if voxel_gi.debug_probe_frame % 10 ~= 1 then return end

	local irradiance = cascade.irradiance:Download()
	local info = cascade.info:Download()
	local irr_pixels = ffi.cast("uint16_t*", irradiance.pixels)
	local info_pixels = ffi.cast("uint16_t*", info.pixels)
	local tile = voxel_gi.IRRADIANCE_OCT_SIZE
	local atlas_width = irradiance.width
	local counts = {voxel_gi.PROBE_COUNT_X, voxel_gi.PROBE_COUNT_Y, voxel_gi.PROBE_COUNT_Z}
	local origin = cascade.grid_origin
	local spacing = cascade.spacing
	local camera_position = render3d.GetRenderCamera():GetPosition()
	local radius = voxel_gi.debug_probes_radius or (spacing * 8)
	local exposure = voxel_gi.debug_probes_exposure or 1
	local drawn = 0

	for y = 0, counts[2] - 1 do
		for z = 0, counts[3] - 1 do
			for x = 0, counts[1] - 1 do
				local gx, gy, gz = origin.x + x, origin.y + y, origin.z + z
				local px, py, pz = gx * spacing, gy * spacing, gz * spacing
				local dx, dy, dz = px - camera_position.x, py - camera_position.y, pz - camera_position.z

				if dx * dx + dy * dy + dz * dz < radius * radius then
					local sx, sy, sz = gx % counts[1], gy % counts[2], gz % counts[3]
					local tile_x, tile_y = sx, sy * counts[3] + sz
					local info_index = (tile_y * info.width + tile_x) * 4
					local ox = half_to_float(info_pixels[info_index])
					local oy = half_to_float(info_pixels[info_index + 1])
					local oz = half_to_float(info_pixels[info_index + 2])
					local enabled = half_to_float(info_pixels[info_index + 3]) > 0.0
					local r, g, b = 0, 0, 0

					for ty = 0, tile - 1 do
						for tx = 0, tile - 1 do
							local index = ((tile_y * tile + ty) * atlas_width + tile_x * tile + tx) * 4
							r = r + half_to_float(irr_pixels[index])
							g = g + half_to_float(irr_pixels[index + 1])
							b = b + half_to_float(irr_pixels[index + 2])
						end
					end

					local scale = exposure / (tile * tile)
					local color = enabled and
						Color(math.min(r * scale, 1), math.min(g * scale, 1), math.min(b * scale, 1), 1) or
						Color(0.4, 0, 0, 1)
					drawn = drawn + 1
					debug_draw.DrawSphere{
						id = "voxel_gi_probe_" .. cascade_index .. "_" .. sx .. "_" .. sy .. "_" .. sz,
						position = Vec3(px + ox, py + oy, pz + oz),
						radius = spacing * 0.08,
						color = color,
						emissive = color,
						ignore_z = true,
						translucent = true,
						double_sided = true,
						time = 2.0,
					}
				end
			end
		end
	end

	voxel_gi.debug_probes_drawn = drawn
end

event.AddListener("Update", "voxel_gi_debug_probes", function()
	voxel_gi.DrawDebugProbes()
end)

commands.Add("voxel_gi_probes=boolean[true],number[1]", function(enabled, cascade_index)
	voxel_gi.debug_probes = enabled
	voxel_gi.debug_probes_cascade = cascade_index
	logf(
		"[voxel_gi] probe overlay %s cascade %d\n",
		enabled and "enabled" or "disabled",
		cascade_index
	)
end)

commands.Add("voxel_gi=boolean[true]", function(enabled)
	voxel_gi.SetEnabled(enabled)
	logf("[voxel_gi] %s\n", enabled and "enabled" or "disabled")
end)

commands.Add("voxel_gi_occlusion=boolean[true]", function(enabled)
	voxel_gi.occlusion_enabled = enabled ~= false
	logf(
		"[voxel_gi] probe occlusion %s\n",
		voxel_gi.occlusion_enabled and "enabled" or "disabled"
	)
end)

commands.Add("voxel_gi_visibility=boolean[true]", function(enabled)
	voxel_gi.visibility_enabled = enabled ~= false
	logf(
		"[voxel_gi] probe visibility weighting %s\n",
		voxel_gi.visibility_enabled and "enabled" or "disabled"
	)
end)

commands.Add("voxel_gi_debug=number[1]", function(mode)
	voxel_gi.debug_mode = mode
	logf("[voxel_gi] debug mode %d\n", mode)
end)

commands.Add("voxel_gi_dump", function()
	voxel_gi.Dump()
end)

commands.Add("voxel_gi_invalidate", function()
	voxel_gi.Invalidate()
end)

if HOTRELOAD then voxel_gi.RemoveResources() end

return voxel_gi
