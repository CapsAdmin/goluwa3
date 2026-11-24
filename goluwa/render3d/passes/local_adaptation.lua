local render3d = import("goluwa/render3d/render3d.lua")
local post_source = import("goluwa/render3d/post_source.lua")
local glsl_common = import("goluwa/render3d/glsl_common.lua")
local local_adaptation = import("goluwa/render3d/local_adaptation.lua")
local GRID_X, GRID_Y, GRID_Z = local_adaptation.GRID_X, local_adaptation.GRID_Y, local_adaptation.GRID_Z

local function is_enabled()
	return local_adaptation.IsEnabled() and post_source.GetExposureTexture() ~= nil
end

return {
	{
		name = "local_adaptation_grid",
		is_enabled = is_enabled,
		ComputePass = true,
		ColorFormat = {{"r32g32b32a32_sfloat", {"grid", "rgba"}}},
		FramebufferSize = {x = GRID_X * GRID_Z, y = GRID_Y},
		framebuffer_count = 1,
		LocalSize = {x = 16, y = 16, z = 1},
		storage_images = {{binding_index = 0, attachment = 1, dst_stage = "compute"}},
		sampled_images = {
			{
				binding_index = 1,
				get_texture = function()
					return post_source.GetSceneSourceTexture({name = "local_adaptation_grid"})
				end,
			},
			{
				binding_index = 2,
				get_texture = function()
					return post_source.GetExposureTexture()
				end,
			},
			{
				binding_index = 3,
				get_texture = function()
					return post_source.GetExposureTexture(true)
				end,
			},
		},
		block = {
			{"unused", "int"},
		},
		write = function(self, block)
			return block
		end,
		on_draw = function(self, cmd, fb, frame, desc)
			self:UploadConstants()
			self.pipeline:DispatchForSize(cmd, GRID_X * 16, GRID_Y * 16, 1, desc, self.dynamic_offsets)
		end,
		shader = glsl_common.GetLuminanceGLSL() .. post_source.GetPreExposureFromExposureGLSL() .. local_adaptation.GetGridGLSL() .. [[
			layout(set = 0, binding = 0, rgba32f) uniform writeonly image2D out_grid;
			layout(set = 0, binding = 1) uniform sampler2D source_tex;
			layout(set = 0, binding = 2) uniform sampler2D exposure_tex;
			layout(set = 0, binding = 3) uniform sampler2D prev_exposure_tex;

			#define FIXED 256.0
			#define CHROMA_OFFSET 16.0
			shared uint cell_level[LOCAL_GRID_Z];
			shared uint cell_a[LOCAL_GRID_Z];
			shared uint cell_b[LOCAL_GRID_Z];
			shared uint cell_count[LOCAL_GRID_Z];

			void main() {
				uint id = gl_LocalInvocationIndex;

				if (id < uint(LOCAL_GRID_Z)) {
					cell_level[id] = 0u;
					cell_a[id] = 0u;
					cell_b[id] = 0u;
					cell_count[id] = 0u;
				}

				barrier();
				ivec2 tile = ivec2(gl_WorkGroupID.xy);
				vec2 uv = (vec2(tile) + (vec2(gl_LocalInvocationID.xy) + 0.5) / 16.0) / vec2(LOCAL_GRID_X, LOCAL_GRID_Y);
				float exposure = texture(exposure_tex, vec2(0.5)).r / pre_exposure_from_exposure(texture(prev_exposure_tex, vec2(0.5)).r);
				vec3 col = textureLod(source_tex, uv, 0.0).rgb;
				float l = local_log_level(col * exposure);
				vec2 chroma = clamp(local_chroma(col), vec2(-CHROMA_OFFSET), vec2(CHROMA_OFFSET));
				int z = local_bin(l);
				atomicAdd(cell_level[z], uint((l - LOCAL_LOG_MIN) * FIXED));
				atomicAdd(cell_a[z], uint((chroma.x + CHROMA_OFFSET) * FIXED));
				atomicAdd(cell_b[z], uint((chroma.y + CHROMA_OFFSET) * FIXED));
				atomicAdd(cell_count[z], 1u);
				barrier();

				if (id < uint(LOCAL_GRID_Z)) {
					float count = float(cell_count[id]);
					vec3 sum = vec3(float(cell_level[id]), float(cell_a[id]), float(cell_b[id])) / FIXED + vec3(LOCAL_LOG_MIN, -CHROMA_OFFSET, -CHROMA_OFFSET) * count;
					imageStore(out_grid, ivec2(tile.x + int(id) * LOCAL_GRID_X, tile.y), vec4(sum, count));
				}
			}
		]],
	},
	{
		name = "local_adaptation_blur",
		is_enabled = is_enabled,
		ComputePass = true,
		ColorFormat = {{"r32g32b32a32_sfloat", {"grid", "rgba"}}},
		FramebufferSize = {x = GRID_X * GRID_Z, y = GRID_Y},
		framebuffer_count = 1,
		LocalSize = {x = 8, y = 8, z = 1},
		storage_images = {{binding_index = 0, attachment = 1, dst_stage = "compute"}},
		sampled_images = {
			{
				binding_index = 1,
				get_texture = function()
					return render3d.pipelines.local_adaptation_grid:GetFramebuffer():GetAttachment(1)
				end,
			},
		},
		block = {
			{"unused", "int"},
		},
		write = function(self, block)
			return block
		end,
		shader = [[
			#define LOCAL_GRID_X ]] .. GRID_X .. [[

			#define LOCAL_GRID_Y ]] .. GRID_Y .. [[

			#define LOCAL_GRID_Z ]] .. GRID_Z .. [[

			layout(set = 0, binding = 0, rgba32f) uniform writeonly image2D out_grid;
			layout(set = 0, binding = 1) uniform sampler2D grid_tex;

			void main() {
				ivec2 pos = ivec2(gl_GlobalInvocationID.xy);

				if (pos.x >= LOCAL_GRID_X * LOCAL_GRID_Z || pos.y >= LOCAL_GRID_Y) return;

				ivec3 cell = ivec3(pos.x % LOCAL_GRID_X, pos.y, pos.x / LOCAL_GRID_X);
				const float w5[5] = float[5](1.0, 4.0, 6.0, 4.0, 1.0);
				const float w3[3] = float[3](1.0, 2.0, 1.0);
				vec4 sum = vec4(0.0);

				for (int dz = -1; dz <= 1; dz++) {
					int z = cell.z + dz;

					if (z < 0 || z >= LOCAL_GRID_Z) continue;

					for (int dy = -2; dy <= 2; dy++) {
						for (int dx = -2; dx <= 2; dx++) {
							ivec2 xy = clamp(cell.xy + ivec2(dx, dy), ivec2(0), ivec2(LOCAL_GRID_X - 1, LOCAL_GRID_Y - 1));
							sum += texelFetch(grid_tex, ivec2(xy.x + z * LOCAL_GRID_X, xy.y), 0) * w5[dx + 2] * w5[dy + 2] * w3[dz + 1];
						}
					}
				}

				imageStore(out_grid, pos, sum / 1024.0);
			}
		]],
	},
}
