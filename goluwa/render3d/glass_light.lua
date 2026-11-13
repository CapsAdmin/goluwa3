local pvars = import("goluwa/cli/pvars.lua")
local render = import("goluwa/render/render.lua")
local ddgi = import("goluwa/render3d/ddgi.lua")
local hit = import("goluwa/render3d/scene/hit.lua")
local rt = import("goluwa/render3d/scene/rt.lua")
local Material = import("goluwa/render3d/material.lua")
local scene_instances = import("goluwa/render3d/scene/instances.lua")
local medium_common = import("goluwa/render3d/medium_common.lua")
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
	return medium_common.GetGLSL() .. [[
		#define GLASS_LIGHT
		#define GLASS_SUN_DISTANCE ]] .. string.format("%.1f", glass_light.SUN_DISTANCE) .. [[

		vec3 get_optical_tint_ray(vec3 origin, vec3 dir, float distance, bool through_medium) {
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
						through = medium_transmittance(material.medium_extinction, material.medium_thickness, material.medium_porosity);
					} else {
						through = material.albedo;

						if (material.albedo_tex >= 0) through *= textureLod(TEXTURE(material.albedo_tex), vec2(0.5), 16.0).rgb;

						through *= ]] .. string.format("%.2f", glass_light.TRANSMITTANCE) .. [[;
					}

					transmitted *= clamp(material.glass_refraction * through + (1.0 - material.glass_refraction) * (1.0 - material.glass_covering), vec3(0.0), vec3(1.0));
				} else if (through_medium && ddgi_has_medium(material)) {
					if (material.medium_body > 0.0 && front) continue;

					transmitted *= medium_transmittance(material.medium_extinction, material.medium_thickness, material.medium_porosity);
				}
			}

			return transmitted;
		}

		vec3 get_optical_tint(vec3 origin, vec3 dir, float distance) {
			return get_optical_tint_ray(origin, dir, distance, true);
		}

		vec3 get_glass_light(vec3 origin, vec3 dir, float distance, float search_radius) {
			vec3 transmitted = get_optical_tint_ray(origin, dir, distance, false);

			if (search_radius > 0.0 && min(transmitted.r, min(transmitted.g, transmitted.b)) > 0.999) {
				vec3 tangent = normalize(cross(dir, abs(dir.y) < 0.99 ? vec3(0.0, 1.0, 0.0) : vec3(1.0, 0.0, 0.0))) * search_radius;
				vec3 bitangent = normalize(cross(dir, tangent)) * search_radius;
				transmitted = min(transmitted, get_optical_tint_ray(origin + tangent, dir, distance, false));
				transmitted = min(transmitted, get_optical_tint_ray(origin - tangent, dir, distance, false));
				transmitted = min(transmitted, get_optical_tint_ray(origin + bitangent, dir, distance, false));
				transmitted = min(transmitted, get_optical_tint_ray(origin - bitangent, dir, distance, false));
			}

			return transmitted;
		}
	]]
end

function glass_light.GetStubGLSL()
	return [[
		vec3 get_glass_light(vec3 origin, vec3 dir, float distance, float search_radius) {
			return vec3(1.0);
		}

		vec3 get_optical_tint(vec3 origin, vec3 dir, float distance) {
			return vec3(1.0);
		}
	]]
end

return glass_light
