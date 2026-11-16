local render3d = import("goluwa/render3d/render3d.lua")
local post_source = import("goluwa/render3d/post_source.lua")
local pvars = import("goluwa/cli/pvars.lua")
local rcas = {}
pvars.StartGroup("Post", "Anti-aliasing", {store = false})
local sharpness = pvars.Setup2{
	key = "r_sharpen",
	default = 0.75,
	help = "the strength of the robust contrast adaptive sharpening (fsr's rcas) run after taa or the spatial upscaler, which wins back what upscaling and the history resampling blur. 1 is the most rcas allows, 0 is off",
}
pvars.EndGroup()

function rcas.IsEnabled()
	return sharpness:Get() > 0
end

function rcas.BuildPass(options)
	local is_enabled = options.is_enabled
	local get_source_texture = options.get_source_texture
	return {
		name = options.name,
		is_enabled = function()
			return sharpness:Get() > 0 and is_enabled()
		end,
		ColorFormat = {{"r16g16b16a16_sfloat", {"color", "rgba"}}},
		fragment = {
			uniform_buffers = {
				{
					name = "rcas_data",
					binding_index = 2,
					block = {
						{"source_tex", "int"},
						{"sharpness", "float"},
						post_source.pre_exposure_block,
					},
					write = function(self, block)
						block.source_tex = self:GetTextureIndex(get_source_texture())
						block.sharpness = sharpness:Get()
						post_source.WritePreExposureBlock(self, block)
						return block
					end,
				},
			},
			shader = post_source.GetPreExposureGLSL("rcas_data") .. [[
			float get_compress_exposure(int pre_exposure_tex) {
				return pre_exposure_tex != -1 ? ]] .. string.format("%.1f", post_source.PRE_EXPOSURE_HEADROOM) .. [[ : 1.0;
			}

			const float RCAS_LIMIT = 0.25 - 1.0 / 16.0;

			ivec2 size;
			float exposure;

			vec3 load(ivec2 p) {
				vec3 c = max(texelFetch(TEXTURE(rcas_data.source_tex), clamp(p, ivec2(0), size - 1), 0).rgb * exposure, vec3(0.0));
				return c / (max(c.r, max(c.g, c.b)) + 1.0);
			}

			void main() {
				size = textureSize(TEXTURE(rcas_data.source_tex), 0);
				exposure = get_compress_exposure(rcas_data.pre_exposure_tex);
				ivec2 pixel = ivec2(gl_FragCoord.xy);
				vec4 center = texelFetch(TEXTURE(rcas_data.source_tex), pixel, 0);
				vec3 b = load(pixel + ivec2(0, -1));
				vec3 d = load(pixel + ivec2(-1, 0));
				vec3 e = load(pixel);
				vec3 f = load(pixel + ivec2(1, 0));
				vec3 h = load(pixel + ivec2(0, 1));
				float b_l = b.b * 0.5 + (b.r * 0.5 + b.g);
				float d_l = d.b * 0.5 + (d.r * 0.5 + d.g);
				float e_l = e.b * 0.5 + (e.r * 0.5 + e.g);
				float f_l = f.b * 0.5 + (f.r * 0.5 + f.g);
				float h_l = h.b * 0.5 + (h.r * 0.5 + h.g);
				float noise = 0.25 * (b_l + d_l + f_l + h_l) - e_l;
				float luma_range = max(max(max(b_l, d_l), max(e_l, f_l)), h_l) - min(min(min(b_l, d_l), min(e_l, f_l)), h_l);
				noise = -0.5 * clamp(abs(noise) / max(luma_range, 1e-6), 0.0, 1.0) + 1.0;
				vec3 min4 = min(min(b, d), min(f, h));
				vec3 max4 = max(max(b, d), max(f, h));
				float lower_limiter = clamp(e_l / max(min(min(b_l, d_l), min(f_l, h_l)), 1e-6), 0.0, 1.0);
				vec3 hit_min = min4 / max(4.0 * max4, vec3(1e-6)) * lower_limiter;
				vec3 hit_max = (1.0 - max4) / min(4.0 * min4 - 4.0, vec3(-1e-6));
				vec3 lobe_rgb = max(-hit_min, hit_max);
				float lobe = max(-RCAS_LIMIT, min(max(lobe_rgb.r, max(lobe_rgb.g, lobe_rgb.b)), 0.0)) * rcas_data.sharpness * noise;
				vec3 sharpened = (lobe * (b + d + f + h) + e) / (4.0 * lobe + 1.0);
				set_color(vec4(sharpened / max(1.0 - max(sharpened.r, max(sharpened.g, sharpened.b)), 1e-6) / exposure, center.a));
			}
		]],
		},
		CullMode = "none",
		DepthTest = false,
		DepthWrite = false,
	}
end

return rcas
