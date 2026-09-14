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
					return texture(TEXTURE(lighting_simple.normal_tex), in_uv).xyz * 2.0 - 1.0;
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

		]] .. directional_shadows.GetSurfaceDirectionalShadowGLSL("lighting_simple", "calculateShadow", {use_receiver_plane_bias = false}) .. [[

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
					float roughness = get_roughness();
					float metallic = get_metallic();
					float NdotL = max(dot(N, L), 0.0);
					float shadow = calculateShadow(world_pos, N, L);

					vec3 ambient = albedo * (shadow+0.1);
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
