local ray_materials = import("goluwa/render3d/scene/ray_materials.lua")
local assets = import("goluwa/assets.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local atmosphere = import("goluwa/render3d/atmosphere.lua")
local directional_shadows = import("goluwa/render3d/directional_shadows.lua")
local scene_lights = import("goluwa/render3d/scene_lights.lua")
local ibl = import("goluwa/render3d/ibl.lua")
local envprobe = import("goluwa/render3d/envprobe.lua")
local light_occlusion = import("goluwa/render3d/light_occlusion.lua")
local light_grid = import("goluwa/render3d/light_grid.lua")
local post_source = import("goluwa/render3d/post_source.lua")
local gi = import("goluwa/render3d/gi.lua")
local optical_rays = import("goluwa/render3d/optical_rays.lua")
local surface_features = import("goluwa/render3d/surface_features.lua")
local scene_instances = import("goluwa/render3d/scene/instances.lua")
local scene_hit = import("goluwa/render3d/scene/hit.lua")
local RAY_ESCAPE = 0.1
local medium_common = import("goluwa/render3d/medium_common.lua")
local media = import("goluwa/render3d/media.lua")
local pvars = import("goluwa/cli/pvars.lua")
local indirect_look = import("goluwa/render3d/indirect_look.lua")
local glsl_common = import("goluwa/render3d/glsl_common.lua")
local caustics = import("goluwa/render3d/caustics.lua")
local surface_lighting = {}
pvars.StartGroup("Lighting", "Ray traced shadows", {store = false, prefix = "r_ray_shadow_"})
local ray_shadows = pvars.Setup2{
	key = "r_ray_shadows",
	friendly = "enabled",
	default = false,
	help = "shadow every light with rays toward a point on the light (the sun's disc, a sphere of the light's source radius) instead of shadow maps, light occlusion maps and screen space shadows. built into the lighting shaders",
	callback = function(value, initial)
		if initial then return end

		render3d.ReloadPasses(surface_lighting.PASS_PATHS)
	end,
}
local ray_shadow_samples = pvars.Setup2{
	key = "r_ray_shadow_samples",
	default = 1,
	integer = true,
	help = "rays per light and pixel toward a light with a size, a light without one always takes one",
}
pvars.EndGroup()
surface_lighting.PASS_PATHS = {
	"goluwa/render3d/passes/ray_shadows.lua",
	"goluwa/render3d/passes/lighting.lua",
	"goluwa/render3d/passes/translucent.lua",
	"goluwa/render3d/passes/path_trace.lua",
}
surface_lighting.block = {
	render3d.camera_block,
	{"lights", "uint64_t"},
	{"light_count", "int"},
	{"shadows", scene_lights.BuildShadowsBlockLayout()},
	{"env_tex", "int"},
	{"brdf_lut_tex", "int"},
	render3d.common_block,
	light_occlusion.GetBlockLayout(),
	{"primary_sun_illuminance", "float"},
	{"primary_sun_color", "vec4"},
	{"primary_sun_direction", "vec4"},
	atmosphere.GetBlockLayout(),
	{"env_irradiance_tex", "int"},
	{"env_position", "vec4"},
	envprobe.GetProbeBlockLayout(),
	{"gi_screen_tex", "int"},
	{"gi_screen_geometry_tex", "int"},
	{"gi_screen_specular_tex", "int"},
	{"gi_gain", "float"},
	{"gi_contrast", "float"},
	{"gi_contrast_pivot", "float"},
	{"gi_saturation", "float"},
	{"light_transmittance", "int"},
	{"caustics", "int"},
	caustics.coverage_block,
	{"optical_tint", "int"},
	{"medium_thickness", "float"},
	{"medium_base_height", "float"},
	{"medium_thickness_per_height", "float"},
	{"medium_cover_slope", "float"},
	{"medium_porosity_low", "float"},
	{"medium_porosity_high", "float"},
	{"medium_noise_phase", "float"},
	{"medium_local_thickness", "float"},
	{"ray_shadow_samples", "int"},
	{"ray_shadow_noise_tex", "int"},
	{"ray_shadow_frame", "int"},
	{"ray_shadow_tex", "int"},
	{"medium_slots", "vec4", (
		media.MAX_SLOTS + 1
	) * media.SLOT_STRIDE},
	post_source.pre_exposure_block,
}

function surface_lighting.WriteBlock(self, block)
	render3d.WriteCameraBlock(self, block)
	local lights = render3d.GetLights()
	block.lights = scene_lights.GetAddress(lights)
	block.light_count = #lights
	scene_lights.WriteShadowBlock(self, block.shadows, lights)
	block.env_tex = self:GetTextureIndex(render3d.GetEnvironmentTexture())
	block.brdf_lut_tex = self:GetTextureIndex(
		assert(
			assets.GetTexture("textures/render/brdf_lut.lua"),
			"the brdf lut texture is not registered"
		)
	)
	render3d.WriteCommonBlock(self, block)
	light_occlusion.WriteOcclusionBlock(block)
	local primary_sun = directional_shadows.GetPrimarySun(lights)
	local sun_direction = directional_shadows.GetPrimarySunDirection(lights)
	sun_direction:CopyToFloatPointer(block.primary_sun_direction)
	block.primary_sun_illuminance = directional_shadows.GetPrimarySunIlluminance(lights)
	block.primary_sun_color[0] = primary_sun and primary_sun.Color.x or 1
	block.primary_sun_color[1] = primary_sun and primary_sun.Color.y or 1
	block.primary_sun_color[2] = primary_sun and primary_sun.Color.z or 1
	block.primary_sun_color[3] = 0
	local environment = render3d.GetEnvironment()

	if environment then
		atmosphere.WriteDisabledBlock(self, block, environment:GetSourceTexture(), environment:GetIntensity())
	else
		atmosphere.WriteBlock(self, block, render3d.GetCamera():GetPosition(), sun_direction)
	end

	block.env_irradiance_tex = self:GetTextureIndex(render3d.GetEnvironmentIrradianceTexture())
	local environment_probe = envprobe.environment_probe
	local env_position = environment_probe and
		environment_probe.position or
		render3d.GetCamera():GetPosition()
	block.env_position[0] = env_position.x
	block.env_position[1] = env_position.y
	block.env_position[2] = env_position.z
	envprobe.WriteProbeBlock(self, block)
	local gi_texture = gi.GetScreenTexture()
	block.gi_screen_tex = gi_texture and self:GetTextureIndex(gi_texture) or -1
	local gi_geometry_texture = gi.GetScreenGeometryTexture()
	block.gi_screen_geometry_tex = gi_geometry_texture and self:GetTextureIndex(gi_geometry_texture) or -1
	local gi_specular_texture = gi.GetScreenSpecularTexture()
	block.gi_screen_specular_tex = gi_specular_texture and self:GetTextureIndex(gi_specular_texture) or -1
	block.gi_gain = indirect_look.gain:Get()
	block.gi_contrast = indirect_look.contrast:Get()
	block.gi_contrast_pivot = indirect_look.contrast_pivot:Get()
	block.gi_saturation = indirect_look.saturation:Get()
	block.light_transmittance = (optical_rays.IsEnabled() and ray_materials.HasDirectTint()) and 1 or 0
	block.caustics = 0
	caustics.WriteCoverageBlock(block)
	block.optical_tint = (
			optical_rays.IsEnabled() and
			(
				ray_materials.HasGlass() or
				ray_materials.HasMedium()
			)
		)
		and
		1 or
		0
	block.ray_shadow_samples = ray_shadow_samples:Get()
	block.ray_shadow_noise_tex = self:GetTextureIndex(
		assert(
			assets.GetTexture("textures/render/blue_noise.lua"),
			"the blue noise texture is not registered"
		)
	)
	block.ray_shadow_frame = render3d.GetTemporalFrame()
	block.ray_shadow_tex = -1
	block.medium_thickness = medium_common.assumed_thickness
	block.medium_base_height = medium_common.base_height
	block.medium_thickness_per_height = medium_common.thickness_per_height
	block.medium_cover_slope = medium_common.cover_slope
	block.medium_porosity_low = medium_common.porosity_low
	block.medium_porosity_high = medium_common.porosity_high
	block.medium_noise_phase = render3d.GetNoisePhase()
	block.medium_local_thickness = medium_common.local_thickness and 1 or 0
	media.WriteSlots(block.medium_slots)
	post_source.WritePreExposureBlock(self, block)
	return block
end

function surface_lighting.UsesRayShadows()
	return ray_shadows:Get()
end

function surface_lighting.GetDeclarationGLSL(grid_binding, occlusion_binding)
	return light_occlusion.GetDeclarationGLSL(occlusion_binding) .. light_grid.GetGLSL(grid_binding)
end

local function light_limit_glsl(block_name, light_limit)
	if not light_limit then return "", "" end

	local last = light_limit - 1
	local insert = {}

	for k = last, 1, -1 do
		insert[#insert + 1] = string.format(
			"if (light_limit_top[%d] > light_limit_top[%d]) { float swap = light_limit_top[%d]; light_limit_top[%d] = light_limit_top[%d]; light_limit_top[%d] = swap; }",
			k,
			k - 1,
			k - 1,
			k - 1,
			k,
			k
		)
	end

	local select = [[
		float light_limit_cut = 0.0;
		{
			float light_limit_top[]] .. light_limit .. [[] = float[]] .. light_limit .. [[](]] .. (
			"0.0, "
		):rep(light_limit - 1) .. [[0.0);

			for (int w = 0; w < light_grid_words(]] .. block_name .. [[.light_count); w++) {
				uint light_bits = light_grid_word(light_cell, w, ]] .. block_name .. [[.light_count);

				while (light_bits != 0u) {
					int i = w * 32 + findLSB(light_bits);
					light_bits &= light_bits - 1u;
					lights_t light = scene_light(]] .. block_name .. [[.lights, i);

					if (get_light_type(light) == 0) continue;

					vec3 L;
					float attenuation = 1.0;

					if (!get_light_vector_and_attenuation(light, s.world_pos, L, attenuation)) continue;

					if ((dot(s.N, L) <= 0.0 || dot(s.vertex_N, L) <= 0.0) && !(]] .. surface_features.GetLitFromBehindExpressionGLSL() .. [[)) continue;

					vec3 radiance = light.color.rgb * light.color.a * attenuation;
					float weight = max(max(radiance.r, radiance.g), radiance.b);

					if (weight > light_limit_top[]] .. last .. [[]) {
						light_limit_top[]] .. last .. [[] = weight;
						]] .. table.concat(insert, "\n\t\t\t\t\t\t") .. [[
					}
				}
			}

			light_limit_cut = light_limit_top[]] .. last .. [[];
		}
	]]
	local skip = "if (type != 0 && max(max(unshadowed_radiance.r, unshadowed_radiance.g), unshadowed_radiance.b) < light_limit_cut) continue;"
	return select, skip
end

function surface_lighting.GetGLSL(block_name, ray_queries, light_limit)
	local light_limit_select, light_limit_skip = light_limit_glsl(block_name, light_limit)
	return "#define SURFACE_RAY_SHADOWS " .. (
			(
				ray_queries and
				ray_shadows:Get()
			) and
			"1" or
			"0"
		) .. "\n" .. atmosphere.GetGLSLDefines(block_name, block_name .. ".primary_sun_illuminance") .. atmosphere.GetGLSLCode() .. post_source.GetPreExposureGLSL(block_name) .. [[
		]] .. ibl.GetBRDFGLSLCode() .. [[

		]] .. ibl.GetEnvironmentGLSLCode() .. [[

		]] .. ibl.GetProbeReflectionGLSLCode(block_name) .. [[

		]] .. scene_lights.GetLightGLSLCode() .. [[

		]] .. light_occlusion.GetSamplingGLSL(block_name) .. [[

		]] .. directional_shadows.GetSurfaceDirectionalShadowGLSL(block_name, "calculateShadow") .. [[

		]] .. scene_lights.GetPointShadowGLSL(block_name) .. [[

		]] .. directional_shadows.GetLocalDirectionalShadowGLSL(block_name) .. [[

		#ifndef OPTICAL_RAYS
		vec3 get_light_transmittance(vec3 origin, vec3 dir, float distance, float search_radius, bool local, bool caustic) {
			return vec3(1.0);
		}
		#endif

		]] .. caustics.GetCoverageGLSL(block_name) .. [[

		]] .. (
			ray_queries and
			scene_hit.GetEscapeGLSL("scene_tlas") or
			scene_hit.GetEscapeStubGLSL()
		) .. [[

		float get_sun_contact_visibility(vec3 origin, vec3 dir, float distance, bool leave_body) {
			]] .. (
			ray_queries and
			[[
			float start = 0.0;

			for (int attempt = 0; attempt < 2; attempt++) {
				rayQueryEXT query;
				rayQueryInitializeEXT(query, scene_tlas, leave_body ? gl_RayFlagsOpaqueEXT : gl_RayFlagsOpaqueEXT | gl_RayFlagsTerminateOnFirstHitEXT, ]] .. string.format("0x%02X", scene_instances.MASK_SOLID) .. [[, origin, start, dir, distance);
				while (rayQueryProceedEXT(query)) {}

				if (rayQueryGetIntersectionTypeEXT(query, true) == gl_RayQueryCommittedIntersectionNoneEXT) return 1.0;

				// see ray_shadow_visible: a ray that starts inside the body it leaves first meets that body's far side from within
				if (!leave_body || !rayQueryGetIntersectionFrontFaceEXT(query, true)) return 0.0;

				leave_body = false;
				start = rayQueryGetIntersectionTEXT(query, true) + 0.002;
			}

			return 0.0;
			]] or
			"return 1.0;"
		) .. [[
		}

		]] .. (
			ray_queries and
			ray_materials.GetShadowRayGLSL() .. glsl_common.GetHashGLSL() .. glsl_common.GetBlueNoiseGLSL() .. [[
			float get_ray_shadow_visibility(int i, int type, lights_t light, vec3 P, vec3 N, vec3 L, bool leave_body) {
				vec4 clip = ]] .. block_name .. [[.projection * (]] .. block_name .. [[.view * vec4(P, 1.0));
				ivec2 pixel = ivec2(floor((clip.xy / clip.w * 0.5 + 0.5) * ]] .. block_name .. [[.render_size));
				ivec2 noise_size = textureSize(TEXTURE(]] .. block_name .. [[.ray_shadow_noise_tex), 0);
				uvec3 tile_hash = pcg3d(uvec3(uvec2(pixel / noise_size), 0x9E3779B9u));
				vec2 noise = blue_noise_r2(blue_noise_texel(TEXTURE(]] .. block_name .. [[.ray_shadow_noise_tex), pixel).rg + vec2(pcg_unorm(tile_hash.x), pcg_unorm(tile_hash.y)), float(]] .. block_name .. [[.ray_shadow_frame % 64));
				vec3 side = dot(N, L) < 0.0 || leave_body ? -N : N;
				vec3 origin = scene_escape_tessellation(P + side * (0.0001 * ]] .. block_name .. [[.view_scale + 0.0001 * distance(P, ]] .. block_name .. [[.camera_position)), side, ]] .. string.format("%.3f", RAY_ESCAPE) .. [[ * ]] .. block_name .. [[.view_scale);
				vec3 axis = L;
				float one_minus_cos = 0.0;
				float center_distance = 0.0;

				if (type == 0) {
					one_minus_cos = 1.0 - cos(SUN_ANGULAR_RADIUS);
				} else if (type != 2) {
					center_distance = distance(light.position.xyz, origin);
					axis = (light.position.xyz - origin) / center_distance;
					float radius = light.direction.w;

					if (radius > 0.0 && center_distance > radius) {
						float sin2 = radius * radius / (center_distance * center_distance);
						one_minus_cos = sin2 / (1.0 + sqrt(1.0 - sin2));
					}
				}

				vec3 T = normalize(cross(abs(axis.y) < 0.99 ? vec3(0.0, 1.0, 0.0) : vec3(1.0, 0.0, 0.0), axis));
				vec3 B = cross(axis, T);
				int samples = one_minus_cos > 0.0 ? ]] .. block_name .. [[.ray_shadow_samples : 1;
				float visible = 0.0;

				for (int k = 0; k < samples; k++) {
					vec2 xi = blue_noise_r2(noise, float((i * samples + k) * 64));
					float cone = xi.x * one_minus_cos;
					float sin_theta = sqrt(max(cone * (2.0 - cone), 0.0));
					float phi = 6.2831853 * xi.y;
					vec3 dir = normalize(T * (sin_theta * cos(phi)) + B * (sin_theta * sin(phi)) + axis * (1.0 - cone));

					// a ray toward the part of a large light below the surface grazes the surface it starts on and hits it by rounding, as speckle
					if (dot(dir, side) <= 0.0) continue;

					float dist;

					if (type == 0) {
						dist = 1e6;
					} else if (type == 2) {
						dist = light.params.x;
					} else if (one_minus_cos > 0.0) {
						vec3 to_center = light.position.xyz - origin;
						float along = dot(to_center, dir);
						dist = along - sqrt(max(along * along - dot(to_center, to_center) + light.direction.w * light.direction.w, 0.0)) - 0.05 * ]] .. block_name .. [[.view_scale;
					} else {
						dist = center_distance - 0.05 * ]] .. block_name .. [[.view_scale;
					}

					if (dist <= 0.0 || ray_shadow_visible(origin, dir, dist, type == 0 ? 0u : ]] .. string.format("0x%02Xu", scene_instances.MASK_LIGHT_BODY) .. [[, leave_body)) visible += 1.0;
				}

				return visible / float(samples);
			}

			ivec2 ray_shadow_pixel = ivec2(-1);

			float get_ray_shadow_factor(int i, int type, lights_t light, vec3 P, vec3 N, vec3 L, bool leave_body) {
				if (ray_shadow_pixel.x < 0 || ]] .. block_name .. [[.ray_shadow_tex < 0) return get_ray_shadow_visibility(i, type, light, P, N, L, leave_body);

				vec4 filtered = texelFetch(TEXTURE(]] .. block_name .. [[.ray_shadow_tex), ray_shadow_pixel, 0);
				return type == 0 ? filtered.r : filtered.g;
			}
			]] or
			[[
			float get_ray_shadow_visibility(int i, int type, lights_t light, vec3 P, vec3 N, vec3 L, bool leave_body) {
				return 1.0;
			}

			float get_ray_shadow_factor(int i, int type, lights_t light, vec3 P, vec3 N, vec3 L, bool leave_body) {
				return 1.0;
			}
			]]
		) .. [[

		float get_medium_assumed_thickness(vec3 P) {
			return ]] .. block_name .. [[.medium_thickness + max(P.y - ]] .. block_name .. [[.medium_base_height, 0.0) * ]] .. block_name .. [[.medium_thickness_per_height;
		}

		vec4 get_medium_slot_extinction(int slot) {
			return ]] .. block_name .. [[.medium_slots[slot * ]] .. media.SLOT_STRIDE .. [[];
		}

		vec4 get_medium_slot_scattering(int slot) {
			return ]] .. block_name .. [[.medium_slots[slot * ]] .. media.SLOT_STRIDE .. [[ + 1];
		}

		vec3 get_medium_slot_porous_scattering(int slot) {
			return ]] .. block_name .. [[.medium_slots[slot * ]] .. media.SLOT_STRIDE .. [[ + 2].rgb;
		}

		vec3 get_medium_slot_tint_ratio(int slot) {
			return ]] .. block_name .. [[.medium_slots[slot * ]] .. media.SLOT_STRIDE .. [[ + 3].rgb;
		}

		vec3 get_medium_slot_deep_color(int slot) {
			return ]] .. block_name .. [[.medium_slots[slot * ]] .. media.SLOT_STRIDE .. [[ + 4].rgb;
		}

		vec3 get_medium_slot_porous_color(int slot) {
			return ]] .. block_name .. [[.medium_slots[slot * ]] .. media.SLOT_STRIDE .. [[ + 5].rgb;
		}

		float get_medium_porosity_low() {
			return ]] .. block_name .. [[.medium_porosity_low;
		}

		float get_medium_porosity_high() {
			return ]] .. block_name .. [[.medium_porosity_high;
		}

		float get_medium_use_local_thickness() {
			return ]] .. block_name .. [[.medium_local_thickness;
		}

		float get_medium_cover_slope() {
			return ]] .. block_name .. [[.medium_cover_slope;
		}

		]] .. optical_rays.GetMediumPathGLSL(ray_queries) .. [[

		float get_medium_local_thickness(vec3 P, vec3 N, vec3 G, float cap) {
			vec3 up = abs(N.y) < 0.99 ? vec3(0.0, 1.0, 0.0) : vec3(1.0, 0.0, 0.0);
			vec3 tangent = normalize(cross(up, N));
			vec3 bitangent = cross(N, tangent);
			vec3 origin = P - G * 0.02;
			uvec3 hash_v = floatBitsToUint(P) * 1664525u + 1013904223u;
			hash_v.x += hash_v.y * hash_v.z;
			hash_v.y += hash_v.z * hash_v.x;
			hash_v.z += hash_v.x * hash_v.y;
			hash_v ^= hash_v >> 16u;
			hash_v.x += hash_v.y * hash_v.z;
			float rotation = 6.2831853 * fract(float(hash_v.x >> 8u) / 16777216.0 + ]] .. block_name .. [[.medium_noise_phase);
			float stratum = fract(float(hash_v.y >> 8u) / 16777216.0 + ]] .. block_name .. [[.medium_noise_phase * 1.6180339);
			float sum = 0.0;

			for (int i = 0; i < 6; i++) {
				float azimuth = float(i) * 2.3999632 + rotation;
				float depression = mix(0.2, 1.1, fract(float(i) / 6.0 + stratum));
				vec3 dir = normalize(tangent * (cos(azimuth) * cos(depression)) + bitangent * (sin(azimuth) * cos(depression)) - N * sin(depression));
				float t = get_medium_light_path(origin, dir, cap);
				sum += t > 0.0 ? t : cap;
			}

			return sum / 6.0;
		}

		#define LIGHT_MIN_SCREEN_RADIANCE 0.001
		#define LIGHT_TRANSMITTANCE_MIN_SCREEN_RADIANCE 0.002

		vec3 get_primary_sun_direction() {
			vec3 sunDir = ]] .. block_name .. [[.primary_sun_direction.xyz;
			if (length(sunDir) < 0.0001) {
				sunDir = vec3(0.0, 1.0, 0.0);
			}
			return normalize(sunDir);
		}

		]] .. surface_features.GetCommonGLSL() .. [[

		]] .. surface_features.GetSurfaceGLSL() .. [[

		]] .. render3d.GetEmissiveGLSL() .. surface_features.GetDefaultFunctionGLSL() .. surface_features.GetFinishFunctionGLSL() .. [[

		float get_light_visibility_at(int i, int type, vec3 position, vec3 L, vec3 light_position, float light_range) {
			if (type == 0) {
				if (i == ]] .. block_name .. [[.shadows.directional_shadow_light_index && ]] .. block_name .. [[.shadows.shadow_map_indices[0] >= 0) return calculateShadow(position, L, L);
			} else if (type == 1 || type == 3) {
				lights_t light = scene_light(]] .. block_name .. [[.lights, i);
				return light_oct_shadow_factor(light.slots.x, light_position, light_range, position, light.direction.w, vec3(0.0));
			}

			return 1.0;
		}

		#if SURFACE_RAY_SHADOWS
		vec4 trace_ray_shadows(vec3 P, vec3 N, vec3 geometric_N, vec3 vertex_N, bool lit_from_behind) {
			vec4 sums = vec4(0.0);
			int light_cell = light_grid_cell(P);

			for (int w = 0; w < light_grid_words(]] .. block_name .. [[.light_count); w++) {
				uint light_bits = light_grid_word(light_cell, w, ]] .. block_name .. [[.light_count);

				while (light_bits != 0u) {
					int i = w * 32 + findLSB(light_bits);
					light_bits &= light_bits - 1u;
					lights_t light = scene_light(]] .. block_name .. [[.lights, i);
					int type = get_light_type(light);
					vec3 L;
					float attenuation = 1.0;

					if (!get_light_vector_and_attenuation(light, P, L, attenuation)) continue;

					float NoL = dot(N, L);

					if ((NoL <= 0.0 || dot(vertex_N, L) <= 0.0) && !lit_from_behind) continue;

					vec3 radiance = light.color.rgb * light.color.a * attenuation;
					float weight = max(max(radiance.r, radiance.g), radiance.b) * max(abs(NoL), 0.05);

					if (weight * get_exposure() < LIGHT_MIN_SCREEN_RADIANCE) continue;

					float visible = get_ray_shadow_visibility(i, type, light, P, geometric_N, L, NoL > 0.0 && dot(geometric_N, L) < 0.0) * weight;

					if (type == 0) {
						sums.xz += vec2(visible, weight);
					} else {
						sums.yw += vec2(visible, weight);
					}
				}
			}

			return vec4(sums.z > 0.0 ? sums.x / sums.z : 1.0, sums.w > 0.0 ? sums.y / sums.w : 1.0, sums.z > 0.0 ? 1.0 : 0.0, sums.w > 0.0 ? 1.0 : 0.0);
		}
		#endif

		vec3 get_direct_light(in Surface s, out vec3 specular)
		{
			vec3 diffuse = vec3(0.0);
			specular = vec3(0.0);
			vec4 direct_lut = texture(TEXTURE(]] .. block_name .. [[.brdf_lut_tex), vec2(s.NdotV, s.perceptual_roughness));
			vec2 direct_env_brdf = direct_lut.rg;
			vec3 energy_compensation = GGXEnergyCompensation(s.F0, direct_env_brdf);
			vec3 diffuse_view = max(1.0 - (s.F0 * direct_env_brdf.x + F90(s.F0) * direct_env_brdf.y) * energy_compensation, vec3(0.0)) * (1.0 - s.metallic);

			int light_cell = light_grid_cell(s.world_pos);
			]] .. light_limit_select .. [[

			for (int w = 0; w < light_grid_words(]] .. block_name .. [[.light_count); w++) {
			uint light_bits = light_grid_word(light_cell, w, ]] .. block_name .. [[.light_count);

			while (light_bits != 0u) {
				int i = w * 32 + findLSB(light_bits);
				light_bits &= light_bits - 1u;
				lights_t light = scene_light(]] .. block_name .. [[.lights, i);
				int type = get_light_type(light);
				vec3 L;
				float attenuation = 1.0;
				if (!get_light_vector_and_attenuation(light, s.world_pos, L, attenuation)) {
					continue;
				}

				vec3 unshadowed_radiance = light.color.rgb * light.color.a * attenuation;
				]] .. light_limit_skip .. [[

				if (type == 0) unshadowed_radiance *= get_ground_fog_sun_transmittance(get_atmosphere_camera_origin(s.world_pos), L) * get_sun_transmittance_from_origin(s.world_pos, L);

				float lobe_alpha_min = s.roughness_alpha;
				]] .. surface_features.GetDirectPeakGLSL() .. [[
				float brightest = max(max(unshadowed_radiance.r, unshadowed_radiance.g), unshadowed_radiance.b) * max(1.0, 0.08 / max(lobe_alpha_min * lobe_alpha_min, 1e-4));

				if (brightest * get_exposure() < LIGHT_MIN_SCREEN_RADIANCE) continue;

				if ((dot(s.N, L) <= 0.0 || dot(s.vertex_N, L) <= 0.0) && !(]] .. surface_features.GetLitFromBehindExpressionGLSL() .. [[)) continue;
				float scatter_floor = 0.0;
				]] .. surface_features.GetDirectFloorGLSL() .. [[
				// a facet that faces away from the light while its smooth shading normal does not would shadow itself in a hard step along the facets, so its test starts toward the light and the shading ends the light at the terminator
				vec3 shadow_N = dot(s.geometric_N, L) > 0.0 ? s.geometric_N : normalize(s.geometric_N + L);
				]] .. surface_features.GetDirectShadowGLSL() .. [[
				vec3 H = normalize(s.V + L);
				float NoL = saturate(dot(s.N, L));
				float NoH = saturate(dot(s.N, H));
				float LoH = saturate(dot(L, H));

				float shadow_factor = 1.0;
				bool screen_marchable = true;

				bool leave_body = dot(s.N, L) > 0.0 && dot(s.geometric_N, L) < 0.0;

				#if SURFACE_RAY_SHADOWS
				shadow_factor = get_ray_shadow_factor(i, type, light, s.world_pos, leave_body ? s.geometric_N : shadow_N, L, leave_body);
				screen_marchable = false;

				if (type == 0 && shadow_factor > 0.0) shadow_factor *= get_cloud_shadow(s.world_pos);
				#else
				if (
					i == ]] .. block_name .. [[.shadows.directional_shadow_light_index &&
					]] .. block_name .. [[.shadows.shadow_map_indices[0] >= 0 &&
					type == 0
				) {
					shadow_factor = calculateShadow(s.world_pos, shadow_N, L);

					// the map cannot see occluders closer than a few texels (single sided walls meeting at a corner), inside the soft filter's receiver plane tolerance, or with a penumbra under a texel
					if (shadow_factor > 0.0 && ]] .. block_name .. [[.shadows.sun_contact_ray > 0.0) {
						vec3 contact_side = leave_body ? -s.geometric_N : shadow_N;
						shadow_factor *= get_sun_contact_visibility(scene_escape_tessellation(s.world_pos + contact_side * (0.0001 * ]] .. block_name .. [[.view_scale + 0.0001 * distance(s.world_pos, ]] .. block_name .. [[.camera_position)), contact_side, ]] .. string.format("%.3f", RAY_ESCAPE) .. [[ * ]] .. block_name .. [[.view_scale), L, max(shadow_texel_world_size * ]] .. block_name .. [[.shadows.sun_contact_ray, shadow_ray_reach), leave_body);
					}
				}

				if (type == 0) {
					if (shadow_factor > 0.0) shadow_factor *= get_cloud_shadow(s.world_pos);
				} else if (
					i == ]] .. block_name .. [[.shadows.local_directional_shadow_light_index &&
					]] .. block_name .. [[.shadows.local_directional_shadow_map_index >= 0 &&
					type == 2
				) {
					shadow_factor = calculateLocalDirectionalShadow(s.world_pos, shadow_N, L);
					screen_marchable = false;
				} else if (type == 1 || type == 3) {
					shadow_factor = light_oct_shadow_factor(light.slots.x, light.position.xyz, light.params.x, s.world_pos, light.direction.w, shadow_N);

					if (scatter_floor <= 0.0 && brightest * shadow_factor * get_exposure() < LIGHT_MIN_SCREEN_RADIANCE) continue;

					int point_shadow_slot = getPointShadowSlot(i);

					if (point_shadow_slot >= 0) {
						shadow_factor *= calculatePointShadow(point_shadow_slot, s.world_pos, shadow_N, L);
						screen_marchable = false;
					}
				}
				#endif

				#ifdef AIR_GRID_GLSL
				// the sun reached through a wall the air grid sealed, a crack between meshes the shadow map and rays let it through
				if (type == 0 && shadow_factor > 0.0 && air_grid_ray_crosses_wall(s.world_pos, shadow_N, s.V, L, 1e5)) shadow_factor = 0.0;
				#endif

				#ifdef SHADOW_SCREEN_SPACE
				#define SCREEN_SHADOW_MIN_SCREEN_RADIANCE 0.002
				if (screen_marchable && ]] .. block_name .. [[.screen_shadows != 0 && NoL > 0.0 && max(max(unshadowed_radiance.r, unshadowed_radiance.g), unshadowed_radiance.b) * shadow_factor * NoL * get_exposure() >= SCREEN_SHADOW_MIN_SCREEN_RADIANCE) {
					float reach = ]] .. block_name .. [[.screen_shadow_length;
					bool reach_is_light = false;

					if (type == 0) {
						reach = clamp(shadow_texel_world_size * 8.0, 0.5 * ]] .. block_name .. [[.view_scale, reach);
					} else if (type != 2) {
						float light_distance = length(light.position.xyz - s.world_pos);
						reach_is_light = light_distance <= reach;
						reach = min(light_distance, reach);
					}

					float screen_visibility = screen_space_shadow_visibility(s.world_pos, shadow_N, L, reach, reach_is_light);
					screen_shadow_term = min(screen_shadow_term, screen_visibility);
					shadow_factor *= screen_visibility;
				}
				#endif

				vec3 radiance = unshadowed_radiance * shadow_factor;

				#ifdef FLUID_SHADOWS
				if (type == 0 && shadow_factor > 0.0) radiance *= fluid_sun_transmittance(s.world_pos, L, -1, -1);
				if (type != 0 && shadow_factor > 0.0) radiance *= fluid_local_light_transmittance(s.world_pos, light.position.xyz, i);
				#endif


				if (radiance.r + radiance.g + radiance.b <= 0.0 && scatter_floor <= 0.0) continue;

				#ifdef OPTICAL_RAYS
				if (]] .. block_name .. [[.light_transmittance != 0 && brightest * shadow_factor * get_exposure() >= LIGHT_TRANSMITTANCE_MIN_SCREEN_RADIANCE) {
					float glass_distance = type == 0 ? OPTICAL_SUN_DISTANCE : (type == 2 ? 50.0 : max(length(light.position.xyz - s.world_pos) - 0.05 * ]] .. block_name .. [[.view_scale, 0.0));
					float glass_search = type == 0 && shadow_factor < 0.999 ? clamp(shadow_texel_world_size * 3.0, 0.05 * ]] .. block_name .. [[.view_scale, 0.5 * ]] .. block_name .. [[.view_scale) : 0.0;
					vec3 glass_origin = s.world_pos + shadow_N * 0.02 * ]] .. block_name .. [[.view_scale;

					radiance *= get_light_transmittance(glass_origin, L, glass_distance, glass_search, type != 0, ]] .. block_name .. [[.caustics != 0 && caustic_covered(i, light.position.xyz, s.world_pos));
				}
				#endif

				float lobe_alpha = s.roughness_alpha;
				float lobe_energy = 1.0;

				if (type == 0) {
					lobe_alpha = saturate(s.roughness_alpha + SUN_ANGULAR_RADIUS * 0.5);
					lobe_energy = s.roughness_alpha / lobe_alpha;
					lobe_energy *= lobe_energy * smoothstep(SUN_ANGULAR_RADIUS * 0.65, SUN_ANGULAR_RADIUS * 2.6, s.roughness_alpha);
				}

				float glow_widening = 0.0;

				if (type != 0 && light.falloff.w > 0.0) {
					glow_widening = light.falloff.w * 0.5 / max(length(light.position.xyz - s.world_pos), 0.0001);
					lobe_alpha = saturate(s.roughness_alpha + glow_widening);
					lobe_energy = s.roughness_alpha / lobe_alpha;
					lobe_energy *= lobe_energy;
				}

				float D = D_GGXAlpha(lobe_alpha, NoH) * lobe_energy;
				float V_func = V_SmithGGXCorrelated(s.roughness_alpha, s.NdotV, NoL);
				vec3 F = F_Surface(s.F0, 0.04 * s.specular, s.metallic, LoH);

				vec3 Fr = (D * V_func) * F * energy_compensation;
				vec3 Fd = Fd_EON(s.albedo, s.diffuse_roughness, NoL, s.NdotV, dot(L, s.V)) * diffuse_view * GGXDiffuseCoupling(s.F0, texture(TEXTURE(]] .. block_name .. [[.brdf_lut_tex), vec2(NoL, s.perceptual_roughness)).rg, direct_lut.ba);

				float diffuse_weight = 1.0;
				]] .. surface_features.GetDirectLayerGLSL() .. [[

				diffuse += Fd * radiance * NoL * diffuse_weight;
				specular += Fr * radiance * NoL;
				]] .. surface_features.GetDirectGLSL() .. [[
			}
			}

			return diffuse;
		}
	]]
end

return surface_lighting
