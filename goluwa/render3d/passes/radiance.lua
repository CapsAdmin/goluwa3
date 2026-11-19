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
local scene_hit = import("goluwa/render3d/scene/hit.lua")
local scene_emitters = import("goluwa/render3d/scene/emitters.lua")
local scene_instances = import("goluwa/render3d/scene/instances.lua")
local surface_features = import("goluwa/render3d/surface_features.lua")
local surface_weather = import("goluwa/render3d/surface_weather.lua")
local radiance = import("goluwa/render3d/radiance.lua")
local BINDING_OUTPUT = 0
local BINDING_DATA = 8
local BINDING_GI = 9
local BINDING_EMITTERS = 13
local SCENE_BINDINGS = {scene = 10, hit = 30, materials = 11, light_grid = 12}
local LOCAL_SIZE = {x = 8, y = 8, z = 1}
-- decals float a hair above the surface they decorate, rays from that surface would hit their undersides
local NO_DECALS_GLSL = string.format("#define SCENE_HIT_MASK 0x%02X\n", scene_instances.MASK_SURFACES)

local function attachment(pipeline_name, framebuffer, index)
	return render3d.pipelines[pipeline_name]:GetFramebuffer(framebuffer):GetAttachment(index)
end

local FILTER_ITERATIONS = 4

local function filter_name(iteration)
	return iteration == FILTER_ITERATIONS - 1 and
		"radiance_filter" or
		"radiance_filter_" .. iteration
end

local function restir_uniform(trace, filter_iteration)
	local layout = {
		render3d.camera_block,
		gbuffer_layout.block,
		surface_weather.rain_surface_block,
		post_source.pre_exposure_block,
		{"blue_noise_tex", "int"},
		{"frame", "int"},
		{"history_valid", "int"},
		{"jitter_shift", "vec2"},
		{"jitter", "vec2"},
		{"prev_view", "mat4"},
		{"prev_projection", "mat4"},
		{"temporal", "int"},
		{"max_history", "float"},
		{"permutation", "int"},
		{"history_cap", "float"},
		{"changed_light_count", "int"},
		{"changed_lights", "vec4", radiance.MAX_CHANGED_LIGHTS},
		{"changed_light_intensities", "vec4", radiance.MAX_CHANGED_LIGHTS},
		{"filter_luminance", "float"},
		{"filter_source_tex", "int"},
		{"filter_specular_source_tex", "int"},
		{"filter_step", "int"},
		{"hit_gi_share", "float"},
		{"guided", "float"},
		{"ray_share", "int"},
		{"boiling_filter", "float"},
		{"spatial", "int"},
		{"spatial_samples", "int"},
		{"spatial_radius", "float"},
		{"visibility", "int"},
		{"temporal_search", "int"},
		{"disocclusion_samples", "int"},
		{"spatial_retries", "int"},
		{"validation", "int"},
		{"accumulation", "float"},
		{"filter_enabled", "int"},
		{"reservoir_a_tex", "int"},
		{"reservoir_b_tex", "int"},
		{"reservoir_c_tex", "int"},
		{"geometry_tex", "int"},
		{"history_a_tex", "int"},
		{"history_b_tex", "int"},
		{"history_c_tex", "int"},
		{"history_geometry_tex", "int"},
		{"history_geometric_normal_tex", "int"},
		{"history_receiver_tex", "int"},
		{"receiver_tex", "int"},
		{"screen_gi_tex", "int"},
		{"screen_geometry_tex", "int"},
		{"candidate_a_tex", "int"},
		{"candidate_b_tex", "int"},
		{"candidate_c_tex", "int"},
		{"raw_tex", "int"},
		{"raw_effective_tex", "int"},
		{"accum_tex", "int"},
		{"accum_moments_tex", "int"},
		{"accum_history_tex", "int"},
		{"accum_history_moments_tex", "int"},
		{"accum_history_irradiance_tex", "int"},
		{"raw_specular_tex", "int"},
		{"candidate_specular_tex", "int"},
		{"specular_reuse", "int"},
		{"accum_history_specular_tex", "int"},
		{"accum_tracking_tex", "int"},
		{"accum_history_tracking_tex", "int"},
		{"candidate_hit_tex", "int"},
		{"specular_tracking", "int"},
		{"brdf_lut_tex", "int"},
		{"specular_emitter_roughness", "float"},
	}

	if trace then
		layout[#layout + 1] = scene_hits.block
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
			surface_weather.WriteRainSurfaceBlock(self, block)
			post_source.WritePreExposureBlock(self, block)
			local frame = system.GetFrameNumber()
			local current = frame % 2 + 1
			local previous = (frame + 1) % 2 + 1
			block.blue_noise_tex = self:GetTextureIndex(
				assert(
					assets.GetTexture("textures/render/blue_noise.lua"),
					"the blue noise texture is not registered"
				)
			)
			block.frame = frame % 65536
			local trace_pipeline = render3d.pipelines.radiance_temporal
			local accumulate_pipeline = render3d.pipelines.radiance_accumulate

			if
				trace_pipeline.restir_framebuffers ~= trace_pipeline.framebuffers or
				accumulate_pipeline.restir_framebuffers ~= accumulate_pipeline.framebuffers
			then
				trace_pipeline.restir_framebuffers = trace_pipeline.framebuffers
				accumulate_pipeline.restir_framebuffers = accumulate_pipeline.framebuffers
				radiance.ResetHistory()
			end

			block.history_valid = render3d.ShouldUseLastFrameHistory() and
				frame > radiance.GetResetFrame()
				and
				1 or
				0
			local camera = render3d.GetCamera()
			local viewport = camera:GetViewport()
			block.jitter_shift[0] = (render3d.previous_jitter.x - camera:GetJitter().x) / viewport.w
			block.jitter_shift[1] = (render3d.previous_jitter.y - camera:GetJitter().y) / viewport.h
			block.jitter[0] = camera:GetJitter().x
			block.jitter[1] = camera:GetJitter().y
			local prev_view = render3d.GetPreviousViewMatrix() or camera:BuildViewMatrix()
			local prev_projection = render3d.GetPreviousProjectionMatrix() or camera:BuildProjectionMatrix()
			prev_view:CopyToFloatPointer(block.prev_view)
			prev_projection:CopyToFloatPointer(block.prev_projection)
			block.temporal = radiance.temporal:Get() and not render3d.IsDenoisingBypassed() and 1 or 0
			block.max_history = radiance.max_history:Get()
			block.permutation = radiance.permutation:Get() and 1 or 0
			block.history_cap = radiance.GetHistoryCap()
			local changed = radiance.GetChangedLights()
			block.changed_light_count = #changed

			for i, light in ipairs(changed) do
				block.changed_lights[i - 1][0] = light.x
				block.changed_lights[i - 1][1] = light.y
				block.changed_lights[i - 1][2] = light.z
				block.changed_lights[i - 1][3] = light.radius
				block.changed_light_intensities[i - 1][0] = light.intensity
			end

			block.filter_luminance = radiance.filter_luminance:Get()
			block.hit_gi_share = radiance.hit_gi_share:Get()
			block.guided = radiance.guided:Get()
			block.ray_share = radiance.GetRayShare()
			block.boiling_filter = radiance.boiling_filter:Get()
			block.spatial = radiance.spatial:Get() and 1 or 0
			block.spatial_samples = radiance.spatial_samples:Get()
			block.spatial_radius = radiance.spatial_radius:Get()
			block.visibility = radiance.visibility:Get() and 1 or 0
			block.temporal_search = radiance.temporal_search:Get() and 1 or 0
			block.disocclusion_samples = radiance.disocclusion_samples:Get()
			block.spatial_retries = radiance.spatial_retries:Get()
			block.validation = radiance.validation:Get() and 1 or 0
			block.accumulation = render3d.IsDenoisingBypassed() and 1 or radiance.accumulation:Get()
			block.filter_enabled = radiance.filter:Get() and not render3d.IsDenoisingBypassed() and 1 or 0
			block.reservoir_a_tex = self:GetTextureIndex(attachment("radiance_temporal", current, 1))
			block.reservoir_b_tex = self:GetTextureIndex(attachment("radiance_temporal", current, 2))
			block.reservoir_c_tex = self:GetTextureIndex(attachment("radiance_temporal", current, 3))
			block.geometry_tex = self:GetTextureIndex(attachment("radiance_temporal", current, 4))
			block.receiver_tex = self:GetTextureIndex(attachment("radiance_temporal", current, 5))
			-- the history is last frame's spatial output, read before the spatial pass rewrites it: a sample one pixel found spreads to its neighbours and stays
			block.history_a_tex = self:GetTextureIndex(attachment("radiance_spatial", 1, 2))
			block.history_b_tex = self:GetTextureIndex(attachment("radiance_spatial", 1, 3))
			block.history_c_tex = self:GetTextureIndex(attachment("radiance_spatial", 1, 4))
			block.history_geometry_tex = self:GetTextureIndex(attachment("radiance_temporal", previous, 4))
			block.history_geometric_normal_tex = self:GetTextureIndex(attachment("radiance_temporal", previous, 6))
			block.history_receiver_tex = self:GetTextureIndex(attachment("radiance_spatial", 1, 5))
			-- last frame's raw estimate, read before the spatial pass rewrites it: feeding back the denoised output makes every bounce wait on its history
			block.screen_gi_tex = block.history_valid == 1 and
				self:GetTextureIndex(attachment("radiance_spatial", 1, 1)) or
				-1
			block.screen_geometry_tex = self:GetTextureIndex(attachment("radiance_temporal", previous, 4))
			block.candidate_a_tex = self:GetTextureIndex(attachment("radiance_candidates", 1, 1))
			block.candidate_b_tex = self:GetTextureIndex(attachment("radiance_candidates", 1, 2))
			block.candidate_c_tex = self:GetTextureIndex(attachment("radiance_candidates", 1, 3))
			block.raw_tex = self:GetTextureIndex(attachment("radiance_spatial", 1, 1))
			block.raw_effective_tex = self:GetTextureIndex(attachment("radiance_spatial", 1, 6))
			block.accum_tex = self:GetTextureIndex(attachment("radiance_accumulate", current, 1))
			block.accum_moments_tex = self:GetTextureIndex(attachment("radiance_accumulate", current, 2))
			block.accum_history_tex = self:GetTextureIndex(attachment("radiance_accumulate", previous, 1))
			block.accum_history_moments_tex = self:GetTextureIndex(attachment("radiance_accumulate", previous, 2))
			block.accum_history_irradiance_tex = self:GetTextureIndex(attachment("radiance_accumulate", previous, 3))
			block.raw_specular_tex = self:GetTextureIndex(attachment("radiance_spatial", 1, 7))
			block.candidate_specular_tex = self:GetTextureIndex(attachment("radiance_candidates", 1, 4))
			block.specular_reuse = radiance.specular_reuse:Get() and 1 or 0
			block.accum_history_specular_tex = self:GetTextureIndex(attachment("radiance_accumulate", previous, 4))
			block.accum_tracking_tex = self:GetTextureIndex(attachment("radiance_accumulate", current, 5))
			block.accum_history_tracking_tex = self:GetTextureIndex(attachment("radiance_accumulate", previous, 5))
			block.candidate_hit_tex = self:GetTextureIndex(attachment("radiance_candidates", 1, 5))
			block.specular_tracking = radiance.specular_tracking:Get() and 1 or 0
			block.specular_emitter_roughness = radiance.specular_emitter_roughness:Get()
			block.brdf_lut_tex = self:GetTextureIndex(
				assert(
					assets.GetTexture("textures/render/brdf_lut.lua"),
					"the brdf lut texture is not registered"
				)
			)

			if filter_iteration then
				block.filter_step = 2 ^ filter_iteration
				block.filter_source_tex = self:GetTextureIndex(
					filter_iteration == 0 and
						attachment("radiance_accumulate", current, 1) or
						attachment(filter_name(filter_iteration - 1), 1, 1)
				)
				block.filter_specular_source_tex = self:GetTextureIndex(
					filter_iteration == 0 and
						attachment("radiance_accumulate", current, 4) or
						attachment(filter_name(filter_iteration - 1), 1, 3)
				)
			end

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
	// the ray was drawn from a mix with the probe guide: only cosine rays count toward the sky visibility, scaled by their share
	#define RESTIR_FLAG_GUIDE_MIX 32
	#define RESTIR_FLAG_LIGHT_CHANGED 64
	#define RESTIR_CHANGED_HISTORY 4.0
	#define RESTIR_SKY_DEPTH 65504.0

	struct restir_sample {
		vec3 x;
		vec3 n;
		vec3 L;
		int kind;
		vec3 id;
	};

	// an emitter sample is kept as its triangle (instance, primitive, packed barycentrics and side) and placed on it each time it is read, so a sample on a moving light moves with it instead of lighting the spot the light left
	vec3 restir_stored_x(restir_sample s) {
		return s.kind == RESTIR_EMITTER ? s.id : s.x;
	}

	// an emitter sample's contribution weight crosses frames per area of the emitter, which a moving emitter keeps, and is turned into solid angle at its receiver from where the emitter is now: kept per solid angle, a sample whose emitter moved closer keeps its old weight under a larger target and flares
	float restir_emitter_area_factor(restir_sample s, vec3 receiver) {
		vec3 to_receiver = receiver - s.x;
		float d2 = dot(to_receiver, to_receiver);
		return abs(dot(s.n, to_receiver)) * inversesqrt(max(d2, 1e-12)) / max(d2, 1e-12);
	}

	vec3 restir_emitter_id(uint instance, uint primitive, vec2 uv, bool flipped) {
		uvec2 q = uvec2(clamp(uv, 0.0, 1.0) * 2047.0 + 0.5);
		return vec3(float(instance), float(primitive), float(q.x | (q.y << 11u) | (flipped ? 1u << 22u : 0u)));
	}

	// below full resolution a gi pixel takes the screen pixel whose jittered sample lands nearest its centre: any other pick (rotating, or the nearest surface) shows another surface every frame under the taa jitter at edges and on thin things, never keeps its history and flickers
	ivec2 restir_gbuffer_pos(ivec2 pos, ivec2 size, ivec2 gsize) {
		ivec2 first = reflection_floor_div(pos * gsize, size);
		ivec2 span = max(reflection_floor_div((pos + 1) * gsize, size) - first, ivec2(1));

		if (span == ivec2(1)) return min(first, gsize - 1);

		vec2 target = (vec2(pos) + 0.5) * vec2(gsize) / vec2(size);
		return clamp(ivec2(floor(target + restir_data.jitter)), first, min(first + span, gsize) - 1);
	}

	vec3 restir_geometric_normal(ivec2 gpos, vec3 P) {
		vec3 G = normalize(gbuffer_geometric_normal(gpos));
		return dot(G, restir_data.camera_position - P) < 0.0 ? -G : G;
	}

	bool restir_surface(ivec2 pos, ivec2 size, out ivec2 gpos, out vec3 P, out vec3 N, out float view_depth, out float depth) {
		ivec2 gsize = textureSize(TEXTURE(restir_data.depth_tex), 0);
		gpos = restir_gbuffer_pos(pos, size, gsize);
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

	#ifdef SCENE_HITS
	]] .. scene_hit.GetEscapeGLSL("scene_tlas") .. [[
	#endif
	]] .. scene_hit.GetEscapeStubGLSL() .. [[

	// a pixel at a crease reconstructs a hair behind one of its two planes, lift it off every neighbouring pixel's plane it lies on
	vec3 restir_ray_origin(ivec2 gpos, vec3 P, vec3 N, float view_depth, float depth) {
		vec3 V = normalize(restir_data.camera_position - P);
		float offset = 0.01 * restir_data.view_scale + 0.001 * view_depth;
		vec3 pull = get_geometric_normal(gpos, P, depth, V);
		ivec2 gsize = textureSize(TEXTURE(restir_data.depth_tex), 0);

		for (int i = 0; i < 4; i++) {
			ivec2 q = clamp(gpos + ivec2(i == 0 ? 1 : i == 1 ? -1 : 0, i == 2 ? 1 : i == 3 ? -1 : 0), ivec2(0), gsize - 1);
			float q_depth = gbuffer_depth(q);

			if (q_depth <= 0.0) continue;

			vec3 q_N = normalize(gbuffer_normal(q));

			if (dot(q_N, pull) < 0.99 && abs(dot(P - get_world_pos((vec2(q) + 0.5) / vec2(gsize), q_depth), q_N)) < offset) pull += q_N;
		}

		pull = normalize(pull);
		return scene_escape_tessellation(P + pull * offset, pull, 0.1 * restir_data.view_scale);
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

		return restir_sample(a.xyz, c.xyz, max(b.rgb, vec3(0.0)), flags & 3, a.xyz);
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
		return float(pcg3d(uvec3(uvec2(pos), (uint(restir_data.frame) << 8u) + stream)).x >> 8u) / 16777216.0;
	}

	// last frame's view space ray through an image position, scaled to a view depth of one
	vec3 restir_previous_view_ray(vec2 uv) {
		vec2 ndc = uv * 2.0 - 1.0;
		return vec3((ndc.x + restir_data.prev_projection[2][0]) / restir_data.prev_projection[0][0], (ndc.y + restir_data.prev_projection[2][1]) / restir_data.prev_projection[1][1], -1.0);
	}

	// how far a history texel lies off the pixel's plane (last frame's view space normal and offset): a surface seen at a grazing angle changes its depth by far more than the tolerance between the jittered or rotated points a texel stands for, but stays on its plane
	float restir_history_plane_distance(ivec2 q, ivec2 size, vec4 plane, out vec4 g) {
		g = texelFetch(TEXTURE(restir_data.history_geometry_tex), q, 0);
		return abs(dot(plane.xyz, restir_previous_view_ray((vec2(q) + 0.5) / vec2(size) - restir_data.jitter_shift) * g.w) - plane.w);
	}

	// G is the geometric normal: a normal map makes neighbouring pixels of one surface look like different ones
	bool restir_history_matches(ivec2 q, ivec2 size, vec3 G, vec4 plane, float tolerance) {
		if (any(lessThan(q, ivec2(0))) || any(greaterThanEqual(q, size))) return false;

		vec4 g;
		float distance = restir_history_plane_distance(q, size, plane, g);
		vec3 history_G = texelFetch(TEXTURE(restir_data.history_geometric_normal_tex), q, 0).xyz;
		return dot(history_G, history_G) > 0.25 && distance <= tolerance && dot(history_G, G) >= 0.8;
	}

	vec4 restir_history_plane(vec3 N, vec3 previous_point) {
		vec3 normal = mat3(restir_data.prev_view) * N;
		return vec4(normal, dot(normal, previous_point));
	}

	// the plane distance a texel may be off by: the point it stands for is known to about a texel, plus a share of the depth
	float restir_history_tolerance(float prev_depth, ivec2 size) {
		return prev_depth * (0.01 + 4.0 * abs(restir_data.inv_projection[1][1]) / float(size.y)) + 0.01;
	}

	// the gi pixel's centre is reprojected, not the screen pixel it samples this frame, or a still view resamples its history bilinearly every frame and smears it
	bool restir_history_taps(ivec2 pos, ivec2 gpos, vec3 P, vec3 G, ivec2 size, out ivec2 base, out vec4 weights, out vec4 plane, out float tolerance, out float moved, out vec2 position) {
		weights = vec4(0.0);
		base = ivec2(0);
		plane = vec4(0.0);
		tolerance = 0.0;
		moved = 0.0;
		position = vec2(-1.0);

		if (restir_data.history_valid == 0) return false;

		ivec2 gsize = textureSize(TEXTURE(restir_data.depth_tex), 0);
		vec2 uv = (vec2(gpos) + 0.5) / vec2(gsize);
		vec2 prev_uv;
		float prev_depth;

		if (restir_data.velocity_tex != -1) {
			vec3 motion = texture(TEXTURE(restir_data.velocity_tex), uv).rgb;
			prev_uv = uv - motion.xy;
			prev_depth = motion.z;
		} else {
			vec4 prev_view_pos = restir_data.prev_view * vec4(P, 1.0);
			vec4 prev_clip = restir_data.prev_projection * prev_view_pos;

			if (prev_clip.w <= 1e-5) return false;

			prev_uv = prev_clip.xy / prev_clip.w * 0.5 + 0.5;
			prev_depth = -prev_view_pos.z;
		}

		if (prev_depth <= 1e-5) return false;

		plane = restir_history_plane(G, restir_previous_view_ray(prev_uv) * prev_depth);
		prev_uv += restir_data.jitter_shift + (vec2(pos) + 0.5) / vec2(size) - uv;

		if (any(lessThan(prev_uv, vec2(0.0))) || any(greaterThan(prev_uv, vec2(1.0)))) return false;

		position = prev_uv * vec2(size) - 0.5;
		moved = length(position - vec2(pos));
		base = ivec2(floor(position));
		vec2 f = position - vec2(base);
		tolerance = restir_history_tolerance(prev_depth, size);

		for (int i = 0; i < 4; i++) {
			if (!restir_history_matches(base + ivec2(i & 1, i >> 1), size, G, plane, tolerance)) continue;

			weights[i] = ((i & 1) == 1 ? f.x : 1.0 - f.x) * ((i >> 1) == 1 ? f.y : 1.0 - f.y) + 1e-4;
		}

		return dot(weights, vec4(1.0)) > 0.0;
	}

	// a thin thing (a fence, a leaf) under the jitter: the 4 texels around last frame's position hold what is behind it half the time, the nearest ring around them with a texel that holds this surface carries its history
	bool restir_history_search(vec2 position, ivec2 size, vec3 G, vec4 plane, float tolerance, out ivec2 found) {
		found = ivec2(-1);

		if (restir_data.temporal_search == 0 || position.x <= -1.0) return false;

		ivec2 nearest = ivec2(floor(position + 0.5));

		for (int ring = 1; ring <= 2; ring++) {
			float best = 1e30;

			for (int y = -ring; y <= ring; y++) {
				for (int x = -ring; x <= ring; x++) {
					if (max(abs(x), abs(y)) != ring && ring > 1) continue;

					ivec2 q = nearest + ivec2(x, y);

					if (!restir_history_matches(q, size, G, plane, tolerance)) continue;

					vec4 g;
					float error = restir_history_plane_distance(q, size, plane, g);

					if (error < best) {
						best = error;
						found = q;
					}
				}
			}

			if (found.x >= 0) return true;
		}

		return false;
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

	// a hit this close to the ray's origin (the other wall at a crease) reads the accumulated estimate, not the raw one: the screen there holds light partly from the receiver itself, and with reservoirs keeping the samples whose noisy read came out high, the raw loop between two walls glows along every crease
	bool scene_hit_screen_gi(vec3 P, vec3 N, float t, out vec3 irradiance) {
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

		irradiance = texelFetch(TEXTURE(t < 0.05 * view_depth ? restir_data.accum_history_irradiance_tex : restir_data.screen_gi_tex), texel, 0).rgb;
		return !any(isnan(irradiance));
	}
]]
local RESOLVE_GLSL = [[
	// a light that moved, turned or changed in the last second, that the receiver sees (one ray toward the sphere around its recent path) and that gives it more than a tenth of its last denoised gi: its history is cut there, or the old light trails behind. the test must not read this frame's or a reservoir's noisy estimate, cutting the dark ones and keeping the bright ones brightens everything
	bool restir_light_changed(vec3 origin, float gi_luminance) {
		for (int i = 0; i < restir_data.changed_light_count; i++) {
			vec4 sphere = restir_data.changed_lights[i];
			vec3 to_light = sphere.xyz - origin;
			float dist = length(to_light);
			float d = max(dist - sphere.w, 0.05 * restir_data.view_scale);

			if (restir_data.changed_light_intensities[i].x / (RESTIR_PI * d * d) <= 0.1 * gi_luminance) continue;

			if (dist <= sphere.w || scene_hit_visible(origin, to_light / dist, dist - sphere.w)) return true;
		}

		return false;
	}

	// aimed at the sample's point lifted off its own surface
	bool restir_sample_visible(vec3 origin, restir_sample s) {
		vec3 to_sample = s.kind == RESTIR_SKY ? s.x * SCENE_HIT_MAX_DISTANCE : s.x + s.n * 0.01 * restir_data.view_scale - origin;
		float ray_length = length(to_sample);
		return scene_hit_visible(origin, to_sample / ray_length, s.kind == RESTIR_SKY ? ray_length : max(ray_length - 0.03 * restir_data.view_scale, 0.0));
	}

	restir_sample restir_resolve(restir_sample s) {
		if (s.kind != RESTIR_EMITTER) return s;

		uint packed = uint(s.id.z);
		vec2 uv = vec2(float(packed & 2047u), float((packed >> 11u) & 2047u)) / 2047.0;
		scene_triangle tri = scene_hit_tri(uint(s.id.x), uint(s.id.y));
		s.x = tri.v0 + tri.e1 * uv.x + tri.e2 * uv.y;
		s.n = (packed & (1u << 22u)) != 0u ? tri.normal : -tri.normal;
		return s;
	}
]]
local TRACE_GLSL = "#define SCENE_HIT_GI_SHARE restir_hit_gi_share\n#define SCENE_HIT_SKY_RAYS 1\nbool radiance_hit_emission = true;\n#define SCENE_HIT_EMISSION radiance_hit_emission\n" .. NO_DECALS_GLSL .. glsl_common.GetConstantsGLSL() .. render3d.GetEmissiveGLSL() .. glsl_common.GetBlueNoiseGLSL() .. SURFACE_GLSL .. SCREEN_GI_GLSL .. HIT_GI_SHARE_GLSL .. ibl.GetEnvironmentGLSLCode() .. post_source.GetPreExposureGLSL("restir_data") .. atmosphere.GetGLSLDefines("restir_data", "restir_data.primary_sun_illuminance") .. atmosphere.GetAerialPerspectiveGLSLCode() .. scene_hits.GetGLSL("restir_data") .. [[
			vec3 restir_cosine_direction(vec3 N, vec2 xi) {
				vec3 up = abs(N.y) < 0.999 ? vec3(0.0, 1.0, 0.0) : vec3(1.0, 0.0, 0.0);
				vec3 T = normalize(cross(up, N));
				vec3 B = cross(N, T);
				float phi = 6.28318530718 * xi.x;
				float r = sqrt(xi.y);
				return normalize(T * (r * cos(phi)) + B * (r * sin(phi)) + N * sqrt(max(1.0 - xi.y, 0.0)));
			}

			// rays leave emission to the emitter samples, so an emitter sample holds only emission and a ray hit only reflected light
			restir_sample restir_hit_sample(vec3 origin, vec3 dir, bool hit, float t, uint instance, uint primitive, vec2 barycentrics, bool emitter, vec3 shaded) {
				restir_sample s;

				if (!hit) {
					s = restir_sample(dir, vec3(0.0), radiance_cache_sky(dir), RESTIR_SKY, vec3(0.0));
					t = SCENE_HIT_MAX_DISTANCE;
				} else {
					scene_triangle tri = scene_hit_tri(instance, primitive);
					vec3 hit_N = -tri.normal;

					if (dot(hit_N, dir) > 0.0) hit_N = -hit_N;

					vec3 P = origin + dir * t;
					s = emitter ?
						restir_sample(P, hit_N, ray_hit_emission(tri, ray_material_albedo(ray_materials[tri.material], P), P, instance, primitive), RESTIR_EMITTER, restir_emitter_id(instance, primitive, barycentrics, dot(hit_N, tri.normal) > 0.0)) :
						restir_sample(P, hit_N, shaded, RESTIR_SURFACE, vec3(0.0));
				}

				if (restir_data.optical_tint != 0) {
					s.L *= get_optical_tint(origin, dir, t, hit);

					if (hit) s.L += optical_inscatter_lit(origin, dir, t, radiance_cache_fog_ambient(), radiance_cache_data.radiance_cache_sun_radiance.rgb, normalize(radiance_cache_data.radiance_cache_sun_direction.xyz), true);
				}

				s.L = min(max(s.L, vec3(0.0)), vec3(1e9));
				return s;
			}

			restir_sample restir_trace(vec3 origin, vec3 dir, bool emitter, out bool miss) {
				float t;
				uint instance;
				uint primitive;
				vec2 barycentrics;
				miss = !trace_scene_hit(origin, dir, 0.0, SCENE_HIT_MAX_DISTANCE, t, instance, primitive, barycentrics);
				return restir_hit_sample(origin, dir, !miss, t, instance, primitive, barycentrics, emitter, miss || emitter ? vec3(0.0) : shade_scene_hit(origin, dir, 1.0, t, instance, primitive, barycentrics));
			}
]] .. RESOLVE_GLSL
-- the specular lobe a pixel reflects with, shared by its ray (the candidates) and the reservoirs that stand in for the ray on rough surfaces (the spatial pass)
local SPECULAR_LOBE_GLSL = scene_hits.CONSTANTS_GLSL .. surface_weather.GetRainSurfaceGLSL("restir_data") .. ibl.GetBRDFGLSLCode() .. [[
	// the specular lobe: one ray a pixel, over the visible normals of the pixel's surface (a mirror's own direction when it is smooth enough), shaded like every other ray hit. the accumulation and the filter average it over frames and pixels by the lobe
	float radiance_specular_roughness(ivec2 gbuffer_pos, vec3 world_pos, float footprint, inout vec3 N) {
		float roughness = sqrt(gbuffer_roughness(gbuffer_pos));
		]] .. surface_features.GetReflectionGLSL() .. [[

		return roughness;
	}

	// the roughness and normal after the surface features that change the lobe (clearcoat, rain), the normal bent toward the view
	float radiance_specular_lobe_setup(ivec2 gpos, vec3 P, vec3 V, vec3 geometric_N, float view_depth, inout vec3 N) {
		float footprint = view_depth / sqrt(max(abs(dot(geometric_N, V)), 0.01)) * 2.0 * restir_data.inv_projection[1][1] / float(textureSize(TEXTURE(restir_data.depth_tex), 0).y);
		float roughness = radiance_specular_roughness(gpos, P, footprint, N);
		N = bend_normal_to_view(N, V);
		return roughness;
	}

	// the rays follow the visible normals and the lobe also masks the light along each: the weight of that (the lobe over the density the rays are drawn at), which the sum of the weighted rays divides by their weights in the accumulation, so the average is the light over the lobe and not over the density
	float radiance_specular_weight(vec3 N, vec3 V, float roughness, vec3 L) {
		float a2 = max(roughness * roughness, 0.001);
		a2 *= a2;
		float NoV = max(dot(N, V), 1e-4);
		float NoL = max(dot(N, L), 1e-4);
		float lambda_v = 0.5 * (sqrt(1.0 + a2 * (1.0 - NoV * NoV) / (NoV * NoV)) - 1.0);
		float lambda_l = 0.5 * (sqrt(1.0 + a2 * (1.0 - NoL * NoL) / (NoL * NoL)) - 1.0);
		return (1.0 + lambda_v) / (1.0 + lambda_v + lambda_l);
	}

	// the luminance the ray's hits are clamped to against fireflies, in absolute units
	float radiance_specular_hit_limit() {
		return restir_data.pre_exposure_tex != -1 ? REFLECTION_MAX_HIT_LUMINANCE / max(get_exposure(), 1e-8) : 1e30;
	}

	// whether this pixel's ray leaves emissive hits to an emitter sample this frame instead of reading their emission
	bool radiance_specular_samples_emitters(ivec2 pos, float roughness) {
		return radiance_cache_data.radiance_cache_emitter_count > 0 && roughness >= max(restir_data.specular_emitter_roughness, REFLECTION_MIRROR_THRESHOLD * 3.0) && restir_random(pos, 52u) < 1.0 - smoothstep(0.35, 0.6, roughness);
	}

	// the part of a reservoir sample's light the ray's clamp would have cut off its hit: sky is never clamped, and emission is not when the ray leaves it to its emitter sample
	vec3 radiance_specular_clipped(restir_sample s, float limit, bool emission_sampled) {
		if (s.kind == RESTIR_SKY || (s.kind == RESTIR_EMITTER && emission_sampled)) return vec3(0.0);

		float l = luminance(s.L);
		return l > limit ? s.L * (1.0 - limit / l) : vec3(0.0);
	}

	// what a weighted ray averages to per solid angle of light: the visible normal density of the reflected direction times its masking weight, D G2 / (4 NoV)
	float radiance_specular_lobe(vec3 N, vec3 V, float roughness, vec3 L) {
		if (dot(N, L) <= 0.0) return 0.0;

		float alpha = max(0.001, roughness * roughness);
		float NoV = max(dot(N, V), 1e-4);
		float G1 = 2.0 * NoV / (NoV + sqrt(alpha * alpha + (1.0 - alpha * alpha) * NoV * NoV));
		return G1 * D_GGXAlpha(alpha, max(dot(N, normalize(V + L)), 0.0)) / (4.0 * NoV) * radiance_specular_weight(N, V, roughness, L);
	}
]]

-- traces this frame's new candidates for the pixels whose turn it is, one thread per tracing pixel so no warp traces a few rays at the cost of a full one
local function pass_candidates()
	return {
		name = "radiance_candidates",
		ComputePass = true,
		ColorFormat = {
			{"r32g32b32a32_sfloat", {"restir_candidate_position", "rgb", 0.01}},
			{
				"r32g32b32a32_sfloat",
				{"restir_candidate_radiance", "rgb", 1 / post_source.UNEXPOSED_SDR_WHITE},
			},
			{"r16g16b16a16_sfloat", {"restir_candidate_normal", "rgb"}},
			{
				"r32g32b32a32_sfloat",
				{"restir_candidate_specular", "rgba", 1 / post_source.UNEXPOSED_SDR_WHITE},
			},
			{"r32_sfloat", {"restir_candidate_specular_distance", "r"}},
		},
		framebuffer_count = 1,
		scale = radiance.GetScale,
		LocalSize = LOCAL_SIZE,
		storage_images = storage_images(5),
		descriptor_sets = scene_hits.GetDescriptorSets(SCENE_BINDINGS, "compute"),
		storage_buffers = {{binding_index = BINDING_EMITTERS}},
		uniform_buffers = {restir_uniform(true), scene_hits.GetRadianceCacheUniformBuffer(BINDING_GI)},
		on_pre_draw = function(self, cmd, frame, desc)
			scene_hits.Bind(self, cmd, desc, SCENE_BINDINGS)
			local emitters = scene_emitters.BuildActive(cmd)
			self:UpdateDescriptorSet("storage_buffer", desc, BINDING_EMITTERS, 0, emitters, emitters:GetSize())
		end,
		on_draw = function(self, cmd, fb, frame, desc)
			local share = radiance.GetRayShare()
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
			layout(set = 0, binding = 3, rgba32f) uniform writeonly image2D out_d;
			layout(set = 0, binding = 4, r32f) uniform writeonly image2D out_e;
		]] .. scene_hits.GetDeclarationGLSL(SCENE_BINDINGS) .. scene_emitters.GetDeclarationGLSL(BINDING_EMITTERS),
		-- temporal and spatial reuse stand in for more candidates: one by each of the emitter tree's weighings
		shader = "#extension GL_EXT_control_flow_attributes : require\n" .. TRACE_GLSL .. "#define EMITTER_CANDIDATES 2\n" .. scene_emitters.GetGLSL() .. scene_emitters.GetLightGLSL() .. SPECULAR_LOBE_GLSL .. scene_hits.GetDirectionGLSL() .. [[
			// the rays are averaged unweighted over the visible normal distribution, so an emitter sample must enter at that density of its direction
			// the diffuse emitter sample's candidates, picked for its origin and normal: the light of each divides out that normal's cosine, so it is evaluated there and only the lobe uses the bent normal
			vec3 radiance_specular_emitter_light(vec3 origin, vec3 receiver_N, vec3 N, vec3 geometric_N, vec3 V, float roughness, uint index, int triangles[EMITTER_CANDIDATES], float weights[EMITTER_CANDIDATES]) {
				float alpha = roughness * roughness;
				float NoV = max(dot(N, V), 1e-4);
				float a = max(0.001, alpha);
				float G1 = 2.0 * NoV / (NoV + sqrt(a * a + (1.0 - a * a) * NoV * NoV));
				uint frame = uint(restir_data.frame);
				vec3 chosen = vec3(0.0);
				vec3 chosen_dir = vec3(0.0);
				float chosen_dist = 0.0;
				float chosen_target = 0.0;
				float total = 0.0;
				

				for (int k = 0; k < EMITTER_CANDIDATES; k++) {
					if (!(weights[k] > 0.0)) continue;

					int emitter = int(uint(triangles[k]) | (uint(k) << 26u));
					vec3 dir;
					float dist;
					vec3 light = emitter_light(emitter, emitter_candidate_point(index, frame, emitter), origin, receiver_N, weights[k], dir, dist);

					if (dot(geometric_N, dir) <= 0.0) continue;

					vec3 value = light * G1 * D_GGXAlpha(a, max(dot(N, normalize(V + dir)), 0.0)) / (4.0 * NoV);
					float target = luminance(value);

					if (!(target > 0.0) || isinf(target)) continue;

					total += target;

					if (emitter_random(index, frame, 0x68e31da4u + uint(k)).w * total < target) {
						chosen = value;
						chosen_dir = dir;
						chosen_dist = dist;
						chosen_target = target;
					}
				}

				if (!(total > 0.0) || chosen_dist <= 0.02 * restir_data.view_scale || !scene_hit_visible(origin, chosen_dir, chosen_dist - 0.02 * restir_data.view_scale)) return vec3(0.0);

				if (restir_data.light_transmittance != 0) chosen *= get_light_transmittance_local(origin, chosen_dir, chosen_dist, 0.0);

								return chosen * (total / float(EMITTER_CANDIDATES)) / chosen_target * radiance_specular_weight(N, V, roughness, chosen_dir);
			}

			struct radiance_specular_ray {
				vec3 V;
				vec3 N;
				vec3 geometric_N;
				vec3 R;
				vec3 origin;
				float roughness;
				float environment_roughness;
				bool lobe_below;
				bool sample_emitters;
			};

			radiance_specular_ray radiance_specular_setup(ivec2 pos, ivec2 gpos, vec3 P, vec3 N, float view_depth, float depth) {
				radiance_specular_ray ray;
				ray.V = normalize(restir_data.camera_position - P);
				ray.geometric_N = get_geometric_normal(gpos, P, depth, ray.V);
				ray.N = N;
				ray.roughness = radiance_specular_lobe_setup(gpos, P, ray.V, ray.geometric_N, view_depth, ray.N);
				ray.R = reflection_direction(ray.N, ray.V, ray.roughness, vec2(restir_random(pos, 50u), restir_random(pos, 51u)), ray.environment_roughness);
				ray.lobe_below = dot(ray.N, ray.R) <= 0.0;
				ray.R = reflection_above(ray.geometric_N, reflection_above(ray.N, ray.R, 0.001), 0.01);
				// an emitter sample reads low across a broad lobe (half of the light a furnace gives a rough metal at roughness 1), where the rays find the large emitters well: a pixel chooses one estimator of the two, so the mean holds
				ray.sample_emitters = radiance_specular_samples_emitters(pos, ray.roughness);
				ray.origin = scene_escape_tessellation(P + ray.geometric_N * (0.0002 + 0.0001 * view_depth), ray.geometric_N, 0.1 * restir_data.view_scale);
				return ray;
			}

			vec4 radiance_specular_finish(radiance_specular_ray ray, vec3 radiance, float hit_t, int index, vec3 emitter_origin, vec3 emitter_N, int triangles[EMITTER_CANDIDATES], float weights[EMITTER_CANDIDATES]) {
				radiance = scene_radiance_through_air(radiance, ray.origin, ray.R, hit_t, SCENE_HIT_MAX_DISTANCE);

				if (ray.roughness > REFLECTION_MIRROR_THRESHOLD && hit_t < SCENE_HIT_MAX_DISTANCE) {
					radiance = reflection_limit_hit(radiance, radiance_specular_hit_limit());
				}

				float ray_weight = mix(1.0, ray.lobe_below ? 0.0 : radiance_specular_weight(ray.N, ray.V, ray.roughness, ray.R), smoothstep(REFLECTION_MIRROR_THRESHOLD, REFLECTION_MIRROR_THRESHOLD * 3.0, ray.roughness));
				radiance *= ray_weight;

				if (ray.sample_emitters) radiance += radiance_specular_emitter_light(emitter_origin, emitter_N, ray.N, ray.geometric_N, ray.V, ray.roughness, uint(index), triangles, weights);

				if (any(isnan(radiance)) || any(isinf(radiance))) {
					radiance = vec3(0.0);
					ray_weight = 0.0;
				}

				return vec4(radiance, ray_weight);
			}

			void main() {
				radiance_hit_emission = radiance_cache_data.radiance_cache_emitter_count == 0;
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

				if (!restir_surface(pos, size, gpos, P, N, view_depth, depth) || !scene_hits_ready()) {
					imageStore(out_a, pos, vec4(0.0));
					imageStore(out_b, pos, vec4(0.0));
					imageStore(out_c, pos, vec4(0.0));
					imageStore(out_d, pos, vec4(0.0));
					imageStore(out_e, pos, vec4(0.0));
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
					int emitter_count = radiance_cache_data.radiance_cache_emitter_count;

					float guided_share = 0.0;
						bool guided = false;
						radiance_specular_ray specular;
						int emitter_triangles[EMITTER_CANDIDATES];
						float emitter_weights[EMITTER_CANDIDATES];
						bool have_emitters = emitter_count > 0 && emitter_candidates(uint(pos.y * size.x + pos.x), frame, origin, N, 0.05, emitter_triangles, emitter_weights);
						vec3 specular_L = vec3(0.0);
						float specular_t = SCENE_HIT_MAX_DISTANCE;

					{
						vec2 xi = vec2(0.5);
						// the noise tile repeats every 64 pixels: each tile copy takes its own random shift per frame, or pixels a tile apart take the same ray every frame and their shared error never averages out
						if (restir_data.blue_noise_tex >= 0) {
							uvec3 tile_hash = pcg3d(uvec3(uvec2(pos / textureSize(TEXTURE(restir_data.blue_noise_tex), 0)), frame));
							xi = fract(blue_noise_texel(TEXTURE(restir_data.blue_noise_tex), pos).rg + vec2(pcg_unorm(tile_hash.x), pcg_unorm(tile_hash.y)));
						}
						vec3 dir = restir_cosine_direction(N, xi);
						ivec2 guide_tile = ivec2(0);

						if (restir_data.guided > 0.0 && radiance_cache_data.radiance_cache_cascade_count > 0 && radiance_cache_data.radiance_cache_guide_tex >= 0 && radiance_cache_data.radiance_cache_uniform_rays < RADIANCE_CACHE_RAYS) {
							for (int c = 0; c < radiance_cache_data.radiance_cache_cascade_count; c++) {
								float spacing = radiance_cache_spacing(c);
								vec3 grid = (P + N * (0.5 * spacing)) / spacing - vec3(radiance_cache_volume_base(c));

								if (any(lessThan(grid, vec3(0.0))) || any(greaterThan(grid, vec3(radiance_cache_volume_size(c) - 1)))) continue;

								ivec3 world = radiance_cache_volume_base(c) + ivec3(floor(grid + 0.5));
								guide_tile = radiance_cache_tile(radiance_cache_slot(world, c), c);

								if (radiance_cache_guide_valid(guide_tile, world, c)) guided_share = restir_data.guided;

								break;
							}
						}

						guided = guided_share > 0.0 && restir_random(pos, 40u) < guided_share;

						if (guided) {
							dir = radiance_cache_guide_sample(restir_random(pos, 41u), vec2(restir_random(pos, 42u), restir_random(pos, 43u)), restir_random(pos, 44u), guide_tile);
						} else {
							float below = dot(dir, geometric_N);

							if (below < 0.01) dir = normalize(dir + geometric_N * (0.01 - 2.0 * below));
						}

						float ray_cosine = dot(N, dir);

						bool diffuse_ray = ray_cosine > 0.0 && dot(dir, geometric_N) > 0.0;
							specular = radiance_specular_setup(pos, gpos, P, N, view_depth, depth);
							vec3 diffuse_L = vec3(0.0);
							bool diffuse_hit = false;
							float diffuse_t = SCENE_HIT_MAX_DISTANCE;
							uint diffuse_instance = 0u;
							uint diffuse_primitive = 0u;
							vec2 diffuse_barycentrics = vec2(0.0);

							// both rays go through one call of the hit shading: unrolled, the shader carried it twice and stalled on instruction fetch
							]] .. "[[dont_unroll]]" .. [[ for (int r = 0; r < 2; r++) {
								bool reflected = r == 1;

								if (!reflected && !diffuse_ray) continue;

								vec3 ray_origin = reflected ? specular.origin : origin;
								vec3 ray_dir = reflected ? specular.R : dir;
								radiance_hit_emission = reflected ? !specular.sample_emitters : emitter_count == 0;
								float t;
								uint instance;
								uint primitive;
								vec2 barycentrics;
								bool hit = trace_scene_hit(ray_origin, ray_dir, 0.0, SCENE_HIT_MAX_DISTANCE, t, instance, primitive, barycentrics);
								vec3 L = hit ? shade_scene_hit(ray_origin, ray_dir, reflected ? specular.environment_roughness : 1.0, t, instance, primitive, barycentrics) : vec3(0.0);

								if (reflected) {
									specular_L = hit ? L : sample_environment_specular_lod(restir_data.env_tex, ray_dir, specular.N, specular.environment_roughness, specular.roughness > REFLECTION_MIRROR_THRESHOLD ? 1.0 : 0.0);
									specular_t = hit ? t : SCENE_HIT_MAX_DISTANCE;
								} else {
									diffuse_L = L;
									diffuse_hit = hit;
									diffuse_t = t;
									diffuse_instance = instance;
									diffuse_primitive = primitive;
									diffuse_barycentrics = barycentrics;
								}
							}

							radiance_hit_emission = true;

							if (diffuse_ray) {
								ray_cosine = max(ray_cosine, 1e-4);
								float pdf = (1.0 - guided_share) * ray_cosine / RESTIR_PI + (guided_share > 0.0 ? guided_share * radiance_cache_guide_density(dir, guide_tile) : 0.0);
								miss = !diffuse_hit;
								chosen = restir_hit_sample(origin, dir, diffuse_hit, diffuse_t, diffuse_instance, diffuse_primitive, diffuse_barycentrics, false, diffuse_L);
								chosen_target = luminance(chosen.L) * ray_cosine;
								w_sum = chosen_target / pdf;
							} else {
								chosen = restir_sample(vec3(0.0), vec3(0.0), vec3(0.0), RESTIR_EMPTY, vec3(0.0));
							}

						miss = miss && !guided;
					}

					if (have_emitters) {
							float sum = 0.0;

							for (int k = 0; k < EMITTER_CANDIDATES; k++) {
								sum += emitter_weights[k];
							}

							float pick = emitter_random(uint(pos.y * size.x + pos.x), frame, 0x5bd1e995u).x * sum;
							int chosen_k = EMITTER_CANDIDATES - 1;
							float running = 0.0;

							for (int k = 0; k < EMITTER_CANDIDATES; k++) {
								running += emitter_weights[k];

								if (pick < running) {
									chosen_k = k;
									break;
								}
							}

							int emitter = int(uint(emitter_triangles[chosen_k]) | (uint(chosen_k) << 26u));
							float weight = sum > 0.0 ? sum / float(EMITTER_CANDIDATES) : 0.0;
							vec3 point = weight > 0.0 ? emitter_candidate_point(uint(pos.y * size.x + pos.x), frame, emitter) : origin;
						vec3 to_point = point - origin;
						float dist = length(to_point);
						vec3 L_dir = to_point / max(dist, 1e-6);
						float cosine = dot(N, L_dir);

						if (weight > 0.0 && cosine > 0.0 && dist > 0.02 * restir_data.view_scale && scene_hit_visible(origin, L_dir, dist - 0.02 * restir_data.view_scale)) {
							int e = int(uint(emitter) & 0x03FFFFFFu);
							scene_triangle tri = scene_hit_tri(emitter_instance(e), emitter_triangle(e) & ~EMITTER_DOUBLE_SIDED);
							ray_material material = ray_materials[tri.material];
							vec3 emitter_N = -tri.normal;

							if (dot(emitter_N, L_dir) > 0.0) emitter_N = -emitter_N;

							vec3 L = ray_hit_emission(tri, ray_material_albedo(material, point), point, emitter_instance(e), emitter_triangle(e) & ~EMITTER_DOUBLE_SIDED);

							if (restir_data.light_transmittance != 0) L *= get_light_transmittance_local(origin, L_dir, dist, 0.0);

							float target = luminance(L) * cosine;
							float w = target * weight / (max(emitter_luminance(e, tri), 1e-6) * max(cosine, 1e-3));

							if (w > 0.0 && !isinf(w)) {
								w_sum += w;

								if (restir_random(pos, 1u) * w_sum < w) {
									vec2 uv = emitter_random(uint(pos.y * size.x + pos.x), frame, uint(emitter) >> 26u).yz;

									if (uv.x + uv.y > 1.0) uv = 1.0 - uv;

									chosen = restir_sample(point, emitter_N, L, RESTIR_EMITTER, restir_emitter_id(emitter_instance(e), emitter_triangle(e) & ~EMITTER_DOUBLE_SIDED, uv, dot(emitter_N, tri.normal) > 0.0));
									chosen_target = target;
								}
							}
						}
					}

				imageStore(out_a, pos, vec4(restir_stored_x(chosen), w_sum));
				imageStore(out_b, pos, vec4(chosen.L, chosen_target));
				imageStore(out_c, pos, vec4(chosen.n, float(chosen.kind | (miss ? RESTIR_FLAG_MISS : 0) | (guided_share > 0.0 ? RESTIR_FLAG_GUIDE_MIX : 0))));
				imageStore(out_d, pos, radiance_specular_finish(specular, specular_L, specular_t, pos.y * size.x + pos.x, origin, N, emitter_triangles, emitter_weights));
				imageStore(out_e, pos, vec4(specular_t));
			}
		]],
	}
end

local function pass_temporal()
	return {
		name = "radiance_temporal",
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
			{"r16g16b16a16_sfloat", {"restir_geometric_normal", "rgb"}},
		},
		framebuffer_count = 2,
		scale = radiance.GetScale,
		LocalSize = LOCAL_SIZE,
		storage_images = storage_images(6),
		descriptor_sets = scene_hits.GetDescriptorSets(SCENE_BINDINGS, "compute"),
		uniform_buffers = {restir_uniform(true), scene_hits.GetRadianceCacheUniformBuffer(BINDING_GI)},
		on_pre_draw = function(self, cmd, frame, desc)
			scene_hits.Bind(self, cmd, desc, SCENE_BINDINGS)
		end,
		custom_declarations = [[
			layout(set = 0, binding = 0, rgba32f) uniform writeonly image2D out_a;
			layout(set = 0, binding = 1, rgba32f) uniform writeonly image2D out_b;
			layout(set = 0, binding = 2, rgba16f) uniform writeonly image2D out_c;
			layout(set = 0, binding = 3, rgba16f) uniform writeonly image2D out_geometry;
			layout(set = 0, binding = 4, rgba32f) uniform writeonly image2D out_receiver;
			layout(set = 0, binding = 5, rgba16f) uniform writeonly image2D out_geometric_normal;
		]] .. scene_hits.GetDeclarationGLSL(SCENE_BINDINGS),
		shader = TRACE_GLSL .. [[

			shared float restir_group_contribution[64];

			void main() {
				radiance_hit_emission = radiance_cache_data.radiance_cache_emitter_count == 0;
				ivec2 pos = get_screen_pos();
				ivec2 size = imageSize(out_a);
				restir_sample chosen = restir_sample(vec3(0.0), vec3(0.0), vec3(0.0), RESTIR_EMPTY, vec3(0.0));
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
				bool surface = is_screen_pos_in_bounds(pos, size) && restir_surface(pos, size, gpos, P, N, view_depth, depth) && scene_hits_ready();

				if (surface) {
					vec3 G = restir_geometric_normal(gpos, P);
					uint frame = uint(restir_data.frame);
					bool traces = restir_traces(pos);
					bool miss = false;
					float chosen_target = 0.0;
					float w_sum = 0.0;

					int candidate_flags = 0;

					if (traces) {
						vec4 candidate_a = texelFetch(TEXTURE(restir_data.candidate_a_tex), pos, 0);
						vec4 candidate_b = texelFetch(TEXTURE(restir_data.candidate_b_tex), pos, 0);
						vec4 candidate_c = texelFetch(TEXTURE(restir_data.candidate_c_tex), pos, 0);
						candidate_flags = int(candidate_c.w + 0.5);
						chosen = restir_resolve(restir_sample(candidate_a.xyz, candidate_c.xyz, candidate_b.rgb, candidate_flags & 3, candidate_a.xyz));
						w_sum = candidate_a.w;
						chosen_target = candidate_b.w;
						miss = (candidate_flags & RESTIR_FLAG_MISS) != 0;
					}

					// the candidates weighed their sample from the lifted ray origin, history and neighbours weigh from the surface point: mixing the two targets darkens creases, where near hit points look different from each
					if (traces) {
						vec3 fresh_dir;
						float fresh_dist;
						float target_here = luminance(chosen.L) * restir_receiver_cosine(chosen, P, N, fresh_dir, fresh_dist);
						w_sum = chosen_target > 0.0 ? w_sum * target_here / chosen_target : 0.0;
						chosen_target = target_here;
					}

					fresh = chosen;
					fresh_W = chosen_target > 0.0 ? w_sum / chosen_target : 0.0;
					// a pixel that traced nothing this frame enters the resampling with no confidence, its history keeps all the weight
					M = traces ? 1.0 : 0.0;
					flags = traces ? RESTIR_FLAG_TRACED | (miss ? RESTIR_FLAG_MISS : 0) | (candidate_flags & RESTIR_FLAG_GUIDE_MIX) : 0;
					bool light_changed = restir_data.changed_light_count > 0 && restir_light_changed(restir_ray_origin(gpos, P, N, view_depth, depth), luminance(texelFetch(TEXTURE(restir_data.accum_history_tex), pos, 0).rgb));

					if (light_changed) flags |= RESTIR_FLAG_LIGHT_CHANGED;
					ivec2 base;
					vec4 weights;

					vec4 plane;
					float tolerance;

					float moved;
					vec2 position;

					bool history = restir_data.temporal != 0 && restir_history_taps(pos, gpos, P, G, size, base, weights, plane, tolerance, moved, position);
					ivec2 q = ivec2(0);

					if (history) {
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

						q = base + ivec2(tap & 1, tap >> 1);
						// permutation sampling: the frame swaps reservoirs with a neighbour, so a lucky sample does not sit in one spot for its whole history
						ivec2 permuted = q ^ ivec2(int(frame) & 1, (int(frame) >> 1) & 1);

						// only with a new sample to weigh against: alone, a neighbour's hit point beside a crease enters with its full reconnection jacobian and sits there as a dot
						if (traces && restir_data.permutation != 0 && restir_history_matches(permuted, size, G, plane, tolerance)) q = permuted;
					} else if (restir_data.temporal != 0) {
						history = restir_history_search(position, size, G, plane, tolerance, q);
					}

					if (history) {
						float h_W;
						float h_M;
						int h_flags;
						restir_sample h = restir_resolve(restir_load(restir_data.history_a_tex, restir_data.history_b_tex, restir_data.history_c_tex, q, h_W, h_M, h_flags));
						// a sample carried along with the motion for its whole history draws a streak, so a moving pixel keeps a shorter one
						h_M = min(h_M, restir_data.max_history / (1.0 + moved));
						vec3 h_dir;
						float h_dist;
						float h_cosine = restir_receiver_cosine(h, P, N, h_dir, h_dist);
						vec3 h_receiver = texelFetch(TEXTURE(restir_data.history_receiver_tex), q, 0).xyz;

						if (h.kind == RESTIR_EMITTER) h_W *= restir_emitter_area_factor(h, h_receiver);
						vec3 h_normal = texelFetch(TEXTURE(restir_data.history_geometry_tex), q, 0).xyz;

						if (restir_data.validation != 0 && h.kind != RESTIR_EMPTY && h_M > 1.0 && ((pos.x + pos.y * 2 + int(frame)) & 3) == 0) {
							// retraced from where the sample was found: from this frame's screen pixel it often lands on another leaf or edge and the history is thrown away
							bool h_miss;
							vec3 h_origin = h_receiver + h_normal * (0.01 * restir_data.view_scale + 0.001 * view_depth);
							vec3 to_h = h.kind == RESTIR_SKY ? h.x : normalize(h.x - h_origin);
							restir_sample retraced = restir_trace(h_origin, to_h, h.kind == RESTIR_EMITTER, h_miss);
							bool moved = retraced.kind != h.kind || (restir_is_point(h.kind) && distance(retraced.x, h.x) > 0.05 * distance(h.x, h_origin) + 0.02);
							float ratio = max(luminance(retraced.L), luminance(h.L)) / max(min(luminance(retraced.L), luminance(h.L)), 1e-6);

							// the stored radiance is never replaced: reservoirs keep samples whose noisy shading came out high, and swapping in a fresh estimate under the same W darkens everything. the history is dropped when the hit is gone or its light clearly changed
							if (ratio > 4.0) flags |= RESTIR_FLAG_CHANGED;

							if (moved || ratio > 4.0) h_M = 0.0;
						}

						float h_target = luminance(h.L) * h_cosine;

						if (light_changed) h_M = min(h_M, 1.0);
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
					imageStore(out_geometric_normal, pos, vec4(0.0));
					return;
				}

				imageStore(out_a, pos, vec4(restir_stored_x(chosen), W));
				imageStore(out_b, pos, vec4(chosen.L, M));
				imageStore(out_c, pos, vec4(chosen.n, float(chosen.kind | flags)));
				imageStore(out_geometry, pos, vec4(N, view_depth));
				imageStore(out_receiver, pos, vec4(kept ? receiver : P, 0.0));
				imageStore(out_geometric_normal, pos, vec4(restir_geometric_normal(gpos, P), 0.0));
			}
		]],
	}
end

local function pass_spatial()
	return {
		name = "radiance_spatial",
		ComputePass = true,
		ColorFormat = {
			{
				"r32g32b32a32_sfloat",
				{"restir_raw", "rgb", 1 / post_source.UNEXPOSED_SDR_WHITE},
			},
			{"r32g32b32a32_sfloat", {"restir_spatial_position", "rgb", 0.01}},
			{
				"r32g32b32a32_sfloat",
				{"restir_spatial_radiance", "rgb", 1 / post_source.UNEXPOSED_SDR_WHITE},
			},
			{"r16g16b16a16_sfloat", {"restir_spatial_normal", "rgb"}},
			{"r32g32b32a32_sfloat", {"restir_spatial_receiver", "rgb", 0.01}},
			{
				"r32g32b32a32_sfloat",
				{"restir_raw_effective", "rgb", 1 / post_source.UNEXPOSED_SDR_WHITE},
			},
			{
				"r32g32b32a32_sfloat",
				{"restir_raw_specular", "rgba", 1 / post_source.UNEXPOSED_SDR_WHITE},
			},
		},
		framebuffer_count = 1,
		scale = radiance.GetScale,
		LocalSize = LOCAL_SIZE,
		storage_images = storage_images(7),
		descriptor_sets = scene_hits.GetDescriptorSets(SCENE_BINDINGS, "compute"),
		uniform_buffers = {restir_uniform(true), scene_hits.GetRadianceCacheUniformBuffer(BINDING_GI)},
		on_pre_draw = function(self, cmd, frame, desc)
			scene_hits.Bind(self, cmd, desc, SCENE_BINDINGS)
		end,
		custom_declarations = [[
			layout(set = 0, binding = 0, rgba32f) uniform writeonly image2D out_raw;
			layout(set = 0, binding = 1, rgba32f) uniform writeonly image2D out_a;
			layout(set = 0, binding = 2, rgba32f) uniform writeonly image2D out_b;
			layout(set = 0, binding = 3, rgba16f) uniform writeonly image2D out_c;
			layout(set = 0, binding = 4, rgba32f) uniform writeonly image2D out_receiver;
			layout(set = 0, binding = 5, rgba32f) uniform writeonly image2D out_effective;
			layout(set = 0, binding = 6, rgba32f) uniform writeonly image2D out_specular;
		]] .. scene_hits.GetDeclarationGLSL(SCENE_BINDINGS),
		shader = NO_DECALS_GLSL .. glsl_common.GetConstantsGLSL() .. render3d.GetEmissiveGLSL() .. SURFACE_GLSL .. ibl.GetEnvironmentGLSLCode() .. post_source.GetPreExposureGLSL("restir_data") .. atmosphere.GetGLSLDefines("restir_data", "restir_data.primary_sun_illuminance") .. atmosphere.GetAerialPerspectiveGLSLCode() .. scene_hits.GetGLSL("restir_data") .. RESOLVE_GLSL .. SPECULAR_LOBE_GLSL .. [[

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
					imageStore(out_effective, pos, vec4(0.0, 0.0, 0.0, 1.0));
					imageStore(out_specular, pos, vec4(0.0));
					imageStore(out_a, pos, vec4(0.0));
					imageStore(out_b, pos, vec4(0.0));
					imageStore(out_c, pos, vec4(0.0));
					imageStore(out_receiver, pos, vec4(0.0));
					return;
				}

				float W;
				float M;
				int flags;
				restir_sample own = restir_resolve(restir_load(restir_data.reservoir_a_tex, restir_data.reservoir_b_tex, restir_data.reservoir_c_tex, pos, W, M, flags));
				vec3 dir;
				float dist;
				float own_cosine = restir_receiver_cosine(own, P, N, dir, dist);
				float own_target = luminance(own.L) * own_cosine;
				vec3 irradiance = own.L * (own_cosine * W);
				// the lighting multiplies the irradiance by the EON response to uniform light, each sample knows where its light came from: backscatter toward the camera reflects up to twice that
				vec3 V = normalize(restir_data.camera_position - P);
				float NoV = max(dot(N, V), 1e-4);
				vec3 albedo = gbuffer_albedo(gpos);
				float roughness = sqrt(gbuffer_roughness(gpos));
				vec3 response = max(EON_directional_albedo(albedo, roughness, NoV), vec3(1e-4));
				bool weigh = all(greaterThan(response, vec3(1e-3)));
				vec3 effective = weigh && own_cosine > 0.0 ? irradiance * Fd_EON(albedo, roughness, own_cosine, NoV, dot(dir, V)) * RESTIR_PI / response : irradiance;
				// the specular ray's hits are clamped against fireflies, and what the clamp cuts off comes from this pixel's reservoir instead: weighed by the lobe rather than the cosine it estimates the same light over the lobe, and drawn by light it finds the bright things that the ray hits rarely. clamped part plus cut part is the whole, so the mean holds without the ray's speckle. the neighbours would lower its noise a little, but carrying the lobe through their loop costs the pass a quarter of its occupancy
				vec3 specular_N = N;
				float specular_roughness = 0.0;
				bool specular_clipped = false;
				float specular_limit = 1e30;
				bool specular_emission_sampled = false;

				if (restir_data.specular_reuse != 0 && (flags & RESTIR_FLAG_TRACED) != 0) {
					specular_roughness = radiance_specular_lobe_setup(gpos, P, V, get_geometric_normal(gpos, P, depth, V), view_depth, specular_N);
					specular_clipped = specular_roughness > REFLECTION_MIRROR_THRESHOLD;
					specular_limit = radiance_specular_hit_limit();
					specular_emission_sampled = radiance_specular_samples_emitters(pos, specular_roughness);
				}

				vec3 specular_excess = specular_clipped && own_cosine > 0.0 ? radiance_specular_clipped(own, specular_limit, specular_emission_sampled) * (radiance_specular_lobe(specular_N, V, specular_roughness, dir) * W) : vec3(0.0);
				// the reservoir handed to next frame: one sample resampled from this pixel's and its neighbours' by the same weights as the irradiance
				restir_sample picked = own;
				float picked_target = own_target;
				float picked_sum = 0.0;
				float picked_M = M;
				bool picked_own = true;
				float picked_W = W;

				// pairwise mis: neighbours get little say over light only this pixel can find (the wall beside it in a crease)
				if (restir_data.spatial != 0 && scene_hits_ready()) {
					vec3 origin = restir_ray_origin(gpos, P, N, view_depth, depth);
					float turn = restir_random(pos, 4u) * 6.28318530718;
					float plane_tolerance = 0.01 + 0.02 * view_depth;
					// a pixel with no history (disoccluded, or moving fast) has only its own fresh sample and nothing for the denoiser to average, it reuses more neighbours
					int count = M < 2.0 ? max(restir_data.spatial_samples, restir_data.disocclusion_samples) : restir_data.spatial_samples;
					float k = float(count);
					float own_weight = 0.0;
					float valid = 0.0;
					vec3 neighbours = vec3(0.0);
					vec3 effective_neighbours = vec3(0.0);

					for (int i = 0; i < count; i++) {
						ivec2 q_gpos;
						vec3 q_P;
						vec3 q_N;
						float q_view_depth;
						float q_depth;
						float q_W;
						float q_M = 0.0;
						int q_flags;
						restir_sample s;
						ivec2 q = pos;

						// a neighbour on another surface or without a reservoir is a wasted sample (foliage, thin geometry): it is drawn again, closer. the choice depends only on the geometry, not on the samples, so the weights hold
						for (int attempt = 0; attempt <= restir_data.spatial_retries && q_M <= 0.0; attempt++) {
							float angle = turn + float(i) * 2.39996323;
							float radius = sqrt((float(i) + restir_random(pos, 64u + uint(i))) / k) * restir_data.spatial_radius;

							if (attempt > 0) {
								angle = restir_random(pos, 128u + uint(i * 4 + attempt)) * 6.28318530718;
								radius = sqrt(restir_random(pos, 192u + uint(i * 4 + attempt))) * restir_data.spatial_radius / float(1 << attempt);
							}

							q = pos + ivec2(round(vec2(cos(angle), sin(angle)) * radius));

							if (q != pos && all(greaterThanEqual(q, ivec2(0))) && all(lessThan(q, size)) && restir_surface(q, size, q_gpos, q_P, q_N, q_view_depth, q_depth) && dot(N, q_N) >= 0.9 && abs(dot(N, q_P - P)) <= plane_tolerance) {
								s = restir_resolve(restir_load(restir_data.reservoir_a_tex, restir_data.reservoir_b_tex, restir_data.reservoir_c_tex, q, q_W, q_M, q_flags));
							}
						}

						if (q_M <= 0.0) {
							own_weight += 1.0;
							continue;
						}

						valid += 1.0;
						picked_M += q_M;

						vec3 q_dir;
						float q_dist;
						float own_at_q = q_M * luminance(own.L) * restir_receiver_cosine(own, q_P, q_N, q_dir, q_dist) * restir_jacobian(own, q_P, P);

						// a neighbour that cannot see this pixel's sample could not have found it, crediting it anyway darkens light found through gaps (canopies)
						if (own_at_q > 0.0 && own_target > 0.0 && restir_data.visibility != 0 && !restir_sample_visible(restir_ray_origin(q_gpos, q_P, q_N, q_view_depth, q_depth), own)) own_at_q = 0.0;

						own_weight += own_target * M / k + own_at_q > 0.0 ? own_target * M / k / (own_target * M / k + own_at_q) : 1.0;
						float jacobian = restir_jacobian(s, P, q_P);
						vec3 s_dir;
						float s_dist;
						float s_cosine = restir_receiver_cosine(s, P, N, s_dir, s_dist);

						if (!(jacobian > 0.0 && jacobian < 1e20) || s_cosine <= 0.0 || q_W <= 0.0 || luminance(s.L) <= 0.0) continue;

						if (restir_data.visibility != 0 && !restir_sample_visible(origin, s)) continue;

						float target_here = luminance(s.L) * s_cosine * M / k;
						float target_there = q_M * luminance(s.L) * restir_receiver_cosine(s, q_P, q_N, q_dir, q_dist) / jacobian;
						float weight = target_there / (target_here + target_there);
						vec3 term = s.L * (weight * s_cosine * jacobian * q_W);
						neighbours += term;
						effective_neighbours += weigh ? term * Fd_EON(albedo, roughness, s_cosine, NoV, dot(s_dir, V)) * RESTIR_PI / response : term;
						float w = luminance(s.L) * s_cosine * weight * jacobian * q_W;
						picked_sum += w;

						if (restir_random(pos, 96u + uint(i)) * picked_sum < w) {
							picked = s;
							picked_target = luminance(s.L) * s_cosine;
							picked_own = false;
						}
					}

					float own_w = M > 0.0 ? own_target * W * own_weight : 0.0;
					picked_sum += own_w;

					if (picked_sum > 0.0 && restir_random(pos, 15u) * picked_sum < own_w) {
						picked = own;
						picked_target = own_target;
						picked_own = true;
					}

					picked_W = picked_target > 0.0 ? picked_sum / (M > 0.0 ? k : max(valid, 1.0)) / picked_target : 0.0;

					// with no reservoir of its own (not traced yet), the pairs with missing neighbours have no one to give their weight to
					irradiance = M > 0.0 ? (irradiance * own_weight + neighbours) / k : neighbours / max(valid, 1.0);
					effective = M > 0.0 ? (effective * own_weight + effective_neighbours) / k : effective_neighbours / max(valid, 1.0);
				}

				irradiance /= RESTIR_PI;
				effective /= RESTIR_PI;

				if (any(isnan(irradiance)) || any(isinf(irradiance))) irradiance = vec3(0.0);

				if (any(isnan(effective)) || any(isinf(effective))) effective = vec3(0.0);

				int sky_flags = flags;

				if ((flags & RESTIR_FLAG_TRACED) == 0) {
					const ivec2 order[4] = ivec2[4](ivec2(0, 0), ivec2(1, 1), ivec2(1, 0), ivec2(0, 1));
					ivec2 partner = restir_data.ray_share == 2 ? pos + ivec2(pos.x + 1 < size.x ? 1 : -1, 0) : (pos & ~1) + order[restir_data.frame & 3];
					sky_flags = int(texelFetch(TEXTURE(restir_data.reservoir_c_tex), clamp(partner, ivec2(0), size - 1), 0).w + 0.5);
				}

				float sky = (sky_flags & RESTIR_FLAG_MISS) == 0 ? 0.0 : (sky_flags & RESTIR_FLAG_GUIDE_MIX) != 0 ? 1.0 / max(1.0 - restir_data.guided, 0.05) : 1.0;
				imageStore(out_raw, pos, vec4(irradiance, sky));
				imageStore(out_effective, pos, vec4(effective, sky));
				// the ray's weight stays the denominator: its weighted light and the reservoirs' estimate both average to the light over the lobe times that weight's mean
				vec4 ray_specular = texelFetch(TEXTURE(restir_data.candidate_specular_tex), pos, 0);

				if (!any(isnan(specular_excess)) && !any(isinf(specular_excess))) ray_specular.rgb += specular_excess;

				imageStore(out_specular, pos, ray_specular);

				if (!(picked_W >= 0.0 && picked_W < 1e30)) {
					picked_W = 0.0;
					picked_M = 0.0;
				}

				vec3 picked_receiver = picked_own ? texelFetch(TEXTURE(restir_data.receiver_tex), pos, 0).xyz : P;

				if (picked.kind == RESTIR_EMITTER) {
					float area_factor = restir_emitter_area_factor(picked, picked_receiver);
					picked_W = area_factor > 1e-6 ? picked_W / area_factor : 0.0;
				}

				imageStore(out_a, pos, vec4(restir_stored_x(picked), picked_W));
				imageStore(out_b, pos, vec4(picked.L, picked_M));
				imageStore(out_c, pos, vec4(picked.n, float(picked.kind | (flags & ~3))));
				imageStore(out_receiver, pos, vec4(picked_receiver, 0.0));
			}
		]],
	}
end

local function pass_accumulate()
	return {
		name = "radiance_accumulate",
		ComputePass = true,
		ColorFormat = {
			{
				"r32g32b32a32_sfloat",
				{"restir_accumulated", "rgb", 1 / post_source.UNEXPOSED_SDR_WHITE},
			},
			{"r32g32b32a32_sfloat", {"restir_history_length", "r", 1 / 16}},
			{
				"r32g32b32a32_sfloat",
				{"restir_accumulated_irradiance", "rgb", 1 / post_source.UNEXPOSED_SDR_WHITE},
			},
			{
				"r32g32b32a32_sfloat",
				{"restir_accumulated_specular", "rgb", 1 / post_source.UNEXPOSED_SDR_WHITE},
			},
			{"r32g32b32a32_sfloat", {"restir_specular_tracking", "r", 0.1}},
		},
		framebuffer_count = 2,
		scale = radiance.GetScale,
		LocalSize = LOCAL_SIZE,
		storage_images = storage_images(5),
		uniform_buffers = {restir_uniform(false)},
		custom_declarations = [[
			layout(set = 0, binding = 0, rgba32f) uniform writeonly image2D out_color;
			layout(set = 0, binding = 1, rgba32f) uniform writeonly image2D out_moments;
			layout(set = 0, binding = 2, rgba32f) uniform writeonly image2D out_irradiance;
			layout(set = 0, binding = 3, rgba32f) uniform writeonly image2D out_specular;
			layout(set = 0, binding = 4, rgba32f) uniform writeonly image2D out_tracking;
		]],
		shader = SURFACE_GLSL .. [[
			// last frame's screen position of the point a distance along -V from P, scaled so a point at any distance (the sky) keeps its precision
			vec2 radiance_previous_image_uv(vec3 P, vec3 V, float distance_behind, out float w) {
				mat4 to_clip = restir_data.prev_projection * restir_data.prev_view;
				vec4 clip = (to_clip * vec4(P, 1.0)) / (1.0 + distance_behind) + (to_clip * vec4(-V, 0.0)) * (distance_behind / (1.0 + distance_behind));
				w = clip.w;
				return clip.xy / max(clip.w, 1e-9) * 0.5 + 0.5;
			}

			// how far, in pixels, the image at a hit distance moves on the screen between last frame and this one, relative to the surface
			vec2 radiance_image_shift(vec3 P, vec3 V, float hit, ivec2 size) {
				float w_surface;
				float w_image;
				return (radiance_previous_image_uv(P, V, hit, w_image) - radiance_previous_image_uv(P, V, 0.0, w_surface)) * vec2(size);
			}

			// the reflection seen in a smooth surface moves on the screen as the reflected point does, not as the surface: its image lies behind the surface along the view ray, by the hit distance for a mirror and by less as the lobe widens and leans toward the normal (the dominant direction factor, as nrd does), so a rough lobe's image slides back onto the surface. the history is read where last frame showed that image, on texels that hold this pixel's plane, which the line from last frame's camera to the image crosses
			bool radiance_virtual_taps(vec3 P, vec3 N, vec3 V, float hit, float dominance, vec2 position, ivec2 size, vec4 plane, out ivec2 base, out vec4 weights) {
				base = ivec2(0);
				weights = vec4(0.0);

				if (position.x <= -1.0 || !(hit > 0.0)) return false;

				float w_surface;
				float w_image;
				vec2 delta = radiance_previous_image_uv(P, V, hit * dominance, w_image) - radiance_previous_image_uv(P, V, 0.0, w_surface);

				if (w_image <= 1e-9 || w_surface <= 1e-5) return false;

				vec2 virtual_position = position + delta * vec2(size);
				vec3 previous_camera = -(transpose(mat3(restir_data.prev_view)) * restir_data.prev_view[3].xyz);
				// the line from last frame's camera toward the image, as a direction for an image too far to place
				float behind = hit * dominance;
				vec3 ray = (P - previous_camera) / (1.0 + behind) - V * (behind / (1.0 + behind));
				float facing = dot(ray, N);

				if (abs(facing) < 1e-6) return false;

				vec3 Q = previous_camera + ray * (dot(P - previous_camera, N) / facing);
				float expected_depth = -(restir_data.prev_view * vec4(Q, 1.0)).z;

				if (expected_depth <= 1e-5) return false;

				base = ivec2(floor(virtual_position));
				vec2 f = virtual_position - vec2(base);

				for (int i = 0; i < 4; i++) {
					if (!restir_history_matches(base + ivec2(i & 1, i >> 1), size, N, plane, restir_history_tolerance(expected_depth, size))) continue;

					weights[i] = ((i & 1) == 1 ? f.x : 1.0 - f.x) * ((i >> 1) == 1 ? f.y : 1.0 - f.y) + 1e-4;
				}

				return dot(weights, vec4(1.0)) > 0.0;
			}

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
					imageStore(out_irradiance, pos, vec4(0.0));
					imageStore(out_specular, pos, vec4(0.0));
					imageStore(out_tracking, pos, vec4(0.0));
					return;
				}

				vec3 G = restir_geometric_normal(gpos, P);
				vec4 current = texelFetch(TEXTURE(restir_data.raw_effective_tex), pos, 0);
				float current_luminance = luminance(current.rgb);
				vec4 history = vec4(0.0);
				vec4 history_moments = vec4(0.0);
				vec3 history_irradiance = vec3(0.0);
				vec4 history_specular = vec4(0.0);
				vec4 history_tracking = vec4(0.0);
				ivec2 base;
				vec4 weights;

				vec4 plane;
				float tolerance;

				float moved;
				vec2 position;

				bool history_found = restir_history_taps(pos, gpos, P, G, size, base, weights, plane, tolerance, moved, position);

				if (!history_found && restir_history_search(position, size, G, plane, tolerance, base)) {
					weights = vec4(1.0, 0.0, 0.0, 0.0);
					history_found = true;
				}

				if (history_found) {
					float total = 0.0;

					for (int i = 0; i < 4; i++) {
						if (weights[i] <= 0.0) continue;

						ivec2 q = base + ivec2(i & 1, i >> 1);
						vec4 value = texelFetch(TEXTURE(restir_data.accum_history_tex), q, 0);
						vec4 moments = texelFetch(TEXTURE(restir_data.accum_history_moments_tex), q, 0);
						vec3 plain = texelFetch(TEXTURE(restir_data.accum_history_irradiance_tex), q, 0).rgb;
						vec4 specular = texelFetch(TEXTURE(restir_data.accum_history_specular_tex), q, 0);
						vec4 tracking = texelFetch(TEXTURE(restir_data.accum_history_tracking_tex), q, 0);

						if (any(isnan(value)) || any(isnan(moments)) || any(isnan(plain)) || any(isnan(specular)) || any(isnan(tracking))) continue;

						history += value * weights[i];
						history_irradiance += plain * weights[i];
						history_specular += specular * weights[i];
						history_tracking += tracking * weights[i];
						history_moments += moments * weights[i];
						total += weights[i];
					}

					if (total > 0.0) {
						history /= total;
						history_moments /= total;
						history_irradiance /= total;
						history_specular /= total;
						history_tracking /= total;
					}
				}

				float history_length = history_moments.x;

				for (int y = -1; y <= 1; y++) {
					for (int x = -1; x <= 1; x++) {
						ivec2 q = clamp(pos + ivec2(x, y), ivec2(0), size - 1);

						if ((int(texelFetch(TEXTURE(restir_data.reservoir_c_tex), q, 0).w + 0.5) & RESTIR_FLAG_CHANGED) != 0) history_length = min(history_length, 2.0);
					}
				}

				if ((int(texelFetch(TEXTURE(restir_data.reservoir_c_tex), pos, 0).w + 0.5) & RESTIR_FLAG_LIGHT_CHANGED) != 0) history_length = min(history_length, RESTIR_CHANGED_HISTORY - 1.0);

				history_length = min(history_length + 1.0, min(restir_data.accumulation, restir_data.history_cap));
				float alpha = 1.0 / history_length;
				vec2 moments = mix(history_moments.yz, vec2(current_luminance, current_luminance * current_luminance), alpha);
				// the specular depends on where it is seen from: its history covers at most half a lobe width of the view turning at this frame's rate, or the light seen from elsewhere stays mixed in
				vec3 previous_camera = -(transpose(mat3(restir_data.prev_view)) * restir_data.prev_view[3].xyz);
				float view_turn = acos(clamp(dot(normalize(restir_data.camera_position - P), normalize(previous_camera - P)), -1.0, 1.0));
				float lobe_width = max(gbuffer_roughness(gpos), 0.001);
				float specular_length = min(min(history_moments.w, view_turn > 0.0 ? 0.5 * lobe_width / view_turn : history_length) + 1.0, history_length);
				bool traced = (int(texelFetch(TEXTURE(restir_data.reservoir_c_tex), pos, 0).w + 0.5) & RESTIR_FLAG_TRACED) != 0;
				// the reflection is tracked by the inverse distance from the camera to its image (the camera to the surface plus the hit), which the image's motion on the screen is proportional to: averaged, a ray that escapes to the sky counts as far away only for its share, where an average of distances would put every image it touches at infinity. this frame's ray on a smooth surface, where it is exact, the accumulated one as the lobe widens and a single ray wanders over it (nrd's curve, already most of the way at perceptual roughness 0.1)
				float wander = (1.0 - exp2(-200.0 * lobe_width)) * pow(sqrt(lobe_width), 0.25);
				float surface_distance = distance(restir_data.camera_position, P);
				// weighed by the light each ray brought: what is seen of a glossy reflection is its bright part (a lamp, a window), and a broad lobe also finds the dark things right beside the surface, whose nearness would make the image trail
				float raw_inverse = traced ? 1.0 / (surface_distance + max(texelFetch(TEXTURE(restir_data.candidate_hit_tex), pos, 0).r, 0.0)) : 0.0;
				vec4 ray_specular = texelFetch(TEXTURE(restir_data.candidate_specular_tex), pos, 0);
				float raw_weight = traced ? luminance(ray_specular.rgb) + 1e-6 : 0.0;
				float history_inverse = history_tracking.y > 0.0 ? history_tracking.x / history_tracking.y : 0.0;
				float history_inverse_spread = history_tracking.y > 0.0 ? sqrt(max(history_tracking.z / history_tracking.y - history_inverse * history_inverse, 0.0)) : 0.0;
				float inverse = history_found && history_inverse > 0.0 ? (raw_inverse > 0.0 ? mix(raw_inverse, history_inverse, wander) : history_inverse) : raw_inverse;
				float hit = inverse > 0.0 ? max(1.0 / inverse - surface_distance, 0.0) : 0.0;
				// how far behind the surface the reflection's image lies, as a share of the hit distance: the dominant direction factor of the lobe, all of a mirror's, none of a fully rough one's
				float dominance = (1.0 - lobe_width) * (sqrt(1.0 - lobe_width) + lobe_width);
				vec3 V_view = normalize(restir_data.camera_position - P);
				ivec2 virtual_base;
				vec4 virtual_weights;

				if (restir_data.specular_tracking != 0 && history_found && radiance_virtual_taps(P, G, V_view, hit, dominance, position, size, plane, virtual_base, virtual_weights)) {
					vec4 virtual_specular = vec4(0.0);
					vec4 virtual_tracking = vec4(0.0);
					float virtual_length = 0.0;
					float total = 0.0;

					for (int i = 0; i < 4; i++) {
						if (virtual_weights[i] <= 0.0) continue;

						ivec2 q = virtual_base + ivec2(i & 1, i >> 1);
						vec4 specular = texelFetch(TEXTURE(restir_data.accum_history_specular_tex), q, 0);
						vec4 tracking = texelFetch(TEXTURE(restir_data.accum_history_tracking_tex), q, 0);
						float tracked_length = texelFetch(TEXTURE(restir_data.accum_history_moments_tex), q, 0).w;

						if (any(isnan(specular)) || any(isnan(tracking)) || isnan(tracked_length)) continue;

						virtual_specular += specular * virtual_weights[i];
						virtual_tracking += tracking * virtual_weights[i];
						virtual_length += tracked_length * virtual_weights[i];
						total += virtual_weights[i];
					}

					if (total > 0.0) {
						virtual_specular /= total;
						virtual_tracking /= total;
						virtual_length /= total;
						// a tracking distance that disagrees with the one found there last frame puts the image elsewhere: the history counts for less the more they differ, but only where one ray is the reflection (a mirror). on a glossy surface the rays scatter over the lobe and their distances always disagree, its history would never grow
						float virtual_inverse = virtual_tracking.y > 0.0 ? virtual_tracking.x / virtual_tracking.y : inverse;
						float confidence = mix(1.0 - clamp(20.0 * abs(inverse - virtual_inverse) / max(max(inverse, virtual_inverse), 1e-12), 0.0, 1.0), 1.0, smoothstep(0.0, 0.5, wander));
						// the image history replaces the surface's outright: a share of the surface's, misplaced by the reflection's motion every frame, builds up over a long history into a smear
						history_specular = virtual_specular;
						history_tracking = virtual_tracking;
						specular_length = min(mix(1.0, virtual_length, confidence) + 1.0, history_length);
						// a broad lobe sees near and far things at once (a box beside the surface, a lamp across the room), and their images move apart on the screen however the history is moved: it keeps only as many frames as they take to drift apart by half the lobe's own footprint on the screen. a mirror sees one thing and keeps all of its history
						float near_inverse = history_inverse + history_inverse_spread;
						float far_inverse = max(history_inverse - history_inverse_spread, 1e-9);
						float drift = length(radiance_image_shift(P, V_view, dominance * max(1.0 / near_inverse - surface_distance, 0.0), size) - radiance_image_shift(P, V_view, dominance * max(1.0 / far_inverse - surface_distance, 0.0), size));
						float footprint = hit * lobe_width / max(surface_distance + hit, 1e-6) / (2.0 * abs(restir_data.inv_projection[1][1]) / float(size.y));

						if (drift > 1e-3) specular_length = min(specular_length, max(0.5 * footprint / drift, 1.0) + 1.0);
					}
				}

				imageStore(out_color, pos, mix(history, current, alpha));
				imageStore(out_moments, pos, vec4(history_length, moments, specular_length));
				vec3 tracking = history_tracking.xyz;
				vec3 raw_tracking = vec3(raw_inverse * raw_weight, raw_weight, raw_inverse * raw_inverse * raw_weight);

				if (raw_inverse > 0.0) tracking = history_tracking.y > 0.0 ? mix(history_tracking.xyz, raw_tracking, max(1.0 / specular_length, 0.1)) : raw_tracking;

				imageStore(out_tracking, pos, vec4(tracking, history_tracking.w));
				imageStore(out_irradiance, pos, vec4(mix(history_irradiance, texelFetch(TEXTURE(restir_data.raw_tex), pos, 0).rgb, alpha), 1.0));
				vec4 accumulated_specular = history_specular;

				if (traced) {
					vec3 specular_mean = vec3(0.0);
					vec3 specular_squared = vec3(0.0);

					for (int y = -1; y <= 1; y++) {
						for (int x = -1; x <= 1; x++) {
							vec3 value = texelFetch(TEXTURE(restir_data.raw_specular_tex), clamp(pos + ivec2(x, y), ivec2(0), size - 1), 0).rgb;
							specular_mean += value;
							specular_squared += value * value;
						}
					}

					specular_mean /= 9.0;
					// a reflected thing that moved leaves the history behind: the history is held in what this frame's neighbourhood shows
					vec3 specular_spread = 3.0 * sqrt(max(specular_squared / 9.0 - specular_mean * specular_mean, vec3(0.0))) + 0.05 * specular_mean + 1e-3;
					// a rough lobe is its own noise and a clamp to the neighbourhood of heavy tailed samples (an emitter sample) darkens it: only a smooth surface holds its history
					specular_spread = mix(specular_spread, vec3(1e30), smoothstep(0.1, 0.3, sqrt(lobe_width)));
					vec4 raw_specular = texelFetch(TEXTURE(restir_data.raw_specular_tex), pos, 0);
					accumulated_specular = mix(vec4(clamp(history_specular.rgb, specular_mean - specular_spread, specular_mean + specular_spread), history_specular.a), raw_specular, 1.0 / specular_length);
				}

				imageStore(out_specular, pos, accumulated_specular);
			}
		]],
	}
end

-- a-trous passes with growing steps over the accumulated estimate, each tap stopped by the plane, the normal and a luminance difference beyond the pixel's standard deviation (of the accumulated mean, carried in alpha between the passes), so a noisy pixel blurs wide and a settled one keeps its detail
local function pass_filter(iteration)
	local last = iteration == FILTER_ITERATIONS - 1
	return {
		name = filter_name(iteration),
		ComputePass = true,
		ColorFormat = {
			{
				"r16g16b16a16_sfloat",
				{filter_name(iteration), "rgb", 1 / post_source.UNEXPOSED_SDR_WHITE},
			},
			{"r16g16b16a16_sfloat", {filter_name(iteration) .. "_geometry", "rgb"}},
			{
				"r16g16b16a16_sfloat",
				{
					filter_name(iteration) .. "_specular",
					"rgb",
					1 / post_source.UNEXPOSED_SDR_WHITE,
				},
			},
		},
		framebuffer_count = 1,
		scale = radiance.GetScale,
		LocalSize = LOCAL_SIZE,
		storage_images = {
			{binding_index = 0, attachment = 1, dst_stage = {"compute", "fragment"}},
			{binding_index = 1, attachment = 2, dst_stage = {"compute", "fragment"}},
			{binding_index = 2, attachment = 3, dst_stage = {"compute", "fragment"}},
		},
		uniform_buffers = {restir_uniform(false, iteration)},
		custom_declarations = [[
			layout(set = 0, binding = 0, rgba16f) uniform writeonly image2D out_color;
			layout(set = 0, binding = 1, rgba16f) uniform writeonly image2D out_geometry;
			layout(set = 0, binding = 2, rgba16f) uniform writeonly image2D out_specular;
		]],
		shader = SURFACE_GLSL .. post_source.GetPreExposureGLSL("restir_data") .. [[
			#define RESTIR_FILTER_FIRST ]] .. (
				iteration == 0 and
				"1" or
				"0"
			) .. [[

			#define RESTIR_FILTER_LAST ]] .. (
				last and
				"1" or
				"0"
			) .. [[

			vec4 restir_filter_specular(ivec2 q) {
				vec4 specular = texelFetch(TEXTURE(restir_data.filter_specular_source_tex), q, 0);

				#if RESTIR_FILTER_FIRST
				specular.rgb *= get_pre_exposure();
				#endif

				return specular;
			}

			float restir_filter_deviation(ivec2 q, vec4 value) {
				#if RESTIR_FILTER_FIRST
				vec3 moments = texelFetch(TEXTURE(restir_data.accum_moments_tex), q, 0).xyz;
				float history_length = max(moments.x, 1.0);

				// the temporal variance means little with a few frames of history, and the pixel's own luminance is no stand in: most single samples of a light that rare rays find are dark, a dark pixel would then turn away its brighter neighbours and the whole newly seen area comes out dark. it blurs by plane and normal only
				if (history_length < 4.0) return 65000.0;

				return sqrt(max(moments.z - moments.y * moments.y, 0.0) / history_length);
				#else
				return value.a;
				#endif
			}

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
					imageStore(out_specular, pos, vec4(0.0));
					return;
				}

				vec4 center = texelFetch(TEXTURE(restir_data.filter_source_tex), pos, 0);
				vec4 specular = restir_filter_specular(pos);
				// a smooth surface keeps its reflection sharp: the specular is only averaged out as far as its lobe is wide
				float specular_reach = 9.0 * smoothstep(0.04, 0.6, sqrt(gbuffer_roughness(gpos)));
												float specular_gate = clamp(specular_reach - float(restir_data.filter_step) + 1.0, 0.0, 1.0);
				float deviation = restir_filter_deviation(pos, center);
				vec3 result = center.rgb;
				float result_deviation = deviation;

				if (restir_data.filter_enabled != 0) {
					float center_luminance = luminance(center.rgb);
					float luminance_tolerance = restir_data.filter_luminance * deviation + 0.01 * center_luminance + 1e-6;
					float plane_tolerance = 0.01 + 0.01 * view_depth;
					vec3 sum = vec3(0.0);
					vec4 specular_sum = vec4(0.0);
					float specular_total = 0.0;
					float total = 0.0;
					float variance = 0.0;

					for (int y = -1; y <= 1; y++) {
						for (int x = -1; x <= 1; x++) {
							ivec2 q = pos + ivec2(x, y) * restir_data.filter_step;

							if (any(lessThan(q, ivec2(0))) || any(greaterThanEqual(q, size))) continue;

							float w = (x == 0 ? 0.5 : 0.25) * (y == 0 ? 0.5 : 0.25);
							vec4 value = center;
							vec4 q_specular = specular;

							if (q != pos) {
								ivec2 q_gpos;
								vec3 q_P;
								vec3 q_N;
								float q_view_depth;
								float q_depth;

								if (!restir_surface(q, size, q_gpos, q_P, q_N, q_view_depth, q_depth)) continue;

								value = texelFetch(TEXTURE(restir_data.filter_source_tex), q, 0);
								q_specular = restir_filter_specular(q);

								if (any(isnan(value)) || any(isnan(q_specular))) continue;

								w *= exp(-abs(dot(N, q_P - P)) / plane_tolerance - abs(luminance(value.rgb) - center_luminance) / luminance_tolerance) * pow(max(dot(N, q_N), 0.0), 16.0);

								if (w <= 1e-5) continue;
							}

							float q_deviation = q == pos ? deviation : restir_filter_deviation(q, value);
							sum += value.rgb * w;
							float specular_w = q == pos ? w : w * specular_gate;
							specular_sum += q_specular * specular_w;
							specular_total += specular_w;
							variance += w * w * q_deviation * q_deviation;
							total += w;
						}
					}

					result = sum / total;
					specular = specular_sum / specular_total;
					result_deviation = sqrt(variance) / total;
				}

				// the last pass hands the lighting the accumulated alpha (sky visibility), the others carry the deviation in it
				#if RESTIR_FILTER_LAST
				imageStore(out_color, pos, min(vec4(result, texelFetch(TEXTURE(restir_data.accum_tex), pos, 0).a), vec4(65000.0)));
				#else
				imageStore(out_color, pos, min(vec4(result, result_deviation), vec4(65000.0)));
				#endif
				imageStore(out_geometry, pos, vec4(N, view_depth));
				imageStore(out_specular, pos, min(specular, vec4(65000.0)));
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
	pass_filter(0),
	pass_filter(1),
	pass_filter(2),
	pass_filter(3),
}
