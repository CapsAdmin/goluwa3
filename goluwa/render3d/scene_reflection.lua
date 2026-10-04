local render = import("goluwa/render/render.lua")
local pvars = import("goluwa/cli/pvars.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local ddgi = import("goluwa/render3d/ddgi.lua")
local scene_bvh = import("goluwa/render3d/scene_bvh.lua")
local scene_lights = import("goluwa/render3d/scene_lights.lua")
local light_grid = import("goluwa/render3d/light_grid.lua")
local scene_reflection = {}
scene_reflection.RAY_QUERY = render.GetDevice().ray_query_supported
scene_reflection.MAX_DISTANCE = 1000
pvars.StartGroup("reflection", {store = false})
local enabled = pvars.Setup2{
	key = "reflection_ray_query",
	default = true,
	help = "trace screen space reflection misses with ray queries",
}
pvars.EndGroup()

function scene_reflection.GetDescriptorSets(bindings, stage)
	return {
		{
			type = "acceleration_structure_khr",
			binding_index = bindings.scene,
			stageFlags = stage,
		},
		{
			type = "storage_buffer",
			binding_index = bindings.triangles,
			stageFlags = stage,
			count = scene_bvh.SOUP_CHUNKS,
		},
		{type = "storage_buffer", binding_index = bindings.materials, stageFlags = stage},
		{
			type = "storage_buffer",
			binding_index = bindings.light_grid,
			stageFlags = stage,
		},
	}
end

function scene_reflection.Bind(self, cmd, desc, bindings)
	local materials = ddgi.WriteMaterialBuffer(self)
	self:UpdateDescriptorSet("storage_buffer", desc, bindings.materials, 0, materials, materials:GetSize())
	light_grid.Bind(self, cmd, desc, bindings.light_grid)
	self:UpdateDescriptorSet(
		"acceleration_structure_khr",
		desc,
		bindings.scene,
		0,
		render3d.IsPassEnabled("ddgi") and
			ddgi.GetFrameState().tlas or
			scene_bvh.GetPlaceholderTLAS(cmd)
	)
	scene_bvh.BindTriangleBuffer(self, desc, bindings.triangles, scene_bvh.triangle_buffer or materials)
end

function scene_reflection.GetDeclarationGLSL(bindings)
	return [[
		#extension GL_EXT_ray_query : require
		#define DDGI_VISIBILITY_RAYS
		#define SCENE_REFLECTION
		layout(set = 0, binding = ]] .. bindings.scene .. [[) uniform accelerationStructureEXT ddgi_scene;
	]] .. scene_bvh.GetTriangleDeclarationGLSL(bindings.triangles) .. ddgi.GetMaterialDeclarationsGLSL(bindings.materials) .. light_grid.GetGLSL(bindings.light_grid)
end

scene_reflection.block = {
	{"lights", scene_lights.BuildLightsBlockLayout(), scene_lights.MAX_LIGHTS},
	{"light_count", "int"},
}

function scene_reflection.WriteBlock(self, block)
	local lights = render3d.GetLights()
	block.light_count = math.min(#lights, scene_lights.MAX_LIGHTS)
	scene_lights.WriteLightsBlock(block.lights, lights)
end

function scene_reflection.GetDDGIUniformBuffer(binding)
	return {
		name = "ddgi_data",
		binding_index = binding,
		block = ddgi.GetProbeBlockLayout(),
		write = function(self, block)
			if render3d.IsPassEnabled("ddgi") then
				ddgi.WriteProbeBlock(self, block)
			else
				block.ddgi_cascade_count = 0
				block.ddgi_rt_ready = 0
			end

			if not enabled:Get() then block.ddgi_rt_ready = 0 end

			return block
		end,
	}
end

function scene_reflection.GetGLSL(block_name)
	return ddgi.GetCommonGLSL() .. scene_lights.GetLightGLSLCode() .. ddgi.GetMaterialGLSL() .. [[
		#define SCENE_REFLECTION_MAX_DISTANCE ]] .. string.format("%.1f", scene_reflection.MAX_DISTANCE) .. [[

		bool scene_reflection_ready() {
			return ddgi_data.ddgi_rt_ready != 0;
		}

		// confirms the first solid hit, translucent and refractive surfaces are looked through
		#define SCENE_REFLECTION_PROCEED(query) \
			while (rayQueryProceedEXT(query)) { \
				uint candidate = uint(rayQueryGetIntersectionInstanceCustomIndexEXT(query, false)) * ]] .. scene_bvh.SOUP_ALIGN .. [[u + uint(rayQueryGetIntersectionPrimitiveIndexEXT(query, false)); \
				if (ddgi_materials[bvh_tri(candidate).material].transparent == 0) rayQueryConfirmIntersectionEXT(query); \
			}

		bool scene_reflection_visible(vec3 origin, vec3 dir, float dist) {
			rayQueryEXT query;
			rayQueryInitializeEXT(query, ddgi_scene, gl_RayFlagsTerminateOnFirstHitEXT, 0xFF, origin, 0.0, dir, dist);

			SCENE_REFLECTION_PROCEED(query)

			return rayQueryGetIntersectionTypeEXT(query, true) == gl_RayQueryCommittedIntersectionNoneEXT;
		}

		// how far along dir the scene is, max_distance when nothing is that close
		float scene_hit_distance(vec3 origin, vec3 dir, float max_distance) {
			rayQueryEXT query;
			rayQueryInitializeEXT(query, ddgi_scene, gl_RayFlagsNoneEXT, 0xFF, origin, 0.0, dir, max_distance);

			SCENE_REFLECTION_PROCEED(query)

			if (rayQueryGetIntersectionTypeEXT(query, true) == gl_RayQueryCommittedIntersectionNoneEXT) return max_distance;

			return rayQueryGetIntersectionTEXT(query, true);
		}

		// radiance arriving at origin from dir, shaded like a ddgi probe ray's hit. hit_t is how far
		// the hit is, max_distance when the ray went on to the sky
		vec3 trace_scene_reflection(vec3 origin, vec3 dir, vec3 N, float roughness, float max_distance, out float hit_t) {
			rayQueryEXT query;
			rayQueryInitializeEXT(query, ddgi_scene, gl_RayFlagsNoneEXT, 0xFF, origin, 0.0, dir, max_distance);

			SCENE_REFLECTION_PROCEED(query)

			hit_t = max_distance;

			if (rayQueryGetIntersectionTypeEXT(query, true) == gl_RayQueryCommittedIntersectionNoneEXT) {
				return sample_environment_specular(]] .. block_name .. [[.env_tex, dir, N, roughness);
			}

			float t = rayQueryGetIntersectionTEXT(query, true);
			hit_t = t;
			scene_bvh_triangle tri = bvh_tri(uint(rayQueryGetIntersectionInstanceCustomIndexEXT(query, true)) * ]] .. scene_bvh.SOUP_ALIGN .. [[u + uint(rayQueryGetIntersectionPrimitiveIndexEXT(query, true)));
			ddgi_material material = ddgi_materials[tri.material];
			// the visible side winds clockwise, so tri.normal points inward
			vec3 hit_N = -tri.normal;

			if (dot(dir, hit_N) > 0.0) {
				if (material.double_sided == 0) return vec3(0.0);

				hit_N = -hit_N;
			}

			vec3 P = origin + dir * t;
			vec3 surface = P + hit_N * 0.02;
			vec3 albedo = ddgi_albedo(material, P);
			vec3 radiance = ddgi_emission(tri, albedo);
			vec3 sun_L = normalize(ddgi_data.ddgi_sun_direction.xyz);
			float sun_NoL = dot(hit_N, sun_L);

			if (sun_NoL > 0.0 && scene_reflection_visible(surface, sun_L, SCENE_REFLECTION_MAX_DISTANCE)) {
				radiance += albedo * ddgi_data.ddgi_sun_radiance.rgb * (sun_NoL / 3.14159265359);
			}

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

					// stops short of the light so a bulb mesh around it doesn't shadow it
					float dist = dot(light.position.xyz - surface, L);

					if (dist > 0.05 && !scene_reflection_visible(surface, L, dist - 0.05)) continue;

					radiance += albedo * light.color.rgb * light.color.a * attenuation * (NoL / 3.14159265359);
				}
			}

			float weight;
			vec4 gi = ddgi_sample_irradiance(P, hit_N, -dir, false, weight);

			if (weight <= 0.0 && !ddgi_in_volume(P)) {
				gi.rgb = sample_environment_irradiance(ddgi_data.ddgi_env_irradiance_tex, hit_N);
			}

			return radiance + albedo * gi.rgb;
		}
	]]
end

return scene_reflection
