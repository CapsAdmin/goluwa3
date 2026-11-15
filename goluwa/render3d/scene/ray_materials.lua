local ffi = require("ffi")
local pvars = import("goluwa/cli/pvars.lua")
local atmosphere = import("goluwa/render3d/atmosphere.lua")
local system = import("goluwa/system.lua")
local render = import("goluwa/render/render.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local scene_materials = import("goluwa/render3d/scene/materials.lua")
local Material = import("goluwa/render3d/material.lua")
local medium_common = import("goluwa/render3d/medium_common.lua")
local media = import("goluwa/render3d/media.lua")
local water = import("goluwa/render3d/water.lua")
local scene_instances = import("goluwa/render3d/scene/instances.lua")
local fluid_volumes = import("goluwa/render3d/fluid_volumes.lua")
local ray_materials = {}
ray_materials.OPTICAL_VOLUME_SLOTS = water.MAX_VOLUMES + fluid_volumes.MAX_VOLUMES + 2
pvars.StartGroup("Rendering", "Ray traced hit shading", {store = false})
local hit_textures = pvars.Setup2{
	key = "r_rt_hit_textures",
	default = true,
	help = "the albedo of a hit comes from its material's texture, off uses the material's flat color and reads no uvs or textures",
}
local hit_texels = pvars.Setup2{
	key = "r_rt_hit_texels",
	default = 8,
	min = 1,
	help = "how many texels across the albedo texture of a probe ray's hit is read at, the mip is chosen from it, fewer is a smaller mip and less memory read",
}
local hit_sun = pvars.Setup2{
	key = "r_rt_hit_sun",
	default = true,
	help = "the sun lights what a ray hits",
}
local hit_lights = pvars.Setup2{
	key = "r_rt_hit_lights",
	default = true,
	help = "the local lights light what a ray hits, off leaves the sun and the probes",
}
local hit_light_samples = pvars.Setup2{
	key = "r_rt_hit_light_samples",
	default = 2,
	integer = true,
	min = 0,
	max = 8,
	help = "how many of the local lights in a hit's light grid cell light it in a reflection or refraction ray, each picked with a probability of its share of the light and traced with a shadow ray. 0 lights it with every light that is bright enough, stochastically for the dim ones",
}
local hit_shadows = pvars.Setup2{
	key = "r_rt_hit_shadow_rays",
	default = true,
	help = "the sun and lights at a hit are tested with a shadow ray, off lights it unshadowed",
}
local hit_any_hit = pvars.Setup2{
	key = "r_rt_hit_any_hit",
	default = true,
	help = "a reflection ray looks through glass and cutout textures (every candidate hit of a non opaque instance is tested), off treats every instance as opaque",
}
local hit_probes = pvars.Setup2{
	key = "r_rt_hit_probes",
	default = true,
	help = "a hit also gets the light the probes hold (further bounces), off lights it directly only",
}
pvars.EndGroup()

function ray_materials.GetHitDefinesGLSL()
	return string.format(
		"#ifndef RT_HIT_SUN\n#define RT_HIT_SUN %d\n#define RT_HIT_LIGHTS %d\n#define RT_HIT_SHADOWS %d\n#define RT_HIT_PROBES %d\n#define RT_HIT_TEXTURES %d\n#define RT_HIT_ANY_HIT %d\n#define RT_HIT_LIGHT_SAMPLES %d\n#endif\n",
		hit_sun:Get() and 1 or 0,
		hit_lights:Get() and 1 or 0,
		hit_shadows:Get() and 1 or 0,
		hit_probes:Get() and 1 or 0,
		hit_textures:Get() and 1 or 0,
		hit_any_hit:Get() and 1 or 0,
		hit_light_samples:Get()
	)
end

function ray_materials.AreHitTexturesOn()
	return hit_textures:Get()
end

local OPTICAL_VOLUME_STRUCT_GLSL = [[
		struct optical_volume {
			mat4 to_local;
			vec3 shape;
			float kind;
			vec3 absorption;
			float ior;
			vec3 scattering;
			float g;
			vec3 extinction;
			vec3 molecular;
			float wave;
			float surface_y;
			float falloff;
			float softness;
			float abbe;
			float foam;
			float caustics;
			float roughness;
			float closed;
			float wave_length;
			float wind_direction;
			vec2 flow;
		};
]]

function ray_materials.GetOpticalDeclarationsGLSL(binding)
	return OPTICAL_VOLUME_STRUCT_GLSL .. [[

		layout(scalar, set = 0, binding = ]] .. binding .. [[) readonly buffer OpticalVolumes {
			ivec3 optical_counts;
			ivec4 optical_ranges;
			int optical_layer;
			optical_volume optical_volumes[]] .. ray_materials.OPTICAL_VOLUME_SLOTS .. [[];
		};
	]]
end

function ray_materials.GetOpticalTintGLSL()
	return medium_common.GetGLSL() .. [[

		vec3 optical_layer_depth(optical_volume volume, vec3 origin, vec3 dir, float distance) {
			float top = volume.shape.y;
			float start = volume.surface_y;
			float scale_height = volume.falloff;
			float from = 0.0;
			float to = distance;

			if (abs(dir.y) < 1e-5) {
				if (origin.y >= top) return vec3(0.0);
			} else {
				float top_distance = (top - origin.y) / dir.y;

				if (dir.y > 0.0) to = min(to, top_distance); else from = max(from, top_distance);
			}

			if (to <= from) return vec3(0.0);

			float below = 0.0;
			float above = 0.0;

			if (abs(dir.y) < 1e-5) {
				if (origin.y <= start) below = to - from; else above = (to - from) * exp(-(origin.y - start) / scale_height);
			} else {
				float split = clamp((start - origin.y) / dir.y, from, to);
				float above_from = dir.y > 0.0 ? split : from;
				float above_to = dir.y > 0.0 ? to : split;
				below = dir.y > 0.0 ? split - from : to - split;
				above = scale_height / dir.y * (exp(-(origin.y + dir.y * above_from - start) / scale_height) - exp(-(origin.y + dir.y * above_to - start) / scale_height));
			}

			return volume.extinction * (below + above) + vec3(volume.softness * (to - from));
		}

		vec3 optical_volume_tint(int index, vec3 origin, vec3 dir, float distance, bool light_ray, bool with_layer) {
			optical_volume volume = optical_volumes[index];

			if (volume.kind > 2.5) {
				if (!with_layer) return vec3(1.0);

				return exp(-optical_layer_depth(volume, origin, dir, distance));
			}

			if (volume.kind > 0.5 && volume.kind < 1.5) {
				float fog_entry;
				float fog_exit;

				if (!medium_box_intersect(volume.to_local, -volume.shape, volume.shape, origin, dir, fog_entry, fog_exit)) return vec3(1.0);

				float start = clamp(fog_entry, 0.0, distance);
				float finish = min(fog_exit, distance);

				if (finish <= start) return vec3(1.0);

				float density = 1.0;

				if (volume.falloff > 0.0) {
					vec3 mid = (volume.to_local * vec4(origin + dir * (0.5 * (start + finish)), 1.0)).xyz;
					density = exp(-(mid.y + volume.shape.y) / volume.falloff);
				}

				return optical_transmittance(volume.extinction * density, finish - start);
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
							path = (top - local_origin.y) / medium_refracted_cosine(local_dir.y, volume.ior);
						}
					}
				}

				averaged += (w == 1 ? 0.5 : 0.25) * optical_transmittance(volume.extinction, path);
			}

			return averaged;
		}

		vec3 optical_range_tint(int first, int count, vec3 origin, vec3 dir, float distance, bool light_ray, bool with_layer) {
			vec3 transmitted = vec3(1.0);

			for (int k = 0; k < count; k++) {
				transmitted *= optical_volume_tint(first + k, origin, dir, distance, light_ray, with_layer);
			}

			return transmitted;
		}

		vec3 optical_inscatter(vec3 origin, vec3 dir, float distance, vec3 ambient, vec3 ambient_visibility, vec3 sun_radiance, vec3 sun_dir, vec3 sun_visibility, bool with_layer) {
			vec3 scattered = vec3(0.0);

			for (int i = 0; i < optical_counts.z; i++) {
				optical_volume volume = optical_volumes[i];
				bool is_fog = volume.kind > 0.5 && volume.kind < 1.5;

				if (!(is_fog || (volume.kind > 2.5 && with_layer))) continue;

				vec3 albedo = volume.scattering / max(volume.extinction, vec3(1e-9));
				float mu = dot(dir, sun_dir);
				vec3 previous = vec3(1.0);

				for (int k = 0; k < 3; k++) {
					vec3 transmittance_end = optical_volume_tint(i, origin, dir, distance * float(k + 1) / 3.0, false, true);
					vec3 middle = origin + dir * (distance * (float(k) + 0.5) / 3.0);
					vec3 sun_transmittance = optical_volume_tint(i, middle, sun_dir, 1.0e5, false, true);
					vec3 sun_phase = medium_multiple_scattering(-log(max(sun_transmittance, vec3(1e-6))), mu, volume.g, 0.0, 0.0, 1.0 - dot(sun_transmittance, vec3(1.0 / 3.0)));
					scattered += (ambient * ambient_visibility[k] + sun_radiance * sun_visibility[k] * sun_phase) * albedo * (previous - transmittance_end);
					previous = transmittance_end;
				}
			}

			return scattered;
		}
	]]
end

function ray_materials.GetMaterialDeclarationsGLSL(binding)
	return [[

		struct ray_material {
			vec3 albedo;
			int albedo_tex;
			int double_sided;
			int terrain_tex;
			ivec4 terrain_layer_tex;
			vec3 terrain_bounds;
			vec4 terrain_detail;
			vec4 terrain_additive_detail;
			int terrain_tex2;
			ivec4 terrain_layer_tex2;
			vec4 terrain_detail2;
			vec4 terrain_additive_detail2;
			float alpha;
			float alpha_cutoff;
			int alpha_test;
			int glass;
			int albedo2_tex;
			int blend_tex;
			int transparent;
			int refractive;
			float glass_refraction;
			float glass_covering;
			float metallic;
			int metallic_tex;
			int metallic_channel;
			float roughness;
			float roughness_min;
			float roughness_max;
			int roughness_tex;
			int roughness_channel;
			vec3 emissive;
			int emissive_alpha;
			vec3 emissive_scale;
			int emissive_tex;
			int emissive_color;
			float emissive_albedo;
			float emissive_floor;
			vec3 medium_extinction;
			vec3 medium_scattering;
			vec3 medium_porous_scattering;
			float medium_g;
			float medium_porosity;
			float medium_porosity_low;
			float medium_porosity_high;
			float medium_thickness;
			float medium_body;
			float medium_ior;
			float medium_wave_height;
			float medium_wave_length;
			float medium_caustics;
			int normal_tex;
			int normal2_tex;
			int normal_ssbump;
			float normal_scale;
			vec3 bump_transform_u;
			vec3 bump_transform_v;
			ivec4 terrain_layer_normal_tex;
			ivec4 terrain_layer_normal_tex2;
			vec4 terrain_scales;
			vec4 terrain_scales2;
			float terrain_triplanar_sharpness;
			};

		]] .. OPTICAL_VOLUME_STRUCT_GLSL .. [[

		layout(scalar, set = 0, binding = ]] .. binding .. [[) readonly buffer DDGIMaterials {
			ivec3 optical_counts;
			ivec4 optical_ranges;
			int optical_layer;
			optical_volume optical_volumes[]] .. ray_materials.OPTICAL_VOLUME_SLOTS .. [[];
			ray_material ray_materials[];
		};

		bool ray_material_has_medium(ray_material material) {
			return material.medium_extinction.x + material.medium_extinction.y + material.medium_extinction.z > 0.0;
		}
	]]
end

function ray_materials.GetMaterialGLSL()
	return medium_common.GetGLSL() .. [[

		vec3 ray_material_albedo(ray_material material, vec3 P) {
			if (material.terrain_tex >= 0) {
				vec2 uv = (P.xz - material.terrain_bounds.xy) * material.terrain_bounds.z;
				vec4 weights = max(textureLod(TEXTURE(material.terrain_tex), uv, 0.0), vec4(0.0));
				vec4 weights2 = material.terrain_tex2 >= 0 ? max(textureLod(TEXTURE(material.terrain_tex2), uv, 0.0), vec4(0.0)) : vec4(0.0);
				float weight_sum = dot(weights, vec4(1.0)) + dot(weights2, vec4(1.0));

				if (weight_sum <= 0.0001) return material.albedo;

				weights /= weight_sum;
				weights2 /= weight_sum;
				vec3 base = material.albedo_tex >= 0 ? textureLod(TEXTURE(material.albedo_tex), uv, 0.0).rgb : vec3(1.0);
				vec3 albedo = vec3(0.0);

				for (int i = 0; i < 8; i++) {
					vec3 layer = base;
					bool second = i >= 4;
					int slot = second ? i - 4 : i;
					int layer_tex = second ? material.terrain_layer_tex2[slot] : material.terrain_layer_tex[slot];
					float weight = second ? weights2[slot] : weights[slot];

					if (weight <= 0.0) continue;

					if (layer_tex >= 0) {
						vec3 average = textureLod(TEXTURE(layer_tex), vec2(0.5), 16.0).rgb;
						float detail = second ? material.terrain_detail2[slot] : material.terrain_detail[slot];
						float additive = second ? material.terrain_additive_detail2[slot] : material.terrain_additive_detail[slot];

						if (detail <= 0.0) {
							layer = average * base;
						} else if (additive > 0.0) {
							layer = pow(max(pow(base, vec3(1.0 / 2.2)) + (average - 0.5) * detail, vec3(0.0)), vec3(2.2)) * additive;
						}
					}

					albedo += layer * weight;
				}

				return albedo * material.albedo;
			}

			vec3 albedo = material.albedo;

			if (material.albedo_tex >= 0) {
				albedo *= textureLod(TEXTURE(material.albedo_tex), vec2(0.5), 16.0).rgb;
			}

			return albedo;
		}

vec3 ray_medium_albedo(ray_material material, vec3 albedo) {
	if (!ray_material_has_medium(material)) return albedo;

	float brightness = pow(max(luminance(albedo), 0.0), 1.0 / 2.2);
	float porosity = max(material.medium_porosity, smoothstep(material.medium_porosity_low, material.medium_porosity_high, brightness));
	vec3 scattering = medium_scattering_at(material.medium_scattering, material.medium_porous_scattering, porosity);
	return mix(medium_scatter_color(material.medium_extinction, scattering, material.medium_g, material.medium_thickness) * MEDIUM_BOUNCE_SHARE, albedo, porosity);
}

float ray_bounce_share(ray_material material) {
	float metallic = material.metallic;

	if (material.metallic_tex >= 0) {
		metallic *= textureLod(TEXTURE(material.metallic_tex), vec2(0.5), 16.0)[material.metallic_channel];
	}

	metallic = clamp(metallic, 0.0, 1.0);

	if (metallic <= 0.0) return 1.0;

	float roughness = material.roughness;

	if (material.roughness_tex >= 0) {
		roughness *= mix(material.roughness_min, material.roughness_max, textureLod(TEXTURE(material.roughness_tex), vec2(0.5), 16.0)[material.roughness_channel]);
	}

	return mix(1.0, smoothstep(0.1, 0.9, roughness), metallic);
}

vec3 ray_material_emission(scene_triangle tri, vec3 albedo) {
			ray_material material = ray_materials[tri.material];
			vec3 emission = material.emissive * albedo * EMISSIVE_REFERENCE_LUMINANCE;

			if (material.emissive_alpha != 0 && material.albedo_tex >= 0) {
				emission *= textureLod(TEXTURE(material.albedo_tex), vec2(0.5), 16.0).a;
			}

			return min(emission, vec3(EMISSIVE_MAX_LUMINANCE));
		}

		#ifndef RAY_EMISSIVE_TEXELS
		#define RAY_EMISSIVE_TEXELS 128.0
		#endif

		vec3 ray_hit_emission(scene_triangle tri, vec3 albedo, vec3 P, uint instance, uint primitive) {
			ray_material material = ray_materials[tri.material];
			bool alpha_mask = material.emissive_alpha != 0 && material.albedo_tex >= 0;

			if (material.emissive_tex < 0 && !alpha_mask) return ray_material_emission(tri, albedo);

			vec3 p = P - tri.v0;
			float d00 = dot(tri.e1, tri.e1);
			float d01 = dot(tri.e1, tri.e2);
			float d11 = dot(tri.e2, tri.e2);
			float d20 = dot(p, tri.e1);
			float d21 = dot(p, tri.e2);
			float inv = 1.0 / (d00 * d11 - d01 * d01);
			float v = (d11 * d20 - d01 * d21) * inv;
			float w = (d00 * d21 - d01 * d20) * inv;
			scene_uv uv = scene_hit_uv(instance, primitive);
			vec2 coord = uv.uv0 * (1.0 - v - w) + uv.uv1 * v + uv.uv2 * w;
			int tex = alpha_mask ? material.albedo_tex : material.emissive_tex;
			ivec2 size = textureSize(TEXTURE(tex), 0);
			float lod = max(log2(float(max(size.x, size.y)) / RAY_EMISSIVE_TEXELS), 0.0);
			vec4 texel = textureLod(TEXTURE(tex), coord, lod);
			vec3 source;

			if (alpha_mask) {
				source = albedo * clamp((texel.a - material.emissive_floor) / (1.0 - material.emissive_floor), 0.0, 1.0);
			} else {
				source = material.emissive_color != 0 ? mix(texel.rgb, texel.rgb * albedo, material.emissive_albedo) : albedo * texel.r;
			}

			return min(material.emissive_scale * source * EMISSIVE_REFERENCE_LUMINANCE, vec3(EMISSIVE_MAX_LUMINANCE));
		}
	]]
end

function ray_materials.GetHitAlbedoGLSL()
	if not hit_textures:Get() then
		return [[
			vec3 ray_hit_albedo(ray_material material, vec3 P, uint instance, uint primitive) {
				return ray_medium_albedo(material, ray_material_albedo(material, P));
			}

			float ray_hit_roughness(ray_material material, vec3 P, uint instance, uint primitive) {
				return material.roughness;
			}
		]]
	end

	return [[

		#define RAY_HIT_ALBEDO_UV_TEXELS ]] .. string.format("%.1f", hit_texels:Get()) .. [[

		vec2 ray_hit_coord(vec3 P, uint instance, uint primitive, out vec3 weights, out scene_uv uv) {
			scene_triangle tri = scene_hit_tri(instance, primitive);
			vec3 p = P - tri.v0;
			float d00 = dot(tri.e1, tri.e1);
			float d01 = dot(tri.e1, tri.e2);
			float d11 = dot(tri.e2, tri.e2);
			float d20 = dot(p, tri.e1);
			float d21 = dot(p, tri.e2);
			float inv = 1.0 / (d00 * d11 - d01 * d01);
			float v = (d11 * d20 - d01 * d21) * inv;
			float w = (d00 * d21 - d01 * d20) * inv;
			weights = vec3(1.0 - v - w, v, w);
			uv = scene_hit_uv(instance, primitive);
			return uv.uv0 * weights.x + uv.uv1 * weights.y + uv.uv2 * weights.z;
		}

		float ray_hit_roughness(ray_material material, vec3 P, uint instance, uint primitive) {
			if (material.terrain_tex >= 0 || material.roughness_tex < 0) return material.roughness;

			vec3 weights;
			scene_uv uv;
			vec2 coord = ray_hit_coord(P, instance, primitive, weights, uv);
			ivec2 size = textureSize(TEXTURE(material.roughness_tex), 0);
			float lod = max(log2(float(max(size.x, size.y)) / RAY_HIT_ALBEDO_UV_TEXELS), 0.0);
			return material.roughness * mix(material.roughness_min, material.roughness_max, textureLod(TEXTURE(material.roughness_tex), coord, lod)[material.roughness_channel]);
		}

		vec3 ray_hit_albedo_plain(ray_material material, vec3 P, uint instance, uint primitive) {
			if (material.terrain_tex >= 0 || material.albedo_tex < 0) return ray_material_albedo(material, P);

			vec3 weights;
			scene_uv uv;
			vec2 coord = ray_hit_coord(P, instance, primitive, weights, uv);
			ivec2 size = textureSize(TEXTURE(material.albedo_tex), 0);
			float lod = max(log2(float(max(size.x, size.y)) / RAY_HIT_ALBEDO_UV_TEXELS), 0.0);
			vec3 rgb = textureLod(TEXTURE(material.albedo_tex), coord, lod).rgb;

			if (material.albedo2_tex >= 0) {
				float blend = dot(uv.blend, weights);

				if (material.blend_tex >= 0) {
					vec2 modulate = textureLod(TEXTURE(material.blend_tex), coord, lod).rg;
					blend = smoothstep(clamp(modulate.g - modulate.r, 0.0, 1.0), clamp(modulate.g + modulate.r, 0.0, 1.0), blend);
				}

				if (blend != 0.0) {
					ivec2 size2 = textureSize(TEXTURE(material.albedo2_tex), 0);
					float lod2 = max(log2(float(max(size2.x, size2.y)) / RAY_HIT_ALBEDO_UV_TEXELS), 0.0);
					rgb = mix(rgb, textureLod(TEXTURE(material.albedo2_tex), coord, lod2).rgb, blend);
				}
			}

			return material.albedo * rgb;
		}

		vec3 ray_hit_albedo(ray_material material, vec3 P, uint instance, uint primitive) {
			return ray_medium_albedo(material, ray_hit_albedo_plain(material, P, instance, primitive));
		}
	]]
end

function ray_materials.GetAlphaTestGLSL()
	return [[

		bool ray_alpha_passes(uint instance, uint primitive, vec2 barycentrics) {
			ray_material material = ray_materials[scene_instance_material(instance)];

			if (material.alpha_test == 0) return true;

			float alpha = material.alpha;

			if (material.alpha_test == 2) {
				scene_uv uv = scene_hit_uv(instance, primitive);
				vec2 coord = uv.uv0 * (1.0 - barycentrics.x - barycentrics.y) + uv.uv1 * barycentrics.x + uv.uv2 * barycentrics.y;
				alpha *= textureLod(TEXTURE(material.albedo_tex), coord, 0.0).a;
			}

			return alpha >= material.alpha_cutoff;
		}
	]]
end

function ray_materials.GetShadowRayGLSL()
	return [[
		bool ray_alpha_passes(uint instance, uint primitive, vec2 barycentrics);

		bool ray_shadow_visible(vec3 origin, vec3 dir, float dist, uint skip_mask) {
			float start = 0.0;

			for (int attempt = 0; attempt < 8; attempt++) {
				rayQueryEXT query;
				rayQueryInitializeEXT(query, scene_tlas, gl_RayFlagsTerminateOnFirstHitEXT, ]] .. string.format("0x%02X", scene_instances.MASK_SURFACES) .. [[, origin, start, dir, dist);

				while (rayQueryProceedEXT(query)) {
					uint candidate = uint(rayQueryGetIntersectionInstanceCustomIndexEXT(query, false));

					if ((scene_instances[candidate].mask_lod & skip_mask) == 0u && ray_materials[scene_instance_material(candidate)].transparent == 0 && ray_alpha_passes(candidate, uint(rayQueryGetIntersectionPrimitiveIndexEXT(query, false)), rayQueryGetIntersectionBarycentricsEXT(query, false))) rayQueryConfirmIntersectionEXT(query);
				}

				if (rayQueryGetIntersectionTypeEXT(query, true) == gl_RayQueryCommittedIntersectionNoneEXT) return true;

				if ((scene_instances[uint(rayQueryGetIntersectionInstanceCustomIndexEXT(query, true))].mask_lod & skip_mask) == 0u) return false;

				start = rayQueryGetIntersectionTEXT(query, true) + 0.002;
			}

			return true;
		}
	]]
end

local MaterialEntry = ffi.typeof([[struct {
	float albedo[3];
	int32_t albedo_tex;
	int32_t double_sided;
	int32_t terrain_tex;
	int32_t terrain_layer_tex[4];
	float terrain_bounds[3];
	float terrain_detail[4];
	float terrain_additive_detail[4];
	int32_t terrain_tex2;
	int32_t terrain_layer_tex2[4];
	float terrain_detail2[4];
	float terrain_additive_detail2[4];
	float alpha;
	float alpha_cutoff;
	int32_t alpha_test;
	int32_t glass;
	int32_t albedo2_tex;
	int32_t blend_tex;
	int32_t transparent;
	int32_t refractive;
	float glass_refraction;
	float glass_covering;
	float metallic;
	int32_t metallic_tex;
	int32_t metallic_channel;
	float roughness;
	float roughness_min;
	float roughness_max;
	int32_t roughness_tex;
	int32_t roughness_channel;
	float emissive[3];
	int32_t emissive_alpha;
	float emissive_scale[3];
	int32_t emissive_tex;
	int32_t emissive_color;
	float emissive_albedo;
	float emissive_floor;
	float medium_extinction[3];
	float medium_scattering[3];
	float medium_porous_scattering[3];
	float medium_g;
	float medium_porosity;
	float medium_porosity_low;
	float medium_porosity_high;
	float medium_thickness;
	float medium_body;
	float medium_ior;
	float medium_wave_height;
	float medium_wave_length;
	float medium_caustics;
	int32_t normal_tex;
	int32_t normal2_tex;
	int32_t normal_ssbump;
	float normal_scale;
	float bump_transform_u[3];
	float bump_transform_v[3];
	int32_t terrain_layer_normal_tex[4];
	int32_t terrain_layer_normal_tex2[4];
	float terrain_scales[4];
	float terrain_scales2[4];
	float terrain_triplanar_sharpness;
	}]])
ray_materials.MaterialEntry = MaterialEntry
local MaterialEntryPointer = ffi.typeof("$*", MaterialEntry)
local MATERIAL_ENTRY_SIZE = ffi.sizeof(MaterialEntry)
local OpticalHeader = ffi.typeof(
	"struct {int32_t glass; int32_t media; int32_t volumes; int32_t water_first; int32_t water_count; int32_t fog_first; int32_t fog_count; int32_t layer;}"
)
local OpticalHeaderPointer = ffi.typeof("$*", OpticalHeader)
local OpticalVolume = ffi.typeof(
	"struct {float to_local[16]; float shape[3]; float kind; float absorption[3]; float ior; float scattering[3]; float g; float extinction[3]; float molecular[3]; float wave; float surface_y; float falloff; float softness; float abbe; float foam; float caustics; float roughness; float closed; float wave_length; float wind_direction; float flow[2];}"
)
local OpticalVolumePointer = ffi.typeof("$*", OpticalVolume)
local OPTICAL_HEADER_SIZE = ffi.sizeof(OpticalHeader)
local OPTICAL_VOLUME_SIZE = ffi.sizeof(OpticalVolume)
local OPTICAL_PREFIX_SIZE = OPTICAL_HEADER_SIZE + ray_materials.OPTICAL_VOLUME_SLOTS * OPTICAL_VOLUME_SIZE
local BytePointer = ffi.typeof("uint8_t*")

function ray_materials.GetMaterialEntries(buffer)
	local base = ffi.cast(BytePointer, buffer:Map(0, buffer:GetSize()))
	return ffi.cast(MaterialEntryPointer, base + OPTICAL_PREFIX_SIZE),
	(buffer:GetSize() - OPTICAL_PREFIX_SIZE) / MATERIAL_ENTRY_SIZE
end

function ray_materials.GetOpticalVolumes(buffer)
	local base = ffi.cast(BytePointer, buffer:Map(0, buffer:GetSize()))
	return ffi.cast(OpticalHeaderPointer, base),
	ffi.cast(OpticalVolumePointer, base + OPTICAL_HEADER_SIZE)
end

local material_buffers = setmetatable({}, {__mode = "k"})
local glass_count = 0
local medium_count = 0

function ray_materials.HasGlass()
	return glass_count > 0
end

local AXES = {"x", "y", "z"}
local volume_count = 0
local OCEAN_HALF_SIZE = 1e5
local OCEAN_DEPTH = 1e4
local OCEAN_WAVE_SCALE = 3.5
local OCEAN_WAVE_FLOOR = 0.05

function ray_materials.HasMedium()
	return medium_count > 0 or volume_count > 0
end

function ray_materials.HasBodies()
	return medium_count > 0 or glass_count > 0
end

function ray_materials.HasVolumes()
	return volume_count > 0
end

function ray_materials.HasDirectTint()
	return glass_count > 0 or volume_count > 0
end

local function set_vec3(target, value)
	target[0], target[1], target[2] = value.x, value.y, value.z
end

local function write_ocean_record(volume)
	local params = water.GetOcean()
	local medium = media.presets[params.Medium]
	volume.to_local[0], volume.to_local[5], volume.to_local[10], volume.to_local[15] = 1, 1, 1, 1
	volume.to_local[13] = -render3d.GetOceanLevel()
	volume.shape[0], volume.shape[1], volume.shape[2] = OCEAN_HALF_SIZE, OCEAN_DEPTH, OCEAN_HALF_SIZE
	volume.kind = 2
	set_vec3(volume.absorption, medium.Absorption)
	set_vec3(volume.scattering, medium.Scattering)
	set_vec3(volume.extinction, media.GetExtinction(params.Medium))
	set_vec3(volume.molecular, medium.Molecular)
	volume.g = medium.PhaseG
	volume.ior = medium.IOR
	volume.abbe = medium.AbbeNumber
	volume.wave = water.GetOceanWaves().height_std * OCEAN_WAVE_SCALE + OCEAN_WAVE_FLOOR
	volume.surface_y = render3d.GetOceanLevel()
end

local function write_water_record(volume, water_volume)
	local size = water_volume:GetSize()
	local transform = water_volume.Owner.transform
	local medium = media.presets[water_volume:GetMedium()]
	local flow = water_volume:GetFlow()
	transform:GetWorldMatrixInverse():CopyToFloatPointer(volume.to_local)
	volume.shape[0], volume.shape[1], volume.shape[2] = size.x / 2, size.y, size.z / 2
	volume.kind = 0
	set_vec3(volume.absorption, medium.Absorption)
	set_vec3(volume.scattering, medium.Scattering)
	set_vec3(volume.extinction, media.GetExtinction(water_volume:GetMedium()))
	set_vec3(volume.molecular, medium.Molecular)
	volume.g = medium.PhaseG
	volume.ior = medium.IOR
	volume.abbe = medium.AbbeNumber
	volume.wave = water_volume:GetWaveHeight()
	volume.surface_y = transform:GetWorldPosition().y
	volume.foam = water_volume:GetFoam()
	volume.caustics = water_volume:GetCaustics()
	volume.roughness = water_volume:GetRoughness()
	volume.closed = water_volume:GetOpen() and 0 or 1
	volume.wave_length = math.max(water_volume:GetWaveLength(), 0.01)
	volume.wind_direction = math.rad(water_volume:GetWindDirection())
	volume.flow[0], volume.flow[1] = flow.x, flow.y
end

local function write_fog_record(volume, fluid_volume)
	local size = fluid_volume:GetSize()
	local medium = media.presets[fluid_volume:GetMedium()]
	local density = fluid_volume:GetDensity() * fluid_volume:GetFill()
	fluid_volume.Owner.transform:GetWorldMatrixInverse():CopyToFloatPointer(volume.to_local)
	volume.shape[0], volume.shape[1], volume.shape[2] = size.x / 2, size.y / 2, size.z / 2
	volume.kind = 1
	set_vec3(volume.absorption, medium.Absorption * density)
	set_vec3(volume.scattering, medium.Scattering * density)
	set_vec3(volume.extinction, (medium.Absorption + medium.Scattering) * density)
	volume.g = medium.PhaseG
	volume.ior = medium.IOR
	volume.softness = fluid_volume:GetEdgeSoftness()
	volume.falloff = fluid_volume:GetHeightFalloff()
end

local function write_layer_record(volume)
	local per_meter = atmosphere.METERS_TO_UNITS
	local extinction = media.GetTint("fog") * (atmosphere.GetGroundFogExtinction() * per_meter)
	volume.kind = 3
	volume.surface_y = (atmosphere.GetGroundFogStartAltitude() - atmosphere.SEA_LEVEL_HEIGHT) / per_meter
	volume.shape[1] = (
			atmosphere.GetGroundFogTopAltitude() - atmosphere.SEA_LEVEL_HEIGHT - atmosphere.GROUND_FOG_TOP_SOFTNESS / 2
		) / per_meter
	volume.falloff = atmosphere.ground_fog_scale_height / per_meter
	volume.softness = atmosphere.precipitation_extinction * per_meter
	set_vec3(volume.extinction, extinction)
	set_vec3(volume.scattering, extinction * media.GetAlbedo("fog"))
	volume.g = media.presets.fog.PhaseG
end

local function refresh_volumes(state)
	local frame_number = system.GetFrameNumber()

	if state.volume_frame == frame_number then return end

	state.volume_frame = frame_number
	local header, volumes = ray_materials.GetOpticalVolumes(state.buffer)
	local count = 0

	if render3d.IsOceanEnabled() then
		ffi.fill(volumes, OPTICAL_VOLUME_SIZE)
		write_ocean_record(volumes[0])
		count = 1
	end

	local layer = -1

	if atmosphere.GetGroundFogExtinction() + atmosphere.precipitation_extinction > 0 then
		ffi.fill(volumes + count, OPTICAL_VOLUME_SIZE)
		write_layer_record(volumes[count])
		layer = count
		count = count + 1
	end

	local water_first = count

	for _, water_volume in ipairs(water.GetNearestVolumes(render3d.GetCamera():GetPosition())) do
		if count >= ray_materials.OPTICAL_VOLUME_SLOTS then break end

		ffi.fill(volumes + count, OPTICAL_VOLUME_SIZE)
		write_water_record(volumes[count], water_volume)
		count = count + 1
	end

	local fog_first = count

	for _, fluid_volume in ipairs(fluid_volumes.GetVolumes()) do
		if count >= ray_materials.OPTICAL_VOLUME_SLOTS then break end

		if fluid_volume:GetSimulation() == "procedural" then
			ffi.fill(volumes + count, OPTICAL_VOLUME_SIZE)
			write_fog_record(volumes[count], fluid_volume)
			count = count + 1
		end
	end

	header.glass, header.media, header.volumes = glass_count, medium_count, count
	header.water_first, header.water_count = water_first, fog_first - water_first
	header.fog_first, header.fog_count = fog_first, count - fog_first
	header.layer = layer
	volume_count = count
end

function ray_materials.BindOpticalVolumes(self, desc, binding)
	local buffer = ray_materials.WriteMaterialBuffer(self)
	self:UpdateDescriptorSet("storage_buffer", desc, binding, 0, buffer, buffer:GetSize())
end

function ray_materials.WriteMaterialBuffer(self)
	local frame = render.GetCurrentFrame()
	local materials = scene_materials.list
	local count = #materials
	material_buffers[self] = material_buffers[self] or {}
	local states = material_buffers[self]
	local state = states[frame]

	if
		not state or
		state.buffer:GetSize() < OPTICAL_PREFIX_SIZE + count * MATERIAL_ENTRY_SIZE
	then
		if state then state.buffer:Remove() end

		local capacity = math.max(count, 1) * 2
		state = {
			buffer = render.CreateBuffer{
				byte_size = OPTICAL_PREFIX_SIZE + capacity * MATERIAL_ENTRY_SIZE,
				buffer_usage = {"storage_buffer"},
				memory_property = {"host_visible", "host_coherent"},
				label = "ray_materials",
				data = ffi.new("uint8_t[?]", OPTICAL_PREFIX_SIZE + capacity * MATERIAL_ENTRY_SIZE),
			},
			written = 0,
			generation = 0,
			releases = -1,
		}
		states[frame] = state
	end

	local generation = Material.ray_material_generation
	local releases = self:GetTextureIndexReleases()
	local glass_enabled = not Material.GlassCastsShadow()

	if
		state.written == count and
		state.generation == generation and
		state.releases == releases and
		state.glass == glass_enabled and
		state.medium_thickness == medium_common.assumed_thickness and
		state.media_generation == media.generation
	then
		glass_count = state.glass_count or 0
		medium_count = state.medium_count or 0
		refresh_volumes(state)
		return state.buffer
	end

	local rewrite_all = state.releases ~= releases or
		state.glass ~= glass_enabled or
		state.medium_thickness ~= medium_common.assumed_thickness or
		state.media_generation ~= media.generation
	state.medium_thickness = medium_common.assumed_thickness
	state.media_generation = media.generation
	local written = state.written
	local stamp = state.generation
	local out = ray_materials.GetMaterialEntries(state.buffer)

	for i = 1, count do
		local material = materials[i]

		if rewrite_all or i > written or material.ray_material_stamp > stamp then
			local entry = out[i - 1]
			local color = material:GetColorMultiplier()
			entry.albedo[0] = color.r
			entry.albedo[1] = color.g
			entry.albedo[2] = color.b
			local albedo = material:GetAlbedoTexture() or NULL
			entry.albedo_tex = albedo:IsValid() and self:GetTextureIndex(albedo) or -1
			entry.double_sided = material:GetDoubleSided() and 1 or 0
			entry.alpha = color.a
			entry.alpha_cutoff = material:GetAlphaCutoff()

			if not material:GetAlphaTest() then
				entry.alpha_test = 0
			else
				entry.alpha_test = material:HasShadowTexture() and 2 or 1
			end

			local was_glass = entry.glass
			entry.glass = (glass_enabled and material:IsGlass()) and 1 or 0
			state.glass_count = (state.glass_count or 0) + entry.glass - was_glass
			entry.glass_refraction = material:GetRefraction()
			entry.glass_covering = material:GetTranslucent() and color.a or 1
			entry.metallic = material:GetMetallicMultiplier()
			local metallic_texture = material:GetMetallicTexture()
			entry.metallic_channel = 0

			if not metallic_texture then
				metallic_texture = material:GetMetallicRoughnessTexture()
				entry.metallic_channel = material:GetMetallicRoughnessIsMR() and 0 or 2
			end

			entry.metallic_tex = metallic_texture and
				metallic_texture:IsValid() and
				self:GetTextureIndex(metallic_texture) or
				-1
			entry.roughness = material:GetRoughnessMultiplier()
			entry.roughness_min = material:GetRoughnessMin()
			entry.roughness_max = material:GetRoughnessMax()
			local roughness_texture = material:GetRoughnessTexture()
			entry.roughness_channel = 0

			if not roughness_texture then
				roughness_texture = material:GetMetallicRoughnessTexture()
				entry.roughness_channel = 1
			end

			entry.roughness_tex = roughness_texture and
				roughness_texture:IsValid() and
				self:GetTextureIndex(roughness_texture) or
				-1
			entry.emissive[0], entry.emissive[1], entry.emissive[2] = scene_materials.GetEmissive(material)
			entry.emissive_alpha = material:GetAlbedoAlphaIsEmissive() and 1 or 0
			local emissive_multiplier = material:GetEmissiveMultiplier()
			entry.emissive_scale[0] = emissive_multiplier.r * emissive_multiplier.a
			entry.emissive_scale[1] = emissive_multiplier.g * emissive_multiplier.a
			entry.emissive_scale[2] = emissive_multiplier.b * emissive_multiplier.a
			local emissive_texture = material:GetEmissiveTexture()
			entry.emissive_tex = emissive_texture and
				emissive_texture:IsValid() and
				not material:GetAdditive()
				and
				not material:GetAlbedoAlphaIsEmissive()
				and
				self:GetTextureIndex(emissive_texture) or
				-1
			entry.emissive_color = material:GetEmissiveTextureIsColor() and 1 or 0
			entry.emissive_albedo = material:GetEmissiveAlbedoFactor()
			entry.emissive_floor = material:GetEmissiveAlphaFloor()
			local from_albedo = material:GetMediumPorosityFromAlbedo() > 0
			local medium_slot = material:GetMediumSlot()

			if medium_slot > 0 then
				local slot = media.slots[medium_slot]
				local preset = media.presets[slot.name]

				for i = 0, 2 do
					local axis = AXES[i + 1]
					entry.medium_extinction[i] = preset.Absorption[axis] * slot.density
					entry.medium_scattering[i] = preset.Scattering[axis] * slot.density
					entry.medium_porous_scattering[i] = preset.PorousScattering[axis] * slot.density
				end

				entry.medium_g = preset.PhaseG
			else
				for i = 0, 2 do
					entry.medium_extinction[i] = 0
					entry.medium_scattering[i] = 0
					entry.medium_porous_scattering[i] = 0
				end

				entry.medium_g = 0
			end

			entry.medium_porosity = material:GetMediumPorosity()
			entry.medium_porosity_low = from_albedo and medium_common.porosity_low or 2
			entry.medium_porosity_high = from_albedo and medium_common.porosity_high or 3
			local body = material:GetMediumThickness()
			entry.medium_thickness = body > 0 and
				body or
				(
					medium_common.assumed_thickness > 0 and
					medium_common.assumed_thickness or
					3
				)
			entry.medium_body = body > 0 and 1 or 0
			entry.medium_ior = material:GetEffectiveIOR()
			entry.medium_wave_height = material:GetMediumWaveHeight()
			entry.medium_wave_length = material:GetMediumWaveLength()
			entry.medium_caustics = material:GetMediumCaustics()
			entry.transparent = material:IsTransparent() and 1 or 0
			entry.refractive = material:IsSeeThrough() and 1 or 0
			local normal = material:GetNormalTexture()
			entry.normal_tex = normal and normal:IsValid() and self:GetTextureIndex(normal) or -1
			local normal2 = material:GetNormal2Texture()
			entry.normal2_tex = normal2 and normal2:IsValid() and self:GetTextureIndex(normal2) or -1
			entry.normal_ssbump = material:GetNormalTextureIsSSBump() and 1 or 0
			entry.normal_scale = material:GetNormalMapMultiplier()
			local bump_u, bump_v = material:GetBumpTransformU(), material:GetBumpTransformV()
			entry.bump_transform_u[0], entry.bump_transform_u[1], entry.bump_transform_u[2] = bump_u.x, bump_u.y, bump_u.z
			entry.bump_transform_v[0], entry.bump_transform_v[1], entry.bump_transform_v[2] = bump_v.x, bump_v.y, bump_v.z
			local albedo2 = material:GetAlbedo2Texture()
			entry.albedo2_tex = albedo2 and albedo2:IsValid() and self:GetTextureIndex(albedo2) or -1
			local blend_texture = material:GetBlendTexture()
			entry.blend_tex = blend_texture and
				blend_texture:IsValid() and
				self:GetTextureIndex(blend_texture) or
				-1
			local terrain = material:GetTerrainMaterialTexture()

			if terrain and terrain:IsValid() then
				entry.terrain_tex = self:GetTextureIndex(terrain)

				for layer = 1, 4 do
					local tex = material["GetTerrainLayer" .. layer .. "Texture"](material)
					entry.terrain_layer_tex[layer - 1] = tex and tex:IsValid() and self:GetTextureIndex(tex) or -1
				end

				for layer = 1, 4 do
					local tex = material["GetTerrainLayer" .. layer .. "NormalTexture"](material)
					entry.terrain_layer_normal_tex[layer - 1] = tex and tex:IsValid() and self:GetTextureIndex(tex) or -1
				end

				local scales = material:GetTerrainLayerScales()
				entry.terrain_scales[0] = scales.r
				entry.terrain_scales[1] = scales.g
				entry.terrain_scales[2] = scales.b
				entry.terrain_scales[3] = scales.a
				entry.terrain_triplanar_sharpness = material:GetTerrainTriplanarSharpness()
				local bounds = material:GetTerrainBounds()
				entry.terrain_bounds[0] = bounds.x
				entry.terrain_bounds[1] = bounds.y
				entry.terrain_bounds[2] = 1 / bounds.z
				local detail = material:GetTerrainLayerDetailStrength()
				local additive = material:GetTerrainLayerAdditiveDetail()
				entry.terrain_detail[0] = detail.r
				entry.terrain_detail[1] = detail.g
				entry.terrain_detail[2] = detail.b
				entry.terrain_detail[3] = detail.a
				entry.terrain_additive_detail[0] = additive.r
				entry.terrain_additive_detail[1] = additive.g
				entry.terrain_additive_detail[2] = additive.b
				entry.terrain_additive_detail[3] = additive.a
				local terrain2 = material:GetTerrainMaterial2Texture()

				if terrain2 and terrain2:IsValid() then
					entry.terrain_tex2 = self:GetTextureIndex(terrain2)

					for layer = 5, 8 do
						local tex = material["GetTerrainLayer" .. layer .. "Texture"](material)
						entry.terrain_layer_tex2[layer - 5] = tex and tex:IsValid() and self:GetTextureIndex(tex) or -1
					end

					for layer = 5, 8 do
						local tex = material["GetTerrainLayer" .. layer .. "NormalTexture"](material)
						entry.terrain_layer_normal_tex2[layer - 5] = tex and tex:IsValid() and self:GetTextureIndex(tex) or -1
					end

					local scales2 = material:GetTerrainLayerScales2()
					entry.terrain_scales2[0] = scales2.r
					entry.terrain_scales2[1] = scales2.g
					entry.terrain_scales2[2] = scales2.b
					entry.terrain_scales2[3] = scales2.a
					local detail2 = material:GetTerrainLayerDetailStrength2()
					local additive2 = material:GetTerrainLayerAdditiveDetail2()
					entry.terrain_detail2[0] = detail2.r
					entry.terrain_detail2[1] = detail2.g
					entry.terrain_detail2[2] = detail2.b
					entry.terrain_detail2[3] = detail2.a
					entry.terrain_additive_detail2[0] = additive2.r
					entry.terrain_additive_detail2[1] = additive2.g
					entry.terrain_additive_detail2[2] = additive2.b
					entry.terrain_additive_detail2[3] = additive2.a
				else
					entry.terrain_tex2 = -1
				end
			else
				entry.terrain_tex = -1
				entry.terrain_tex2 = -1
			end
		end
	end

	state.written = count
	state.generation = generation
	state.releases = releases
	state.glass = glass_enabled
	glass_count = state.glass_count or 0
	state.medium_count = 0

	for i = 1, count do
		if materials[i]:GetMediumSlot() > 0 then
			state.medium_count = state.medium_count + 1
		end
	end

	medium_count = state.medium_count
	refresh_volumes(state)
	return state.buffer
end

return ray_materials
