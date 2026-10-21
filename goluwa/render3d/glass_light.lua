local pvars = import("goluwa/cli/pvars.lua")
local render = import("goluwa/render/render.lua")
local ddgi = import("goluwa/render3d/ddgi.lua")
local hit = import("goluwa/render3d/scene/hit.lua")
local rt = import("goluwa/render3d/scene/rt.lua")
local Material = import("goluwa/render3d/material.lua")
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
	return [[
		#define GLASS_LIGHT
		#define GLASS_SUN_DISTANCE ]] .. string.format("%.1f", glass_light.SUN_DISTANCE) .. [[

		vec3 get_glass_light_ray(vec3 origin, vec3 dir, float distance) {
			vec3 transmitted = vec3(1.0);
			rayQueryEXT query;
			rayQueryInitializeEXT(query, ]] .. scene_name .. [[, gl_RayFlagsCullOpaqueEXT, 0x02, origin, 0.0, dir, min(distance, ]] .. string.format("%.1f", max_distance:Get()) .. [[));

			while (rayQueryProceedEXT(query)) {
				ddgi_material material = ddgi_materials[scene_instance_material(uint(rayQueryGetIntersectionInstanceCustomIndexEXT(query, false)))];

				if (material.glass == 0) continue;

				if (material.double_sided == 0 && rayQueryGetIntersectionFrontFaceEXT(query, false)) continue;

				vec3 albedo = material.albedo;

				if (material.albedo_tex >= 0) albedo *= textureLod(TEXTURE(material.albedo_tex), vec2(0.5), 16.0).rgb;

				transmitted *= clamp(material.glass_refraction * ]] .. string.format("%.2f", glass_light.TRANSMITTANCE) .. [[ * albedo + (1.0 - material.glass_refraction) * (1.0 - material.glass_covering), vec3(0.0), vec3(1.0));
			}

			return transmitted;
		}

		vec3 get_glass_light(vec3 origin, vec3 dir, float distance, float search_radius) {
			vec3 transmitted = get_glass_light_ray(origin, dir, distance);

			if (search_radius > 0.0 && min(transmitted.r, min(transmitted.g, transmitted.b)) > 0.999) {
				vec3 tangent = normalize(cross(dir, abs(dir.y) < 0.99 ? vec3(0.0, 1.0, 0.0) : vec3(1.0, 0.0, 0.0))) * search_radius;
				vec3 bitangent = normalize(cross(dir, tangent)) * search_radius;
				transmitted = min(transmitted, get_glass_light_ray(origin + tangent, dir, distance));
				transmitted = min(transmitted, get_glass_light_ray(origin - tangent, dir, distance));
				transmitted = min(transmitted, get_glass_light_ray(origin + bitangent, dir, distance));
				transmitted = min(transmitted, get_glass_light_ray(origin - bitangent, dir, distance));
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
	]]
end

return glass_light
