local system = import("goluwa/system.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local post_source = import("goluwa/render3d/post_source.lua")

local function get_scene_source_texture(self, block, key)
	post_source.WriteSceneSourceTexture(self, block, key)
end

return {
	name = "luminance",
	ColorFormat = {{"r16_sfloat", {"luma", "r"}}},
	scale = 0.0625,
	framebuffer_count = 2,
	fragment = {
		push_constants = {
			{
				name = "lum",
				block = {
					{"source_tex", "int"},
					{"prev_luma_tex", "int"},
				},
				write = function(self, block)
					get_scene_source_texture(self, block, "source_tex")

					if not render3d.pipelines.luminance or not render3d.pipelines.luminance.framebuffers then
						block.prev_luma_tex = -1
						return block
					end

					local prev_idx = (system.GetFrameNumber() + 1) % 2 + 1
					local prev_fb = render3d.pipelines.luminance:GetFramebuffer(prev_idx)

					if not prev_fb.initialized then
						block.prev_luma_tex = -1
						return block
					end

					block.prev_luma_tex = self:GetTextureIndex(prev_fb:GetAttachment(1))
					return block
				end,
			},
		},
		shader = [[
			void main() {
				float luma;
				if (lum.source_tex == -1) {
					luma = 0.5;
					set_luma(luma);
					return;
				}

				vec3 col = texture(TEXTURE(lum.source_tex), in_uv).rgb;
				float current_luma = dot(col, vec3(0.2126, 0.7152, 0.0722));
				current_luma = log2(max(current_luma, 0.0001));

				if (lum.prev_luma_tex != -1) {
					float prev_luma = texture(TEXTURE(lum.prev_luma_tex), in_uv).r;
					float adapt_speed = 0.001;
					current_luma = mix(prev_luma, current_luma, adapt_speed);
				}

				set_luma(current_luma);
			}
		]],
	},
	CullMode = "none",
	DepthTest = false,
	DepthWrite = false,
}
