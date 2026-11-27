local pvars = import("goluwa/cli/pvars.lua")
local render = import("goluwa/render/render.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local gpu_timing = import("goluwa/render/gpu_timing.lua")
local Texture = import("goluwa/render/texture.lua")
local EasyPipeline = import("goluwa/render/easy_pipeline.lua")
local hit = import("goluwa/render3d/scene/hit.lua")
local bridge = import("goluwa/render3d/scene/bridge.lua")
local instances = import("goluwa/render3d/scene/instances.lua")
local rt = import("goluwa/render3d/scene/rt.lua")
local glsl_common = import("goluwa/render3d/glsl_common.lua")
local system = import("goluwa/system.lua")
local light_occlusion = {}
light_occlusion.capacity = 64
pvars.StartGroup("Lighting", "Light occlusion", {store = false, prefix = "light_occlusion_"})
local enabled = pvars.Setup2{
	key = "light_occlusion",
	default = true,
	friendly = "enabled",
	help = "trace per light occlusion maps against the scene bvh",
}
local oct_size = pvars.Setup2{
	key = "light_occlusion_size",
	default = 128,
	integer = true,
	min = 16,
	max = 256,
	help = "octahedral map size in texels, maps that exist keep theirs",
}
local subs = pvars.Setup2{
	key = "light_occlusion_subs",
	default = 1,
	integer = true,
	min = 1,
	max = 32,
	help = "sub rays per texel",
	callback = function(_, is_init)
		if not is_init and light_occlusion.trace_pipeline then
			light_occlusion.trace_pipeline = nil
			light_occlusion.Reset()
		end
	end,
}
local bias = pvars.Setup2{
	key = "light_occlusion_bias",
	default = 0.01,
	min = 0,
	help = "variance bias of the Chebyshev test",
}
local blur = pvars.Setup2{
	key = "light_occlusion_blur",
	default = 1.5,
	min = 0,
	help = "blur radius of the maps in texels",
	callback = function(_, is_init)
		if is_init then return end

		light_occlusion.blur_pipelines = nil
		light_occlusion.Reset()
	end,
}
local soft = pvars.Setup2{
	key = "light_occlusion_soft",
	default = true,
	help = "point and spot lights with a source radius cast soft shadows: the penumbra widens with the distance between the occluder and what it shades, off every occlusion map shadow is as sharp as the map",
}
local contact = pvars.Setup2{
	key = "light_occlusion_contact",
	default = 3,
	min = 0,
	help = "length of a ray toward the light from points the map leaves lit, in map texels at the point's distance. catches thin walls and edges closer than the map can resolve, 0 is off",
}
local bleed_reduction = pvars.Setup2{
	key = "light_occlusion_bleed_reduction",
	default = 0.5,
	min = 0,
	max = 0.95,
	help = "how much of the Chebyshev bound's tail is cut off",
}
pvars.EndGroup()
local LIGHT_OCCL_MAX_TRACES_PER_FRAME = 4
local LIGHT_OCCL_RETRACE_INTERVAL = 4
local LIGHT_OCCL_MOVE_TOLERANCE_SQ = 0.02 * 0.02
local BINDING_UNIFORM = 0
local BINDING_MAP = 1
local BINDING_TLAS = 2
local BINDING_HIT = 3
local BINDING_BLUR_SRC = 1
local BINDING_BLUR_DST = 2
local BINDING_MIP_SRC = 1
local BINDING_MIP_DST = 2
local MAP_SAMPLER_CONFIG = {
	min_filter = "linear",
	mag_filter = "linear",
	wrap_s = "clamp_to_edge",
	wrap_t = "clamp_to_edge",
	wrap_r = "clamp_to_edge",
}

local function get_mip_count(size)
	return math.floor(math.log(size) / math.log(2) + 0.5) + 1
end

local function create_map_texture(size, layers, debug_name, usage, sampler, levels)
	local texture = Texture.New{
		width = size,
		height = size,
		format = "r32g32_sfloat",
		mip_map_levels = levels,
		image = {
			array_layers = layers,
			usage = usage,
		},
		view = {
			view_type = "2d_array",
			layer_count = layers,
			level_count = levels,
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
	return light_occlusion.map_size or oct_size:Get()
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
local chosen_light = {}
local chosen_score = {}
local UNTRACED_SCORE = -1e9

local function choose(light_index, score, chosen_count)
	local i = chosen_count + 1

	if i > LIGHT_OCCL_MAX_TRACES_PER_FRAME then
		if score >= chosen_score[LIGHT_OCCL_MAX_TRACES_PER_FRAME] then
			return chosen_count
		end

		i = LIGHT_OCCL_MAX_TRACES_PER_FRAME
		chosen_count = chosen_count - 1
	end

	while i > 1 and chosen_score[i - 1] > score do
		chosen_light[i] = chosen_light[i - 1]
		chosen_score[i] = chosen_score[i - 1]
		i = i - 1
	end

	chosen_light[i] = light_index
	chosen_score[i] = score
	return chosen_count + 1
end

local function sphere_overlaps_box(px, py, pz, radius_sq, box)
	local dx = math.max(box[1] - px, 0, px - box[4])
	local dy = math.max(box[2] - py, 0, py - box[5])
	local dz = math.max(box[3] - pz, 0, pz - box[6])
	return dx * dx + dy * dy + dz * dz <= radius_sq
end

local dirty_queue = bridge.CreateDirtyQueue()

local function process_geometry_change(lights)
	local dirty_all, boxes = bridge.ConsumeDirty(dirty_queue)

	if not dirty_all and not boxes[1] then return end

	for light_index = 1, math.min(#lights, light_occlusion.capacity) do
		local light = lights[light_index]

		if is_occlusion_light(light) then
			local stale = dirty_all

			if not stale then
				local pos = light.Owner.transform:GetWorldPosition()
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
		storage_buffers = {},
		descriptor_sets = hit.IsSupported() and
			hit.GetDescriptorSets(BINDING_HIT, "compute", BINDING_TLAS) or
			nil,
		uniform_buffers = {
			{
				name = "oct_data",
				binding_index = BINDING_UNIFORM,
				block = {
					{"trace_positions", "vec4", LIGHT_OCCL_MAX_TRACES_PER_FRAME},
					{"slot_at_z", "int", LIGHT_OCCL_MAX_TRACES_PER_FRAME},
					{"oct_size", "int"},
				},
				write = function(self, block)
					local lights = render3d.GetLights()

					for i = 0, LIGHT_OCCL_MAX_TRACES_PER_FRAME - 1 do
						local slot = slot_at_z[i + 1] or 0
						local light = lights[slot + 1]
						block.slot_at_z[i] = slot

						if is_occlusion_light(light) then
							light.Owner.transform:GetWorldPosition():CopyToFloatPointer(block.trace_positions[i])
							block.trace_positions[i][3] = light:GetEffectiveRange()
						else
							block.trace_positions[i][0] = 0
							block.trace_positions[i][1] = 0
							block.trace_positions[i][2] = 0
							block.trace_positions[i][3] = 0
						end
					end

					block.oct_size = get_map_size()
					return block
				end,
			},
		},
		custom_declarations = (
				hit.IsSupported() and
				hit.GetSceneGLSL("light_occlusion_scene", BINDING_TLAS) .. hit.GetGLSL(BINDING_HIT)
				or
				""
			) .. (
				[[
			layout(set = 0, binding = %d, rg32f) uniform writeonly image2DArray light_oct_map;
		]]
			):format(BINDING_MAP),
		shader = (
				[[
			const float LIGHT_OCCL_T_MIN = 0.05;

			]] .. glsl_common.GetOctahedralGLSL() .. [[

			]] .. (
					hit.IsSupported() and
					hit.GetTraceGLSL("light_occlusion_scene", instances.MASK_LIGHT_BODY) or
					hit.GetStubTraceGLSL()
				) .. [[

			const int LIGHT_OCCL_SUBS = ]] .. subs:Get() .. [[;

			void main() {
				ivec2 p = ivec2(gl_GlobalInvocationID.xy);
				int slot = oct_data.slot_at_z[gl_GlobalInvocationID.z];
				vec4 light = oct_data.trace_positions[gl_GlobalInvocationID.z];
				int size = oct_data.oct_size;

				if (p.x >= size || p.y >= size) return;

				vec2 moments = vec2(0.0);
				vec2 uv0 = vec2(p) / float(size);
				vec2 uv_step = vec2(1.0) / (float(size) * float(LIGHT_OCCL_SUBS));
				scene_trace_hit hit;

				for (int sy = 0; sy < LIGHT_OCCL_SUBS; sy++) {
					for (int sx = 0; sx < LIGHT_OCCL_SUBS; sx++) {
						vec3 dir = oct_decode((uv0 + (vec2(sx, sy) + 0.5) * uv_step) * 2.0 - 1.0);
						float dist = scene_trace(light.xyz, dir, LIGHT_OCCL_T_MIN, light.w, hit) ? hit.distance : light.w;
						moments += vec2(dist, dist * dist);
					}
				}

				imageStore(light_oct_map, ivec3(p, slot), vec4(moments / float(LIGHT_OCCL_SUBS * LIGHT_OCCL_SUBS), 0.0, 0.0));
			}
		]]
			),
	}
end

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
					block.radius = math.ceil(blur:Get())
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
			const float SIGMA = ]] .. string.format("%.4f", math.max(blur:Get(), 0.5) * 0.5 + 0.25) .. [[;

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

local function build_mip_pipeline(levels)
	local storage_images = {{binding_index = BINDING_MIP_SRC}}
	local declarations = {
		(
			"layout(set = 0, binding = %d, rg32f) uniform readonly image2DArray mip_src;"
		):format(BINDING_MIP_SRC),
	}
	local stores = {}

	for level = 1, levels - 1 do
		storage_images[#storage_images + 1] = {binding_index = BINDING_MIP_DST + level - 1}
		declarations[#declarations + 1] = (
			"layout(set = 0, binding = %d, rg32f) uniform writeonly image2DArray mip_%d;"
		):format(BINDING_MIP_DST + level - 1, level)
		stores[#stores + 1] = (
			"if (level == %d) imageStore(mip_%d, ivec3(p, slot), vec4(sum, 0.0, 0.0));"
		):format(level, level)
	end

	return EasyPipeline.Compute{
		name = "light_occlusion_mips",
		DescriptorSetCount = get_frame_span(),
		LocalSize = {x = 8, y = 8, z = 1},
		storage_images = storage_images,
		uniform_buffers = {
			{
				name = "mip_data",
				binding_index = BINDING_UNIFORM,
				block = {
					{"slot_at_z", "int", LIGHT_OCCL_MAX_TRACES_PER_FRAME},
					{"slot_count", "int"},
				},
				write = function(self, block)
					for i = 0, LIGHT_OCCL_MAX_TRACES_PER_FRAME - 1 do
						block.slot_at_z[i] = slot_at_z[i + 1] or 0
					end

					block.slot_count = light_occlusion.last_dispatches
					return block
				end,
			},
		},
		custom_declarations = table.concat(declarations, "\n"),
		shader = [[
			void main() {
				int level = int(gl_GlobalInvocationID.z) / mip_data.slot_count + 1;
				int slot = mip_data.slot_at_z[int(gl_GlobalInvocationID.z) % mip_data.slot_count];
				int size = imageSize(mip_src).x >> level;
				ivec2 p = ivec2(gl_GlobalInvocationID.xy);

				if (p.x >= size || p.y >= size) return;

				int span = 1 << level;
				vec2 sum = vec2(0.0);

				for (int y = 0; y < span; y++) {
					for (int x = 0; x < span; x++) {
						sum += imageLoad(mip_src, ivec3(p * span + ivec2(x, y), slot)).rg;
					}
				}

				sum /= float(span * span);
				]] .. table.concat(stores, "\n\t\t\t\t") .. [[
			}
		]],
	}
end

local function create_map_layers(size, levels, capacity)
	light_occlusion.map_texture = create_map_texture(
		size,
		capacity,
		"light_occlusion_map",
		{"sampled", "storage", "transfer_src", "transfer_dst"},
		MAP_SAMPLER_CONFIG,
		levels
	)
	light_occlusion.map_capacity = capacity
	light_occlusion.mip_views = {}

	for level = 0, levels - 1 do
		light_occlusion.mip_views[level] = light_occlusion.map_texture:GetImage():CreateView{
			view_type = "2d_array",
			base_mip_level = level,
			level_count = 1,
			base_array_layer = 0,
			layer_count = capacity,
		}
	end
end

local function ensure_map_texture()
	if not light_occlusion.map_texture then
		local size = oct_size:Get()
		local levels = get_mip_count(size)
		create_map_layers(size, levels, light_occlusion.capacity)
		light_occlusion.scratch_texture = create_map_texture(
			size,
			LIGHT_OCCL_MAX_TRACES_PER_FRAME,
			"light_occlusion_blur_scratch",
			{"storage"},
			nil,
			1
		)
		light_occlusion.map_size = size
		light_occlusion.map_levels = levels
	end
end

function light_occlusion.SetCapacity(cmd, capacity)
	light_occlusion.capacity = capacity
	local old = light_occlusion.map_texture

	if not old or light_occlusion.map_capacity == capacity then return end

	local old_capacity = light_occlusion.map_capacity
	local old_views = light_occlusion.mip_views
	local size = light_occlusion.map_size
	create_map_layers(size, light_occlusion.map_levels, capacity)
	local new = light_occlusion.map_texture
	render.TransitionResource(old, "transfer_src_optimal", {cmd = cmd})
	render.TransitionResource(new, "transfer_dst_optimal", {cmd = cmd})

	for level = 0, light_occlusion.map_levels - 1 do
		cmd:CopyImageToImage{
			src_image = old:GetImage(),
			dst_image = new:GetImage(),
			width = math.max(bit.rshift(size, level), 1),
			height = math.max(bit.rshift(size, level), 1),
			src_mip_level = level,
			dst_mip_level = level,
			layer_count = math.min(old_capacity, capacity),
		}
	end

	render.TransitionResource(
		new,
		"shader_read_only_optimal",
		{cmd = cmd, dstStage = "all_commands", dstAccess = "shader_read"}
	)

	for _, view in pairs(old_views) do
		view:Remove()
	end

	old:Remove()

	for light_index = capacity + 1, old_capacity do
		state[light_index] = nil
		stamps[light_index] = nil
		move_frame[light_index] = nil
		geom_stale[light_index] = nil
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

	if not light_occlusion.mip_pipeline then
		light_occlusion.mip_pipeline = build_mip_pipeline(light_occlusion.map_levels)
	end
end

local function get_descriptor_slot()
	local frame = render.GetCurrentFrame() or 1
	return ((frame - 1) % get_frame_span()) + 1
end

light_occlusion.last_dispatches = 0

function light_occlusion.Draw(cmd)
	light_occlusion.last_dispatches = 0

	if not (hit.IsSupported() and enabled:Get()) then return end

	local tlas = rt.GetTLAS(cmd)
	local lights = render3d.GetLights()
	local frame = system.GetFrameNumber()
	process_geometry_change(lights)
	local dirty_count = 0
	local camera_pos = render3d.GetCamera():GetPosition()

	for light_index = 1, light_occlusion.capacity do
		local light = lights[light_index]

		if not is_occlusion_light(light) then
			state[light_index] = nil
			stamps[light_index] = nil
			move_frame[light_index] = nil
			geom_stale[light_index] = nil
		else
			local pos = light.Owner.transform:GetWorldPosition()
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
					local dx, dy, dz = pos.x - camera_pos.x, pos.y - camera_pos.y, pos.z - camera_pos.z
					dirty_count = choose(
						light_index,
						(
								info and
								info.light == light
							)
							and
							info.frame or
							UNTRACED_SCORE + dx * dx + dy * dy + dz * dz,
						dirty_count
					)
				end
			end
		end
	end

	if dirty_count == 0 then return end

	for i = 1, dirty_count do
		slot_at_z[i] = chosen_light[i] - 1
	end

	ensure_resources()
	local pipeline = light_occlusion.trace_pipeline
	local map_texture = light_occlusion.map_texture
	local scratch_texture = light_occlusion.scratch_texture
	local slot = get_descriptor_slot()
	render.TransitionResourceToComputeStorage(
		map_texture,
		{cmd = cmd, base_array_layer = 0, layer_count = light_occlusion.map_capacity}
	)
	render.TransitionResourceToComputeStorage(
		scratch_texture,
		{cmd = cmd, base_array_layer = 0, layer_count = LIGHT_OCCL_MAX_TRACES_PER_FRAME}
	)
	pipeline:UpdateDescriptorSet("storage_image", slot, BINDING_MAP, 0, light_occlusion.mip_views[0])
	pipeline:UpdateDescriptorSet("acceleration_structure_khr", slot, BINDING_TLAS, 0, tlas)
	hit.Bind(pipeline, slot, BINDING_HIT)
	pipeline:UploadConstants()
	local size = get_map_size()
	light_occlusion.last_dispatches = dirty_count
	gpu_timing.BeginScope(cmd, "light_occlusion", "lighting")
	pipeline.pipeline:Dispatch(
		cmd,
		math.ceil(size / 8),
		math.ceil(size / 8),
		dirty_count,
		slot,
		pipeline.dynamic_offsets
	)

	if blur:Get() > 0 then
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
			blur:UpdateDescriptorSet(
				"storage_image",
				slot,
				BINDING_BLUR_SRC,
				0,
				src == map_texture and light_occlusion.mip_views[0] or src:GetView()
			)
			blur:UpdateDescriptorSet(
				"storage_image",
				slot,
				BINDING_BLUR_DST,
				0,
				dst == map_texture and light_occlusion.mip_views[0] or dst:GetView()
			)
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

	cmd:PipelineBarrier{
		srcStage = "compute",
		dstStage = "compute",
		imageBarriers = {
			{
				image = map_texture:GetImage(),
				oldLayout = "general",
				newLayout = "general",
				srcAccessMask = "shader_write",
				dstAccessMask = "shader_read",
			},
		},
	}
	local mips = light_occlusion.mip_pipeline
	mips:UpdateDescriptorSet("storage_image", slot, BINDING_MIP_SRC, 0, light_occlusion.mip_views[0])

	for level = 1, light_occlusion.map_levels - 1 do
		mips:UpdateDescriptorSet(
			"storage_image",
			slot,
			BINDING_MIP_DST + level - 1,
			0,
			light_occlusion.mip_views[level]
		)
	end

	mips:UploadConstants()
	mips.pipeline:Dispatch(
		cmd,
		math.ceil(size / 16),
		math.ceil(size / 16),
		dirty_count * (light_occlusion.map_levels - 1),
		slot,
		mips.dynamic_offsets
	)
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
			layer_count = light_occlusion.map_capacity,
		}
	)

	for i = 1, dirty_count do
		local light_index = slot_at_z[i] + 1
		local light = lights[light_index]
		local pos = light.Owner.transform:GetWorldPosition()
		state[light_index] = {
			light = light,
			x = pos.x,
			y = pos.y,
			z = pos.z,
			range = light:GetEffectiveRange(),
			stamp_dispatched = stamps[light_index],
			frame = frame,
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

function light_occlusion.GetDebugState()
	local lights = render3d.GetLights()
	local out = {
		frame = system.GetFrameNumber(),
		bias = bias:Get(),
		blur = blur:Get(),
		bleed_reduction = bleed_reduction:Get(),
		oct_size = get_map_size(),
		max_traces = LIGHT_OCCL_MAX_TRACES_PER_FRAME,
		lights = {},
	}

	for light_index = 1, light_occlusion.capacity do
		local light = lights[light_index]

		if is_occlusion_light(light) then
			local info = state[light_index]
			local stamp = stamps[light_index] or 0
			local pos = light.Owner.transform:GetWorldPosition()
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
		{"bvh_oct_size", "int"},
		{"bvh_oct_bias", "float"},
		{"bvh_oct_bleed_reduction", "float"},
		{"bvh_oct_soft", "int"},
		{"bvh_oct_contact", "float"},
	}
end

function light_occlusion.WriteOcclusionBlock(block)
	block.bvh_oct_size = get_map_size()
	block.bvh_oct_bias = bias:Get()
	block.bvh_oct_bleed_reduction = bleed_reduction:Get()
	block.bvh_oct_soft = soft:Get() and 1 or 0
	block.bvh_oct_contact = contact:Get()
end

function light_occlusion.GetMapLayer(index, light)
	if not (enabled:Get() and hit.IsSupported()) then return -1 end

	local info = state[index + 1]
	return info and info.light == light and index or -1
end

local SAMPLING_TAPS = 12
-- the driver evaluates cos, sin and sqrt of a constant per tap instead of folding them
local sampling_tap_offsets_glsl

do
	local offsets = {}

	for k = 0, SAMPLING_TAPS - 1 do
		local angle = k * 2.39996323
		local radius = math.sqrt((k + 0.5) / SAMPLING_TAPS)
		offsets[k + 1] = string.format("vec2(%.9f, %.9f)", math.cos(angle) * radius, math.sin(angle) * radius)
	end

	sampling_tap_offsets_glsl = string.format(
		"const vec2 LIGHT_OCCL_TAP_OFFSETS[%d] = vec2[%d](%s);\n",
		SAMPLING_TAPS,
		SAMPLING_TAPS,
		table.concat(offsets, ", ")
	)
end

function light_occlusion.GetSamplingGLSL(data_block)
	return (
			[[
		const int LIGHT_OCCL_TAPS = ]] .. SAMPLING_TAPS .. [[;
		]] .. sampling_tap_offsets_glsl .. [[

		]] .. glsl_common.GetOctahedralGLSL() .. [[

		float light_oct_chebyshev(vec2 moments, float dist, float bleed) {
			if (moments.x <= 0.0) return 1.0;

			float bias = ]] .. data_block .. [[.bvh_oct_bias;
			float d = dist - moments.x * (1.0 + bias);

			if (d <= 0.0) return 1.0;

			float min_std = moments.x * bias;
			float variance = max(moments.y - moments.x * moments.x, min_std * min_std);
			return clamp((variance / (variance + d * d) - bleed) / (1.0 - bleed), 0.0, 1.0);
		}

		vec2 light_oct_wrap(vec2 uv) {
			if (uv.x < 0.0) uv = vec2(-uv.x, 1.0 - uv.y);
			else if (uv.x > 1.0) uv = vec2(2.0 - uv.x, 1.0 - uv.y);

			if (uv.y < 0.0) uv = vec2(1.0 - uv.x, -uv.y);
			else if (uv.y > 1.0) uv = vec2(1.0 - uv.x, 2.0 - uv.y);

			return uv;
		}

		float light_oct_receiver_depth(vec2 uv, vec3 to_pos, vec3 normal, float dist) {
			float facing = dot(normal, oct_decode(uv * 2.0 - 1.0));

			if (facing > -0.05) return dist;

			return min(dot(normal, to_pos) / facing, dist * 4.0);
		}

		float light_oct_shadow_factor(int slot, vec3 light_pos, float range, vec3 world_pos, float source_radius, vec3 normal) {
			if (slot < 0) return 1.0;
			vec3 to_pos = world_pos - light_pos;
			float dist = length(to_pos);

			if (dist >= range) return 1.0;

			vec3 uv = vec3(oct_encode(to_pos / max(dist, 1e-5)) * 0.5 + 0.5, float(slot));
			float bleed = ]] .. data_block .. [[.bvh_oct_bleed_reduction;

			if (source_radius <= 0.0 || dist <= source_radius || ]] .. data_block .. [[.bvh_oct_soft == 0) return light_oct_chebyshev(textureLod(light_oct_map, uv, 0.0).rg, dist, bleed);

			float map_size = float(]] .. data_block .. [[.bvh_oct_size);
			float max_lod = float(textureQueryLevels(light_oct_map) - 1);
			float search = 3.0 * source_radius / dist;
			float sharp = light_oct_chebyshev(textureLod(light_oct_map, uv, 0.0).rg, dist, bleed);
			float coarse = light_oct_chebyshev(textureLod(light_oct_map, uv, clamp(log2(2.0 * search * map_size / 3.5449077), 0.0, max_lod)).rg, dist, 0.0);

			if (sharp >= 0.99 && coarse >= 0.99) return 1.0;

			if (sharp <= 0.01 && coarse <= 0.01) return 0.0;

			vec3 center_dir = oct_decode(uv.xy * 2.0 - 1.0);
			vec2 step = vec2(clamp(uv.x + 1.0 / map_size, 0.0, 1.0) - uv.x, clamp(uv.y + 1.0 / map_size, 0.0, 1.0) - uv.y);
			step = mix(-vec2(1.0 / map_size), step, greaterThan(abs(step), vec2(0.5 / map_size)));
			float angle_per_uv = 0.5 * (acos(clamp(dot(center_dir, oct_decode(vec2(uv.x + step.x, uv.y) * 2.0 - 1.0)), -1.0, 1.0)) / abs(step.x) + acos(clamp(dot(center_dir, oct_decode(vec2(uv.x, uv.y + step.y) * 2.0 - 1.0)), -1.0, 1.0)) / abs(step.y));
			float texel_angle = angle_per_uv / map_size;
			float tap_spread = 2.0 / sqrt(float(LIGHT_OCCL_TAPS));
			float search_lod = clamp(log2(search * tap_spread / texel_angle) - 3.0, 0.0, max_lod);
			float blocker_sum = 0.0;
			float blocker_count = 0.0;

			for (int k = 0; k < LIGHT_OCCL_TAPS; k++) {
				vec2 tap = light_oct_wrap(uv.xy + LIGHT_OCCL_TAP_OFFSETS[k] * search / angle_per_uv);
				float mean = textureLod(light_oct_map, vec3(tap, uv.z), search_lod).r;

				if (mean > 0.0 && mean * (1.0 + ]] .. data_block .. [[.bvh_oct_bias) < light_oct_receiver_depth(tap, to_pos, normal, dist)) {
					blocker_sum += 1.0 / max(mean, 0.05);
					blocker_count += 1.0;
				}
			}

			if (blocker_count == 0.0) return sharp;

			float penumbra = source_radius * max(blocker_sum / blocker_count - 1.0 / dist, 0.0);
			float lod = clamp(log2(penumbra * tap_spread / texel_angle) - 1.0, 0.0, max_lod);
			float tap_bleed = bleed * clamp((4.0 - penumbra / texel_angle) / 3.0, 0.0, 1.0);
			float visibility = 0.0;

			for (int k = 0; k < LIGHT_OCCL_TAPS; k++) {
				vec2 tap = light_oct_wrap(uv.xy + LIGHT_OCCL_TAP_OFFSETS[k] * penumbra / angle_per_uv);
				visibility += light_oct_chebyshev(textureLod(light_oct_map, vec3(tap, uv.z), lod).rg, light_oct_receiver_depth(tap, to_pos, normal, dist), tap_bleed);
			}

			return visibility / float(LIGHT_OCCL_TAPS);
		}
	]]
		)
end

return light_occlusion
