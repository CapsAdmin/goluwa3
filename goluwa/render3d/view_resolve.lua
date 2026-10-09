local EasyPipeline = import("goluwa/render/easy_pipeline.lua")
local compute_helpers = import("goluwa/render3d/compute_helpers.lua")
local render3d = import("goluwa/render3d/render3d.lua")
import("goluwa/render3d/passes/blit.lua")
local view_resolve = library()
local pipeline
local source_texture
local source_ratio
local source_exposure

local function get_pipeline()
	if pipeline then return pipeline end

	pipeline = EasyPipeline.New{
		name = "view_resolve",
		dont_create_framebuffers = true,
		ColorFormat = {{"r8g8b8a8_srgb", {"color", "rgba"}}},
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
					name = "view_resolve_data",
					block = {
						{"source_tex", "int"},
						{"ratio", "int"},
						{"exposure", "float"},
						{"tonemapper", "int"},
					},
					write = function(self, block)
						block.source_tex = self:GetTextureIndex(source_texture)
						block.ratio = source_ratio
						block.exposure = source_exposure
						block.tonemapper = render3d.GetTonemapperIndex()
						return block
					end,
				},
			},
			custom_declarations = compute_helpers.GetColorHelpersGLSL(),
			shader = [[
				void main() {
					ivec2 base = ivec2(gl_FragCoord.xy) * view_resolve_data.ratio;
					vec4 sum = vec4(0.0);

					for (int y = 0; y < view_resolve_data.ratio; y++) {
						for (int x = 0; x < view_resolve_data.ratio; x++) {
							vec4 scene = texelFetch(TEXTURE(view_resolve_data.source_tex), base + ivec2(x, y), 0);
							vec3 color = clamp(tonemap(scene.rgb * view_resolve_data.exposure, view_resolve_data.tonemapper), 0.0, 1.0);
							sum += vec4(color * scene.a, scene.a);
						}
					}

					sum /= float(view_resolve_data.ratio * view_resolve_data.ratio);
					set_color(sum.a > 0.0 ? vec4(sum.rgb / sum.a, sum.a) : vec4(0.0));
				}
			]],
		},
	}
	return pipeline
end

-- exposes the scene color of an offscreen view, tonemaps it and averages ratio x ratio samples into
-- each pixel of framebuffer. alpha stays straight, the sky of a transparent view being 0
function view_resolve.Draw(cmd, framebuffer, texture, ratio, exposure)
	source_texture = texture
	source_ratio = ratio
	source_exposure = exposure
	get_pipeline():Draw(cmd, framebuffer)
	source_texture = nil
end

return view_resolve
