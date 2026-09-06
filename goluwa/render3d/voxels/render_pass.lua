local render3d = import("goluwa/render3d/render3d.lua")
local model_pipeline = import("goluwa/render3d/model_pipeline.lua")
local rasterize = import("goluwa/render3d/voxels/rasterize.lua")
local voxel_gi = import("goluwa/render3d/voxels/global_illumination.lua")
local compute_helpers = import("goluwa/render3d/compute_helpers.lua")
local screen_reconstruct = import("goluwa/render3d/screen_reconstruct.lua")
local ibl = import("goluwa/render3d/ibl.lua")
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
	{
		-- Screen space diffuse gi, one probe grid lookup per pixel, written
		-- out as rgb irradiance plus the leftover sky visibility in alpha.
		--
		-- This is its own pass rather than a call inside the lighting shader
		-- because the probe sampling code costs the lighting shader far more
		-- in occupancy than it costs to run: with every probe rejected on its
		-- first weight test the lighting pass was still ~13 ms slower on an
		-- M2 Air than with the code absent entirely.
		name = "voxel_gi_irradiance",
		ComputePass = true,
		ColorFormat = {
			{"r16g16b16a16_sfloat", {"color", "rgba"}},
		},
		framebuffer_count = 1,
		-- resolved when the framebuffers are built, so voxel_gi_quality can
		-- move the gi pass between half and full resolution
		scale = function()
			return voxel_gi.SCREEN_SCALE
		end,
		LocalSize = {x = 8, y = 8, z = 1},
		storage_images = {
			{
				binding_index = 0,
				attachment = 1,
				dst_stage = "compute",
			},
		},
		uniform_buffers = {
			{
				name = "gi_data",
				binding_index = 3,
				block = {
					render3d.camera_block,
					render3d.gbuffer_block,
					{"env_irradiance_tex", "int"},
					voxel_gi.GetBlockLayout(),
				},
				write = function(self, block)
					render3d.WriteCameraBlock(self, block)
					render3d.WriteGBufferBlock(self, block)
					block.env_irradiance_tex = self:GetCubeMapTextureIndex(render3d.GetEnvironmentIrradianceTexture())
					voxel_gi.WriteBlock(self, block)
					return block
				end,
			},
		},
		custom_declarations = [[
			layout(set = 0, binding = 0, rgba16f) uniform writeonly image2D out_color;
		]],
		shader = [[
			vec2 in_uv;
			#define saturate(x) clamp(x, 0.0, 1.0)

			]] .. compute_helpers.GetScreenHelpersGLSL() .. [[
			]] .. screen_reconstruct.GetWorldPosGLSL("gi_data") .. [[
			]] .. ibl.GetEnvironmentGLSLCode() .. [[
			]] .. voxel_gi.GetGLSLCode("gi_data") .. [[

			void main() {
				ivec2 pos = get_screen_pos();
				ivec2 size = imageSize(out_color);

				if (!is_screen_pos_in_bounds(pos, size)) return;

				// this runs at half resolution, so the gbuffer is read with
				// the exact texel under this pixel rather than a filtered
				// sample: a blend across a silhouette reconstructs a world
				// position that lies on neither surface and lights it wrong
				ivec2 gbuffer_size = textureSize(TEXTURE(gi_data.depth_tex), 0);
				ivec2 gbuffer_pos = min(
					ivec2((vec2(pos) + 0.5) * vec2(gbuffer_size) / vec2(size)),
					gbuffer_size - 1
				);
				in_uv = (vec2(gbuffer_pos) + 0.5) / vec2(gbuffer_size);
				float depth = texelFetch(TEXTURE(gi_data.depth_tex), gbuffer_pos, 0).r;
				vec3 N = texelFetch(TEXTURE(gi_data.normal_tex), gbuffer_pos, 0).xyz;
				vec3 sky = sample_environment_irradiance(gi_data.env_irradiance_tex, N);

				// nothing was drawn here, the lighting pass takes the sky path
				if (depth == 1.0 || gi_data.gi_enabled == 0) {
					imageStore(out_color, pos, vec4(sky, 1.0));
					return;
				}

				vec3 world_pos = get_world_pos(depth);
				vec3 V = normalize(gi_data.camera_position.xyz - world_pos);
				float sky_visibility;
				vec3 irradiance = sample_voxel_gi_irradiance(world_pos, N, V, sky, sky_visibility);
				imageStore(out_color, pos, vec4(min(irradiance, vec3(65504.0)), sky_visibility));
			}
		]],
	},
	{
		-- Resolves the half resolution irradiance to full resolution with a
		-- depth aware 2x2 tap. A plain bilinear upsample pulls irradiance
		-- across silhouettes and leaves a bright rim around every object.
		name = "voxel_gi_upsample",
		ComputePass = true,
		ColorFormat = {
			{"r16g16b16a16_sfloat", {"color", "rgba"}},
		},
		framebuffer_count = 1,
		LocalSize = {x = 8, y = 8, z = 1},
		storage_images = {
			{
				binding_index = 0,
				attachment = 1,
				dst_stage = "compute",
			},
		},
		uniform_buffers = {
			{
				name = "gi_upsample_data",
				binding_index = 3,
				block = {
					render3d.camera_block,
					render3d.gbuffer_block,
					{"gi_half_tex", "int"},
				},
				write = function(self, block)
					render3d.WriteCameraBlock(self, block)
					render3d.WriteGBufferBlock(self, block)

					if render3d.pipelines.voxel_gi_irradiance then
						block.gi_half_tex = self:GetTextureIndex(render3d.pipelines.voxel_gi_irradiance:GetFramebuffer(1):GetAttachment(1))
					else
						block.gi_half_tex = -1
					end

					return block
				end,
			},
		},
		custom_declarations = [[
			layout(set = 0, binding = 0, rgba16f) uniform writeonly image2D out_color;
		]],
		shader = [[
			]] .. compute_helpers.GetScreenHelpersGLSL() .. [[
			]] .. screen_reconstruct.GetWorldPosFromUVGLSL("gi_upsample_data") .. [[

			// depth is non linear, so the edge test compares view space depth
			float get_view_depth(vec2 uv, float depth) {
				return -(gi_upsample_data.view * vec4(get_world_pos(uv, depth), 1.0)).z;
			}

			void main() {
				ivec2 pos = get_screen_pos();
				ivec2 size = imageSize(out_color);

				if (!is_screen_pos_in_bounds(pos, size)) return;

				vec2 uv = get_screen_uv(pos, size);

				if (gi_upsample_data.gi_half_tex < 0) {
					imageStore(out_color, pos, vec4(0.0, 0.0, 0.0, 1.0));
					return;
				}

				ivec2 half_size = textureSize(TEXTURE(gi_upsample_data.gi_half_tex), 0);
				float center_depth = texelFetch(TEXTURE(gi_upsample_data.depth_tex), pos, 0).r;

				if (center_depth == 1.0) {
					imageStore(out_color, pos, texture(TEXTURE(gi_upsample_data.gi_half_tex), uv));
					return;
				}

				float center_view_depth = get_view_depth(uv, center_depth);
				float depth_sigma = max(0.02 * center_view_depth, 0.01);
				vec2 half_uv = uv * vec2(half_size) - 0.5;
				ivec2 base = ivec2(floor(half_uv));
				vec2 f = half_uv - vec2(base);
				vec4 total = vec4(0.0);
				float weight_sum = 0.0;

				for (int i = 0; i < 4; i++) {
					ivec2 offset = ivec2(i & 1, i >> 1);
					ivec2 texel = clamp(base + offset, ivec2(0), half_size - 1);
					// the gbuffer texel that half resolution sample was taken
					// from, so its depth is the one it actually shaded
					ivec2 gbuffer_pos = min(
						ivec2((vec2(texel) + 0.5) * vec2(size) / vec2(half_size)),
						size - 1
					);
					float sample_depth = texelFetch(TEXTURE(gi_upsample_data.depth_tex), gbuffer_pos, 0).r;

					if (sample_depth == 1.0) continue;

					vec2 sample_uv = (vec2(gbuffer_pos) + 0.5) / vec2(size);
					float depth_diff = get_view_depth(sample_uv, sample_depth) - center_view_depth;
					float bilinear = (offset.x == 0 ? 1.0 - f.x : f.x) * (offset.y == 0 ? 1.0 - f.y : f.y);
					float weight = bilinear *
						exp(-(depth_diff * depth_diff) / (2.0 * depth_sigma * depth_sigma));
					total += texelFetch(TEXTURE(gi_upsample_data.gi_half_tex), texel, 0) * weight;
					weight_sum += weight;
				}

				// every tap sat on a different surface: take the nearest one
				// rather than a blend of things this pixel cannot see
				if (weight_sum < 1e-4) {
					ivec2 texel = clamp(
						ivec2(uv * vec2(half_size)),
						ivec2(0),
						half_size - 1
					);
					imageStore(out_color, pos, texelFetch(TEXTURE(gi_upsample_data.gi_half_tex), texel, 0));
					return;
				}

				imageStore(out_color, pos, total / weight_sum);
			}
		]],
	},
}
