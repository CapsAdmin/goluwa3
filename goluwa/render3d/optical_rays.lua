local ray_materials = import("goluwa/render3d/scene/ray_materials.lua")
local pvars = import("goluwa/cli/pvars.lua")
local render = import("goluwa/render/render.lua")
local hit = import("goluwa/render3d/scene/hit.lua")
local Material = import("goluwa/render3d/material.lua")
local scene_instances = import("goluwa/render3d/scene/instances.lua")
local optical_rays = {}
optical_rays.RAY_QUERY = render.GetDevice().ray_query_supported
optical_rays.SUN_DISTANCE = 300
optical_rays.TRANSMITTANCE = 0.9
pvars.StartGroup("Lighting", "Optical rays", {store = false})
local enabled = pvars.Setup2{
	key = "r_light_transmittance",
	default = true,
	friendly = "transparent bodies tint light",
	help = "light passing through glass and media bodies takes on their colour and absorption along a ray instead of being blocked by the shadow map, so glass casts no shadow of its own",
}
local max_distance = pvars.Setup2{
	key = "r_optical_ray_distance",
	default = 4000,
	min = 1,
	help = "how far optical rays (light transmittance, body exits) look for transparent bodies, in meters. built into the shaders",
}
pvars.EndGroup()

function optical_rays.GetMaxDistance()
	return max_distance:Get()
end

function optical_rays.IsEnabled()
	return optical_rays.RAY_QUERY and enabled:Get()
end

Material.GlassCastsShadow = function()
	return not optical_rays.IsEnabled()
end

function optical_rays.GetDeclarationGLSL(bindings)
	return hit.GetSceneGLSL("scene_tlas", bindings.scene) .. hit.GetGLSL(bindings.hit) .. ray_materials.GetMaterialDeclarationsGLSL(bindings.materials)
end

function optical_rays.GetGlassThroughGLSL()
	return [[
		#ifndef OPTICAL_GLASS_THROUGH
		#define OPTICAL_GLASS_THROUGH
		vec3 optical_glass_through(ray_material material, uint instance, uint primitive, vec2 barycentrics) {
			if (material.albedo_tex < 0) return material.albedo * ]] .. string.format("%.2f", optical_rays.TRANSMITTANCE) .. [[;

			scene_uv uv = scene_hit_uv(instance, primitive);
			ivec2 size = textureSize(TEXTURE(material.albedo_tex), 0);
			vec4 texel = textureLod(TEXTURE(material.albedo_tex), uv.uv0 * (1.0 - barycentrics.x - barycentrics.y) + uv.uv1 * barycentrics.x + uv.uv2 * barycentrics.y, max(log2(float(max(size.x, size.y)) / 64.0), 0.0));
			return mix(vec3(1.0), material.albedo * texel.rgb, texel.a) * ]] .. string.format("%.2f", optical_rays.TRANSMITTANCE) .. [[;
		}
		#endif
	]]
end

function optical_rays.GetGLSL()
	return ray_materials.GetOpticalTintGLSL() .. hit.GetOccludedGLSL("scene_tlas") .. optical_rays.GetGlassThroughGLSL() .. [[
		#define OPTICAL_RAYS
		#define OPTICAL_SUN_DISTANCE ]] .. string.format("%.1f", optical_rays.SUN_DISTANCE) .. [[

		vec3 get_material_medium_transmittance(ray_material material) {
			return medium_transmittance(material.medium_extinction, medium_scattering_at(material.medium_scattering, material.medium_porous_scattering, material.medium_porosity), material.medium_g, material.medium_thickness);
		}

		ivec3 get_optical_header() {
			return optical_counts;
		}

		vec3 get_optical_tint_ray(vec3 origin, vec3 dir, float distance, bool through_medium, bool caustic) {
			ivec3 header = get_optical_header();

			if (header.x == 0 && (!through_medium || header.y == 0)) return vec3(1.0);

			vec3 transmitted = vec3(1.0);
			rayQueryEXT query;
			rayQueryInitializeEXT(query, scene_tlas, gl_RayFlagsCullOpaqueEXT, ]] .. string.format("0x%02X", scene_instances.MASK_GLASS) .. [[, origin, 0.0, dir, min(distance, ]] .. string.format("%.1f", max_distance:Get()) .. [[));

			while (rayQueryProceedEXT(query)) {
				uint instance = uint(rayQueryGetIntersectionInstanceCustomIndexEXT(query, false));
				ray_material material = ray_materials[scene_instance_material(instance)];
				bool front = rayQueryGetIntersectionFrontFaceEXT(query, false);

				if (material.glass != 0) {
					// the caustic photons carry this light
					if (caustic && material.caustic != 0) return vec3(0.0);

					if (material.double_sided == 0 && front) continue;

					vec3 through = ray_material_has_medium(material) ? get_material_medium_transmittance(material) : optical_glass_through(material, instance, scene_query_primitive(query, false), rayQueryGetIntersectionBarycentricsEXT(query, false));

					transmitted *= clamp(material.glass_refraction * through + (1.0 - material.glass_refraction) * (1.0 - material.glass_covering), vec3(0.0), vec3(1.0));
				} else if (through_medium && ray_material_has_medium(material)) {
					if (material.medium_body > 0.0 && front) continue;

					transmitted *= get_material_medium_transmittance(material);
				}
			}

			return transmitted;
		}

		vec3 get_medium_volume_tint(vec3 origin, vec3 dir, float distance, bool light_ray, bool with_layer, bool caustic) {
			return optical_range_tint(0, get_optical_header().z, origin, dir, distance, light_ray, with_layer, caustic);
		}

		float get_body_exit(vec3 origin, vec3 dir, float max_distance, out vec3 outward_normal) {
			outward_normal = vec3(0.0);

			if (dot(dir, dir) < 0.5 || get_optical_header().x + get_optical_header().y == 0) return 0.0;

			float exit_distance = 0.0;
			uint exit_instance = 0u;
			uint exit_primitive = 0u;
			vec2 exit_barycentrics = vec2(0.0);
			rayQueryEXT query;
			rayQueryInitializeEXT(query, scene_tlas, gl_RayFlagsCullBackFacingTrianglesEXT, ]] .. string.format("0x%02X", scene_instances.MASK_GLASS) .. [[, origin, 0.001, normalize(dir), max_distance);

			// committing each accepted face shortens the ray to it, or traversal hands back every face of every layer up to max_distance
			while (rayQueryProceedEXT(query)) {
				ray_material material = ray_materials[scene_instance_material(uint(rayQueryGetIntersectionInstanceCustomIndexEXT(query, false)))];

				if (!rayQueryGetIntersectionFrontFaceEXT(query, false) || (material.glass == 0 && !ray_material_has_medium(material))) continue;

				float t = rayQueryGetIntersectionTEXT(query, false);

				if (exit_distance == 0.0 || t < exit_distance) {
					exit_distance = t;
					exit_instance = uint(rayQueryGetIntersectionInstanceCustomIndexEXT(query, false));
					exit_primitive = scene_query_primitive(query, false);
					exit_barycentrics = rayQueryGetIntersectionBarycentricsEXT(query, false);
					rayQueryConfirmIntersectionEXT(query);
				}
			}

			if (exit_distance > 0.0) {
				vec3 normal = scene_hit_smooth_normal(exit_instance, exit_primitive, exit_barycentrics);
				outward_normal = dot(normal, dir) < 0.0 ? -normal : normal;
			}

			return exit_distance;
		}

		vec3 get_optical_tint(vec3 origin, vec3 dir, float distance, bool with_layer) {
			return get_optical_tint_ray(origin, dir, distance, true, false) * get_medium_volume_tint(origin, dir, min(distance, ]] .. string.format("%.1f", max_distance:Get()) .. [[), false, with_layer, false);
		}

		vec3 get_light_transmittance_with(vec3 origin, vec3 dir, float distance, float search_radius, bool with_layer, bool caustic_glass, bool caustic_water) {
			vec3 transmitted = get_optical_tint_ray(origin, dir, distance, false, caustic_glass);

			if (search_radius > 0.0 && min(transmitted.r, min(transmitted.g, transmitted.b)) > 0.999) {
				vec3 tangent = normalize(cross(dir, abs(dir.y) < 0.99 ? vec3(0.0, 1.0, 0.0) : vec3(1.0, 0.0, 0.0))) * search_radius;
				vec3 bitangent = normalize(cross(dir, tangent)) * search_radius;
				transmitted = min(transmitted, get_optical_tint_ray(origin + tangent, dir, distance, false, caustic_glass));
				transmitted = min(transmitted, get_optical_tint_ray(origin - tangent, dir, distance, false, caustic_glass));
				transmitted = min(transmitted, get_optical_tint_ray(origin + bitangent, dir, distance, false, caustic_glass));
				transmitted = min(transmitted, get_optical_tint_ray(origin - bitangent, dir, distance, false, caustic_glass));
			}

			return transmitted * get_medium_volume_tint(origin, dir, min(distance, ]] .. string.format("%.1f", max_distance:Get()) .. [[), true, with_layer, caustic_water);
		}

		vec3 get_light_transmittance(vec3 origin, vec3 dir, float distance, float search_radius) {
			return get_light_transmittance_with(origin, dir, distance, search_radius, false, false, false);
		}

		vec3 get_light_transmittance_caustic(vec3 origin, vec3 dir, float distance, float search_radius) {
			return get_light_transmittance_with(origin, dir, distance, search_radius, false, true, true);
		}

		vec3 get_light_transmittance_local(vec3 origin, vec3 dir, float distance, float search_radius) {
			return get_light_transmittance_with(origin, dir, distance, search_radius, true, false, false);
		}

		vec3 get_light_transmittance_local_caustic(vec3 origin, vec3 dir, float distance, float search_radius) {
			return get_light_transmittance_with(origin, dir, distance, search_radius, true, true, true);
		}

		vec3 optical_inscatter_lit(vec3 origin, vec3 dir, float distance, vec3 ambient, vec3 sun_radiance, vec3 sun_dir, bool with_layer) {
			if (get_optical_header().y + get_optical_header().z == 0) return vec3(0.0);

			// what scatters in is what the volumes take out along the ray: a ray that loses nothing to them needs none of the visibility rays below
			vec3 through = get_medium_volume_tint(origin, dir, distance, false, with_layer, false);

			if (min(through.r, min(through.g, through.b)) > 0.9999) return vec3(0.0);

			vec3 sun_visibility = vec3(0.0);

			if (dot(sun_radiance, sun_radiance) > 0.0) {
				for (int k = 0; k < 3; k++) sun_visibility[k] = scene_occluded(origin + dir * (distance * (float(k) + 0.5) / 3.0), sun_dir, 0.01, 1.0e4) ? 0.0 : 1.0;
			}

			vec3 ambient_visibility = vec3(0.0);

			if (dot(ambient, ambient) > 0.0) {
				for (int k = 0; k < 3; k++) ambient_visibility[k] = scene_occluded(origin + dir * (distance * (float(k) + 0.5) / 3.0), vec3(0.0, 1.0, 0.0), 0.01, 1.0e4) ? 0.0 : 1.0;
			}

			return optical_inscatter(origin, dir, distance, ambient, ambient_visibility, sun_radiance, sun_dir, sun_visibility, with_layer);
		}

]]
end

function optical_rays.GetStubGLSL()
	return [[
		vec3 get_light_transmittance(vec3 origin, vec3 dir, float distance, float search_radius) {
			return vec3(1.0);
		}

		vec3 get_light_transmittance_caustic(vec3 origin, vec3 dir, float distance, float search_radius) {
			return vec3(1.0);
		}

		vec3 get_light_transmittance_local(vec3 origin, vec3 dir, float distance, float search_radius) {
			return vec3(1.0);
		}

		vec3 get_light_transmittance_local_caustic(vec3 origin, vec3 dir, float distance, float search_radius) {
			return vec3(1.0);
		}

		vec3 optical_inscatter_lit(vec3 origin, vec3 dir, float distance, vec3 ambient, vec3 sun_radiance, vec3 sun_dir, bool with_layer) {
			return vec3(0.0);
		}

		vec3 get_optical_tint(vec3 origin, vec3 dir, float distance, bool with_layer) {
			return vec3(1.0);
		}
	]]
end

return optical_rays
