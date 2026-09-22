local commands = import("goluwa/cli/commands.lua")
local system = import("goluwa/system.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local scene_lights = import("goluwa/render3d/scene_lights.lua")
local directional_shadows = import("goluwa/render3d/directional_shadows.lua")
local voxel_gi = import("goluwa/render3d/voxels/global_illumination.lua")
local scene_bvh = import("goluwa/render3d/scene_bvh.lua")
local light_occlusion = import("goluwa/render3d/light_occlusion.lua")
local screen_reconstruct = import("goluwa/render3d/screen_reconstruct.lua")
local radiance_cascades = library()
local MAX_CLIPMAPS = voxel_gi.GetMaxClipmapCount()
radiance_cascades.BACKEND = "bvh"
radiance_cascades.CASCADE_COUNT = 6
radiance_cascades.INTERVAL_SCALE = 4
radiance_cascades.PROBES_PER_AXIS = 128
radiance_cascades.DIRECTIONS_PER_AXIS = 4
radiance_cascades.DIRECTION_COUNT = radiance_cascades.DIRECTIONS_PER_AXIS * radiance_cascades.DIRECTIONS_PER_AXIS
radiance_cascades.VOLUME_EXTENT = 50.0
radiance_cascades.MAX_TRACE_STEPS = 96
radiance_cascades.BVH_NORMAL_BIAS = 0.02
radiance_cascades.SKY_INTENSITY = 1
radiance_cascades.DENOISE = 1
radiance_cascades.DENOISE_RADIUS = 2
radiance_cascades.DENOISE_STRIDE = 3
-- Second bounce taken from the voxel gi's probe cascades.
radiance_cascades.WORLD_BOUNCE_STRENGTH = 1
radiance_cascades.VISIBILITY_MERGE = true
radiance_cascades.VISMERGE_BIAS = 0.001
radiance_cascades.VISMERGE_RANGE = 1
-- resolve gather offset along the surface normal, in probe spacings
radiance_cascades.NORMAL_BIAS = 0.5
radiance_cascades.BOUNCE = 1
radiance_cascades.RESOLVE_SCALE = 1.0
-- how much of the reprojected previous frame to keep. the resolve only gathers
-- 16 directions from 8 probes, so the per-pixel estimate is grainy; accumulating
-- it over frames is what buys the sample count back
radiance_cascades.TEMPORAL = 0.9
radiance_cascades.enabled = true

-- The final resolved GI for the screen, taken from the last stage of the chain
-- that actually exists: denoise, else temporal, else the raw resolve. Consumers
-- used to reach into render3d.pipelines themselves and pick wrong when a stage
-- was disabled -- one of them called a GetResolveFramebufferIndex that had never
-- existed, which would have been a nil call the moment denoise was turned off.
function radiance_cascades.GetScreenTexture()
	local denoise = render3d.pipelines.radiance_cascades_denoise

	if denoise then return denoise:GetFramebuffer(1):GetAttachment(1) end

	local temporal = render3d.pipelines.radiance_cascades_temporal

	if temporal then
		return temporal:GetFramebuffer(radiance_cascades.GetTemporalFramebufferIndex()):GetAttachment(1)
	end

	local resolve = render3d.pipelines.radiance_cascades_resolve

	if resolve then return resolve:GetFramebuffer(1):GetAttachment(1) end

	return nil
end

-- the temporal pass ping-pongs two framebuffers, this is the one written (and
-- therefore read by everything downstream) this frame
function radiance_cascades.GetTemporalFramebufferIndex()
	return system.GetFrameNumber() % 2 + 1
end

-- Cascade 0's rays have to reach at least as far as the next probe, otherwise
-- almost all of them terminate in empty space and inherit the coarse cascades'
-- radiance instead -- and those probes are far enough apart to sit on the other
-- side of a wall, which is how a sealed room fills with outdoor light. Tying the
-- interval to the probe spacing is the invariant the cascade hierarchy is built
-- on; the diagonal of a probe cell is sqrt(3) spacings, so cover that.
function radiance_cascades.GetBaseInterval()
	if radiance_cascades.BASE_INTERVAL then
		return radiance_cascades.BASE_INTERVAL
	end

	return radiance_cascades.GetProbeSpacing() * 2
end

function radiance_cascades.GetInterval(cascade)
	local base = radiance_cascades.GetBaseInterval()
	local scale = radiance_cascades.INTERVAL_SCALE

	if cascade == 0 then return 0, base end

	return base * scale ^ (cascade - 1), base * scale ^ cascade
end

function radiance_cascades.GetProbesPerAxis(cascade)
	return math.max(2, math.floor(radiance_cascades.PROBES_PER_AXIS / (2 ^ (cascade or 0))))
end

function radiance_cascades.GetProbeSpacing()
	return 2 * radiance_cascades.VOLUME_EXTENT / radiance_cascades.GetProbesPerAxis(0)
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
		{"lights", scene_lights.BuildLightsBlockLayout(), scene_lights.MAX_LIGHTS},
		{"light_count", "int"},
		{"shadows", scene_lights.BuildShadowsBlockLayout()},
		light_occlusion.GetBlockLayout(),
		{"rc_sun_direction", "vec4"},
		{"rc_sun_radiance", "vec4"},
		{"rc_env_tex", "int"},
		{"rc_env_irradiance_tex", "int"},
		{"rc_enabled", "int"},
		{"rc_clipmap_count", "int"},
		{"rc_clip_origin", "vec4", MAX_CLIPMAPS},
		{"rc_clip_params", "vec4", MAX_CLIPMAPS},
		{"rc_base_interval", "float"},
		{"rc_interval_scale", "float"},
		{"rc_max_steps", "int"},
		{"rc_min_clipmap", "int"},
		{"rc_sky_intensity", "float"},
		{"rc_world_bounce", "float"},
		{"rc_vismerge", "float"},
		{"rc_vismerge_bias", "float"},
		{"rc_vismerge_range", "float"},
		{"rc_normal_bias", "float"},
		{"rc_bounce", "float"},
		{"rc_feedback_probes", "int"},
		{"rc_feedback_camera", "vec4"},
		{"rc_denoise", "float"},
		{"rc_frame", "int"},
		{"gi", voxel_gi.GetBlockLayout()},
	}
end

-- The feedback volume is a persistent texture indexed by a bare slot number:
-- the bounce pass stores probe P at texel P and records no world position at
-- all. The slot's world position is implied by the grid origin in force when it
-- was written, so a reader using the *current* origin is reading a lattice that
-- has moved out from under the data. The origin snaps to the camera every
-- 0.78 m of travel, and each snap slides the whole cached field one cell
-- sideways for a frame -- interior light visibly pushed out through the walls,
-- then pulled back once the pass refills it.
--
-- So hand the shader the lattice the data was actually written on. Both origins
-- are floor()*spacing, so the correction is a whole number of cells and the
-- remap is exact -- no resampling, no blur.
--
-- What gets snapshotted is the very same camera_position the block already
-- carries, rather than a camera accessor re-read here: the shader derives the
-- lattice from that field, so anything else risks disagreeing with it, and a
-- disagreement is worse than the bug being fixed -- the lookup lands outside the
-- volume, most of the eight taps drop out, and acc/wsum renormalizes whatever
-- survives back up to full brightness.
local feedback_frame = nil
local feedback_seeded = false
local feedback_camera_current = {x = 0, y = 0, z = 0}
local feedback_camera_previous = {x = 0, y = 0, z = 0}

local function advance_feedback_camera(block)
	local frame = system.GetFrameNumber()

	if feedback_frame ~= frame then
		feedback_frame = frame
		feedback_camera_previous, feedback_camera_current = feedback_camera_current, feedback_camera_previous
		feedback_camera_current.x = block.camera_position[0]
		feedback_camera_current.y = block.camera_position[1]
		feedback_camera_current.z = block.camera_position[2]

		if not feedback_seeded then
			-- nothing written yet, so there is no older lattice to correct back
			-- to; the texture reads a = 0 on that first frame anyway
			feedback_camera_previous.x = feedback_camera_current.x
			feedback_camera_previous.y = feedback_camera_current.y
			feedback_camera_previous.z = feedback_camera_current.z
			feedback_seeded = true
		end
	end

	return feedback_camera_previous
end

function radiance_cascades.WriteBlock(self, block, cascade)
	render3d.WriteCameraBlock(self, block)
	render3d.WriteGBufferBlock(self, block)
	local lights, light_instance_indices = scene_lights.GetVisibleLights()
	block.light_count = math.min(#lights, scene_lights.MAX_LIGHTS)
	scene_lights.WriteLightsBlock(block.lights, lights)
	scene_lights.WriteShadowBlock(self, block.shadows, lights)
	light_occlusion.WriteOcclusionBlock(block, lights, light_instance_indices)
	local sun_direction = directional_shadows.GetPrimarySunDirection(lights)
	local sun_color = directional_shadows.GetPrimarySunColor(lights)
	local sun_illuminance = directional_shadows.GetPrimarySunIlluminance(lights)
	sun_direction:CopyToFloatPointer(block.rc_sun_direction)
	block.rc_sun_direction[3] = 0
	block.rc_sun_radiance[0] = sun_color.x * sun_illuminance
	block.rc_sun_radiance[1] = sun_color.y * sun_illuminance
	block.rc_sun_radiance[2] = sun_color.z * sun_illuminance
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
	block.rc_base_interval = radiance_cascades.GetBaseInterval()
	block.rc_interval_scale = radiance_cascades.INTERVAL_SCALE
	block.rc_max_steps = radiance_cascades.MAX_TRACE_STEPS
	block.rc_min_clipmap = math.min(cascade, math.max(clipmap_count - 1, 0))
	block.rc_sky_intensity = radiance_cascades.SKY_INTENSITY
	block.rc_denoise = radiance_cascades.DENOISE
	block.rc_frame = system.GetFrameNumber() % 4096
	block.rc_world_bounce = radiance_cascades.WORLD_BOUNCE_STRENGTH
	block.rc_vismerge = radiance_cascades.VISIBILITY_MERGE and 1 or 0
	block.rc_vismerge_bias = radiance_cascades.VISMERGE_BIAS
	block.rc_vismerge_range = radiance_cascades.VISMERGE_RANGE
	block.rc_normal_bias = radiance_cascades.NORMAL_BIAS
	block.rc_bounce = radiance_cascades.BOUNCE
	block.rc_feedback_probes = radiance_cascades.GetProbesPerAxis(0)

	do
		local camera_position = advance_feedback_camera(block)
		block.rc_feedback_camera[0] = camera_position.x
		block.rc_feedback_camera[1] = camera_position.y
		block.rc_feedback_camera[2] = camera_position.z
		block.rc_feedback_camera[3] = 0
	end

	voxel_gi.WriteBlock(self, block.gi)
	return block
end

function radiance_cascades.GetCommonGLSL(probes_per_axis)
	probes_per_axis = probes_per_axis or radiance_cascades.PROBES_PER_AXIS
	return [[
		vec3 rc_oct_decode(vec2 uv) {
			vec2 p = uv * 2.0 - 1.0;
			vec3 n = vec3(p.x, p.y, 1.0 - abs(p.x) - abs(p.y));

			if (n.z < 0.0) {
				n.xy = (1.0 - abs(n.yx)) * vec2(p.x >= 0.0 ? 1.0 : -1.0, p.y >= 0.0 ? -1.0 : 1.0);
			}

			return normalize(n);
		}

		const int RC_PROBES_PER_AXIS = ]] .. probes_per_axis .. [[;
		const int RC_DIRECTION_COUNT = ]] .. radiance_cascades.DIRECTION_COUNT .. [[;
		const float RC_VOLUME_EXTENT = ]] .. radiance_cascades.VOLUME_EXTENT .. [[;
		const float RC_SPACING = 2.0 * RC_VOLUME_EXTENT / float(RC_PROBES_PER_AXIS);

		vec3 rc_grid_origin() {
			return floor((rc_data.camera_position.xyz - vec3(RC_VOLUME_EXTENT)) / RC_SPACING) * RC_SPACING;
		}

		float rc_interval_end(int c) {
			return rc_data.rc_base_interval * pow(rc_data.rc_interval_scale, float(c));
		}

		vec3 rc_probe_world_pos(ivec3 probe_idx) {
			return rc_grid_origin() + (vec3(probe_idx) + 0.5) * RC_SPACING;
		}

		int rc_probe_index(ivec3 probe_idx) {
			return probe_idx.x + RC_PROBES_PER_AXIS * (probe_idx.y + RC_PROBES_PER_AXIS * probe_idx.z);
		}

		ivec3 rc_probe_coords(int index) {
			return ivec3(
				index % RC_PROBES_PER_AXIS,
				(index / RC_PROBES_PER_AXIS) % RC_PROBES_PER_AXIS,
				index / (RC_PROBES_PER_AXIS * RC_PROBES_PER_AXIS)
			);
		}

		ivec2 rc_texel_coord(ivec3 probe_idx, int dir_idx) {
			return ivec2(
				probe_idx.x + RC_PROBES_PER_AXIS * probe_idx.y,
				probe_idx.z * RC_DIRECTION_COUNT + dir_idx
			);
		}
	]]
end

function radiance_cascades.GetProbeGLSL(block_name)
	return screen_reconstruct.GetWorldPosFromUVGLSL(block_name, {function_name = "rc_reconstruct_world_pos"}) .. (
			[[
		float rc_probe_depth(vec2 uv) {
			return texture(TEXTURE(%s.depth_tex), uv).r;
		}

		vec3 rc_probe_normal(vec2 uv) {
			vec3 n = texture(TEXTURE(%s.normal_tex), uv).xyz * 2.0 - 1.0;
			float len = length(n);
			return len > 1e-4 ? n / len : vec3(0.0, 1.0, 0.0);
		}

		float rc_linear_depth(float depth) {
			return %s.projection[3][2] / (depth + %s.projection[2][2]);
		}
	]]
		):format(block_name, block_name, block_name, block_name)
end

function radiance_cascades.GetTraceGLSL(block_name)
	local fetch = {}

	for i = 0, MAX_CLIPMAPS - 1 do
		fetch[#fetch + 1] = "\tif (c == " .. i .. ") return texelFetch(rc_volume_" .. i .. ", ivec3(v.xy, v.z), 0);"
	end

	local fetch_normal = {}

	for i = 0, MAX_CLIPMAPS - 1 do
		fetch_normal[#fetch + 1] = "\tif (c == " .. i .. ") return texelFetch(rc_normal_" .. i .. ", ivec3(v.xy, v.z), 0).xyz;"
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
			).rgb * RC_BLOCK.rc_sky_intensity;
		}

		// second bounce for a traced hit. goes through the same cascade
		// compositing the lighting pass uses so the occlusion gating applies
		// here too, with a black fallback: a hit outside every probe cascade
		// contributes no bounce rather than inheriting the sky
		vec3 rc_world_bounce(vec3 pos, vec3 N) {
			float unused_sky_visibility;
			return sample_voxel_gi_irradiance(pos, N, N, vec3(0.0), unused_sky_visibility) *
				RC_BLOCK.rc_world_bounce;
		}

		vec3 rc_shade_hit(rc_hit hit) {
			vec3 N = hit.normal;
			float voxel_size = rc_clip_voxel_size(max(hit.clipmap, 0));
			vec3 surface_pos = hit.position + N * ]] .. (
			radiance_cascades.BACKEND == "bvh" and
			"0.02" or
			"(voxel_size * 0.5)"
		) .. [[;
			vec3 L = normalize(RC_BLOCK.rc_sun_direction.xyz);
			float NoL = max(dot(N, L), 0.0);
			float shadow = RC_BLOCK.shadows.shadow_map_indices[0] >= 0 ? 1.0 : 0.0;

			if (NoL > 0.0 && RC_BLOCK.shadows.shadow_map_indices[0] >= 0) {
				shadow = calculateShadow(surface_pos, N, L);
			}

			vec3 albedo = hit.voxel.rgb;
			vec3 direct = RC_BLOCK.rc_sun_radiance.rgb * (NoL * shadow / 3.14159265359);

			for (int i = 0; i < RC_BLOCK.light_count; i++) {
				lights_t light = RC_BLOCK.lights[i];
				int light_type = get_light_type(light);

				if (light_type == 0) continue;

				vec3 light_to_surface;
				float light_attenuation;

				if (!get_light_vector_and_attenuation(light, surface_pos, light_to_surface, light_attenuation)) {
					continue;
				}

				float light_NoL = max(dot(N, light_to_surface), 0.0);

				if (light_NoL <= 0.0) continue;

				float light_shadow = 1.0;

				if (light_type == 2) {
					if (
						i == RC_BLOCK.shadows.local_directional_shadow_light_index &&
						RC_BLOCK.shadows.local_directional_shadow_map_index >= 0
					) {
						light_shadow = calculateLocalDirectionalShadow(surface_pos, N, light_to_surface);
					}
				} else {
					int point_shadow_slot = getPointShadowSlot(i);

					if (point_shadow_slot >= 0) {
						light_shadow = calculatePointShadow(point_shadow_slot, surface_pos, N, light_to_surface);
					}

					light_shadow *= light_oct_shadow_factor(
						RC_BLOCK.bvh_oct_slot[i],
						light.position.xyz,
						light.params.x,
						surface_pos
					);
				}

				if (light_shadow > 0.0) {
					direct += light.color.rgb * light.color.a * light_attenuation * light_shadow *
						(light_NoL / 3.14159265359);
				}
			}

			vec3 bounce = rc_world_bounce(surface_pos, N);
			float emissive_luma = max(hit.voxel.a - 1.0, 0.0) * 4.0;
			float luma = dot(albedo, vec3(0.2126, 0.7152, 0.0722));
			return albedo * (direct + bounce) + albedo * (emissive_luma / max(luma, 1e-3));
		}
	]]
end

function radiance_cascades.GetShadowGLSL(block_name)
	return directional_shadows.GetSurfaceDirectionalShadowGLSL(block_name, "calculateShadow")
end

function radiance_cascades.GetLightGLSL(block_name)
	return (
			scene_lights.GetLightGLSLCode() .. "\n" .. directional_shadows.GetLocalDirectionalShadowGLSL(block_name) .. "\n" .. scene_lights.GetPointShadowGLSL(block_name) .. "\n" .. light_occlusion.GetSamplingGLSL(block_name)
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

commands.Add("rc_sky=number[1]", function(intensity)
	radiance_cascades.SKY_INTENSITY = intensity
	logf("[radiance_cascades] sky intensity %f\n", intensity)
end)

commands.Add("radiance_cascades_steps=number[96]", function(steps)
	radiance_cascades.MAX_TRACE_STEPS = math.floor(steps)
end)

commands.Add("radiance_cascades_denoise=number[1]", function(strength)
	radiance_cascades.DENOISE = strength
	logf("[radiance_cascades] denoise %f\n", strength)
end)

commands.Add("radiance_cascades_world_bounce=number[1]", function(strength)
	radiance_cascades.WORLD_BOUNCE_STRENGTH = math.max(strength, 0)
	logf(
		"[radiance_cascades] world bounce strength %f\n",
		radiance_cascades.WORLD_BOUNCE_STRENGTH
	)
end)

commands.Add("radiance_cascades_vismerge=boolean[true]", function(enabled)
	radiance_cascades.VISIBILITY_MERGE = enabled ~= false
	logf(
		"[radiance_cascades] visibility merge %s\n",
		radiance_cascades.VISIBILITY_MERGE and "on" or "off"
	)
end)

commands.Add("radiance_cascades_vismerge_bias=number[0.001]", function(value)
	radiance_cascades.VISMERGE_BIAS = math.max(value, 0)
	logf("[radiance_cascades] vismerge bias %f\n", radiance_cascades.VISMERGE_BIAS)
end)

commands.Add("radiance_cascades_vismerge_range=number[0.5]", function(value)
	radiance_cascades.VISMERGE_RANGE = math.clamp(value, 0.01, 1.0)
	logf("[radiance_cascades] vismerge range %f\n", radiance_cascades.VISMERGE_RANGE)
end)

commands.Add("radiance_cascades_normal_bias=number[0.5]", function(value)
	radiance_cascades.NORMAL_BIAS = math.max(value, 0)
	logf("[radiance_cascades] normal bias %f spacings\n", radiance_cascades.NORMAL_BIAS)
end)

commands.Add("radiance_cascades_temporal=number[0.9]", function(value)
	radiance_cascades.TEMPORAL = math.clamp(value, 0, 0.98)
	logf("[radiance_cascades] temporal blend %f\n", radiance_cascades.TEMPORAL)
end)

commands.Add("radiance_cascades_bounce=number[0]", function(value)
	radiance_cascades.BOUNCE = math.clamp(value, 0.0, 0.95)
	logf("[radiance_cascades] bounce feedback %f\n", radiance_cascades.BOUNCE)
end)

commands.Add("radiance_cascades_backend=string[bvh]", function(backend)
	if backend ~= "voxel" and backend ~= "bvh" then
		error("backend must be voxel or bvh", 2)
	end

	radiance_cascades.BACKEND = backend

	if backend == "bvh" then scene_bvh.Build() end

	logf("[radiance_cascades] %s backend, rebuilding pipelines\n", backend)
	rebuild_pipelines()
end)

commands.Add("radiance_cascades_count=number[6]", function(count)
	radiance_cascades.CASCADE_COUNT = math.floor(count)
	logf("[radiance_cascades] %d cascades, rebuilding pipelines\n", count)
	rebuild_pipelines()
end)

commands.Add("radiance_cascades_probes=number[16]", function(count)
	radiance_cascades.PROBES_PER_AXIS = math.clamp(math.floor(count), 4, 64)
	logf(
		"[radiance_cascades] %d probes per axis, rebuilding pipelines\n",
		radiance_cascades.PROBES_PER_AXIS
	)
	rebuild_pipelines()
end)

commands.Add("radiance_cascades_extent=number[10]", function(extent)
	radiance_cascades.VOLUME_EXTENT = math.max(extent, 1)
	logf(
		"[radiance_cascades] volume extent %f, rebuilding pipelines\n",
		radiance_cascades.VOLUME_EXTENT
	)
	rebuild_pipelines()
end)

return radiance_cascades
