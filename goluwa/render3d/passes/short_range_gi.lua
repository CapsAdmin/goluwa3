local render = import("goluwa/render/render.lua")
local assets = import("goluwa/assets.lua")
local system = import("goluwa/system.lua")
local glsl_common = import("goluwa/render3d/glsl_common.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local gbuffer_layout = import("goluwa/render3d/gbuffer_layout.lua")
local compute_helpers = import("goluwa/render3d/compute_helpers.lua")
local screen_reconstruct = import("goluwa/render3d/screen_reconstruct.lua")
local ibl = import("goluwa/render3d/ibl.lua")
local atmosphere = import("goluwa/render3d/atmosphere.lua")
local directional_shadows = import("goluwa/render3d/directional_shadows.lua")
local post_source = import("goluwa/render3d/post_source.lua")
local scene_hits = import("goluwa/render3d/scene_hits.lua")
local scene_instances = import("goluwa/render3d/scene/instances.lua")
local gi = import("goluwa/render3d/gi.lua")
local short_range_gi = import("goluwa/render3d/short_range_gi.lua")

if not render.GetDevice().ray_query_supported then return {} end

local BINDING_DATA = 8
local BINDING_GI = 9
local SCENE_BINDINGS = {scene = 10, hit = 30, materials = 11, light_grid = 12}
local LOCAL_SIZE = {x = 8, y = 8, z = 1}

local function attachment(pipeline_name, framebuffer, index)
	return render3d.pipelines[pipeline_name]:GetFramebuffer(framebuffer):GetAttachment(index)
end

local function is_enabled()
	return gi.GetMode() ~= "none" and not gi.IsPerPixel()
end

local function uniform(trace)
	local layout = {
		render3d.camera_block,
		gbuffer_layout.block,
		post_source.pre_exposure_block,
		{"blue_noise_tex", "int"},
		{"frame", "int"},
		{"history_valid", "int"},
		{"prev_view", "mat4"},
		{"prev_projection", "mat4"},
		{"range", "float"},
		{"rays", "int"},
		{"accumulation", "float"},
		{"raw_tex", "int"},
		{"history_tex", "int"},
		{"history_geometry_tex", "int"},
	}

	if trace then
		layout[#layout + 1] = scene_hits.block
		layout[#layout + 1] = atmosphere.GetBlockLayout()
		layout[#layout + 1] = {"primary_sun_illuminance", "float"}
		layout[#layout + 1] = {"env_tex", "int"}
	end

	return {
		name = "srgi_data",
		binding_index = BINDING_DATA,
		block = layout,
		write = function(self, block)
			render3d.WriteCameraBlock(self, block)
			gbuffer_layout.WriteBlock(self, block)
			post_source.WritePreExposureBlock(self, block)
			local frame = system.GetFrameNumber()
			block.blue_noise_tex = self:GetTextureIndex(
				assert(
					assets.GetTexture("textures/render/blue_noise.lua"),
					"the blue noise texture is not registered"
				)
			)
			block.frame = frame % 65536
			block.history_valid = render3d.ShouldUseLastFrameHistory() and
				frame > short_range_gi.GetResetFrame()
				and
				1 or
				0
			local camera = render3d.GetCamera()
			local prev_view = render3d.GetPreviousViewMatrix() or camera:BuildViewMatrix()
			local prev_projection = render3d.GetPreviousProjectionMatrix() or camera:BuildProjectionMatrix()
			prev_view:CopyToFloatPointer(block.prev_view)
			prev_projection:CopyToFloatPointer(block.prev_projection)
			block.range = short_range_gi.range:Get()
			block.rays = short_range_gi.rays:Get()
			block.accumulation = short_range_gi.accumulation:Get()
			block.raw_tex = self:GetTextureIndex(attachment("short_range_gi", 1, 1))
			block.history_tex = self:GetTextureIndex(attachment("short_range_gi_accumulate", (frame + 1) % 2 + 1, 1))
			block.history_geometry_tex = self:GetTextureIndex(attachment("short_range_gi_accumulate", (frame + 1) % 2 + 1, 2))

			if trace then
				scene_hits.WriteBlock(self, block)
				local lights = render3d.GetLights()
				atmosphere.WriteBlock(
					self,
					block,
					camera:GetPosition(),
					directional_shadows.GetPrimarySunDirection(lights)
				)
				block.primary_sun_illuminance = directional_shadows.GetPrimarySunIlluminance(lights)
				block.env_tex = self:GetTextureIndex(render3d.GetEnvironmentTexture())
			end

			return block
		end,
	}
end

local SURFACE_GLSL = glsl_common.GetConstantsGLSL() .. glsl_common.GetHashGLSL() .. compute_helpers.GetScreenHelpersGLSL() .. gbuffer_layout.GetDecodeGLSL("srgi_data") .. screen_reconstruct.GetWorldPosFromUVGLSL("srgi_data") .. screen_reconstruct.GetGeometricNormalGLSL("srgi_data", {world_pos_function = "get_world_pos"}) .. [[
	bool srgi_surface(ivec2 pos, out vec3 P, out vec3 N, out float view_depth, out float depth) {
		ivec2 gsize = textureSize(TEXTURE(srgi_data.depth_tex), 0);
		depth = gbuffer_depth(pos);
		P = vec3(0.0);
		N = vec3(0.0);
		view_depth = 0.0;

		if (depth <= 0.0) return false;

		P = get_world_pos((vec2(pos) + 0.5) / vec2(gsize), depth);
		N = normalize(gbuffer_normal(pos));
		view_depth = -(srgi_data.view * vec4(P, 1.0)).z;
		return true;
	}
]]
-- hits the camera saw last frame read this pass's own result there: probe light inside a cavity is too bright, and a hit lit by it carries that into the cavity again
local SCREEN_GI_GLSL = [[
	#define SCENE_HIT_SCREEN_GI

	bool scene_hit_screen_gi(vec3 P, vec3 N, float t, out vec3 irradiance) {
		irradiance = vec3(0.0);

		if (srgi_data.history_valid == 0) return false;

		vec4 view_pos = srgi_data.prev_view * vec4(P, 1.0);
		float view_depth = -view_pos.z;

		if (view_depth <= 0.01) return false;

		vec4 clip = srgi_data.prev_projection * view_pos;
		vec2 uv = clip.xy / clip.w * 0.5 + 0.5;

		if (any(lessThan(uv, vec2(0.0))) || any(greaterThanEqual(uv, vec2(1.0)))) return false;

		ivec2 size = textureSize(TEXTURE(srgi_data.history_tex), 0);
		ivec2 texel = min(ivec2(uv * vec2(size)), size - 1);
		vec4 geometry = texelFetch(TEXTURE(srgi_data.history_geometry_tex), texel, 0);

		if (dot(geometry.xyz, N) < 0.8 || abs(geometry.w - view_depth) > 0.02 * view_depth + 0.02) return false;

		irradiance = texelFetch(TEXTURE(srgi_data.history_tex), texel, 0).rgb;
		return !any(isnan(irradiance));
	}
]]
local TRACE_GLSL = string.format("#define SCENE_HIT_MASK 0x%02X\n", scene_instances.MASK_SURFACES) .. "#define SCENE_HIT_SKY_RAYS 1\n" .. glsl_common.GetConstantsGLSL() .. render3d.GetEmissiveGLSL() .. glsl_common.GetBlueNoiseGLSL() .. SURFACE_GLSL .. SCREEN_GI_GLSL .. ibl.GetEnvironmentGLSLCode() .. post_source.GetPreExposureGLSL("srgi_data") .. atmosphere.GetGLSLDefines("srgi_data", "srgi_data.primary_sun_illuminance") .. atmosphere.GetAerialPerspectiveGLSLCode() .. scene_hits.GetGLSL("srgi_data")

local function pass_trace()
	return {
		name = "short_range_gi",
		ComputePass = true,
		is_enabled = is_enabled,
		ColorFormat = {
			{
				"r16g16b16a16_sfloat",
				{"short_range_gi_raw", "rgb", 1 / post_source.UNEXPOSED_SDR_WHITE},
			},
		},
		framebuffer_count = 1,
		LocalSize = LOCAL_SIZE,
		storage_images = {{binding_index = 0, attachment = 1, dst_stage = "compute"}},
		descriptor_sets = scene_hits.GetDescriptorSets(SCENE_BINDINGS, "compute"),
		uniform_buffers = {uniform(true), scene_hits.GetDDGIUniformBuffer(BINDING_GI)},
		on_pre_draw = function(self, cmd, frame, desc)
			scene_hits.Bind(self, cmd, desc, SCENE_BINDINGS)
		end,
		custom_declarations = [[
			layout(set = 0, binding = 0, rgba16f) uniform writeonly image2D out_raw;
		]] .. scene_hits.GetDeclarationGLSL(SCENE_BINDINGS),
		shader = TRACE_GLSL .. [[
			vec3 srgi_cosine_direction(vec3 N, vec2 xi) {
				vec3 up = abs(N.y) < 0.999 ? vec3(0.0, 1.0, 0.0) : vec3(1.0, 0.0, 0.0);
				vec3 T = normalize(cross(up, N));
				vec3 B = cross(N, T);
				float phi = 6.28318530718 * xi.x;
				float r = sqrt(xi.y);
				return normalize(T * (r * cos(phi)) + B * (r * sin(phi)) + N * sqrt(max(1.0 - xi.y, 0.0)));
			}

			// a pixel at a crease reconstructs a hair behind one of its two planes, lift it off every neighbouring pixel's plane it lies on
			vec3 srgi_ray_origin(ivec2 pos, vec3 P, vec3 N, float view_depth, float depth) {
				vec3 V = normalize(srgi_data.camera_position - P);
				float offset = 0.01 * srgi_data.view_scale + 0.001 * view_depth;
				vec3 pull = get_geometric_normal(pos, P, depth, V, N);
				ivec2 gsize = textureSize(TEXTURE(srgi_data.depth_tex), 0);

				for (int i = 0; i < 4; i++) {
					ivec2 q = clamp(pos + ivec2(i == 0 ? 1 : i == 1 ? -1 : 0, i == 2 ? 1 : i == 3 ? -1 : 0), ivec2(0), gsize - 1);
					float q_depth = gbuffer_depth(q);

					if (q_depth <= 0.0) continue;

					vec3 q_N = normalize(gbuffer_normal(q));

					if (dot(q_N, pull) < 0.99 && abs(dot(P - get_world_pos((vec2(q) + 0.5) / vec2(gsize), q_depth), q_N)) < offset) pull += q_N;
				}

				return P + normalize(pull) * offset;
			}

			vec3 srgi_far_field(vec3 end, vec3 dir) {
				float weight;
				vec3 far = ddgi_data.gi_mode == GI_MODE_DDGI && ddgi_data.ddgi_radiance_tex >= 0 ? ddgi_sample_radiance(end, dir, weight) : gi_sample_irradiance(end, dir, -dir, false, DDGI_NO_VISIBILITY_RAYS, weight).rgb;
				return gi_covers(end, weight) ? far : ddgi_sky(dir);
			}

			void main() {
				ivec2 pos = get_screen_pos();
				ivec2 size = imageSize(out_raw);

				if (!is_screen_pos_in_bounds(pos, size)) return;

				vec3 P;
				vec3 N;
				float view_depth;
				float depth;

				if (!srgi_surface(pos, P, N, view_depth, depth) || !scene_hits_ready()) {
					imageStore(out_raw, pos, vec4(0.0));
					return;
				}

				vec3 origin = srgi_ray_origin(pos, P, N, view_depth, depth);
				vec3 geometric_N = normalize(origin - P);
				float range = srgi_data.range * ddgi_spacing(0);
				vec2 noise = srgi_data.blue_noise_tex >= 0 ? blue_noise_texel(TEXTURE(srgi_data.blue_noise_tex), pos).rg : vec2(0.5);
				vec3 sum = vec3(0.0);

				for (int k = 0; k < srgi_data.rays; k++) {
					vec3 dir = srgi_cosine_direction(N, blue_noise_r2(noise, float((uint(srgi_data.frame) * uint(srgi_data.rays) + uint(k)) % 4096u)));
					float below = dot(dir, geometric_N);

					if (below < 0.01) dir = normalize(dir + geometric_N * (0.01 - 2.0 * below));

					float t;
					uint instance;
					uint primitive;
					vec2 barycentrics;

					bool hit = trace_scene_hit(origin, dir, 0.0, range, t, instance, primitive, barycentrics);
					vec3 L = hit ? shade_scene_hit(origin, dir, 1.0, t, instance, primitive, barycentrics) : srgi_far_field(origin + dir * range, dir);

					if (srgi_data.optical_tint != 0) {
						if (!hit) t = range;

						L *= get_optical_tint(origin, dir, t, hit);

						if (hit) L += optical_inscatter_lit(origin, dir, t, ddgi_fog_ambient(), ddgi_data.ddgi_sun_radiance.rgb, normalize(ddgi_data.ddgi_sun_direction.xyz), true);
					}

					sum += L;
				}

				imageStore(out_raw, pos, vec4(min(max(sum / float(srgi_data.rays), vec3(0.0)), vec3(65000.0)), 1.0));
			}
		]],
	}
end

local function pass_accumulate()
	return {
		name = "short_range_gi_accumulate",
		ComputePass = true,
		is_enabled = is_enabled,
		ColorFormat = {
			{
				"r16g16b16a16_sfloat",
				{"short_range_gi", "rgb", 1 / post_source.UNEXPOSED_SDR_WHITE},
			},
			{"r16g16b16a16_sfloat", {"short_range_gi_geometry", "rgb"}},
		},
		framebuffer_count = 2,
		LocalSize = LOCAL_SIZE,
		storage_images = {
			{binding_index = 0, attachment = 1, dst_stage = "compute"},
			{binding_index = 1, attachment = 2, dst_stage = "compute"},
		},
		uniform_buffers = {uniform(false)},
		custom_declarations = [[
			layout(set = 0, binding = 0, rgba16f) uniform writeonly image2D out_color;
			layout(set = 0, binding = 1, rgba16f) uniform writeonly image2D out_geometry;
		]],
		shader = SURFACE_GLSL .. [[
			void main() {
				ivec2 pos = get_screen_pos();
				ivec2 size = imageSize(out_color);

				if (!is_screen_pos_in_bounds(pos, size)) return;

				vec3 P;
				vec3 N;
				float view_depth;
				float depth;

				if (!srgi_surface(pos, P, N, view_depth, depth)) {
					imageStore(out_color, pos, vec4(0.0));
					imageStore(out_geometry, pos, vec4(0.0));
					return;
				}

				vec4 current = texelFetch(TEXTURE(srgi_data.raw_tex), pos, 0);
				vec4 history = vec4(0.0);
				float total = 0.0;

				if (srgi_data.history_valid != 0) {
					vec4 prev_view_pos = srgi_data.prev_view * vec4(P, 1.0);
					float prev_depth = -prev_view_pos.z;
					vec4 clip = srgi_data.prev_projection * prev_view_pos;
					vec2 position = (clip.xy / clip.w * 0.5 + 0.5) * vec2(size) - 0.5;
					ivec2 base = ivec2(floor(position));
					vec2 fraction = position - vec2(base);

					if (prev_depth > 0.0) {
						for (int i = 0; i < 4; i++) {
							ivec2 q = base + ivec2(i & 1, i >> 1);

							if (any(lessThan(q, ivec2(0))) || any(greaterThanEqual(q, size))) continue;

							vec4 geometry = texelFetch(TEXTURE(srgi_data.history_geometry_tex), q, 0);

							if (dot(geometry.xyz, N) < 0.8 || abs(geometry.w - prev_depth) > 0.02 * prev_depth + 0.02) continue;

							float w = (i & 1) == 1 ? fraction.x : 1.0 - fraction.x;
							w *= (i >> 1) == 1 ? fraction.y : 1.0 - fraction.y;
							vec4 value = texelFetch(TEXTURE(srgi_data.history_tex), q, 0);

							if (w <= 0.0 || any(isnan(value))) continue;

							history += value * w;
							total += w;
						}
					}
				}

				float history_length = total > 0.0 ? history.a / total : 0.0;
				vec3 history_color = total > 0.0 ? history.rgb / total : vec3(0.0);
				history_length = min(history_length + 1.0, srgi_data.accumulation);
				imageStore(out_color, pos, vec4(mix(history_color, current.rgb, 1.0 / history_length), history_length));
				imageStore(out_geometry, pos, vec4(N, view_depth));
			}
		]],
	}
end

return {
	pass_trace(),
	pass_accumulate(),
}
