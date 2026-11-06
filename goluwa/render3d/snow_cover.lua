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
snow_cover.MAX_SMOOTH_TEXELS = 6
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

						if (shelter_depth(q) > d + jump) {
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

local function get_smooth_pipeline()
	if state.smooth_pipeline then return state.smooth_pipeline end

	state.smooth_pipeline = EasyPipeline.Compute{
		name = "snow_cover_smooth",
		DescriptorSetCount = SLOTS,
		LocalSize = {x = 8, y = 8, z = 1},
		storage_images = {{binding_index = 0}, {binding_index = 1}},
		uniform_buffers = {
			{
				name = "smooth_params",
				binding_index = 2,
				block = {
					{"size", "int"},
					{"radius", "int"},
					{"jump", "float"},
				},
				write = function(self, block)
					block.size = params.size
					block.radius = params.smooth_radius
					block.jump = params.jump * params.depth_per_meter
					return block
				end,
			},
		},
		custom_declarations = [[
			layout(set = 0, binding = 0, rg32f) uniform readonly image2D raw_map;
			layout(set = 0, binding = 1, rg32f) uniform writeonly image2D snow_map;
		]],
		shader = [[
			void main() {
				ivec2 p = ivec2(gl_GlobalInvocationID.xy);

				if (p.x >= smooth_params.size || p.y >= smooth_params.size) return;

				vec2 center = imageLoad(raw_map, p).rg;

				if (center.r > 1.5) {
					imageStore(snow_map, p, vec4(center, 0.0, 0.0));
					return;
				}

				int radius = smooth_params.radius;
				float sigma = float(radius) * 0.5 + 0.5;
				float sum = 0.0;
				float weight_sum = 0.0;

				for (int y = -radius; y <= radius; y++) {
					for (int x = -radius; x <= radius; x++) {
						ivec2 q = clamp(p + ivec2(x, y), ivec2(0), ivec2(smooth_params.size - 1));
						vec2 n = imageLoad(raw_map, q).rg;

						if (n.r > 1.5 || abs(n.g - center.g) > smooth_params.jump) continue;

						float w = exp(-float(x * x + y * y) / (2.0 * sigma * sigma));
						sum += (n.g - n.r) * w;
						weight_sum += w;
					}
				}

				imageStore(snow_map, p, vec4(center.g - sum / weight_sum, center.g, 0.0, 0.0));
			}
		]],
	}
	return state.smooth_pipeline
end

function snow_cover.Build(map, cmd)
	local shelter = map:GetDepthTexture(1)
	local size = shelter:GetWidth()

	if not state.texture or state.texture:GetWidth() ~= size then
		state.raw = Texture.New{
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
	local pipeline = get_pipeline()
	local slot = ((render.GetCurrentFrame() or 1) - 1) % SLOTS + 1
	pipeline:BindStorageImage(cmd, slot, 0, state.raw)
	pipeline:BindSampledImage(cmd, slot, 1, shelter)
	pipeline:UploadConstants()
	pipeline.pipeline:Dispatch(cmd, math.ceil(size / 8), math.ceil(size / 8), 1, slot, pipeline.dynamic_offsets)
	cmd:PipelineBarrier{srcStage = "compute", dstStage = "compute", memoryBarrier = true}
	local smooth = get_smooth_pipeline()
	smooth:BindStorageImage(cmd, slot, 0, state.raw)
	smooth:BindStorageImage(cmd, slot, 1, state.texture)
	smooth:UploadConstants()
	smooth.pipeline:Dispatch(cmd, math.ceil(size / 8), math.ceil(size / 8), 1, slot, smooth.dynamic_offsets)
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
