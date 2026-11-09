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
local scene_reflection = import("goluwa/render3d/scene_reflection.lua")
local scene_emitters = import("goluwa/render3d/scene/emitters.lua")
local scene_instances = import("goluwa/render3d/scene/instances.lua")
local restir_gi = import("goluwa/render3d/restir_gi.lua")
local BINDING_OUTPUT = 0
local BINDING_DATA = 8
local BINDING_GI = 9
local BINDING_EMITTERS = 13
local SCENE_BINDINGS = {scene = 10, hit = 30, materials = 11, light_grid = 12}
local LOCAL_SIZE = {x = 8, y = 8, z = 1}
-- decals float a hair above the surface they decorate, rays from that surface would hit their undersides
local NO_DECALS_GLSL = string.format("#define SCENE_REFLECTION_MASK 0x%02X\n", scene_instances.MASK_SURFACES)

local function attachment(pipeline_name, framebuffer, index)
	return render3d.pipelines[pipeline_name]:GetFramebuffer(framebuffer):GetAttachment(index)
end

local function restir_uniform(trace)
	local layout = {
		render3d.camera_block,
		gbuffer_layout.block,
		post_source.pre_exposure_block,
		{"blue_noise_tex", "int"},
		{"frame", "int"},
		{"phase", "int"},
		{"history_valid", "int"},
		{"jitter_shift", "vec2"},
		{"prev_view", "mat4"},
		{"prev_projection", "mat4"},
		{"temporal", "int"},
		{"max_history", "float"},
		{"permutation", "int"},
		{"history_cap", "float"},
		{"hit_gi_share", "float"},
		{"ray_share", "int"},
		{"boiling_filter", "float"},
		{"spatial", "int"},
		{"spatial_samples", "int"},
		{"spatial_radius", "float"},
		{"visibility", "int"},
		{"validation", "int"},
		{"accumulation", "float"},
		{"filter_enabled", "int"},
		{"filter_radius", "float"},
		{"reservoir_a_tex", "int"},
		{"reservoir_b_tex", "int"},
		{"reservoir_c_tex", "int"},
		{"geometry_tex", "int"},
		{"history_a_tex", "int"},
		{"history_b_tex", "int"},
		{"history_c_tex", "int"},
		{"history_geometry_tex", "int"},
		{"history_receiver_tex", "int"},
		{"screen_gi_tex", "int"},
		{"screen_geometry_tex", "int"},
		{"candidate_a_tex", "int"},
		{"candidate_b_tex", "int"},
		{"candidate_c_tex", "int"},
		{"raw_tex", "int"},
		{"accum_tex", "int"},
		{"accum_moments_tex", "int"},
		{"accum_history_tex", "int"},
		{"accum_history_moments_tex", "int"},
		{"blur_tex", "int"},
	}

	if trace then
		layout[#layout + 1] = scene_reflection.block
		layout[#layout + 1] = atmosphere.GetBlockLayout()
		layout[#layout + 1] = {"primary_sun_illuminance", "float"}
		layout[#layout + 1] = {"env_tex", "int"}
	end

	return {
		name = "restir_data",
		binding_index = BINDING_DATA,
		block = layout,
		write = function(self, block)
			render3d.WriteCameraBlock(self, block)
			gbuffer_layout.WriteBlock(self, block)
			post_source.WritePreExposureBlock(self, block)
			local frame = system.GetFrameNumber()
			local current = frame % 2 + 1
			local previous = (frame + 1) % 2 + 1
			block.blue_noise_tex = self:GetTextureIndex(assets.GetTexture("textures/render/blue_noise.lua"))
			block.frame = frame % 65536
			block.phase = render3d.GetTemporalFrame() % 4
			local trace_pipeline = render3d.pipelines.restir_gi_temporal
			local accumulate_pipeline = render3d.pipelines.restir_gi_accumulate

			if
				trace_pipeline.restir_framebuffers ~= trace_pipeline.framebuffers or
				accumulate_pipeline.restir_framebuffers ~= accumulate_pipeline.framebuffers
			then
				trace_pipeline.restir_framebuffers = trace_pipeline.framebuffers
				accumulate_pipeline.restir_framebuffers = accumulate_pipeline.framebuffers
				restir_gi.ResetHistory()
			end

			block.history_valid = render3d.ShouldUseLastFrameHistory() and
				frame > restir_gi.GetResetFrame()
				and
				1 or
				0
			local camera = render3d.GetCamera()
			local viewport = camera:GetViewport()
			block.jitter_shift[0] = (render3d.previous_jitter.x - camera:GetJitter().x) / viewport.w
			block.jitter_shift[1] = (render3d.previous_jitter.y - camera:GetJitter().y) / viewport.h
			local prev_view = render3d.GetPreviousViewMatrix() or camera:BuildViewMatrix()
			local prev_projection = render3d.GetPreviousProjectionMatrix() or camera:BuildProjectionMatrix()
			prev_view:CopyToFloatPointer(block.prev_view)
			prev_projection:CopyToFloatPointer(block.prev_projection)
			block.temporal = restir_gi.temporal:Get() and 1 or 0
			block.max_history = restir_gi.max_history:Get()
			block.permutation = restir_gi.permutation:Get() and 1 or 0
			block.history_cap = restir_gi.GetHistoryCap()
			block.hit_gi_share = restir_gi.hit_gi_share:Get()
			block.ray_share = restir_gi.GetRayShare()
			block.boiling_filter = restir_gi.boiling_filter:Get()
			block.spatial = restir_gi.spatial:Get() and 1 or 0
			block.spatial_samples = restir_gi.spatial_samples:Get()
			block.spatial_radius = restir_gi.spatial_radius:Get()
			block.visibility = restir_gi.visibility:Get() and 1 or 0
			block.validation = restir_gi.validation:Get() and 1 or 0
			block.accumulation = restir_gi.accumulation:Get()
			block.filter_enabled = restir_gi.filter:Get() and 1 or 0
			block.filter_radius = restir_gi.filter_radius:Get()
			block.reservoir_a_tex = self:GetTextureIndex(attachment("restir_gi_temporal", current, 1))
			block.reservoir_b_tex = self:GetTextureIndex(attachment("restir_gi_temporal", current, 2))
			block.reservoir_c_tex = self:GetTextureIndex(attachment("restir_gi_temporal", current, 3))
			block.geometry_tex = self:GetTextureIndex(attachment("restir_gi_temporal", current, 4))
			block.history_a_tex = self:GetTextureIndex(attachment("restir_gi_temporal", previous, 1))
			block.history_b_tex = self:GetTextureIndex(attachment("restir_gi_temporal", previous, 2))
			block.history_c_tex = self:GetTextureIndex(attachment("restir_gi_temporal", previous, 3))
			block.history_geometry_tex = self:GetTextureIndex(attachment("restir_gi_temporal", previous, 4))
			block.history_receiver_tex = self:GetTextureIndex(attachment("restir_gi_temporal", previous, 5))
			-- last frame's raw estimate, read before the spatial pass rewrites it: feeding back the denoised output makes every bounce wait on its history
			block.screen_gi_tex = block.history_valid == 1 and
				self:GetTextureIndex(attachment("restir_gi_spatial", 1, 1)) or
				-1
			block.screen_geometry_tex = self:GetTextureIndex(attachment("restir_gi_temporal", previous, 4))
			block.candidate_a_tex = self:GetTextureIndex(attachment("restir_gi_candidates", 1, 1))
			block.candidate_b_tex = self:GetTextureIndex(attachment("restir_gi_candidates", 1, 2))
			block.candidate_c_tex = self:GetTextureIndex(attachment("restir_gi_candidates", 1, 3))
			block.raw_tex = self:GetTextureIndex(attachment("restir_gi_spatial", 1, 1))
			block.accum_tex = self:GetTextureIndex(attachment("restir_gi_accumulate", current, 1))
			block.accum_moments_tex = self:GetTextureIndex(attachment("restir_gi_accumulate", current, 2))
			block.accum_history_tex = self:GetTextureIndex(attachment("restir_gi_accumulate", previous, 1))
			block.accum_history_moments_tex = self:GetTextureIndex(attachment("restir_gi_accumulate", previous, 2))
			block.blur_tex = self:GetTextureIndex(attachment("restir_gi_blur", 1, 1))

			if trace then
				scene_reflection.WriteBlock(self, block)
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

local function storage_images(count)
	local images = {}

	for i = 1, count do
		images[i] = {binding_index = BINDING_OUTPUT + i - 1, attachment = i, dst_stage = "compute"}
	end

	return images
end

local SURFACE_GLSL = glsl_common.GetConstantsGLSL() .. glsl_common.GetHashGLSL() .. compute_helpers.GetScreenHelpersGLSL() .. gbuffer_layout.GetDecodeGLSL("restir_data") .. ibl.GetReflectionQuadGLSL() .. screen_reconstruct.GetWorldPosFromUVGLSL("restir_data") .. screen_reconstruct.GetGeometricNormalGLSL("restir_data", {world_pos_function = "get_world_pos"}) .. [[

	#define RESTIR_PI 3.14159265359
	#define RESTIR_EMPTY 0
	#define RESTIR_SURFACE 1
	#define RESTIR_SKY 2
	#define RESTIR_EMITTER 3
	#define restir_is_point(kind) (((kind) & 1) != 0)
	#define RESTIR_FLAG_MISS 4
	#define RESTIR_FLAG_CHANGED 8
	#define RESTIR_FLAG_TRACED 16
	#define RESTIR_SKY_DEPTH 65504.0

	struct restir_sample {
		vec3 x;
		vec3 n;
		vec3 L;
		int kind;
	};

	bool restir_surface(ivec2 pos, ivec2 size, out ivec2 gpos, out vec3 P, out vec3 N, out float view_depth, out float depth) {
		ivec2 gsize = textureSize(TEXTURE(restir_data.depth_tex), 0);
		gpos = min(get_reflection_gbuffer_pos(pos, restir_data.phase, gsize, size), gsize - 1);
		depth = gbuffer_depth(gpos);
		P = vec3(0.0);
		N = vec3(0.0);
		view_depth = RESTIR_SKY_DEPTH;

		if (depth <= 0.0) return false;

		P = get_world_pos((vec2(gpos) + 0.5) / vec2(gsize), depth);
		N = normalize(gbuffer_normal(gpos));
		view_depth = -(restir_data.view * vec4(P, 1.0)).z;
		return true;
	}

	// a pixel at a crease reconstructs a hair behind one of its two planes, lift it off every neighbouring pixel's plane it lies on
	vec3 restir_ray_origin(ivec2 gpos, vec3 P, vec3 N, float view_depth, float depth) {
		vec3 V = normalize(restir_data.camera_position - P);
		float offset = 0.01 + 0.001 * view_depth;
		vec3 pull = get_geometric_normal(gpos, P, depth, V, N);
		ivec2 gsize = textureSize(TEXTURE(restir_data.depth_tex), 0);

		for (int i = 0; i < 4; i++) {
			ivec2 q = clamp(gpos + ivec2(i == 0 ? 1 : i == 1 ? -1 : 0, i == 2 ? 1 : i == 3 ? -1 : 0), ivec2(0), gsize - 1);
			float q_depth = gbuffer_depth(q);

			if (q_depth <= 0.0) continue;

			vec3 q_N = normalize(gbuffer_normal(q));

			if (dot(q_N, pull) < 0.99 && abs(dot(P - get_world_pos((vec2(q) + 0.5) / vec2(gsize), q_depth), q_N)) < offset) pull += q_N;
		}

		return P + normalize(pull) * offset;
	}

	restir_sample restir_load(int a_tex, int b_tex, int c_tex, ivec2 pos, out float W, out float M, out int flags) {
		vec4 a = texelFetch(TEXTURE(a_tex), pos, 0);
		vec4 b = texelFetch(TEXTURE(b_tex), pos, 0);
		vec4 c = texelFetch(TEXTURE(c_tex), pos, 0);
		flags = int(c.w + 0.5);
		W = a.w;
		M = b.w;

		if (!(W >= 0.0 && W < 1e30) || !(M >= 0.0) || any(isnan(b.rgb)) || any(isnan(a.xyz))) {
			W = 0.0;
			M = 0.0;
			flags = 0;
		}

		return restir_sample(a.xyz, c.xyz, max(b.rgb, vec3(0.0)), flags & 3);
	}

	float restir_receiver_cosine(restir_sample s, vec3 P, vec3 N, out vec3 dir, out float dist) {
		if (s.kind == RESTIR_SKY) {
			dir = s.x;
			dist = 1e30;
		} else {
			vec3 to_sample = s.x - P;
			dist = length(to_sample);
			dir = to_sample / max(dist, 1e-6);

			if (!restir_is_point(s.kind) || dot(s.n, dir) >= 0.0) return 0.0;
		}

		return max(dot(N, dir), 0.0);
	}

	float restir_jacobian(restir_sample s, vec3 R, vec3 Q) {
		if (!restir_is_point(s.kind)) return 1.0;

		vec3 to_r = R - s.x;
		vec3 to_q = Q - s.x;
		float r2 = dot(to_r, to_r);
		float q2 = dot(to_q, to_q);
		float cos_r = dot(s.n, to_r) * inversesqrt(max(r2, 1e-12));
		float cos_q = dot(s.n, to_q) * inversesqrt(max(q2, 1e-12));

		if (cos_r <= 0.0 || cos_q <= 1e-4) return 0.0;

		return cos_r / cos_q * q2 / max(r2, 1e-12);
	}

	bool restir_traces(ivec2 pos) {
		if (restir_data.ray_share <= 1) return true;

		if (restir_data.ray_share == 2) return ((pos.x + pos.y + restir_data.frame) & 1) == 0;

		const ivec2 order[4] = ivec2[4](ivec2(0, 0), ivec2(1, 1), ivec2(1, 0), ivec2(0, 1));
		return (pos & 1) == order[restir_data.frame & 3];
	}

	float restir_random(ivec2 pos, uint stream) {
		return float(pcg3d(uvec3(uvec2(pos), uint(restir_data.frame) * 16u + stream)).x >> 8u) / 16777216.0;
	}

	bool restir_history_matches(ivec2 q, ivec2 size, vec3 N, float prev_depth, float tolerance) {
		if (any(lessThan(q, ivec2(0))) || any(greaterThanEqual(q, size))) return false;

		vec4 g = texelFetch(TEXTURE(restir_data.history_geometry_tex), q, 0);
		return dot(g.xyz, g.xyz) > 0.25 && abs(g.w - prev_depth) <= tolerance && dot(g.xyz, N) >= 0.8;
	}

	// the gi pixel's centre is reprojected, not the screen pixel it samples this frame, or a still view resamples its history bilinearly every frame and smears it
	bool restir_history_taps(ivec2 pos, ivec2 gpos, vec3 P, vec3 N, ivec2 size, out ivec2 base, out vec4 weights, out float prev_depth, out float tolerance) {
		weights = vec4(0.0);
		base = ivec2(0);
		prev_depth = 0.0;
		tolerance = 0.0;

		if (restir_data.history_valid == 0) return false;

		ivec2 gsize = textureSize(TEXTURE(restir_data.depth_tex), 0);
		vec2 uv = (vec2(gpos) + 0.5) / vec2(gsize);
		vec2 prev_uv;

		if (restir_data.velocity_tex != -1) {
			vec3 motion = texture(TEXTURE(restir_data.velocity_tex), uv).rgb;
			prev_uv = uv - motion.xy + restir_data.jitter_shift;
			prev_depth = motion.z;
		} else {
			vec4 prev_view_pos = restir_data.prev_view * vec4(P, 1.0);
			vec4 prev_clip = restir_data.prev_projection * prev_view_pos;

			if (prev_clip.w <= 1e-5) return false;

			prev_uv = prev_clip.xy / prev_clip.w * 0.5 + 0.5 + restir_data.jitter_shift;
			prev_depth = -prev_view_pos.z;
		}

		prev_uv += (vec2(pos) + 0.5) / vec2(size) - uv;

		if (prev_depth <= 1e-5 || any(lessThan(prev_uv, vec2(0.0))) || any(greaterThan(prev_uv, vec2(1.0)))) return false;

		vec2 position = prev_uv * vec2(size) - 0.5;
		base = ivec2(floor(position));
		vec2 f = position - vec2(base);
		vec3 V = normalize(restir_data.camera_position - P);
		tolerance = prev_depth * 0.02 / max(abs(dot(N, V)), 0.15) + 0.01;

		for (int i = 0; i < 4; i++) {
			if (!restir_history_matches(base + ivec2(i & 1, i >> 1), size, N, prev_depth, tolerance)) continue;

			weights[i] = ((i & 1) == 1 ? f.x : 1.0 - f.x) * ((i >> 1) == 1 ? f.y : 1.0 - f.y) + 1e-4;
		}

		return dot(weights, vec4(1.0)) > 0.0;
	}
]]
-- the world cache lookup at off screen hits (light past the first bounce) runs for a whole thread group on one frame in 1/share and counts 1/share as much: a linear estimate, so no bias and nothing leaks, and coherent per group, so the warps that skip it skip its visibility rays
local HIT_GI_SHARE_GLSL = [[
	float restir_hit_gi_share = 1.0;

	void restir_pick_hit_gi(ivec2 group) {
		int period = int(round(1.0 / restir_data.hit_gi_share));
		// a hashed phase per group: a linear one lines the groups that look up on the same frame up into diagonal bands
		int phase = int(pcg3d(uvec3(uvec2(group), 0x2545F491u)).x % uint(max(period, 1)));
		restir_hit_gi_share = period <= 1 || (phase + restir_data.frame) % period == 0 ? 1.0 / float(max(period, 1)) : 0.0;
	}
]]
-- hits the camera saw last frame read this gi's own result there instead of the world cache, probe caches leak at the foot of walls
local SCREEN_GI_GLSL = [[
	#define SCENE_HIT_SCREEN_GI

	bool scene_hit_screen_gi(vec3 P, vec3 N, out vec3 irradiance) {
		irradiance = vec3(0.0);

		if (restir_data.screen_gi_tex < 0) return false;

		vec4 view_pos = restir_data.prev_view * vec4(P, 1.0);
		float view_depth = -view_pos.z;

		if (view_depth <= 0.01) return false;

		vec4 clip = restir_data.prev_projection * view_pos;
		vec2 uv = clip.xy / clip.w * 0.5 + 0.5;

		if (any(lessThan(uv, vec2(0.0))) || any(greaterThanEqual(uv, vec2(1.0)))) return false;

		ivec2 size = textureSize(TEXTURE(restir_data.screen_gi_tex), 0);
		ivec2 texel = min(ivec2(uv * vec2(size)), size - 1);
		vec4 geometry = texelFetch(TEXTURE(restir_data.screen_geometry_tex), texel, 0);

		if (dot(geometry.xyz, N) < 0.8 || abs(geometry.w - view_depth) > 0.02 * view_depth + 0.02) return false;

		irradiance = texelFetch(TEXTURE(restir_data.screen_gi_tex), texel, 0).rgb;
		return !any(isnan(irradiance));
	}
]]
local TRACE_GLSL = "#define SCENE_HIT_GI_SHARE restir_hit_gi_share\n#define SCENE_HIT_SKY_RAYS 1\n#define SCENE_HIT_EMISSION (ddgi_data.ddgi_emitter_count == 0)\n" .. NO_DECALS_GLSL .. glsl_common.GetConstantsGLSL() .. render3d.GetEmissiveGLSL() .. glsl_common.GetBlueNoiseGLSL() .. SURFACE_GLSL .. SCREEN_GI_GLSL .. HIT_GI_SHARE_GLSL .. ibl.GetEnvironmentGLSLCode() .. post_source.GetPreExposureGLSL("restir_data") .. atmosphere.GetGLSLDefines("restir_data", "restir_data.primary_sun_illuminance") .. atmosphere.GetAerialPerspectiveGLSLCode() .. scene_reflection.GetGLSL("restir_data") .. [[
			vec3 restir_cosine_direction(vec3 N, vec2 xi) {
				vec3 up = abs(N.y) < 0.999 ? vec3(0.0, 1.0, 0.0) : vec3(1.0, 0.0, 0.0);
				vec3 T = normalize(cross(up, N));
				vec3 B = cross(N, T);
				float phi = 6.28318530718 * xi.x;
				float r = sqrt(xi.y);
				return normalize(T * (r * cos(phi)) + B * (r * sin(phi)) + N * sqrt(max(1.0 - xi.y, 0.0)));
			}

			// rays leave emission to the emitter samples, so an emitter sample holds only emission and a ray hit only reflected light
			restir_sample restir_trace(vec3 origin, vec3 dir, bool emitter, out bool miss) {
				float t;
				uint instance;
				uint primitive;
				vec2 barycentrics;
				restir_sample s;
				miss = !trace_scene_hit(origin, dir, 0.0, SCENE_REFLECTION_MAX_DISTANCE, t, instance, primitive, barycentrics);

				if (miss) {
					s = restir_sample(dir, vec3(0.0), ddgi_sky(dir), RESTIR_SKY);
					t = SCENE_REFLECTION_MAX_DISTANCE;
				} else {
					scene_triangle tri = scene_hit_tri(instance, primitive);
					vec3 hit_N = -tri.normal;

					if (dot(hit_N, dir) > 0.0) hit_N = -hit_N;

					vec3 P = origin + dir * t;
					s = emitter ?
						restir_sample(P, hit_N, ddgi_emission(tri, ddgi_albedo(ddgi_materials[tri.material], P)), RESTIR_EMITTER) :
						restir_sample(P, hit_N, shade_scene_reflection_hit(origin, dir, 1.0, t, instance, primitive, barycentrics), RESTIR_SURFACE);
				}

				if (restir_data.glass_light != 0) s.L *= get_glass_light(origin, dir, t, 0.0);

				s.L = min(max(s.L, vec3(0.0)), vec3(1e9));
				return s;
			}
]]

-- traces this frame's new candidates for the pixels whose turn it is, one thread per tracing pixel so no warp traces a few rays at the cost of a full one
local function pass_candidates()
	return {
		name = "restir_gi_candidates",
		ComputePass = true,
		ColorFormat = {
			{"r32g32b32a32_sfloat", {"restir_candidate_position", "rgb", 0.01}},
			{
				"r32g32b32a32_sfloat",
				{"restir_candidate_radiance", "rgb", 1 / post_source.UNEXPOSED_SDR_WHITE},
			},
			{"r16g16b16a16_sfloat", {"restir_candidate_normal", "rgb"}},
		},
		framebuffer_count = 1,
		scale = restir_gi.GetScale,
		LocalSize = LOCAL_SIZE,
		storage_images = storage_images(3),
		descriptor_sets = scene_reflection.GetDescriptorSets(SCENE_BINDINGS, "compute"),
		storage_buffers = {{binding_index = BINDING_EMITTERS}},
		uniform_buffers = {restir_uniform(true), scene_reflection.GetDDGIUniformBuffer(BINDING_GI)},
		on_pre_draw = function(self, cmd, frame, desc)
			scene_reflection.Bind(self, cmd, desc, SCENE_BINDINGS)
			local emitters = scene_emitters.BuildActive(cmd)
			self:UpdateDescriptorSet("storage_buffer", desc, BINDING_EMITTERS, 0, emitters, emitters:GetSize())
		end,
		on_draw = function(self, cmd, fb, frame, desc)
			local share = restir_gi.GetRayShare()
			self:UploadConstants()
			self.pipeline:DispatchForSize(
				cmd,
				share == 1 and fb.width or math.ceil(fb.width / 2),
				share == 4 and math.ceil(fb.height / 2) or fb.height,
				1,
				desc,
				self.dynamic_offsets
			)
		end,
		custom_declarations = [[
			layout(set = 0, binding = 0, rgba32f) uniform writeonly image2D out_a;
			layout(set = 0, binding = 1, rgba32f) uniform writeonly image2D out_b;
			layout(set = 0, binding = 2, rgba16f) uniform writeonly image2D out_c;
		]] .. scene_reflection.GetDeclarationGLSL(SCENE_BINDINGS) .. scene_emitters.GetDeclarationGLSL(BINDING_EMITTERS),
		shader = TRACE_GLSL .. scene_emitters.GetGLSL() .. [[

			void main() {
				ivec2 id = get_screen_pos();
				ivec2 size = imageSize(out_a);
				const ivec2 order[4] = ivec2[4](ivec2(0, 0), ivec2(1, 1), ivec2(1, 0), ivec2(0, 1));
				ivec2 pos = restir_data.ray_share == 4 ? id * 2 + order[restir_data.frame & 3] : restir_data.ray_share == 2 ? ivec2(id.x * 2 + ((id.y + restir_data.frame) & 1), id.y) : id;

				if (!is_screen_pos_in_bounds(pos, size)) return;

				ivec2 gpos;
				vec3 P;
				vec3 N;
				float view_depth;
				float depth;

				if (!restir_surface(pos, size, gpos, P, N, view_depth, depth) || !scene_reflection_ready()) {
					imageStore(out_a, pos, vec4(0.0));
					imageStore(out_b, pos, vec4(0.0));
					imageStore(out_c, pos, vec4(0.0));
					return;
				}

				restir_pick_hit_gi(ivec2(gl_WorkGroupID.xy));

					vec3 origin = restir_ray_origin(gpos, P, N, view_depth, depth);
					vec3 geometric_N = normalize(origin - P);
					uint frame = uint(restir_data.frame);
					bool miss = false;
					restir_sample chosen;
					float chosen_target = 0.0;
					float w_sum = 0.0;
					int emitter_count = ddgi_data.ddgi_emitter_count;

					{
						vec2 xi = blue_noise_r2(blue_noise_texel(TEXTURE(restir_data.blue_noise_tex), pos).rg, float(frame % 4096u));
						vec3 dir = restir_cosine_direction(N, xi);
						float below = dot(dir, geometric_N);

						if (below < 0.01) dir = normalize(dir + geometric_N * (0.01 - 2.0 * below));

						float ray_cosine = max(dot(N, dir), 1e-4);
						chosen = restir_trace(origin, dir, false, miss);
						chosen_target = luminance(chosen.L) * ray_cosine;
						w_sum = chosen_target / (ray_cosine / RESTIR_PI);
					}

					if (emitter_count > 0) {
						int emitter;
						vec3 point;
						float weight = emitter_pick_sample_local(uint(pos.y * size.x + pos.x), frame, emitter_count, origin, N, 0.05, emitter, point);
						vec3 to_point = point - origin;
						float dist = length(to_point);
						vec3 L_dir = to_point / max(dist, 1e-6);
						float cosine = dot(N, L_dir);

						if (weight > 0.0 && cosine > 0.0 && dist > 0.02 && scene_reflection_visible(origin, L_dir, dist - 0.02)) {
							int e = int(uint(emitter) & 0x03FFFFFFu);
							scene_triangle tri = scene_hit_tri(emitter_instance(e), emitter_triangle(e) & ~EMITTER_DOUBLE_SIDED);
							ddgi_material material = ddgi_materials[tri.material];
							vec3 emitter_N = -tri.normal;

							if (dot(emitter_N, L_dir) > 0.0) emitter_N = -emitter_N;

							vec3 L = ddgi_emission(tri, ddgi_albedo(material, point));

							if (restir_data.glass_light != 0) L *= get_glass_light(origin, L_dir, dist, 0.0);

							float target = luminance(L) * cosine;
							float w = target * weight / (max(dot(material.emissive, vec3(0.2126, 0.7152, 0.0722)), 1e-6) * max(cosine, 1e-3));

							if (w > 0.0 && !isinf(w)) {
								w_sum += w;

								if (restir_random(pos, 1u) * w_sum < w) {
									chosen = restir_sample(point, emitter_N, L, RESTIR_EMITTER);
									chosen_target = target;
								}
							}
						}
					}

				imageStore(out_a, pos, vec4(chosen.x, w_sum));
				imageStore(out_b, pos, vec4(chosen.L, chosen_target));
				imageStore(out_c, pos, vec4(chosen.n, float(chosen.kind | (miss ? RESTIR_FLAG_MISS : 0))));
			}
		]],
	}
end

local function pass_temporal()
	return {
		name = "restir_gi_temporal",
		ComputePass = true,
		ColorFormat = {
			{"r32g32b32a32_sfloat", {"restir_reservoir_position", "rgb", 0.01}},
			{
				"r32g32b32a32_sfloat",
				{"restir_reservoir_radiance", "rgb", 1 / post_source.UNEXPOSED_SDR_WHITE},
			},
			{"r16g16b16a16_sfloat", {"restir_reservoir_normal", "rgb"}},
			{"r16g16b16a16_sfloat", {"restir_geometry", "rgb"}},
			{"r32g32b32a32_sfloat", {"restir_receiver", "rgb", 0.01}},
		},
		framebuffer_count = 2,
		scale = restir_gi.GetScale,
		LocalSize = LOCAL_SIZE,
		storage_images = storage_images(5),
		descriptor_sets = scene_reflection.GetDescriptorSets(SCENE_BINDINGS, "compute"),
		uniform_buffers = {restir_uniform(true), scene_reflection.GetDDGIUniformBuffer(BINDING_GI)},
		on_pre_draw = function(self, cmd, frame, desc)
			scene_reflection.Bind(self, cmd, desc, SCENE_BINDINGS)
		end,
		custom_declarations = [[
			layout(set = 0, binding = 0, rgba32f) uniform writeonly image2D out_a;
			layout(set = 0, binding = 1, rgba32f) uniform writeonly image2D out_b;
			layout(set = 0, binding = 2, rgba16f) uniform writeonly image2D out_c;
			layout(set = 0, binding = 3, rgba16f) uniform writeonly image2D out_geometry;
			layout(set = 0, binding = 4, rgba32f) uniform writeonly image2D out_receiver;
		]] .. scene_reflection.GetDeclarationGLSL(SCENE_BINDINGS),
		shader = TRACE_GLSL .. [[

			shared float restir_group_contribution[64];

			void main() {
				ivec2 pos = get_screen_pos();
				ivec2 size = imageSize(out_a);
				restir_sample chosen = restir_sample(vec3(0.0), vec3(0.0), vec3(0.0), RESTIR_EMPTY);
				restir_sample fresh = chosen;
				float W = 0.0;
				float fresh_W = 0.0;
				float M = 0.0;
				int flags = 0;
				float contribution = 0.0;
				vec3 receiver = vec3(0.0);
				bool kept = false;
				ivec2 gpos;
				vec3 P;
				vec3 N;
				float view_depth;
				float depth;
				bool surface = is_screen_pos_in_bounds(pos, size) && restir_surface(pos, size, gpos, P, N, view_depth, depth) && scene_reflection_ready();

				if (surface) {
					uint frame = uint(restir_data.frame);
					bool traces = restir_traces(pos);
					bool miss = false;
					float chosen_target = 0.0;
					float w_sum = 0.0;

					if (traces) {
						vec4 candidate_a = texelFetch(TEXTURE(restir_data.candidate_a_tex), pos, 0);
						vec4 candidate_b = texelFetch(TEXTURE(restir_data.candidate_b_tex), pos, 0);
						vec4 candidate_c = texelFetch(TEXTURE(restir_data.candidate_c_tex), pos, 0);
						int candidate_flags = int(candidate_c.w + 0.5);
						chosen = restir_sample(candidate_a.xyz, candidate_c.xyz, candidate_b.rgb, candidate_flags & 3);
						w_sum = candidate_a.w;
						chosen_target = candidate_b.w;
						miss = (candidate_flags & RESTIR_FLAG_MISS) != 0;
					}

					fresh = chosen;
					fresh_W = chosen_target > 0.0 ? w_sum / chosen_target : 0.0;
					// a pixel that traced nothing this frame enters the resampling with no confidence, its history keeps all the weight
					M = traces ? 1.0 : 0.0;
					flags = traces ? RESTIR_FLAG_TRACED | (miss ? RESTIR_FLAG_MISS : 0) : 0;
					ivec2 base;
					vec4 weights;

					float prev_depth;
					float tolerance;

					if (restir_data.temporal != 0 && restir_history_taps(pos, gpos, P, N, size, base, weights, prev_depth, tolerance)) {
						float pick = restir_random(pos, 2u) * dot(weights, vec4(1.0));
						int tap = 3;

						for (int i = 0; i < 3; i++) {
							pick -= weights[i];

							if (pick < 0.0) {
								tap = i;
								break;
							}
						}

						while (tap > 0 && weights[tap] <= 0.0) tap--;

						ivec2 q = base + ivec2(tap & 1, tap >> 1);
						// permutation sampling: the frame swaps reservoirs with a neighbour, so a lucky sample does not sit in one spot for its whole history
						ivec2 permuted = q ^ ivec2(int(frame) & 1, (int(frame) >> 1) & 1);

						// only with a new sample to weigh against: alone, a neighbour's hit point beside a crease enters with its full reconnection jacobian and sits there as a dot
						if (traces && restir_data.permutation != 0 && restir_history_matches(permuted, size, N, prev_depth, tolerance)) q = permuted;

						float h_W;
						float h_M;
						int h_flags;
						restir_sample h = restir_load(restir_data.history_a_tex, restir_data.history_b_tex, restir_data.history_c_tex, q, h_W, h_M, h_flags);
						h_M = min(h_M, restir_data.max_history);
						vec3 h_dir;
						float h_dist;
						float h_cosine = restir_receiver_cosine(h, P, N, h_dir, h_dist);
						vec3 h_receiver = texelFetch(TEXTURE(restir_data.history_receiver_tex), q, 0).xyz;
						vec3 h_normal = texelFetch(TEXTURE(restir_data.history_geometry_tex), q, 0).xyz;

						if (restir_data.validation != 0 && h.kind != RESTIR_EMPTY && h_M > 1.0 && ((pos.x + pos.y * 2 + int(frame)) & 3) == 0) {
							// retraced from where the sample was found: from this frame's screen pixel it often lands on another leaf or edge and the history is thrown away
							bool h_miss;
							vec3 h_origin = h_receiver + h_normal * (0.01 + 0.001 * view_depth);
							vec3 to_h = h.kind == RESTIR_SKY ? h.x : normalize(h.x - h_origin);
							restir_sample retraced = restir_trace(h_origin, to_h, h.kind == RESTIR_EMITTER, h_miss);
							bool moved = retraced.kind != h.kind || (restir_is_point(h.kind) && distance(retraced.x, h.x) > 0.05 * distance(h.x, h_origin) + 0.02);
							float ratio = max(luminance(retraced.L), luminance(h.L)) / max(min(luminance(retraced.L), luminance(h.L)), 1e-6);

							// the stored radiance is never replaced: reservoirs keep samples whose noisy shading came out high, and swapping in a fresh estimate under the same W darkens everything. the history is dropped when the hit is gone or its light clearly changed
							if (ratio > 4.0) flags |= RESTIR_FLAG_CHANGED;

							if (moved || ratio > 4.0) h_M = 0.0;
						}

						float h_target = luminance(h.L) * h_cosine;
						float h_jacobian = restir_jacobian(h, P, h_receiver);

						// on a frame without a new sample the reservoir and the receiver it was found from are kept as they are, so the next traced frame reconnects it once against a new sample to weigh it by. reconnecting it every frame without one lets the receiver's jitter multiply into W unchecked (dots at creases)
						if (!traces && h.kind != RESTIR_EMPTY && h_M > 0.0) {
							chosen = h;
							chosen_target = h_target;
							W = h_W;
							M = h_M;
							receiver = h_receiver;
							kept = true;
						} else if (h.kind != RESTIR_EMPTY && h_M > 0.0) {
							// balance heuristic weights, not sample counts: with the receiver jittering, counts let a hit point next to it ratchet its weight up
							vec3 unused_dir;
							float unused_dist;
							float fresh_there = h_M * luminance(chosen.L) * restir_receiver_cosine(chosen, h_receiver, h_normal, unused_dir, unused_dist) * restir_jacobian(chosen, h_receiver, P);
							float fresh_target = M * chosen_target;
							w_sum *= fresh_target + fresh_there > 0.0 ? fresh_target / (fresh_target + fresh_there) : 1.0;

							if (h_target > 0.0 && h_jacobian > 0.0 && h_jacobian < 1e20) {
								float history_there = h_M * luminance(h.L) * restir_receiver_cosine(h, h_receiver, h_normal, unused_dir, unused_dist) / h_jacobian;
								float w = history_there / (M * h_target + history_there) * h_target * h_jacobian * h_W;
								w_sum += w;

								if (restir_random(pos, 3u) * w_sum < w) {
									chosen = h;
									chosen_target = h_target;
								}
							}

							M += h_M;
						}
					}

					if (!kept) W = chosen_target > 0.0 ? w_sum / chosen_target : 0.0;
					contribution = chosen_target * W;
				}

				// boiling filter: a reservoir far above its group is a sample the reuse blew up, it falls back to this frame's own sample
				float group_sum = 0.0;
				float group_count = 0.0;
				restir_group_contribution[gl_LocalInvocationIndex] = contribution;
				barrier();

				for (int i = 0; i < 64; i++) {
					float c = restir_group_contribution[i];

					if (c > 0.0) {
						group_sum += c;
						group_count += 1.0;
					}
				}

				if (restir_data.boiling_filter > 0.0 && M > 1.0 && fresh.kind != RESTIR_EMPTY && contribution * group_count > restir_data.boiling_filter * group_sum) {
					chosen = fresh;
					W = fresh_W;
					M = 1.0;
				}

				if (!is_screen_pos_in_bounds(pos, size)) return;

				if (!surface) {
					imageStore(out_a, pos, vec4(0.0));
					imageStore(out_b, pos, vec4(0.0));
					imageStore(out_c, pos, vec4(0.0));
					imageStore(out_geometry, pos, vec4(0.0, 0.0, 0.0, RESTIR_SKY_DEPTH));
					imageStore(out_receiver, pos, vec4(0.0));
					return;
				}

				imageStore(out_a, pos, vec4(chosen.x, W));
				imageStore(out_b, pos, vec4(chosen.L, M));
				imageStore(out_c, pos, vec4(chosen.n, float(chosen.kind | flags)));
				imageStore(out_geometry, pos, vec4(N, view_depth));
				imageStore(out_receiver, pos, vec4(kept ? receiver : P, 0.0));
			}
		]],
	}
end

local function pass_spatial()
	return {
		name = "restir_gi_spatial",
		ComputePass = true,
		ColorFormat = {
			{
				"r16g16b16a16_sfloat",
				{"restir_raw", "rgb", 1 / post_source.UNEXPOSED_SDR_WHITE},
			},
		},
		framebuffer_count = 1,
		scale = restir_gi.GetScale,
		LocalSize = LOCAL_SIZE,
		storage_images = storage_images(1),
		descriptor_sets = scene_reflection.GetDescriptorSets(SCENE_BINDINGS, "compute"),
		uniform_buffers = {restir_uniform(true), scene_reflection.GetDDGIUniformBuffer(BINDING_GI)},
		on_pre_draw = function(self, cmd, frame, desc)
			scene_reflection.Bind(self, cmd, desc, SCENE_BINDINGS)
		end,
		custom_declarations = [[
			layout(set = 0, binding = 0, rgba16f) uniform writeonly image2D out_raw;
		]] .. scene_reflection.GetDeclarationGLSL(SCENE_BINDINGS),
		shader = NO_DECALS_GLSL .. glsl_common.GetConstantsGLSL() .. render3d.GetEmissiveGLSL() .. SURFACE_GLSL .. ibl.GetEnvironmentGLSLCode() .. post_source.GetPreExposureGLSL("restir_data") .. atmosphere.GetGLSLDefines("restir_data", "restir_data.primary_sun_illuminance") .. atmosphere.GetAerialPerspectiveGLSLCode() .. scene_reflection.GetGLSL("restir_data") .. [[

			void main() {
				ivec2 pos = get_screen_pos();
				ivec2 size = imageSize(out_raw);

				if (!is_screen_pos_in_bounds(pos, size)) return;

				ivec2 gpos;
				vec3 P;
				vec3 N;
				float view_depth;
				float depth;

				if (!restir_surface(pos, size, gpos, P, N, view_depth, depth)) {
					imageStore(out_raw, pos, vec4(0.0, 0.0, 0.0, 1.0));
					return;
				}

				float W;
				float M;
				int flags;
				restir_sample own = restir_load(restir_data.reservoir_a_tex, restir_data.reservoir_b_tex, restir_data.reservoir_c_tex, pos, W, M, flags);
				vec3 dir;
				float dist;
				float own_cosine = restir_receiver_cosine(own, P, N, dir, dist);
				float own_target = luminance(own.L) * own_cosine;
				vec3 irradiance = own.L * (own_cosine * W);

				// pairwise mis: neighbours get little say over light only this pixel can find (the wall beside it in a crease)
				if (restir_data.spatial != 0 && scene_reflection_ready()) {
					vec3 origin = restir_ray_origin(gpos, P, N, view_depth, depth);
					float turn = restir_random(pos, 4u) * 6.28318530718;
					float plane_tolerance = 0.01 + 0.02 * view_depth;
					float k = float(restir_data.spatial_samples);
					float own_weight = 0.0;
					float valid = 0.0;
					vec3 neighbours = vec3(0.0);

					for (int i = 0; i < restir_data.spatial_samples; i++) {
						float angle = turn + float(i) * 2.39996323;
						float radius = sqrt((float(i) + restir_random(pos, 5u + uint(i))) / k) * restir_data.spatial_radius;
						ivec2 q = pos + ivec2(round(vec2(cos(angle), sin(angle)) * radius));

						ivec2 q_gpos;
						vec3 q_P;
						vec3 q_N;
						float q_view_depth;
						float q_depth;
						float q_W;
						float q_M = 0.0;
						int q_flags;
						restir_sample s;

						if (q != pos && all(greaterThanEqual(q, ivec2(0))) && all(lessThan(q, size)) && restir_surface(q, size, q_gpos, q_P, q_N, q_view_depth, q_depth) && dot(N, q_N) >= 0.9 && abs(dot(N, q_P - P)) <= plane_tolerance) {
							s = restir_load(restir_data.reservoir_a_tex, restir_data.reservoir_b_tex, restir_data.reservoir_c_tex, q, q_W, q_M, q_flags);
						}

						if (q_M <= 0.0) {
							own_weight += 1.0;
							continue;
						}

						valid += 1.0;

						vec3 q_dir;
						float q_dist;
						float own_at_q = q_M * luminance(own.L) * restir_receiver_cosine(own, q_P, q_N, q_dir, q_dist) * restir_jacobian(own, q_P, P);

						// a neighbour that cannot see this pixel's sample could not have found it, crediting it anyway darkens light found through gaps (canopies)
						if (own_at_q > 0.0 && own_target > 0.0 && restir_data.visibility != 0) {
							vec3 q_origin = restir_ray_origin(q_gpos, q_P, q_N, q_view_depth, q_depth);
							vec3 to_own = own.kind == RESTIR_SKY ? own.x * SCENE_REFLECTION_MAX_DISTANCE : own.x + own.n * 0.01 - q_origin;
							float own_length = length(to_own);

							if (!scene_reflection_visible(q_origin, to_own / own_length, own.kind == RESTIR_SKY ? own_length : max(own_length - 0.03, 0.0))) own_at_q = 0.0;
						}

						own_weight += own_target * M / k + own_at_q > 0.0 ? own_target * M / k / (own_target * M / k + own_at_q) : 1.0;
						float jacobian = restir_jacobian(s, P, q_P);
						vec3 s_dir;
						float s_dist;
						float s_cosine = restir_receiver_cosine(s, P, N, s_dir, s_dist);

						if (!(jacobian > 0.0 && jacobian < 1e20) || s_cosine <= 0.0 || q_W <= 0.0 || luminance(s.L) <= 0.0) continue;

						if (restir_data.visibility != 0) {
							vec3 to_sample = s.kind == RESTIR_SKY ? s.x * SCENE_REFLECTION_MAX_DISTANCE : s.x + s.n * 0.01 - origin;
							float ray_length = length(to_sample);

							if (!scene_reflection_visible(origin, to_sample / ray_length, s.kind == RESTIR_SKY ? ray_length : max(ray_length - 0.03, 0.0))) continue;
						}

						float target_here = luminance(s.L) * s_cosine * M / k;
						float target_there = q_M * luminance(s.L) * restir_receiver_cosine(s, q_P, q_N, q_dir, q_dist) / jacobian;
						float weight = target_there / (target_here + target_there);
						neighbours += s.L * (weight * s_cosine * jacobian * q_W);
					}

					// with no reservoir of its own (not traced yet), the pairs with missing neighbours have no one to give their weight to
					irradiance = M > 0.0 ? (irradiance * own_weight + neighbours) / k : neighbours / max(valid, 1.0);
				}

				irradiance /= RESTIR_PI;

				if (any(isnan(irradiance)) || any(isinf(irradiance))) irradiance = vec3(0.0);

				int sky_flags = flags;

				if ((flags & RESTIR_FLAG_TRACED) == 0) {
					const ivec2 order[4] = ivec2[4](ivec2(0, 0), ivec2(1, 1), ivec2(1, 0), ivec2(0, 1));
					ivec2 partner = restir_data.ray_share == 2 ? pos + ivec2(pos.x + 1 < size.x ? 1 : -1, 0) : (pos & ~1) + order[restir_data.frame & 3];
					sky_flags = int(texelFetch(TEXTURE(restir_data.reservoir_c_tex), clamp(partner, ivec2(0), size - 1), 0).w + 0.5);
				}

				imageStore(out_raw, pos, vec4(min(irradiance, vec3(65000.0)), (sky_flags & RESTIR_FLAG_MISS) != 0 ? 1.0 : 0.0));
			}
		]],
	}
end

local function pass_accumulate()
	return {
		name = "restir_gi_accumulate",
		ComputePass = true,
		ColorFormat = {
			{
				"r32g32b32a32_sfloat",
				{"restir_accumulated", "rgb", 1 / post_source.UNEXPOSED_SDR_WHITE},
			},
			{"r32g32b32a32_sfloat", {"restir_history_length", "r", 1 / 16}},
		},
		framebuffer_count = 2,
		scale = restir_gi.GetScale,
		LocalSize = LOCAL_SIZE,
		storage_images = storage_images(2),
		uniform_buffers = {restir_uniform(false)},
		custom_declarations = [[
			layout(set = 0, binding = 0, rgba32f) uniform writeonly image2D out_color;
			layout(set = 0, binding = 1, rgba32f) uniform writeonly image2D out_moments;
		]],
		shader = SURFACE_GLSL .. [[

			void main() {
				ivec2 pos = get_screen_pos();
				ivec2 size = imageSize(out_color);

				if (!is_screen_pos_in_bounds(pos, size)) return;

				ivec2 gpos;
				vec3 P;
				vec3 N;
				float view_depth;
				float depth;

				if (!restir_surface(pos, size, gpos, P, N, view_depth, depth)) {
					imageStore(out_color, pos, vec4(0.0, 0.0, 0.0, 1.0));
					imageStore(out_moments, pos, vec4(0.0));
					return;
				}

				vec4 current = texelFetch(TEXTURE(restir_data.raw_tex), pos, 0);
				float current_luminance = luminance(current.rgb);
				vec4 history = vec4(0.0);
				vec3 history_moments = vec3(0.0);
				ivec2 base;
				vec4 weights;

				float prev_depth;
				float tolerance;

				if (restir_history_taps(pos, gpos, P, N, size, base, weights, prev_depth, tolerance)) {
					float total = 0.0;

					for (int i = 0; i < 4; i++) {
						if (weights[i] <= 0.0) continue;

						ivec2 q = base + ivec2(i & 1, i >> 1);
						vec4 value = texelFetch(TEXTURE(restir_data.accum_history_tex), q, 0);
						vec3 moments = texelFetch(TEXTURE(restir_data.accum_history_moments_tex), q, 0).xyz;

						if (any(isnan(value)) || any(isnan(moments))) continue;

						history += value * weights[i];
						history_moments += moments * weights[i];
						total += weights[i];
					}

					if (total > 0.0) {
						history /= total;
						history_moments /= total;
					}
				}

				float history_length = history_moments.x;

				for (int y = -1; y <= 1; y++) {
					for (int x = -1; x <= 1; x++) {
						ivec2 q = clamp(pos + ivec2(x, y), ivec2(0), size - 1);

						if ((int(texelFetch(TEXTURE(restir_data.reservoir_c_tex), q, 0).w + 0.5) & RESTIR_FLAG_CHANGED) != 0) history_length = min(history_length, 2.0);
					}
				}

				history_length = min(history_length + 1.0, min(restir_data.accumulation, restir_data.history_cap));
				float alpha = 1.0 / history_length;
				vec2 moments = mix(history_moments.yz, vec2(current_luminance, current_luminance * current_luminance), alpha);
				imageStore(out_color, pos, mix(history, current, alpha));
				imageStore(out_moments, pos, vec4(history_length, moments, 0.0));
			}
		]],
	}
end

local function pass_filter(name, source_field, radius_scale, seed)
	return {
		name = name,
		ComputePass = true,
		ColorFormat = {
			{
				"r16g16b16a16_sfloat",
				{name, "rgb", 1 / post_source.UNEXPOSED_SDR_WHITE},
			},
			{"r16g16b16a16_sfloat", {name .. "_geometry", "rgb"}},
		},
		framebuffer_count = 1,
		scale = restir_gi.GetScale,
		LocalSize = LOCAL_SIZE,
		storage_images = {
			{binding_index = 0, attachment = 1, dst_stage = {"compute", "fragment"}},
			{binding_index = 1, attachment = 2, dst_stage = {"compute", "fragment"}},
		},
		uniform_buffers = {restir_uniform(false)},
		custom_declarations = [[
			layout(set = 0, binding = 0, rgba16f) uniform writeonly image2D out_color;
			layout(set = 0, binding = 1, rgba16f) uniform writeonly image2D out_geometry;
		]],
		shader = SURFACE_GLSL .. [[

			#define RESTIR_FILTER_TAPS 16
			#define RESTIR_FILTER_SOURCE restir_data.]] .. source_field .. [[

			void main() {
				ivec2 pos = get_screen_pos();
				ivec2 size = imageSize(out_color);

				if (!is_screen_pos_in_bounds(pos, size)) return;

				ivec2 gpos;
				vec3 P;
				vec3 N;
				float view_depth;
				float depth;

				if (!restir_surface(pos, size, gpos, P, N, view_depth, depth)) {
					imageStore(out_color, pos, vec4(0.0, 0.0, 0.0, 1.0));
					imageStore(out_geometry, pos, vec4(0.0, 0.0, 0.0, RESTIR_SKY_DEPTH));
					return;
				}

				vec4 center = texelFetch(TEXTURE(RESTIR_FILTER_SOURCE), pos, 0);
				vec4 result = center;

				if (restir_data.filter_enabled != 0) {
					vec3 moments = texelFetch(TEXTURE(restir_data.accum_moments_tex), pos, 0).xyz;
					float history_length = max(moments.x, 1.0);
					float center_luminance = luminance(center.rgb);
					// the temporal variance means little with a few frames of history
					float luminance_scale = history_length < 4.0 ? 0.0 : 1.0 / (4.0 * sqrt(max(moments.z - moments.y * moments.y, 0.0)) + 0.1 * center_luminance + 1e-6);
					float radius = max(restir_data.filter_radius * ]] .. radius_scale .. [[ * mix(1.0, 0.5, saturate(history_length / 16.0)), 1.0);
					float turn = restir_random(pos, ]] .. seed .. [[u) * 6.28318530718;
					float plane_tolerance = 0.01 + 0.01 * view_depth;
					vec4 sum = center;
					float total = 1.0;

					for (int k = 0; k < RESTIR_FILTER_TAPS; k++) {
						float angle = turn + float(k) * 2.39996323;
						ivec2 q = pos + ivec2(round(vec2(cos(angle), sin(angle)) * sqrt((float(k) + 0.5) / float(RESTIR_FILTER_TAPS)) * radius));

						if (q == pos || any(lessThan(q, ivec2(0))) || any(greaterThanEqual(q, size))) continue;

						ivec2 q_gpos;
						vec3 q_P;
						vec3 q_N;
						float q_view_depth;
						float q_depth;

						if (!restir_surface(q, size, q_gpos, q_P, q_N, q_view_depth, q_depth)) continue;

						vec4 value = texelFetch(TEXTURE(RESTIR_FILTER_SOURCE), q, 0);

						if (any(isnan(value))) continue;

						float w = exp(-abs(dot(N, q_P - P)) / plane_tolerance - abs(luminance(value.rgb) - center_luminance) * luminance_scale) * pow(max(dot(N, q_N), 0.0), 16.0);

						if (w <= 1e-4) continue;

						sum += value * w;
						total += w;
					}

					result = sum / total;
				}

				imageStore(out_color, pos, min(result, vec4(65000.0)));
				imageStore(out_geometry, pos, vec4(N, view_depth));
			}
		]],
	}
end

if not render.GetDevice().ray_query_supported then return {} end

return {
	pass_candidates(),
	pass_temporal(),
	pass_spatial(),
	pass_accumulate(),
	pass_filter("restir_gi_blur", "accum_tex", "1.0", "40"),
	pass_filter("restir_gi_filter", "blur_tex", "0.5", "41"),
}
