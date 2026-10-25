local render = import("goluwa/render/render.lua")
local EasyPipeline = import("goluwa/render/easy_pipeline.lua")
local pvars = import("goluwa/cli/pvars.lua")
local glsl_common = import("goluwa/render3d/glsl_common.lua")
local hdr_output = {}
pvars.StartGroup("Engine", "HDR", {prefix = "hdr_"})
local ui_white = pvars.Setup2{
	key = "r_hdr_ui_white",
	default = 200,
	min = 0,
	help = "nits the UI is shown at in HDR output, 0 is the brightest the display can show (r_hdr_peak)",
}
pvars.EndGroup()

function hdr_output.GetWhiteNits()
	local nits = ui_white:Get()

	if nits == 0 then return pvars.Get("r_hdr_peak") or 1000 end

	return nits
end

do
	local pipeline
	local pipeline_format
	local source_texture
	local output_pq

	local function get_pipeline(format)
		if pipeline_format == format then return pipeline end

		pipeline_format = format
		pipeline = EasyPipeline.New{
			name = "hdr_output",
			dont_create_framebuffers = true,
			ColorFormat = {{format, {"color", "rgba"}}},
			DepthFormat = false,
			RasterizationSamples = "1",
			Blend = false,
			CullMode = "none",
			DepthTest = false,
			DepthWrite = false,
			on_pre_draw = function(self)
				self:GetTextureIndex(source_texture)
			end,
			fragment = {
				push_constants = {
					{
						name = "hdr_output_data",
						block = {
							{"source_tex", "int"},
							{"white_nits", "float"},
							{"pq", "int"},
						},
						write = function(self, block)
							block.source_tex = self:GetTextureIndex(source_texture)
							block.white_nits = hdr_output.GetWhiteNits()
							block.pq = output_pq and 1 or 0
							return block
						end,
					},
				},
				custom_declarations = glsl_common.GetPQGLSL(),
				shader = [[
					void main() {
						vec3 encoded = texelFetch(TEXTURE(hdr_output_data.source_tex), ivec2(gl_FragCoord.xy), 0).rgb;
						vec3 low = encoded / 12.92;
						vec3 high = pow(max((encoded + 0.055) / 1.055, vec3(0.0)), vec3(2.4));
						vec3 nits = mix(low, high, step(0.04045, encoded)) * hdr_output_data.white_nits;

						if (hdr_output_data.pq != 0) {
							const mat3 bt709_to_bt2020 = mat3(
								0.6274, 0.0691, 0.0164,
								0.3293, 0.9195, 0.0880,
								0.0433, 0.0114, 0.8956
							);
							set_color(vec4(pq_encode(bt709_to_bt2020 * nits), 1.0));
						} else {
							set_color(vec4(nits / 80.0, 1.0));
						}
					}
				]],
			},
		}
		return pipeline
	end

	function hdr_output.Resolve(cmd, layer, target, color_space)
		source_texture = layer
		output_pq = color_space == "hdr10_st2084_ext"
		render.TransitionResourceToShaderRead(layer, {cmd = cmd})
		render.TransitionResourceTo(
			target,
			"color_attachment_optimal",
			{
				cmd = cmd,
				srcStage = "color_attachment_output",
				srcAccess = "none",
				dstStage = "color_attachment_output",
				dstAccess = "color_attachment_write",
			}
		)
		cmd:BeginRendering{
			color_image_view = target:GetView(),
			w = target:GetWidth(),
			h = target:GetHeight(),
			load_op = "dont_care",
		}
		get_pipeline(target.format):Draw(cmd)
		cmd:EndRendering()
		source_texture = nil
	end
end

return hdr_output
