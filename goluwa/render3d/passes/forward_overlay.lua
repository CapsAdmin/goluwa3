local event = import("goluwa/event.lua")
local render = import("goluwa/render/render.lua")
local orientation = import("goluwa/render3d/orientation.lua")
local Material = import("goluwa/render3d/material.lua")
local model_pipeline = import("goluwa/render3d/model_pipeline.lua")
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
		vertex = model_pipeline.CreateVertexStage{
			uv = true,
			texture_blend = true,
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
					block = model_pipeline.GetSurfaceMaterialBlock(),
				},
			},
			shader = [[
			]] .. model_pipeline.BuildSurfaceSamplingGlsl("model") .. [[

			layout(location = 0) out vec4 frag_color;

			void main() {
				if (clip_plane.Enabled != 0 && dot(in_position - clip_plane.Origin, clip_plane.Normal) < 0.0) discard;

				vec4 color = get_surface_color();

				discard_surface_alpha(color);

				frag_color = vec4(color.rgb + get_surface_emissive(color.rgb), color.a);
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
