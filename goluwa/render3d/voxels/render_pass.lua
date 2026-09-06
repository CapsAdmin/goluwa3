local render3d = import("goluwa/render3d/render3d.lua")
local model_pipeline = import("goluwa/render3d/model_pipeline.lua")
local rasterize = import("goluwa/render3d/voxels/rasterize.lua")
local voxel_gi = import("goluwa/render3d/voxels/global_illumination.lua")
return {
	{
		name = "voxel_rasterize",
		ColorFormat = {
			{"r8g8b8a8_unorm", {"color", "rgba"}},
			{"r8g8b8a8_unorm", {"normal", "rgba"}},
		},
		dont_create_framebuffers = true,
		on_draw = function(self, cmd)
			rasterize.Draw(self, cmd)
		end,
		vertex = {
			bindings = {
				{
					binding = 0,
					stride = model_pipeline.GetVertexStride(),
					input_rate = "vertex",
					attributes = model_pipeline.GetVertexAttributesSubset({"position", "uv", "normal"}),
				},
			},
			outputs = {
				{"uv", "vec2"},
				{"normal", "vec3"},
			},
			push_constants = {
				{
					name = "vertex",
					block = model_pipeline.GetTransformBlock(true),
					write = model_pipeline.BuildTransformBlockWriter(true, rasterize.GetProjectionViewWorldMatrix),
				},
			},
			shader = [[
				void main() {
					vec3 local_position = in_position;
					gl_Position = vertex.projection_view_world * vec4(local_position, 1.0);
					out_uv = in_uv;
					out_normal = normalize(mat3(vertex.world) * in_normal);
				}
			]],
		},
		fragment = {
			uniform_buffers = {
				{
					name = "voxel_rasterize_data",
					binding_index = 3,
					block = {
						{"clipmap_index", "int"},
						{"axis_index", "int"},
						{"current_slice", "int"},
						{"resolution", "int"},
						{"voxel_size", "float"},
						{"clipmap_origin", "vec3"},
						{"world_span", "float"},
					},
					write = function(self, block)
						return rasterize.WriteDataBlock(block)
					end,
				},
				{
					name = "surface",
					upload_scope = "frame_keyed",
					upload_key = render3d.GetMaterialUploadKey,
					block = model_pipeline.GetSurfaceMaterialBlock(),
					write = model_pipeline.WriteSurfaceMaterialBlock,
				},
			},
			shader = model_pipeline.BuildSurfaceSamplingGlsl("surface") .. [[
			void main() {
				vec4 surface_color = get_surface_color();
				discard_surface_alpha(surface_color);
				vec3 albedo = clamp(surface_color.rgb, vec3(0.0), vec3(1.0));
				vec3 emissive = clamp(get_surface_emissive(albedo), vec3(0.0), vec3(1.0));
				vec3 voxel_color = clamp(albedo + emissive, vec3(0.0), vec3(1.0));
				// alpha >= 0.5 marks an occupied voxel, the range above 0.5
				// encodes the emissive luminance (0..4) so voxel gi can re-emit it
				float emissive_luma = dot(emissive, vec3(0.2126, 0.7152, 0.0722));
				set_color(vec4(voxel_color, 0.5 + 0.5 * clamp(emissive_luma / 4.0, 0.0, 1.0)));
				// the normal target is signed and additive: opposite faces that
				// land in the same voxel (thin slabs) cancel to a zero normal,
				// which voxel gi treats as two sided instead of a backface
				vec3 n = normalize(in_normal);
				set_normal(vec4(n, 1.0));
			}
			]],
		},
		CullMode = "none",
		color_blend = {
			attachments = {
				{},
				{
					blend = true,
					src_color_blend_factor = "one",
					dst_color_blend_factor = "one",
					color_blend_op = "add",
					src_alpha_blend_factor = "one",
					dst_alpha_blend_factor = "one",
					alpha_blend_op = "add",
				},
			},
		},
		DepthTest = false,
		DepthWrite = false,
		Blend = true,
		SrcColorBlendFactor = "one",
		DstColorBlendFactor = "one",
		ColorBlendOp = "max",
		SrcAlphaBlendFactor = "one",
		DstAlphaBlendFactor = "one",
		AlphaBlendOp = "max",
		ColorWriteMask = "rgba",
	},
	{
		-- refreshes the voxel gi probe grids. the pass owns no screen sized
		-- output, the 1x1 framebuffer only exists to satisfy the compute pass
		-- plumbing
		name = "voxel_gi",
		ComputePass = true,
		ColorFormat = {{"r8_unorm", {"dummy", "r"}}},
		FramebufferSize = {x = 1, y = 1},
		framebuffer_count = 1,
		LocalSize = {x = 1, y = 1, z = 1},
		shader = [[
			void main() {}
		]],
		on_draw = function(self, cmd)
			voxel_gi.Draw(cmd)
		end,
	},
}
