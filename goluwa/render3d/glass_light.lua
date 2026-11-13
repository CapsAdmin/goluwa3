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

		vec3 get_medium_volume_tint(vec3 origin, vec3 dir, float distance, bool light_ray) {
			int volume_count = get_optical_header().z;
			vec3 transmitted = vec3(1.0);

			for (int k = 0; k < volume_count; k++) {
				optical_volume volume = optical_volumes[k];

				if (volume.kind > 0.5) {
					float fog_entry;
					float fog_exit;

					if (medium_box_intersect(volume.to_local, -volume.shape, volume.shape, origin, dir, fog_entry, fog_exit)) {
						float start = clamp(fog_entry, 0.0, distance);
						float finish = min(fog_exit, distance);

						if (finish > start) {
							float density = 1.0;

							if (volume.falloff > 0.0) {
								vec3 mid = (volume.to_local * vec4(origin + dir * (0.5 * (start + finish)), 1.0)).xyz;
								density = exp(-(mid.y + volume.shape.y) / volume.falloff);
							}

							transmitted *= optical_transmittance(volume.extinction * density, finish - start);
						}
					}

					continue;
				}

				vec3 local_origin = (volume.to_local * vec4(origin, 1.0)).xyz;
				vec3 local_dir = (volume.to_local * vec4(dir, 0.0)).xyz;
				vec3 averaged = vec3(0.0);

				for (int w = 0; w < 3; w++) {
					float top = (float(w) - 1.0) * volume.wave;
					float t_entry;
					float t_exit;
					bool enters_through_top;
					float path = 0.0;

					if (medium_volume_intersect(volume.to_local, volume.shape, top, origin, dir, t_entry, t_exit, enters_through_top)) {
						path = min(t_exit, distance) - clamp(t_entry, 0.0, distance);

						if (light_ray && t_entry <= 0.0 && local_dir.y > 1e-4) {
							float top_t = (top - local_origin.y) / local_dir.y;

							if (top_t < distance && t_exit >= top_t - 1e-3) {
								float sin_water_squared = (1.0 - local_dir.y * local_dir.y) / (volume.ior * volume.ior);
								path = (top - local_origin.y) / sqrt(max(1.0 - sin_water_squared, 1e-4));
							}
						}
					}

					averaged += (w == 1 ? 0.5 : 0.25) * optical_transmittance(volume.extinction, path);
				}

				transmitted *= averaged;
			}

			return transmitted;
		}

		vec3 get_optical_tint(vec3 origin, vec3 dir, float distance) {
			return get_optical_tint_ray(origin, dir, distance, true) * get_medium_volume_tint(origin, dir, min(distance, ]] .. string.format("%.1f", max_distance:Get()) .. [[), false);
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

			return transmitted * get_medium_volume_tint(origin, dir, min(distance, ]] .. string.format("%.1f", max_distance:Get()) .. [[), true);
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
