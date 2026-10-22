local event = import("goluwa/event.lua")
local render = import("goluwa/render/render.lua")
local orientation = import("goluwa/render3d/orientation.lua")
local Material = import("goluwa/render3d/material.lua")
local model_pipeline = import("goluwa/render3d/model_pipeline.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local screen_reconstruct = import("goluwa/render3d/screen_reconstruct.lua")
local gbuffer_layout = import("goluwa/render3d/gbuffer_layout.lua")
local Matrix44 = import("goluwa/structs/matrix44.lua")
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
					name = "overlay_view",
					block = {render3d.camera_block, {"depth_tex", "int"}},
					write = function(self, block)
						render3d.WriteCameraBlock(self, block)
						block.depth_tex = self:GetTextureIndex(gbuffer_layout.GetDepthTexture())
						return block
					end,
				},
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
			]] .. model_pipeline.BuildSurfaceSamplingGlsl() .. screen_reconstruct.GetWorldPosFromUVGLSL("overlay_view", {function_name = "get_scene_pos"}) .. [[

			layout(location = 0) out vec4 frag_color;

			void main() {
				if (clip_plane.Enabled != 0 && dot(in_position - clip_plane.Origin, clip_plane.Normal) < 0.0) discard;

				vec4 color = get_surface_color();

				discard_surface_alpha(color);

				vec3 lit = color.rgb + get_surface_emissive(color.rgb);

				if (model.RimColor.a > 0.0) {
					vec3 view_dir = normalize(overlay_view.camera_position.xyz - in_position);
					float rim = clamp(pow(1.0 - abs(dot(normalize(in_normal), view_dir)), model.RimPower) * model.RimColor.a, 0.0, 1.0);
					float alpha = max(color.a, rim);
					lit = (lit * color.a + model.RimColor.rgb * rim) / max(alpha, 0.0001);
					color.a = alpha;
				}

				if (model.OcclusionRadius > 0.0) {
					vec2 screen_uv = gl_FragCoord.xy / overlay_view.render_size;
					float scene_depth = texture(TEXTURE(overlay_view.depth_tex), screen_uv).r;

					if (scene_depth > 0.0) {
						float gap = distance(overlay_view.camera_position.xyz, in_position) - distance(overlay_view.camera_position.xyz, get_scene_pos(screen_uv, scene_depth));
						float soft = min(model.OcclusionSoftness, model.OcclusionRadius);
						color.a *= 1.0 - smoothstep(model.OcclusionRadius - soft, model.OcclusionRadius, gap);
					}
				}

				frag_color = vec4(lit, color.a);
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
