local event = import("goluwa/event.lua")
local render = import("goluwa/render/render.lua")
local orientation = import("goluwa/render3d/orientation.lua")
local Material = import("goluwa/render3d/material.lua")
local model_pipeline = import("goluwa/render3d/model_pipeline.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local Matrix44 = import("goluwa/structs/matrix44.lua")
-- the overlay draws to the swapchain, whose depth is cleared to 1 and not
-- the reversed depth of the gbuffer, so its geometry is flipped back
local standard_depth = Matrix44()
standard_depth.m22 = -1
standard_depth.m32 = 1
local overlay_matrix = Matrix44()

local function get_overlay_matrix()
	return render3d.GetUnjitteredProjectionViewWorldMatrix():GetMultiplied(standard_depth, overlay_matrix)
end
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
			get_projection_view_world_matrix = get_overlay_matrix,
		},
		fragment = {
			uniform_buffers = {
				{
					name = "clip_plane",
					block = {
						{"Enabled", "int"},
						{"Origin", "vec3"},
						{"Normal", "vec3"},
					},
					write = function(self, block)
						block.Enabled = render3d.IsForwardOverlayClipPlaneEnabled() and 1 or 0
						render3d.GetForwardOverlayClipPlaneOrigin():CopyToFloatPointer(block.Origin)
						render3d.GetForwardOverlayClipPlaneNormal():CopyToFloatPointer(block.Normal)
						return block
					end,
				},
				{
					name = "model",
					block = model_pipeline.GetSurfaceMaterialBlock(),
					write = model_pipeline.WriteSurfaceMaterialBlock,
				},
			},
			shader = [[
			]] .. model_pipeline.BuildSurfaceSamplingGlsl() .. [[

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
		ColorWriteMask = "rgba",
	},
}
