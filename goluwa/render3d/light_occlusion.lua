local commands = import("goluwa/cli/commands.lua")
local render = import("goluwa/render/render.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local gpu_timing = import("goluwa/render/gpu_timing.lua")
local Texture = import("goluwa/render/texture.lua")
local EasyPipeline = import("goluwa/render/easy_pipeline.lua")
local scene_lights = import("goluwa/render3d/scene_lights.lua")
local scene_bvh = import("goluwa/render3d/scene_bvh.lua")
local system = import("goluwa/system.lua")
local light_occlusion = library()
light_occlusion.oct_size = 256
light_occlusion.subs = 1
light_occlusion.bias = 0.01
light_occlusion.blur = 0
light_occlusion.softness = 0
local LIGHT_OCCL_MAX_TRACES_PER_FRAME = 4
local LIGHT_OCCL_RETRACE_INTERVAL = 4
local LIGHT_OCCL_MOVE_TOLERANCE_SQ = 0.02 * 0.02
local MAX_LIGHTS = scene_lights.MAX_LIGHTS
local BINDING_UNIFORM = 0
local BINDING_MAP = 1
local BINDING_BVH_NODES = 2
local BINDING_BVH_TRIANGLES = 3
local BINDING_VERSION = 4

local function octahedral_glsl()
	return [[
		vec2 light_oct_encode(vec3 d) {
			d /= (abs(d.x) + abs(d.y) + abs(d.z));
			vec2 p = d.xy;

			if (d.z < 0.0) {
				p = (1.0 - abs(d.yx)) * vec2(d.x >= 0.0 ? 1.0 : -1.0, d.y >= 0.0 ? 1.0 : -1.0);
			}

			return p * 0.5 + 0.5;
		}

		vec3 light_oct_decode(vec2 uv) {
			vec2 p = uv * 2.0 - 1.0;
			vec3 d = vec3(p.x, p.y, 1.0 - abs(p.x) - abs(p.y));

			if (d.z < 0.0) {
				d.xy = (1.0 - abs(d.yx)) * vec2(p.x >= 0.0 ? 1.0 : -1.0, p.y >= 0.0 ? 1.0 : -1.0);
			}

			return normalize(d);
		}
	]]
end

local MAP_SAMPLER_CONFIG = {
	min_filter = "linear",
	mag_filter = "linear",
	wrap_s = "clamp_to_edge",
	wrap_t = "clamp_to_edge",
	wrap_r = "clamp_to_edge",
}

local function create_map_texture(size, format, debug_name, usage, sampler)
	local texture = Texture.New{
		width = size,
		height = size,
		format = format,
		mip_map_levels = 1,
		image = {
			array_layers = MAX_LIGHTS,
			usage = usage,
		},
		view = {
			view_type = "2d_array",
			layer_count = MAX_LIGHTS,
		},
		sampler = sampler,
	}
	texture:SetDebugName(debug_name)
	return texture
end

local function get_frame_span()
	return math.max(render.GetSwapchainImageCount() or 1, 1)
end

local function get_map_size()
	return light_occlusion.map_size or light_occlusion.oct_size
end

local function is_occlusion_light(light)
	return light ~= nil and
		light.OcclusionMap ~= false and
		(
			light.Type == "light_point" or
			light.Type == "light_spot"
		)
end

local state = {}
local stamps = {}
local move_frame = {}
local geom_stale = {}
local slot_at_z = {}
local geom_version = -1

local function sphere_overlaps_box(px, py, pz, radius_sq, box)
	local dx = math.max(box[1] - px, 0, px - box[4])
	local dy = math.max(box[2] - py, 0, py - box[5])
	local dz = math.max(box[3] - pz, 0, pz - box[6])
	return dx * dx + dy * dy + dz * dz <= radius_sq
end

-- consumes the boxes scene_bvh recorded while the tree was dirty and marks
-- every light whose range overlaps one of them as stale
local function process_geometry_change(lights)
	local version = scene_bvh.version

	if geom_version == version then return end

	geom_version = version
	local dirty_all = scene_bvh.dirty_all
	local boxes = scene_bvh.dirty_boxes or {}
	scene_bvh.dirty_all = false
	scene_bvh.dirty_boxes = {}

	for light_index = 1, math.min(#lights, MAX_LIGHTS) do
		local light = lights[light_index]

		if is_occlusion_light(light) then
			local stale = dirty_all

			if not stale then
				local pos = light.Owner.transform:GetPosition()
				local radius_sq = light.Range * light.Range

				for i = 1, #boxes do
					if sphere_overlaps_box(pos.x, pos.y, pos.z, radius_sq, boxes[i]) then
						stale = true

						break
					end
				end
			end

			if stale then geom_stale[light_index] = true end
		end
	end
end

local function build_trace_pipeline()
	return EasyPipeline.Compute{
		name = "light_occlusion_trace",
		DescriptorSetCount = get_frame_span(),
		LocalSize = {x = 8, y = 8, z = 1},
		storage_images = {
			{binding_index = BINDING_MAP},
			{binding_index = BINDING_VERSION},
		},
		storage_buffers = {
			{binding_index = BINDING_BVH_NODES},
			{binding_index = BINDING_BVH_TRIANGLES},
		},
		uniform_buffers = {
			{
				name = "oct_data",
				binding_index = BINDING_UNIFORM,
				block = {
					{"oct_positions", "vec4", MAX_LIGHTS},
					{"slot_at_z", "int", MAX_LIGHTS},
					{"occl_stamps", "int", MAX_LIGHTS},
					{"oct_size", "int"},
				},
				write = function(self, block)
					local lights = render3d.GetLights()

					for i = 0, MAX_LIGHTS - 1 do
						local light = lights[i + 1]

						if is_occlusion_light(light) then
							light.Owner.transform:GetPosition():CopyToFloatPointer(block.oct_positions[i])
							block.oct_positions[i][3] = light.Range
						else
							block.oct_positions[i][0] = 0
							block.oct_positions[i][1] = 0
							block.oct_positions[i][2] = 0
							block.oct_positions[i][3] = 0
						end

						block.slot_at_z[i] = slot_at_z[i + 1] or 0
						block.occl_stamps[i] = stamps[i + 1] or 0
					end

					block.oct_size = get_map_size()
					return block
				end,
			},
		},
		custom_declarations = (
				[[
			layout(set = 0, binding = %d, r32f) uniform writeonly image2DArray light_oct_map;
			layout(set = 0, binding = %d, r32ui) uniform uimage2DArray light_oct_version;
		]]
			):format(BINDING_MAP, BINDING_VERSION) .. scene_bvh.GetDeclarationsGLSL(BINDING_BVH_NODES, BINDING_BVH_TRIANGLES),
		shader = (
				[[
			const float LIGHT_OCCL_T_MIN = 0.05;

			]] .. octahedral_glsl() .. [[

			]] .. scene_bvh.GetTraversalGLSL() .. [[

			const int LIGHT_OCCL_SUBS = ]] .. light_occlusion.subs .. [[;

			void main() {
				ivec2 p = ivec2(gl_GlobalInvocationID.xy);
				int slot = oct_data.slot_at_z[gl_GlobalInvocationID.z];
				vec4 light = oct_data.oct_positions[slot];
				uint stamp = uint(oct_data.occl_stamps[slot]);
				int size = oct_data.oct_size;

				uint version = imageLoad(light_oct_version, ivec3(p, slot)).r;

				if (version >= stamp) return;

				float fsize = float(size);
				float dist = 0.0;
				bool clear = false;

				vec2 uv0 = vec2(p) / fsize;
				vec2 uv_step = vec2(1.0) / (fsize * float(LIGHT_OCCL_SUBS));
				scene_bvh_hit hit;

				for (int sy = 0; sy < LIGHT_OCCL_SUBS; sy++) {
					for (int sx = 0; sx < LIGHT_OCCL_SUBS; sx++) {
						vec2 uv = uv0 + (vec2(sx, sy) + 0.5) * uv_step;
						vec3 dir = light_oct_decode(uv);

						if (scene_bvh_trace(light.xyz, dir, LIGHT_OCCL_T_MIN, light.w, hit)) {
							dist = max(dist, hit.distance);
						} else {
							clear = true;
							sy = LIGHT_OCCL_SUBS;
						}
					}
				}

				if (clear) dist = light.w;

				imageStore(light_oct_map, ivec3(p, slot), vec4(dist));
				imageStore(light_oct_version, ivec3(p, slot), uvec4(stamp));
			}
		]]
			),
	}
end

local function ensure_map_texture()
	if not light_occlusion.map_texture then
		local size = light_occlusion.oct_size
		light_occlusion.map_texture = create_map_texture(
			size,
			"r32_sfloat",
			"light_occlusion_map",
			{"sampled", "storage", "transfer_src", "transfer_dst"},
			MAP_SAMPLER_CONFIG
		)
		light_occlusion.version_texture = create_map_texture(
			size,
			"r32_uint",
			"light_occlusion_version",
			{"sampled", "storage", "transfer_src"},
			nil
		)
		light_occlusion.map_size = size
	end
end

local function ensure_resources()
	ensure_map_texture()

	if not light_occlusion.trace_pipeline then
		light_occlusion.trace_pipeline = build_trace_pipeline()
	end
end

local function get_descriptor_slot()
	local frame = render.GetCurrentFrame() or 1
	return ((frame - 1) % get_frame_span()) + 1
end

light_occlusion.last_dispatches = 0

function light_occlusion.Draw(cmd)
	light_occlusion.last_dispatches = 0

	if not (scene_bvh.IsReady() and scene_bvh.LightOcclusion ~= false) then
		return
	end

	local lights = render3d.GetLights()
	local frame = system.GetFrameNumber()
	process_geometry_change(lights)
	local dirty_count = 0

	for light_index = 1, MAX_LIGHTS do
		local light = lights[light_index]

		if not is_occlusion_light(light) then
			state[light_index] = nil
			stamps[light_index] = nil
			move_frame[light_index] = nil
			geom_stale[light_index] = nil
			slot_at_z[light_index] = nil
		else
			local pos = light.Owner.transform:GetPosition()

			if render3d.SphereInFrustum(pos.x, pos.y, pos.z, light.Range) then
				local info = state[light_index]
				local stamp = stamps[light_index] or 0
				local mode = 0

				if (not info) or info.light ~= light then
					stamp = stamp + 1
					mode = 1
				else
					local pending = stamp > info.stamp_dispatched

					if geom_stale[light_index] then
						geom_stale[light_index] = nil

						if not pending then stamp = stamp + 1 end

						mode = 2
					elseif info.range < light.Range - 1e-4 then
						if not pending then stamp = stamp + 1 end

						mode = 2
					elseif
						(
							(
								pos.x - info.x
							) * (
								pos.x - info.x
							) + (
								pos.y - info.y
							) * (
								pos.y - info.y
							) + (
								pos.z - info.z
							) * (
								pos.z - info.z
							) > LIGHT_OCCL_MOVE_TOLERANCE_SQ and
							frame - (
								move_frame[light_index] or
								-LIGHT_OCCL_RETRACE_INTERVAL
							) >= LIGHT_OCCL_RETRACE_INTERVAL
						)
					then
						stamp = stamp + 1
						move_frame[light_index] = frame
						mode = 2
					elseif pending then
						mode = 2
					end
				end

				if mode ~= 0 then
					stamps[light_index] = stamp
					slot_at_z[dirty_count + 1] = light_index - 1
					dirty_count = dirty_count + 1
				end
			end
		end
	end

	if dirty_count == 0 then return end

	if dirty_count > LIGHT_OCCL_MAX_TRACES_PER_FRAME then
		dirty_count = LIGHT_OCCL_MAX_TRACES_PER_FRAME
	end

	ensure_resources()
	local pipeline = light_occlusion.trace_pipeline
	local map_texture = light_occlusion.map_texture
	local version_texture = light_occlusion.version_texture
	local slot = get_descriptor_slot()
	render.TransitionResourceToComputeStorage(map_texture, {cmd = cmd, base_array_layer = 0, layer_count = MAX_LIGHTS})
	render.TransitionResourceToComputeStorage(version_texture, {cmd = cmd, base_array_layer = 0, layer_count = MAX_LIGHTS})
	pipeline:UpdateDescriptorSet("storage_image", slot, BINDING_MAP, 0, map_texture:GetView())
	pipeline:UpdateDescriptorSet("storage_image", slot, BINDING_VERSION, 0, version_texture:GetView())
	scene_bvh.BindBuffers(pipeline, slot, BINDING_BVH_NODES, BINDING_BVH_TRIANGLES)
	pipeline:UploadConstants()
	local size = get_map_size()
	light_occlusion.last_dispatches = dirty_count
	gpu_timing.BeginScope(cmd, "light_occlusion")
	pipeline.pipeline:Dispatch(cmd, size, size, dirty_count, slot, pipeline.dynamic_offsets)
	gpu_timing.EndScope(cmd, "light_occlusion")

	for _, texture in ipairs({map_texture, version_texture}) do
		render.TransitionResourceFrom(
			texture,
			"shader_read_only_optimal",
			{
				cmd = cmd,
				srcStage = "compute",
				srcAccess = "shader_write",
				dstStage = "compute",
				dstAccess = "shader_read",
				base_array_layer = 0,
				layer_count = MAX_LIGHTS,
			}
		)
	end

	for i = 1, dirty_count do
		local light_index = slot_at_z[i] + 1
		local light = lights[light_index]
		local pos = light.Owner.transform:GetPosition()
		state[light_index] = {
			light = light,
			x = pos.x,
			y = pos.y,
			z = pos.z,
			range = light.Range,
			stamp_dispatched = stamps[light_index],
		}
	end
end

function light_occlusion.Reset()
	for k in pairs(state) do
		state[k] = nil
	end

	for k in pairs(move_frame) do
		move_frame[k] = nil
	end

	for k in pairs(geom_stale) do
		geom_stale[k] = nil
	end
end

-- per-light debug state for the console and the stress scene overlay
function light_occlusion.GetDebugState()
	local lights = render3d.GetLights()
	local out = {
		frame = system.GetFrameNumber(),
		bias = light_occlusion.bias,
		blur = light_occlusion.blur,
		softness = light_occlusion.softness,
		oct_size = get_map_size(),
		max_traces = LIGHT_OCCL_MAX_TRACES_PER_FRAME,
		lights = {},
	}

	for light_index = 1, MAX_LIGHTS do
		local light = lights[light_index]

		if is_occlusion_light(light) then
			local info = state[light_index]
			local stamp = stamps[light_index] or 0
			local pos = light.Owner.transform:GetPosition()
			out.lights[#out.lights + 1] = {
				index = light_index - 1,
				name = light.Owner.Name or ("light" .. light_index),
				x = pos.x,
				y = pos.y,
				z = pos.z,
				range = light.Range,
				stamp = stamp,
				dispatched = info and info.stamp_dispatched or 0,
				pending = stamp > (info and info.stamp_dispatched or 0),
				geom_stale = geom_stale[light_index] ~= nil,
				in_frustum = render3d.SphereInFrustum(pos.x, pos.y, pos.z, light.Range),
			}
		end
	end

	return out
end

function light_occlusion.GetOcclusionTexture()
	ensure_map_texture()
	return light_occlusion.map_texture
end

function light_occlusion.GetVersionTexture()
	ensure_map_texture()
	return light_occlusion.version_texture
end

function light_occlusion.GetDeclarationGLSL(binding, set)
	return (
		[[
		layout(set = %d, binding = %d) uniform sampler2DArray light_oct_map;
	]]
	):format(set or 0, binding)
end

local map_sampler

function light_occlusion.GetOcclusionDescriptor()
	local texture = light_occlusion.GetOcclusionTexture()

	if not map_sampler then
		map_sampler = render.CreateSampler(MAP_SAMPLER_CONFIG)
	end

	return {texture:GetView(), map_sampler}
end

function light_occlusion.GetBlockLayout()
	return {
		{"bvh_oct_slot", "int", MAX_LIGHTS},
		{"bvh_oct_active", "int"},
		{"bvh_oct_size", "int"},
		{"bvh_oct_bias", "float"},
		{"bvh_oct_blur", "float"},
		{"bvh_oct_softness", "float"},
	}
end

-- lights is the packed visible light list from scene_lights.GetVisibleLights,
-- instance_indices maps each packed slot back to its Light.Instances index,
-- which is what the occlusion maps and their state are keyed by
function light_occlusion.WriteOcclusionBlock(block, lights, instance_indices)
	for i = 0, MAX_LIGHTS - 1 do
		block.bvh_oct_slot[i] = -1
	end

	local active = 0

	if scene_bvh.IsReady() and scene_bvh.LightOcclusion ~= false then
		for packed_index = 1, #lights do
			local light = lights[packed_index]
			local light_index = instance_indices[packed_index]
			local info = state[light_index]

			if info and info.light == light then
				block.bvh_oct_slot[packed_index - 1] = light_index - 1
				active = 1
			end
		end
	end

	block.bvh_oct_active = active
	block.bvh_oct_size = get_map_size()
	block.bvh_oct_bias = light_occlusion.bias
	block.bvh_oct_blur = light_occlusion.blur
	block.bvh_oct_softness = light_occlusion.softness
end

function light_occlusion.GetSamplingGLSL(data_block)
	return (
			[[
		const int LIGHT_OCCL_MAX_SLOTS = ]] .. MAX_LIGHTS .. [[;

		]] .. octahedral_glsl() .. [[

		float light_oct_fetch(int slot, vec3 dir) {
			vec2 uv = light_oct_encode(dir);

			if (]] .. data_block .. [[.bvh_oct_blur <= 0.0) {
				return texture(light_oct_map, vec3(uv, float(slot))).r;
			}

			vec2 o = vec2(]] .. data_block .. [[.bvh_oct_blur / float(]] .. data_block .. [[.bvh_oct_size));
			return (
				texture(light_oct_map, vec3(uv, float(slot))).r +
				texture(light_oct_map, vec3(uv + vec2(o.x, 0.0), float(slot))).r +
				texture(light_oct_map, vec3(uv - vec2(o.x, 0.0), float(slot))).r +
				texture(light_oct_map, vec3(uv + vec2(0.0, o.y), float(slot))).r +
				texture(light_oct_map, vec3(uv - vec2(0.0, o.y), float(slot))).r
			) * 0.2;
		}

		float light_oct_shadow_factor(int slot, vec3 light_pos, float range, vec3 world_pos) {
			if (slot < 0 || slot >= LIGHT_OCCL_MAX_SLOTS || ]] .. data_block .. [[.bvh_oct_active == 0) return 1.0;
			vec3 to_pos = world_pos - light_pos;
			float dist = length(to_pos);

			if (dist >= range) return 1.0;

			float occl = light_oct_fetch(slot, to_pos / max(dist, 1e-5));

			// 0 means the texel was never traced (the map is zero initialized)
			// and is assumed clear, it will be traced on the next dispatch
			if (occl <= 0.0) return 1.0;

			if (]] .. data_block .. [[.bvh_oct_softness <= 0.0) {
				return dist > occl + occl * ]] .. data_block .. [[.bvh_oct_bias ? 0.0 : 1.0;
			}

			float margin = (dist - occl * (1.0 + ]] .. data_block .. [[.bvh_oct_bias)) /
				max(occl * ]] .. data_block .. [[.bvh_oct_softness, 1e-5);
			return 1.0 - smoothstep(0.0, 1.0, margin);
		}
	]]
		)
end

commands.Add("light_occlusion_bias=number[0.045]", function(bias)
	light_occlusion.bias = bias
	logf("[light_occlusion] bias %g\n", bias)
end)

commands.Add("light_occlusion_blur=number[0]", function(blur)
	light_occlusion.blur = math.max(0, blur)
	logf("[light_occlusion] blur radius %.1f texels\n", light_occlusion.blur)
end)

commands.Add("light_occlusion_softness=number[0]", function(softness)
	light_occlusion.softness = math.max(0, softness)
	logf("[light_occlusion] softness margin %g\n", light_occlusion.softness)
end)

commands.Add("light_occlusion_subs=number[1]", function(subs)
	light_occlusion.subs = math.clamp(math.floor(subs), 1, 32)

	if light_occlusion.trace_pipeline then
		light_occlusion.trace_pipeline = nil
		light_occlusion.Reset()
	end

	logf("[light_occlusion] sub rays per texel %d\n", light_occlusion.subs)
end)

commands.Add("light_occlusion_size=number[64]", function(size)
	light_occlusion.oct_size = math.clamp(math.floor(size), 16, 256)
	logf(
		"[light_occlusion] octahedral map size %d%s\n",
		light_occlusion.oct_size,
		light_occlusion.map_texture and " (current maps keep their size)" or ""
	)
end)

commands.Add("lo_debug", function()
	local debug_state = light_occlusion.GetDebugState()
	logf(
		"[light_occlusion] frame %d, %d occlusion lights, bias %g blur %g softness %g oct %d\n",
		debug_state.frame,
		#debug_state.lights,
		debug_state.bias,
		debug_state.blur,
		debug_state.softness,
		debug_state.oct_size
	)

	for _, light in ipairs(debug_state.lights) do
		logf(
			"  [%d] %-20s pos (%.1f %.1f %.1f) range %g stamp %d dispatched %d%s%s%s\n",
			light.index,
			light.name,
			light.x,
			light.y,
			light.z,
			light.range,
			light.stamp,
			light.dispatched,
			light.pending and " PENDING" or "",
			light.geom_stale and " GEOM_STALE" or "",
			light.in_frustum and "" or " OUT_OF_FRUSTUM"
		)
	end
end)

commands.Add("scene_bvh_light_occlusion=boolean[true]", function(enabled)
	scene_bvh.LightOcclusion = enabled ~= false
	logf(
		"[scene_bvh] light occlusion %s\n",
		scene_bvh.LightOcclusion and "enabled" or "disabled"
	)
end)

return light_occlusion
