local event = import("goluwa/event.lua")
local render = import("goluwa/render/render.lua")
local orientation = import("goluwa/render3d/orientation.lua")
local Material = import("goluwa/render3d/material.lua")
local render3d = import("goluwa/render3d/render3d.lua")
return {
	{
		name = "forward_overlay",
		draw_in_prerender = false,
		post_draw = function(self, cmd)
			self:Draw(cmd)
		end,
		on_draw = function()
			event.Call("Draw3DForwardOverlay")
		end,
		RasterizationSamples = function()
			return render.target.samples
		end,
		vertex = {
			binding_index = 0,
			attributes = {
				{"position", "vec3", "r32g32b32_sfloat"},
				{"normal", "vec3", "r32g32b32_sfloat"},
				{"uv", "vec2", "r32g32_sfloat"},
				{"tangent", "vec4", "r32g32b32a32_sfloat"},
				{"texture_blend", "float", "r32_sfloat"},
			},
			push_constants = {
				{
					name = "vertex",
					block = {
						{
							"projection_view_world",
							"mat4",
							function(self, block, key)
								render3d.GetProjectionViewWorldMatrix():CopyToFloatPointer(block[key])
							end,
						},
						{
							"world",
							"mat4",
							function(self, block, key)
								render3d.GetWorldMatrix():CopyToFloatPointer(block[key])
							end,
						},
					},
				},
			},
			shader = [[
			void main() {
				gl_Position = vertex.projection_view_world * vec4(in_position, 1.0);
				out_position = (vertex.world * vec4(in_position, 1.0)).xyz;
				out_uv = in_uv;
				out_texture_blend = in_texture_blend;
			}
		]],
		},
		fragment = {
			uniform_buffers = {
				{
					name = "clip_plane",
					block = {
						{
							"Enabled",
							"int",
							function(self, block, key)
								block[key] = render3d.IsForwardOverlayClipPlaneEnabled() and 1 or 0
							end,
						},
						{
							"Origin",
							"vec3",
							function(self, block, key)
								render3d.GetForwardOverlayClipPlaneOrigin():CopyToFloatPointer(block[key])
							end,
						},
						{
							"Normal",
							"vec3",
							function(self, block, key)
								render3d.GetForwardOverlayClipPlaneNormal():CopyToFloatPointer(block[key])
							end,
						},
					},
				},
				{
					name = "model",
					block = {
						{
							"Flags",
							"int",
							function(self, block, key)
								block[key] = render3d.GetMaterial():GetFillFlags()
							end,
						},
						{
							"AlbedoTexture",
							"int",
							function(self, block, key)
								block[key] = render3d.pipelines.forward_overlay:GetTextureIndex(render3d.GetMaterial():GetAlbedoTexture())
							end,
						},
						{
							"ColorMultiplier",
							"vec4",
							function(self, block, key)
								render3d.GetMaterial():GetColorMultiplier():CopyToFloatPointer(block[key])
							end,
						},
						{
							"EmissiveMultiplier",
							"vec4",
							function(self, block, key)
								render3d.GetMaterial():GetEmissiveMultiplier():CopyToFloatPointer(block[key])
							end,
						},
						{
							"AlphaCutoff",
							"float",
							function(self, block, key)
								block[key] = render3d.GetMaterial():GetAlphaCutoff()
							end,
						},
					},
				},
			},
			shader = [[
			]] .. Material.BuildGlslFlags("model.Flags") .. [[

			layout(location = 0) out vec4 frag_color;

			vec4 get_color() {
				vec4 color = model.ColorMultiplier;

				if (model.AlbedoTexture != -1) {
					color *= texture(TEXTURE(model.AlbedoTexture), in_uv);
				}

				return color;
			}

			void main() {
				if (clip_plane.Enabled != 0 && dot(in_position - clip_plane.Origin, clip_plane.Normal) < 0.0) discard;

				vec4 color = get_color();

				if (AlphaTest && color.a < model.AlphaCutoff) discard;

				frag_color = vec4(color.rgb + model.EmissiveMultiplier.rgb * model.EmissiveMultiplier.a, color.a);
			}
		]],
		},
		CullMode = orientation.CULL_MODE,
		FrontFace = orientation.FRONT_FACE,
		DepthTest = true,
		DepthWrite = true,
		DepthCompareOp = "less_or_equal",
		Blend = true,
		SrcColorBlendFactor = "src_alpha",
		DstColorBlendFactor = "one_minus_src_alpha",
		ColorBlendOp = "add",
		SrcAlphaBlendFactor = "one",
		DstAlphaBlendFactor = "zero",
		AlphaBlendOp = "add",
		ColorWriteMask = {"r", "g", "b", "a"},
	},
}
