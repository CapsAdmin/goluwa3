local ray_materials = import("goluwa/render3d/scene/ray_materials.lua")
local render = import("goluwa/render/render.lua")
local pvars = import("goluwa/cli/pvars.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local gi = import("goluwa/render3d/gi.lua")
local atmosphere = import("goluwa/render3d/atmosphere.lua")
local clouds = import("goluwa/render3d/clouds.lua")
local ibl = import("goluwa/render3d/ibl.lua")
local hit = import("goluwa/render3d/scene/hit.lua")
local rt = import("goluwa/render3d/scene/rt.lua")
local scene_lights = import("goluwa/render3d/scene_lights.lua")
local light_grid = import("goluwa/render3d/light_grid.lua")
local optical_rays = import("goluwa/render3d/optical_rays.lua")
local glsl_common = import("goluwa/render3d/glsl_common.lua")
local caustics = import("goluwa/render3d/caustics.lua")
local ray_reorder = import("goluwa/render3d/ray_reorder.lua")
local media = import("goluwa/render3d/media.lua")
local scene_hits = {}
scene_hits.RAY_QUERY = render.GetDevice().ray_query_supported
pvars.StartGroup("Rendering", "Ray traced hit shading", {store = false})
scene_hits.fog = pvars.Setup2{
	key = "r_rt_hit_fog",
	default = true,
	help = "the ground fog between a reflection ray's origin and what it hit is applied to the hit (analytic, unshadowed), the volumetric fog only covers what the camera sees. the reflections, the glass and the water use it",
}
scene_hits.refraction = pvars.Setup2{
	key = "r_rt_refraction",
	default = true,
	help = "refracted rays (through glass and other translucent bodies, and the view from inside a body) find what they hit with a ray query and shade it by ray tracing when it is off screen or hidden, off they march the screen and keep what it holds. costs a ray per refracted sample",
}
scene_hits.max_distance = pvars.Setup2{
	key = "r_rt_hit_distance",
	default = 1000000,
	min = 1,
	help = "how far reflection and refraction rays travel, in meters, a ray that goes no further finds the sky or the environment. the reflections, the glass and the water use it",
}
pvars.EndGroup()
pvars.StartGroup("Lighting", "Reflections", {store = false, prefix = "reflection_"})
scene_hits.rough_rays = pvars.Setup2{
	key = "reflection_rough_rays",
	default = 4,
	integer = true,
	min = 1,
	max = 16,
	help = "rays a pixel traces once its surface is rough (the count rises from 1 between roughness 0.1 and 0.4), each in its own direction over the lobe, and their results are averaged. a single ray is one sharp point of the scene. the reflections and the water use it",
}
scene_hits.filter_radius = pvars.Setup2{
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
pvars.EndGroup()

function scene_hits.GetDescriptorSets(bindings, stage)
	local sets = hit.GetDescriptorSets(bindings.hit, stage, bindings.scene)
	sets[#sets + 1] = {
		type = "storage_buffer",
		binding_index = bindings.materials,
		stageFlags = stage,
	}

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

	function scene_hits.Bind(self, cmd, desc, bindings)
		local materials = ray_materials.WriteMaterialBuffer(self)
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

function scene_hits.GetDeclarationGLSL(bindings, shared)
	return [[
		]] .. (
			shared and
			"" or
			"#define RADIANCE_CACHE_VISIBILITY_RAYS"
		) .. [[

		#define SCENE_HITS
		#define SCENE_HIT_CONE 0.0017
	]] .. optical_rays.GetDeclarationGLSL(bindings) .. (
			bindings.light_grid and
			light_grid.GetGLSL(bindings.light_grid) or
			""
		)
end

function scene_hits.GetRayGeneration(reordered)
	if not (reordered and ray_reorder.IsSupported()) then return nil end

	return ray_reorder.GetRayGeneration{
		declarations = [[
			#define SCENE_HIT_SER
			layout(location = 0) rayPayloadEXT int scene_hit_payload;
			layout(location = 1) SER_hitObjectAttribute vec2 scene_hit_attributes;
		]],
		anyhit = [[
			hitAttributeEXT vec2 barycentrics;
			layout(location = 0) rayPayloadInEXT int payload;
		]] .. ray_materials.GetAlphaTestGLSL() .. [[

			void main() {
				uint instance = uint(gl_InstanceCustomIndexEXT);

				if (ray_materials[scene_instance_material(instance)].transparent != 0 || !ray_alpha_passes(instance, scene_shader_primitive(), barycentrics)) ignoreIntersectionEXT;
			}
		]],
	}
end

scene_hits.CONSTANTS_GLSL = [[

		#define REFLECTION_MIRROR_THRESHOLD 0.06
		#define REFLECTION_MAX_HIT_LUMINANCE 8.0
]]

function scene_hits.GetDirectionGLSL()
	return scene_hits.CONSTANTS_GLSL .. [[

		int reflection_ray_count(float roughness, int rough_rays) {
			return 1 + int(float(rough_rays - 1) * smoothstep(0.03, 0.25, roughness) + 0.5);
		}

		vec3 reflection_direction(vec3 N, vec3 V, float roughness, vec2 xi, out float environment_roughness) {
			vec3 mirror = reflect(-V, N);
			environment_roughness = roughness;

			if (roughness <= REFLECTION_MIRROR_THRESHOLD) return mirror;

			vec3 up = abs(N.y) < 0.999 ? vec3(0.0, 1.0, 0.0) : vec3(1.0, 0.0, 0.0);
			vec3 T = normalize(cross(up, N));
			vec3 B = cross(N, T);
			vec3 V_local = vec3(dot(V, T), dot(V, B), dot(V, N));
			vec3 H_local = ImportanceSampleGGXVNDF(V_local, max(0.001, roughness * roughness), xi);
			vec3 H = normalize(T * H_local.x + B * H_local.y + N * H_local.z);
			float rough_mix = smoothstep(REFLECTION_MIRROR_THRESHOLD, REFLECTION_MIRROR_THRESHOLD * 3.0, roughness);
			vec3 R = normalize(mix(mirror, reflect(-V, H), rough_mix));
			environment_roughness = roughness * (1.0 - rough_mix);
			return R;
		}

		vec3 reflection_above(vec3 N, vec3 R, float margin) {
			float below = dot(N, R);
			return below < margin ? normalize(R + N * (margin - 2.0 * below)) : R;
		}

		vec3 reflection_limit_hit(vec3 traced, float limit) {
			float traced_luma = dot(traced, vec3(0.2126, 0.7152, 0.0722));

			return traced_luma > limit ? traced * (limit / traced_luma) : traced;
		}
	]]
end

scene_hits.block = {
	{"lights", "uint64_t"},
	{"light_count", "int"},
	{"reflection_screenspace_roughness", "float"},
	{"hit_max_distance", "float"},
	{"hit_fog", "int"},
	{"light_transmittance", "int"},
	{"optical_tint", "int"},
	{"refraction_rays", "int"},
}

function scene_hits.WriteBlock(self, block)
	local lights = render3d.GetLights()
	block.light_count = #lights
	block.reflection_screenspace_roughness = screenspace_roughness:Get()
	block.hit_max_distance = scene_hits.max_distance:Get()
	block.hit_fog = scene_hits.fog:Get() and 1 or 0
	block.light_transmittance = ray_materials.HasDirectTint() and 1 or 0
	block.optical_tint = (ray_materials.HasGlass() or ray_materials.HasMedium()) and 1 or 0
	block.refraction_rays = scene_hits.refraction:Get() and 1 or 0
	block.lights = scene_lights.GetAddress(lights)
end

function scene_hits.WriteProbeBlock(self, block)
	gi.WriteProbeBlock(self, block)

	if not enabled:Get() then block.radiance_cache_rt_ready = 0 end

	return block
end

function scene_hits.GetRadianceCacheUniformBuffer(binding)
	return {
		name = "radiance_cache_data",
		binding_index = binding,
		block = gi.GetProbeBlockLayout(),
		write = scene_hits.WriteProbeBlock,
	}
end

function scene_hits.GetGLSL(block_name, shared)
	return ray_materials.GetHitDefinesGLSL() .. (
			shared and
			"" or
			gi.GetCommonGLSL() .. clouds.GetShadowGLSL("radiance_cache_data") .. scene_lights.GetLightGLSLCode()
		) .. ray_materials.GetMaterialGLSL() .. ray_materials.GetAlphaTestGLSL() .. ibl.GetEONGLSL() .. ibl.GetHitBRDFGLSL() .. (
			shared and
			"" or
			optical_rays.GetGLSL()
		) .. glsl_common.GetHashGLSL() .. media.GetTransmissionPhaseGLSL() .. caustics.GetHitGLSL() .. [[
		#define SCENE_HIT_MAX_DISTANCE (]] .. block_name .. [[.hit_max_distance)

		#ifdef DEVICE_OPACITY_MICROMAP
		#extension GL_EXT_opacity_micromap : require
		#define SCENE_HIT_COARSE_ALPHA gl_RayFlagsForceOpacityMicromap2StateEXT
		#else
		#define SCENE_HIT_COARSE_ALPHA gl_RayFlagsNoneEXT
		#endif

		bool scene_hit_coarse_alpha = false;

		#define SCENE_HIT_FLAGS (RT_HIT_ANY_HIT == 0 ? gl_RayFlagsOpaqueEXT : scene_hit_coarse_alpha ? SCENE_HIT_COARSE_ALPHA : gl_RayFlagsNoneEXT)
		#define SCENE_HIT_LIGHT_FULL_RADIANCE 0.02
		#ifndef SCENE_HIT_SKY_RAYS
		#define SCENE_HIT_SKY_RAYS 4
		#endif
		#ifndef SCENE_HIT_EMISSION
		#define SCENE_HIT_EMISSION true
		#endif
		#ifndef SCENE_HIT_BOUNCE
		#define SCENE_HIT_BOUNCE false
		#endif
		#ifndef SCENE_HIT_MASK
		#define SCENE_HIT_MASK 0xFF
		#endif

		float scene_hit_random(vec3 p, int light) {
			return pcg_unorm(pcg3d(uvec3(floatBitsToUint(p.x), floatBitsToUint(p.y), floatBitsToUint(p.z) ^ (uint(light) * 2654435761u + uint(radiance_cache_data.radiance_cache_frame) * 40503u))).x);
		}

		float scene_hit_light_weight(vec3 contribution, vec3 p, int light) {
			float probability = min(max(max(contribution.r, contribution.g), contribution.b) * get_exposure() / SCENE_HIT_LIGHT_FULL_RADIANCE, 1.0);

			if (probability >= 1.0) return 1.0;

			return scene_hit_random(p, light) < probability ? 1.0 / probability : 0.0;
		}

		bool scene_hits_ready() {
			return radiance_cache_data.radiance_cache_rt_ready != 0;
		}

		bool reflection_screen_first(float roughness) {
			return roughness < ]] .. block_name .. [[.reflection_screenspace_roughness;
		}

		#define SCENE_HIT_PROCEED(query) \
			while (rayQueryProceedEXT(query)) { \
				uint candidate = uint(rayQueryGetIntersectionInstanceCustomIndexEXT(query, false)); \
				if (ray_materials[scene_instance_material(candidate)].transparent == 0 && ray_alpha_passes(candidate, scene_query_primitive(query, false), rayQueryGetIntersectionBarycentricsEXT(query, false))) rayQueryConfirmIntersectionEXT(query); \
			}

		bool scene_hit_visible(vec3 origin, vec3 dir, float dist) {
			rayQueryEXT query;
			rayQueryInitializeEXT(query, scene_tlas, gl_RayFlagsTerminateOnFirstHitEXT | (RT_HIT_ANY_HIT != 0 ? SCENE_HIT_COARSE_ALPHA : gl_RayFlagsOpaqueEXT), SCENE_HIT_MASK, origin, 0.0, dir, dist);

			SCENE_HIT_PROCEED(query)

			return rayQueryGetIntersectionTypeEXT(query, true) == gl_RayQueryCommittedIntersectionNoneEXT;
		}

		float scene_hit_distance(vec3 origin, vec3 dir, float max_distance) {
			rayQueryEXT query;
			rayQueryInitializeEXT(query, scene_tlas, SCENE_HIT_FLAGS, SCENE_HIT_MASK, origin, 0.0, dir, max_distance);

			SCENE_HIT_PROCEED(query)

			if (rayQueryGetIntersectionTypeEXT(query, true) == gl_RayQueryCommittedIntersectionNoneEXT) return max_distance;

			return rayQueryGetIntersectionTEXT(query, true);
		}

		bool trace_scene_interval(vec3 origin, vec3 dir, float t_min, float t_max, out float t, out uint instance, out uint primitive, out vec2 barycentrics) {
			rayQueryEXT query;
			rayQueryInitializeEXT(query, scene_tlas, SCENE_HIT_FLAGS, SCENE_HIT_MASK, origin, t_min, dir, t_max);

			SCENE_HIT_PROCEED(query)

			if (rayQueryGetIntersectionTypeEXT(query, true) == gl_RayQueryCommittedIntersectionNoneEXT) return false;

			t = rayQueryGetIntersectionTEXT(query, true);
			instance = uint(rayQueryGetIntersectionInstanceCustomIndexEXT(query, true));
			primitive = scene_query_primitive(query, true);
			barycentrics = rayQueryGetIntersectionBarycentricsEXT(query, true);
			return true;
		}

		bool trace_scene_hit(vec3 origin, vec3 dir, float t_min, float t_max, out float t, out uint instance, out uint primitive, out vec2 barycentrics) {
			#ifdef SCENE_HIT_SER
			SER_hitObject hit_object;
			SER_hitObjectTraceRay(hit_object, scene_tlas, SCENE_HIT_FLAGS, SCENE_HIT_MASK, 0, 0, 0, origin, t_min, dir, t_max, 0);

			SER_reorderThread(hit_object);

			if (!SER_hitObjectIsHit(hit_object)) return false;

			t = SER_hitObjectGetRayTMax(hit_object);
			instance = uint(SER_hitObjectGetInstanceCustomIndex(hit_object));
			primitive = scene_hit_object_primitive(hit_object);
			SER_hitObjectGetAttributes(hit_object, 1);
			barycentrics = scene_hit_attributes;
			return true;
			#else
			return trace_scene_interval(origin, dir, t_min, t_max, t, instance, primitive, barycentrics);
			#endif
		}

		vec3 shade_scene_hit(vec3 origin, vec3 dir, float roughness, float t, uint hit_instance, uint hit_primitive, vec2 hit_barycentrics);

		vec3 trace_scene_radiance_unfogged(vec3 origin, vec3 dir, vec3 N, float roughness, float max_distance, out float hit_t) {
			hit_t = max_distance;
			float t;
			uint hit_instance;
			uint hit_primitive;
			vec2 hit_barycentrics;

			if (!trace_scene_hit(origin, dir, 0.0, max_distance, t, hit_instance, hit_primitive, hit_barycentrics)) {
				return sample_environment_specular(]] .. block_name .. [[.env_tex, dir, N, roughness);
			}

			hit_t = t;
			return shade_scene_hit(origin, dir, roughness, t, hit_instance, hit_primitive, hit_barycentrics);
		}

		float scene_hit_open_sky(vec3 surface, vec3 N, vec3 P) {
			vec3 tangent = normalize(cross(N, abs(N.y) < 0.99 ? vec3(0.0, 1.0, 0.0) : vec3(1.0, 0.0, 0.0)));
			vec3 bitangent = cross(N, tangent);
			float spin = fract(sin(dot(P, vec3(12.9898, 78.233, 37.719))) * 43758.5453) * 6.28318530718;
			float open_sky = 0.0;

			for (int k = 0; k < SCENE_HIT_SKY_RAYS; k++) {
				float phi = spin + float(k) * (6.28318530718 / float(SCENE_HIT_SKY_RAYS));
				vec3 sky_dir = normalize(N + tangent * cos(phi) + bitangent * sin(phi));

				if (scene_hit_visible(surface, sky_dir, SCENE_HIT_MAX_DISTANCE)) open_sky += 1.0 / float(SCENE_HIT_SKY_RAYS);
			}

			return open_sky;
		}

		vec3 scene_hit_probe_light(vec3 P, vec3 hit_N, vec3 specular_direction, vec3 dir, bool alpha_tested, vec3 diffuse_albedo, vec3 specular_albedo) {
			float weight;
			vec4 specular_gi;
			radiance_cache_lookup_at_hit = true;
			vec4 gi = gi_sample_irradiance_pair(P, hit_N, hit_N, specular_direction, -dir, false, alpha_tested ? RADIANCE_CACHE_NO_VISIBILITY_RAYS : RADIANCE_CACHE_CONTRAST_VISIBILITY_RAYS, weight, specular_gi);
			radiance_cache_lookup_at_hit = false;

			if (!gi_covers(P, weight)) {
				float open_sky = scene_hit_open_sky(P + hit_N * 0.02 * ]] .. block_name .. [[.view_scale, hit_N, P);
				gi.rgb = sample_environment_irradiance(radiance_cache_data.radiance_cache_env_irradiance_tex, hit_N) * open_sky;
				specular_gi.rgb = sample_environment_irradiance(radiance_cache_data.radiance_cache_env_irradiance_tex, specular_direction) * open_sky;
			}

			#ifdef SCENE_HIT_GI_SHARE
			gi.rgb /= SCENE_HIT_GI_SHARE;
			specular_gi.rgb /= SCENE_HIT_GI_SHARE;
			#endif

			return diffuse_albedo * gi.rgb + specular_albedo * specular_gi.rgb;
		}

		#ifdef SCENE_HIT_DEFER_PROBE_LIGHT
		bool scene_hit_probe_light_deferred = false;
		vec3 scene_hit_deferred_specular_direction;
		vec3 scene_hit_deferred_diffuse_albedo;
		vec3 scene_hit_deferred_specular_albedo;
		#endif

		vec3 shade_scene_hit(vec3 origin, vec3 dir, float roughness, float t, uint hit_instance, uint hit_primitive, vec2 hit_barycentrics) {
			scene_triangle tri = scene_hit_tri(hit_instance, hit_primitive);
			ray_material material = ray_materials[tri.material];
			vec3 hit_N = -tri.normal;

			if (dot(dir, hit_N) > 0.0) {
				if (material.double_sided == 0) return vec3(0.0);

				hit_N = -hit_N;
			}

			vec3 P = origin + dir * t;
			vec3 surface = P + hit_N * 0.02 * ]] .. block_name .. [[.view_scale;
			vec3 albedo = ray_material_albedo(material, P);
			float hit_roughness = material.roughness;
			float metallic = material.metallic;
			float transmission = saturate(material.transmission);

			#if RT_HIT_TEXTURES
			if (material.terrain_tex < 0 && material.albedo_tex >= 0) {
				vec2 barycentrics = hit_barycentrics;
				scene_uv uv = scene_hit_uv(hit_instance, hit_primitive);
				vec3 weights = vec3(1.0 - barycentrics.x - barycentrics.y, barycentrics);
				vec2 coord = uv.uv0 * weights.x + uv.uv1 * weights.y + uv.uv2 * weights.z;
				float cone_width = t * (SCENE_HIT_CONE + roughness * roughness * 0.25);
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

				if (material.roughness_tex >= 0) hit_roughness *= mix(material.roughness_min, material.roughness_max, textureLod(TEXTURE(material.roughness_tex), coord, scene_hit_texture_lod(tri, uv, textureSize(TEXTURE(material.roughness_tex), 0), cone_width))[material.roughness_channel]);

				if (material.metallic_tex >= 0) metallic *= textureLod(TEXTURE(material.metallic_tex), coord, scene_hit_texture_lod(tri, uv, textureSize(TEXTURE(material.metallic_tex), 0), cone_width))[material.metallic_channel];

				if (transmission > 0.0 && material.transmission_tex >= 0) transmission = saturate(material.transmission * luminance(textureLod(TEXTURE(material.transmission_tex), coord, scene_hit_texture_lod(tri, uv, textureSize(TEXTURE(material.transmission_tex), 0), cone_width)).rgb));
			}
			#endif

			albedo = ray_medium_albedo(material, ray_material_decal_albedo(material, P, hit_N, albedo));
			vec3 radiance = SCENE_HIT_EMISSION ? ray_hit_emission(tri, albedo, P, hit_instance, hit_primitive, dir) : vec3(0.0);

			if (SCENE_HIT_BOUNCE) albedo = radiance_cache_bounce_albedo(albedo);

			metallic = saturate(metallic);
			hit_brdf brdf = hit_brdf_prepare(albedo, metallic, material.specular, clamp(hit_roughness, 0.045, 1.0), material.diffuse_roughness, dot(hit_N, -dir));
			vec3 sun_L = normalize(radiance_cache_data.radiance_cache_sun_direction.xyz);
			float sun_NoL = dot(hit_N, sun_L);
			vec3 transmitted = transmission * material.transmission_color * albedo * (1.0 - metallic);
			vec3 back_surface = P - hit_N * 0.02 * ]] .. block_name .. [[.view_scale;
			vec3 sun_surface = sun_NoL > 0.0 ? surface : back_surface;

			if (RT_HIT_SUN != 0 && (sun_NoL > 0.0 || transmission > 0.0) && (RT_HIT_SHADOWS == 0 || scene_hit_visible(sun_surface, sun_L, SCENE_HIT_MAX_DISTANCE))) {
				float fog_altitude = ]] .. string.format("%.17g", atmosphere.SEA_LEVEL_HEIGHT) .. [[ + P.y * ]] .. string.format("%.17g", atmosphere.METERS_TO_UNITS) .. [[;
				vec3 response = sun_NoL > 0.0 ? hit_brdf_light(brdf, hit_N, -dir, sun_L, brdf.alpha + ]] .. string.format("%.9e", atmosphere.SUN_ANGULAR_RADIUS * 0.5) .. [[) : transmitted * transmission_phase(-dir, sun_L, -sun_NoL, material.transmission_scattering) * -sun_NoL;
				vec3 sun_radiance = response * radiance_cache_data.radiance_cache_sun_radiance.rgb * get_cloud_shadow(P) * radiance_cache_ground_fog_sun_transmittance(fog_altitude, sun_L.y, radiance_cache_data.radiance_cache_ground_fog.x, radiance_cache_data.radiance_cache_ground_fog.y, radiance_cache_data.radiance_cache_ground_fog.z, radiance_cache_data.radiance_cache_ground_fog_range.x, radiance_cache_data.radiance_cache_ground_fog_range.y);

				if (]] .. block_name .. [[.light_transmittance != 0) sun_radiance *= get_light_transmittance(sun_surface, sun_L, OPTICAL_SUN_DISTANCE, 0.0, false, caustic_hit_covered(int(radiance_cache_data.caustic_sun.w), vec3(0.0), P));

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
				int picked_index[RT_HIT_LIGHT_SAMPLES];
				float u[RT_HIT_LIGHT_SAMPLES];

				for (int k = 0; k < RT_HIT_LIGHT_SAMPLES; k++) {
					picked_weight[k] = 0.0;
					u[k] = scene_hit_random(P, -1 - k);
				}

				for (int w = 0; w < light_grid_words(light_count); w++) {
					uint light_bits = light_grid_word(light_cell, w, light_count);

					while (light_bits != 0u) {
						int i = w * 32 + findLSB(light_bits);
						light_bits &= light_bits - 1u;
						lights_t light = scene_light(]] .. block_name .. [[.lights, i);

						if (get_light_type(light) == 0) continue;

						vec3 L;
						float attenuation;

						if (!get_light_vector_and_attenuation(light, surface, L, attenuation)) continue;

						float NoL = dot(hit_N, L);

						if (NoL <= 0.0) continue;

						vec3 contribution = hit_brdf_light(brdf, hit_N, -dir, L, brdf.alpha) * light.color.rgb * light.color.a * attenuation;
						float weight = max(max(contribution.r, contribution.g), contribution.b);

						if (weight <= 0.0) continue;

						total += weight;
						float p = weight / total;

						for (int k = 0; k < RT_HIT_LIGHT_SAMPLES; k++) {
							if (u[k] < p) {
								picked_light[k] = contribution;
								picked_ray[k] = vec4(L, dot(light.position.xyz - surface, L));
								picked_weight[k] = weight;
								picked_index[k] = i;
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

					if (RT_HIT_SHADOWS != 0 && dist > 0.05 * ]] .. block_name .. [[.view_scale && !scene_hit_visible(surface, picked_ray[k].xyz, dist - 0.05 * ]] .. block_name .. [[.view_scale)) continue;

					vec3 contribution = picked_light[k];

					if (]] .. block_name .. [[.light_transmittance != 0) contribution *= get_light_transmittance(surface, picked_ray[k].xyz, max(dist - 0.05 * ]] .. block_name .. [[.view_scale, 0.0), 0.0, true, caustic_hit_covered(picked_index[k], scene_light(]] .. block_name .. [[.lights, picked_index[k]).position.xyz, P));

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
					lights_t light = scene_light(]] .. block_name .. [[.lights, i);

					if (get_light_type(light) == 0) continue;

					vec3 L;
					float attenuation;

					if (!get_light_vector_and_attenuation(light, surface, L, attenuation)) continue;

					float NoL = dot(hit_N, L);

					if (NoL <= 0.0) continue;

					vec3 contribution = hit_brdf_light(brdf, hit_N, -dir, L, brdf.alpha) * light.color.rgb * light.color.a * attenuation;
					float light_weight = scene_hit_light_weight(contribution, P, i);

					if (light_weight == 0.0) continue;

					float dist = dot(light.position.xyz - surface, L);

					if (RT_HIT_SHADOWS != 0 && dist > 0.05 * ]] .. block_name .. [[.view_scale && !scene_hit_visible(surface, L, dist - 0.05 * ]] .. block_name .. [[.view_scale)) continue;

					if (]] .. block_name .. [[.light_transmittance != 0) contribution *= get_light_transmittance(surface, L, max(dist - 0.05 * ]] .. block_name .. [[.view_scale, 0.0), 0.0, true, caustic_hit_covered(i, light.position.xyz, P));

					radiance += contribution * light_weight;
				}
			}
			#endif

			radiance += (hit_brdf_ambient_diffuse(brdf) + brdf.specular_albedo) * caustic_world_irradiance(P, hit_N) / 3.14159265359;

			#if !RT_HIT_PROBES
			return radiance;
			#endif

			if (transmission > 0.0) {
				float back_weight;
				vec3 back = gi_sample_irradiance(P, -hit_N, -dir, false, RADIANCE_CACHE_NO_VISIBILITY_RAYS, back_weight).rgb;

				if (!gi_covers(P, back_weight)) back = sample_environment_irradiance(radiance_cache_data.radiance_cache_env_irradiance_tex, -hit_N) * scene_hit_open_sky(back_surface, -hit_N, P);

				radiance += transmitted * back;
			}

			#ifdef SCENE_HIT_SCREEN_GI
			vec3 screen_gi;

			if (scene_hit_screen_gi(P, hit_N, t, screen_gi)) return radiance + (hit_brdf_ambient_diffuse(brdf) + brdf.specular_albedo) * screen_gi;
			#endif

			#ifdef SCENE_HIT_GI_SHARE
			if (SCENE_HIT_GI_SHARE <= 0.0) return radiance;
			#endif

			vec3 specular_direction = hit_brdf_specular_direction(brdf, hit_N, -dir);

			#ifdef SCENE_HIT_DEFER_PROBE_LIGHT
			scene_hit_probe_light_deferred = true;
			scene_hit_deferred_specular_direction = specular_direction;
			scene_hit_deferred_diffuse_albedo = hit_brdf_ambient_diffuse(brdf);
			scene_hit_deferred_specular_albedo = brdf.specular_albedo;
			return radiance;
			#else
			return radiance + scene_hit_probe_light(P, hit_N, specular_direction, dir, scene_instance_alpha_tested(hit_instance), hit_brdf_ambient_diffuse(brdf), brdf.specular_albedo);
			#endif
		}

		vec3 scene_radiance_through_air(vec3 radiance, vec3 origin, vec3 dir, float hit_t, float max_distance, float segment_pick) {
			bool fog_hit = ]] .. block_name .. [[.hit_fog != 0 && hit_t < max_distance;

			if (]] .. block_name .. [[.optical_tint != 0) radiance *= get_optical_tint(origin, dir, hit_t, fog_hit);

			if (fog_hit) {
				vec3 fog_origin = get_atmosphere_camera_origin(origin);
				vec3 fog_ambient = radiance_cache_fog_ambient();
				vec3 fog_sun = ATMOSPHERE_SUN_ILLUMINANCE * SUN_COLOR * sample_transmittance_lut(fog_origin, ATMOSPHERE_SKY_SUN_DIRECTION) * ATMOSPHERE_FOG_RAY_STRENGTH;
				radiance += optical_inscatter_lit(origin, dir, hit_t, fog_ambient, fog_sun, ATMOSPHERE_SKY_SUN_DIRECTION, true, segment_pick);
			}

			return radiance;
		}

		vec3 trace_scene_radiance(vec3 origin, vec3 dir, vec3 N, float roughness, float max_distance, out float hit_t) {
			vec3 radiance = trace_scene_radiance_unfogged(origin, dir, N, roughness, max_distance, hit_t);
			return scene_radiance_through_air(radiance, origin, dir, hit_t, max_distance, -1.0);
		}
	]]
end

return scene_hits
