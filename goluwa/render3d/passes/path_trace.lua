local render3d = import("goluwa/render3d/render3d.lua")
local glsl_common = import("goluwa/render3d/glsl_common.lua")
local gbuffer_layout = import("goluwa/render3d/gbuffer_layout.lua")
local compute_helpers = import("goluwa/render3d/compute_helpers.lua")
local screen_reconstruct = import("goluwa/render3d/screen_reconstruct.lua")
local atmosphere = import("goluwa/render3d/atmosphere.lua")
local light_occlusion = import("goluwa/render3d/light_occlusion.lua")
local light_grid = import("goluwa/render3d/light_grid.lua")
local surface_lighting = import("goluwa/render3d/surface_lighting.lua")
local surface_features = import("goluwa/render3d/surface_features.lua")
local surface_weather = import("goluwa/render3d/surface_weather.lua")
local scene_hits = import("goluwa/render3d/scene_hits.lua")
local scene_instances = import("goluwa/render3d/scene/instances.lua")
local ray_materials = import("goluwa/render3d/scene/ray_materials.lua")
local optical_rays = import("goluwa/render3d/optical_rays.lua")
local path_trace = import("goluwa/render3d/path_trace.lua")
local caustics = import("goluwa/render3d/caustics.lua")

if not optical_rays.RAY_QUERY then return {} end

local COMPUTE_LOCAL_SIZE = {x = 8, y = 8, z = 1}
local BINDING_ACCUM = 0
local BINDING_RASTER = 1
local BINDING_SCENE_COLOR = 2
local BINDING_UNIFORM = 3
local BINDING_OCCLUSION_MAP = 4
local BINDING_LIGHT_GRID = 5
local BINDING_SUBSURFACE = 7
local BINDING_VIEW = 9
local BINDING_PHOTONS = 10
local PHOTON_LOCAL_SIZE = {x = 64, y = 1, z = 1}
local PHOTON_ROW = 65536
local SCENE_BINDINGS = {scene = 6, hit = 30, materials = 8}
local VIEW_INDEX = {}

for i, name in ipairs(path_trace.VIEWS) do
	VIEW_INDEX[name] = i - 1
end

local function lighting_attachment(index)
	return render3d.pipelines.lighting:GetFramebuffer(1):GetAttachment(index)
end

local SUN_ONE_MINUS_COS = 2 * math.sin(atmosphere.SUN_ANGULAR_RADIUS / 2) ^ 2
local GLSL = render3d.GetEmissiveGLSL() .. glsl_common.GetHashGLSL() .. compute_helpers.GetScreenHelpersGLSL() .. [[
			vec2 in_uv;
			ivec2 in_pixel;
			float in_view_depth;

			]] .. gbuffer_layout.GetDecodeGLSL("lighting_data") .. surface_weather.GetRainSurfaceGLSL("lighting_data") .. optical_rays.GetGLSL() .. surface_lighting.GetGLSL("lighting_data", true) .. ray_materials.GetMaterialGLSL() .. ray_materials.GetAlphaTestGLSL() .. surface_features.GetDecodeFunctionGLSL() .. [[

			]] .. screen_reconstruct.GetWorldPosGLSL("lighting_data") .. [[

			]] .. screen_reconstruct.GetWorldPosFromUVGLSL("lighting_data", {function_name = "get_world_pos_at"}) .. [[

			]] .. screen_reconstruct.GetGeometricNormalGLSL("lighting_data") .. caustics.GetGLSL("lighting_data") .. [[

			#define PT_PI 3.14159265359
			#define PT_MASK ]] .. string.format("0x%02X", scene_instances.MASK_SURFACES) .. [[

			#define PT_SUN_ONE_MINUS_COS ]] .. string.format("%.9e", SUN_ONE_MINUS_COS) .. [[

			#define PT_SUN_SOLID_ANGLE (2.0 * PT_PI * PT_SUN_ONE_MINUS_COS)

			uint pt_rng;

			float pt_random() {
				pt_rng = pt_rng * 747796405u + 2891336453u;
				uint word = ((pt_rng >> ((pt_rng >> 28u) + 4u)) ^ pt_rng) * 277803737u;
				return float(((word >> 22u) ^ word) >> 8u) / 16777216.0;
			}

			void pt_basis(vec3 n, out vec3 t, out vec3 b) {
				float s = n.z >= 0.0 ? 1.0 : -1.0;
				float a = -1.0 / (s + n.z);
				float c = n.x * n.y * a;
				t = vec3(1.0 + s * n.x * n.x * a, s * c, -s * n.x);
				b = vec3(c, s + n.y * n.y * a, -n.y);
			}

			#define PT_PROCEED(query) \
				while (rayQueryProceedEXT(query)) { \
					uint candidate = uint(rayQueryGetIntersectionInstanceCustomIndexEXT(query, false)); \
					ray_material candidate_material = ray_materials[scene_instance_material(candidate)]; \
					if ((lighting_data.pt_caustics != 0 && candidate_material.caustic != 0) || (candidate_material.transparent == 0 && ray_alpha_passes(candidate, scene_query_primitive(query, false), rayQueryGetIntersectionBarycentricsEXT(query, false)))) rayQueryConfirmIntersectionEXT(query); \
				}

			bool pt_trace(vec3 origin, vec3 dir, out float t, out uint instance, out uint primitive, out vec2 barycentrics) {
				rayQueryEXT query;
				rayQueryInitializeEXT(query, scene_tlas, gl_RayFlagsNoneEXT, PT_MASK, origin, 0.0, dir, lighting_data.hit_max_distance);

				PT_PROCEED(query)

				if (rayQueryGetIntersectionTypeEXT(query, true) == gl_RayQueryCommittedIntersectionNoneEXT) return false;

				t = rayQueryGetIntersectionTEXT(query, true);
				instance = uint(rayQueryGetIntersectionInstanceCustomIndexEXT(query, true));
				primitive = scene_query_primitive(query, true);
				barycentrics = rayQueryGetIntersectionBarycentricsEXT(query, true);
				return true;
			}

			vec3 pt_offset(vec3 P, vec3 Ng) {
				vec3 magnitude = abs(P);
				return P + Ng * (0.0005 * lighting_data.view_scale + 4e-6 * max(max(magnitude.x, magnitude.y), magnitude.z));
			}

			struct pt_vertex {
				vec3 P;
				vec3 N;
				vec3 Ng;
				vec3 V;
				vec3 albedo;
				vec3 F0;
				float alpha;
				float perceptual_roughness;
				float diffuse_roughness;
				float metallic;
				float dielectric_f0;
				float NoV;
				vec3 energy_compensation;
				vec3 diffuse_view;
				vec2 average_env_brdf;
				float specular_chance;
				vec3 P_back;
				float transmission;
				vec3 transmission_color;
				float transmission_scattering;
				float transmission_chance;
			};

			void pt_prepare(inout pt_vertex v) {
				v.N = bend_normal_to_view(v.N, v.V);
				v.alpha = max(v.alpha, 0.0015);
				v.NoV = max(dot(v.N, v.V), 0.001);
				vec4 brdf_lut = textureLod(TEXTURE(lighting_data.brdf_lut_tex), vec2(v.NoV, v.perceptual_roughness), 0.0);
				vec2 env_brdf = brdf_lut.rg;
				v.energy_compensation = GGXEnergyCompensation(v.F0, env_brdf);
				vec3 specular_albedo = (v.F0 * env_brdf.x + F90(v.F0) * env_brdf.y) * v.energy_compensation;
				v.diffuse_view = max(1.0 - specular_albedo, vec3(0.0)) * (1.0 - v.metallic);
				v.average_env_brdf = brdf_lut.ba;
				float specular = luminance(specular_albedo);
				float diffuse = luminance(v.albedo * v.diffuse_view);
				float transmitted = v.transmission * luminance(v.transmission_color * v.albedo) * (1.0 - v.metallic);
				v.specular_chance = diffuse + transmitted <= 0.0 ? 1.0 : clamp(specular / max(specular + diffuse + transmitted, 1e-6), 0.1, 0.9);
				v.transmission_chance = v.transmission > 0.0 ? clamp(transmitted / max(transmitted + diffuse, 1e-6), 0.1, 0.9) : 0.0;
			}

			vec3 pt_origin(pt_vertex v, vec3 L) {
				return dot(L, v.Ng) < 0.0 ? v.P_back : pt_offset(v.P, v.Ng);
			}

			vec3 pt_bsdf(pt_vertex v, vec3 L, out float pdf) {
				pdf = 0.0;
				float NoL = dot(v.N, L);
				float NgoL = dot(v.Ng, L);

				if (NoL < 0.0 && NgoL < 0.0 && v.transmission > 0.0) {
					pdf = (1.0 - v.specular_chance) * v.transmission_chance * -NoL / PT_PI;
					return v.transmission * v.transmission_color * v.albedo * (1.0 - v.metallic) * transmission_phase(v.V, L, -NoL, v.transmission_scattering);
				}

				if (NoL <= 0.0 || NgoL <= 0.0) return vec3(0.0);

				vec3 H = normalize(v.V + L);
				float NoH = saturate(dot(v.N, H));
				float LoH = saturate(dot(L, H));
				float D = D_GGXAlpha(v.alpha, NoH);
				float a2 = v.alpha * v.alpha;
				float G1 = 2.0 * v.NoV / (v.NoV + sqrt(a2 + (1.0 - a2) * v.NoV * v.NoV));
				pdf = v.specular_chance * G1 * D / (4.0 * v.NoV) + (1.0 - v.specular_chance) * (1.0 - v.transmission_chance) * NoL / PT_PI;
				vec3 Fr = D * V_SmithGGXCorrelated(v.alpha, v.NoV, NoL) * F_Surface(v.F0, v.dielectric_f0, v.metallic, LoH) * v.energy_compensation;
				vec3 Fd = Fd_EON(v.albedo, v.diffuse_roughness, NoL, v.NoV, dot(L, v.V)) * v.diffuse_view * GGXDiffuseCoupling(v.F0, textureLod(TEXTURE(lighting_data.brdf_lut_tex), vec2(NoL, v.perceptual_roughness), 0.0).rg, v.average_env_brdf);
				return Fr + Fd;
			}

			vec3 pt_sample_direction(pt_vertex v) {
				vec3 T;
				vec3 B;
				pt_basis(v.N, T, B);
				float u = pt_random();
				vec2 xi = vec2(pt_random(), pt_random());

				if (u < v.specular_chance) {
					vec3 H_local = ImportanceSampleGGXVNDF(vec3(dot(v.V, T), dot(v.V, B), dot(v.V, v.N)), v.alpha, xi);
					return reflect(-v.V, normalize(T * H_local.x + B * H_local.y + v.N * H_local.z));
				}

				float r = sqrt(xi.x);
				float phi = 2.0 * PT_PI * xi.y;
				float side = (u - v.specular_chance) / (1.0 - v.specular_chance) < v.transmission_chance ? -1.0 : 1.0;
				return normalize(T * (r * cos(phi)) + B * (r * sin(phi)) + v.N * (side * sqrt(max(1.0 - xi.x, 0.0))));
			}

			float pt_power_heuristic(float a, float b) {
				float a2 = a * a;
				return a2 / max(a2 + b * b, 1e-30);
			}

			vec3 pt_sun_irradiance(lights_t light, vec3 P) {
				vec3 axis = -get_light_direction(light);
				return light.color.rgb * light.color.a * get_ground_fog_sun_transmittance(get_atmosphere_camera_origin(P), axis) * get_cloud_shadow(P);
			}

			vec3 pt_sample_cone(vec3 axis, float one_minus_cos_max) {
				vec3 T;
				vec3 B;
				pt_basis(axis, T, B);
				float one_minus_cos = pt_random() * one_minus_cos_max;
				float sin_theta = sqrt(max(one_minus_cos * (2.0 - one_minus_cos), 0.0));
				float phi = 2.0 * PT_PI * pt_random();
				return normalize(T * (sin_theta * cos(phi)) + B * (sin_theta * sin(phi)) + axis * (1.0 - one_minus_cos));
			}

			float pt_light_one_minus_cos(lights_t light, float dist) {
				float radius = light.direction.w;

				if (radius <= 0.0 || dist <= radius) return 0.0;

				float sin2 = radius * radius / (dist * dist);
				return sin2 / (1.0 + sqrt(1.0 - sin2));
			}

			float pt_light_weight(lights_t light, vec3 N, vec3 axis, float one_minus_cos, float attenuation) {
				float cos_axis = dot(N, axis);
				float cos_cone = 1.0 - one_minus_cos;
				float reach = cos_axis >= cos_cone ? 1.0 : cos_axis * cos_cone + sqrt(max(1.0 - cos_axis * cos_axis, 0.0)) * sqrt(max(one_minus_cos * (2.0 - one_minus_cos), 0.0));
				return luminance(light.color.rgb) * light.color.a * attenuation * max(reach, 0.0);
			}

			float pt_vertex_light_weight(pt_vertex v, lights_t light, vec3 axis, float one_minus_cos, float attenuation) {
				float weight = pt_light_weight(light, v.N, axis, one_minus_cos, attenuation);
				return v.transmission > 0.0 ? max(weight, pt_light_weight(light, -v.N, axis, one_minus_cos, attenuation)) : weight;
			}

			float pt_sphere_distance(vec3 origin, vec3 dir, vec3 center, float radius) {
				vec3 to_center = center - origin;
				float along = dot(to_center, dir);
				return along - sqrt(max(along * along - dot(to_center, to_center) + radius * radius, 0.0));
			}

			vec3 pt_direct(pt_vertex v, out float light_total) {
				vec3 radiance = vec3(0.0);
				light_total = 0.0;
				int picked = -1;
				float picked_weight = 0.0;
				vec3 picked_axis = vec3(0.0);
				float picked_attenuation = 0.0;
				float picked_one_minus_cos = 0.0;
				float u = pt_random();

				for (int i = 0; i < lighting_data.light_count; i++) {
					lights_t light = lighting_data.lights[i];
					int type = get_light_type(light);

					if (type == 0) {
						vec3 L = pt_sample_cone(-get_light_direction(light), PT_SUN_ONE_MINUS_COS);
						float bsdf_pdf;
						vec3 f = pt_bsdf(v, L, bsdf_pdf);

						if (bsdf_pdf <= 0.0) continue;

						vec3 contribution = f * abs(dot(v.N, L)) * pt_sun_irradiance(light, v.P);
						vec3 origin = pt_origin(v, L);

						if (max(max(contribution.r, contribution.g), contribution.b) <= 0.0 || !ray_shadow_visible(origin, L, lighting_data.hit_max_distance, 0u, false)) continue;

						if (lighting_data.light_transmittance != 0) contribution *= lighting_data.pt_caustics != 0 ? get_light_transmittance_caustic(origin, L, OPTICAL_SUN_DISTANCE, 0.0) : get_light_transmittance(origin, L, OPTICAL_SUN_DISTANCE, 0.0);

						radiance += contribution * pt_power_heuristic(1.0 / PT_SUN_SOLID_ANGLE, bsdf_pdf);
						continue;
					}

					vec3 axis;
					float attenuation;

					if (!get_light_vector_and_attenuation(light, v.P, axis, attenuation)) continue;

					float one_minus_cos = type == 2 ? 0.0 : pt_light_one_minus_cos(light, distance(light.position.xyz, v.P));
					float weight = pt_vertex_light_weight(v, light, axis, one_minus_cos, attenuation);

					if (weight <= 0.0) continue;

					light_total += weight;
					float p = weight / light_total;

					if (u < p) {
						u /= p;
						picked = i;
						picked_weight = weight;
						picked_axis = axis;
						picked_attenuation = attenuation;
						picked_one_minus_cos = one_minus_cos;
					} else {
						u = (u - p) / (1.0 - p);
					}
				}

				if (picked < 0) return radiance;

				lights_t light = lighting_data.lights[picked];
				vec3 L = picked_one_minus_cos > 0.0 ? pt_sample_cone(picked_axis, picked_one_minus_cos) : picked_axis;
				float bsdf_pdf;
				vec3 f = pt_bsdf(v, L, bsdf_pdf);

				if (bsdf_pdf <= 0.0) return radiance;

				float pick = picked_weight / light_total;
				vec3 contribution = f * abs(dot(v.N, L)) * light.color.rgb * light.color.a * picked_attenuation / pick;
				vec3 origin = pt_origin(v, L);
				float dist;

				if (get_light_type(light) == 2) {
					dist = light.params.x;
				} else if (picked_one_minus_cos > 0.0) {
					dist = pt_sphere_distance(origin, L, light.position.xyz, light.direction.w) - 0.05 * lighting_data.view_scale;
					contribution *= pt_power_heuristic(pick / (2.0 * PT_PI * picked_one_minus_cos), bsdf_pdf);
				} else {
					dist = dot(light.position.xyz - origin, L) - 0.05 * lighting_data.view_scale;
				}

				if (dist <= 0.0 || !ray_shadow_visible(origin, L, dist, ]] .. string.format("0x%02Xu", scene_instances.MASK_LIGHT_BODY) .. [[, false)) return radiance;

				if (lighting_data.light_transmittance != 0) contribution *= lighting_data.pt_caustics != 0 ? get_light_transmittance_local_caustic(origin, L, dist, 0.0) : get_light_transmittance_local(origin, L, dist, 0.0);

				return radiance + contribution;
			}

			vec3 pt_light_hit(pt_vertex v, vec3 origin, vec3 dir, float bsdf_pdf, float scene_distance, float light_total) {
				vec3 radiance = vec3(0.0);

				for (int i = 0; i < lighting_data.light_count; i++) {
					lights_t light = lighting_data.lights[i];
					int type = get_light_type(light);

					if (type != 1 && type != 3) continue;

					vec3 axis;
					float attenuation;

					if (!get_light_vector_and_attenuation(light, v.P, axis, attenuation)) continue;

					float one_minus_cos = pt_light_one_minus_cos(light, distance(light.position.xyz, v.P));

					if (one_minus_cos <= 0.0 || 1.0 - dot(dir, axis) > one_minus_cos) continue;

					float dist = pt_sphere_distance(origin, dir, light.position.xyz, light.direction.w);

					if (dist <= 0.0 || dist > scene_distance) continue;

					float solid_angle = 2.0 * PT_PI * one_minus_cos;
					float pick = light_total > 0.0 ? pt_vertex_light_weight(v, light, axis, one_minus_cos, attenuation) / light_total : 0.0;
					vec3 contribution = light.color.rgb * light.color.a * attenuation / solid_angle * pt_power_heuristic(bsdf_pdf, pick / solid_angle);

					if (lighting_data.optical_tint != 0) contribution *= get_optical_tint(origin, dir, dist, false);

					radiance += contribution;
				}

				return radiance;
			}

			vec3 pt_light_hit_bent(vec3 origin, vec3 dir, float scene_distance, bool primary, vec3 primary_P) {
				vec3 radiance = vec3(0.0);

				for (int i = 0; i < lighting_data.light_count; i++) {
					lights_t light = lighting_data.lights[i];
					int type = get_light_type(light);

					if (type != 1 && type != 3) continue;

					vec3 axis;
					float attenuation;

					if (!get_light_vector_and_attenuation(light, origin, axis, attenuation)) continue;

					float one_minus_cos = pt_light_one_minus_cos(light, distance(light.position.xyz, origin));

					if (one_minus_cos <= 0.0 || 1.0 - dot(dir, axis) > one_minus_cos) continue;

					float dist = pt_sphere_distance(origin, dir, light.position.xyz, light.direction.w);

					if (dist <= 0.0 || dist > scene_distance) continue;

					if (primary && caustic_covered(i, light.position.xyz, primary_P)) continue;

					vec3 contribution = light.color.rgb * light.color.a * attenuation / (2.0 * PT_PI * one_minus_cos);

					if (lighting_data.optical_tint != 0) contribution *= get_optical_tint(origin, dir, dist, false);

					radiance += contribution;
				}

				return radiance;
			}

			vec3 pt_sky(vec3 dir) {
				if (lighting_data.env_tex == -1) return vec3(0.0);

				// mip 0 holds the sun disc, which pt_sun_hit adds
				float lod = dot(dir, ATMOSPHERE_SKY_SUN_DIRECTION) > 0.9998 ? 1.0 : 0.0;
				vec4 stored = textureLod(TEXTURE(lighting_data.env_tex), dir_to_equirect_uv(correct_environment_lookup_dir(dir)), lod);
				return stored.rgb * stored.a;
			}

			vec3 pt_sun_hit(vec3 dir, vec3 P, float bsdf_pdf, bool bent, bool primary) {
				vec3 radiance = vec3(0.0);

				for (int i = 0; i < lighting_data.light_count; i++) {
					lights_t light = lighting_data.lights[i];

					if (get_light_type(light) != 0 || 1.0 - dot(dir, -get_light_direction(light)) > PT_SUN_ONE_MINUS_COS) continue;

					// the photons carry the sun through glass and water tops to the first surface
					float weight = bent ? (primary && caustic_covered(i, vec3(0.0), P) ? 0.0 : 1.0) : pt_power_heuristic(bsdf_pdf, 1.0 / PT_SUN_SOLID_ANGLE);
					radiance += pt_sun_irradiance(light, P) / PT_SUN_SOLID_ANGLE * weight;
				}

				return radiance;
			}

			vec3 pt_decode_normal(vec4 texel, bool ssbump) {
				if (!ssbump) {
					vec2 xy = texel.xy * 2.0 - 1.0;
					return vec3(xy, sqrt(max(1.0 - dot(xy, xy), 0.0)));
				}

				vec3 w = sqrt(texel.rgb);
				return normalize(w.r * vec3(0.81649661, 0.0, 0.57735026) + w.g * vec3(-0.40824821, 0.70710677, 0.57735026) + w.b * vec3(-0.40824821, -0.70710677, 0.57735026));
			}

			vec3 pt_normal_map(ray_material material, uint instance, uint primitive, vec2 barycentrics, vec3 N, vec2 coord, float blend) {
				vec4 tangent = scene_hit_smooth_tangent(instance, primitive, barycentrics);

				if (dot(tangent.xyz, tangent.xyz) < 1e-12) return N;

				bool ssbump = material.normal_ssbump != 0;
				vec2 bump_coord = vec2(dot(material.bump_transform_u.xy, coord) + material.bump_transform_u.z, dot(material.bump_transform_v.xy, coord) + material.bump_transform_v.z);
				vec3 n = pt_decode_normal(textureLod(TEXTURE(material.normal_tex), bump_coord, 0.0), ssbump);
				n = normalize(vec3(n.xy * material.normal_scale, n.z));

				if (material.normal2_tex >= 0 && blend != 0.0) n = normalize(mix(n, pt_decode_normal(textureLod(TEXTURE(material.normal2_tex), coord, 0.0), ssbump), blend));

				n = normalize(vec3(n.xy * lighting_data.normal_map_strength, n.z));
				vec3 T = normalize(tangent.xyz);
				vec3 B = cross(N, T) * tangent.w;
				return normalize(T * n.x + B * n.y + N * n.z);
			}

			vec3 pt_terrain_layer_normal(int tex, vec3 P, float scale, vec3 blend, vec3 N) {
				float safe_scale = max(scale, 0.0001);
				vec3 n = vec3(0.0);

				for (int a = 0; a < 3; a++) {
					float w = a == 0 ? blend.y : (a == 1 ? blend.x : blend.z);

					if (w <= 0.001) continue;

					vec3 t = textureLod(TEXTURE(tex), (a == 0 ? P.xz : (a == 1 ? vec2(-P.z, -P.y) : vec2(P.x, -P.y))) / safe_scale, 0.0).xyz * 2.0 - 1.0;
					t.xy *= a == 1 ? vec2(-1.0) : (a == 2 ? vec2(1.0, -1.0) : vec2(1.0));
					vec3 tn = vec3(t.xy + (a == 0 ? N.xz : (a == 1 ? N.zy : N.xy)), abs(t.z) * (a == 0 ? N.y : (a == 1 ? N.x : N.z)));
					n += (a == 0 ? tn.xzy : (a == 1 ? tn.zyx : tn.xyz)) * w;
				}

				return n;
			}

			vec3 pt_terrain_normal(ray_material material, vec2 coord, vec3 P) {
				vec3 N = vec3(0.0, 1.0, 0.0);

				if (material.normal_tex >= 0) {
					vec2 xz = textureLod(TEXTURE(material.normal_tex), coord, 0.0).xy * 2.0 - 1.0;
					N = normalize(vec3(xz.x, sqrt(max(1.0 - dot(xz, xz), 0.0)), xz.y));
				}

				vec4 weights = max(textureLod(TEXTURE(material.terrain_tex), coord, 0.0), vec4(0.0));
				vec4 weights2 = material.terrain_tex2 >= 0 ? max(textureLod(TEXTURE(material.terrain_tex2), coord, 0.0), vec4(0.0)) : vec4(0.0);
				float weight_sum = dot(weights, vec4(1.0)) + dot(weights2, vec4(1.0));

				if (weight_sum <= 0.0001) return N;

				weights /= weight_sum;
				weights2 /= weight_sum;
				vec3 sharp = abs(N);
				sharp = pow(sharp / max(max(sharp.x, sharp.y), max(sharp.z, 0.0001)), vec3(max(material.terrain_triplanar_sharpness, 1.0)));
				sharp /= max(sharp.x + sharp.y + sharp.z, 0.0001);
				vec3 blend = max(sharp - 0.05, vec3(0.0));
				blend /= max(blend.x + blend.y + blend.z, 0.0001);
				vec3 n = vec3(0.0);
				float normal_weight = 0.0;

				for (int k = 0; k < (material.terrain_tex2 >= 0 ? 8 : 4); k++) {
					int i = k & 3;
					bool second = k >= 4;
					int tex = second ? material.terrain_layer_normal_tex2[i] : material.terrain_layer_normal_tex[i];
					float weight = second ? weights2[i] : weights[i];

					if (tex < 0 || weight <= 0.001) continue;

					n += pt_terrain_layer_normal(tex, P, second ? material.terrain_scales2[i] : material.terrain_scales[i], blend, N) * weight;
					normal_weight += weight;
				}

				return normal_weight > 0.001 ? normalize(mix(N, normalize(n), normal_weight)) : N;
			}

			bool pt_hit_vertex(vec3 dir, uint instance, uint primitive, vec2 barycentrics, out pt_vertex v, out vec3 emission) {
				scene_triangle tri = scene_hit_tri(instance, primitive);
				ray_material material = ray_materials[tri.material];
				vec3 Ng = -tri.normal;
				bool back = dot(dir, Ng) > 0.0;
				emission = vec3(0.0);

				if (back && material.double_sided == 0) return false;

				vec3 P = tri.v0 + tri.e1 * barycentrics.x + tri.e2 * barycentrics.y;
				scene_uv uv = scene_hit_uv(instance, primitive);
				vec3 weights = vec3(1.0 - barycentrics.x - barycentrics.y, barycentrics);
				vec2 coord = uv.uv0 * weights.x + uv.uv1 * weights.y + uv.uv2 * weights.z;
				float blend = dot(uv.blend, weights);

				if (material.blend_tex >= 0) {
					vec2 modulate = textureLod(TEXTURE(material.blend_tex), coord, 0.0).rg;
					blend = smoothstep(clamp(modulate.g - modulate.r, 0.0, 1.0), clamp(modulate.g + modulate.r, 0.0, 1.0), blend);
				}

				vec3 N = scene_hit_smooth_normal(instance, primitive, barycentrics);
				vec3 albedo = ray_material_albedo(material, P);
				float roughness = material.roughness;
				float metallic = material.metallic;

				if (material.terrain_tex >= 0) {
					N = pt_terrain_normal(material, coord, P);
				} else {
					if (material.normal_tex >= 0) N = pt_normal_map(material, instance, primitive, barycentrics, N, coord, blend);

					if (material.albedo_tex >= 0) {
						vec3 rgb = textureLod(TEXTURE(material.albedo_tex), coord, 0.0).rgb;

						if (material.albedo2_tex >= 0) rgb = mix(rgb, textureLod(TEXTURE(material.albedo2_tex), coord, 0.0).rgb, blend);

						albedo = material.albedo * rgb;
					}

					if (material.roughness_tex >= 0) roughness *= mix(material.roughness_min, material.roughness_max, textureLod(TEXTURE(material.roughness_tex), coord, 0.0)[material.roughness_channel]);

					if (material.metallic_tex >= 0) metallic *= textureLod(TEXTURE(material.metallic_tex), coord, 0.0)[material.metallic_channel];
				}

				if (back) {
					Ng = -Ng;
					N = -N;
				}

				if (dot(N, Ng) <= 0.0) N = Ng;

				ProjectedDecalSurface decal_surface;
				decal_surface.albedo = albedo;
				decal_surface.N = N;
				decal_surface.roughness = roughness;
				decal_surface.metallic = metallic;

				if (ray_material_decals(material, P, Ng, 0.0, decal_surface)) {
					albedo = decal_surface.albedo;
					N = decal_surface.N;
					roughness = decal_surface.roughness;
					metallic = decal_surface.metallic;
				}

				emission = ray_hit_emission(tri, albedo, P, instance, primitive, dir);
				albedo = ray_medium_albedo(material, albedo);
				metallic = clamp(metallic, 0.0, 1.0);
				v.transmission = material.transmission;

				if (material.transmission_tex >= 0) v.transmission *= luminance(textureLod(TEXTURE(material.transmission_tex), coord, 0.0).rgb);

				v.transmission = saturate(v.transmission);

				v.transmission_color = material.transmission_color;
				v.transmission_scattering = material.transmission_scattering;
				v.P = P;
				v.P_back = pt_offset(P, -Ng);
				v.N = N;
				v.Ng = Ng;
				v.V = -dir;
				v.albedo = albedo;
				v.metallic = metallic;
				v.dielectric_f0 = 0.04 * material.specular;
				v.diffuse_roughness = material.diffuse_roughness;
				v.F0 = mix(vec3(v.dielectric_f0), albedo, metallic);
				v.alpha = clamp(roughness * roughness, 0.002, 1.0);
				v.perceptual_roughness = sqrt(v.alpha);
				pt_prepare(v);
				return true;
			}

			vec3 pt_path(pt_vertex v) {
				vec3 radiance = vec3(0.0);
				vec3 throughput = vec3(1.0);
				float wavelength = 0.0;
				bool caustics = lighting_data.pt_caustics != 0;

				for (int bounce = 0; ; bounce++) {
					float light_total;
					radiance += throughput * pt_direct(v, light_total);

					if (bounce >= lighting_data.pt_bounces) break;

					vec3 L = pt_sample_direction(v);
					float pdf;
					vec3 f = pt_bsdf(v, L, pdf);

					if (pdf <= 0.0) break;

					throughput *= f * abs(dot(v.N, L)) / pdf;

					if (bounce >= 2) {
						float survive = clamp(max(max(throughput.r, throughput.g), throughput.b), 0.05, 0.95);

						if (pt_random() >= survive) break;

						throughput /= survive;
					}

					vec3 origin = pt_origin(v, L);
					vec3 dir = L;
					bool through_glass = false;
					bool through_water = false;
					bool surface = false;
					float t;
					uint instance;
					uint primitive;
					vec2 barycentrics;

					for (int event = 0; event <= lighting_data.caustic_bounces; event++) {
						bool hit = pt_trace(origin, dir, t, instance, primitive, barycentrics);
						float reach = hit ? t : lighting_data.hit_max_distance;
						float top_t;

						if (caustics && caustic_water_top(origin, dir, reach, top_t) >= 0) through_water = true;

						if (through_glass || through_water) {
							radiance += throughput * pt_light_hit_bent(origin, dir, reach, bounce == 0, v.P);
						} else if (light_total > 0.0) {
							radiance += throughput * pt_light_hit(v, origin, dir, pdf, reach, light_total);
						}

						if (!hit) {
							if (lighting_data.optical_tint != 0) throughput *= get_optical_tint(origin, dir, OPTICAL_SUN_DISTANCE, false);

							radiance += throughput * (pt_sky(dir) + pt_sun_hit(dir, v.P, pdf, through_glass || through_water, bounce == 0));
							return radiance;
						}

						// stops short of the hit, a caster's own face is absorbed below
						if (lighting_data.optical_tint != 0) throughput *= get_optical_tint(origin, dir, t * 0.999, false);

						scene_triangle tri = scene_hit_tri(instance, primitive);
						ray_material material = ray_materials[tri.material];

						if (!caustics || material.caustic == 0) {
							surface = true;
							break;
						}

						vec3 P = origin + dir * t;
						vec3 Ng = -tri.normal;
						bool entering = dot(dir, Ng) < 0.0;

						if (!entering) throughput *= caustic_body_tint(material, t, instance, primitive, barycentrics);

						if (wavelength <= 0.0 && caustic_splits(material.medium_ior, material.abbe, lighting_data.caustic_dispersion_spread)) {
							wavelength = mix(CAUSTIC_WAVELENGTH_MIN, CAUSTIC_WAVELENGTH_MAX, pt_random());
							throughput *= caustic_spectrum(wavelength);
						}

						vec3 N = scene_hit_smooth_normal(instance, primitive, barycentrics);

						if (dot(N, Ng) <= 0.0) N = Ng;

						float ior = caustic_ior(material.medium_ior, material.abbe, wavelength);
						caustic_rng = pt_rng;
						bool refracted;
						dir = caustic_scatter(dir, entering ? N : -N, material.roughness * material.roughness, entering ? 1.0 / ior : ior, refracted);
						pt_rng = caustic_rng;
						origin = pt_offset(P, dot(dir, Ng) > 0.0 ? Ng : -Ng);
						through_glass = true;
					}

					if (!surface) break;

					vec3 emission;

					if (!pt_hit_vertex(dir, instance, primitive, barycentrics, v, emission)) break;

					radiance += throughput * emission;
				}

				return radiance;
			}

			bool pt_primary(ivec2 pos, ivec2 size, bool refine, out pt_vertex primary, out vec3 emissive) {
				in_uv = get_screen_uv(pos, size);
				in_pixel = pos;
				float depth = gbuffer_depth(in_uv);
				emissive = vec3(0.0);

				if (depth == 0.0 || gbuffer_alpha(in_uv) == 0.0) return false;

				in_view_depth = -(lighting_data.inv_projection[2][2] * depth + lighting_data.inv_projection[3][2]) / (lighting_data.inv_projection[2][3] * depth + lighting_data.inv_projection[3][3]);
				vec3 world_pos = get_world_pos(depth);
				vec3 V = normalize(lighting_data.camera_position.xyz - world_pos);
				vec3 N = bend_normal_to_view(gbuffer_normal(in_uv), V);

				Surface surface;
				surface.NdotV = max(dot(N, V), 0.001);
				surface.world_pos = world_pos;
				surface.V = V;
				surface.N = N;
				surface.geometric_N = get_geometric_normal(ivec2(in_uv * vec2(textureSize(TEXTURE(lighting_data.depth_tex), 0))), world_pos, depth, V);
				decode_surface_features(surface, in_uv, size);
				finish_surface_features(surface);

				float surface_offset = 0.001 * lighting_data.view_scale + 0.0005 * in_view_depth;
				primary.P = world_pos + surface.geometric_N * surface_offset;
				primary.P_back = world_pos - surface.geometric_N * surface_offset;
				primary.Ng = surface.geometric_N;

				if (refine) {
					float camera_distance = distance(world_pos, lighting_data.camera_position.xyz);
					float tolerance = 0.002 * camera_distance + 0.01 * lighting_data.view_scale;
					float t;
					uint instance;
					uint primitive;
					vec2 barycentrics;

					if (pt_trace(lighting_data.camera_position.xyz, -V, t, instance, primitive, barycentrics) && abs(t - camera_distance) < tolerance) {
						vec3 Ng = -scene_hit_tri(instance, primitive).normal;
						primary.Ng = dot(Ng, V) < 0.0 ? -Ng : Ng;
						primary.P = pt_offset(lighting_data.camera_position.xyz - V * t, primary.Ng);
						primary.P_back = pt_offset(lighting_data.camera_position.xyz - V * t, -primary.Ng);
					}
				}

				primary.N = surface.N;
				primary.V = V;
				primary.albedo = surface.albedo;
				primary.F0 = surface.F0;
				primary.alpha = surface.roughness_alpha;
				primary.perceptual_roughness = surface.perceptual_roughness;
				primary.metallic = surface.metallic;
				primary.dielectric_f0 = 0.04 * surface.specular;
				primary.diffuse_roughness = surface.diffuse_roughness;
				primary.transmission = surface.transmission;
				primary.transmission_color = surface.transmission_color;
				primary.transmission_scattering = surface.transmission_scattering;
				pt_prepare(primary);
				emissive = surface.emissive;
				return true;
			}

]]
local uniform_block = {
	surface_lighting.block,
	gbuffer_layout.block,
	surface_weather.rain_surface_block,
	render3d.last_frame_block,
	caustics.block,
	{"hit_max_distance", "float"},
	{"pt_samples_before", "int"},
	{"pt_samples_per_frame", "int"},
	{"pt_trace", "int"},
	{"pt_bounces", "int"},
	{"pt_view", "int"},
	{"pt_split", "float"},
	{"pt_difference_stops", "float"},
	{"pt_caustics", "int"},
	{"pt_raw", "int"},
}

local function write_block(self, block, photons)
	surface_lighting.WriteBlock(self, block)
	gbuffer_layout.WriteBlock(self, block)
	surface_weather.WriteRainSurfaceBlock(self, block)
	render3d.WriteLastFrameBlock(self, block)

	if photons then path_trace.Update(block.lights) end

	local before, trace = path_trace.GetFrame()
	local caustic = path_trace.caustics:Get() and optical_rays.IsEnabled()
	block.hit_max_distance = scene_hits.max_distance:Get()
	block.pt_samples_before = before
	block.pt_samples_per_frame = path_trace.samples_per_frame:Get()
	block.pt_trace = trace and 1 or 0
	block.pt_bounces = path_trace.bounces:Get()
	block.pt_view = VIEW_INDEX[path_trace.view:Get()]
	block.pt_split = path_trace.split:Get()
	block.pt_difference_stops = path_trace.difference_stops:Get()
	block.pt_caustics = caustic and 1 or 0
	block.pt_raw = render3d.IsAntiAliasingEnabled("dlss_rr") and 1 or 0
	return caustics.WriteBlock(
		self,
		block,
		photons and trace and caustic and path_trace.photons:Get() or 0,
		true
	)
end

local function bind_photons(self, cmd, desc)
	local size = render3d.GetRenderSize()
	local buffer = caustics.GetBuffer("path", cmd, size.x, size.y)
	self:UpdateDescriptorSet("storage_buffer", desc, BINDING_PHOTONS, 0, buffer, buffer:GetSize())
end

local function is_enabled()
	return render3d.IsPassEnabled("lighting")
end

local occlusion_map = {
	binding_index = BINDING_OCCLUSION_MAP,
	get_texture = function()
		return light_occlusion.GetOcclusionTexture()
	end,
}
local declarations = surface_lighting.GetDeclarationGLSL(BINDING_LIGHT_GRID, BINDING_OCCLUSION_MAP) .. optical_rays.GetDeclarationGLSL(SCENE_BINDINGS) .. caustics.GetBufferDeclarationGLSL(BINDING_PHOTONS)
return {
	{
		name = "path_trace_photons",
		ComputePass = true,
		is_enabled = is_enabled,
		ColorFormat = {{"r8_unorm", {"path_trace_photons_dummy", "r"}}},
		FramebufferSize = {x = 1, y = 1},
		framebuffer_count = 1,
		LocalSize = PHOTON_LOCAL_SIZE,
		storage_buffers = {{binding_index = BINDING_LIGHT_GRID}, {binding_index = BINDING_PHOTONS}},
		descriptor_sets = scene_hits.GetDescriptorSets(SCENE_BINDINGS, "compute"),
		on_pre_draw = function(self, cmd, frame, desc)
			light_grid.Bind(self, cmd, desc, BINDING_LIGHT_GRID)
			scene_hits.Bind(self, cmd, desc, SCENE_BINDINGS)
			bind_photons(self, cmd, desc)
		end,
		on_draw = function(self, cmd, fb, frame, desc)
			caustics.Barrier(cmd, "path")
			self:UploadConstants()

			if self.photon_count > 0 then
				self.pipeline:DispatchForSize(
					cmd,
					PHOTON_ROW,
					math.ceil(self.photon_count / PHOTON_ROW),
					1,
					desc,
					self.dynamic_offsets
				)
			end

			caustics.Barrier(cmd, "path")
		end,
		sampled_images = {occlusion_map},
		uniform_buffers = {
			{
				-- the surface features' decode snippets read the block as lighting_data
				name = "lighting_data",
				binding_index = BINDING_UNIFORM,
				block = uniform_block,
				write = function(self, block)
					self.photon_count = write_block(self, block, true)
					return block
				end,
			},
		},
		custom_declarations = declarations,
		shader = GLSL .. [[
			bool caustic_land(vec3 P, vec3 Ng, vec3 incoming, vec3 flux) {
				ivec2 pixel = caustic_screen_pixel(P, Ng);

				if (pixel.x < 0) return false;

				pt_vertex primary;
				vec3 emissive;

				if (!pt_primary(pixel, ivec2(lighting_data.render_size), false, primary, emissive)) return false;

				float pdf;
				vec3 f = pt_bsdf(primary, -incoming, pdf);
				caustic_add(uint(pixel.y) * uint(lighting_data.render_size.x) + uint(pixel.x), f * flux / caustic_pixel_area(P, Ng) * get_pre_exposure());
				return true;
			}

			void main() {
				uint id = gl_GlobalInvocationID.y * ]] .. PHOTON_ROW .. [[u + gl_GlobalInvocationID.x;

				uvec4 seed = pcg4d(uvec4(id, uint(lighting_data.pt_samples_before), 0x2545F491u, 0x68E31DA4u));
				caustic_rng = seed.x ^ seed.w;
				caustic_run(id, lighting_data.caustic_bounces, lighting_data.caustic_dispersion_spread, lighting_data.view_scale);
			}
		]],
	},
	{
		name = "path_trace",
		ComputePass = true,
		is_enabled = is_enabled,
		ColorFormat = {
			{"r32g32b32a32_sfloat", {"path_trace", "rgba"}},
			{"r32g32b32a32_sfloat", {"path_trace_raster", "rgba"}},
			{"r16g16b16a16_sfloat", {"path_trace_view", "rgba"}},
		},
		framebuffer_count = 1,
		LocalSize = COMPUTE_LOCAL_SIZE,
		storage_images = {
			{binding_index = BINDING_ACCUM, attachment = 1, dst_stage = "compute"},
			{binding_index = BINDING_RASTER, attachment = 2, dst_stage = "compute"},
			{binding_index = BINDING_VIEW, attachment = 3, dst_stage = "compute"},
			{
				binding_index = BINDING_SCENE_COLOR,
				dst_stage = {"compute", "fragment"},
				get_texture = function()
					return lighting_attachment(1)
				end,
			},
			{
				binding_index = BINDING_SUBSURFACE,
				dst_stage = "compute",
				get_texture = function()
					return lighting_attachment(2)
				end,
			},
		},
		storage_buffers = {{binding_index = BINDING_LIGHT_GRID}, {binding_index = BINDING_PHOTONS}},
		descriptor_sets = scene_hits.GetDescriptorSets(SCENE_BINDINGS, "compute"),
		on_pre_draw = function(self, cmd, frame, desc)
			light_grid.Bind(self, cmd, desc, BINDING_LIGHT_GRID)
			scene_hits.Bind(self, cmd, desc, SCENE_BINDINGS)
			bind_photons(self, cmd, desc)
		end,
		sampled_images = {occlusion_map},
		uniform_buffers = {
			{
				name = "lighting_data",
				binding_index = BINDING_UNIFORM,
				block = uniform_block,
				write = function(self, block)
					write_block(self, block, false)
					return block
				end,
			},
		},
		custom_declarations = [[
			layout(set = 0, binding = ]] .. BINDING_ACCUM .. [[, rgba32f) uniform image2D path_accum;
			layout(set = 0, binding = ]] .. BINDING_RASTER .. [[, rgba32f) uniform writeonly image2D path_raster;
			layout(set = 0, binding = ]] .. BINDING_SCENE_COLOR .. [[, rgba16f) uniform image2D scene_color;
			layout(set = 0, binding = ]] .. BINDING_SUBSURFACE .. [[, rgba16f) uniform writeonly image2D scene_subsurface_diffuse;
			layout(set = 0, binding = ]] .. BINDING_VIEW .. [[, rgba16f) uniform writeonly image2D path_view;
		]] .. declarations,
		shader = GLSL .. [[
			void main() {
				ivec2 pos = get_screen_pos();
				ivec2 size = imageSize(path_accum);

				if (!is_screen_pos_in_bounds(pos, size)) return;

				vec4 raster = imageLoad(scene_color, pos);
				vec4 accum = lighting_data.pt_samples_before > 0 ? imageLoad(path_accum, pos) : vec4(0.0);
				vec3 caustic = vec3(0.0);

				if (lighting_data.pt_trace != 0 && lighting_data.pt_caustics != 0) caustic = caustic_take(uint(pos.y * size.x + pos.x)) / get_pre_exposure();

				pt_vertex primary;
				vec3 emissive;

				if (!pt_primary(pos, size, lighting_data.pt_trace != 0, primary, emissive)) {
					imageStore(path_accum, pos, accum);
					imageStore(path_raster, pos, vec4(0.0));
					imageStore(path_view, pos, vec4(vec3(0.02), 1.0));
					return;
				}

				vec3 frame_color = vec3(0.0);

				if (lighting_data.pt_trace != 0) {
					vec3 sum = vec3(0.0);
					uint frame_sample = uint(lighting_data.pt_samples_before);

					for (int s = 0; s < lighting_data.pt_samples_per_frame; s++) {
						uvec4 seed = pcg4d(uvec4(uint(pos.x), uint(pos.y), frame_sample + uint(s), 0x9E3779B9u));
						pt_rng = seed.x ^ seed.y;
						sum += emissive + caustic + pt_path(primary);
					}

					if (!any(isnan(sum)) && !any(isinf(sum))) {
						frame_color = sum / float(lighting_data.pt_samples_per_frame);
						float count = accum.a + float(lighting_data.pt_samples_per_frame);
						accum = vec4(accum.rgb + (sum - accum.rgb * float(lighting_data.pt_samples_per_frame)) / count, count);
					}

					imageStore(path_accum, pos, accum);
				}

				vec3 raster_radiance = raster.rgb / get_pre_exposure();
				imageStore(path_raster, pos, vec4(raster_radiance, 1.0));

				int view = lighting_data.pt_view;

				if (view == 3) {
					float path_level = luminance(accum.rgb);
					float raster_level = luminance(raster_radiance);
					float shown = (accum.a > 0.0 ? path_level : raster_level) * get_exposure();
					float grey = shown / (1.0 + shown);
					float difference = accum.a > 0.0 ? clamp(log2(max(raster_level, 1e-9) / max(path_level, 1e-9)) / max(lighting_data.pt_difference_stops, 1e-3), -1.0, 1.0) : 0.0;
					vec3 tint = difference > 0.0 ? vec3(1.0, 0.1, 0.1) : vec3(0.1, 0.35, 1.0);
					imageStore(path_view, pos, vec4(mix(vec3(grey), tint * max(grey, 0.3), abs(difference)), 1.0));
					return;
				}

				if (accum.a <= 0.0) return;

				vec3 color = lighting_data.pt_raw != 0 ? frame_color : accum.rgb;

				if (view == 1) return;

				if (view == 2) {
					float split = lighting_data.pt_split * float(size.x);

					if (float(pos.x) < split - 0.5) return;

					if (float(pos.x) < split + 0.5) color = vec3(0.0);
				}

				imageStore(scene_color, pos, vec4(min(color * get_pre_exposure(), vec3(65504.0)), raster.a));
				imageStore(scene_subsurface_diffuse, pos, vec4(0.0));
			}
		]],
	},
}
