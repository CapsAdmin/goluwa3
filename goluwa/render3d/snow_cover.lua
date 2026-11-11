local render = import("goluwa/render/render.lua")
local EasyPipeline = import("goluwa/render/easy_pipeline.lua")
local Texture = import("goluwa/render/texture.lua")
local event = import("goluwa/event.lua")
local surface_weather = import("goluwa/render3d/surface_weather.lua")
local snow_cover = {}
snow_cover.MIN_DEPTH = 0.01
snow_cover.EDGE_JUMP = 0.1
snow_cover.LIP = 1.5
snow_cover.MAX_LIP_TEXELS = 24
snow_cover.SMOOTH = 0.5
snow_cover.MAX_SMOOTH_TEXELS = 24
snow_cover.EDGE_RADIUS = 8
local SLOTS = 4
local state = {}
local params = {}

local function get_pipeline()
	if state.pipeline then return state.pipeline end

	state.pipeline = EasyPipeline.Compute{
		name = "snow_cover",
		DescriptorSetCount = SLOTS,
		LocalSize = {x = 8, y = 8, z = 1},
		storage_images = {{binding_index = 0}},
		sampled_images = {{binding_index = 1}},
		uniform_buffers = {
			{
				name = "snow_params",
				binding_index = 2,
				block = {
					{"size", "int"},
					{"lip_texels", "int"},
					{"depth_per_meter", "float"},
					{"texel", "float"},
					{"depth", "float"},
					{"jump", "float"},
					{"lip", "float"},
				},
				write = function(self, block)
					block.size = params.size
					block.lip_texels = params.lip_texels
					block.depth_per_meter = params.depth_per_meter
					block.texel = params.texel
					block.depth = params.depth
					block.jump = params.jump
					block.lip = params.lip
					return block
				end,
			},
		},
		custom_declarations = [[
			layout(set = 0, binding = 0, rg32f) uniform writeonly image2D snow_map;
			layout(set = 0, binding = 1) uniform sampler2D shelter;
		]],
		shader = [[
			float shelter_depth(ivec2 p) {
				p = clamp(p, ivec2(0), ivec2(snow_params.size - 1));
				return texelFetch(shelter, p, 0).r;
			}

			void main() {
				ivec2 p = ivec2(gl_GlobalInvocationID.xy);

				if (p.x >= snow_params.size || p.y >= snow_params.size) return;

				float d = shelter_depth(p);

				if (d >= 0.9999) {
					imageStore(snow_map, p, vec4(2.0, d, 0.0, 0.0));
					return;
				}

				float dpm = snow_params.depth_per_meter;
				float jump = snow_params.jump * dpm;
				float dl = shelter_depth(p - ivec2(1, 0));
				float dr = shelter_depth(p + ivec2(1, 0));
				float dd = shelter_depth(p - ivec2(0, 1));
				float du = shelter_depth(p + ivec2(0, 1));
				float sx = abs(dr - dl) < 2.0 * jump ? (dr - dl) * 0.5 : (abs(dr - d) < abs(dl - d) ? dr - d : d - dl);
				float sy = abs(du - dd) < 2.0 * jump ? (du - dd) * 0.5 : (abs(du - d) < abs(dd - d) ? du - d : d - dd);
				vec2 slope = vec2(sx, sy) / (dpm * snow_params.texel);
				float up = 1.0 / sqrt(1.0 + dot(slope, slope));
				float nearest = float(snow_params.lip_texels + 1);

				for (int i = 0; i < 16; i++) {
					float a = float(i) * 0.3926991;
					vec2 dir = vec2(cos(a), sin(a));

					for (int r = 1; r <= snow_params.lip_texels; r++) {
						if (float(r) >= nearest) break;

						ivec2 q = p + ivec2(round(dir * float(r)));

						if (any(lessThan(q, ivec2(0))) || any(greaterThanEqual(q, ivec2(snow_params.size)))) break;

						if (abs(shelter_depth(q) - d) > jump) {
							nearest = float(r);
							break;
						}
					}
				}

				float taper = smoothstep(0.0, snow_params.lip, (nearest - 0.5) * snow_params.texel);
				float thickness = snow_params.depth * smoothstep(0.5, 0.87, up) * taper;
				imageStore(snow_map, p, vec4(d - thickness * dpm, d, 0.0, 0.0));
			}
		]],
	}
	return state.pipeline
end

local get_edge_pipeline

do
	local pipeline

	function get_edge_pipeline()
		if pipeline then return pipeline end

		pipeline = EasyPipeline.Compute{
			name = "snow_cover_edge",
			DescriptorSetCount = SLOTS,
			LocalSize = {x = 8, y = 8, z = 1},
			storage_images = {{binding_index = 0}, {binding_index = 1}},
			uniform_buffers = {
				{
					name = "edge_params",
					binding_index = 2,
					block = {
						{"size", "int"},
						{"radius", "int"},
						{"jump", "float"},
					},
					write = function(self, block)
						block.size = params.size
						block.radius = snow_cover.EDGE_RADIUS
						block.jump = params.jump * params.depth_per_meter
						return block
					end,
				},
			},
			custom_declarations = [[
				layout(set = 0, binding = 0, rg32f) uniform writeonly image2D edge_map;
				layout(set = 0, binding = 1, rg32f) uniform readonly image2D raw_map;
			]],
			shader = [[
				void main() {
					ivec2 p = ivec2(gl_GlobalInvocationID.xy);

					if (p.x >= edge_params.size || p.y >= edge_params.size) return;

					vec2 center = imageLoad(raw_map, p).rg;

					if (center.r > 1.5) {
						imageStore(edge_map, p, vec4(0.0));
						return;
					}

					int radius = edge_params.radius;
					float sigma = float(radius) * 0.4;
					float weights[33];

					for (int i = 0; i <= radius; i++) {
						weights[i] = exp(-float(i * i) / (2.0 * sigma * sigma));
					}

					float same = 0.0;
					float total = 0.0;

					for (int y = -radius; y <= radius; y++) {
						for (int x = -radius; x <= radius; x++) {
							ivec2 q = clamp(p + ivec2(x, y), ivec2(0), ivec2(edge_params.size - 1));
							vec2 n = imageLoad(raw_map, q).rg;
							float w = weights[abs(x)] * weights[abs(y)];
							total += w;
							same += n.r < 1.5 && abs(n.g - center.g) < edge_params.jump ? w : 0.0;
						}
					}

					imageStore(edge_map, p, vec4(same / total, 0.0, 0.0, 0.0));
				}
			]],
		}
		return pipeline
	end
end

local get_smooth_pipeline

do
	local pipelines = {}

	function get_smooth_pipeline(axis)
		if pipelines[axis] then return pipelines[axis] end

		pipelines[axis] = EasyPipeline.Compute{
			name = "snow_cover_smooth_" .. axis,
			DescriptorSetCount = SLOTS,
			LocalSize = {x = 8, y = 8, z = 1},
			storage_images = axis == 1 and
				{{binding_index = 0}, {binding_index = 1}, {binding_index = 3}} or
				{{binding_index = 0}, {binding_index = 1}},
			uniform_buffers = {
				{
					name = "smooth_params",
					binding_index = 2,
					block = {
						{"size", "int"},
						{"radius", "int"},
						{"axis", "int"},
						{"jump", "float"},
					},
					write = function(self, block)
						block.size = params.size
						block.radius = params.smooth_radius
						block.axis = axis
						block.jump = params.jump * params.depth_per_meter
						return block
					end,
				},
			},
			custom_declarations = [[
				layout(set = 0, binding = 0, rg32f) uniform readonly image2D source_map;
			]] .. (
					axis == 1 and
					[[
				layout(set = 0, binding = 1, rg32f) uniform writeonly image2D target_map;
				layout(set = 0, binding = 3, rg32f) uniform readonly image2D edge_map;
				#define STORE_RESULT(p, value, center) imageStore(target_map, p, vec4(value, 0.0, 0.0))
				#define EDGE_FADE(p) smoothstep(0.5, 0.92, imageLoad(edge_map, p).r)
			]] or
					[[
				layout(set = 0, binding = 1, rg32f) uniform writeonly image2D target_map;
				#define STORE_RESULT(p, value, center) imageStore(target_map, p, vec4(value, 0.0, 0.0))
				#define EDGE_FADE(p) 1.0
			]]
				),
			shader = [[
				void main() {
					ivec2 p = ivec2(gl_GlobalInvocationID.xy);

					if (p.x >= smooth_params.size || p.y >= smooth_params.size) return;

					vec2 center = imageLoad(source_map, p).rg;

					if (center.r > 1.5) {
						STORE_RESULT(p, center, center);
						return;
					}

					bool first = smooth_params.axis == 0;
					ivec2 step_dir = first ? ivec2(1, 0) : ivec2(0, 1);
					int radius = smooth_params.radius;
					float sigma = float(radius) * 0.5 + 0.5;
					float sum = 0.0;
					float weight_sum = 0.0;

					for (int i = -radius; i <= radius; i++) {
						ivec2 q = clamp(p + step_dir * i, ivec2(0), ivec2(smooth_params.size - 1));
						vec2 n = imageLoad(source_map, q).rg;

						if (n.r > 1.5 || abs(n.g - center.g) > smooth_params.jump) continue;

						float w = exp(-float(i * i) / (2.0 * sigma * sigma));
						sum += (first ? n.g - n.r : n.r) * w;
						weight_sum += w;
					}

					float thickness = sum / weight_sum * EDGE_FADE(p);
					STORE_RESULT(p, vec2(first ? thickness : center.g - thickness, center.g), center);
				}
			]],
		}
		return pipelines[axis]
	end
end

function snow_cover.Build(map, cmd)
	local shelter = map:GetDepthTexture(1)
	local size = shelter:GetWidth()

	if not state.texture or state.texture:GetWidth() ~= size then
		state.blurred = Texture.New{
			width = size,
			height = size,
			format = "r32g32_sfloat",
			mip_map_levels = 1,
			image = {usage = {"storage"}},
		}
		state.raw = Texture.New{
			width = size,
			height = size,
			format = "r32g32_sfloat",
			mip_map_levels = 1,
			image = {usage = {"storage"}},
		}
		state.edge = Texture.New{
			width = size,
			height = size,
			format = "r32g32_sfloat",
			mip_map_levels = 1,
			image = {usage = {"storage"}},
		}
		state.texture = Texture.New{
			width = size,
			height = size,
			format = "r32g32_sfloat",
			mip_map_levels = 1,
			image = {usage = {"sampled", "storage"}},
			sampler = {
				min_filter = "linear",
				mag_filter = "linear",
				wrap_s = "clamp_to_edge",
				wrap_t = "clamp_to_edge",
			},
		}
	end

	local m = map:GetLightSpaceMatrix(1)
	local texel = map:GetCascadeTexelWorldSize(1)
	local depth = surface_weather.snow_depth
	params.size = size
	params.depth_per_meter = math.sqrt(m.m02 * m.m02 + m.m12 * m.m12 + m.m22 * m.m22)
	params.texel = texel
	params.depth = depth
	params.jump = snow_cover.EDGE_JUMP + texel
	params.lip = math.max(depth * snow_cover.LIP, texel)
	params.lip_texels = math.min(math.ceil(params.lip / texel), snow_cover.MAX_LIP_TEXELS)
	params.smooth_radius = math.max(
		math.min(math.ceil(depth * snow_cover.SMOOTH / texel), snow_cover.MAX_SMOOTH_TEXELS),
		1
	)
	local slot = ((render.GetCurrentFrame() or 1) - 1) % SLOTS + 1
	local groups = math.ceil(size / 8)
	local pipeline = get_pipeline()
	pipeline:BindStorageImage(cmd, slot, 0, state.raw)
	pipeline:BindSampledImage(cmd, slot, 1, shelter)
	pipeline:UploadConstants()
	pipeline.pipeline:Dispatch(cmd, groups, groups, 1, slot, pipeline.dynamic_offsets)
	cmd:PipelineBarrier{srcStage = "compute", dstStage = "compute", memoryBarrier = true}
	local edge = get_edge_pipeline()
	edge:BindStorageImage(cmd, slot, 0, state.edge)
	edge:BindStorageImage(cmd, slot, 1, state.raw)
	edge:UploadConstants()
	edge.pipeline:Dispatch(cmd, groups, groups, 1, slot, edge.dynamic_offsets)
	cmd:PipelineBarrier{srcStage = "compute", dstStage = "compute", memoryBarrier = true}
	local horizontal = get_smooth_pipeline(0)
	horizontal:BindStorageImage(cmd, slot, 0, state.raw)
	horizontal:BindStorageImage(cmd, slot, 1, state.blurred)
	horizontal:UploadConstants()
	horizontal.pipeline:Dispatch(
		cmd,
		math.ceil(size / 8),
		math.ceil(size / 8),
		1,
		slot,
		horizontal.dynamic_offsets
	)
	cmd:PipelineBarrier{srcStage = "compute", dstStage = "compute", memoryBarrier = true}
	local vertical = get_smooth_pipeline(1)
	vertical:BindStorageImage(cmd, slot, 0, state.blurred)
	vertical:BindStorageImage(cmd, slot, 1, state.texture)
	vertical:BindStorageImage(cmd, slot, 3, state.edge)
	vertical:UploadConstants()
	vertical.pipeline:Dispatch(cmd, math.ceil(size / 8), math.ceil(size / 8), 1, slot, vertical.dynamic_offsets)
	render.TransitionResourceToShaderRead(state.texture, {cmd = cmd})
	surface_weather.snow_map = state.texture
end

function snow_cover.Update(map)
	local rendered = map.enabled and map.cascade[1].last_rendered_frame

	if surface_weather.snow_depth < snow_cover.MIN_DEPTH or not rendered then
		surface_weather.snow_map = nil
		state.key = nil
		return
	end

	local key = rendered .. " " .. surface_weather.snow_depth

	if key ~= state.key then
		state.key = key
		state.pending = map
	end
end

event.AddListener("PreRenderPass", "snow_cover", function()
	local map = state.pending

	if not map then return end

	state.pending = nil
	snow_cover.Build(map, render.GetCommandBuffer())
end)

return snow_cover
