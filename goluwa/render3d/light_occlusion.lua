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
-- Per light octahedral maps of the distance to the nearest hit, stored as
-- the mean and mean square over a blurred neighbourhood of directions so a
-- lookup can estimate how much of that neighbourhood hides a point
-- (Chebyshev, like variance shadow maps). The blur trades accuracy for soft
-- edges that don't show the map's low resolution.
light_occlusion.oct_size = 128
light_occlusion.subs = 1
light_occlusion.bias = 0.01
-- blur radius in texels
light_occlusion.blur = 1.5
-- how much of the Chebyshev bound's tail is cut off, against light bleeding
-- through where occluders at different distances overlap
light_occlusion.bleed_reduction = 0.5
local LIGHT_OCCL_MAX_TRACES_PER_FRAME = 4
local LIGHT_OCCL_RETRACE_INTERVAL = 4
local LIGHT_OCCL_MOVE_TOLERANCE_SQ = 0.02 * 0.02
local MAX_LIGHTS = scene_lights.MAX_LIGHTS
local BINDING_UNIFORM = 0
local BINDING_MAP = 1
local BINDING_BVH_NODES = 2
local BINDING_BVH_TRIANGLES = 3
local BINDING_BLUR_SRC = 1
local BINDING_BLUR_DST = 2

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

local function create_map_texture(size, layers, debug_name, usage, sampler)
	local texture = Texture.New{
		width = size,
		height = size,
		format = "r32g32_sfloat",
		mip_map_levels = 1,
		image = {
			array_layers = layers,
			usage = usage,
		},
		view = {
			view_type = "2d_array",
			layer_count = layers,
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
-- every light whose range overlaps one of them as stale. Invalidate bumps the
-- version before the rebuild, so while one is pending the boxes wait for it,
-- or the lights would be retraced against the old tree and never again.
local function process_geometry_change(lights)
	local version = scene_bvh.version

	if geom_version == version or scene_bvh.dirty_since then return end

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
				local range = light:GetEffectiveRange()
				local radius_sq = range * range

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
					{"slot_at_z", "int", LIGHT_OCCL_MAX_TRACES_PER_FRAME},
					{"oct_size", "int"},
				},
				write = function(self, block)
					local lights = render3d.GetLights()

					for i = 0, MAX_LIGHTS - 1 do
						local light = lights[i + 1]

						if is_occlusion_light(light) then
							light.Owner.transform:GetPosition():CopyToFloatPointer(block.oct_positions[i])
							block.oct_positions[i][3] = light:GetEffectiveRange()
						else
							block.oct_positions[i][0] = 0
							block.oct_positions[i][1] = 0
							block.oct_positions[i][2] = 0
							block.oct_positions[i][3] = 0
						end
					end

					for i = 0, LIGHT_OCCL_MAX_TRACES_PER_FRAME - 1 do
						block.slot_at_z[i] = slot_at_z[i + 1] or 0
					end

					block.oct_size = get_map_size()
					return block
				end,
			},
		},
		custom_declarations = (
				[[
			layout(set = 0, binding = %d, rg32f) uniform writeonly image2DArray light_oct_map;
		]]
			):format(BINDING_MAP) .. scene_bvh.GetDeclarationsGLSL(BINDING_BVH_NODES, BINDING_BVH_TRIANGLES),
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
				int size = oct_data.oct_size;

				if (p.x >= size || p.y >= size) return;

				// a ray that hits nothing counts as a hit at the range
				vec2 moments = vec2(0.0);
				vec2 uv0 = vec2(p) / float(size);
				vec2 uv_step = vec2(1.0) / (float(size) * float(LIGHT_OCCL_SUBS));
				scene_bvh_hit hit;

				for (int sy = 0; sy < LIGHT_OCCL_SUBS; sy++) {
					for (int sx = 0; sx < LIGHT_OCCL_SUBS; sx++) {
						vec3 dir = light_oct_decode(uv0 + (vec2(sx, sy) + 0.5) * uv_step);
						float dist = scene_bvh_trace(light.xyz, dir, LIGHT_OCCL_T_MIN, light.w, hit) ? hit.distance : light.w;
						moments += vec2(dist, dist * dist);
					}
				}

				imageStore(light_oct_map, ivec3(p, slot), vec4(moments / float(LIGHT_OCCL_SUBS * LIGHT_OCCL_SUBS), 0.0, 0.0));
			}
		]]
			),
	}
end

-- One gaussian pass along x or y over the maps just traced: horizontal reads
-- the light's layer and writes the scratch layer, vertical writes it back.
-- A texel past an edge of the octahedral map is the one mirrored across that
-- edge's midpoint, the direction the edge folds onto.
local function build_blur_pipeline(horizontal)
	return EasyPipeline.Compute{
		name = horizontal and "light_occlusion_blur_x" or "light_occlusion_blur_y",
		DescriptorSetCount = get_frame_span(),
		LocalSize = {x = 8, y = 8, z = 1},
		storage_images = {
			{binding_index = BINDING_BLUR_SRC},
			{binding_index = BINDING_BLUR_DST},
		},
		uniform_buffers = {
			{
				name = "blur_data",
				binding_index = BINDING_UNIFORM,
				block = {
					{"slot_at_z", "int", LIGHT_OCCL_MAX_TRACES_PER_FRAME},
					{"oct_size", "int"},
					{"radius", "int"},
				},
				write = function(self, block)
					for i = 0, LIGHT_OCCL_MAX_TRACES_PER_FRAME - 1 do
						block.slot_at_z[i] = slot_at_z[i + 1] or 0
					end

					block.oct_size = get_map_size()
					block.radius = math.ceil(light_occlusion.blur)
					return block
				end,
			},
		},
		custom_declarations = ([[
			layout(set = 0, binding = %d, rg32f) uniform readonly image2DArray blur_src;
			layout(set = 0, binding = %d, rg32f) uniform writeonly image2DArray blur_dst;
		]]):format(BINDING_BLUR_SRC, BINDING_BLUR_DST),
		shader = [[
			const bool HORIZONTAL = ]] .. tostring(horizontal) .. [[;
			const float SIGMA = ]] .. string.format("%.4f", math.max(light_occlusion.blur, 0.5) * 0.5 + 0.25) .. [[;

			ivec2 oct_wrap(ivec2 p, int n) {
				if (p.x < 0) {
					p = ivec2(-p.x - 1, n - 1 - p.y);
				} else if (p.x >= n) {
					p = ivec2(2 * n - 1 - p.x, n - 1 - p.y);
				}

				if (p.y < 0) {
					p = ivec2(n - 1 - p.x, -p.y - 1);
				} else if (p.y >= n) {
					p = ivec2(n - 1 - p.x, 2 * n - 1 - p.y);
				}

				return p;
			}

			void main() {
				ivec2 p = ivec2(gl_GlobalInvocationID.xy);
				int n = blur_data.oct_size;

				if (p.x >= n || p.y >= n) return;

				int z = int(gl_GlobalInvocationID.z);
				int slot = blur_data.slot_at_z[z];
				int src_layer = HORIZONTAL ? slot : z;
				int dst_layer = HORIZONTAL ? z : slot;
				ivec2 axis = HORIZONTAL ? ivec2(1, 0) : ivec2(0, 1);
				vec2 sum = vec2(0.0);
				float weight_sum = 0.0;

				for (int i = -blur_data.radius; i <= blur_data.radius; i++) {
					float w = exp(-float(i * i) / (2.0 * SIGMA * SIGMA));
					sum += imageLoad(blur_src, ivec3(oct_wrap(p + axis * i, n), src_layer)).rg * w;
					weight_sum += w;
				}

				imageStore(blur_dst, ivec3(p, dst_layer), vec4(sum / weight_sum, 0.0, 0.0));
			}
		]],
	}
end

local function ensure_map_texture()
	if not light_occlusion.map_texture then
		local size = light_occlusion.oct_size
		light_occlusion.map_texture = create_map_texture(
			size,
			MAX_LIGHTS,
			"light_occlusion_map",
			{"sampled", "storage", "transfer_src", "transfer_dst"},
			MAP_SAMPLER_CONFIG
		)
		light_occlusion.scratch_texture = create_map_texture(
			size,
			LIGHT_OCCL_MAX_TRACES_PER_FRAME,
			"light_occlusion_blur_scratch",
			{"storage"},
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

	if not light_occlusion.blur_pipelines then
		light_occlusion.blur_pipelines = {build_blur_pipeline(true), build_blur_pipeline(false)}
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
			local range = light:GetEffectiveRange()

			if render3d.SphereInFrustum(pos.x, pos.y, pos.z, range) then
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
					elseif info.range < range - 1e-4 then
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
	local scratch_texture = light_occlusion.scratch_texture
	local slot = get_descriptor_slot()
	render.TransitionResourceToComputeStorage(map_texture, {cmd = cmd, base_array_layer = 0, layer_count = MAX_LIGHTS})
	render.TransitionResourceToComputeStorage(
		scratch_texture,
		{cmd = cmd, base_array_layer = 0, layer_count = LIGHT_OCCL_MAX_TRACES_PER_FRAME}
	)
	pipeline:UpdateDescriptorSet("storage_image", slot, BINDING_MAP, 0, map_texture:GetView())
	scene_bvh.BindBuffers(pipeline, slot, BINDING_BVH_NODES, BINDING_BVH_TRIANGLES)
	pipeline:UploadConstants()
	local size = get_map_size()
	light_occlusion.last_dispatches = dirty_count
	gpu_timing.BeginScope(cmd, "light_occlusion")
	pipeline.pipeline:Dispatch(
		cmd,
		math.ceil(size / 8),
		math.ceil(size / 8),
		dirty_count,
		slot,
		pipeline.dynamic_offsets
	)

	if light_occlusion.blur > 0 then
		for pass = 1, 2 do
			local blur = light_occlusion.blur_pipelines[pass]
			local src, dst = map_texture, scratch_texture

			if pass == 2 then src, dst = scratch_texture, map_texture end

			cmd:PipelineBarrier{
				srcStage = "compute",
				dstStage = "compute",
				imageBarriers = {
					{
						image = src:GetImage(),
						oldLayout = "general",
						newLayout = "general",
						srcAccessMask = "shader_write",
						dstAccessMask = "shader_read",
					},
					{
						image = dst:GetImage(),
						oldLayout = "general",
						newLayout = "general",
						srcAccessMask = "shader_read",
						dstAccessMask = "shader_write",
					},
				},
			}
			blur:UpdateDescriptorSet("storage_image", slot, BINDING_BLUR_SRC, 0, src:GetView())
			blur:UpdateDescriptorSet("storage_image", slot, BINDING_BLUR_DST, 0, dst:GetView())
			blur:UploadConstants()
			blur.pipeline:Dispatch(
				cmd,
				math.ceil(size / 8),
				math.ceil(size / 8),
				dirty_count,
				slot,
				blur.dynamic_offsets
			)
		end
	end

	gpu_timing.EndScope(cmd, "light_occlusion")
	render.TransitionResourceFrom(
		map_texture,
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

	for i = 1, dirty_count do
		local light_index = slot_at_z[i] + 1
		local light = lights[light_index]
		local pos = light.Owner.transform:GetPosition()
		state[light_index] = {
			light = light,
			x = pos.x,
			y = pos.y,
			z = pos.z,
			range = light:GetEffectiveRange(),
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
		bleed_reduction = light_occlusion.bleed_reduction,
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
			local range = light:GetEffectiveRange()
			out.lights[#out.lights + 1] = {
				index = light_index - 1,
				name = light.Owner.Name or ("light" .. light_index),
				x = pos.x,
				y = pos.y,
				z = pos.z,
				range = range,
				stamp = stamp,
				dispatched = info and info.stamp_dispatched or 0,
				pending = stamp > (info and info.stamp_dispatched or 0),
				geom_stale = geom_stale[light_index] ~= nil,
				in_frustum = render3d.SphereInFrustum(pos.x, pos.y, pos.z, range),
			}
		end
	end

	return out
end

function light_occlusion.GetOcclusionTexture()
	ensure_map_texture()
	return light_occlusion.map_texture
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
		{"bvh_oct_bleed_reduction", "float"},
	}
end

-- lights is render3d.GetLights, which the occlusion maps and their state are
-- keyed by
function light_occlusion.WriteOcclusionBlock(block, lights)
	for i = 0, MAX_LIGHTS - 1 do
		block.bvh_oct_slot[i] = -1
	end

	local active = 0

	if scene_bvh.IsReady() and scene_bvh.LightOcclusion ~= false then
		for light_index = 1, math.min(#lights, MAX_LIGHTS) do
			local info = state[light_index]

			if info and info.light == lights[light_index] then
				block.bvh_oct_slot[light_index - 1] = light_index - 1
				active = 1
			end
		end
	end

	block.bvh_oct_active = active
	block.bvh_oct_size = get_map_size()
	block.bvh_oct_bias = light_occlusion.bias
	block.bvh_oct_bleed_reduction = light_occlusion.bleed_reduction
end

function light_occlusion.GetSamplingGLSL(data_block)
	return (
			[[
		const int LIGHT_OCCL_MAX_SLOTS = ]] .. MAX_LIGHTS .. [[;

		]] .. octahedral_glsl() .. [[

		float light_oct_shadow_factor(int slot, vec3 light_pos, float range, vec3 world_pos) {
			if (slot < 0 || slot >= LIGHT_OCCL_MAX_SLOTS || ]] .. data_block .. [[.bvh_oct_active == 0) return 1.0;
			vec3 to_pos = world_pos - light_pos;
			float dist = length(to_pos);

			if (dist >= range) return 1.0;

			vec2 moments = texture(light_oct_map, vec3(light_oct_encode(to_pos / max(dist, 1e-5)), float(slot))).rg;

			// 0 means the map was never traced (it is zero initialized) and is
			// assumed clear, it will be traced on the next dispatch
			if (moments.x <= 0.0) return 1.0;

			float bias = ]] .. data_block .. [[.bvh_oct_bias;
			float d = dist - moments.x * (1.0 + bias);

			if (d <= 0.0) return 1.0;

			float min_std = moments.x * bias;
			float variance = max(moments.y - moments.x * moments.x, min_std * min_std);
			float bleed = ]] .. data_block .. [[.bvh_oct_bleed_reduction;
			return clamp((variance / (variance + d * d) - bleed) / (1.0 - bleed), 0.0, 1.0);
		}
	]]
		)
end

commands.Add("light_occlusion_bias=number[0.01]", function(bias)
	light_occlusion.bias = bias
	logf("[light_occlusion] bias %g\n", bias)
end)

commands.Add("light_occlusion_blur=number[1.5]", function(blur)
	light_occlusion.blur = math.max(0, blur)
	light_occlusion.blur_pipelines = nil
	light_occlusion.Reset()
	logf("[light_occlusion] blur radius %.1f texels\n", light_occlusion.blur)
end)

commands.Add("light_occlusion_bleed_reduction=number[0.5]", function(amount)
	light_occlusion.bleed_reduction = math.clamp(amount, 0, 0.95)
	logf("[light_occlusion] bleed reduction %g\n", light_occlusion.bleed_reduction)
end)

commands.Add("light_occlusion_subs=number[1]", function(subs)
	light_occlusion.subs = math.clamp(math.floor(subs), 1, 32)

	if light_occlusion.trace_pipeline then
		light_occlusion.trace_pipeline = nil
		light_occlusion.Reset()
	end

	logf("[light_occlusion] sub rays per texel %d\n", light_occlusion.subs)
end)

commands.Add("light_occlusion_size=number[128]", function(size)
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
		"[light_occlusion] frame %d, %d occlusion lights, bias %g blur %g bleed reduction %g oct %d\n",
		debug_state.frame,
		#debug_state.lights,
		debug_state.bias,
		debug_state.blur,
		debug_state.bleed_reduction,
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
