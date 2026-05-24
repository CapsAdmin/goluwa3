local system = import("goluwa/system.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local atmosphere = import("goluwa/render3d/atmosphere.lua")
local directional_shadows = import("goluwa/render3d/directional_shadows.lua")
local get_primary_sun_direction = directional_shadows.GetPrimarySunDirection
local get_primary_sun_intensity = directional_shadows.GetPrimarySunIntensity

return {
	{
		name = "atmosphere",
		ColorFormat = {{"r16g16b16a16_sfloat", {"color", "rgba"}}},
		framebuffer_count = 2,
		fragment = {
			uniform_buffers = {
				{
					name = "atmosphere_data",
					binding_index = 3,
					block = {
						render3d.camera_block,
						{"source_tex", "int"},
						{"depth_tex", "int"},
						{"stars_texture_index", "int"},
						{"atmosphere_transmittance_texture_index", "int"},
						{"atmosphere_sky_view_texture_index", "int"},
						{"primary_sun_direction", "vec4"},
						{"primary_sun_intensity", "float"},
					},
					write = function(self, block)
						render3d.WriteCameraBlock(self, block)

						if not render3d.pipelines.lighting or not render3d.pipelines.lighting.framebuffers then
							block.source_tex = -1
						else
							local current_idx = system.GetFrameNumber() % 2 + 1
							block.source_tex = self:GetTextureIndex(render3d.pipelines.lighting:GetFramebuffer(current_idx):GetAttachment(1))
						end

						block.depth_tex = self:GetTextureIndex(render3d.pipelines.gbuffer:GetFramebuffer():GetDepthTexture())
						block.stars_texture_index = self:GetTextureIndex(atmosphere.GetStarsTexture())
						block.atmosphere_transmittance_texture_index = self:GetTextureIndex(atmosphere.GetTransmittanceTexture())
						block.atmosphere_sky_view_texture_index = self:GetTextureIndex(
							atmosphere.GetSkyViewTexture(render3d.GetCamera():GetPosition(), get_primary_sun_direction(render3d.GetLights()))
						)
						get_primary_sun_direction(render3d.GetLights()):CopyToFloatPointer(block.primary_sun_direction)
						block.primary_sun_intensity = get_primary_sun_intensity(render3d.GetLights())
						return block
					end,
				},
			},
			shader = [[
				#define ATMOSPHERE_SUN_INTENSITY atmosphere_data.primary_sun_intensity

				]] .. atmosphere.GetGLSLCode() .. [[

				float get_depth() {
					return texture(TEXTURE(atmosphere_data.depth_tex), in_uv).r;
				}

				vec3 get_primary_sun_direction() {
					vec3 sun_dir = atmosphere_data.primary_sun_direction.xyz;
					if (length(sun_dir) < 0.0001) {
						sun_dir = vec3(0.0, 1.0, 0.0);
					}
					return normalize(sun_dir);
				}

				vec3 get_sky() {
					vec4 clip_pos = vec4(in_uv * 2.0 - 1.0, 1.0, 1.0);
					vec4 view_pos = atmosphere_data.inv_projection * clip_pos;
					view_pos /= view_pos.w;
					vec3 world_pos = (atmosphere_data.inv_view * view_pos).xyz;
					vec3 sky_dir = normalize(world_pos - atmosphere_data.camera_position.xyz);
					vec3 sun_dir = get_primary_sun_direction();
					vec3 sky_color_output = vec3(0.0);

					]] .. atmosphere.GetGLSLMainCode(
						"sky_dir",
						"sun_dir",
						"atmosphere_data.camera_position.xyz",
						"atmosphere_data.stars_texture_index",
						"atmosphere_data.atmosphere_sky_view_texture_index",
						"atmosphere_data.atmosphere_transmittance_texture_index"
					) .. [[

					return clamp(sky_color_output, vec3(0.0), vec3(65504.0));
				}

				void main() {
					vec4 scene = atmosphere_data.source_tex == -1 ? vec4(0.0, 0.0, 0.0, 1.0) : texture(TEXTURE(atmosphere_data.source_tex), in_uv);

					if (get_depth() != 1.0) {
						set_color(scene);
						return;
					}

					set_color(vec4(get_sky(), 1.0));
				}
			]],
		},
		CullMode = "none",
		DepthTest = false,
		DepthWrite = false,
	},
}