local pvars = import("goluwa/cli/pvars.lua")
local render = import("goluwa/render/render.lua")
local ddgi = import("goluwa/render3d/ddgi.lua")
local hit = import("goluwa/render3d/scene/hit.lua")
local rt = import("goluwa/render3d/scene/rt.lua")
local Material = import("goluwa/render3d/material.lua")
local scene_instances = import("goluwa/render3d/scene/instances.lua")
local glass_light = {}
glass_light.RAY_QUERY = render.GetDevice().ray_query_supported
glass_light.SUN_DISTANCE = 300
glass_light.TRANSMITTANCE = 0.9
pvars.StartGroup("Lighting", "Glass light", {store = false})
local enabled = pvars.Setup2{
	key = "r_glass_light",
	default = true,
	friendly = "glass tints light",
	help = "lights take on the colour of the glass between them and a surface, glass casts no shadow of its own",
}
local max_distance = pvars.Setup2{
	key = "r_glass_light_distance",
	default = 4000,
	min = 1,
	help = "how far a ray looks for glass in front of what it lights, in meters, glass further away does not tint it. built into the shaders",
}
pvars.EndGroup()

function glass_light.GetMaxDistance()
	return max_distance:Get()
end

function glass_light.IsEnabled()
	return glass_light.RAY_QUERY and enabled:Get()
end

Material.GlassCastsShadow = function()
	return not glass_light.IsEnabled()
end

function glass_light.GetDescriptorSets(bindings, stage)
	local sets = hit.GetDescriptorSets(bindings.hit, stage, bindings.scene)
	sets[#sets + 1] = {type = "storage_buffer", binding_index = bindings.materials, stageFlags = stage}
	return sets
end

do
	local bound = setmetatable({}, {__mode = "k"})

	function glass_light.Bind(self, cmd, desc, bindings)
		local materials = ddgi.WriteMaterialBuffer(self)
		local tlas = rt.GetTLAS(cmd)
		bound[self] = bound[self] or {}
		local last = bound[self][desc]

		if not last then
			last = {}
			bound[self][desc] = last
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

function glass_light.GetDeclarationGLSL(bindings)
	return hit.GetSceneGLSL("glass_light_scene", bindings.scene) .. hit.GetGLSL(bindings.hit) .. ddgi.GetMaterialDeclarationsGLSL(bindings.materials)
end

function glass_light.GetGLSL(scene_name)
	return ddgi.GetOpticalTintGLSL() .. [[
		#define GLASS_LIGHT
		#define GLASS_SUN_DISTANCE ]] .. string.format("%.1f", glass_light.SUN_DISTANCE) .. [[

		vec3 get_material_medium_transmittance(ddgi_material material) {
			return medium_transmittance(material.medium_extinction, medium_scattering_at(material.medium_scattering, material.medium_porous_scattering, material.medium_porosity), material.medium_g, material.medium_thickness);
		}

		ivec3 get_optical_header() {
			return optical_counts;
		}

		vec3 get_optical_tint_ray(vec3 origin, vec3 dir, float distance, bool through_medium) {
			ivec3 header = get_optical_header();

			if (header.x == 0 && (!through_medium || header.y == 0)) return vec3(1.0);

			vec3 transmitted = vec3(1.0);
			rayQueryEXT query;
			rayQueryInitializeEXT(query, ]] .. scene_name .. [[, gl_RayFlagsCullOpaqueEXT, ]] .. string.format("0x%02X", scene_instances.MASK_GLASS) .. [[, origin, 0.0, dir, min(distance, ]] .. string.format("%.1f", max_distance:Get()) .. [[));

			while (rayQueryProceedEXT(query)) {
				ddgi_material material = ddgi_materials[scene_instance_material(uint(rayQueryGetIntersectionInstanceCustomIndexEXT(query, false)))];
				bool front = rayQueryGetIntersectionFrontFaceEXT(query, false);

				if (material.glass != 0) {
					if (material.double_sided == 0 && front) continue;

					vec3 through;

					if (ddgi_has_medium(material)) {
						through = get_material_medium_transmittance(material);
					} else {
						through = material.albedo;

						if (material.albedo_tex >= 0) through *= textureLod(TEXTURE(material.albedo_tex), vec2(0.5), 16.0).rgb;

						through *= ]] .. string.format("%.2f", glass_light.TRANSMITTANCE) .. [[;
					}

					transmitted *= clamp(material.glass_refraction * through + (1.0 - material.glass_refraction) * (1.0 - material.glass_covering), vec3(0.0), vec3(1.0));
				} else if (through_medium && ddgi_has_medium(material)) {
					if (material.medium_body > 0.0 && front) continue;

					transmitted *= get_material_medium_transmittance(material);
				}
			}

			return transmitted;
		}

		vec3 get_medium_volume_tint(vec3 origin, vec3 dir, float distance, bool light_ray, bool with_layer) {
			return optical_range_tint(0, get_optical_header().z, origin, dir, distance, light_ray, with_layer);
		}

		float get_glass_body_exit(vec3 origin, vec3 dir, float max_distance, out vec3 outward_normal) {
			outward_normal = vec3(0.0);

			if (dot(dir, dir) < 0.5 || get_optical_header().x + get_optical_header().y == 0) return 0.0;

			float exit_distance = 0.0;
			uint exit_instance = 0u;
			uint exit_primitive = 0u;
			vec2 exit_barycentrics = vec2(0.0);
			rayQueryEXT query;
			rayQueryInitializeEXT(query, ]] .. scene_name .. [[, gl_RayFlagsNoneEXT, ]] .. string.format("0x%02X", scene_instances.MASK_GLASS) .. [[, origin, 0.001, normalize(dir), max_distance);

			while (rayQueryProceedEXT(query)) {
				ddgi_material material = ddgi_materials[scene_instance_material(uint(rayQueryGetIntersectionInstanceCustomIndexEXT(query, false)))];

				if (!rayQueryGetIntersectionFrontFaceEXT(query, false) || (material.glass == 0 && !ddgi_has_medium(material))) continue;

				float t = rayQueryGetIntersectionTEXT(query, false);

				if (exit_distance == 0.0 || t < exit_distance) {
					exit_distance = t;
					exit_instance = uint(rayQueryGetIntersectionInstanceCustomIndexEXT(query, false));
					exit_primitive = uint(rayQueryGetIntersectionPrimitiveIndexEXT(query, false));
					exit_barycentrics = rayQueryGetIntersectionBarycentricsEXT(query, false);
				}
			}

			if (exit_distance > 0.0) {
				vec3 normal = scene_hit_smooth_normal(exit_instance, exit_primitive, exit_barycentrics);
				outward_normal = dot(normal, dir) < 0.0 ? -normal : normal;
			}

			return exit_distance;
		}

		vec3 get_optical_tint(vec3 origin, vec3 dir, float distance, bool with_layer) {
			return get_optical_tint_ray(origin, dir, distance, true) * get_medium_volume_tint(origin, dir, min(distance, ]] .. string.format("%.1f", max_distance:Get()) .. [[), false, with_layer);
		}

		vec3 get_glass_light_with(vec3 origin, vec3 dir, float distance, float search_radius, bool with_layer) {
			vec3 transmitted = get_optical_tint_ray(origin, dir, distance, false);

			if (search_radius > 0.0 && min(transmitted.r, min(transmitted.g, transmitted.b)) > 0.999) {
				vec3 tangent = normalize(cross(dir, abs(dir.y) < 0.99 ? vec3(0.0, 1.0, 0.0) : vec3(1.0, 0.0, 0.0))) * search_radius;
				vec3 bitangent = normalize(cross(dir, tangent)) * search_radius;
				transmitted = min(transmitted, get_optical_tint_ray(origin + tangent, dir, distance, false));
				transmitted = min(transmitted, get_optical_tint_ray(origin - tangent, dir, distance, false));
				transmitted = min(transmitted, get_optical_tint_ray(origin + bitangent, dir, distance, false));
				transmitted = min(transmitted, get_optical_tint_ray(origin - bitangent, dir, distance, false));
			}

			return transmitted * get_medium_volume_tint(origin, dir, min(distance, ]] .. string.format("%.1f", max_distance:Get()) .. [[), true, with_layer);
		}

		vec3 get_glass_light(vec3 origin, vec3 dir, float distance, float search_radius) {
			return get_glass_light_with(origin, dir, distance, search_radius, false);
		}

		vec3 get_glass_light_local(vec3 origin, vec3 dir, float distance, float search_radius) {
			return get_glass_light_with(origin, dir, distance, search_radius, true);
		}

		float get_medium_sun_visibility(vec3 point, vec3 sun_dir) {
			rayQueryEXT query;
			rayQueryInitializeEXT(query, ]] .. scene_name .. [[, gl_RayFlagsOpaqueEXT | gl_RayFlagsTerminateOnFirstHitEXT, ]] .. string.format("0x%02X", scene_instances.MASK_SOLID) .. [[, point, 0.01, sun_dir, 1.0e4);
			while (rayQueryProceedEXT(query)) {}
			return rayQueryGetIntersectionTypeEXT(query, true) == gl_RayQueryCommittedIntersectionNoneEXT ? 1.0 : 0.0;
		}

		vec3 optical_inscatter_lit(vec3 origin, vec3 dir, float distance, vec3 ambient, vec3 sun_radiance, vec3 sun_dir, bool with_layer) {
			if (get_optical_header().y + get_optical_header().z == 0) return vec3(0.0);

			vec3 sun_visibility = vec3(0.0);

			if (dot(sun_radiance, sun_radiance) > 0.0) {
				for (int k = 0; k < 3; k++) sun_visibility[k] = get_medium_sun_visibility(origin + dir * (distance * (float(k) + 0.5) / 3.0), sun_dir);
			}

			return optical_inscatter(origin, dir, distance, ambient, sun_radiance, sun_dir, sun_visibility, with_layer);
		}

]]
end

function glass_light.GetStubGLSL()
	return [[
		vec3 get_glass_light(vec3 origin, vec3 dir, float distance, float search_radius) {
			return vec3(1.0);
		}

		vec3 get_glass_light_local(vec3 origin, vec3 dir, float distance, float search_radius) {
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

return glass_light
