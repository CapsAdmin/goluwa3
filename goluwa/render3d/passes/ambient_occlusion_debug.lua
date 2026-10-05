local render3d = import("goluwa/render3d/render3d.lua")
local ambient_occlusion = import("goluwa/render3d/ambient_occlusion.lua")
local post_source = import("goluwa/render3d/post_source.lua")
local directional_shadows = import("goluwa/render3d/directional_shadows.lua")
return {
	{
		name = "ambient_occlusion_debug",
		is_enabled = function()
			return ambient_occlusion.GetDebugView() ~= 0 and
				render3d.IsPassEnabled("ambient_occlusion")
		end,
		ColorFormat = {{"r16g16b16a16_sfloat", {"color", "rgba"}}},
		fragment = {
			uniform_buffers = {
				{
					name = "debug_data",
					binding_index = 2,
					block = {
						{"ao_tex", "int"},
						{"bent_tex", "int"},
						{"view", "int"},
						{"primary_sun_illuminance", "float"},
						post_source.pre_exposure_block,
					},
					write = function(self, block)
						local framebuffer = render3d.pipelines.ambient_occlusion_blur:GetFramebuffer(1)
						block.ao_tex = self:GetTextureIndex(framebuffer:GetAttachment(1))
						block.bent_tex = self:GetTextureIndex(framebuffer:GetAttachment(2))
						block.view = ambient_occlusion.GetDebugView()
						block.primary_sun_illuminance = directional_shadows.GetPrimarySunIlluminance(render3d.GetLights())
						post_source.WritePreExposureBlock(self, block)
						return block
					end,
				},
			},
			shader = post_source.GetPreExposureGLSL("debug_data") .. [[
			void main() {
				ivec2 pixel = ivec2(gl_FragCoord.xy);
				vec4 bounce_ao = texelFetch(TEXTURE(debug_data.ao_tex), pixel, 0);
				// a surface lit by a thirtieth of the sun's illuminance reads as a light grey
				float white = 0.03 * debug_data.primary_sun_illuminance * get_pre_exposure();
				vec3 shown;

				if (debug_data.view == ]] .. ambient_occlusion.DEBUG_AO .. [[) {
					shown = vec3(bounce_ao.a * white);
				} else if (debug_data.view == ]] .. ambient_occlusion.DEBUG_BOUNCE .. [[) {
					shown = bounce_ao.rgb;
				} else {
					vec3 bent = texelFetch(TEXTURE(debug_data.bent_tex), pixel, 0).xyz;
					shown = (length(bent) > 0.01 ? normalize(bent) * 0.5 + 0.5 : vec3(0.0)) * white;
				}

				set_color(vec4(shown, 1.0));
			}
		]],
		},
		CullMode = "none",
		DepthTest = false,
		DepthWrite = false,
	},
}
