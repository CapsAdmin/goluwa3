local render = import("goluwa/render/render.lua")
local pvars = import("goluwa/cli/pvars.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local ddgi = import("goluwa/render3d/ddgi.lua")
local scene_bvh = import("goluwa/render3d/scene_bvh.lua")
local scene_lights = import("goluwa/render3d/scene_lights.lua")
local light_grid = import("goluwa/render3d/light_grid.lua")
local glass_light = import("goluwa/render3d/glass_light.lua")
local scene_reflection = {}
scene_reflection.RAY_QUERY = render.GetDevice().ray_query_supported
scene_reflection.MAX_DISTANCE = 1000
pvars.StartGroup("reflection", {store = false})
local enabled = pvars.Setup2{
	key = "reflection_ray_query",
	default = true,
	help = "trace screen space reflection misses with ray queries",
}
local primary = pvars.Setup2{
	key = "reflection_ray_query_primary",
	default = true,
	help = "ray-traced reflections replace screen-space reflections and sample the textures of what they hit",
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
		{type = "storage_buffer", binding_index = bindings.uvs, stageFlags = stage, count = scene_bvh.SOUP_CHUNKS},
		bindings.light_grid and
		{
			type = "storage_buffer",
			binding_index = bindings.light_grid,
			stageFlags = stage,
		} or
		nil,
	}
end

do
	-- a set that a command buffer is still using can't be written to, so only what changed is
	local bound = setmetatable({}, {__mode = "k"})

	-- bindings.light_grid is left out by a pass that has the light grid already
	function scene_reflection.Bind(self, cmd, desc, bindings)
		local materials = ddgi.WriteMaterialBuffer(self)
		local tlas = render3d.IsPassEnabled("ddgi") and
			ddgi.GetFrameState().tlas or
			scene_bvh.GetPlaceholderTLAS(cmd)
		local triangles = scene_bvh.triangle_buffer or materials
		local uvs = scene_bvh.uv_buffer or materials
		bound[self] = bound[self] or {}
		local last = bound[self][desc]

		if not last then
			last = {}
			bound[self][desc] = last
		end

		if bindings.light_grid then light_grid.Bind(self, cmd, desc, bindings.light_grid) end

		if last.materials ~= materials then
			self:UpdateDescriptorSet("storage_buffer", desc, bindings.materials, 0, materials, materials:GetSize())
			last.materials = materials
		end

		if last.tlas ~= tlas then
			self:UpdateDescriptorSet("acceleration_structure_khr", desc, bindings.scene, 0, tlas)
			last.tlas = tlas
		end

		if last.triangles ~= triangles then
			scene_bvh.BindTriangleBuffer(self, desc, bindings.triangles, triangles)
			last.triangles = triangles
		end

		if last.uvs ~= uvs then
			scene_bvh.BindTriangleBuffer(self, desc, bindings.uvs, uvs, scene_bvh.UV_CHUNK_BYTES)
			last.uvs = uvs
		end
	end
end

-- shared is for a pass that has the light grid and ddgi_sample_irradiance's visibility rays turned
-- off already, it is not given the light grid and does not get the visibility rays
function scene_reflection.GetDeclarationGLSL(bindings, shared)
	return [[
		#extension GL_EXT_ray_query : require
		]] .. (shared and "" or "#define DDGI_VISIBILITY_RAYS") .. [[

		#define SCENE_REFLECTION
		layout(set = 0, binding = ]] .. bindings.scene .. [[) uniform accelerationStructureEXT ddgi_scene;
	]] .. scene_bvh.GetTriangleDeclarationGLSL(bindings.triangles) .. scene_bvh.GetUvDeclarationGLSL(bindings.uvs) .. ddgi.GetMaterialDeclarationsGLSL(bindings.materials) .. (
			bindings.light_grid and
			light_grid.GetGLSL(bindings.light_grid) or
			""
		)
end

function scene_reflection.IsEnabled()
	return enabled:Get()
end

function scene_reflection.IsPrimary()
	return primary:Get()
end

scene_reflection.block = {
	{"lights", scene_lights.BuildLightsBlockLayout(), scene_lights.MAX_LIGHTS},
	{"light_count", "int"},
	{"reflection_primary", "int"},
	{"glass_light", "int"},
}

function scene_reflection.WriteBlock(self, block)
	local lights = render3d.GetLights()
	block.light_count = math.min(#lights, scene_lights.MAX_LIGHTS)
	block.reflection_primary = primary:Get() and 1 or 0
	block.glass_light = ddgi.HasGlass() and 1 or 0
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

-- shared is for a pass that has ddgi.GetCommonGLSL, the light code and get_glass_light before this
function scene_reflection.GetGLSL(block_name, shared)
	return (
			shared and
			"" or
			ddgi.GetCommonGLSL() .. scene_lights.GetLightGLSLCode()
		) .. ddgi.GetMaterialGLSL() .. ddgi.GetAlphaTestGLSL() .. (
			shared and
			"" or
			glass_light.GetGLSL("ddgi_scene")
		) .. [[
		#define SCENE_REFLECTION_MAX_DISTANCE ]] .. string.format("%.1f", scene_reflection.MAX_DISTANCE) .. [[

		#define SCENE_REFLECTION_LIGHT_FULL_RADIANCE 0.02

		// different for every point, light and frame, the reflections' histories average it out
		float scene_reflection_random(vec3 p, int light) {
			uvec3 v = uvec3(floatBitsToUint(p.x), floatBitsToUint(p.y), floatBitsToUint(p.z) ^ (uint(light) * 2654435761u + uint(ddgi_data.ddgi_frame) * 40503u));
			v = v * 1664525u + 1013904223u;
			v.x += v.y * v.z;
			v.y += v.z * v.x;
			v.z += v.x * v.y;
			v ^= v >> 16u;
			v.x += v.y * v.z;
			return float(v.x >> 8u) * (1.0 / 16777216.0);
		}

		// what a light that adds contribution (absolute luminance) at p counts for. a light that
		// shows dimmer than SCENE_REFLECTION_LIGHT_FULL_RADIANCE on screen (1 is white) is only
		// traced with a probability that falls with it, 0 when it isn't and the inverse of the
		// probability when it is, so the light that is left out is counted for in what is not
		float scene_reflection_light_weight(vec3 contribution, vec3 p, int light) {
			float probability = min(max(max(contribution.r, contribution.g), contribution.b) * get_exposure() / SCENE_REFLECTION_LIGHT_FULL_RADIANCE, 1.0);

			if (probability >= 1.0) return 1.0;

			return scene_reflection_random(p, light) < probability ? 1.0 / probability : 0.0;
		}

		bool scene_reflection_ready() {
			return ddgi_data.ddgi_rt_ready != 0;
		}

		// the scene hit owns visibility and is shaded with the hit's textures, screen space is not used
		bool scene_reflection_primary() {
			return ]]..block_name..[[.reflection_primary != 0;
		}

		// confirms the first solid hit, looking through glass and, when primary, respecting cutout textures
		#define SCENE_REFLECTION_PROCEED(query) \
			while (rayQueryProceedEXT(query)) { \
				uint candidate = uint(rayQueryGetIntersectionInstanceCustomIndexEXT(query, false)) * ]] .. scene_bvh.SOUP_ALIGN .. [[u + uint(rayQueryGetIntersectionPrimitiveIndexEXT(query, false)); \
				if (ddgi_materials[bvh_tri(candidate).material].transparent == 0 && (!scene_reflection_primary() || ddgi_alpha_passes(candidate, rayQueryGetIntersectionBarycentricsEXT(query, false)))) rayQueryConfirmIntersectionEXT(query); \
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

		// the hit is lit by the sun and lights through the glass in front of them, see trace_scene_reflection
		vec3 trace_scene_reflection_hit(vec3 origin, vec3 dir, vec3 N, float roughness, float max_distance, out float hit_t) {
			rayQueryEXT query;
			rayQueryInitializeEXT(query, ddgi_scene, gl_RayFlagsNoneEXT, 0xFF, origin, 0.0, dir, max_distance);

			SCENE_REFLECTION_PROCEED(query)

			hit_t = max_distance;

			if (rayQueryGetIntersectionTypeEXT(query, true) == gl_RayQueryCommittedIntersectionNoneEXT) {
				return sample_environment_specular(]] .. block_name .. [[.env_tex, dir, N, roughness);
			}

			float t = rayQueryGetIntersectionTEXT(query, true);
			hit_t = t;
			uint triangle = uint(rayQueryGetIntersectionInstanceCustomIndexEXT(query, true)) * ]] .. scene_bvh.SOUP_ALIGN .. [[u + uint(rayQueryGetIntersectionPrimitiveIndexEXT(query, true));
			scene_bvh_triangle tri = bvh_tri(triangle);
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

			if (scene_reflection_primary() && material.terrain_tex < 0 && material.albedo_tex >= 0) {
				vec2 barycentrics = rayQueryGetIntersectionBarycentricsEXT(query, true);
				scene_bvh_uv uv = bvh_uv(triangle);
				vec3 weights = vec3(1.0 - barycentrics.x - barycentrics.y, barycentrics);
				vec2 coord = uv.uv0 * weights.x + uv.uv1 * weights.y + uv.uv2 * weights.z;
				vec3 rgb = textureLod(TEXTURE(material.albedo_tex), coord, 0.0).rgb;

				if (material.albedo2_tex >= 0) {
					float blend = dot(uv.blend, weights);

					if (material.blend_tex >= 0) {
						vec2 modulate = textureLod(TEXTURE(material.blend_tex), coord, 0.0).rg;
						blend = smoothstep(clamp(modulate.g - modulate.r, 0.0, 1.0), clamp(modulate.g + modulate.r, 0.0, 1.0), blend);
					}

					rgb = mix(rgb, textureLod(TEXTURE(material.albedo2_tex), coord, 0.0).rgb, blend);
				}

				albedo = material.albedo * rgb;
			}

			vec3 radiance = ddgi_emission(tri, albedo);
			vec3 sun_L = normalize(ddgi_data.ddgi_sun_direction.xyz);
			float sun_NoL = dot(hit_N, sun_L);

			if (sun_NoL > 0.0 && scene_reflection_visible(surface, sun_L, SCENE_REFLECTION_MAX_DISTANCE)) {
				vec3 sun_radiance = albedo * ddgi_data.ddgi_sun_radiance.rgb * (sun_NoL / 3.14159265359);

				if (]]..block_name..[[.glass_light != 0) sun_radiance *= get_glass_light(surface, sun_L, GLASS_SUN_DISTANCE, 0.0);

				radiance += sun_radiance;
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

					vec3 contribution = albedo * light.color.rgb * light.color.a * attenuation * (NoL / 3.14159265359);
					float light_weight = scene_reflection_light_weight(contribution, P, i);

					if (light_weight == 0.0) continue;

					// stops short of the light so a bulb mesh around it doesn't shadow it
					float dist = dot(light.position.xyz - surface, L);

					if (dist > 0.05 && !scene_reflection_visible(surface, L, dist - 0.05)) continue;

					if (]]..block_name..[[.glass_light != 0) contribution *= get_glass_light(surface, L, max(dist - 0.05, 0.0), 0.0);

					radiance += contribution * light_weight;
				}
			}

			float weight;
			vec4 gi = ddgi_sample_irradiance(P, hit_N, hit_N, -dir, false, DDGI_NO_VISIBILITY_RAYS, weight);

			if (weight <= 0.0 && !ddgi_in_volume(P)) {
				// outside the probes nothing knows how much sky is open, and a hit in a
				// cave would be lit by all of it. estimate from rays around the normal
				vec3 tangent = normalize(cross(hit_N, abs(hit_N.y) < 0.99 ? vec3(0.0, 1.0, 0.0) : vec3(1.0, 0.0, 0.0)));
				vec3 bitangent = cross(hit_N, tangent);
				float spin = fract(sin(dot(P, vec3(12.9898, 78.233, 37.719))) * 43758.5453) * 6.28318530718;
				float open_sky = 0.0;

				for (int k = 0; k < 4; k++) {
					float phi = spin + float(k) * 1.57079632679;
					vec3 sky_dir = normalize(hit_N + tangent * cos(phi) + bitangent * sin(phi));

					if (scene_reflection_visible(surface, sky_dir, SCENE_REFLECTION_MAX_DISTANCE)) open_sky += 0.25;
				}

				gi.rgb = sample_environment_irradiance(ddgi_data.ddgi_env_irradiance_tex, hit_N) * open_sky;
			}

			return radiance + albedo * gi.rgb;
		}

		// radiance arriving at origin from dir, shaded like a ddgi probe ray's hit, after the glass the
		// ray passes through. hit_t is how far the hit is, max_distance when the ray went on to the sky
		vec3 trace_scene_reflection(vec3 origin, vec3 dir, vec3 N, float roughness, float max_distance, out float hit_t) {
			vec3 radiance = trace_scene_reflection_hit(origin, dir, N, roughness, max_distance, hit_t);

			if (]]..block_name..[[.glass_light != 0) radiance *= get_glass_light(origin, dir, hit_t, 0.0);

			return radiance;
		}
	]]
end

return scene_reflection
