local render = import("goluwa/render/render.lua")
local pvars = import("goluwa/cli/pvars.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local ddgi = import("goluwa/render3d/ddgi.lua")
local gi = import("goluwa/render3d/gi.lua")
local atmosphere = import("goluwa/render3d/atmosphere.lua")
local hit = import("goluwa/render3d/scene/hit.lua")
local rt = import("goluwa/render3d/scene/rt.lua")
local scene_lights = import("goluwa/render3d/scene_lights.lua")
local light_grid = import("goluwa/render3d/light_grid.lua")
local glass_light = import("goluwa/render3d/glass_light.lua")
local glsl_common = import("goluwa/render3d/glsl_common.lua")
local ray_reorder = import("goluwa/render3d/ray_reorder.lua")
local scene_reflection = {}
scene_reflection.RAY_QUERY = render.GetDevice().ray_query_supported
pvars.StartGroup("Rendering", "Ray traced hit shading", {store = false})
scene_reflection.fog = pvars.Setup2{
	key = "r_rt_reflection_fog",
	default = true,
	help = "the ground fog between a reflection ray's origin and what it hit is applied to the hit (analytic, unshadowed), the volumetric fog only covers what the camera sees. the reflections, the glass and the water use it",
}
scene_reflection.max_distance = pvars.Setup2{
	key = "r_rt_reflection_distance",
	default = 1000000,
	min = 1,
	help = "how far reflection and refraction rays travel, in meters, a ray that goes no further finds the sky or the environment. the reflections, the glass and the water use it",
}
pvars.EndGroup()
pvars.StartGroup("Lighting", "Reflections", {store = false, prefix = "reflection_"})
scene_reflection.rough_rays = pvars.Setup2{
	key = "reflection_rough_rays",
	default = 4,
	integer = true,
	min = 1,
	max = 16,
	help = "rays a pixel traces once its surface is rough (the count rises from 1 between roughness 0.1 and 0.4), each in its own direction over the lobe, and their results are averaged. a single ray is one sharp point of the scene. the reflections and the water use it",
}
scene_reflection.RESOLUTION_SCALES = {full = 1, half = 0.5, quarter = 0.25}
scene_reflection.filter_radius = pvars.Setup2{
	key = "reflection_filter_radius",
	default = 3,
	min = 1,
	max = 16,
	help = "radius in texels of the half resolution (a full resolution texel counts as half) the denoiser averages a fully rough reflection over, it falls to 1 as the surface gets smooth. the taps are weighted by plane distance, normal and roughness so it stays on the surface. the water's resolve uses it too, by its distance",
}
local enabled = pvars.Setup2{
	key = "reflection_ray_query",
	default = true,
	help = "reflections are ray traced with ray queries, off (or without ray query hardware) only the screen space march traces them",
}
local screenspace_roughness = pvars.Setup2{
	key = "reflection_screenspace_roughness",
	default = 0,
	min = 0,
	max = 1,
	help = "perceptual roughness below which the screen space reflection is used first and the ray trace only fills what the screen does not hold. from there up, and everywhere at 0, the trace is the reflection and the screen is not traced",
}
local reorder = pvars.Setup2{
	key = "reflection_reorder",
	default = true,
	help = "the reflection rays are traced from a ray generation shader with a hit object and the threads are reordered by what they hit before it is shaded, off traces with ray queries in a compute shader. needs ray tracing invocation reorder, built into the shader",
}
pvars.EndGroup()

function scene_reflection.GetDescriptorSets(bindings, stage)
	local sets = hit.GetDescriptorSets(bindings.hit, stage, bindings.scene)
	sets[#sets + 1] = {type = "storage_buffer", binding_index = bindings.materials, stageFlags = stage}

	if bindings.light_grid then
		sets[#sets + 1] = {
			type = "storage_buffer",
			binding_index = bindings.light_grid,
			stageFlags = stage,
		}
	end

	return sets
end

do
	local bound = setmetatable({}, {__mode = "k"})

	function scene_reflection.Bind(self, cmd, desc, bindings)
		local materials = ddgi.WriteMaterialBuffer(self)
		local tlas = rt.GetTLAS(cmd)
		bound[self] = bound[self] or {}
		local last = bound[self][desc]

		if not last then
			last = {}
			bound[self][desc] = last
		end

		if bindings.light_grid then
			light_grid.Bind(self, cmd, desc, bindings.light_grid)
		end

		if last.materials ~= materials then
			self:UpdateDescriptorSet("storage_buffer", desc, bindings.materials, 0, materials, materials:GetSize())
			last.materials = materials
		end

		if last.tlas ~= tlas then
			self:UpdateDescriptorSet("acceleration_structure_khr", desc, bindings.scene, 0, tlas)
			last.tlas = tlas
		end

		hit.Bind(self, desc, bindings.hit)
	end
end

function scene_reflection.GetDeclarationGLSL(bindings, shared)
	return [[
		]] .. (
			shared and
			"" or
			"#define DDGI_VISIBILITY_RAYS"
		) .. [[

		#define SCENE_REFLECTION
		#define SCENE_REFLECTION_CONE 0.0017
	]] .. hit.GetSceneGLSL("ddgi_scene", bindings.scene) .. hit.GetGLSL(bindings.hit) .. ddgi.GetMaterialDeclarationsGLSL(bindings.materials) .. (
			bindings.light_grid and
			light_grid.GetGLSL(bindings.light_grid) or
			""
		)
end

function scene_reflection.GetRayGeneration()
	return ray_reorder.GetRayGeneration{
		declarations = [[
			#define SCENE_REFLECTION_SER
			layout(location = 0) rayPayloadEXT int scene_reflection_payload;
			layout(location = 1) SER_hitObjectAttribute vec2 scene_reflection_attributes;
		]],
		anyhit = [[
			hitAttributeEXT vec2 barycentrics;
			layout(location = 0) rayPayloadInEXT int payload;
		]] .. ddgi.GetAlphaTestGLSL() .. [[

			void main() {
				uint instance = uint(gl_InstanceCustomIndexEXT);

				if (ddgi_materials[scene_instance_material(instance)].transparent != 0 || !ddgi_alpha_passes(instance, uint(gl_PrimitiveID), barycentrics)) ignoreIntersectionEXT;
			}
		]],
	}
end

scene_reflection.CONSTANTS_GLSL = [[

		#define SCENE_REFLECTION_MIRROR_THRESHOLD 0.06
		#define SCENE_REFLECTION_MAX_HIT_LUMINANCE 8.0
		#define SCENE_REFLECTION_ROUGH_LIMIT_SCALE 0.25
]]

function scene_reflection.GetDirectionGLSL()
	return scene_reflection.CONSTANTS_GLSL .. [[

		int scene_reflection_ray_count(float roughness, int rough_rays) {
			return 1 + int(float(rough_rays - 1) * smoothstep(0.03, 0.25, roughness) + 0.5);
		}

		vec3 scene_reflection_direction(vec3 N, vec3 V, float roughness, vec2 xi, out float environment_roughness) {
			vec3 mirror = reflect(-V, N);
			environment_roughness = roughness;

			if (roughness <= SCENE_REFLECTION_MIRROR_THRESHOLD) return mirror;

			vec3 up = abs(N.y) < 0.999 ? vec3(0.0, 1.0, 0.0) : vec3(1.0, 0.0, 0.0);
			vec3 T = normalize(cross(up, N));
			vec3 B = cross(N, T);
			vec3 V_local = vec3(dot(V, T), dot(V, B), dot(V, N));
			vec3 H_local = ImportanceSampleGGXVNDF(V_local, max(0.001, roughness * roughness), xi);
			vec3 H = normalize(T * H_local.x + B * H_local.y + N * H_local.z);
			float rough_mix = smoothstep(SCENE_REFLECTION_MIRROR_THRESHOLD, SCENE_REFLECTION_MIRROR_THRESHOLD * 3.0, roughness);
			vec3 R = normalize(mix(mirror, reflect(-V, H), rough_mix));
			environment_roughness = roughness * (1.0 - rough_mix);

			float below_normal = dot(N, R);

			if (below_normal < 0.001) R = normalize(R + N * (0.001 - 2.0 * below_normal));

			return R;
		}

		float scene_reflection_hit_luminance_limit(float roughness, float max_luminance, float cutoff) {
			return max_luminance * mix(1.0, SCENE_REFLECTION_ROUGH_LIMIT_SCALE, smoothstep(SCENE_REFLECTION_MIRROR_THRESHOLD, cutoff, roughness));
		}

		vec3 scene_reflection_limit_hit(vec3 traced, float roughness, float limit) {
			float traced_luma = dot(traced, vec3(0.2126, 0.7152, 0.0722));

			return traced_luma > limit ? traced * (limit / traced_luma) : traced;
		}
	]]
end

function scene_reflection.IsReordered()
	return reorder:Get()
end

function scene_reflection.IsEnabled()
	return enabled:Get()
end

scene_reflection.block = {
	{"lights", scene_lights.BuildLightsBlockLayout(), scene_lights.MAX_LIGHTS},
	{"light_count", "int"},
	{"reflection_screenspace_roughness", "float"},
	{"reflection_max_distance", "float"},
	{"reflection_fog", "int"},
	{"glass_light", "int"},
}

function scene_reflection.WriteBlock(self, block)
	local lights = render3d.GetLights()
	block.light_count = math.min(#lights, scene_lights.MAX_LIGHTS)
	block.reflection_screenspace_roughness = screenspace_roughness:Get()
	block.reflection_max_distance = scene_reflection.max_distance:Get()
	block.reflection_fog = scene_reflection.fog:Get() and 1 or 0
	block.glass_light = ddgi.HasGlass() and 1 or 0
	scene_lights.WriteLightsBlock(block.lights, lights)
end

function scene_reflection.WriteProbeBlock(self, block)
	gi.WriteProbeBlock(self, block)

	if not enabled:Get() then block.ddgi_rt_ready = 0 end

	return block
end

function scene_reflection.GetDDGIUniformBuffer(binding)
	return {
		name = "ddgi_data",
		binding_index = binding,
		block = gi.GetProbeBlockLayout(),
		write = scene_reflection.WriteProbeBlock,
	}
end

function scene_reflection.GetGLSL(block_name, shared)
	return ddgi.GetHitDefinesGLSL() .. (
			shared and
			"" or
			gi.GetCommonGLSL() .. scene_lights.GetLightGLSLCode()
		) .. ddgi.GetMaterialGLSL() .. ddgi.GetAlphaTestGLSL() .. (
			shared and
			"" or
			glass_light.GetGLSL("ddgi_scene")
		) .. glsl_common.GetHashGLSL() .. [[
		#define SCENE_REFLECTION_MAX_DISTANCE (]] .. block_name .. [[.reflection_max_distance)

		#define SCENE_REFLECTION_FLAGS (RT_HIT_ANY_HIT != 0 ? gl_RayFlagsNoneEXT : gl_RayFlagsOpaqueEXT)
		#define SCENE_REFLECTION_LIGHT_FULL_RADIANCE 0.02
		#ifndef SCENE_HIT_SKY_RAYS
		#define SCENE_HIT_SKY_RAYS 4
		#endif

		float scene_reflection_random(vec3 p, int light) {
			return pcg_unorm(pcg3d(uvec3(floatBitsToUint(p.x), floatBitsToUint(p.y), floatBitsToUint(p.z) ^ (uint(light) * 2654435761u + uint(ddgi_data.ddgi_frame) * 40503u))).x);
		}

		float scene_reflection_light_weight(vec3 contribution, vec3 p, int light) {
			float probability = min(max(max(contribution.r, contribution.g), contribution.b) * get_exposure() / SCENE_REFLECTION_LIGHT_FULL_RADIANCE, 1.0);

			if (probability >= 1.0) return 1.0;

			return scene_reflection_random(p, light) < probability ? 1.0 / probability : 0.0;
		}

		bool scene_reflection_ready() {
			return ddgi_data.ddgi_rt_ready != 0;
		}

		bool scene_reflection_screen_first(float roughness) {
			return roughness < ]] .. block_name .. [[.reflection_screenspace_roughness;
		}

		#define SCENE_REFLECTION_PROCEED(query) \
			while (rayQueryProceedEXT(query)) { \
				uint candidate = uint(rayQueryGetIntersectionInstanceCustomIndexEXT(query, false)); \
				if (ddgi_materials[scene_instance_material(candidate)].transparent == 0 && ddgi_alpha_passes(candidate, uint(rayQueryGetIntersectionPrimitiveIndexEXT(query, false)), rayQueryGetIntersectionBarycentricsEXT(query, false))) rayQueryConfirmIntersectionEXT(query); \
			}

		bool scene_reflection_visible(vec3 origin, vec3 dir, float dist) {
			rayQueryEXT query;
			rayQueryInitializeEXT(query, ddgi_scene, gl_RayFlagsTerminateOnFirstHitEXT | (RT_HIT_ANY_HIT != 0 ? 0u : gl_RayFlagsOpaqueEXT), 0xFF, origin, 0.0, dir, dist);

			SCENE_REFLECTION_PROCEED(query)

			return rayQueryGetIntersectionTypeEXT(query, true) == gl_RayQueryCommittedIntersectionNoneEXT;
		}

		float scene_hit_distance(vec3 origin, vec3 dir, float max_distance) {
			rayQueryEXT query;
			rayQueryInitializeEXT(query, ddgi_scene, SCENE_REFLECTION_FLAGS, 0xFF, origin, 0.0, dir, max_distance);

			SCENE_REFLECTION_PROCEED(query)

			if (rayQueryGetIntersectionTypeEXT(query, true) == gl_RayQueryCommittedIntersectionNoneEXT) return max_distance;

			return rayQueryGetIntersectionTEXT(query, true);
		}

		bool trace_scene_interval(vec3 origin, vec3 dir, float t_min, float t_max, out float t, out uint instance, out uint primitive, out vec2 barycentrics) {
			rayQueryEXT query;
			rayQueryInitializeEXT(query, ddgi_scene, SCENE_REFLECTION_FLAGS, 0xFF, origin, t_min, dir, t_max);

			SCENE_REFLECTION_PROCEED(query)

			if (rayQueryGetIntersectionTypeEXT(query, true) == gl_RayQueryCommittedIntersectionNoneEXT) return false;

			t = rayQueryGetIntersectionTEXT(query, true);
			instance = uint(rayQueryGetIntersectionInstanceCustomIndexEXT(query, true));
			primitive = uint(rayQueryGetIntersectionPrimitiveIndexEXT(query, true));
			barycentrics = rayQueryGetIntersectionBarycentricsEXT(query, true);
			return true;
		}

		vec3 shade_scene_reflection_hit(vec3 origin, vec3 dir, float roughness, float t, uint hit_instance, uint hit_primitive, vec2 hit_barycentrics);

		vec3 trace_scene_reflection_hit(vec3 origin, vec3 dir, vec3 N, float roughness, float max_distance, out float hit_t) {
			hit_t = max_distance;
			float t;
			uint hit_instance;
			uint hit_primitive;
			vec2 hit_barycentrics;

			#ifdef SCENE_REFLECTION_SER
			SER_hitObject hit_object;
			SER_hitObjectTraceRay(hit_object, ddgi_scene, SCENE_REFLECTION_FLAGS, 0xFF, 0, 0, 0, origin, 0.0, dir, max_distance, 0);

			SER_reorderThread(hit_object);

			if (!SER_hitObjectIsHit(hit_object)) {
				return sample_environment_specular(]] .. block_name .. [[.env_tex, dir, N, roughness);
			}

			t = SER_hitObjectGetRayTMax(hit_object);
			hit_instance = uint(SER_hitObjectGetInstanceCustomIndex(hit_object));
			hit_primitive = uint(SER_hitObjectGetPrimitiveIndex(hit_object));
			SER_hitObjectGetAttributes(hit_object, 1);
			hit_barycentrics = scene_reflection_attributes;
			#else
			if (!trace_scene_interval(origin, dir, 0.0, max_distance, t, hit_instance, hit_primitive, hit_barycentrics)) {
				return sample_environment_specular(]] .. block_name .. [[.env_tex, dir, N, roughness);
			}
			#endif

			hit_t = t;
			return shade_scene_reflection_hit(origin, dir, roughness, t, hit_instance, hit_primitive, hit_barycentrics);
		}

		vec3 shade_scene_reflection_hit(vec3 origin, vec3 dir, float roughness, float t, uint hit_instance, uint hit_primitive, vec2 hit_barycentrics) {
			scene_triangle tri = scene_hit_tri(hit_instance, hit_primitive);
			ddgi_material material = ddgi_materials[tri.material];
			vec3 hit_N = -tri.normal;

			if (dot(dir, hit_N) > 0.0) {
				if (material.double_sided == 0) return vec3(0.0);

				hit_N = -hit_N;
			}

			vec3 P = origin + dir * t;
			vec3 surface = P + hit_N * 0.02;
			vec3 albedo = ddgi_albedo(material, P);

			#if RT_HIT_TEXTURES
			if (material.terrain_tex < 0 && material.albedo_tex >= 0) {
				vec2 barycentrics = hit_barycentrics;
				scene_uv uv = scene_hit_uv(hit_instance, hit_primitive);
				vec3 weights = vec3(1.0 - barycentrics.x - barycentrics.y, barycentrics);
				vec2 coord = uv.uv0 * weights.x + uv.uv1 * weights.y + uv.uv2 * weights.z;
				float cone_width = t * (SCENE_REFLECTION_CONE + roughness * roughness * 0.25);
				vec3 rgb = textureLod(TEXTURE(material.albedo_tex), coord, scene_hit_texture_lod(tri, uv, textureSize(TEXTURE(material.albedo_tex), 0), cone_width)).rgb;

				if (material.albedo2_tex >= 0) {
					float blend = dot(uv.blend, weights);

					if (material.blend_tex >= 0) {
						vec2 modulate = textureLod(TEXTURE(material.blend_tex), coord, scene_hit_texture_lod(tri, uv, textureSize(TEXTURE(material.blend_tex), 0), cone_width)).rg;
						blend = smoothstep(clamp(modulate.g - modulate.r, 0.0, 1.0), clamp(modulate.g + modulate.r, 0.0, 1.0), blend);
					}

					rgb = mix(rgb, textureLod(TEXTURE(material.albedo2_tex), coord, scene_hit_texture_lod(tri, uv, textureSize(TEXTURE(material.albedo2_tex), 0), cone_width)).rgb, blend);
				}

				albedo = material.albedo * rgb;
			}
			#endif

			vec3 radiance = ddgi_emission(tri, albedo);
			vec3 sun_L = normalize(ddgi_data.ddgi_sun_direction.xyz);
			float sun_NoL = dot(hit_N, sun_L);

			if (RT_HIT_SUN != 0 && sun_NoL > 0.0 && (RT_HIT_SHADOWS == 0 || scene_reflection_visible(surface, sun_L, SCENE_REFLECTION_MAX_DISTANCE))) {
				vec3 sun_radiance = albedo * ddgi_data.ddgi_sun_radiance.rgb * (sun_NoL / 3.14159265359);

				if (]] .. block_name .. [[.glass_light != 0) sun_radiance *= get_glass_light(surface, sun_L, GLASS_SUN_DISTANCE, 0.0);

				radiance += sun_radiance;
			}

			#if RT_HIT_LIGHTS && RT_HIT_LIGHT_SAMPLES > 0
			{
				int light_cell = light_grid_cell(surface);
				int light_count = ]] .. block_name .. [[.light_count;
				float total = 0.0;
				vec3 picked_light[RT_HIT_LIGHT_SAMPLES];
				vec4 picked_ray[RT_HIT_LIGHT_SAMPLES];
				float picked_weight[RT_HIT_LIGHT_SAMPLES];
				float u[RT_HIT_LIGHT_SAMPLES];

				for (int k = 0; k < RT_HIT_LIGHT_SAMPLES; k++) {
					picked_weight[k] = 0.0;
					u[k] = scene_reflection_random(P, -1 - k);
				}

				for (int w = 0; w < light_grid_words(light_count); w++) {
					uint light_bits = light_grid_word(light_cell, w, light_count);

					while (light_bits != 0u) {
						int i = w * 32 + findLSB(light_bits);
						light_bits &= light_bits - 1u;
						lights_t light = ]] .. block_name .. [[.lights[i];

						if (get_light_type(light) == 0) continue;

						vec3 L;
						float attenuation;

						if (!get_light_vector_and_attenuation(light, surface, L, attenuation)) continue;

						float NoL = dot(hit_N, L);

						if (NoL <= 0.0) continue;

						vec3 contribution = albedo * light.color.rgb * light.color.a * attenuation * (NoL / 3.14159265359);
						float weight = max(max(contribution.r, contribution.g), contribution.b);

						if (weight <= 0.0) continue;

						total += weight;
						float p = weight / total;

						for (int k = 0; k < RT_HIT_LIGHT_SAMPLES; k++) {
							if (u[k] < p) {
								picked_light[k] = contribution;
								picked_ray[k] = vec4(L, dot(light.position.xyz - surface, L));
								picked_weight[k] = weight;
								u[k] /= p;
							} else {
								u[k] = (u[k] - p) / (1.0 - p);
							}
						}
					}
				}

				for (int k = 0; k < RT_HIT_LIGHT_SAMPLES; k++) {
					if (picked_weight[k] <= 0.0) continue;

					float dist = picked_ray[k].w;

					if (RT_HIT_SHADOWS != 0 && dist > 0.05 && !scene_reflection_visible(surface, picked_ray[k].xyz, dist - 0.05)) continue;

					vec3 contribution = picked_light[k];

					if (]] .. block_name .. [[.glass_light != 0) contribution *= get_glass_light(surface, picked_ray[k].xyz, max(dist - 0.05, 0.0), 0.0);

					radiance += contribution * (total / (picked_weight[k] * float(RT_HIT_LIGHT_SAMPLES)));
				}
			}
			#elif RT_HIT_LIGHTS
			int light_cell = light_grid_cell(surface);
			int light_count = ]] .. block_name .. [[.light_count;

			for (int w = 0; w < light_grid_words(light_count); w++) {
				uint light_bits = light_grid_word(light_cell, w, light_count);

				while (light_bits != 0u) {
					int i = w * 32 + findLSB(light_bits);
					light_bits &= light_bits - 1u;
					lights_t light = ]] .. block_name .. [[.lights[i];

					if (get_light_type(light) == 0) continue;

					vec3 L;
					float attenuation;

					if (!get_light_vector_and_attenuation(light, surface, L, attenuation)) continue;

					float NoL = dot(hit_N, L);

					if (NoL <= 0.0) continue;

					vec3 contribution = albedo * light.color.rgb * light.color.a * attenuation * (NoL / 3.14159265359);
					float light_weight = scene_reflection_light_weight(contribution, P, i);

					if (light_weight == 0.0) continue;

					float dist = dot(light.position.xyz - surface, L);

					if (RT_HIT_SHADOWS != 0 && dist > 0.05 && !scene_reflection_visible(surface, L, dist - 0.05)) continue;

					if (]] .. block_name .. [[.glass_light != 0) contribution *= get_glass_light(surface, L, max(dist - 0.05, 0.0), 0.0);

					radiance += contribution * light_weight;
				}
			}
			#endif

			#if !RT_HIT_PROBES
			return radiance;
			#endif

			float weight;
			vec4 gi = gi_sample_irradiance(P, hit_N, -dir, false, DDGI_CONTRAST_VISIBILITY_RAYS, weight);

			if (!gi_covers(P, weight)) {
				vec3 tangent = normalize(cross(hit_N, abs(hit_N.y) < 0.99 ? vec3(0.0, 1.0, 0.0) : vec3(1.0, 0.0, 0.0)));
				vec3 bitangent = cross(hit_N, tangent);
				float spin = fract(sin(dot(P, vec3(12.9898, 78.233, 37.719))) * 43758.5453) * 6.28318530718;
				float open_sky = 0.0;

				for (int k = 0; k < SCENE_HIT_SKY_RAYS; k++) {
					float phi = spin + float(k) * (6.28318530718 / float(SCENE_HIT_SKY_RAYS));
					vec3 sky_dir = normalize(hit_N + tangent * cos(phi) + bitangent * sin(phi));

					if (scene_reflection_visible(surface, sky_dir, SCENE_REFLECTION_MAX_DISTANCE)) open_sky += 1.0 / float(SCENE_HIT_SKY_RAYS);
				}

				gi.rgb = sample_environment_irradiance(ddgi_data.ddgi_env_irradiance_tex, hit_N) * open_sky;
			}

			return radiance + albedo * gi.rgb;
		}

		vec3 trace_scene_reflection(vec3 origin, vec3 dir, vec3 N, float roughness, float max_distance, out float hit_t) {
			vec3 radiance = trace_scene_reflection_hit(origin, dir, N, roughness, max_distance, hit_t);

			if (]] .. block_name .. [[.glass_light != 0) radiance *= get_glass_light(origin, dir, hit_t, 0.0);

			if (]] .. block_name .. [[.reflection_fog != 0 && hit_t < max_distance) {
				float fog_sky = 1.0;
				vec3 fog_gi = vec3(0.0);

				if (gi_available() && gi_in_volume(origin)) {
					float fog_weight;
					vec4 up = gi_sample_irradiance(origin, vec3(0.0, 1.0, 0.0), vec3(0.0), false, DDGI_NO_VISIBILITY_RAYS, fog_weight);

					if (fog_weight > 0.0) {
						fog_sky = saturate(up.a);
						fog_gi = up.rgb;
					}
				}

				radiance = apply_ground_fog_ray(radiance, dir, ATMOSPHERE_SKY_SUN_DIRECTION, origin, hit_t * ]] .. string.format("%.17g", atmosphere.METERS_TO_UNITS) .. [[, fog_sky, fog_gi, fog_sky);
			}

			return radiance;
		}
	]]
end

return scene_reflection
