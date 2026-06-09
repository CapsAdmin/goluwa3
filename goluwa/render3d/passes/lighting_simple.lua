local render3d = import("goluwa/render3d/render3d.lua")
local directional_shadows = import("goluwa/render3d/directional_shadows.lua")
local screen_reconstruct = import("goluwa/render3d/screen_reconstruct.lua")

local function get_primary_sun(lights)
	lights = lights or render3d.GetLights()

	for i, light in ipairs(lights) do
		if light.LightType == "sun" then return light end
	end

	return nil
end

return {
	{
		-- Keep the pipeline name identical so this file can replace lighting.lua by
		-- swapping the import in render3d.lua without touching downstream passes.
		name = "lighting",
		ColorFormat = {{"r16g16b16a16_sfloat", {"color", "rgba"}}},
		framebuffer_count = 2,
		fragment = {
			uniform_buffers = {
				{
					name = "lighting_simple",
					binding_index = 3,
					block = {
						render3d.camera_block,
						render3d.gbuffer_block,
						{"shadows", directional_shadows.BuildFogShadowBlockLayout()},
						{"debug_mode", "int"},
						{"sun_direction", "vec4"},
						{"sun_color", "vec4"},
					},
					write = function(self, block)
						render3d.WriteCameraBlock(self, block)
						render3d.WriteGBufferBlock(self, block)
						directional_shadows.WriteFogShadowBlock(self, block.shadows, render3d.GetLights())
						local sun = get_primary_sun(render3d.GetLights())
						local sun_direction = sun and sun.Owner.transform:GetRotation():GetForward()
						local sun_color = sun and sun.Color
						block.sun_direction[0] = sun_direction and sun_direction.x or 0
						block.sun_direction[1] = sun_direction and sun_direction.y or 1
						block.sun_direction[2] = sun_direction and sun_direction.z or 0
						block.sun_direction[3] = 0
						block.sun_color[0] = sun_color and sun_color.x or 1
						block.sun_color[1] = sun_color and sun_color.y or 1
						block.sun_color[2] = sun_color and sun_color.z or 1
						block.sun_color[3] = sun and sun.Intensity or 1
						return block
					end,
				},
			},
			shader = screen_reconstruct.GetWorldPosGLSL("lighting_simple") .. [[
				vec3 get_albedo() {
					return texture(TEXTURE(lighting_simple.albedo_tex), in_uv).rgb;
				}

				float get_alpha() {
					return texture(TEXTURE(lighting_simple.albedo_tex), in_uv).a;
				}

				float get_depth() {
					return texture(TEXTURE(lighting_simple.depth_tex), in_uv).r;
				}

				vec3 get_normal() {
					return texture(TEXTURE(lighting_simple.normal_tex), in_uv).xyz;
				}

				float get_metallic() {
					return texture(TEXTURE(lighting_simple.mra_tex), in_uv).r;
				}

				float get_roughness() {
					return texture(TEXTURE(lighting_simple.mra_tex), in_uv).g;
				}

				float get_ao() {
					return texture(TEXTURE(lighting_simple.mra_tex), in_uv).b;
				}

				vec3 get_emissive() {
					return texture(TEXTURE(lighting_simple.emissive_tex), in_uv).rgb;
				}

				vec3 safe_normalize(vec3 value, vec3 fallback_value) {
					float len2 = dot(value, value);
					if (len2 <= 0.0001) return fallback_value;
					return value * inversesqrt(len2);
				}

				int get_shadow_cascade_index(vec3 world_pos) {
					float dist = -(lighting_simple.view * vec4(world_pos, 1.0)).z;

					for (int i = 0; i < lighting_simple.shadows.cascade_count; i++) {
						if (dist < lighting_simple.shadows.cascade_splits[i]) {
							return i;
						}
					}

					return lighting_simple.shadows.cascade_count - 1;
				}

				bool project_shadow_map(
					mat4 light_space_matrix,
					vec3 world_pos,
					vec3 normal,
					vec3 light_dir,
					float texel_world_size,
					out vec3 proj_coords
				) {
					float normal_bias = max(texel_world_size * 1.5, 0.0005);
					float bias_val = normal_bias * max(1.0 - dot(normal, light_dir), 0.15);
					vec3 offset_pos = world_pos + normal * bias_val;
					vec4 light_space_pos = light_space_matrix * vec4(offset_pos, 1.0);
					proj_coords = light_space_pos.xyz / light_space_pos.w;
					proj_coords.xy = proj_coords.xy * 0.5 + 0.5;
					return !(
						proj_coords.z > 1.0 ||
						proj_coords.z < 0.0 ||
						proj_coords.x < 0.0 ||
						proj_coords.x > 1.0 ||
						proj_coords.y < 0.0 ||
						proj_coords.y > 1.0
					);
				}

				float sample_simple_shadow(int shadow_map_idx, vec3 proj_coords, float bias) {
					float shadow_depth = texture(TEXTURE(shadow_map_idx), proj_coords.xy).r;
					return proj_coords.z - bias > shadow_depth ? 0.0 : 1.0;
				}

				float calculate_simple_shadow(vec3 world_pos, vec3 normal, vec3 light_dir) {
					if (lighting_simple.shadows.cascade_count <= 0) return 1.0;

					float dist = -(lighting_simple.view * vec4(world_pos, 1.0)).z;
					vec3 proj_coords;

					if (
						lighting_simple.shadows.inset_shadow_map_index >= 0 &&
						dist < lighting_simple.shadows.inset_shadow_distance &&
						project_shadow_map(
							lighting_simple.shadows.inset_light_space_matrix,
							world_pos,
							normal,
							light_dir,
							lighting_simple.shadows.inset_shadow_texel_world_size,
							proj_coords
						)
					) {
						return sample_simple_shadow(lighting_simple.shadows.inset_shadow_map_index, proj_coords, 0.0005);
					}

					int cascade_idx = get_shadow_cascade_index(world_pos);
					if (cascade_idx < 0) return 1.0;

					int shadow_map_idx = lighting_simple.shadows.shadow_map_indices[cascade_idx];
					if (shadow_map_idx < 0) return 1.0;

					if (!project_shadow_map(
						lighting_simple.shadows.light_space_matrices[cascade_idx],
						world_pos,
						normal,
						light_dir,
						lighting_simple.shadows.cascade_texel_world_sizes[cascade_idx],
						proj_coords
					)) {
						return 1.0;
					}

					return sample_simple_shadow(shadow_map_idx, proj_coords, 0.0005);
				}

				void main() {
					float alpha = get_alpha();
					float depth = get_depth();
					vec3 albedo = get_albedo();
					vec3 emissive = get_emissive();

					if (depth >= 0.99999) {
						set_color(vec4(emissive, alpha));
						return;
					}

					vec3 N = safe_normalize(get_normal(), vec3(0.0, 0.0, 1.0));
					vec3 world_pos = get_world_pos(depth);
					vec3 L = safe_normalize(-lighting_simple.sun_direction.xyz, vec3(0.0, -1.0, 0.0));
					vec3 sun_color = lighting_simple.sun_color.rgb;
					float sun_intensity = lighting_simple.sun_color.a;
					float ao = get_ao();
					float roughness = get_roughness();
					float metallic = get_metallic();
					float NdotL = max(dot(N, L), 0.0);
					float shadow = NdotL > 0.0 ? calculate_simple_shadow(world_pos, N, L) : 1.0;

					vec3 ambient = albedo * (0.08 + ao * 0.22);
					float diffuse_strength = mix(1.0, 0.75, metallic);
					float roughness_softening = mix(1.0, 0.6, roughness);
					vec3 direct = albedo * sun_color * (sun_intensity * NdotL * diffuse_strength * roughness_softening * shadow);
					vec3 color = ambient + direct + emissive;

					set_color(vec4(color, alpha));
				}
			]],
		},
		CullMode = "none",
		DepthTest = false,
		DepthWrite = false,
	},
}
