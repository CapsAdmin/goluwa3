
local commands = import("goluwa/cli/commands.lua")
local system = import("goluwa/system.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local scene_lights = import("goluwa/render3d/scene_lights.lua")
local directional_shadows = import("goluwa/render3d/directional_shadows.lua")
local voxel_gi = import("goluwa/render3d/voxels/global_illumination.lua")
local scene_bvh = import("goluwa/render3d/scene_bvh.lua")
local screen_reconstruct = import("goluwa/render3d/screen_reconstruct.lua")
local radiance_cascades = library()
local MAX_CLIPMAPS = voxel_gi.GetMaxClipmapCount()
radiance_cascades.BACKEND = radiance_cascades.BACKEND or "bvh"
radiance_cascades.CASCADE_COUNT = radiance_cascades.CASCADE_COUNT or 6
radiance_cascades.INTERVAL_VOXELS = radiance_cascades.INTERVAL_VOXELS or 2
radiance_cascades.INTERVAL_SCALE = 4
radiance_cascades.DIRECTIONS_0 = radiance_cascades.DIRECTIONS_0 or 4
radiance_cascades.SCREEN_SCALE = radiance_cascades.SCREEN_SCALE or 0.5
radiance_cascades.JITTER = radiance_cascades.JITTER or 1
radiance_cascades.MAX_TRACE_STEPS = radiance_cascades.MAX_TRACE_STEPS or 96
radiance_cascades.NORMAL_BIAS = radiance_cascades.NORMAL_BIAS or 1.5
radiance_cascades.BVH_NORMAL_BIAS = radiance_cascades.BVH_NORMAL_BIAS or 0.02
radiance_cascades.SKY_INTENSITY = radiance_cascades.SKY_INTENSITY or 1
radiance_cascades.FEEDBACK_STRENGTH = radiance_cascades.FEEDBACK_STRENGTH or 1
radiance_cascades.TEMPORAL_BLEND = radiance_cascades.TEMPORAL_BLEND or 0.98
radiance_cascades.DENOISE = radiance_cascades.DENOISE or 1
radiance_cascades.DENOISE_RADIUS = radiance_cascades.DENOISE_RADIUS or 2
radiance_cascades.DENOISE_STRIDE = radiance_cascades.DENOISE_STRIDE or 3
radiance_cascades.WORLD_BOUNCE = radiance_cascades.WORLD_BOUNCE ~= false
radiance_cascades.WORLD_BOUNCE_STRENGTH = radiance_cascades.WORLD_BOUNCE_STRENGTH or 1
radiance_cascades.enabled = radiance_cascades.enabled ~= false

function radiance_cascades.GetDirectionCount(cascade)
	return radiance_cascades.DIRECTIONS_0 * (2 ^ cascade)
end

function radiance_cascades.GetBaseInterval()
	if radiance_cascades.BASE_INTERVAL then return radiance_cascades.BASE_INTERVAL end

	local info = voxel_gi.GetClipmapInfo(1)
	return (
		info and info.voxel_size or 0.5
	) * radiance_cascades.INTERVAL_VOXELS
end

function radiance_cascades.GetInterval(cascade)
	local base = radiance_cascades.GetBaseInterval()
	local scale = radiance_cascades.INTERVAL_SCALE

	if cascade == 0 then return 0, base end

	return base * scale ^ (cascade - 1), base * scale ^ cascade
end

function radiance_cascades.IsActive()
	if not radiance_cascades.enabled then return false end

	if radiance_cascades.BACKEND == "bvh" and not scene_bvh.IsReady() then
		return false
	end

	for i = 1, MAX_CLIPMAPS do
		local info = voxel_gi.GetClipmapInfo(i)

		if info and info.valid then return true end
	end

	return false
end

function radiance_cascades.GetBlockLayout()
	return {
		render3d.camera_block,
		render3d.gbuffer_block,
		{"shadows", scene_lights.BuildShadowsBlockLayout()},
		{"rc_sun_direction", "vec4"},
		{"rc_sun_radiance", "vec4"},
		{"rc_env_tex", "int"},
		{"rc_env_irradiance_tex", "int"},
		{"rc_enabled", "int"},
		{"rc_clipmap_count", "int"},
		{"rc_clip_origin", "vec4", MAX_CLIPMAPS},
		{"rc_clip_params", "vec4", MAX_CLIPMAPS},
		{"rc_interval", "vec4"},
		{"rc_max_steps", "int"},
		{"rc_min_clipmap", "int"},
		{"rc_feedback_tex", "int"},
		{"rc_feedback_strength", "float"},
		{"rc_world_bounce", "float"},
		{"rc_denoise", "float"},
		{"rc_history_tex", "int"},
		{"rc_history_depth_tex", "int"},
		{"rc_history_blend", "float"},
		{"rc_jitter", "float"},
		{"rc_frame", "int"},
		{"rc_prev_view", "mat4"},
		{"rc_prev_projection", "mat4"},
		{"gi", voxel_gi.GetBlockLayout()},
	}
end

function radiance_cascades.GetResolveFramebufferIndex(offset)
	return (system.GetFrameNumber() + (offset or 0)) % 2 + 1
end

function radiance_cascades.WriteBlock(self, block, cascade)
	render3d.WriteCameraBlock(self, block)
	render3d.WriteGBufferBlock(self, block)
	local lights = render3d.GetLights()
	scene_lights.WriteShadowBlock(self, block.shadows, lights)
	local sun_direction = directional_shadows.GetPrimarySunDirection(lights)
	local sun_color = directional_shadows.GetPrimarySunColor(lights)
	local sun_intensity = directional_shadows.GetPrimarySunIntensity(lights)
	sun_direction:CopyToFloatPointer(block.rc_sun_direction)
	block.rc_sun_direction[3] = 0
	block.rc_sun_radiance[0] = sun_color.x * sun_intensity
	block.rc_sun_radiance[1] = sun_color.y * sun_intensity
	block.rc_sun_radiance[2] = sun_color.z * sun_intensity
	block.rc_sun_radiance[3] = 0
	block.rc_env_tex = self:GetTextureIndex(render3d.GetEnvironmentTexture())
	block.rc_env_irradiance_tex = self:GetTextureIndex(render3d.GetEnvironmentIrradianceTexture())
	block.rc_enabled = radiance_cascades.IsActive() and 1 or 0
	local clipmap_count = 0

	for i = 0, MAX_CLIPMAPS - 1 do
		local info = voxel_gi.GetClipmapInfo(i + 1)

		if info and info.valid then
			clipmap_count = i + 1
			block.rc_clip_origin[i][0] = info.origin.x
			block.rc_clip_origin[i][1] = info.origin.y
			block.rc_clip_origin[i][2] = info.origin.z
			block.rc_clip_origin[i][3] = info.voxel_size
			block.rc_clip_params[i][0] = info.world_span
			block.rc_clip_params[i][1] = info.resolution
			block.rc_clip_params[i][2] = 1
			block.rc_clip_params[i][3] = 0
		else
			block.rc_clip_origin[i][0] = 0
			block.rc_clip_origin[i][1] = 0
			block.rc_clip_origin[i][2] = 0
			block.rc_clip_origin[i][3] = 1
			block.rc_clip_params[i][0] = 0
			block.rc_clip_params[i][1] = 0
			block.rc_clip_params[i][2] = 0
			block.rc_clip_params[i][3] = 0
		end
	end

	block.rc_clipmap_count = clipmap_count
	local interval_start, interval_end = radiance_cascades.GetInterval(cascade)
	block.rc_interval[0] = interval_start
	block.rc_interval[1] = interval_end
	block.rc_interval[2] = radiance_cascades.BACKEND == "bvh" and
		radiance_cascades.BVH_NORMAL_BIAS or
		radiance_cascades.NORMAL_BIAS * block.rc_clip_origin[0][3]
	block.rc_interval[3] = radiance_cascades.SKY_INTENSITY
	block.rc_max_steps = radiance_cascades.MAX_TRACE_STEPS
	block.rc_min_clipmap = math.min(cascade, math.max(clipmap_count - 1, 0))

	local resolve = render3d.pipelines.radiance_cascades_resolve

	if resolve then
		local history = resolve:GetFramebuffer(radiance_cascades.GetResolveFramebufferIndex(1))
		block.rc_feedback_tex = self:GetTextureIndex(history:GetAttachment(1))
		block.rc_history_tex = self:GetTextureIndex(history:GetAttachment(1))
		block.rc_history_depth_tex = self:GetTextureIndex(history:GetAttachment(2))
	else
		block.rc_feedback_tex = -1
		block.rc_history_tex = -1
		block.rc_history_depth_tex = -1
	end

	if not render3d.ShouldUseLastFrameHistory() then
		block.rc_history_tex = -1
		block.rc_history_depth_tex = -1
	end

	block.rc_denoise = radiance_cascades.DENOISE
	block.rc_history_blend = radiance_cascades.TEMPORAL_BLEND
	block.rc_jitter = radiance_cascades.JITTER
	block.rc_frame = system.GetFrameNumber() % 4096
	local prev_view = render3d.GetPreviousViewMatrix() or render3d.GetRenderCamera():BuildViewMatrix()
	local prev_projection = render3d.GetPreviousProjectionMatrix() or
		render3d.GetRenderCamera():BuildProjectionMatrix()
	prev_view:CopyToFloatPointer(block.rc_prev_view)
	prev_projection:CopyToFloatPointer(block.rc_prev_projection)

	block.rc_feedback_strength = radiance_cascades.FEEDBACK_STRENGTH
	block.rc_world_bounce = radiance_cascades.WORLD_BOUNCE and
		radiance_cascades.WORLD_BOUNCE_STRENGTH or
		0
	voxel_gi.WriteBlock(self, block.gi)
	return block
end

function radiance_cascades.GetCommonGLSL()
	return [[
		vec3 rc_oct_decode(vec2 uv) {
			vec2 p = uv * 2.0 - 1.0;
			vec3 n = vec3(p.x, p.y, 1.0 - abs(p.x) - abs(p.y));

			if (n.z < 0.0) {
				n.xy = (1.0 - abs(n.yx)) * vec2(p.x >= 0.0 ? 1.0 : -1.0, p.y >= 0.0 ? 1.0 : -1.0);
			}

			return normalize(n);
		}

		vec2 rc_direction_jitter(int frame, float strength) {
			if (strength <= 0.0) return vec2(0.0);

			return (fract(vec2(0.7548776662, 0.5698402909) * float(frame)) - 0.5) * strength;
		}

		ivec2 rc_bilinear_offset(int index) {
			return ivec2(index & 1, index >> 1);
		}

		vec4 rc_bilinear_weights(vec2 ratio) {
			return vec4(
				(1.0 - ratio.x) * (1.0 - ratio.y),
				ratio.x * (1.0 - ratio.y),
				(1.0 - ratio.x) * ratio.y,
				ratio.x * ratio.y
			);
		}

		float rc_project_on_line(vec3 line_start, vec3 line_end, vec3 point) {
			vec3 line = line_end - line_start;
			float length_squared = dot(line, line);

			if (length_squared < 1e-12) return 0.0;

			return clamp(dot(point - line_start, line) / length_squared, 0.0, 1.0);
		}

		vec2 rc_bilinear_3d_ratio(vec3 probe_positions[4], vec3 point, vec2 ratio) {
			for (int i = 0; i < 4; i++) {
				vec3 mixed_y0 = mix(probe_positions[0], probe_positions[2], ratio.y);
				vec3 mixed_y1 = mix(probe_positions[1], probe_positions[3], ratio.y);
				ratio.x = rc_project_on_line(mixed_y0, mixed_y1, point);
				vec3 mixed_x0 = mix(probe_positions[0], probe_positions[1], ratio.x);
				vec3 mixed_x1 = mix(probe_positions[2], probe_positions[3], ratio.x);
				ratio.y = rc_project_on_line(mixed_x0, mixed_x1, point);
			}

			return ratio;
		}
	]]
end

function radiance_cascades.GetProbeGLSL(block_name)
	return screen_reconstruct.GetWorldPosFromUVGLSL(block_name, {function_name = "rc_reconstruct_world_pos"}) .. (
		[[
		bool rc_fetch_surface_motion(vec2 uv, float depth, out vec2 prev_uv, out float prev_depth) {
			if (%s.velocity_tex != -1) {
				vec3 motion = texture(TEXTURE(%s.velocity_tex), uv).rgb;
				prev_uv = uv - motion.xy;
				prev_depth = motion.z;
				return prev_depth > 0.0;
			}

			vec3 world_pos = rc_reconstruct_world_pos(uv, depth);
			vec4 prev_view_pos = %s.rc_prev_view * vec4(world_pos, 1.0);
			vec4 prev_clip = %s.rc_prev_projection * prev_view_pos;

			if (prev_clip.w <= 0.0) return false;

			prev_uv = (prev_clip.xy / prev_clip.w) * 0.5 + 0.5;
			prev_depth = -prev_view_pos.z;
			return true;
		}

		const float RC_PROBE_DEPTH_BIAS = 0.999;

		float rc_probe_depth(vec2 uv) {
			return texture(TEXTURE(%s.depth_tex), uv).r;
		}

		vec3 rc_probe_world_pos(vec2 uv, float depth) {
			vec3 world_pos = rc_reconstruct_world_pos(uv, depth);
			return mix(%s.camera_position.xyz, world_pos, RC_PROBE_DEPTH_BIAS);
		}

		vec3 rc_probe_normal(vec2 uv) {
			vec3 n = texture(TEXTURE(%s.normal_tex), uv).xyz;
			float len = length(n);
			return len > 1e-4 ? n / len : vec3(0.0, 1.0, 0.0);
		}

		float rc_linear_depth(float depth) {
			return %s.projection[3][2] / (depth + %s.projection[2][2]);
		}
	]]
	):format(
		block_name,
		block_name,
		block_name,
		block_name,
		block_name,
		block_name,
		block_name,
		block_name,
		block_name
	)
end

function radiance_cascades.GetTraceGLSL(block_name)
	local fetch = {}

	for i = 0, MAX_CLIPMAPS - 1 do
		fetch[#fetch + 1] = "\tif (c == " .. i .. ") return texelFetch(rc_volume_" .. i .. ", ivec3(v.xy, v.z), 0);"
	end

	local fetch_normal = {}

	for i = 0, MAX_CLIPMAPS - 1 do
		fetch_normal[#fetch_normal + 1] = "\tif (c == " .. i .. ") return texelFetch(rc_normal_" .. i .. ", ivec3(v.xy, v.z), 0).xyz;"
	end

	return [[
		#define RC_BLOCK ]] .. block_name .. [[

		vec3 rc_clip_origin(int c) { return RC_BLOCK.rc_clip_origin[c].xyz; }
		float rc_clip_voxel_size(int c) { return RC_BLOCK.rc_clip_origin[c].w; }
		float rc_clip_span(int c) { return RC_BLOCK.rc_clip_params[c].x; }
		int rc_clip_resolution(int c) { return int(RC_BLOCK.rc_clip_params[c].y + 0.5); }

		bool rc_clip_valid(int c) {
			return c >= 0 && c < RC_BLOCK.rc_clipmap_count && RC_BLOCK.rc_clip_params[c].z > 0.5;
		}

		bool rc_clip_contains(int c, vec3 p) {
			if (!rc_clip_valid(c)) return false;

			vec3 d = abs(p - rc_clip_origin(c));
			return all(lessThan(d, vec3(rc_clip_span(c) * 0.5 - rc_clip_voxel_size(c) * 0.01)));
		}

		int rc_find_clipmap(vec3 p, int min_clip) {
			for (int c = max(min_clip, 0); c < RC_BLOCK.rc_clipmap_count; c++) {
				if (rc_clip_contains(c, p)) return c;
			}

			return -1;
		}

		vec4 rc_fetch_voxel(int c, ivec3 v) {
]] .. table.concat(fetch, "\n") .. [[

			return vec4(0.0);
		}

		vec3 rc_fetch_voxel_normal(int c, ivec3 v) {
]] .. table.concat(fetch_normal, "\n") .. [[

			return vec3(0.0);
		}

		vec3 rc_decode_voxel_normal(vec3 stored) {
			vec3 n = stored * 2.0 - 1.0;
			float len = length(n);
			return len > 1e-3 ? n / len : vec3(0.0);
		}

		struct rc_hit {
			vec3 position;
			vec3 normal;
			vec4 voxel;
			int clipmap;
		};

		vec4 rc_sample_surface_voxel(vec3 p, vec3 n) {
			for (int c = 0; c < RC_BLOCK.rc_clipmap_count; c++) {
				if (!rc_clip_contains(c, p)) continue;

				float voxel_size = rc_clip_voxel_size(c);
				vec3 min_corner = rc_clip_origin(c) - vec3(rc_clip_span(c) * 0.5);
				ivec3 v = ivec3(floor((p - n * (voxel_size * 0.5) - min_corner) / voxel_size));

				if (
					any(lessThan(v, ivec3(0))) ||
					any(greaterThanEqual(v, ivec3(rc_clip_resolution(c))))
				) {
					continue;
				}

				vec4 voxel = rc_fetch_voxel(c, v);

				if (voxel.a >= 0.5) return voxel;
			}

			return vec4(0.5, 0.5, 0.5, 1.0);
		}

		bool rc_trace_voxels(vec3 origin, vec3 dir, float t_min, float t_max, out rc_hit hit) {
			vec3 start = origin + dir * t_min;
			float span = t_max - t_min;
			int c = rc_find_clipmap(start, RC_BLOCK.rc_min_clipmap);
			vec3 safe_dir = mix(dir, vec3(1e-5), lessThan(abs(dir), vec3(1e-5)));
			vec3 inv_dir = 1.0 / safe_dir;
			vec3 dir_sign = mix(vec3(-1.0), vec3(1.0), greaterThanEqual(dir, vec3(0.0)));
			vec3 face_normal = -dir;
			float t = 0.0;

			for (int step = 0; step < RC_BLOCK.rc_max_steps; step++) {
				if (c < 0 || t > span) return false;

				vec3 pos = start + dir * t;
				float voxel_size = rc_clip_voxel_size(c);
				int resolution = rc_clip_resolution(c);
				vec3 min_corner = rc_clip_origin(c) - vec3(rc_clip_span(c) * 0.5);
				ivec3 v = ivec3(floor((pos - min_corner) / voxel_size));

				if (any(lessThan(v, ivec3(0))) || any(greaterThanEqual(v, ivec3(resolution)))) {
					c = rc_find_clipmap(pos, c + 1);
					continue;
				}

				vec4 voxel = rc_fetch_voxel(c, v);

				if (voxel.a >= 0.5) {
					vec3 stored = rc_decode_voxel_normal(rc_fetch_voxel_normal(c, v));
					bool has_stored = dot(stored, stored) > 0.5;
					hit.position = pos;
					hit.voxel = voxel;
					hit.clipmap = c;
					hit.normal = has_stored && dot(stored, dir) <= 0.0 ? stored : face_normal;
					return true;
				}

				vec3 boundary = min_corner + vec3(v) * voxel_size +
					mix(vec3(0.0), vec3(voxel_size), greaterThanEqual(dir, vec3(0.0)));
				vec3 tt = max((boundary - pos) * inv_dir, vec3(0.0));
				int axis = tt.x <= tt.y && tt.x <= tt.z ? 0 : (tt.y <= tt.z ? 1 : 2);
				face_normal = vec3(0.0);
				face_normal[axis] = -dir_sign[axis];
				t += min(tt.x, min(tt.y, tt.z)) + voxel_size * 1e-3;
			}

			return false;
		}

]] .. (
		radiance_cascades.BACKEND == "bvh" and
		[[
		bool rc_trace_interval(vec3 origin, vec3 dir, float t_min, float t_max, out rc_hit hit) {
			scene_bvh_hit traced;

			if (!scene_bvh_trace(origin, dir, 0.0, t_max, traced)) return false;

			if (traced.distance < t_min) {
				hit.position = traced.position;
				hit.normal = traced.normal;
				hit.clipmap = 0;
				hit.voxel = vec4(0.0, 0.0, 0.0, 1.0);
				return true;
			}

			hit.position = traced.position;
			hit.normal = traced.normal;
			hit.clipmap = max(rc_find_clipmap(traced.position, 0), 0);
			vec4 voxel = rc_sample_surface_voxel(traced.position, traced.normal);
			vec3 emissive = clamp(voxel.rgb * traced.emissive, vec3(0.0), vec3(1.0));
			hit.voxel = vec4(voxel.rgb, 1.0 + dot(emissive, vec3(0.2126, 0.7152, 0.0722)));
			return true;
		}
	]] or
		[[
		bool rc_trace_interval(vec3 origin, vec3 dir, float t_min, float t_max, out rc_hit hit) {
			return rc_trace_voxels(origin, dir, t_min, t_max, hit);
		}
	]]
	) .. [[

		vec3 rc_sky(vec3 dir) {
			return textureLod(
				TEXTURE(RC_BLOCK.rc_env_tex),
				dir_to_equirect_uv(correct_environment_lookup_dir(dir)),
				1.0
			).rgb * RC_BLOCK.rc_interval.w;
		}

		vec3 rc_feedback_irradiance(vec3 hit_pos, vec3 hit_normal, float voxel_size, out float confidence) {
			confidence = 0.0;

			if (RC_BLOCK.rc_feedback_tex < 0) return vec3(0.0);

			vec4 clip = RC_BLOCK.projection * (RC_BLOCK.view * vec4(hit_pos, 1.0));

			if (clip.w <= 0.0) return vec3(0.0);

			vec2 uv = (clip.xy / clip.w) * 0.5 + 0.5;

			if (any(lessThan(uv, vec2(0.0))) || any(greaterThan(uv, vec2(1.0)))) return vec3(0.0);

			float depth = texture(TEXTURE(RC_BLOCK.depth_tex), uv).r;

			if (depth == 1.0) return vec3(0.0);

			vec3 seen = rc_reconstruct_world_pos(uv, depth);
			float seen_view_z = -(RC_BLOCK.view * vec4(seen, 1.0)).z;
			float hit_view_z = -(RC_BLOCK.view * vec4(hit_pos, 1.0)).z;

			if (abs(seen_view_z - hit_view_z) > voxel_size) return vec3(0.0);

			float agreement = smoothstep(0.0, 0.5, dot(rc_probe_normal(uv), hit_normal));

			if (agreement <= 0.0) return vec3(0.0);

			confidence = agreement;
			return texture(TEXTURE(RC_BLOCK.rc_feedback_tex), uv).rgb *
				RC_BLOCK.rc_feedback_strength;
		}

		vec3 rc_world_bounce(vec3 pos, vec3 N) {
			int cascade_count = min(RC_BLOCK.gi.gi_cascade_count, VOXEL_GI_MAX_SAMPLE_CASCADES);

			for (int c = 0; c < cascade_count; c++) {
				vec3 bias_pos = pos + N * (voxel_gi_spacing(c) * 0.25);

				if (voxel_gi_cascade_fade(c, bias_pos) <= 0.0) continue;

				float weight;
				vec3 irradiance = voxel_gi_sample_cascade(c, pos, bias_pos, N, false, weight);

				if (weight > 1e-6) return irradiance * RC_BLOCK.rc_world_bounce;
			}

			return vec3(0.0);
		}

		vec3 rc_shade_hit(rc_hit hit) {
			vec3 N = hit.normal;
			float voxel_size = rc_clip_voxel_size(max(hit.clipmap, 0));
			vec3 surface_pos = hit.position + N * ]] .. (
		radiance_cascades.BACKEND == "bvh" and "RC_BLOCK.rc_interval.z" or "(voxel_size * 0.5)"
	) .. [[;
			vec3 L = normalize(RC_BLOCK.rc_sun_direction.xyz);
			float NoL = max(dot(N, L), 0.0);
			float shadow = 1.0;

			if (NoL > 0.0 && RC_BLOCK.shadows.shadow_map_indices[0] >= 0) {
				shadow = calculateShadow(surface_pos, N, L);
			}

			vec3 albedo = clamp(hit.voxel.rgb, vec3(0.0), vec3(1.0));
			vec3 direct = RC_BLOCK.rc_sun_radiance.rgb * (NoL * shadow / 3.14159265359);
			float confidence;
			vec3 bounce = rc_feedback_irradiance(surface_pos, N, voxel_size, confidence);

			if (RC_BLOCK.rc_world_bounce > 0.0 && confidence < 1.0) {
				bounce = mix(rc_world_bounce(surface_pos, N), bounce, confidence);
			} else {
				bounce *= confidence;
			}
			float emissive_luma = max(hit.voxel.a - 1.0, 0.0) * 4.0;
			float luma = dot(albedo, vec3(0.2126, 0.7152, 0.0722));
			return albedo * (direct + bounce) + albedo * (emissive_luma / max(luma, 1e-3));
		}
	]]
end

function radiance_cascades.GetShadowGLSL(block_name)
	return directional_shadows.GetSurfaceDirectionalShadowGLSL(
		block_name,
		"calculateShadow",
		{use_receiver_plane_bias = false}
	)
end

local function rebuild_pipelines()
	import.loaded[import:ResolvePath("goluwa/render3d/passes/radiance_cascades.lua")] = nil
	render3d.Initialize()
end

commands.Add("radiance_cascades=boolean[true]", function(enabled)
	radiance_cascades.enabled = enabled ~= false
	logf(
		"[radiance_cascades] %s\n",
		radiance_cascades.enabled and "enabled" or "disabled"
	)
end)

commands.Add("radiance_cascades_interval=number[0]", function(length)
	radiance_cascades.BASE_INTERVAL = length > 0 and length or nil
	logf(
		"[radiance_cascades] base interval %f, reach %f\n",
		radiance_cascades.GetBaseInterval(),
		select(2, radiance_cascades.GetInterval(radiance_cascades.CASCADE_COUNT - 1))
	)
end)

commands.Add("radiance_cascades_bias=number[1.5]", function(bias)
	radiance_cascades.NORMAL_BIAS = bias
end)

commands.Add("radiance_cascades_feedback=number[1]", function(strength)
	radiance_cascades.FEEDBACK_STRENGTH = strength
end)

commands.Add("radiance_cascades_steps=number[96]", function(steps)
	radiance_cascades.MAX_TRACE_STEPS = math.floor(steps)
end)

commands.Add("radiance_cascades_scale=number[0.5]", function(scale)
	radiance_cascades.SCREEN_SCALE = scale
	logf("[radiance_cascades] screen scale %f, rebuilding pipelines\n", scale)
	rebuild_pipelines()
end)

commands.Add("radiance_cascades_denoise=number[1]", function(strength)
	radiance_cascades.DENOISE = strength
	logf("[radiance_cascades] denoise %f\n", strength)
end)

commands.Add("radiance_cascades_jitter=number[1]", function(strength)
	radiance_cascades.JITTER = math.clamp(strength, 0, 1)
	logf("[radiance_cascades] direction jitter %f\n", radiance_cascades.JITTER)
end)

commands.Add("radiance_cascades_temporal=number[0.98]", function(blend)
	radiance_cascades.TEMPORAL_BLEND = math.clamp(blend, 0, 0.99)
	logf("[radiance_cascades] temporal blend %f\n", radiance_cascades.TEMPORAL_BLEND)
end)

commands.Add("radiance_cascades_world_bounce=number[1]", function(strength)
	local was_on = radiance_cascades.WORLD_BOUNCE
	radiance_cascades.WORLD_BOUNCE_STRENGTH = strength
	radiance_cascades.WORLD_BOUNCE = strength > 0

	-- the probe update is a pass of its own, so turning the bounce on or off
	-- changes the pass list rather than just a uniform
	if was_on ~= radiance_cascades.WORLD_BOUNCE then
		logf("[radiance_cascades] world bounce %s, rebuilding pipelines\n", strength > 0 and "on" or "off")
		rebuild_pipelines()
	else
		logf("[radiance_cascades] world bounce strength %f\n", strength)
	end
end)

commands.Add("radiance_cascades_backend=string[voxel]", function(backend)
	if backend ~= "voxel" and backend ~= "bvh" then
		error("backend must be voxel or bvh", 2)
	end

	radiance_cascades.BACKEND = backend

	-- switching backend by hand is an explicit request, so the tree is built
	-- now rather than waiting for the scene to settle the way a load does
	if backend == "bvh" then scene_bvh.Build() end

	logf("[radiance_cascades] %s backend, rebuilding pipelines\n", backend)
	rebuild_pipelines()
end)

commands.Add("radiance_cascades_count=number[6]", function(count)
	radiance_cascades.CASCADE_COUNT = math.floor(count)
	logf("[radiance_cascades] %d cascades, rebuilding pipelines\n", radiance_cascades.CASCADE_COUNT)
	rebuild_pipelines()
end)

return radiance_cascades
