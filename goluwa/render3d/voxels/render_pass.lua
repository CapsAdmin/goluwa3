local render3d = import("goluwa/render3d/render3d.lua")
local voxel_gi = import("goluwa/render3d/voxels/global_illumination.lua")
local compute_helpers = import("goluwa/render3d/compute_helpers.lua")
local screen_reconstruct = import("goluwa/render3d/screen_reconstruct.lua")
local ibl = import("goluwa/render3d/ibl.lua")
return {
	import("goluwa/render3d/voxels/rasterize_pass.lua"),
	{
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
		name = "voxel_gi_irradiance",
		ComputePass = true,
		ColorFormat = {
			{"r16g16b16a16_sfloat", {"color", "rgba"}},
		},
		framebuffer_count = 1,
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
					block.env_irradiance_tex = self:GetTextureIndex(render3d.GetEnvironmentIrradianceTexture())
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

				ivec2 gbuffer_size = textureSize(TEXTURE(gi_data.depth_tex), 0);
				ivec2 gbuffer_pos = min(
					ivec2((vec2(pos) + 0.5) * vec2(gbuffer_size) / vec2(size)),
					gbuffer_size - 1
				);
				in_uv = (vec2(gbuffer_pos) + 0.5) / vec2(gbuffer_size);
				float depth = texelFetch(TEXTURE(gi_data.depth_tex), gbuffer_pos, 0).r;
				vec3 N = texelFetch(TEXTURE(gi_data.normal_tex), gbuffer_pos, 0).xyz;
				vec3 sky = sample_environment_irradiance(gi_data.env_irradiance_tex, N);

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
