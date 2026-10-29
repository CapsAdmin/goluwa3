local render3d = import("goluwa/render3d/render3d.lua")
local post_source = import("goluwa/render3d/post_source.lua")
local gbuffer_layout = import("goluwa/render3d/gbuffer_layout.lua")
local translucent_extras = import("goluwa/render3d/translucent_extras.lua")
local passes = {
	{
		name = "effects_post_layer",
		lazy_framebuffers = true,
		is_enabled = translucent_extras.IsPostActive,
		ColorFormat = {{"r16g16b16a16_sfloat", {"color", "rgba"}}},
		DepthFormat = gbuffer_layout.DEPTH_FORMAT,
		ReadOnlyDepth = gbuffer_layout.GetDepthTexture,
		ClearColors = {{0, 0, 0, 0}},
		on_draw = function(self, cmd)
			translucent_extras.DrawPost(cmd)
		end,
		fragment = {shader = "void main() { set_color(vec4(0.0)); }"},
		CullMode = "none",
		DepthTest = false,
		DepthWrite = false,
	},
}

for _, extra in ipairs(translucent_extras.post_list) do
	for _, pass in ipairs(extra.BuildPostPasses()) do
		table.insert(passes, pass)
	end
end

table.insert(
	passes,
	{
		name = "effects_post",
		lazy_framebuffers = true,
		is_enabled = translucent_extras.IsPostActive,
		ColorFormat = {{"r16g16b16a16_sfloat", {"color", "rgba"}}},
		fragment = {
			uniform_buffers = {
				{
					name = "effects_post_data",
					binding_index = 2,
					block = {
						{"source_tex", "int"},
						{"layer_tex", "int"},
					},
					write = function(self, block)
						block.source_tex = self:GetTextureIndex(post_source.GetAntiAliasedSceneTexture())
						block.layer_tex = self:GetTextureIndex(post_source.GetEffectLayerTexture())
						return block
					end,
				},
			},
			shader = [[
				void main() {
					ivec2 pixel = ivec2(gl_FragCoord.xy);
					vec4 scene = texelFetch(TEXTURE(effects_post_data.source_tex), pixel, 0);
					vec4 layer = texelFetch(TEXTURE(effects_post_data.layer_tex), pixel, 0);
					set_color(vec4(scene.rgb * (1.0 - min(layer.a, 1.0)) + layer.rgb, scene.a));
				}
			]],
		},
		CullMode = "none",
		DepthTest = false,
		DepthWrite = false,
	}
)
return passes
