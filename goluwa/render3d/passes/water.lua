local ray_materials = import("goluwa/render3d/scene/ray_materials.lua")
local assets = import("goluwa/assets.lua")
local system = import("goluwa/system.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local gbuffer_layout = import("goluwa/render3d/gbuffer_layout.lua")
local atmosphere = import("goluwa/render3d/atmosphere.lua")
local directional_shadows = import("goluwa/render3d/directional_shadows.lua")
local ibl = import("goluwa/render3d/ibl.lua")
local screen_reconstruct = import("goluwa/render3d/screen_reconstruct.lua")
local screen_refraction = import("goluwa/render3d/screen_refraction.lua")
local glsl_common = import("goluwa/render3d/glsl_common.lua")
local post_source = import("goluwa/render3d/post_source.lua")
local water = import("goluwa/render3d/water.lua")
local media = import("goluwa/render3d/media.lua")
local medium_common = import("goluwa/render3d/medium_common.lua")
local medium_surface = import("goluwa/render3d/medium_surface.lua")
local optical_rays = import("goluwa/render3d/optical_rays.lua")
local light_occlusion = import("goluwa/render3d/light_occlusion.lua")
local medium_lighting = import("goluwa/render3d/medium_lighting.lua")
local scene_lights = import("goluwa/render3d/scene_lights.lua")
local ocean_fft = import("goluwa/render3d/ocean_fft.lua")
local water_field = import("goluwa/render3d/water_field.lua")
local surf = import("goluwa/render3d/surf.lua")
local render = import("goluwa/render/render.lua")
local scene_hits = import("goluwa/render3d/scene_hits.lua")
local path_trace = import("goluwa/render3d/path_trace.lua")
local caustics = import("goluwa/render3d/caustics.lua")
local RAY_QUERY = scene_hits.RAY_QUERY
local REFLECTION_BINDINGS = {scene = 5, hit = 30, materials = 7, light_grid = 9}
local BINDING_OCCLUSION = 10
local BINDING_OPTICAL = 11
local pvars = import("goluwa/cli/pvars.lua")
local planet = import("goluwa/planet.lua")
local FEATURES = {}
pvars.StartGroup("Environment", "Water", {store = false, prefix = "water_"})

for _, feature in ipairs{
	{"caustics", "r_water_caustics", "the caustics on the floor under the water"},
	{
		"shafts",
		"r_water_shafts",
		"the sun shafts, light scattered towards the viewer under the surface",
	},
	{"ripples", "r_water_ripples", "the small ripples on top of the wave textures"},
	{
		"lights",
		"r_water_lights",
		"point lights glinting off the water and scattering in it",
	},
	{
		"reflection_trace",
		"r_water_reflection_trace",
		"traced and screen space reflections, off leaves the environment map",
	},
	{
		"shore_foam",
		"r_water_shore_foam",
		"the depth and slope samples that place foam along shores and around things, and the wet band above the water",
	},
	{
		"inscatter",
		"r_water_inscatter",
		"light scattered in the water between the surface and what is under it (shafts, sky and lights)",
	},
	{
		"refraction",
		"r_water_refraction",
		"the scene seen through the surface, the floor under the water",
	},
	{
		"sun_shadows",
		"r_water_sun_shadows",
		"shadows of the sun on the water, the floor under it and in the shafts",
	},
	{"shaft_caustics", "r_water_shaft_caustics", "the caustics in the light shafts"},
	{
		"ambient_gi",
		"r_water_ambient_gi",
		"the light from above that the global illumination probes give the water, off is the sky's",
	},
	{
		"waves",
		"r_water_waves",
		"the waves, the ripples and the roughness they leave, off is a perfectly flat, smooth mirror surface",
	},
	{
		"roughness",
		"r_water_roughness",
		"the roughness the unresolved waves give the sea, off the waves are drawn with a mirror surface",
		false,
	},
	{
		"uniform_roughness",
		"r_water_uniform_roughness",
		"the roughness of the sea is what the nearest wave texture leaves unresolved everywhere, off it is what the textures that cover the pixel leave, which steps at the edge of each",
	},
} do
	FEATURES[#FEATURES + 1] = {
		bit = 2 ^ #FEATURES,
		pvar = pvars.Setup2{key = feature[2], default = feature[4] ~= false, help = feature[3]},
	}
end

local screenspace_roughness_pvar = pvars.Setup2{
	key = "r_water_screenspace_roughness",
	default = 1,
	min = 0,
	max = 1,
	help = "perceptual roughness below which the water's reflection is the screen first (the last frame, fog and all) and the rays only fill what the screen does not hold, the water's own reflection_screenspace_roughness. 0 is rays only, which have no fog and are blurred by the denoiser",
}
local shaft_samples_pvar = pvars.Setup2{
	key = "r_water_shaft_samples",
	default = 8,
	min = 1,
	max = 8,
	integer = true,
	help = "most samples along the view ray for the sun shafts under the surface (short paths take fewer), fewer is noisier shafts",
}
local trace_steps_pvar = pvars.Setup2{
	key = "r_water_trace_steps",
	default = 160,
	min = 24,
	max = 160,
	integer = true,
	help = "most steps of the trace for the sea's surface from above, too few miss the thin tops of steep waves at grazing angles",
}
local field_debug_pvar = pvars.Setup2{
	key = "r_water_field_debug",
	default = false,
	help = "colours the sea by the wave field from the depth around the camera: hue is the angle the waves turn towards the shore, dark is sheltered from the open sea, blue is where surf runs, red is whitewater, cyan is swash over the sand",
}
local reorder_pvar = pvars.Setup2{
	key = "r_water_reorder",
	default = true,
	help = "the water's reflection and refraction rays are traced from a ray generation shader and the threads are reordered by what they hit before it is shaded, off traces with ray queries in a compute shader. needs ray tracing invocation reorder, built into the shader",
}
pvars.EndGroup()
local WAVE_TEX_SIZE = 512
local WAVE_CASCADES = {
	{name = "ocean_waves_near", world_half = 64, foam_weight = 1, fft_count = 3},
	{name = "ocean_waves_mid", world_half = 256, foam_weight = 1, fft_count = 2},
	{name = "ocean_waves", world_half = 1024, foam_weight = 0, fft_count = 1},
}
local NEAR_TEXEL_SIZE = water.NEAR_TEXEL_SIZE
assert(NEAR_TEXEL_SIZE == WAVE_CASCADES[1].world_half * 2 / WAVE_TEX_SIZE)

local function get_cascade_texel_size(cascade)
	return cascade.world_half * 2 / WAVE_TEX_SIZE
end

local function write_cascade_origin(ptr, cascade)
	local snap = get_cascade_texel_size(cascade)
	local cam = render3d.GetCamera():GetPosition()
	ptr[0] = math.floor(cam.x / snap) * snap
	ptr[1] = math.floor(cam.z / snap) * snap
end

local passes = {}
local FOAM_BIAS = 1.03
local FOAM_SPREAD = 1.5
local FOAM_GAIN = 2.5
local FOAM_DECAY = 0.3
local SWASH_LEVEL_BIAS = 1
local FOAM_ADD = 1.0
local previous_origins = {}

local function get_foam_pipeline_name(cascade)
	return cascade.name .. "_foam"
end

local FFT_COMMON_GLSL = [[
	const uint FFT_N = 256u;
	shared vec2 fft_buf[2][256];

	vec2 fft_mul(vec2 a, vec2 b) {
		return vec2(a.x * b.x - a.y * b.y, a.x * b.y + a.y * b.x);
	}

	uint fft_inverse(uint tid) {
		uint src = 0u;

		for (uint ns = 1u; ns < FFT_N; ns <<= 1u) {
			uint dst = 1u - src;
			uint k = tid % ns;
			vec2 v0 = fft_buf[src][tid];
			vec2 v1 = fft_buf[src][tid + 128u];
			float angle = 6.28318530718 * float(k) / float(ns * 2u);
			v1 = fft_mul(v1, vec2(cos(angle), sin(angle)));
			uint out_index = (tid / ns) * ns * 2u + k;
			fft_buf[dst][out_index] = v0 + v1;
			fft_buf[dst][out_index + ns] = v0 - v1;
			barrier();
			src = dst;
		}

		return src;
	}
]]
local FFT_BINDING_DATA = 4

local function dummy_color_format()
	return {{"r8_unorm", {"ocean_fft_dummy", "r"}}}
end

for cascade_index, fft_cascade in ipairs(water.FFT_CASCADES) do
	local function textures()
		return ocean_fft.textures[cascade_index]
	end

	list.insert(
		passes,
		{
			name = "ocean_fft_rows_" .. cascade_index,
			ComputePass = true,
			ColorFormat = dummy_color_format(),
			FramebufferSize = {x = 1, y = 1},
			framebuffer_count = 1,
			LocalSize = {x = 128, y = 1, z = 1},
			storage_images = {
				{
					binding_index = 0,
					dst_stage = "compute",
					get_texture = function()
						ocean_fft.Update()
						return textures().h0
					end,
				},
				{
					binding_index = 1,
					dst_stage = "compute",
					get_texture = function()
						return textures().omega
					end,
				},
				{
					binding_index = 2,
					dst_stage = "compute",
					get_texture = function()
						return textures().temp0
					end,
				},
				{
					binding_index = 3,
					dst_stage = "compute",
					get_texture = function()
						return textures().temp1
					end,
				},
			},
			uniform_buffers = {
				{
					name = "fft_data",
					binding_index = FFT_BINDING_DATA,
					block = {{"time_fraction", "float"}},
					write = function(self, block)
						block.time_fraction = water.GetWaveTime() / water.WAVE_PERIOD
						return block
					end,
				},
			},
			on_draw = function(self, cmd, fb, frame, desc)
				self:UploadConstants()
				self.pipeline:DispatchForSize(cmd, 128 * water.FFT_SIZE, 1, 1, desc, self.dynamic_offsets)
			end,
			custom_declarations = [[
				layout(set = 0, binding = 0, rgba32f) uniform readonly image2D in_h0;
				layout(set = 0, binding = 1, r32f) uniform readonly image2D in_omega;
				layout(set = 0, binding = 2, rgba32f) uniform writeonly image2D out_temp0;
				layout(set = 0, binding = 3, rgba32f) uniform writeonly image2D out_temp1;
			]] .. FFT_COMMON_GLSL,
			shader = [[
				const float TILE_SIZE = ]] .. fft_cascade.size .. [[;

				vec2 times_i(vec2 a) {
					return vec2(-a.y, a.x);
				}

				void get_spectra(uint u, uint row, out vec2 c[4]) {
					c[0] = vec2(0.0);
					c[1] = vec2(0.0);
					c[2] = vec2(0.0);
					c[3] = vec2(0.0);
					ivec2 id = ivec2(int(u), int(row));
					float omega_index = imageLoad(in_omega, id).x;

					if (omega_index == 0.0) return;

					vec4 h0 = imageLoad(in_h0, id);
					int n = int(u) - (u >= 128u ? 256 : 0);
					int m = int(row) - (row >= 128u ? 256 : 0);
					vec2 kv = vec2(float(n), float(m)) * (6.28318530718 / TILE_SIZE);
					float k = length(kv);
					vec2 dir = kv / k;
					float phase = 6.28318530718 * fract(omega_index * fft_data.time_fraction);
					vec2 e = vec2(cos(phase), sin(phase));
					vec2 h = fft_mul(h0.xy, vec2(e.x, -e.y)) + fft_mul(vec2(h0.z, -h0.w), e);
					vec2 ih = times_i(h);
					c[0] = ih * dir.x + times_i(ih * dir.y);
					c[1] = h + times_i(h * (-kv.x * dir.y));
					c[2] = ih * kv.x + times_i(ih * kv.y);
					c[3] = h * (-kv.x * dir.x) + times_i(h * (-kv.y * dir.y));
				}

				void main() {
					uint tid = gl_LocalInvocationID.x;
					uint row = gl_WorkGroupID.x;
					vec2 a[4];
					vec2 b[4];
					get_spectra(tid, row, a);
					get_spectra(tid + 128u, row, b);
					vec2 low[4];
					vec2 high[4];

					for (int f = 0; f < 4; f++) {
						fft_buf[0][tid] = a[f];
						fft_buf[0][tid + 128u] = b[f];
						barrier();
						uint result = fft_inverse(tid);
						low[f] = fft_buf[result][tid];
						high[f] = fft_buf[result][tid + 128u];
						barrier();
					}

					imageStore(out_temp0, ivec2(int(tid), int(row)), vec4(low[0], low[1]));
					imageStore(out_temp1, ivec2(int(tid), int(row)), vec4(low[2], low[3]));
					imageStore(out_temp0, ivec2(int(tid + 128u), int(row)), vec4(high[0], high[1]));
					imageStore(out_temp1, ivec2(int(tid + 128u), int(row)), vec4(high[2], high[3]));
				}
			]],
		}
	)
	list.insert(
		passes,
		{
			name = "ocean_fft_columns_" .. cascade_index,
			ComputePass = true,
			ColorFormat = dummy_color_format(),
			FramebufferSize = {x = 1, y = 1},
			framebuffer_count = 1,
			LocalSize = {x = 128, y = 1, z = 1},
			storage_images = {
				{
					binding_index = 0,
					dst_stage = "compute",
					get_texture = function()
						return textures().temp0
					end,
				},
				{
					binding_index = 1,
					dst_stage = "compute",
					get_texture = function()
						return textures().temp1
					end,
				},
				{
					binding_index = 2,
					dst_stage = "fragment",
					get_texture = function()
						return textures().displacement
					end,
				},
				{
					binding_index = 3,
					dst_stage = "fragment",
					get_texture = function()
						return textures().derivatives
					end,
				},
			},
			on_draw = function(self, cmd, fb, frame, desc)
				self:UploadConstants()
				self.pipeline:DispatchForSize(cmd, 128 * water.FFT_SIZE, 1, 1, desc, self.dynamic_offsets)
			end,
			custom_declarations = [[
				layout(set = 0, binding = 0, rgba32f) uniform readonly image2D in_temp0;
				layout(set = 0, binding = 1, rgba32f) uniform readonly image2D in_temp1;
				layout(set = 0, binding = 2, rgba16f) uniform writeonly image2D out_displacement;
				layout(set = 0, binding = 3, rgba16f) uniform writeonly image2D out_derivatives;
			]] .. FFT_COMMON_GLSL,
			shader = [[
				void main() {
					uint tid = gl_LocalInvocationID.x;
					uint column = gl_WorkGroupID.x;
					ivec2 low_id = ivec2(int(column), int(tid));
					ivec2 high_id = ivec2(int(column), int(tid + 128u));
					vec4 t0_low = imageLoad(in_temp0, low_id);
					vec4 t1_low = imageLoad(in_temp1, low_id);
					vec4 t0_high = imageLoad(in_temp0, high_id);
					vec4 t1_high = imageLoad(in_temp1, high_id);
					vec2 low[4] = vec2[4](t0_low.xy, t0_low.zw, t1_low.xy, t1_low.zw);
					vec2 high[4] = vec2[4](t0_high.xy, t0_high.zw, t1_high.xy, t1_high.zw);
					vec2 out_low[4];
					vec2 out_high[4];

					for (int f = 0; f < 4; f++) {
						fft_buf[0][tid] = low[f];
						fft_buf[0][tid + 128u] = high[f];
						barrier();
						uint result = fft_inverse(tid);
						out_low[f] = fft_buf[result][tid];
						out_high[f] = fft_buf[result][tid + 128u];
						barrier();
					}

					imageStore(out_displacement, low_id, vec4(out_low[0].x, out_low[1].x, out_low[0].y, out_low[1].y));
					imageStore(out_derivatives, low_id, vec4(out_low[2].x, out_low[2].y, out_low[3].x, out_low[3].y));
					imageStore(out_displacement, high_id, vec4(out_high[0].x, out_high[1].x, out_high[0].y, out_high[1].y));
					imageStore(out_derivatives, high_id, vec4(out_high[2].x, out_high[2].y, out_high[3].x, out_high[3].y));
				}
			]],
		}
	)
end

for _, cascade in ipairs(WAVE_CASCADES) do
	local function write_wave_block(self, block)
		render3d.WriteCommonBlock(self, block)
		block.time = water.GetWaveTime()
		local waves = water.GetOceanWaves()
		block.wave_choppiness = waves.choppiness
		write_cascade_origin(block.wave_origin, cascade)
		local params = water.GetOcean()
		block.foam_amount = water.GetWhitecapFactor(params.WindSpeed) * params.Foam
		water_field.WriteBlock(self, block, params.ShoalDepth)
		surf.WriteBlock(self, block)
		local fft_textures = ocean_fft.Update()

		for i = 1, #water.FFT_CASCADES do
			block.fft_tex[(i - 1) * 2] = self:GetTextureIndex(fft_textures[i].displacement)
			block.fft_tex[(i - 1) * 2 + 1] = self:GetTextureIndex(fft_textures[i].derivatives)
		end
	end

	local field_surface_glsl = [[
		const float FIELD_TURN_STEP = 0.5235988;
		const float SHELTER_DAMPING = 0.85;
		const float SURF_FOAM = 1.2;
		const float SURF_TAKEOVER = ]] .. surf.TAKEOVER .. [[;
		const float SWASH_DRY_RATE = 0.02;
		const float SWASH_LEVEL_BIAS = ]] .. SWASH_LEVEL_BIAS .. [[;

		void fft_surface_turned(vec2 world_xz, float choppiness, float turn, out float height, out vec2 slope, out float jacobian) {
			vec2 axis = vec2(cos(turn), sin(turn));
			vec2 p = fft_undisplace(vec2(axis.x * world_xz.x + axis.y * world_xz.y, -axis.y * world_xz.x + axis.x * world_xz.y), choppiness);
			vec3 normal;
			fft_surface(p, choppiness, height, normal, jacobian);
			vec2 local_slope = -normal.xz / normal.y;
			slope = vec2(axis.x * local_slope.x - axis.y * local_slope.y, axis.y * local_slope.x + axis.x * local_slope.y);
		}

		void field_surface(vec2 world_xz, float choppiness, out float height, out vec2 slope, out float jacobian, out float shelter) {
			vec2 field = water_field_waves(world_xz);
			shelter = field.y;
			float bin = field.x / FIELD_TURN_STEP;
			float low = floor(bin);
			float blend = bin - low;
			fft_surface_turned(world_xz, choppiness, low * FIELD_TURN_STEP, height, slope, jacobian);

			if (blend > 0.01) {
				float other_height;
				vec2 other_slope;
				float other_jacobian;
				fft_surface_turned(world_xz, choppiness, (low + 1.0) * FIELD_TURN_STEP, other_height, other_slope, other_jacobian);
				float scale = 1.0 / sqrt((1.0 - blend) * (1.0 - blend) + blend * blend);
				height = mix(height, other_height, blend) * scale;
				slope = mix(slope, other_slope, blend) * scale;
				jacobian = 1.0 + (mix(jacobian, other_jacobian, blend) - 1.0) * scale;
			}

			float open_sea = 1.0 - SHELTER_DAMPING * shelter;
			height *= open_sea;
			slope *= open_sea;
			jacobian = 1.0 + (jacobian - 1.0) * open_sea;
		}
	]]
	local fft_fields = {
		{"fft_tex", "int", #water.FFT_CASCADES * 2},
		{"wave_choppiness", "float"},
		{"foam_amount", "float"},
		water_field.GetFields(),
		surf.GetFields(),
	}
	list.insert(
		passes,
		{
			name = get_foam_pipeline_name(cascade),
			ColorFormat = {
				{"r16g16b16a16_sfloat", {"foam", "rgba"}},
			},
			FramebufferSize = {x = WAVE_TEX_SIZE, y = WAVE_TEX_SIZE},
			framebuffer_count = 2,
			fragment = {
				uniform_buffers = {
					{
						name = "wave_block",
						binding_index = 3,
						block = {
							render3d.common_block,
							{"wave_origin", "vec2"},
							{"origin_shift", "vec2"},
							{"history_tex", "int"},
							{"history_valid", "float"},
							{"dt", "float"},
							unpack(fft_fields),
						},
						write = function(self, block)
							write_wave_block(self, block)
							local frame = system.GetFrameNumber()
							local previous = previous_origins[cascade]
							local ox, oz = block.wave_origin[0], block.wave_origin[1]
							block.origin_shift[0] = previous and (ox - previous[1]) / (cascade.world_half * 2) or 0
							block.origin_shift[1] = previous and (oz - previous[2]) / (cascade.world_half * 2) or 0
							previous_origins[cascade] = {ox, oz}
							local pipeline = render3d.pipelines[get_foam_pipeline_name(cascade)]
							block.history_tex = self:GetTextureIndex(pipeline:GetFramebuffer((frame + 1) % 2 + 1):GetAttachment(1))
							block.history_valid = previous and 1 or 0
							block.dt = water.GetStepTime()
							return block
						end,
					},
				},
				shader = ocean_fft.GetGLSL("wave_block", math.min(cascade.fft_count, 2)) .. [[
				const float WAVE_TEX_WORLD_HALF = ]] .. cascade.world_half .. [[;
				const float FOAM_BIAS = ]] .. FOAM_BIAS .. [[;
				const float FOAM_WEIGHT = ]] .. cascade.foam_weight .. [[;
				const float FOAM_GAIN = ]] .. FOAM_GAIN .. [[;
				const float FOAM_DECAY = ]] .. FOAM_DECAY .. [[;
				const float FOAM_ADD = ]] .. FOAM_ADD .. [[;
				const float FOAM_SPREAD = ]] .. FOAM_SPREAD .. [[;
				]] .. glsl_common.GetNoiseGLSL() .. water_field.GetGLSL("wave_block") .. surf.GetGLSL("wave_block") .. field_surface_glsl .. [[

				void main() {
					vec2 world_xz = wave_block.wave_origin + (in_uv * 2.0 - 1.0) * WAVE_TEX_WORLD_HALF;
					float height;
					vec2 slope;
					float jacobian;
					float shelter;
					field_surface(world_xz, wave_block.wave_choppiness, height, slope, jacobian, shelter);
					float depth = water_field_depth(world_xz);
					float surf_height;
					vec2 surf_slope;
					float whitewater;
					float surf_presence;
					float swash_wet;
					surf_wave(world_xz, depth, wave_block.time, shelter, surf_height, surf_slope, whitewater, surf_presence, swash_wet);
					float breaking = water_field_breaking(height, depth) * FOAM_WEIGHT + whitewater * SURF_FOAM;
					float previous = 0.0;
					float previous_wet = 0.0;
					vec2 history_uv = in_uv + wave_block.origin_shift;

					if (wave_block.history_valid > 0.5 && all(greaterThan(history_uv, vec2(0.0))) && all(lessThan(history_uv, vec2(1.0)))) {
						vec2 texel = vec2(1.0 / ]] .. WAVE_TEX_SIZE .. [[.0);
						float spread = min(wave_block.dt * FOAM_SPREAD, 0.2);
						float around = textureLod(TEXTURE(wave_block.history_tex), history_uv + vec2(texel.x, 0.0), 0.0).r
							+ textureLod(TEXTURE(wave_block.history_tex), history_uv - vec2(texel.x, 0.0), 0.0).r
							+ textureLod(TEXTURE(wave_block.history_tex), history_uv + vec2(0.0, texel.y), 0.0).r
							+ textureLod(TEXTURE(wave_block.history_tex), history_uv - vec2(0.0, texel.y), 0.0).r;
						previous = mix(textureLod(TEXTURE(wave_block.history_tex), history_uv, 0.0).r, around * 0.25, spread);
						if (!(previous >= 0.0 && previous < 16.0)) previous = 0.0;
						previous_wet = clamp(textureLod(TEXTURE(wave_block.history_tex), history_uv, 0.0).g, 0.0, 8.0);
					}

					float made = clamp((mix(FOAM_BIAS - 0.15, FOAM_BIAS, wave_block.foam_amount) - jacobian) * FOAM_GAIN, 0.0, 1.0) * wave_block.foam_amount * FOAM_WEIGHT * water_field_damping(depth);
					float wet = max(previous_wet - wave_block.dt * SWASH_DRY_RATE, swash_wet > 0.0 ? surf_height + SWASH_LEVEL_BIAS : 0.0);
					float foam = previous * exp(-FOAM_DECAY * (1.0 + previous) * wave_block.dt) + (made + breaking) * FOAM_ADD * wave_block.dt;
					set_foam(vec4(foam, wet, 0.0, 1.0));
				}
				]],
			},
			CullMode = "none",
			DepthTest = false,
			DepthWrite = false,
		}
	)
	list.insert(
		passes,
		{
			name = cascade.name,
			ColorFormat = {
				{"r16g16b16a16_sfloat", {"wave_data", "rgba"}},
			},
			FramebufferSize = {x = WAVE_TEX_SIZE, y = WAVE_TEX_SIZE},
			fragment = {
				uniform_buffers = {
					{
						name = "wave_block",
						binding_index = 3,
						block = {
							render3d.common_block,
							{"wave_origin", "vec2"},
							{"foam_tex", "int"},
							unpack(fft_fields),
						},
						write = function(self, block)
							write_wave_block(self, block)
							local pipeline = render3d.pipelines[get_foam_pipeline_name(cascade)]
							block.foam_tex = self:GetTextureIndex(pipeline:GetFramebuffer(system.GetFrameNumber() % 2 + 1):GetAttachment(1))
							return block
						end,
					},
				},
				shader = ocean_fft.GetGLSL("wave_block", cascade.fft_count) .. [[
				const float WAVE_TEX_WORLD_HALF = ]] .. cascade.world_half .. [[;
				const float FOAM_BIAS = ]] .. FOAM_BIAS .. [[;
				const float FOAM_WEIGHT = ]] .. cascade.foam_weight .. [[;
				const float FOAM_GAIN = ]] .. FOAM_GAIN .. [[;
				]] .. glsl_common.GetNoiseGLSL() .. water_field.GetGLSL("wave_block") .. surf.GetGLSL("wave_block") .. field_surface_glsl .. [[

				void main() {
					vec2 world_xz = wave_block.wave_origin + (in_uv * 2.0 - 1.0) * WAVE_TEX_WORLD_HALF;
					float height;
					vec2 slope;
					float jacobian;
					float shelter;
					field_surface(world_xz, wave_block.wave_choppiness, height, slope, jacobian, shelter);
					float left_behind = textureLod(TEXTURE(wave_block.foam_tex), in_uv, 0.0).r;
					float depth = water_field_depth(world_xz);
					float fresh = clamp((mix(FOAM_BIAS - 0.15, FOAM_BIAS, wave_block.foam_amount) - jacobian) * FOAM_GAIN, 0.0, 1.0) * wave_block.foam_amount * FOAM_WEIGHT * water_field_damping(depth);
					float surf_height;
					vec2 surf_slope;
					float whitewater;
					float surf_presence;
					float swash_wet;
					surf_wave(world_xz, depth, wave_block.time, shelter, surf_height, surf_slope, whitewater, surf_presence, swash_wet);
					float damping = water_field_damping(depth) * water_field_height_scale(height, depth) * (1.0 - SURF_TAKEOVER * surf_presence);
					fresh += water_field_breaking(height, depth) * FOAM_WEIGHT + whitewater * SURF_FOAM * 0.25;
					set_wave_data(vec4(height * damping + surf_height, slope * damping + surf_slope, left_behind + fresh));
				}
				]],
			},
			CullMode = "none",
			DepthTest = false,
			DepthWrite = false,
		}
	)
end

local SEA_DRIFT = 0.7
local sea_offset = {x = 0, z = 0, time = 0, frame = -1}

local function write_ocean(self, block)
	local params = water.GetOcean()
	local waves = water.GetOceanWaves()
	block.ocean_enabled = render3d.IsOceanEnabled() and 1 or 0
	block.gi_tinted = (RAY_QUERY and ray_materials.HasVolumes()) and 1 or 0
	block.sun_tinted = (optical_rays.IsEnabled() and ray_materials.HasVolumes()) and 1 or 0
	block.ocean_level = render3d.GetOceanLevel()
	local medium = media.presets[params.Medium]
	block.ocean_absorption[0] = medium.Absorption.x
	block.ocean_absorption[1] = medium.Absorption.y
	block.ocean_absorption[2] = medium.Absorption.z
	block.ocean_absorption[3] = medium.IOR
	block.ocean_scattering[0] = medium.Scattering.x
	block.ocean_scattering[1] = medium.Scattering.y
	block.ocean_scattering[2] = medium.Scattering.z
	block.ocean_molecular[0] = medium.Molecular.x
	block.ocean_molecular[1] = medium.Molecular.y
	block.ocean_molecular[2] = medium.Molecular.z
	block.ocean_phase_g = medium.PhaseG
	block.ocean_scattering[3] = params.Foam
	block.ocean_wave_info[0] = waves.height_std * 3.5 + 0.05 + surf.GetHeightBound()
	block.ocean_wave_info[1] = params.Caustics
	block.ocean_wave_info[2] = waves.total_slope_variance
	block.ocean_wave_info[3] = medium.AbbeNumber

	for i = 1, 2 do
		local pipeline = render3d.pipelines[get_foam_pipeline_name(WAVE_CASCADES[i])]
		block.swash_wet_tex[i - 1] = pipeline and
			pipeline.framebuffers and
			self:GetTextureIndex(pipeline:GetFramebuffer(system.GetFrameNumber() % 2 + 1):GetAttachment(1)) or
			-1
	end

	for i, cascade in ipairs(WAVE_CASCADES) do
		local pipeline = render3d.pipelines[cascade.name]
		block.wave_tex[i - 1] = pipeline and
			pipeline.framebuffers and
			self:GetTextureIndex(pipeline:GetFramebuffer():GetAttachment(1)) or
			-1
		write_cascade_origin(block.wave_origin[i - 1], cascade)
		block.wave_origin[i - 1][2] = cascade.world_half
		block.wave_origin[i - 1][3] = water.GetResolvedSlopeVariance(waves, get_cascade_texel_size(cascade))
	end

	local fft_textures = ocean_fft.Update()
	block.far_tex[0] = self:GetTextureIndex(fft_textures[1].displacement)
	block.far_tex[1] = self:GetTextureIndex(fft_textures[1].derivatives)
	block.wave_choppiness = waves.choppiness
	block.far_variance = block.wave_origin[#WAVE_CASCADES - 1][3]
	block.detail_info[0] = math.cos(waves.wind_angle)
	block.detail_info[1] = math.sin(waves.wind_angle)
	block.detail_info[2] = waves.detail_wavelength
	block.detail_info[3] = waves.detail_slope_variance / water.DETAIL_OCTAVES
	block.ripple_info[0] = params.RippleStrength
	block.ripple_info[1] = params.RippleScale
	block.ripple_info[2] = params.RippleLifetime
	block.sea_info[0] = params.WindSpeed
	block.sea_info[1] = params.GustAmount
	block.sea_info[2] = params.SlickAmount
	block.sea_info[3] = params.StreakAmount
	local frame = system.GetFrameNumber()

	if frame ~= sea_offset.frame then
		local drift = params.WindSpeed * SEA_DRIFT * water.GetStepTime()
		sea_offset.x = sea_offset.x + math.cos(waves.wind_angle) * drift
		sea_offset.z = sea_offset.z + math.sin(waves.wind_angle) * drift
		sea_offset.time = sea_offset.time + water.GetStepTime()
		sea_offset.frame = frame
	end

	block.sea_offset[0] = sea_offset.x
	block.sea_offset[1] = sea_offset.z
	block.sea_offset[2] = sea_offset.time
end

list.insert(
	passes,
	{
		name = "water",
		ComputePass = true,
		ColorFormat = {
			{"r16g16b16a16_sfloat", {"color", "rgba"}},
			{"r32g32b32a32_sfloat", {"water_distance", "rgba"}},
		},
		framebuffer_count = 2,
		dont_create_framebuffers = true,
		LocalSize = {x = 8, y = 8, z = 1},
		ray_generation = RAY_QUERY and scene_hits.GetRayGeneration(reorder_pvar:Get()) or nil,
		storage_images = {
			{binding_index = 0, attachment = 1, dst_stage = {"compute", "fragment"}},
			{binding_index = 1, attachment = 2, dst_stage = {"compute", "fragment"}},
		},
		storage_buffers = not RAY_QUERY and {{binding_index = BINDING_OPTICAL}} or nil,
		on_pre_draw = function(self, cmd, frame, desc)
			if RAY_QUERY then
				scene_hits.Bind(self, cmd, desc, REFLECTION_BINDINGS)
			else
				ray_materials.BindOpticalVolumes(self, desc, BINDING_OPTICAL)
			end
		end,
		descriptor_sets = RAY_QUERY and
			scene_hits.GetDescriptorSets(REFLECTION_BINDINGS, "compute") or
			nil,
		sampled_images = RAY_QUERY and
			{
				{
					binding_index = BINDING_OCCLUSION,
					get_descriptor = light_occlusion.GetOcclusionDescriptor,
				},
			} or
			nil,
		custom_declarations = [[
			layout(set = 0, binding = 0, rgba16f) uniform writeonly image2D out_color;
			layout(set = 0, binding = 1, rgba32f) uniform writeonly image2D out_water_distance;
		]] .. (
				RAY_QUERY and
				scene_hits.GetDeclarationGLSL(REFLECTION_BINDINGS) .. light_occlusion.GetDeclarationGLSL(BINDING_OCCLUSION, 0)
				or
				ray_materials.GetOpticalDeclarationsGLSL(BINDING_OPTICAL)
			),
		uniform_buffers = {
			{
				name = "water_data",
				binding_index = 3,
				block = {
					render3d.camera_block,
					render3d.common_block,
					gbuffer_layout.block,
					{"scene_tex", "int"},
					{"env_tex", "int"},
					{"env_irradiance_tex", "int"},
					{"blue_noise_tex", "int"},
					{"frame", "int"},
					{"features", "int"},
					{"shaft_samples", "int"},
					{"trace_steps", "int"},
					{"rough_rays", "int"},
					{"last_frame_tex", "int"},
					{"prev_view", "mat4"},
					{"prev_projection", "mat4"},
					{"reflection_roughness_cutoff", "float"},
					{"sun_direction", "vec3"},
					{"primary_sun_illuminance", "float"},
					{"primary_sun_color", "vec3"},
					{"ocean_enabled", "int"},
					{"gi_tinted", "int"},
					{"sun_tinted", "int"},
					{"photon_caustics", "int"},
					caustics.coverage_block,
					{"ocean_level", "float"},
					{"ocean_absorption", "vec4"},
					{"ocean_scattering", "vec4"},
					{"ocean_molecular", "vec3"},
					{"ocean_phase_g", "float"},
					{"ocean_wave_info", "vec4"},
					{"wave_tex", "int", #WAVE_CASCADES},
					{"wave_origin", "vec4", #WAVE_CASCADES},
					{"far_tex", "int", 2},
					{"wave_choppiness", "float"},
					{"far_variance", "float"},
					{"detail_info", "vec4"},
					{"ripple_info", "vec4"},
					{"sea_info", "vec4"},
					{"sea_offset", "vec4"},
					{"field_debug", "int"},
					{"swash_wet_tex", "int", 2},
					water_field.GetFields(),
					surf.GetFields(),
					medium_surface.block,
					{"shadows", scene_lights.BuildShadowsBlockLayout()},
					post_source.pre_exposure_block,
					RAY_QUERY and scene_hits.block or nil,
					RAY_QUERY and atmosphere.GetBlockLayout() or nil,
					RAY_QUERY and light_occlusion.GetBlockLayout() or nil,
				},
				write = function(self, block)
					render3d.WriteCameraBlock(self, block)
					render3d.WriteCommonBlock(self, block)
					block.time = water.GetSurfaceTime()
					gbuffer_layout.WriteBlock(self, block)
					post_source.WritePreExposureBlock(self, block)
					local current_idx = system.GetFrameNumber() % 2 + 1

					if not render3d.IsPassEnabled("lighting") then
						block.scene_tex = -1
					else
						block.scene_tex = self:GetTextureIndex(render3d.pipelines.lighting:GetFramebuffer(current_idx):GetAttachment(1))
					end

					block.env_tex = self:GetTextureIndex(render3d.GetEnvironmentTexture())
					block.env_irradiance_tex = self:GetTextureIndex(render3d.GetEnvironmentIrradianceTexture())
					block.blue_noise_tex = self:GetTextureIndex(
						assert(
							assets.GetTexture("textures/render/blue_noise.lua"),
							"the blue noise texture is not registered"
						)
					)
					block.frame = system.GetFrameNumber() % 4096
					local features = 0

					for _, feature in ipairs(FEATURES) do
						if feature.pvar:Get() then features = features + feature.bit end
					end

					block.features = features
					block.shaft_samples = shaft_samples_pvar:Get()
					block.trace_steps = trace_steps_pvar:Get()
					block.rough_rays = math.max(1, math.floor(scene_hits.rough_rays:Get() / 4 + 0.5))
					block.last_frame_tex = render3d.ShouldUseLastFrameHistory() and
						render3d.IsPassEnabled("volumetric_fog") and
						self:GetTextureIndex(post_source.GetFoggedOpaqueSceneTexture()) or
						-1
					local prev_view = render3d.GetPreviousViewMatrix() or render3d.GetCamera():BuildViewMatrix()
					local prev_projection = render3d.GetPreviousProjectionMatrix() or
						render3d.GetCamera():BuildProjectionMatrix()
					prev_view:CopyToFloatPointer(block.prev_view)
					prev_projection:CopyToFloatPointer(block.prev_projection)
					local _, gi_end = ibl.GetReflectionGIRange()
					block.reflection_roughness_cutoff = gi_end
					local lights = render3d.GetLights()
					directional_shadows.GetPrimarySunDirection(lights):CopyToFloatPointer(block.sun_direction)
					block.primary_sun_illuminance = directional_shadows.GetPrimarySunIlluminance(lights)
					directional_shadows.GetPrimarySunColor(lights):CopyToFloatPointer(block.primary_sun_color)
					scene_lights.WriteShadowBlock(self, block.shadows, lights)
					write_ocean(self, block)
					water_field.WriteBlock(self, block, water.GetOcean().ShoalDepth)
					surf.WriteBlock(self, block)
					block.field_debug = field_debug_pvar:Get() and 1 or 0
					medium_surface.WriteBlock(self, block)
					caustics.WriteCoverageBlock(block)
					block.photon_caustics = (
							optical_rays.IsEnabled() and
							(
								caustics.IsLit() or
								path_trace.AreCausticsShown()
							)
						)
						and
						1 or
						0

					if RAY_QUERY then
						light_occlusion.WriteOcclusionBlock(block, lights)
						scene_hits.WriteBlock(self, block)
						atmosphere.WriteBlock(
							self,
							block,
							render3d.GetCamera():GetPosition(),
							directional_shadows.GetPrimarySunDirection(render3d.GetLights())
						)
						block.reflection_screenspace_roughness = screenspace_roughness_pvar:Get()
					end

					return block
				end,
			},
			RAY_QUERY and scene_hits.GetRadianceCacheUniformBuffer(8) or nil,
		},
		shader = medium_common.GetGLSL() .. [[
			ivec2 water_pixel;
			vec2 in_uv;

			void set_color(vec4 color) {
				imageStore(out_color, water_pixel, color);
			}

			void set_water_distance(vec4 distance) {
				imageStore(out_water_distance, water_pixel, distance);
			}
			]] .. post_source.GetPreExposureGLSL("water_data") .. [[

			const int WATER_CAUSTICS = 1;
			const int WATER_SHAFTS = 2;
			const int WATER_RIPPLES = 4;
			const int WATER_LIGHTS = 8;
			const int WATER_REFLECTION_TRACE = 16;
			const int WATER_SHORE_FOAM = 32;
			const int WATER_INSCATTER = 64;
			const int WATER_REFRACTION = 128;
			const int WATER_SUN_SHADOWS = 256;
			const int WATER_SHAFT_CAUSTICS = 512;
			const int WATER_AMBIENT_GI = 1024;
			const int WATER_WAVES = 2048;
			const int WATER_ROUGHNESS = 4096;
			const int WATER_UNIFORM_ROUGHNESS = 8192;

			bool water_feature(int bit) {
				return (water_data.features & bit) != 0;
			}

			vec3 get_scene_color(vec2 uv) {
				if (water_data.scene_tex == -1) return vec3(0.0);
				return texture(TEXTURE(water_data.scene_tex), uv).rgb / get_pre_exposure();
			}

			float water_rt_share = 0.0;

			float waterline = 0.0;

			void set_scene_color(vec3 color, float alpha) {
				color *= 1.0 + waterline * 1.5;
				set_color(vec4(min(color * get_pre_exposure(), vec3(65504.0)), alpha));
			}

			#define WATER_NEAR_PLANE (0.1 * water_data.view_scale)
			const float WATER_MAX_SLOPE = 1.5;
			const float WATER_MULTIPLE_SCATTERING = 0.5;
			const float WATER_CREST_GLOW = 20.0;
			float water_particle_backscatter(float g) {
				if (abs(g) < 1e-3) return 0.5;
				return (1.0 - g) / (2.0 * g) * ((1.0 + g) / sqrt(1.0 + g * g) - 1.0);
			}
			const int WAVE_CASCADES = ]] .. #WAVE_CASCADES .. [[;
			const float WAVE_TEXELS_PER_WAVELENGTH = ]] .. water.WAVE_TEXELS_PER_WAVELENGTH .. [[;
			const float WATER_OPEN_DEPTH = 2000.0;
			const float WATER_SCREENSPACE_DISTANCE = 20000.0;

			]] .. gbuffer_layout.GetDecodeGLSL("water_data") .. [[
			]] .. screen_reconstruct.GetWorldPosFromUVGLSL("water_data") .. [[
			]] .. screen_reconstruct.GetViewRayFromUVGLSL("water_data") .. [[
			]] .. screen_refraction.GetGLSL("water_data") .. [[

]] .. glsl_common.GetSunHorizonVisibilityGLSL() .. [[

			]] .. directional_shadows.GetMediumDirectionalShadowGLSL("water_data", "get_water_sun_visibility_shadowed") .. [[

			float get_water_sun_visibility(vec3 p, vec3 dir) {
				return water_feature(WATER_SUN_SHADOWS) ? get_water_sun_visibility_shadowed(p, dir) : 1.0;
			}

			]] .. planet.GLSL .. glsl_common.GetNoiseGLSL() .. glsl_common.GetFresnelGLSL() .. glsl_common.GetBlueNoiseGLSL() .. glsl_common.GetPhaseGLSL() .. ibl.GetBRDFGLSLCode() .. [[
			]] .. ibl.GetEnvironmentGLSLCode() .. (
				RAY_QUERY and
				render3d.GetEmissiveGLSL() .. atmosphere.GetGLSLDefines("water_data", "water_data.primary_sun_illuminance") .. atmosphere.GetAerialPerspectiveGLSLCode() .. scene_hits.GetGLSL("water_data") .. scene_hits.GetDirectionGLSL() .. light_occlusion.GetSamplingGLSL("water_data") .. scene_lights.GetPointShadowGLSL("water_data")
				or
				scene_hits.CONSTANTS_GLSL .. "#define RADIANCE_CACHE_NO_VISIBILITY_RAYS 1e30\nconst float SUN_ANGULAR_RADIUS = " .. atmosphere.SUN_ANGULAR_RADIUS .. ";\n"
			) .. [[


			float get_blue_noise() {
				if (water_data.blue_noise_tex == -1) return 0.5;
				float n = blue_noise_texel(TEXTURE(water_data.blue_noise_tex), water_pixel).r;
				return fract(n + float(water_data.frame) * 0.61803398875);
			}

			vec2 get_blue_noise2(int sample_index) {
				if (water_data.blue_noise_tex == -1) return vec2(0.5);
				return blue_noise_r2(blue_noise_texel(TEXTURE(water_data.blue_noise_tex), water_pixel).rg, float(water_data.frame * water_data.rough_rays + sample_index));
			}

			]] .. medium_surface.GetGLSL("water_data") .. water_field.GetGLSL("water_data") .. surf.GetGLSL("water_data") .. [[

			vec2 foam_cells(vec2 p) {
				vec2 i = floor(p);
				vec2 f = fract(p);
				float d1 = 8.0;
				float d2 = 8.0;

				for (int y = -1; y <= 1; y++) {
					for (int x = -1; x <= 1; x++) {
						vec2 o = vec2(float(x), float(y));
						vec2 r = o + vec2(medium_hash(i + o), medium_hash(i + o + 17.3)) - f;
						float d = dot(r, r);

						if (d < d1) {
							d2 = d1;
							d1 = d;
						} else if (d < d2) {
							d2 = d;
						}
					}
				}

				return sqrt(vec2(d1, d2));
			}

			vec3 foam_pattern(vec2 p, float time, float footprint) {
				vec2 flow = vec2(time * 0.07, -time * 0.05);
				vec2 warp = vec2(value_noise2(p * 0.35 + flow), value_noise2(p * 0.35 + flow + 31.7)) - 0.5;
				vec2 q = p + warp * 1.6;
				float raft = value_noise2(q * 0.5) * 0.5 + value_noise2(q * 1.3 + 7.0) * 0.3;
				float fine_raft = 1.0 - smoothstep(0.3, 1.0, footprint * 3.1);
				raft += mix(0.075, value_noise2(q * 3.1 + 3.3) * 0.15, fine_raft);
				vec2 big = foam_cells(q * 0.9);
				float strands = 1.0 - smoothstep(0.0, 0.3, big.y - big.x);
				float hole = smoothstep(0.38, 0.62, big.x);
				float lace_fade = 1.0 - smoothstep(0.3, 1.0, footprint * 2.6);
				vec2 small = foam_cells(q * 2.6 + 3.1);
				float small_strands = 1.0 - smoothstep(0.0, 0.35, small.y - small.x);
				float density = raft * 0.8 + strands * 0.17 + small_strands * 0.1 * lace_fade - hole * 0.32;
				float bubble_fade = 1.0 - smoothstep(0.3, 1.0, footprint * 11.0);
				float bubbles = mix(0.5, 1.0 - smoothstep(0.1, 0.35, foam_cells(q * 11.0).x), bubble_fade);
				return vec3(density, bubbles, raft);
			}

			vec2 foam_lace(vec2 p, float density, float footprint, float time) {
				vec2 warp = vec2(value_noise2(p * 0.45 + vec2(time * 0.03, 0.0)), value_noise2(p * 0.45 + vec2(5.2, -time * 0.025))) - 0.5;
				vec2 bend = vec2(value_noise2(p * 1.7 + 2.1), value_noise2(p * 1.7 + 8.4)) - 0.5;
				vec2 q = p + warp * 1.4 + bend * 0.7;
				vec2 big = foam_cells(q);
				vec2 small = foam_cells(q * 2.6 + 11.3);
				vec2 tiny = foam_cells(q * 6.5 + 23.7);
				float big_width = mix(0.02, 0.3, density) * mix(0.6, 1.3, value_noise2(q * 2.2 + 3.0));
				float small_width = mix(0.01, 0.2, density);
				float big_soft = 0.03 + footprint * 0.6;
				float small_soft = 0.03 + footprint * 1.6;
				float strands = 1.0 - smoothstep(big_width - big_soft, big_width + big_soft, big.y - big.x);
				float bubbles = 1.0 - smoothstep(small_width - small_soft, small_width + small_soft, small.y - small.x);
				float breakup = value_noise2(q * 1.3 + 17.0) * 0.7 + value_noise2(q * 3.1 + 4.0) * 0.3;
				float lace = max(strands, bubbles * (1.0 - smoothstep(0.1, 0.45, footprint)) * 0.9) * smoothstep(0.75 - density, 0.95 - density, breakup);
				float walls = mix(0.5, 1.0 - smoothstep(0.0, 0.18, tiny.y - tiny.x), 1.0 - smoothstep(0.03, 0.15, footprint));
				float thickness = clamp(1.0 - (big.y - big.x) / max(big_width, 0.05), 0.0, 1.0);
				float resolved = 1.0 - smoothstep(0.3, 1.0, footprint);
				float alpha = mix(density * 0.8, lace * mix(0.6, 1.0, walls), resolved) * smoothstep(0.0, 0.12, density);
				return vec2(alpha, mix(0.75, mix(0.5, 1.0, max(thickness * 0.5, walls)), resolved));
			}

			float get_pixel_footprint(float t, float cos_incidence) {
				float pixel_angle = 2.0 / (abs(water_data.projection[1][1]) * water_data.render_size.y);
				return t * pixel_angle / sqrt(max(abs(cos_incidence), 0.03));
			}

			vec4 sample_wave_cascade(int cascade, vec2 world_xz, out float coverage) {
				coverage = 0.0;
				int tex = water_data.wave_tex[cascade];
				if (tex == -1) return vec4(0.0);
				vec4 origin = water_data.wave_origin[cascade];
				vec2 uv = (world_xz - origin.xy) * (0.5 / origin.z) + 0.5;
				vec2 edge = abs(uv - 0.5) * 2.0;
				coverage = 1.0 - smoothstep(0.75, 0.97, max(edge.x, edge.y));
				if (coverage <= 0.0) return vec4(0.0);
				return textureLod(TEXTURE(tex), uv, 0.0);
			}

			vec4 get_wave_data(vec2 world_xz, float footprint, out float resolved_variance) {
				vec4 data = vec4(0.0);
				resolved_variance = 0.0;
				if (!water_feature(WATER_WAVES)) return data;
				{
					const float FAR_TILE = ]] .. water.FFT_CASCADES[1].size .. [[;
					vec2 uv = world_xz / FAR_TILE + 0.5 / ]] .. water.FFT_SIZE .. [[.0;
					vec2 shifted = world_xz - water_data.wave_choppiness * textureLod(TEXTURE(water_data.far_tex[0]), uv, 0.0).xz;
					uv = shifted / FAR_TILE + 0.5 / ]] .. water.FFT_SIZE .. [[.0;
					float texel = FAR_TILE / ]] .. water.FFT_SIZE .. [[.0;
					float lod = max(log2(footprint / texel), 0.0);
					float weight = medium_surface_resolve(texel * WAVE_TEXELS_PER_WAVELENGTH, footprint);
					vec4 far_derivatives = textureLod(TEXTURE(water_data.far_tex[1]), uv, lod);
					data = vec4(textureLod(TEXTURE(water_data.far_tex[0]), uv, lod).y, far_derivatives.xy / (1.0 + water_data.wave_choppiness * far_derivatives.zw), 0.0);
					data *= weight;
					resolved_variance = water_data.far_variance * weight;
				}

				for (int i = WAVE_CASCADES - 1; i >= 0; i--) {
					float coverage;
					vec4 cascade = sample_wave_cascade(i, world_xz, coverage);
					float texel = water_data.wave_origin[i].z * 2.0 / ]] .. WAVE_TEX_SIZE .. [[.0;
					float weight = coverage * medium_surface_resolve(texel * WAVE_TEXELS_PER_WAVELENGTH, footprint);
					data = mix(data, cascade, weight);
					resolved_variance = mix(resolved_variance, water_data.wave_origin[i].w, weight);
				}

				return data;
			}

			float get_water_surface_height(vec2 world_xz) {
				float variance;
				return water_data.ocean_level - planet_drop(world_xz) + get_wave_data(world_xz, 0.0, variance).r;
			}

			const float OCEAN_RIPPLE_UPWIND_SHARE = 0.1;

			float sea_noise(vec2 p, float seed) {
				return value_noise2(p + vec2(seed * 31.7, seed * 17.3));
			}

			vec4 get_sea_detail(vec2 xz) {
				vec4 info = water_data.sea_info;
				vec2 wind = water_data.detail_info.xy;
				vec2 p = xz - water_data.sea_offset.xy;
				float g1 = sea_noise(p / 620.0, 1.0);
				float g2 = sea_noise(p / 230.0 + vec2(water_data.sea_offset.z * 0.0009, 0.37), 2.0);
				float gust = clamp((g1 * 0.62 + g2 * 0.38 - 0.5) * 3.0 * info.y + 0.5, 0.0, 1.0);
				float along = dot(p, wind);
				float across = dot(p, vec2(-wind.y, wind.x)) + (g2 - 0.5) * 26.0;
				float calm_wind = smoothstep(13.0, 4.0, info.x);
				float slick = smoothstep(0.6, 0.72, sea_noise(vec2(along / 1100.0, across / 70.0), 3.0)) * (1.0 - gust * 0.8) * calm_wind * info.z;
				float fresh_wind = smoothstep(6.0, 12.0, info.x);
				float streak = smoothstep(0.66, 0.8, sea_noise(vec2(along / 380.0, across / 11.0) + vec2(0.13, 0.71), 4.0)) * smoothstep(0.4, 0.62, sea_noise(vec2(along / 140.0, across / 40.0) + vec2(0.51, 0.29), 5.0)) * fresh_wind * info.w;
				float rough = mix(0.5, 1.5, gust) * (1.0 - slick * 0.8) * (1.0 - streak / max(info.w, 1e-3) * 0.45);
				return vec4(rough, gust, slick, streak);
			}

			vec4 sea_state = vec4(1.0, 0.5, 0.0, 0.0);

			float add_detail_ripples(vec2 p, float footprint, float rough, inout vec2 grad, inout vec3 hess) {
				vec4 info = water_data.detail_info;
				vec4 ripple = water_data.ripple_info;
				if (!water_feature(WATER_RIPPLES) || !water_feature(WATER_WAVES)) return info.w * float(MEDIUM_SURFACE_OCTAVES);
				float drawn = info.w * ripple.x * rough * rough;

				if (water_data.bump_tex != -1) {
					float lost = medium_surface_bump(p, footprint, 1.0, info.xy, 1.0, grad, hess);
					return max(info.w * float(MEDIUM_SURFACE_OCTAVES) - water_data.bump_info.x * 0.0225 * 10.0 + lost, 0.0);
				}

				return medium_surface_ripples(p, footprint, info.xy, vec2(0.0), drawn, info.z * ripple.y, OCEAN_RIPPLE_UPWIND_SHARE, ripple.z, grad, hess) + (info.w - drawn) * float(MEDIUM_SURFACE_OCTAVES);
			}

			float height_map_tracing(vec3 ray_dir, float plane_t, vec3 camera_origin, float scene_limit, out vec3 hit_pos) {
				float wave_bound = water_data.ocean_wave_info.x;

				if (water_data.wave_tex[0] == -1) {
					hit_pos = ray_dir * plane_t;
					return plane_t;
				}

				float camera_height = camera_origin.y - get_water_surface_height(camera_origin.xz);

				if (camera_height >= 0.0) {
					vec2 top_hit = planet_sphere_intersect(camera_origin, ray_dir, water_data.ocean_level + wave_bound);
					vec2 bottom_hit = planet_sphere_intersect(camera_origin, ray_dir, water_data.ocean_level - wave_bound);
					float t = max(top_hit.x, 0.0);
					float t_end = min(bottom_hit.x > 0.0 ? bottom_hit.x : top_hit.y, scene_limit);

					if (t >= t_end) return -1.0;

					float horizontal = sqrt(max(1.0 - ray_dir.y * ray_dir.y, 0.0));
					float approach = WATER_MAX_SLOPE * horizontal + max(-ray_dir.y, 0.0);
					float prev_t = t;
					bool crossed = false;
					bool reached_end = false;
					float last_h = 1.0;

					for (int i = 0; i < water_data.trace_steps; i++) {
						vec3 p = ray_dir * t + camera_origin;
						float h = p.y - get_water_surface_height(p.xz);
						last_h = h;

						if (h < 0.0) {
							crossed = true;
							break;
						}

						if (t >= t_end) {
							reached_end = true;
							break;
						}

						prev_t = t;
						t = min(t + max(h / approach, 0.008 * t + 0.02), t_end);
					}

					if (!crossed && !reached_end) {
						hit_pos = ray_dir * t;
						return t;
					}

					if (!crossed) {
						float mean_t = planet_surface_t(camera_origin, ray_dir, water_data.ocean_level);

						if (last_h < wave_bound * 2.0 && mean_t > 0.0 && mean_t < scene_limit) {
							hit_pos = ray_dir * mean_t;
							return mean_t;
						}

						return -1.0;
					}

					float tm = prev_t;
					float tx = t;

					for (int i = 0; i < 14; i++) {
						float tmid = 0.5 * (tm + tx);
						vec3 pmid = ray_dir * tmid + camera_origin;

						if (pmid.y - get_water_surface_height(pmid.xz) > 0.0) {
							tm = tmid;
						} else {
							tx = tmid;
						}
					}

					float hit_t = 0.5 * (tm + tx);
					hit_pos = ray_dir * hit_t;
					return hit_t;
				}

				float vertical_span = abs(camera_height) + wave_bound * 4.0;
				float search_radius = clamp(vertical_span / max(abs(ray_dir.y), 0.02), 8.0, 256.0);

				if (plane_t <= 0.0 && camera_height >= 0.0) {
					search_radius = min(search_radius, mix(24.0, 64.0, smoothstep(0.0, wave_bound * 1.7, camera_height)));
				}

				if (plane_t > 0.0 && camera_height >= 0.0) {
					search_radius = clamp(wave_bound * 2.6 / max(abs(ray_dir.y), 0.002), 8.0, 8192.0);
				}

				float tm = max(plane_t - search_radius, 0.0);

				if (tm >= scene_limit) return -1.0;

				float tx = min(plane_t + search_radius, scene_limit);
				float start_t = tm;
				float start_h = 0.0;

				if (camera_height >= 0.0 && tm <= 0.0) {
					start_t = 0.0;
					start_h = camera_height;
				} else {
					vec3 pstart = ray_dir * start_t;
					start_h = (pstart.y + camera_origin.y) - get_water_surface_height(pstart.xz + camera_origin.xz);
				}

				float prev_t = start_t;
				float prev_h = start_h;
				vec3 pend = ray_dir * tx;
				float end_h = (pend.y + camera_origin.y) - get_water_surface_height(pend.xz + camera_origin.xz);
				int trace_samples = int(mix(32.0, 96.0, 1.0 - smoothstep(0.08, 0.35, abs(ray_dir.y))));
				float trace_bias = mix(1.15, 2.75, 1.0 - smoothstep(0.08, 0.35, abs(ray_dir.y)));
				bool found_bracket = false;

				for (int i = 1; i <= 96; i++) {
					if (i > trace_samples) break;
					float sample_frac = pow(float(i) / float(trace_samples), trace_bias);
					float sample_t = mix(start_t, tx, sample_frac);
					vec3 psample = ray_dir * sample_t;
					float sample_h = (psample.y + camera_origin.y) - get_water_surface_height(psample.xz + camera_origin.xz);

					if (sample_h * prev_h <= 0.00) {
						tm = prev_t;
						tx = sample_t;
						found_bracket = true;
						break;
					}

					prev_t = sample_t;
					prev_h = sample_h;
				}

				if (!found_bracket) {
					if (start_h * end_h > 0.0) {
						float mean_t = planet_surface_t(camera_origin, ray_dir, water_data.ocean_level);

						if (camera_height >= 0.0 && mean_t > 0.0 && mean_t < scene_limit) {
							hit_pos = ray_dir * mean_t;
							return mean_t;
						}

						return -1.0;
					}

					tm = start_t;
				}

				vec3 pm = ray_dir * tm;
				float hm = (pm.y + camera_origin.y) - get_water_surface_height(pm.xz + camera_origin.xz);

				for (int i = 0; i < 14; i++) {
					float tmid = 0.5 * (tm + tx);
					vec3 pmid = ray_dir * tmid;
					float hmid = (pmid.y + camera_origin.y) - get_water_surface_height(pmid.xz + camera_origin.xz);
					if (hmid * hm > 0.0) {
						tm = tmid;
						hm = hmid;
					} else {
						tx = tmid;
					}
				}

				float tfinal = 0.5 * (tm + tx);
				hit_pos = ray_dir * tfinal;
				return tfinal;
			}


			optical_volume water_record(int i) {
				return optical_volumes[optical_ranges.x + i];
			}

			mat4 water_volume_to_local(int i) {
				return water_record(i).to_local;
			}

			vec4 water_volume_shape(int i) {
				return vec4(water_record(i).shape, water_record(i).surface_y);
			}

			vec4 water_volume_absorption(int i) {
				return vec4(water_record(i).absorption, water_record(i).ior);
			}

			vec4 water_volume_scattering(int i) {
				return vec4(water_record(i).scattering, water_record(i).roughness);
			}

			vec4 water_volume_waves(int i) {
				return vec4(water_record(i).wave, water_record(i).wave_length, water_record(i).wind_direction, water_record(i).foam);
			}

			vec4 water_volume_flow(int i) {
				return vec4(water_record(i).flow, water_record(i).caustics, water_record(i).abbe);
			}

			vec4 water_volume_misc(int i) {
				return vec4(water_record(i).closed, water_record(i).g, 0.0, 0.0);
			}

			bool intersect_volume(int i, vec3 ray_origin, vec3 ray_dir, out float t_entry, out float t_exit, out bool top) {
				return medium_volume_intersect(water_volume_to_local(i), water_volume_shape(i).xyz, 0.0, ray_origin, ray_dir, t_entry, t_exit, top);
			}

			float get_volume_exit(int i, vec3 ray_origin, vec3 ray_dir) {
				float t_entry;
				float t_exit;
				bool top;
				if (!intersect_volume(i, ray_origin, ray_dir, t_entry, t_exit, top)) return 0.0;
				return t_exit;
			}

			bool is_inside_volume(int i, vec3 p) {
				vec4 shape = water_volume_shape(i);
				vec3 local = (water_volume_to_local(i) * vec4(p, 1.0)).xyz;
				return all(lessThanEqual(abs(local.xz), shape.xz + 0.05)) && local.y <= 0.0 && local.y >= -shape.y - 0.05;
			}

			float get_volume_ripples(int i, vec2 world_xz, float footprint, out vec2 grad, inout vec3 hess) {
				return medium_surface_gradient(water_volume_waves(i), water_volume_flow(i).xy, world_xz, footprint, grad, hess);
			}


			struct Water {
				int volume;
				vec3 absorption;
				vec3 particles;
				vec3 molecular;
				float g;
				float ior;
				float abbe;
				float surface_y;
				float foam;
				float caustics;
				float roughness;
				float closed;
				vec2 flow;
			};

			Water get_ocean_water(vec3 world_pos) {
				Water w;
				w.volume = -1;
				w.absorption = water_data.ocean_absorption.rgb;
				w.particles = water_data.ocean_scattering.rgb;
				w.molecular = water_data.ocean_molecular;
				w.g = water_data.ocean_phase_g;
				w.ior = water_data.ocean_absorption.w;
				w.abbe = water_data.ocean_wave_info.w;
				w.surface_y = water_data.ocean_level - planet_drop(world_pos.xz);
				w.foam = water_data.ocean_scattering.w;
				w.caustics = water_data.ocean_wave_info.y;
				w.roughness = 0.0;
				w.closed = 0.0;
				w.flow = vec2(0.0);
				return w;
			}

			Water get_volume_water(int i) {
				Water w;
				w.volume = i;
				w.absorption = water_volume_absorption(i).rgb;
				w.particles = water_volume_scattering(i).rgb;
				w.molecular = water_record(i).molecular;
				w.g = water_volume_misc(i).y;
				w.ior = water_volume_absorption(i).w;
				w.abbe = water_volume_flow(i).w;
				w.surface_y = water_volume_shape(i).w;
				w.foam = water_volume_waves(i).w;
				w.caustics = water_volume_flow(i).z;
				w.roughness = water_volume_scattering(i).w;
				w.closed = water_volume_misc(i).x;
				w.flow = water_volume_flow(i).xy;
				return w;
			}

			const float VOLUME_EDGE_BLEND = 12.0;

			Water mix_water(Water a, Water b, float t) {
				Water w = b;
				w.absorption = mix(a.absorption, b.absorption, t);
				w.particles = mix(a.particles, b.particles, t);
				w.molecular = mix(a.molecular, b.molecular, t);
				w.g = mix(a.g, b.g, t);
				w.ior = mix(a.ior, b.ior, t);
				w.abbe = mix(a.abbe, b.abbe, t);
				w.foam = mix(a.foam, b.foam, t);
				w.caustics = mix(a.caustics, b.caustics, t);
				w.roughness = mix(a.roughness, b.roughness, t);
				w.closed = mix(a.closed, b.closed, t);
				w.flow = mix(a.flow, b.flow, t);
				return w;
			}

			vec3 get_extinction(Water w) {
				return w.absorption + w.molecular + w.particles;
			}

			vec3 water_scatter(Water w, float mu) {
				return medium_scatter_phase(w.molecular, w.particles, w.g, mu);
			}

			vec3 get_sun_illuminance() {
				float above_horizon = smoothstep(-0.02, 0.04, water_data.sun_direction.y);
				return water_data.primary_sun_color * (water_data.primary_sun_illuminance * above_horizon);
			}

			vec3 get_underwater_sun_dir(Water w, out float transmission) {
				vec3 sun = normalize(water_data.sun_direction);
				float cos_i = max(sun.y, 0.0);
				transmission = 1.0 - fresnel_dielectric(cos_i, 1.0 / w.ior);
				return normalize(vec3(-sun.x / w.ior, -medium_refracted_cosine(cos_i, w.ior), -sun.z / w.ior));
			}

			vec3 get_ambient_irradiance(vec3 P, float visibility_min_weight, bool smooth_blend) {
				vec3 sky = sample_environment_irradiance(water_data.env_irradiance_tex, vec3(0.0, 1.0, 0.0));
				#ifdef SCENE_HITS
				if (scene_hits_ready() && water_feature(WATER_AMBIENT_GI)) {
					float weight;
					vec4 gi = gi_sample_irradiance(P, vec3(0.0, 1.0, 0.0), vec3(0.0, 1.0, 0.0), smooth_blend, visibility_min_weight, weight);
					if (weight > 0.0) return gi.rgb;
				}
				#endif
				return sky;
			}

			vec3 integrate_attenuated(vec3 sigma, float depth_start, float rate, float len, float mu) {
				vec3 x = sigma * ((1.0 + rate / mu) * len);
				vec3 first = exp(-sigma * (depth_start / mu));
				vec3 last = exp(-sigma * (depth_start / mu) - x);
				vec3 series = first * (1.0 - x * (0.5 - x / 6.0));
				bvec3 near_zero = lessThan(abs(x), vec3(1e-3));
				return len * mix((first - last) / mix(x, vec3(1.0), near_zero), series, near_zero);
			}

			#define WATER_LIGHT_RANGE (40.0 * water_data.view_scale)
			const int WATER_LIGHT_SAMPLES = 4;
			const int WATER_LIGHT_MAX_PER_SAMPLE = 6;

			vec3 get_caustic(Water w, vec3 world_pos, float footprint, int newton_steps, float fade, bool detail);

			#ifdef SCENE_HITS
			]] .. medium_lighting.GetLocalLightsGLSL(
				"water_data",
				"WATER_LIGHT_MAX_PER_SAMPLE",
				{
					name = "get_water_local_light_scattering",
					params = "Water w, vec3 sigma",
					phase = "water_scatter(w, mu)",
					attenuation = "exp(-sigma * (light.position.y > w.surface_y ? min(dist, max(w.surface_y - world_pos.y, 0.0) / max(L.y, 0.1)) : dist))",
				}
			) .. [[
			#endif


			float water_shaft_sample(Water w, vec3 sun_dir, float shaft_focus, vec3 p) {
				vec3 surface = p - sun_dir * ((p.y - w.surface_y) / sun_dir.y);
				float shaft = get_water_sun_visibility(surface, water_data.sun_direction);

				#ifdef SCENE_HITS
				if (shaft > 0.0 && scene_hits_ready() && water_feature(WATER_SUN_SHADOWS) && !scene_hit_visible(p, -sun_dir, distance(p, surface) - 0.05)) shaft = 0.0;
				#endif

				if (shaft_focus > 0.0 && shaft > 0.0) {
					shaft *= mix(1.0, get_caustic(w, p, get_pixel_footprint(distance(p, water_data.camera_position.xyz), 1.0), 0, 3.0, false).g, shaft_focus);
				}

				return shaft;
			}

			]] .. medium_common.GetShaftGLSL{
				name = "water_shaft",
				params = "Water w, vec3 sun_dir, float shaft_focus",
				sample = "vec3(water_shaft_sample(w, sun_dir, shaft_focus, p))",
			} .. [[

			vec3 get_water_inscatter(Water w, vec3 origin, vec3 dir, float len, float jitter, out vec3 transmittance) {
				vec3 sigma = get_extinction(w);
				transmittance = exp(-sigma * len);
				float depth_start = max(w.surface_y - origin.y, 0.0);
				float rate = -dir.y;
				float sun_transmission;
				vec3 sun_dir = get_underwater_sun_dir(w, sun_transmission);
				float sun_mu = max(-sun_dir.y, 0.05);
				vec3 sun_light = get_sun_illuminance() * sun_transmission;
				float visibility = 0.0;

				if (dot(sun_light, sun_light) > 0.0 && water_feature(WATER_SHAFTS)) {
					float shadow_len = min(len, 60.0 * water_data.view_scale);

					float shaft_focus = 1.0 - smoothstep(25.0 * water_data.view_scale, 140.0 * water_data.view_scale, distance(origin, water_data.camera_position.xyz));

					int shaft_samples = min(len < 2.0 ? 2 : (len < 8.0 ? 4 : 8), water_data.shaft_samples);

					visibility = water_shaft(w, sun_dir, shaft_focus, origin, dir, shadow_len, shaft_samples, jitter, vec3(0.0)).x / max(shadow_len, 1e-4);
				}

				vec3 backscatter = w.molecular * 0.5 + w.particles * water_particle_backscatter(w.g);
				vec3 diffuse_scatter = backscatter * (WATER_MULTIPLE_SCATTERING * 0.33 * 4.0) / (w.absorption + backscatter) * sigma / PI;
				vec3 sun_scatter = sun_light * visibility * (water_scatter(w, dot(-dir, sun_dir)) + diffuse_scatter) * integrate_attenuated(sigma, depth_start, rate, len, sun_mu);
				float particle_share = mix(water_particle_backscatter(w.g), 1.0 - water_particle_backscatter(w.g), 0.5 + 0.5 * dir.y) / (2.0 * PI);
				vec3 sky_phase = w.molecular / (4.0 * PI) + w.particles * particle_share;
				vec3 ambient = sample_environment_irradiance(water_data.env_irradiance_tex, vec3(0.0, 1.0, 0.0));

				#ifdef SCENE_HITS
				if (scene_hits_ready() && water_feature(WATER_AMBIENT_GI)) {
					float f = jitter;
					ambient = get_ambient_irradiance(origin + dir * (min(len, 60.0) * f * f), RADIANCE_CACHE_NO_VISIBILITY_RAYS, false);
				}
				#endif

				vec3 sky_scatter = ambient * (PI * sky_phase + diffuse_scatter) * integrate_attenuated(sigma, depth_start, rate, len, 0.75);
				vec3 light_scatter = vec3(0.0);

				#ifdef SCENE_HITS
				if (scene_hits_ready() && water_feature(WATER_LIGHTS)) {
					float light_len = min(len, WATER_LIGHT_RANGE);

					for (int i = 0; i < WATER_LIGHT_SAMPLES; i++) {
						float t = light_len * (float(i) + jitter) / float(WATER_LIGHT_SAMPLES);
						vec3 point_light = get_water_local_light_scattering(dir, origin + dir * t, w, sigma);
						light_scatter += point_light * exp(-sigma * t) * (light_len / float(WATER_LIGHT_SAMPLES));
					}
				}
				#endif

				return sun_scatter + sky_scatter + light_scatter;
			}

			]] .. caustics.GetCoverageGLSL("water_data") .. [[

			const float WET_DARKENING = 0.65;

			vec3 relight_submerged(Water w, vec2 uv, vec3 scene_color, vec3 world_pos, vec3 caustic) {
				float depth = w.surface_y - world_pos.y;
				if (depth <= 0.0 || (w.volume >= 0 && water_data.photon_caustics != 0 && caustic_covered(int(water_data.caustic_sun.w), vec3(0.0), world_pos))) return scene_color;
				vec3 sigma = get_extinction(w);
				float sun_transmission;
				vec3 sun_dir = get_underwater_sun_dir(w, sun_transmission);
				vec3 normal = gbuffer_normal(uv);
				float porous = 1.0 - gbuffer_metallic(uv);
				vec3 albedo = gbuffer_albedo(uv) * porous;
				float no_l = max(dot(normal, normalize(water_data.sun_direction)), 0.0);
				float shadow = get_water_sun_visibility(world_pos + normal * 0.1, water_data.sun_direction);
				vec3 sun_path = exp(-sigma * (depth / max(-sun_dir.y, 0.05)));
				vec3 sky_path = exp(-sigma * (depth / 0.75));
				vec3 sun_in_scene = water_data.sun_tinted != 0 ? sun_path : vec3(1.0);
				vec3 direct = min(albedo / PI * get_sun_illuminance() * (no_l * shadow) * sun_in_scene, scene_color);
				vec3 rest = scene_color - direct;
				return (direct * (water_data.sun_tinted != 0 ? vec3(1.0) : sun_path) * (sun_transmission * caustic) + rest * (water_data.gi_tinted != 0 ? vec3(1.0) : sky_path)) * mix(1.0, WET_DARKENING, porous);
			}

			const float WET_REACH = 0.3;

			float get_height_above_water(vec3 world_pos) {
				float above = water_data.ocean_enabled != 0 ? world_pos.y + planet_drop(world_pos.xz) - water_data.ocean_level : 1e30;

				for (int i = 0; i < optical_ranges.y; i++) {
					vec3 local = (water_volume_to_local(i) * vec4(world_pos, 1.0)).xyz;
					vec4 shape = water_volume_shape(i);

					if (abs(local.x) < shape.x && abs(local.z) < shape.z && world_pos.y > shape.w - 1.0) above = min(above, world_pos.y - shape.w);
				}

				return above;
			}

			const float SWASH_LEVEL_BIAS = ]] .. SWASH_LEVEL_BIAS .. [[;

			float get_swash_wetness(vec3 world_pos) {
				float level = 0.0;

				for (int i = 1; i >= 0; i--) {
					int tex = water_data.swash_wet_tex[i];
					if (tex < 0) continue;
					vec4 origin = water_data.wave_origin[i];
					vec2 uv = (world_pos.xz - origin.xy) * (0.5 / origin.z) + 0.5;
					vec2 edge = abs(uv - 0.5) * 2.0;
					float coverage = 1.0 - smoothstep(0.75, 0.97, max(edge.x, edge.y));
					if (coverage <= 0.0) continue;
					level = mix(level, textureLod(TEXTURE(tex), uv, 0.0).g, coverage);
				}

				if (level <= 0.0) return 0.0;

				return 1.0 - smoothstep(-0.02, 0.03, world_pos.y + planet_drop(world_pos.xz) - water_data.ocean_level - (level - SWASH_LEVEL_BIAS));
			}

			float get_wetness(vec3 world_pos, float above) {
				float reach = (WET_REACH + water_data.ocean_wave_info.x * 0.3) * mix(0.75, 1.25, value_noise2(world_pos.xz * 0.5) * 0.6 + value_noise2(world_pos.xz * 1.1 + 5.3) * 0.4);
				return 1.0 - smoothstep(reach * 0.35, reach, above);
			}

			vec3 apply_wetness(vec2 uv, vec3 color, vec3 world_pos, vec3 view_dir, float wetness, float film) {
				if (wetness <= 0.0) return color;
				vec3 normal = gbuffer_normal(uv);
				color *= mix(1.0, WET_DARKENING, wetness * (1.0 - gbuffer_metallic(uv)));
				float perceptual = mix(0.45, 0.25, film);
				float alpha = perceptual * perceptual;
				float no_v = max(dot(normal, view_dir), 1e-3);
				vec3 sun = normalize(water_data.sun_direction);
				float no_l = max(dot(normal, sun), 0.0);
				vec3 half_dir = normalize(view_dir + sun);
				float sun_specular = no_l > 0.0 ? D_GGXAlpha(alpha, max(dot(normal, half_dir), 0.0)) * V_SmithGGXCorrelated(alpha, no_v, no_l) * fresnel_dielectric(max(dot(view_dir, half_dir), 0.0), 1.0 / 1.33) * no_l * get_water_sun_visibility(world_pos + normal * 0.05, sun) : 0.0;
				vec3 sky = sample_environment_specular(water_data.env_tex, reflect(-view_dir, normal), normal, perceptual) * fresnel_dielectric(no_v, 1.0 / 1.33);
				return color + (sky + get_sun_illuminance() * sun_specular) * wetness * mix(0.12, 1.0, film);
			}

			]] .. medium_surface.GetCausticGLSL(
				"water_data",
				{
					name = "water_caustic",
					params = "Water w",
					gradient = [=[
if (w.volume >= 0) {
			get_volume_ripples(w.volume, xz, filter_size, grad, hess);
		} else {
			float e = filter_size;
			float variance;
			vec2 gx = get_wave_data(xz + vec2(e, 0.0), filter_size, variance).gb - get_wave_data(xz - vec2(e, 0.0), filter_size, variance).gb;
			vec2 gz = get_wave_data(xz + vec2(0.0, e), filter_size, variance).gb - get_wave_data(xz - vec2(0.0, e), filter_size, variance).gb;
			hess = vec3(gx.x, gz.y, 0.5 * (gx.y + gz.x)) / (2.0 * e);
			if (detail) add_detail_ripples(xz, filter_size, 1.0, grad, hess);
		}]=],
				}
			) .. [[

			vec3 get_caustic(Water w, vec3 world_pos, float footprint, int newton_steps, float fade, bool detail) {
				if (w.caustics <= 0.0 || !water_feature(detail ? WATER_CAUSTICS : WATER_SHAFT_CAUSTICS) || (detail && w.volume >= 0 && water_data.photon_caustics != 0 && caustic_covered(int(water_data.caustic_sun.w), vec3(0.0), world_pos))) return vec3(1.0);
				float sun_transmission;
				vec3 sun_dir = get_underwater_sun_dir(w, sun_transmission);
				float depth = max(w.surface_y - world_pos.y, 0.0);
				if (depth <= 0.0) return vec3(1.0);
				return water_caustic(w, world_pos, footprint, newton_steps, fade, detail, depth, sun_dir, w.ior, w.abbe, w.caustics);
			}


			vec3 get_last_frame_color(vec3 world_pos, vec2 uv) {
				if (water_data.last_frame_tex == -1) return get_scene_color(uv);

				vec4 prev_clip = water_data.prev_projection * (water_data.prev_view * vec4(world_pos, 1.0));

				if (prev_clip.w <= 1e-5) return get_scene_color(uv);

				vec2 prev_uv = prev_clip.xy / prev_clip.w * 0.5 + 0.5;

				if (!screen_refraction_on_screen(prev_uv)) return get_scene_color(uv);

				return texture(TEXTURE(water_data.last_frame_tex), prev_uv).rgb / get_previous_pre_exposure();
			}

			float scene_depth_at(vec2 uv) {
				return textureLod(TEXTURE(water_data.depth_tex), uv, 0.0).r;
			}

			bool trace_water_reflection(vec3 origin, vec3 dir, float jitter, out vec2 hit_uv, out float hit_t, out float weight) {
				float previous = 0.0;
				hit_uv = vec2(0.0);
				hit_t = 0.0;
				weight = 0.0;

				for (int i = 1; i <= 24; i++) {
					float f = (float(i) - jitter) / 24.0;
					float t = WATER_SCREENSPACE_DISTANCE * f * f;
					vec3 p = screen_refraction_project(origin + dir * t);

					if (!screen_refraction_on_screen(p.xy)) return false;

					float depth = scene_depth_at(p.xy);

					if (depth > 0.0 && p.z <= depth) {
						float near = previous;
						float far = t;

						for (int j = 0; j < 6; j++) {
							float middle = (near + far) * 0.5;
							vec3 pm = screen_refraction_project(origin + dir * middle);

							if (pm.z <= scene_depth_at(pm.xy)) {
								far = middle;
							} else {
								near = middle;
							}
						}

						vec3 hit = screen_refraction_project(origin + dir * far);
						vec3 ray_pos = origin + dir * far;
						vec3 scene_pos = get_world_pos(hit.xy, scene_depth_at(hit.xy));

						if (length(scene_pos - ray_pos) > max(0.4, far * 0.04)) return false;

						vec2 edge = min(hit.xy, 1.0 - hit.xy);
						hit_uv = hit.xy;
						hit_t = far;
						weight = smoothstep(0.0, 0.06, min(edge.x, edge.y));
						return true;
					}

					previous = t;
				}

				return false;
			}

			const int WATER_SCREEN_LOBE_TAPS = 8;

			vec3 refl_env;
			vec3 refl_origin;
			vec3 refl_dir;
			vec3 refl_normal;
			vec3 refl_view;
			float refl_perceptual;
			vec3 refl_screen_color;
			float refl_screen_weight;
			bool refl_rough;
			float refl_limit;
			int refl_rays;
			vec3 refl_sum;

			int prepare_reflection(vec3 surface_pos, vec3 view_dir, vec3 reflection_dir, vec3 normal, float alpha, float jitter) {
				refl_perceptual = sqrt(alpha);
				refl_env = sample_environment_specular(water_data.env_tex, reflection_dir, normal, refl_perceptual);
				refl_origin = surface_pos + normal * 0.02;
				refl_dir = reflection_dir;
				refl_normal = normal;
				refl_view = view_dir;
				refl_screen_color = vec3(0.0);
				refl_screen_weight = 0.0;
				refl_rough = false;
				refl_rays = 0;
				refl_sum = vec3(0.0);
				water_rt_share = 0.0;

				if (!water_feature(WATER_REFLECTION_TRACE) || refl_perceptual > water_data.reflection_roughness_cutoff) return 0;

				bool rays_ready = false;
				bool screen_first = true;

				#ifdef SCENE_HITS
				rays_ready = scene_hits_ready();
				screen_first = !rays_ready || reflection_screen_first(refl_perceptual);
				#endif

				vec2 screen_uv;
				float screen_t;

				if (screen_first && refl_dir.y > -0.2 && trace_water_reflection(refl_origin, refl_dir, jitter, screen_uv, screen_t, refl_screen_weight)) {
					vec3 hit_pos = get_world_pos(screen_uv, scene_depth_at(screen_uv));
					refl_screen_color = get_last_frame_color(hit_pos, screen_uv);

					if (refl_perceptual > REFLECTION_MIRROR_THRESHOLD) {
						vec3 tangent = normalize(cross(refl_dir, abs(refl_dir.y) < 0.99 ? vec3(0.0, 1.0, 0.0) : vec3(1.0, 0.0, 0.0)));
						vec3 bitangent = cross(refl_dir, tangent);
						float spin = get_blue_noise() * 6.2831853;
						float radius = screen_t * refl_perceptual * refl_perceptual;
						vec3 sum = refl_screen_color;
						float valid = 1.0;
						float tolerance = max(0.4, screen_t * 0.04);

						for (int tap = 0; tap < WATER_SCREEN_LOBE_TAPS; tap++) {
							float angle = spin + float(tap) * 2.39996323;
							float r = radius * sqrt((float(tap) + 0.5) / float(WATER_SCREEN_LOBE_TAPS));
							vec3 tap_pos = hit_pos + (tangent * cos(angle) + bitangent * sin(angle)) * r;
							vec2 tap_uv = screen_refraction_project(tap_pos).xy;

							if (!screen_refraction_on_screen(tap_uv)) continue;

							float tap_depth = scene_depth_at(tap_uv);

							if (tap_depth <= 0.0 || length(get_world_pos(tap_uv, tap_depth) - tap_pos) > tolerance) continue;

							sum += get_last_frame_color(tap_pos, tap_uv);
							valid += 1.0;
						}

						refl_screen_color = sum / valid;
						refl_screen_weight *= valid / float(WATER_SCREEN_LOBE_TAPS + 1);
					}
				}

				#ifdef SCENE_HITS
				if (rays_ready && refl_screen_weight < 0.999) {
					refl_rough = refl_perceptual > REFLECTION_MIRROR_THRESHOLD;
					refl_rays = reflection_ray_count(refl_perceptual, water_data.rough_rays);
					refl_limit = REFLECTION_MAX_HIT_LUMINANCE / get_exposure();
				}
				#endif

				return refl_rays;
			}

			vec3 resolve_reflection() {
				if (refl_rays > 0) {
					water_rt_share = refl_rough ? 1.0 - refl_screen_weight : 0.0;
					return mix(refl_sum / float(refl_rays), refl_screen_color, refl_screen_weight);
				}

				return mix(refl_env, refl_screen_color, refl_screen_weight);
			}

			vec3 get_refracted_scene(Water w, vec3 surface_pos, vec3 ray_dir, vec3 normal, float scene_distance, out float path_len, out vec3 floor_pos, out vec2 floor_uv, out bool has_floor) {
				path_len = WATER_OPEN_DEPTH;
				has_floor = false;
				floor_uv = in_uv;
				floor_pos = surface_pos;
				vec3 channel_ior = screen_refraction_dispersed_ior(w.ior, w.abbe);
				vec3 flat_dir = normalize(refract(ray_dir, vec3(0.0, 1.0, 0.0), 1.0 / channel_ior.g));
				vec3 bent_dir = refract(ray_dir, normal, 1.0 / channel_ior.g);
				if (dot(bent_dir, bent_dir) <= 0.0) bent_dir = flat_dir;
				float volume_exit = w.volume >= 0 ? mix(WATER_OPEN_DEPTH, get_volume_exit(w.volume, surface_pos + flat_dir * 0.001, flat_dir), w.closed) : WATER_OPEN_DEPTH;

				if (scene_distance >= 1e29) {
					path_len = volume_exit;
					return w.volume >= 0 ? get_scene_color(in_uv) * w.closed : vec3(0.0);
				}

				vec3 straight = surface_pos + ray_dir * scene_distance;
				vec3 bent = screen_refraction_project(straight + (normalize(bent_dir) - flat_dir) * scene_distance);

				if (bent.z > -1.0) {
					vec2 uv = clamp(bent.xy, vec2(0.001), vec2(0.999));

					if (scene_depth_at(uv) <= screen_refraction_project(surface_pos).z) floor_uv = uv;
				}

				float depth = scene_depth_at(floor_uv);

				if (depth <= 0.0) {
					path_len = volume_exit;
					return w.volume >= 0 ? get_scene_color(floor_uv) * w.closed : vec3(0.0);
				}

				vec3 behind = get_scene_color(floor_uv);

				if (w.abbe > 0.0) {
					float surface_depth = screen_refraction_project(surface_pos).z;

					for (int channel = 0; channel < 3; channel += 2) {
						vec3 channel_flat = normalize(refract(ray_dir, vec3(0.0, 1.0, 0.0), 1.0 / channel_ior[channel]));
						vec3 channel_bent = refract(ray_dir, normal, 1.0 / channel_ior[channel]);
						if (dot(channel_bent, channel_bent) <= 0.0) channel_bent = channel_flat;
						vec3 projected = screen_refraction_project(straight + (normalize(channel_bent) - channel_flat) * scene_distance);
						vec2 channel_uv = floor_uv;

						if (projected.z > -1.0) {
							vec2 uv = clamp(projected.xy, vec2(0.001), vec2(0.999));
							if (scene_depth_at(uv) <= surface_depth) channel_uv = uv;
						}

						behind[channel] = get_scene_color(channel_uv)[channel];
					}
				}

				floor_pos = get_world_pos(floor_uv, depth);
				has_floor = w.volume < 0 || w.closed < 0.5 || is_inside_volume(w.volume, floor_pos);
				path_len = has_floor ? length(floor_pos - surface_pos) : volume_exit;
				return behind;
			}

			vec3 above_view_dir;
			float above_scene_distance;
			float above_no_v;
			float above_fresnel;
			float above_sky_visibility;
			vec3 above_behind;
			float above_path_len;
			vec3 above_floor_pos;
			bool above_has_floor;
			vec3 above_refracted_dir;
			float above_footprint;

			int prepare_above(Water w, vec3 surface_pos, vec3 normal, float alpha, vec3 ray_dir, float t, float scene_distance, float jitter) {
				above_view_dir = -ray_dir;
				above_scene_distance = scene_distance;
				above_no_v = max(dot(normal, above_view_dir), 1e-4);
				above_fresnel = fresnel_dielectric(above_no_v, 1.0 / w.ior);
				vec3 reflection_dir = reflect(ray_dir, normal);
				above_sky_visibility = smoothstep(-0.15, 0.08, reflection_dir.y);
				if (reflection_dir.y < 0.0) reflection_dir = normalize(vec3(reflection_dir.x, -reflection_dir.y * 0.3, reflection_dir.z));
				if (w.volume < 0) {
					float up = max(reflection_dir.y, 0.004) + alpha * (1.0 - max(reflection_dir.y, 0.0));
					reflection_dir = normalize(vec3(reflection_dir.x, up, reflection_dir.z));
				}
				int rays = prepare_reflection(surface_pos, above_view_dir, reflection_dir, normal, alpha, jitter);
				vec2 floor_uv = in_uv;
				above_behind = vec3(0.0);
				above_path_len = WATER_OPEN_DEPTH;
				above_floor_pos = surface_pos;
				above_has_floor = false;

				if (water_feature(WATER_REFRACTION)) above_behind = get_refracted_scene(w, surface_pos, ray_dir, normal, scene_distance, above_path_len, above_floor_pos, floor_uv, above_has_floor);
				above_refracted_dir = above_has_floor && above_path_len > 1e-3 ? normalize(above_floor_pos - surface_pos) : normalize(refract(ray_dir, vec3(0.0, 1.0, 0.0), 1.0 / w.ior));
				above_refracted_dir.y = min(above_refracted_dir.y, -0.02);
				above_refracted_dir = normalize(above_refracted_dir);
				above_footprint = get_pixel_footprint(t, ray_dir.y);

				if (above_has_floor) above_behind = relight_submerged(w, floor_uv, above_behind, above_floor_pos, get_caustic(w, above_floor_pos, above_footprint, w.volume >= 0 ? 3 : 2, 1.0, true));

				return rays;
			}

			float above_unfiltered = 0.0;

			vec3 finish_above(Water w, vec3 surface_pos, vec3 normal, float alpha, float fold, vec3 transmittance, vec3 inscatter) {
				if (water_data.field_debug != 0 && w.volume < 0) {
					vec2 field = water_field_waves(surface_pos.xz);
					float hue = field.x / 6.28318530718 + 0.5;
					vec3 tint = clamp(abs(fract(hue + vec3(0.0, 2.0 / 3.0, 1.0 / 3.0)) * 6.0 - 3.0) - 1.0, 0.0, 1.0);
					tint = mix(vec3(1.0), tint, clamp(abs(field.x) * 2.0, 0.0, 1.0)) * (1.0 - 0.8 * field.y);
					float cell = max(4.0, above_footprint * 40.0);
					vec2 center = (floor(surface_pos.xz / cell) + 0.5) * cell;
					vec2 center_field = water_field_waves(center);
					float c = cos(center_field.x);
					float sn = sin(center_field.x);
					vec2 dir = vec2(c * water_data.field_wave_dir.x - sn * water_data.field_wave_dir.y, sn * water_data.field_wave_dir.x + c * water_data.field_wave_dir.y);
					vec2 local_p = (surface_pos.xz - center) / cell;
					vec2 along = vec2(dot(local_p, dir), dot(local_p, vec2(-dir.y, dir.x)));
					float shaft = step(abs(along.y), 0.04) * step(abs(along.x), 0.35);
					float head = step(0.15, along.x) * step(along.x, 0.4) * step(abs(along.y), (0.4 - along.x) * 0.8);
					tint = mix(tint, vec3(0.0), max(shaft, head));
					float surf_height;
					vec2 surf_slope;
					float whitewater;
					float surf_presence;
					float swash_wet;
					surf_wave(surface_pos.xz, water_field_depth(surface_pos.xz), water_data.time, field.y, surf_height, surf_slope, whitewater, surf_presence, swash_wet);
					tint = mix(tint, vec3(0.1, 0.4, 1.0), surf_presence * 0.5);
					tint = mix(tint, vec3(1.0, 0.1, 0.0), clamp(whitewater, 0.0, 1.0));
					if (water_field_depth(surface_pos.xz) < 0.0) tint = vec3(0.0, 1.0, 1.0);
					return tint * get_sun_illuminance() * 0.08;
				}

				vec3 reflection = resolve_reflection() * mix(0.3, 1.0, above_sky_visibility);
				vec3 transmitted = above_behind * transmittance + inscatter;

				vec3 sun = normalize(water_data.sun_direction);
				float shadow = get_water_sun_visibility(surface_pos, sun);
				vec3 sun_light = get_sun_illuminance() * shadow;
				float no_l = max(dot(normal, sun), 0.0);
				vec3 half_dir = normalize(above_view_dir + sun);
				float no_h = max(dot(normal, half_dir), 0.0);
				float glint_alpha = sqrt(alpha * alpha + SUN_ANGULAR_RADIUS * SUN_ANGULAR_RADIUS);
				float specular = D_GGXAlpha(glint_alpha, no_h) * V_SmithGGXCorrelated(glint_alpha, above_no_v, no_l) * fresnel_dielectric(max(dot(above_view_dir, half_dir), 0.0), 1.0 / w.ior);
				vec3 color = mix(transmitted, reflection, above_fresnel) + sun_light * (specular * no_l);

				#ifdef SCENE_HITS
				if (scene_hits_ready() && water_feature(WATER_LIGHTS)) {
					int light_cell = light_grid_cell(surface_pos);
					int light_count = water_data.light_count;
					int shaded = 0;
					float lamp_alpha = max(alpha, 0.02);

					for (int word = 0; word < light_grid_words(light_count) && shaded < WATER_LIGHT_MAX_PER_SAMPLE; word++) {
						uint light_bits = light_grid_word(light_cell, word, light_count);

						while (light_bits != 0u && shaded < WATER_LIGHT_MAX_PER_SAMPLE) {
							int li = word * 32 + findLSB(light_bits);
							light_bits &= light_bits - 1u;
							lights_t light = water_data.lights[li];

							if (get_light_type(light) == 0) continue;

							vec3 lamp_dir;
							float attenuation;

							if (!get_light_vector_and_attenuation(light, surface_pos, lamp_dir, attenuation)) continue;

							float lamp_no_l = dot(normal, lamp_dir);

							if (lamp_no_l <= 0.0) continue;

							vec3 lamp_half = normalize(above_view_dir + lamp_dir);
							float lamp_specular = D_GGXAlpha(lamp_alpha, max(dot(normal, lamp_half), 0.0)) * V_SmithGGXCorrelated(lamp_alpha, above_no_v, lamp_no_l) * fresnel_dielectric(max(dot(above_view_dir, lamp_half), 0.0), 1.0 / w.ior);
							vec3 lamp_light = light.color.rgb * light.color.a * attenuation * (lamp_specular * lamp_no_l);
							float lamp_visibility = get_medium_light_visibility(li, light, surface_pos, lamp_dir);

							if (lamp_visibility <= 0.0) continue;

							shaded++;
							color += lamp_light * lamp_visibility;
						}
					}
				}
				#endif

				if (w.volume < 0) {
					float sun_transmission;
					vec3 sun_dir = get_underwater_sun_dir(w, sun_transmission);
					float crest = clamp((surface_pos.y - w.surface_y) / max(water_data.ocean_wave_info.x, 0.05), 0.0, 1.0);
					vec3 sigma = get_extinction(w);
					float thickness = 1.5;
					color += (1.0 - above_fresnel) * sun_light * sun_transmission * water_scatter(w, dot(-above_refracted_dir, sun_dir)) * thickness * exp(-sigma * thickness) * crest * crest * 4.0;
					vec2 view_side = normalize(above_view_dir.xz + 1e-5);
					vec2 sun_side = normalize(sun.xz + 1e-5);
					float back = pow(clamp(dot(view_side, -sun_side) * 0.6 + 0.4, 0.0, 1.0), 2.5);
					float lit_crest = clamp(crest * 0.9 + 0.1, 0.0, 1.0) * (clamp((1.0 - normal.y) * 4.0, 0.0, 1.0) + 0.25);
					vec3 isotropic = (w.molecular + w.particles) / (4.0 * PI);
					color += (1.0 - above_fresnel) * sun_light * sun_transmission * isotropic * thickness * exp(-sigma * thickness) * WATER_CREST_GLOW * back * lit_crest * smoothstep(0.0, 0.25, sun.y);
				}

				const float SHORE_CAST = 1.5;
				const float MAX_SHORE_SLOPE = 4.0;
				const float SHORE_FOAM_WIDTH = 3.0;
				float shore_distance = 1e3;
				float shore_depth = 1e3;
				float shore_fade = 1.0;
				float shore_blend = 1.0;
				vec3 shore_floor = surface_pos;

				float water_top = w.volume < 0 ? max(surface_pos.y, w.surface_y) : w.surface_y;

				if (above_scene_distance < 1e29 && w.foam > 0.0 && water_feature(WATER_SHORE_FOAM)) {
					shore_floor = surface_pos - above_view_dir * above_scene_distance;
					float vertical = water_top - shore_floor.y;

					if (vertical < SHORE_CAST) {
						vec2 texel = 14.0 / water_data.render_size;
						vec2 inside = 0.5 / water_data.render_size;
						float slope = 0.0;
						float height_sum = vertical;

						for (int i = 0; i < 8; i++) {
							float angle = float(i) * 0.7853982;
							vec2 uv = clamp(in_uv + vec2(cos(angle), sin(angle)) * texel, inside, 1.0 - inside);
							float depth = scene_depth_at(uv);
							vec3 neighbor = depth > 0.0 ? get_world_pos(uv, depth) : shore_floor;
							slope += min(abs(neighbor.y - shore_floor.y) / max(length(neighbor.xz - shore_floor.xz), 1e-3), MAX_SHORE_SLOPE) * 0.125;
							height_sum += max(water_top - neighbor.y, -0.05);
						}

						shore_depth = height_sum / 9.0;
						shore_distance = max(shore_depth, 0.0) / max(slope, 0.05);
						shore_blend = max(pow(smoothstep(0.0, 2.0, shore_distance), 1.5), smoothstep(0.05, 0.2, shore_depth));
					}

					shore_fade = 1.0 - smoothstep(SHORE_CAST * 0.5, SHORE_CAST, max(vertical, 0.0));
				}

				const float FOAM_SCALE = 3.0;
				float foam_footprint = above_footprint * FOAM_SCALE;
				vec2 foam_xz = surface_pos.xz - w.flow * water_data.time;
				vec2 foam_p = foam_xz * FOAM_SCALE;
				vec3 pattern = foam_pattern(foam_p, water_data.time, foam_footprint);
				float coverage = clamp(fold * mix(0.5, 1.5, sea_state.y) * w.foam, 0.0, 1.0);
				float threshold = 1.05 - coverage * 1.1;
				float cap_density = smoothstep(threshold - 0.25, threshold + 0.35, pattern.x) * smoothstep(0.0, 0.08, coverage);
				float shore_amount = clamp(w.foam * 2.5, 0.0, 1.0);
				vec2 drift = vec2(water_data.time * 0.05, -water_data.time * 0.03);
				float swash = sin(water_data.time * 0.6 + value_noise2(surface_pos.xz * 0.04) * 12.0);
				float wash_width = SHORE_FOAM_WIDTH * mix(0.5, 1.5, value_noise2(surface_pos.xz * 0.09 + 3.1)) * (1.0 + 0.2 * swash);
				float reach = shore_distance / wash_width;
				float patches = value_noise2(foam_xz * 0.55 + drift) * 0.6 + value_noise2(foam_xz * 1.6 - drift) * 0.4;
				float shore_density = smoothstep(reach + 0.05, reach + 0.45, patches * 1.3 - 0.15) * (1.0 - smoothstep(0.9, 1.4, reach)) * (1.0 - 0.7 * clamp(reach, 0.0, 1.0)) * mix(0.3, 0.6, value_noise2(foam_xz * 3.1 + drift * 2.0)) * shore_fade * shore_amount;
				float flow_density = 0.0;
				float speed = length(w.flow);

				if (speed > 0.05) {
					vec2 along = w.flow / speed;
					vec2 q = vec2(dot(foam_xz, along), dot(foam_xz, vec2(-along.y, along.x)));
					float streak = value_noise2(vec2(q.x * 0.15, q.y * 0.9)) * 0.6 + value_noise2(vec2(q.x * 0.4, q.y * 2.5) + 4.7) * 0.4;
					flow_density = smoothstep(0.5, 0.85, streak) * 0.45 * clamp(speed * 0.5, 0.0, 1.0) * shore_amount;
				}

				float density = max(max(cap_density, shore_density), flow_density) * max(smoothstep(0.0, 0.6, shore_distance), smoothstep(0.03, 0.12, shore_depth));

				if (shore_blend < 1.0) color = mix(apply_wetness(in_uv, get_scene_color(in_uv), shore_floor, above_view_dir, 1.0, 1.0), color, shore_blend);

				above_unfiltered = 1.0 - shore_blend;

				if (density > 0.0) {
					vec2 lace = foam_lace(foam_p, density, foam_footprint, water_data.time);
					float opacity = mix(lace.x * mix(0.35, 0.85, density), density * 0.75, smoothstep(0.15, 1.2, above_footprint));
					vec3 foam_light = sun_light * (clamp((sun.y + 0.4) / 1.4, 0.0, 1.0) / PI) + get_ambient_irradiance(surface_pos + vec3(0.0, 0.1, 0.0), RADIANCE_CACHE_NO_VISIBILITY_RAYS, true);
					color = mix(color, foam_light * 0.8 * exp(-get_extinction(w) * 0.4), smoothstep(0.0, 1.0, max(cap_density, shore_density)) * 0.25 * shore_blend);
					color = mix(color, foam_light * 0.75 * lace.y, opacity);
					above_unfiltered = max(above_unfiltered, smoothstep(0.0, 0.1, density));
				}

				return color;
			}

			vec3 get_submerged_light(Water w, vec3 world_pos) {
				float sun_transmission;
				vec3 sun_dir = get_underwater_sun_dir(w, sun_transmission);
				return sun_transmission * exp(-get_extinction(w) * (max(w.surface_y - world_pos.y, 0.0) / max(-sun_dir.y, 0.05)));
			}

			bool below_surface;
			vec3 below_surface_pos;
			vec3 below_normal_up;
			vec3 below_ray_dir;
			vec3 below_fresnel;
			vec3 below_channel_ior;
			bool below_refracts;
			int below_primary;
			vec3 below_primary_dir;
			vec3 below_primary_above;
			bool below_hit_scene;
			bool below_scene_traced;
			vec3 below_reflect_dir;
			vec3 below_origin;
			float below_len;
			vec3 below_behind;
			float below_weight;
			vec3 under_behind;
			float under_len;

			int prepare_below(Water w, vec3 surface_pos, vec3 normal_up, vec3 ray_dir, float jitter) {
				below_surface_pos = surface_pos;
				below_normal_up = normal_up;
				below_ray_dir = ray_dir;
				float cos_i = dot(-normal_up, -ray_dir);
				below_channel_ior = screen_refraction_dispersed_ior(w.ior, w.abbe);
				below_fresnel = screen_refraction_fresnel(cos_i, below_channel_ior);
				below_refracts = below_fresnel.r < 1.0;
				below_primary = below_fresnel.g < 1.0 ? 1 : 0;
				below_primary_dir = below_refracts ? normalize(refract(ray_dir, -normal_up, below_channel_ior[below_primary])) : normal_up;
				below_primary_above = sample_environment_specular(water_data.env_tex, below_primary_dir, normal_up, 0.05);
				below_hit_scene = false;
				below_reflect_dir = reflect(ray_dir, -normal_up);
				below_origin = surface_pos + below_reflect_dir * 0.02;
				below_len = w.volume >= 0 ? mix(WATER_OPEN_DEPTH, get_volume_exit(w.volume, below_origin, below_reflect_dir) + 0.25, w.closed) : WATER_OPEN_DEPTH;
				below_behind = vec3(0.0);
				vec2 hit_uv;
				float hit_t;

				if (trace_water_reflection(below_origin, below_reflect_dir, jitter, hit_uv, hit_t, below_weight) && hit_t < below_len) {
					vec3 scene_pos = get_world_pos(hit_uv, scene_depth_at(hit_uv));
					float footprint = get_pixel_footprint(length(scene_pos - water_data.camera_position.xyz), 1.0);
					below_behind = relight_submerged(w, hit_uv, get_scene_color(hit_uv), scene_pos, get_caustic(w, scene_pos, footprint, w.volume >= 0 ? 3 : 2, 1.0, true));
					below_len = hit_t;
				} else {
					below_weight = 0.0;
				}

				below_scene_traced = false;

				#ifdef SCENE_HITS
				below_scene_traced = scene_hits_ready();
				#endif

				return below_scene_traced ? 2 : 0;
			}

			vec3 finish_below(Water w, float jitter, vec3 transmittance, vec3 inscatter) {
				if (!below_scene_traced && below_refracts) {
					vec2 uv;
					float hit;

					if (screen_refraction_trace(below_surface_pos, below_surface_pos, below_primary_dir, 200.0, jitter, uv, hit) && hit < 200.0 && scene_depth_at(uv) > 0.0) {
						below_primary_above = get_scene_color(uv);
						below_hit_scene = true;
					}
				}

				vec3 above = vec3(0.0);

				if (below_refracts) {
					vec3 sun = normalize(water_data.sun_direction);
					vec3 sun_light = get_sun_illuminance() * get_water_sun_visibility(below_surface_pos, sun);

					if (w.abbe <= 0.0) {
						above = below_primary_above + sun_light * smoothstep(0.9995, 0.99995, dot(below_primary_dir, sun)) * 2000.0;
					} else {
						for (int c = 0; c < 3; c++) {
							if (below_fresnel[c] >= 1.0) continue;

							vec3 refracted_dir = c == below_primary ? below_primary_dir : normalize(refract(below_ray_dir, -below_normal_up, below_channel_ior[c]));
							float sky = below_hit_scene || c == below_primary ? below_primary_above[c] : sample_environment_specular(water_data.env_tex, refracted_dir, below_normal_up, 0.05)[c];
							above[c] = sky + sun_light[c] * smoothstep(0.9995, 0.99995, dot(refracted_dir, sun)) * 2000.0;
						}
					}
				}

				return mix(above, below_behind * transmittance + inscatter, below_fresnel);
			}

			int prepare_underwater(Water w, vec3 camera, vec3 ray_dir, float surface_t, vec3 surface_normal, float exit_t, float scene_t, float footprint_t, vec3 scene_color, vec3 scene_pos, float jitter, out float distance) {
				below_surface = surface_t > 0.0 && surface_t < scene_t;

				if (below_surface) {
					under_len = surface_t;
					distance = surface_t;
					return prepare_below(w, camera + ray_dir * surface_t, surface_normal, ray_dir, jitter);
				}

				if (scene_t < exit_t) {
					under_len = scene_t;
					float footprint = get_pixel_footprint(footprint_t, 1.0);
					vec3 caustic = get_caustic(w, scene_pos, footprint, w.volume >= 0 ? 3 : 2, 1.0, true);
					under_behind = relight_submerged(w, in_uv, scene_color, scene_pos, caustic);
					distance = scene_t;
					return 0;
				}

				under_len = exit_t;
				under_behind = w.volume >= 0 ? scene_color : vec3(0.0);
				distance = -1.0;
				return 0;
			}

			void get_ocean_surface(vec2 xz, float footprint, out vec3 normal, out float alpha, out float fold) {
				vec3 unused_hess = vec3(0.0);
				float resolved_variance;
				vec4 wd = get_wave_data(xz, footprint, resolved_variance);
				vec2 grad = wd.gb;
				sea_state = get_sea_detail(xz);
				float detail_lost = add_detail_ripples(xz, footprint, sea_state.x, grad, unused_hess);
				float detail_total = water_data.detail_info.w * float(MEDIUM_SURFACE_OCTAVES);

				float unresolved = max(water_data.ocean_wave_info.z - (water_feature(WATER_UNIFORM_ROUGHNESS) ? water_data.wave_origin[0].w : resolved_variance) - (detail_total - detail_lost), 0.0) * sea_state.x * sea_state.x;
				if (!water_feature(WATER_WAVES)) unresolved = 0.0;
				alpha = water_feature(WATER_WAVES) && water_feature(WATER_ROUGHNESS) ? sqrt(max(unresolved, 4e-4)) : 0.001;
				normal = normalize(vec3(-grad.x, 1.0, -grad.y));
				fold = wd.a;
			}

			void write_passthrough(vec3 scene_color) {
				set_scene_color(scene_color, -1.0);
				set_water_distance(vec4(-1.0));
			}

			void shade_water_pixel() {
				vec3 unused_hess = vec3(0.0);
				vec3 scene_color = get_scene_color(in_uv);

				if (water_data.scene_tex == -1 || (water_data.ocean_enabled == 0 && optical_ranges.y == 0)) {
					write_passthrough(scene_color);
					return;
				}

				float scene_depth = gbuffer_depth(in_uv);
				vec3 ray_dir = get_view_ray(in_uv);
				vec3 camera_origin = water_data.camera_position.xyz + ray_dir * WATER_NEAR_PLANE;

				float camera_datum_y = camera_origin.y + planet_drop(camera_origin.xz);
				bool near_surface = water_data.ocean_enabled != 0 && abs(camera_datum_y - water_data.ocean_level) < water_data.ocean_wave_info.x + 0.5;

				for (int i = 0; i < optical_ranges.y && !near_surface; i++) {
					vec3 local = (water_volume_to_local(i) * vec4(camera_origin, 1.0)).xyz;
					vec4 shape = water_volume_shape(i);
					near_surface = abs(local.y) < 0.5 && abs(local.x) < shape.x + 0.5 && abs(local.z) < shape.z + 0.5;
				}

				float near_height = 1e3;

				if (near_surface) {
					if (water_data.ocean_enabled != 0) {
						near_height = camera_origin.y - get_water_surface_height(camera_origin.xz);
					}

					for (int i = 0; i < optical_ranges.y; i++) {
						vec3 local = (water_volume_to_local(i) * vec4(camera_origin, 1.0)).xyz;
						vec4 shape = water_volume_shape(i);

						if (abs(local.x) < shape.x + 0.5 && abs(local.z) < shape.z + 0.5 && abs(local.y) < abs(near_height)) near_height = local.y;
					}
				}

				if (abs(near_height) < 0.03) {
					float wobble_time = water_data.time;
					vec2 wobble_p = camera_origin.xz;
					float wobble = (value_noise2(wobble_p * 110.0 + vec2(wobble_time * 0.7, -wobble_time * 0.4)) - 0.5) * 0.0035 + (value_noise2(wobble_p * 290.0 + vec2(-wobble_time * 1.1, wobble_time * 0.6)) - 0.5) * 0.0012;
					vec2 wobble_x = wobble_p + vec2(0.002, 0.0);
					vec2 wobble_z = wobble_p + vec2(0.0, 0.002);
					float wobble_dx = (value_noise2(wobble_x * 110.0 + vec2(wobble_time * 0.7, -wobble_time * 0.4)) - 0.5) * 0.0035 + (value_noise2(wobble_x * 290.0 + vec2(-wobble_time * 1.1, wobble_time * 0.6)) - 0.5) * 0.0012;
					float wobble_dz = (value_noise2(wobble_z * 110.0 + vec2(wobble_time * 0.7, -wobble_time * 0.4)) - 0.5) * 0.0035 + (value_noise2(wobble_z * 290.0 + vec2(-wobble_time * 1.1, wobble_time * 0.6)) - 0.5) * 0.0012;
					float shift = wobble + (get_blue_noise() - 0.5) * 0.002;
					camera_origin.y += shift;
					near_height += shift;
					float film = exp(-near_height * near_height / (0.006 * 0.006));
					waterline = exp(-near_height * near_height / (0.0025 * 0.0025));
					ray_dir = normalize(ray_dir + vec3(wobble_dx - wobble, 0.0, wobble_dz - wobble) / 0.002 * 0.12 * film);
				}
				vec3 scene_pos = camera_origin + ray_dir * 1e30;
				float scene_t = 1e30;
				float jitter = get_blue_noise();

				if (scene_depth > 0.0) {
					scene_pos = get_world_pos(in_uv, scene_depth);
					scene_t = dot(scene_pos - camera_origin, ray_dir);
				}

				int volume = -1;
				float volume_entry = 1e30;
				float volume_exit = 0.0;
				bool volume_top = false;

				for (int i = 0; i < optical_ranges.y; i++) {
					float t_entry;
					float t_exit;
					bool top;

					if (intersect_volume(i, camera_origin, ray_dir, t_entry, t_exit, top)) {
						t_entry = max(t_entry, 0.0);

						if (t_entry < volume_entry && t_entry < scene_t) {
							volume = i;
							volume_entry = t_entry;
							volume_exit = t_exit;
							volume_top = top;
						}
					}
				}

				bool camera_under_ocean = false;
				float ocean_t = -1.0;
				vec3 ocean_local_pos = vec3(0.0);

				if (water_data.ocean_enabled != 0) {
					float wave_bound = water_data.ocean_wave_info.x;
					float camera_surface_delta = camera_origin.y - get_water_surface_height(camera_origin.xz);
					camera_under_ocean = camera_surface_delta < 0.0;
					float trace_plane_y = water_data.ocean_level + (camera_under_ocean ? -wave_bound : wave_bound);

					if (!camera_under_ocean && camera_datum_y < trace_plane_y) trace_plane_y = water_data.ocean_level;

					float plane_t = planet_surface_t(camera_origin, ray_dir, trace_plane_y);
					float trace_anchor_t = plane_t > 0.0 ? plane_t : -1.0;

					if (trace_anchor_t <= 0.0 && abs(camera_surface_delta) <= wave_bound * 1.7) {
						trace_anchor_t = 0.0;
					}

					if (camera_under_ocean && trace_anchor_t < 0.0) trace_anchor_t = ray_dir.y > 0.0 ? 0.0 : -1.0;

					if (!camera_under_ocean) trace_anchor_t = max(trace_anchor_t, 0.0);

					if (trace_anchor_t >= 0.0) {
						ocean_t = height_map_tracing(ray_dir, trace_anchor_t, camera_origin, camera_under_ocean ? 1e30 : scene_t, ocean_local_pos);
					}
				}

				bool ocean_first = camera_under_ocean || (ocean_t > 0.0 && ocean_t < scene_t);
				float ocean_entry = camera_under_ocean ? 0.0 : ocean_t;

				bool volume_in_sea = false;

				if (volume >= 0 && water_data.ocean_enabled != 0) {
					volume_in_sea = abs(water_volume_shape(volume).w + planet_drop(camera_origin.xz) - water_data.ocean_level) < water_data.ocean_wave_info.x + 0.5;

					if (volume_in_sea && !volume_top && volume_entry > 0.0) volume = -1;
				}

				int shade_mode = 0;
				Water w;
				vec3 under_camera = camera_origin;
				float under_scene_t = scene_t;
				bool side_entry = false;
				float surface_t = -1.0;
				vec3 normal_up = vec3(0.0, 1.0, 0.0);
				float exit_t = 0.0;
				vec3 surface_pos = vec3(0.0);
				vec3 normal = vec3(0.0, 1.0, 0.0);
				float alpha = 0.0;
				float fold = 0.0;
				float entry_t = 0.0;

				if (volume >= 0 && (!ocean_first || volume_entry < ocean_entry || (volume_entry == 0.0 && !camera_under_ocean) || (volume_in_sea && volume_top && !camera_under_ocean))) {
					w = get_volume_water(volume);

					if (volume_entry <= 0.0) {
						surface_t = ray_dir.y > 1e-4 ? (w.surface_y - camera_origin.y) / ray_dir.y : -1.0;
						if (surface_t > volume_exit + 1e-3) surface_t = -1.0;

						if (surface_t > 0.0) {
							vec3 p = camera_origin + ray_dir * surface_t;
							vec2 grad;
							get_volume_ripples(volume, p.xz, get_pixel_footprint(surface_t, ray_dir.y), grad, unused_hess);
							normal_up = normalize(vec3(-grad.x, 1.0, -grad.y));
						}

						exit_t = volume_exit;
						shade_mode = 1;
					} else if (!volume_top) {
						under_camera = camera_origin + ray_dir * volume_entry;
						under_scene_t = scene_t - volume_entry;
						exit_t = volume_exit - volume_entry;
						side_entry = true;
						shade_mode = 1;
					} else {
						surface_pos = camera_origin + ray_dir * volume_entry;
						float footprint = get_pixel_footprint(volume_entry, ray_dir.y);
						vec2 grad;
						float lost_variance = get_volume_ripples(volume, surface_pos.xz, footprint, grad, unused_hess);
						normal = normalize(vec3(-grad.x, 1.0, -grad.y));
						alpha = sqrt(w.roughness * w.roughness + lost_variance);

						if (volume_in_sea) {
							vec3 local = (water_volume_to_local(volume) * vec4(surface_pos, 1.0)).xyz;
							vec4 shape = water_volume_shape(volume);
							float edge = min(shape.x - abs(local.x), shape.z - abs(local.z));
							float inside = smoothstep(0.0, min(VOLUME_EDGE_BLEND, 0.5 * min(shape.x, shape.z)), edge);

							if (inside < 1.0) {
								vec3 sea_normal;
								float sea_alpha;
								float sea_fold;
								get_ocean_surface(surface_pos.xz, footprint, sea_normal, sea_alpha, sea_fold);
								w = mix_water(get_ocean_water(surface_pos), w, inside);
								normal = normalize(mix(sea_normal, normal, inside));
								alpha = mix(sea_alpha, alpha, inside);
								fold = sea_fold * (1.0 - inside);
							}
						}

						entry_t = volume_entry;
						shade_mode = 2;
					}
				} else {
					if (!ocean_first) {
						if (scene_depth > 0.0 && water_feature(WATER_SHORE_FOAM)) {
							float above = get_height_above_water(scene_pos);
							if (above < 3.0) {
								float swash_wet = water_data.ocean_enabled != 0 ? get_swash_wetness(scene_pos) : 0.0;
								scene_color = apply_wetness(in_uv, scene_color, scene_pos, -ray_dir, max(get_wetness(scene_pos, above), swash_wet), 1.0 - smoothstep(0.0, 0.1, above));
							}
						}

						write_passthrough(scene_color);
						return;
					}

					w = get_ocean_water(camera_under_ocean ? camera_origin : camera_origin + ocean_local_pos);

					if (camera_under_ocean) {
						surface_t = ocean_t > 0.0 ? ocean_t : -1.0;

						if (surface_t > 0.0) {
							vec3 p = camera_origin + ocean_local_pos;
							float footprint = get_pixel_footprint(surface_t, ray_dir.y);
							float variance;
							vec4 wd = get_wave_data(p.xz, footprint, variance);
							vec2 grad = wd.gb;
							add_detail_ripples(p.xz, footprint, 1.0, grad, unused_hess);
							normal_up = planet_to_world(normalize(vec3(-grad.x, 1.0, -grad.y)), planet_up(p));
						}

						exit_t = WATER_OPEN_DEPTH;
						shade_mode = 1;
					} else {
						surface_pos = camera_origin + ocean_local_pos;
						vec3 surface_up = planet_up(surface_pos);
						get_ocean_surface(surface_pos.xz, get_pixel_footprint(ocean_t, dot(ray_dir, surface_up)), normal, alpha, fold);
						normal = planet_to_world(normal, surface_up);
						entry_t = ocean_t;
						shade_mode = 2;
					}
				}

				float distance = 0.0;
				int trace_count = shade_mode == 1 ?
					prepare_underwater(w, under_camera, ray_dir, surface_t, normal_up, exit_t, under_scene_t, scene_t, scene_color, scene_pos, jitter, distance) :
					prepare_above(w, surface_pos, normal, alpha, ray_dir, entry_t, scene_t < 1e29 ? max(scene_t - entry_t, 0.0) : 1e30, jitter);

				// every call site inlines the whole hit shading, gi lookup and inscatter, so all rays share one trace call and all segments one inscatter call
				#ifdef SCENE_HITS
				for (int ray = 0; ray < trace_count; ray++) {
					vec3 origin = refl_origin;
					vec3 dir = refl_dir;
					vec3 n = refl_normal;
					float roughness = refl_perceptual;
					float max_t = SCENE_HIT_MAX_DISTANCE;

					if (shade_mode == 2) {
						if (refl_rough) {
							dir = reflection_above(refl_normal, reflection_direction(refl_normal, refl_view, refl_perceptual, get_blue_noise2(ray), roughness), 0.001);
							if (dir.y < 0.0) dir = normalize(vec3(dir.x, -dir.y * 0.3, dir.z));
						}
					} else if (ray == 0) {
						if (!below_refracts) continue;

						origin = below_surface_pos + below_normal_up * 0.02;
						dir = below_primary_dir;
						n = below_normal_up;
						roughness = 0.05;
					} else {
						if (below_weight >= 0.999) continue;

						origin = below_origin;
						dir = below_reflect_dir;
						n = -below_reflect_dir;
						roughness = 0.0;
						max_t = below_len;
					}

					float traced_t;
					vec3 traced = trace_scene_radiance(origin, dir, n, roughness, max_t, traced_t);

					if (shade_mode == 2) {
						if (refl_rough && traced_t < SCENE_HIT_MAX_DISTANCE) traced = reflection_limit_hit(traced, refl_limit);

						refl_sum += traced;
					} else if (ray == 0) {
						below_primary_above = traced;
						below_hit_scene = traced_t < SCENE_HIT_MAX_DISTANCE;
					} else if (traced_t < below_len) {
						below_behind = mix(traced * get_submerged_light(w, below_origin + below_reflect_dir * traced_t), below_behind, below_weight);
						if (below_weight <= 0.0) below_len = traced_t;
					}
				}
				#endif

				int segments = shade_mode == 1 ? (below_surface ? 2 : 1) : (water_feature(WATER_INSCATTER) ? 1 : 0);
				vec3 view_transmittance = vec3(1.0);
				vec3 view_inscatter = vec3(0.0);
				vec3 below_transmittance = vec3(1.0);
				vec3 below_inscatter = vec3(0.0);

				for (int segment = 0; segment < segments; segment++) {
					bool reflected = segment == 1;
					vec3 transmittance;
					vec3 inscatter = get_water_inscatter(
						w,
						shade_mode == 2 ? surface_pos : reflected ? below_origin : under_camera,
						shade_mode == 2 ? above_refracted_dir : reflected ? below_reflect_dir : ray_dir,
						shade_mode == 2 ? above_path_len : reflected ? below_len : under_len,
						jitter,
						transmittance
					);

					if (reflected) {
						below_transmittance = transmittance;
						below_inscatter = inscatter;
					} else {
						view_transmittance = transmittance;
						view_inscatter = inscatter;
					}
				}

				if (shade_mode == 1) {
					if (below_surface) under_behind = finish_below(w, jitter, below_transmittance, below_inscatter);

					set_scene_color(under_behind * view_transmittance + view_inscatter, 1.0);
					set_water_distance(side_entry ? vec4(volume_entry, 0.0, volume_entry, 0.0) : vec4(distance, 0.0, 0.0, 0.0));
					return;
				}

				set_scene_color(finish_above(w, surface_pos, normal, alpha, fold, view_transmittance, view_inscatter), 1.0);
				set_water_distance(vec4(entry_t, sqrt(alpha) * water_rt_share * (1.0 - above_unfiltered), entry_t, 0.0));
			}

			void main() {
				water_pixel = ivec2(gl_GlobalInvocationID.xy);
				ivec2 size = imageSize(out_color);

				if (any(greaterThanEqual(water_pixel, size))) return;

				in_uv = (vec2(water_pixel) + 0.5) / vec2(size);
				shade_water_pixel();
			}
		]],
	}
)
list.insert(
	passes,
	{
		name = "water_resolve",
		ColorFormat = {{"r16g16b16a16_sfloat", {"color", "rgba"}}},
		framebuffer_count = 2,
		dont_create_framebuffers = true,
		fragment = {
			uniform_buffers = {
				{
					name = "water_resolve_data",
					binding_index = 3,
					block = {
						render3d.camera_block,
						{"current_water_tex", "int"},
						{"history_water_tex", "int"},
						{"history_blend", "float"},
						{"current_water_distance_tex", "int"},
						{"filter_radius", "float"},
						{"prev_view", "mat4"},
						{"prev_projection", "mat4"},
						post_source.pre_exposure_block,
					},
					write = function(self, block)
						render3d.WriteCameraBlock(self, block)
						post_source.WritePreExposureBlock(self, block)

						if not render3d.pipelines.water.framebuffers then
							block.current_water_tex = -1
							block.current_water_distance_tex = -1
						else
							local current_idx = system.GetFrameNumber() % 2 + 1
							local framebuffer = render3d.pipelines.water:GetFramebuffer(current_idx)
							block.current_water_tex = self:GetTextureIndex(framebuffer:GetAttachment(1))
							block.current_water_distance_tex = self:GetTextureIndex(framebuffer:GetAttachment(2))
						end

						block.history_blend = render3d.IsTemporalAntiAliasingEnabled() and 0.7 or 0.9
						block.filter_radius = scene_hits.filter_radius:Get()

						if not render3d.pipelines.water_resolve.framebuffers then
							block.history_water_tex = -1
						else
							local prev_idx = (system.GetFrameNumber() + 1) % 2 + 1
							block.history_water_tex = self:GetTextureIndex(render3d.pipelines.water_resolve:GetFramebuffer(prev_idx):GetAttachment(1))
						end

						local prev_view = render3d.GetPreviousViewMatrix()
						local prev_projection = render3d.GetPreviousProjectionMatrix()

						if prev_view then
							prev_view:CopyToFloatPointer(block.prev_view)
						else
							render3d.GetCamera():BuildViewMatrix():CopyToFloatPointer(block.prev_view)
						end

						if prev_projection then
							prev_projection:CopyToFloatPointer(block.prev_projection)
						else
							render3d.GetCamera():BuildProjectionMatrix():CopyToFloatPointer(block.prev_projection)
						end

						return block
					end,
				},
			},
			shader = [[
			vec4 get_current_water(vec2 uv) {
				if (water_resolve_data.current_water_tex == -1) return vec4(0.0, 0.0, 0.0, -1.0);
				return texture(TEXTURE(water_resolve_data.current_water_tex), uv);
			}

			float get_current_water_distance(vec2 uv) {
				if (water_resolve_data.current_water_distance_tex == -1) return -1.0;
				return texture(TEXTURE(water_resolve_data.current_water_distance_tex), uv).r;
			}

			]] .. scene_hits.CONSTANTS_GLSL .. [[

			float get_current_water_roughness(vec2 uv) {
				if (water_resolve_data.current_water_distance_tex == -1) return 0.0;
				return texture(TEXTURE(water_resolve_data.current_water_distance_tex), uv).g;
			}

			const int OCEAN_FILTER_TAPS = 16;

			vec4 get_filtered_water(vec4 center, float center_distance, float roughness) {
				float radius = water_resolve_data.filter_radius * 2.0 * smoothstep(0.02, 0.15, roughness);

				if (radius < 0.5) return center;

				vec2 texel_size = 1.0 / vec2(textureSize(TEXTURE(water_resolve_data.current_water_tex), 0));
				float spin = fract(sin(dot(gl_FragCoord.xy, vec2(12.9898, 78.233))) * 43758.5453) * 6.28318530718;
				float limit = REFLECTION_MAX_HIT_LUMINANCE / ]] .. post_source.PRE_EXPOSURE_HEADROOM .. [[.0;
				float center_weight = 1.0 / (1.0 + dot(center.rgb, vec3(0.2126, 0.7152, 0.0722)) / (limit * 0.1));
				vec3 sum = center.rgb * center_weight;
				float total = center_weight;

				for (int i = 0; i < OCEAN_FILTER_TAPS; i++) {
					float angle = spin + float(i) * 2.39996323;
					vec2 tap_uv = in_uv + vec2(cos(angle), sin(angle)) * (radius * sqrt((float(i) + 0.5) / float(OCEAN_FILTER_TAPS))) * texel_size;
					vec4 tap = get_current_water(tap_uv);
					float tap_distance = get_current_water_distance(tap_uv);

					if (tap.a < 0.0 || tap_distance < 0.0) continue;

					float weight = exp(-abs(tap_distance - center_distance) / max(center_distance * 0.02, 0.05)) / (1.0 + dot(tap.rgb, vec3(0.2126, 0.7152, 0.0722)) / (limit * 0.1));
					sum += tap.rgb * weight;
					total += weight;
				}

				return vec4(sum / total, center.a);
			}

			]] .. post_source.GetPreExposureGLSL("water_resolve_data") .. [[

			vec4 get_history_water(vec2 uv) {
				if (water_resolve_data.history_water_tex == -1) return vec4(0.0, 0.0, 0.0, -1.0);
				vec4 history = texture(TEXTURE(water_resolve_data.history_water_tex), uv);
				return vec4(history.rgb * (get_pre_exposure() / get_previous_pre_exposure()), history.a);
			}


			]] .. screen_reconstruct.GetViewRayFromUVGLSL("water_resolve_data") .. [[

			void main() {
				vec4 current = get_current_water(in_uv);
				float current_distance = get_current_water_distance(in_uv);

				if (current.a >= 0.0 && current_distance >= 0.0) current = get_filtered_water(current, current_distance, get_current_water_roughness(in_uv));

				if (current.a < 0.0 || current_distance < 0.0 || water_resolve_data.history_water_tex == -1) {
					set_color(current);
					return;
				}

				vec3 world_pos = water_resolve_data.camera_position.xyz + get_view_ray(in_uv) * current_distance;
				vec4 prev_view_pos = water_resolve_data.prev_view * vec4(world_pos, 1.0);
				vec4 prev_clip = water_resolve_data.prev_projection * prev_view_pos;
				vec2 prev_uv = (prev_clip.xy / prev_clip.w) * 0.5 + 0.5;

				if (prev_uv.x < 0.0 || prev_uv.x > 1.0 || prev_uv.y < 0.0 || prev_uv.y > 1.0) {
					set_color(current);
					return;
				}

				vec4 history = get_history_water(prev_uv);

				if (history.a < 0.0) {
					set_color(current);
					return;
				}

				vec3 m1 = vec3(0.0);
				vec3 m2 = vec3(0.0);
				float sample_count = 0.0;
				vec2 texel_size = 1.0 / vec2(textureSize(TEXTURE(water_resolve_data.current_water_tex), 0));

				for (int y = -1; y <= 1; y++) {
					for (int x = -1; x <= 1; x++) {
						vec4 sample_color = get_current_water(in_uv + vec2(x, y) * texel_size);
						if (sample_color.a < 0.0) continue;
						m1 += sample_color.rgb;
						m2 += sample_color.rgb * sample_color.rgb;
						sample_count += 1.0;
					}
				}

				if (sample_count < 4.0) {
					set_color(current);
					return;
				}

				m1 /= sample_count;
				m2 /= sample_count;

				vec3 sigma = sqrt(max(vec3(0.0), m2 - m1 * m1));
				float gamma = 1.25;
				vec3 clamped_rgb = clamp(history.rgb, m1 - sigma * gamma, m1 + sigma * gamma);
				float clamp_diff = length(history.rgb - clamped_rgb) / max(max(m1.r, max(m1.g, m1.b)), 1e-4);
				float blend = water_resolve_data.history_blend * (1.0 - clamp(clamp_diff * 2.0, 0.0, 1.0));

				set_color(vec4(mix(current.rgb, clamped_rgb, blend), current.a));
			}
		]],
		},
		CullMode = "none",
		DepthTest = false,
		DepthWrite = false,
	}
)
return passes
