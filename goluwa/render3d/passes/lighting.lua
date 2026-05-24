local Vec3 = import("goluwa/structs/vec3.lua")
local assets = import("goluwa/assets.lua")
local system = import("goluwa/system.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local atmosphere = import("goluwa/render3d/atmosphere.lua")
local directional_shadows = import("goluwa/render3d/directional_shadows.lua")
local screen_reconstruct = import("goluwa/render3d/screen_reconstruct.lua")
local scene_lights = import("goluwa/render3d/scene_lights.lua")
local lightprobes = import("goluwa/render3d/lightprobes.lua")
local ibl = import("goluwa/render3d/ibl.lua")
local get_primary_sun = directional_shadows.GetPrimarySun
local get_primary_sun_direction = directional_shadows.GetPrimarySunDirection
local get_primary_sun_intensity = directional_shadows.GetPrimarySunIntensity
local MAX_LIGHTS = scene_lights.MAX_LIGHTS
local MAX_CASCADES = scene_lights.MAX_CASCADES
local MAX_POINT_SHADOWS = scene_lights.MAX_POINT_SHADOWS
local MAX_PROBES = 64
local SSAO_KERNEL = {}

for i = 1, 64 do
	math.randomseed(i)
	local sample = Vec3(math.random() * 2 - 1, math.random() * 2 - 1, math.random()):Normalize()
	sample = sample * math.random()
	local scale = (i - 1) / 64
	scale = math.lerp(0.1, 1.0, scale * scale)
	SSAO_KERNEL[i] = sample * scale
end

local function sort_lights(a, b)
	if a.last_update_frame ~= b.last_update_frame then
		return a.last_update_frame > b.last_update_frame
	end

	if a.distance_score ~= b.distance_score then
		return a.distance_score < b.distance_score
	end

	return a.light_index < b.light_index
end

local function write_shadow_block(self, shadow_block, lights)
	return scene_lights.WriteShadowBlock(self, shadow_block, lights)
end

local function write_lights_block(lights_block, lights)
	return scene_lights.WriteLightsBlock(lights_block, lights)
end

return {
	{
		name = "lighting",
		ColorFormat = {{"r16g16b16a16_sfloat", {"color", "rgba"}}},
		framebuffer_count = 2,
		fragment = {
			uniform_buffers = {
				{
					name = "lighting_data",
					binding_index = 3,
					block = {
						render3d.camera_block,
						{"ssao_kernel", "vec3", 64},
						{"lights", scene_lights.BuildLightsBlockLayout(), 128},
						{"light_count", "int"},
						{"shadows", scene_lights.BuildShadowsBlockLayout()},
						render3d.debug_block,
						render3d.gbuffer_block,
						{"env_tex", "int"},
						{"blue_noise_tex", "int"},
						render3d.last_frame_block,
						render3d.common_block,
						{"primary_sun_intensity", "float"},
						{"primary_sun_direction", "vec4"},
						{"atmosphere_transmittance_texture_index", "int"},
						{"ssr_tex", "int"},
						{"probe_color_textures", "int", 64},
						{"probe_depth_textures", "int", 64},
						{"probe_positions", "vec4", 64},
					},
					write = function(self, block)
						render3d.WriteCameraBlock(self, block)

						for i, sample in ipairs(SSAO_KERNEL) do
							sample:CopyToFloatPointer(block.ssao_kernel[i - 1])
						end

						local lights = render3d.GetLights()
						local light_count = math.min(#lights, MAX_LIGHTS)
						block.light_count = light_count
						write_lights_block(block.lights, lights)
						write_shadow_block(self, block.shadows, lights)
						render3d.WriteDebugBlock(self, block)
						render3d.WriteGBufferBlock(self, block)
						block.env_tex = self:GetTextureIndex(render3d.GetEnvironmentTexture())
						block.blue_noise_tex = self:GetTextureIndex(assets.GetTexture("textures/render/blue_noise.lua"))
						render3d.WriteLastFrameBlock(self, block)
						render3d.WriteCommonBlock(self, block)
						get_primary_sun_direction(lights):CopyToFloatPointer(block.primary_sun_direction)
						block.primary_sun_intensity = get_primary_sun_intensity(lights)
						block.atmosphere_transmittance_texture_index = self:GetTextureIndex(atmosphere.GetTransmittanceTexture())

						if
							not render3d.pipelines.ssr_resolve or
							not render3d.pipelines.ssr_resolve.framebuffers
						then
							block.ssr_tex = -1
						else
							local current_idx = system.GetFrameNumber() % 2 + 1
							local current_ssr_fb = render3d.pipelines.ssr_resolve:GetFramebuffer(current_idx)
							block.ssr_tex = self:GetTextureIndex(current_ssr_fb:GetAttachment(1))
						end

						for i = 0, MAX_PROBES - 1 do
							block.probe_color_textures[i] = -1
							block.probe_depth_textures[i] = -1
							block.probe_positions[i][0] = 0
							block.probe_positions[i][1] = 0
							block.probe_positions[i][2] = 0
							block.probe_positions[i][3] = 0
						end

						if lightprobes.IsEnabled() then
							local probes = lightprobes.GetProbes()

							for i = 0, MAX_PROBES - 1 do
								local probe = probes[i + 1]

								if probe then
									if probe.cubemap then
										block.probe_color_textures[i] = self:GetTextureIndex(probe.cubemap)
									end

									if probe.depth_cubemap then
										block.probe_depth_textures[i] = self:GetTextureIndex(probe.depth_cubemap)
									end

									block.probe_positions[i][0] = probe.position.x
									block.probe_positions[i][1] = probe.position.y
									block.probe_positions[i][2] = probe.position.z
									block.probe_positions[i][3] = probe.radius or 20
								end
							end
						end

						return block
					end,
				},
			},
			shader = [[
			vec3 get_albedo() {
				return texture(TEXTURE(lighting_data.albedo_tex), in_uv).rgb;
			}

			float get_alpha() {
				return texture(TEXTURE(lighting_data.albedo_tex), in_uv).a;
			}

			float get_depth() {
				return texture(TEXTURE(lighting_data.depth_tex), in_uv).r;
			}

			vec3 get_normal() {
				return texture(TEXTURE(lighting_data.normal_tex), in_uv).xyz;
			}

			float get_transmission_view_dependency() {
				return texture(TEXTURE(lighting_data.normal_tex), in_uv).a;
			}

			float get_metallic() {
				vec3 mra = texture(TEXTURE(lighting_data.mra_tex), in_uv).rgb;
				return mra.r;
			}

			float get_roughness() {
				vec3 mra = texture(TEXTURE(lighting_data.mra_tex), in_uv).rgb;
				return mra.g;
			}

			float get_ao() {
				vec3 mra = texture(TEXTURE(lighting_data.mra_tex), in_uv).rgb;
				return mra.b;
			}

			float get_subsurface() {
				return texture(TEXTURE(lighting_data.mra_tex), in_uv).a;
			}

			vec3 get_emissive() {
				return texture(TEXTURE(lighting_data.emissive_tex), in_uv).rgb;
			}

			float get_transmission_blocking() {
				return texture(TEXTURE(lighting_data.emissive_tex), in_uv).a;
			}

			vec3 get_transmission_color() {
				return texture(TEXTURE(lighting_data.emissive_tex), in_uv).rgb;
			}

			#define ATMOSPHERE_SUN_INTENSITY lighting_data.primary_sun_intensity


			]] .. import("goluwa/render3d/atmosphere.lua").GetAerialPerspectiveGLSLCode() .. [[


			#define SSR 1
			#define PARALLAX_CORRECTION 1
			#define uv in_uv
			float hash(vec2 p) {
				p = fract(p * vec2(123.34, 456.21));
				p += dot(p, p + 45.32);
				return fract(p.x * p.y);
			}

			vec3 random_vec3(vec2 p) {
				return vec3(hash(p), hash(p + 1.0), hash(p + 2.0)) * 2.0 - 1.0;
			}

			#define saturate(x) clamp(x, 0.0, 1.0)
			]] .. ibl.GetBRDFGLSLCode() .. [[

			]] .. ibl.GetEnvironmentGLSLCode() .. [[

			]] .. ibl.GetReflectionGLSLCode() .. [[
			]] .. scene_lights.GetLightGLSLCode() .. [[

			// Cascade debug colors
			const vec3 CASCADE_COLORS[4] = vec3[4](
				vec3(1.0, 0.2, 0.2),  // Red - cascade 1
				vec3(0.2, 1.0, 0.2),  // Green - cascade 2
				vec3(0.2, 0.2, 1.0),  // Blue - cascade 3
				vec3(1.0, 1.0, 0.2)   // Yellow - cascade 4
			);

			float random(vec2 co)
			{
				return fract(sin(dot(co.xy ,vec2(12.9898,78.233))) * 43758.5453);
			}
			vec3 get_noise3_world(vec3 world_pos)
			{
				float x = random(world_pos.xy);
				float y = random(world_pos.yz * x);
				float z = random(world_pos.xz * y);

				return vec3(x, y, z) * 2.0 - 1.0;
			}

			]] .. directional_shadows.GetSurfaceDirectionalShadowGLSL("lighting_data", "calculateShadow") .. [[

			int getPointShadowSlot(int light_index) {
				for (int i = 0; i < lighting_data.shadows.point_shadow_count; i++) {
					if (lighting_data.shadows.point_shadow_light_indices[i] == light_index) {
						return i;
					}
				}

				return -1;
			}

			float samplePointShadowProjection(int shadow_map_idx, vec3 sample_dir, float current_depth, float bias, float filter_radius_texels) {
				vec3 lookup_dir = normalize(vec3(-sample_dir.x, sample_dir.y, sample_dir.z));
				float face_size = float(textureSize(CUBEMAP(shadow_map_idx), 0).x);
				float angular_radius = filter_radius_texels / max(face_size, 1.0);
				vec3 up = abs(lookup_dir.y) < 0.999 ? vec3(0.0, 1.0, 0.0) : vec3(1.0, 0.0, 0.0);
				vec3 tangent = normalize(cross(up, lookup_dir));
				vec3 bitangent = cross(lookup_dir, tangent);
				float visibility = 0.0;
				const vec2 POISSON_DISK[8] = vec2[8](
					vec2(-0.326, -0.406),
					vec2(-0.840, -0.074),
					vec2(-0.696,  0.457),
					vec2(-0.203,  0.621),
					vec2( 0.962, -0.195),
					vec2( 0.473, -0.480),
					vec2( 0.519,  0.767),
					vec2( 0.185, -0.893)
				);

				for (int i = 0; i < 8; i++) {
					vec2 offset = POISSON_DISK[i] * angular_radius;
					vec3 tap_dir = normalize(lookup_dir + tangent * offset.x + bitangent * offset.y);
					float stored_depth = texture(CUBEMAP(shadow_map_idx), tap_dir).r;
					visibility += current_depth - bias > stored_depth ? 0.0 : 1.0;
				}

				return visibility / 8.0;
			}

			float calculatePointShadow(int shadow_slot, vec3 world_pos, vec3 normal, vec3 light_dir) {
				if (shadow_slot < 0 || shadow_slot >= lighting_data.shadows.point_shadow_count) return 1.0;

				int shadow_map_idx = lighting_data.shadows.point_shadow_map_indices[shadow_slot];
				if (shadow_map_idx < 0) return 1.0;

				vec3 light_pos = lighting_data.shadows.point_shadow_positions[shadow_slot].xyz;
				float far_plane = lighting_data.shadows.point_shadow_positions[shadow_slot].w;
				float face_size = float(textureSize(CUBEMAP(shadow_map_idx), 0).x);
				float texel_world_size = far_plane / max(face_size, 1.0);
				float normal_bias = max(texel_world_size * 2.0, 0.01);
				float bias_val = normal_bias * max(1.0 - dot(normal, light_dir), 0.2);
				vec3 offset_pos = world_pos + normal * bias_val;
				vec3 light_to_surface = offset_pos - light_pos;
				float light_distance = length(light_to_surface);

				if (light_distance <= 0.0001 || light_distance >= far_plane) return 1.0;

				vec3 sample_dir = light_to_surface / light_distance;
				float current_depth = light_distance / max(far_plane, 0.0001);
				float normalized_bias = max(bias_val / max(far_plane, 0.0001), 0.0005);
				return samplePointShadowProjection(shadow_map_idx, sample_dir, current_depth, normalized_bias, 1.25);
			}

			float calculateLocalDirectionalShadow(vec3 world_pos, vec3 normal, vec3 light_dir) {
				int shadow_map_idx = lighting_data.shadows.local_directional_shadow_map_index;
				if (shadow_map_idx < 0) return 1.0;

				vec3 proj_coords;

				if (!projectShadowMap(
					lighting_data.shadows.local_directional_light_space_matrix,
					world_pos,
					normal,
					light_dir,
					lighting_data.shadows.local_directional_shadow_texel_world_size,
					proj_coords
				)) {
					return 1.0;
				}

				return sampleShadowProjection(shadow_map_idx, proj_coords, 1.35);
			}

			vec3 parallax_depth(vec3 R, vec3 ray_origin, float sphere_radius, int depth_tex) {
				const int MAX_STEPS = 8;
				float t_min = 0.0;
				float t_max = sphere_radius * 2.0;

				// Binary search for intersection with actual geometry
				for (int i = 0; i < MAX_STEPS; i++) {
					float t_mid = (t_min + t_max) * 0.5;
					vec3 ray_pos = ray_origin + t_mid * R;
					vec3 ray_dir = normalize(ray_pos);
					float ray_dist = length(ray_pos);

					// Sample linearized depth from cubemap (distance from probe center)
					float stored_depth = textureLod(CUBEMAP(depth_tex), ray_dir, 0).r;

					if (ray_dist < stored_depth) {
						t_min = t_mid;  // Ray is in front of geometry, move forward
					} else {
						t_max = t_mid;  // Ray is behind geometry, move backward
					}
				}

				return normalize(ray_origin + t_max * R);
			}

			vec3 get_environment_reflection(vec3 normal, float roughness, vec3 V, vec3 world_pos) {
				vec3 raw_R = reflect(-V, normal);
				vec3 R = get_specular_dominant_direction(raw_R, normal, roughness);

				vec3 global_env = sample_environment_specular(lighting_data.env_tex, raw_R, normal, roughness);

				vec3 probes_env = vec3(0.0);
				float total_weight = 0.0;

				for (int i = 0; i < 64; i++) {
					int color_tex = lighting_data.probe_color_textures[i];
					int depth_tex = lighting_data.probe_depth_textures[i];
					if (color_tex == -1) continue;

					vec3 probe_pos = lighting_data.probe_positions[i].xyz;
					float sphere_radius = lighting_data.probe_positions[i].w;
					vec3 probe_to_point = world_pos - probe_pos;
					float dist_to_point = length(probe_to_point);

					if (dist_to_point < sphere_radius) {
						vec3 dir_to_point = normalize(probe_to_point);

						// Check visibility and how accurately this probe sees the surface
						float stored_depth = texture(CUBEMAP(depth_tex), dir_to_point).r;
						float depth_diff = abs(stored_depth - dist_to_point);
						float bias = 0.3;

						// Surface must be visible (not behind geometry)
						if (dist_to_point > stored_depth + bias) continue;

						// Weight based on depth match quality - closer match = higher weight
						// Using exponential falloff for smoother blending
						float depth_weight = exp(-depth_diff * 0.5); // Tune the 0.5 multiplier
						
						// Also weight by distance from probe center for smooth edge falloff
						float edge_weight = smoothstep(sphere_radius, sphere_radius * 0.3, dist_to_point);
						
						float weight = depth_weight * edge_weight;

						if (weight > 0.001) {
							vec3 corrected_R = parallax_depth(R, probe_to_point, sphere_radius, depth_tex);
							probes_env += sample_environment_specular(color_tex, corrected_R, corrected_R, roughness) * weight;
							total_weight += weight;
						}
					}
				}

				return blend_environment_sources(global_env, probes_env / max(total_weight, 0.0001), min(total_weight, 1.0));
			}

			vec3 get_environment_irradiance(vec3 normal, vec3 world_pos) {
				vec3 global_env = sample_environment_irradiance(lighting_data.env_tex, normal);

				vec3 probes_env = vec3(0.0);
				float total_weight = 0.0;

				for (int i = 0; i < 64; i++) {
					int color_tex = lighting_data.probe_color_textures[i];
					int depth_tex = lighting_data.probe_depth_textures[i];
					if (color_tex == -1 || depth_tex == -1) continue;

					vec3 probe_pos = lighting_data.probe_positions[i].xyz;
					float sphere_radius = lighting_data.probe_positions[i].w;
					vec3 probe_to_point = world_pos - probe_pos;
					float dist_to_point = length(probe_to_point);

					if (dist_to_point < sphere_radius) {
						vec3 dir_to_point = normalize(probe_to_point);
						float stored_depth = texture(CUBEMAP(depth_tex), dir_to_point).r;
						float bias = 0.3;

						if (dist_to_point > stored_depth + bias) continue;

						float depth_diff = abs(stored_depth - dist_to_point);
						float depth_weight = exp(-depth_diff * 0.5);
						float edge_weight = smoothstep(sphere_radius, sphere_radius * 0.3, dist_to_point);
						float weight = depth_weight * edge_weight;

						if (weight > 0.001) {
							probes_env += sample_environment_irradiance(color_tex, normal) * weight;
							total_weight += weight;
						}
					}
				}

				return blend_environment_sources(global_env, probes_env / max(total_weight, 0.0001), min(total_weight, 1.0));
			}

			vec3 get_reflection(vec3 normal, float roughness, vec3 V, vec3 world_pos) {
				vec3 env = get_environment_reflection(normal, roughness, V, world_pos);
				vec4 ssr = get_filtered_ssr_reflection(lighting_data.ssr_tex, in_uv);
				return combine_reflections(env, ssr, 1.0);
			}

			vec3 get_irradiance(vec3 normal, vec3 V, vec3 world_pos) {
				return get_environment_irradiance(normal, world_pos);
			}

			float get_ambient_occlusion(vec2 uv, vec3 world_pos, vec3 N) {
				float ao_tex = get_ao();

				if (lighting_data.blue_noise_tex == -1) return ao_tex;

				vec3 p = (lighting_data.view * vec4(world_pos, 1.0)).xyz;
				vec3 V = normalize(-p);
				vec3 view_normal = normalize(mat3(lighting_data.view) * N);

				ivec2 screen_size = textureSize(TEXTURE(lighting_data.depth_tex), 0);
				ivec2 pixel = ivec2(uv * vec2(screen_size));
				ivec2 noise_size = textureSize(TEXTURE(lighting_data.blue_noise_tex), 0);
				vec2 noise = texelFetch(TEXTURE(lighting_data.blue_noise_tex), pixel % noise_size, 0).rg;
				
				float random_offset = noise.x;
				float random_rotation = noise.y * 6.28318;

				float world_radius = 2.0;
				// radius_uv = (world_radius * focal_length / -p.z) * 0.5
				float screen_radius = (world_radius * lighting_data.projection[0][0]) / (-p.z * 2.0);

				const int Nd = 4; // Slices
				const int Ns = 12; // Steps per side
				const uint Nb = 32;
				float thickness = 0.025; 
				float bias = 0.2;

				float total_ao = 0.0;
				float total_weight = 0.0;

				for (int i = 0; i < Nd; i++) {
					float angle = (float(i) / float(Nd)) * 3.14159 + random_rotation;
					vec2 dir = vec2(cos(angle), sin(angle));
					
					vec4 dir_v = lighting_data.inv_projection * vec4(dir, 0.0, 0.0);
					vec3 T_v = normalize(dir_v.xyz);
					T_v = normalize(T_v - V * dot(T_v, V));

					vec3 M = cross(V, T_v);
					vec3 n_proj = view_normal - M * dot(view_normal, M);
					float n_proj_len = length(n_proj);
					
					float weight = max(0.0, n_proj_len);
					if (weight < 0.001) continue;
					
					float theta_n = atan(dot(n_proj, T_v), dot(n_proj, V));

					uint bi = 0u;
					for (int j = 0; j < Ns; j++) {
						// Exponential stepping for better local detail
						float o = (float(j) + random_offset) / float(Ns);
						float step_dist = o * o * screen_radius;
						
						for (float side = -1.0; side <= 1.0; side += 2.0) {
							if (side == 0.0) continue;
							vec2 sample_uv = uv + dir * step_dist * side;
							
							if (sample_uv.x < 0.0 || sample_uv.x > 1.0 || sample_uv.y < 0.0 || sample_uv.y > 1.0) continue;

							float sample_depth = texture(TEXTURE(lighting_data.depth_tex), sample_uv).r;
							vec4 sample_clip_pos = vec4(sample_uv * 2.0 - 1.0, sample_depth, 1.0);
							vec4 sample_view_pos = lighting_data.inv_projection * sample_clip_pos;
							vec3 sf = sample_view_pos.xyz / sample_view_pos.w;
							
							vec3 v_f = sf - p;
							float dist2 = dot(v_f, v_f);
							
							if (dist2 > world_radius * world_radius || dist2 < 0.0001) continue;
							
							float proj_T = dot(v_f, T_v);
							float proj_V = dot(v_f, V);
							
							// Skip samples that are too close to the surface or behind it to avoid self-occlusion
							if (proj_V < bias) continue;

							float theta_f = atan(proj_T, proj_V);
							// Thickness model: assume sample has a fixed thickness along the view vector
							float theta_b = atan(proj_T, proj_V - thickness);
							
							float diff_f = theta_f - theta_n;
							if (diff_f > 3.14159) diff_f -= 6.28318;
							if (diff_f < -3.14159) diff_f += 6.28318;
							
							float diff_b = theta_b - theta_n;
							if (diff_b > 3.14159) diff_b -= 6.28318;
							if (diff_b < -3.14159) diff_b += 6.28318;

							float theta_min = clamp(min(diff_f, diff_b), -1.5708, 1.5708);
							float theta_max = clamp(max(diff_f, diff_b), -1.5708, 1.5708);
							
							uint a = uint(floor((theta_min + 1.5708) / 3.14159 * float(Nb)));
							uint b = uint(ceil((theta_max + 1.5708) / 3.14159 * float(Nb)));
							
							a = clamp(a, 0u, Nb);
							b = clamp(b, 0u, Nb);

							if (b > a) {
								uint count = b - a;
								uint mask = (count >= 32u) ? 0xFFFFFFFFu : ((1u << count) - 1u) << a;
								bi |= mask;
							}
						}
					}
					total_ao += (1.0 - float(bitCount(bi)) / float(Nb)) * weight;
					total_weight += weight;
				}

				float ao = (total_weight > 0.001) ? (total_ao / total_weight) : 1.0;
				return pow(clamp(ao, 0.0, 1.0), 1) * ao_tex;
			}

				vec3 get_primary_sun_direction() {
					vec3 sunDir = lighting_data.primary_sun_direction.xyz;
					if (length(sunDir) < 0.0001) {
						sunDir = vec3(0.0, 1.0, 0.0);
					}
					return normalize(sunDir);
				}

			vec3 subsurface_shading_back(vec3 eye_dir, vec3 light_dir, vec3 normal, vec3 transmission_color, float view_dependency)
			{
				float backlit = saturate(dot(-normal, light_dir));
				float eye_dot_light = saturate(dot(eye_dir, -light_dir));
				float eye_dot_light_pow = eye_dot_light * eye_dot_light;
				eye_dot_light_pow *= eye_dot_light_pow;
				float focused_backlit = backlit * backlit;
				float back_wrap = smoothstep(0.45, 0.95, backlit);
				back_wrap *= back_wrap;
				float back_shading = mix(eye_dot_light_pow * focused_backlit, back_wrap, view_dependency);
				return back_shading * transmission_color;
			}

			float get_transmission_blocking_detail(float transmission_blocking)
			{
				return saturate(transmission_blocking + 0.25);
			}

			void subsurface_shading_front(vec3 eye_dir, vec3 light_dir, vec3 normal, vec3 diffuse_color, vec3 specular_color, float gloss_power, out vec3 out_diffuse, out vec3 out_specular)
			{
				float light_dot_normal = saturate(dot(normal, light_dir));
				vec3 reflected_light = reflect(-light_dir, normal);
				float specular = pow(saturate(dot(reflected_light, eye_dir)), gloss_power);
				float wrapped_diffuse = saturate(light_dot_normal * 0.7 + 0.3);
				out_diffuse = wrapped_diffuse * diffuse_color;
				out_specular = specular * specular_color;
			}

			vec3 get_direct_light(vec3 F0, float NdotV, vec3 albedo, float r2, float metallic, float subsurface, float transmission_blocking, vec3 transmission_color, float transmission_view_dependency, vec3 world_pos, vec3 V, vec3 N)
			{
				vec3 Lo = vec3(0.0);
				float subsurface_factor = subsurface;

                for (int i = 0; i < lighting_data.light_count; i++) {
                    lights_t light = lighting_data.lights[i];
					int type = get_light_type(light);
					vec3 L;
					float attenuation = 1.0;
					if (!get_light_vector_and_attenuation(light, world_pos, L, attenuation)) {
						continue;
					}
                    vec3 H = normalize(V + L);
                    float NoL = saturate(dot(N, L));
                    float NoH = saturate(dot(N, H));
                    float LoH = saturate(dot(L, H));

					float D = D_GGX(r2, NoH);
					float V_func = V_SmithGGXCorrelated(r2, NdotV, NoL);
                    vec3 F = F_Schlick(F0, LoH);

                    vec3 Fr = (D * V_func) * F;
                    vec3 kD = vec3(1.0 - metallic);
                    vec3 Fd = kD * albedo * Fd_Lambert();

                    float shadow_factor = 1.0;
					if (
						i == lighting_data.shadows.directional_shadow_light_index &&
						lighting_data.shadows.shadow_map_indices[0] >= 0 &&
						type == 0
					) {
                        shadow_factor = calculateShadow(world_pos, N, L);
					} else if (
						i == lighting_data.shadows.local_directional_shadow_light_index &&
						lighting_data.shadows.local_directional_shadow_map_index >= 0 &&
						type == 2
					) {
						shadow_factor = calculateLocalDirectionalShadow(world_pos, N, L);
					} else if (type == 1) {
						int point_shadow_slot = getPointShadowSlot(i);
						if (point_shadow_slot >= 0) {
							shadow_factor = calculatePointShadow(point_shadow_slot, world_pos, N, L);
						}
                    }
                    vec3 radiance = light.color.rgb * light.color.a * attenuation;
					vec3 transmission = vec3(0.0);
					vec3 subsurface_front = vec3(0.0);
					vec3 subsurface_spec = vec3(0.0);

					if (subsurface > 0.0) {
						float subsurface_gloss = mix(6.0, 24.0, 1.0 - r2);
						float blocking_detail = get_transmission_blocking_detail(transmission_blocking);
						float transmission_amount = 1.0 - blocking_detail;
						float front_amount = blocking_detail;
						vec3 transmission_tint = mix(transmission_color, transmission_color * albedo, blocking_detail);
						vec3 front_diffuse = vec3(0.0);
						vec3 front_specular = vec3(0.0);
						vec3 subsurface_specular_color = mix(vec3(0.01), albedo * 0.035, 0.5);
						subsurface_shading_front(V, L, N, light.color.rgb, subsurface_specular_color, subsurface_gloss, front_diffuse, front_specular);
						transmission = subsurface_shading_back(V, L, N, transmission_tint, transmission_view_dependency) * transmission_amount * radiance * shadow_factor * 1.2;
						subsurface_front = front_diffuse * albedo * radiance * shadow_factor * front_amount;
						subsurface_spec = front_specular * radiance * shadow_factor * 0.35 * front_amount;
					}

					vec3 pbr_light = (Fd + Fr) * radiance * NoL * shadow_factor;
					vec3 subsurface_light = subsurface_front + subsurface_spec + transmission;
					Lo += mix(pbr_light, subsurface_light, subsurface_factor);
                }

				return Lo;				
			}

			vec3 get_indirect_light(vec3 F0, float NdotV, vec3 albedo, float roughness, float metallic, float subsurface, float transmission_blocking, vec3 transmission_color, float transmission_view_dependency, vec3 world_pos, vec3 V, vec3 N)
			{
				float subsurface_factor = subsurface;
				float blocking_detail = get_transmission_blocking_detail(transmission_blocking);
				float transmission_amount = 1.0 - blocking_detail;
				float effective_roughness = roughness;
				vec3 reflection = get_reflection(N, effective_roughness, V, world_pos);
				float ambient_front_amount = blocking_detail;
				vec3 ambient_transmission_tint = mix(vec3(1.0), transmission_color * albedo, blocking_detail);
				float ambient_occlusion = get_ambient_occlusion(in_uv, world_pos, N);

				vec3 irradiance = get_irradiance(N, V, world_pos);
				vec3 back_irradiance = get_irradiance(-N, V, world_pos);
				vec3 F_ambient = F_SchlickRoughness(F0, NdotV, effective_roughness);
				vec3 kD_ambient = (1.0 - F_ambient) * (1.0 - metallic);
				vec3 ambient_diffuse = kD_ambient * irradiance * albedo * ambient_occlusion;
				ambient_diffuse *= mix(1.0, ambient_front_amount, subsurface_factor);
				float hemi = saturate(N.y * 0.5 + 0.5);
				vec3 subsurface_ambient = mix(ambient_diffuse * 0.5, ambient_diffuse, hemi);
				vec3 ambient_subsurface = back_irradiance * ambient_transmission_tint * transmission_amount * ambient_occlusion;
				ambient_subsurface *= mix(0.3, 1.0, transmission_view_dependency);
				subsurface_ambient += ambient_subsurface;

				vec2 envBRDF = envBRDFApprox(NdotV, effective_roughness);
				vec3 ambient_specular = reflection * (F0 * envBRDF.x + envBRDF.y) * ambient_occlusion;
				ambient_specular *= 1.0 - subsurface_factor;

				vec3 ambient = ambient_diffuse + ambient_specular;
				ambient += (subsurface_ambient - ambient_diffuse) * subsurface_factor;
				return ambient;
			}


			]] .. screen_reconstruct.GetWorldPosGLSL("lighting_data") .. [[

			vec3 get_view_normal(vec3 world_pos) {
				return normalize(lighting_data.camera_position.xyz - world_pos);
			}

			void main() {
				float depth = get_depth();

				if (depth == 1.0) {
					set_color(vec4(0.0, 0.0, 0.0, 1.0));
					return;
				}

				float alpha = get_alpha();
				if (alpha == 0.0) discard;


				vec3 N = get_normal();
				vec3 world_pos = get_world_pos(depth);
				vec3 V = get_view_normal(world_pos);


				vec3 albedo = get_albedo();
				float metallic = get_metallic();
				float roughness = get_roughness();
				float subsurface = get_subsurface();
				float transmission_blocking = get_transmission_blocking();
				vec3 transmission_color = get_transmission_color();
				float transmission_view_dependency = get_transmission_view_dependency();
				vec3 emissive = subsurface > 0.0 ? vec3(0.0) : get_emissive();
				vec3 F0 = mix(vec3(0.04), albedo, metallic);
				float NdotV = max(dot(N, V), 0.001);
				float ambient_occlusion = get_ambient_occlusion(in_uv, world_pos, N);
				vec3 irradiance = get_irradiance(N, V, world_pos);
				vec3 direct = get_direct_light(F0, NdotV, albedo, roughness, metallic, subsurface, transmission_blocking, transmission_color, transmission_view_dependency, world_pos, V, N);
				vec3 indirect = get_indirect_light(F0, NdotV, albedo, roughness, metallic, subsurface, transmission_blocking, transmission_color, transmission_view_dependency, world_pos, V, N);
				vec3 color = direct + indirect + emissive;
				vec3 sunDir = get_primary_sun_direction();
				float atmosphere_sun_visibility = 1.0;

				if (
					lighting_data.light_count > 0 &&
					lighting_data.shadows.shadow_map_indices[0] >= 0 &&
					lighting_data.shadows.directional_shadow_light_index >= 0
				) {
					atmosphere_sun_visibility = calculateShadow(world_pos, N, sunDir);
				}

				color = apply_atmospheric_aerial_perspective(
					color,
					world_pos,
					sunDir,
					lighting_data.camera_position.xyz,
					lighting_data.atmosphere_transmittance_texture_index,
					atmosphere_sun_visibility
				);

				if (lighting_data.debug_cascade_colors != 0) {
					int cascade_idx = getCascadeIndex(world_pos);
					color = mix(color, CASCADE_COLORS[cascade_idx], 0.4);
				}

				]] .. render3d.debug_mode_glsl .. [[

				set_color(vec4(color, alpha));
			}
		]],
		},
		CullMode = "none",
		DepthTest = false,
		DepthWrite = false,
	},
}
