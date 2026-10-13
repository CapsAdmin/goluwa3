local pvars = import("goluwa/cli/pvars.lua")
local render = import("goluwa/render/render.lua")
local ddgi = import("goluwa/render3d/ddgi.lua")
local scene_bvh = import("goluwa/render3d/scene_bvh.lua")
local Material = import("goluwa/render3d/material.lua")
local glass_light = {}
glass_light.RAY_QUERY = render.GetDevice().ray_query_supported
glass_light.SUN_DISTANCE = 300
glass_light.TRANSMITTANCE = 0.9
pvars.StartGroup("glass_light", {store = false})
local enabled = pvars.Setup2{
	key = "r_glass_light",
	default = true,
	friendly = "glass tints light",
	help = "lights take on the colour of the glass between them and a surface, glass casts no shadow of its own",
}
pvars.EndGroup()

function glass_light.IsEnabled()
	return glass_light.RAY_QUERY and enabled:Get()
end

-- the shadow maps see glass as dithered opacity until a ray sees it as a filter
Material.GlassCastsShadow = function()
	return not glass_light.IsEnabled()
end

function glass_light.GetDescriptorSets(bindings, stage)
	return {
		{type = "acceleration_structure_khr", binding_index = bindings.scene, stageFlags = stage},
		{
			type = "storage_buffer",
			binding_index = bindings.triangles,
			stageFlags = stage,
			count = scene_bvh.SOUP_CHUNKS,
		},
		{type = "storage_buffer", binding_index = bindings.materials, stageFlags = stage},
	}
end

do
	-- a set that a command buffer is still using can't be written to, so only what changed is
	local bound = setmetatable({}, {__mode = "k"})

	function glass_light.Bind(self, cmd, desc, bindings)
		local materials = ddgi.WriteMaterialBuffer(self)
		local tlas = ddgi.GetFrameState().tlas or scene_bvh.GetPlaceholderTLAS(cmd)
		local triangles = scene_bvh.triangle_buffer or materials
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

		if last.triangles ~= triangles then
			scene_bvh.BindTriangleBuffer(self, desc, bindings.triangles, triangles)
			last.triangles = triangles
		end
	end
end

function glass_light.GetDeclarationGLSL(bindings)
	return [[
		#extension GL_EXT_ray_query : require
		layout(set = 0, binding = ]] .. bindings.scene .. [[) uniform accelerationStructureEXT glass_light_scene;
	]] .. scene_bvh.GetTriangleDeclarationGLSL(bindings.triangles) .. ddgi.GetMaterialDeclarationsGLSL(bindings.materials)
end

-- what the light along origin + dir * distance is multiplied by after the glass in between. only see
-- through geometry makes a candidate once opaque geometry is culled, so what the shadow maps hold is not
-- counted twice. a closed glass solid is counted once, by the faces the ray enters through
function glass_light.GetGLSL(scene_name)
	return [[
		#define GLASS_LIGHT
		#define GLASS_SUN_DISTANCE ]] .. string.format("%.1f", glass_light.SUN_DISTANCE) .. [[

		vec3 get_glass_light_ray(vec3 origin, vec3 dir, float distance) {
			vec3 transmitted = vec3(1.0);
			rayQueryEXT query;
			rayQueryInitializeEXT(query, ]] .. scene_name .. [[, gl_RayFlagsCullOpaqueEXT, 0xFF, origin, 0.0, dir, distance);

			while (rayQueryProceedEXT(query)) {
				uint candidate = uint(rayQueryGetIntersectionInstanceCustomIndexEXT(query, false)) * ]] .. scene_bvh.SOUP_ALIGN .. [[u + uint(rayQueryGetIntersectionPrimitiveIndexEXT(query, false));
				ddgi_material material = ddgi_materials[bvh_tri(candidate).material];

				if (material.glass == 0) continue;

				// the soup's faces wind the other way round, so a face the ray enters through is not a front face
				if (material.double_sided == 0 && rayQueryGetIntersectionFrontFaceEXT(query, false)) continue;

				vec3 albedo = material.albedo;

				if (material.albedo_tex >= 0) albedo *= textureLod(TEXTURE(material.albedo_tex), vec2(0.5), 16.0).rgb;

				transmitted *= clamp(material.glass_refraction * ]] .. string.format("%.2f", glass_light.TRANSMITTANCE) .. [[ * albedo + (1.0 - material.glass_refraction) * (1.0 - material.glass_covering), vec3(0.0), vec3(1.0));
			}

			return transmitted;
		}

		// search_radius is how far to look sideways for glass when the ray itself finds none. the shadow maps'
		// penumbra reaches past the edge of an opaque frame into where its footprint is, the light that gets
		// through there passed beside the frame and through the glass next to it. 0 for no search
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

-- no ray queries, the surface lighting counts nothing for glass
function glass_light.GetStubGLSL()
	return [[
		vec3 get_glass_light(vec3 origin, vec3 dir, float distance, float search_radius) {
			return vec3(1.0);
		}
	]]
end

return glass_light
