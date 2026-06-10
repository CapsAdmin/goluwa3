local render3d = import("goluwa/render3d/render3d.lua")
local post_source = import("goluwa/render3d/post_source.lua")
local compute_helpers = import("goluwa/render3d/compute_helpers.lua")
local COMPUTE_LOCAL_SIZE = {x = 8, y = 8, z = 1}
local BLOOM_THRESHOLD = 1.25
local BLOOM_KNEE = 0.75
local BLOOM_KERNEL_HALO = 2
local BLOOM_TILE_WIDTH = COMPUTE_LOCAL_SIZE.x + BLOOM_KERNEL_HALO * 2
local BLOOM_TILE_HEIGHT = COMPUTE_LOCAL_SIZE.y + BLOOM_KERNEL_HALO * 2

local function get_scene_source_texture(name)
	return function()
		return post_source.GetSceneSourceTexture({name = name})
	end
end

local function build_tile_loader_glsl(load_expression)
	return string.format(
		[[
			for (int tile_y = int(gl_LocalInvocationID.y); tile_y < %d; tile_y += %d) {
				for (int tile_x = int(gl_LocalInvocationID.x); tile_x < %d; tile_x += %d) {
					ivec2 sample_pos = ivec2(
						int(gl_WorkGroupID.x) * %d + tile_x - %d,
						int(gl_WorkGroupID.y) * %d + tile_y - %d
					);
					vec2 sample_uv = get_screen_uv(sample_pos, imageSize(out_bloom));
					bloom_tile[tile_y][tile_x] = %s;
				}
			}

			memoryBarrierShared();
			barrier();
		]],
		BLOOM_TILE_HEIGHT,
		COMPUTE_LOCAL_SIZE.y,
		BLOOM_TILE_WIDTH,
		COMPUTE_LOCAL_SIZE.x,
		COMPUTE_LOCAL_SIZE.x,
		BLOOM_KERNEL_HALO,
		COMPUTE_LOCAL_SIZE.y,
		BLOOM_KERNEL_HALO,
		load_expression
	)
end

local function build_downsample_pass(i, prev_name)
	local get_source_texture

	if i == 1 then
		get_source_texture = get_scene_source_texture("bloom_down1")
	else
		get_source_texture = function()
			return render3d.pipelines[prev_name]:GetFramebuffer():GetAttachment(1)
		end
	end

	local shader

	if i == 1 then
		shader = compute_helpers.GetScreenHelpersGLSL() .. string.format(
				[[
				layout(set = 0, binding = 0, rgba16f) uniform writeonly image2D out_bloom;
				layout(set = 0, binding = 1) uniform sampler2D source_tex;
				shared vec3 bloom_tile[%d][%d];

				vec3 extract_bloom(vec3 col) {
					float brightness = dot(col, vec3(0.2126, 0.7152, 0.0722));
					float soft = brightness - %.3f + %.3f;
					soft = clamp(soft, 0.0, 2.0 * %.3f);
					soft = soft * soft / (4.0 * %.3f + 0.00001);
					float contribution = max(soft, brightness - %.3f);
					contribution /= max(brightness, 0.00001);
					return col * contribution;
				}

				void main() {
					ivec2 pos = get_screen_pos();
					ivec2 size = imageSize(out_bloom);

					bool in_bounds = is_screen_pos_in_bounds(pos, size);

					if (compute.has_source_tex == 0) {
						for (int ty = int(gl_LocalInvocationID.y); ty < %d; ty += %d) {
							for (int tx = int(gl_LocalInvocationID.x); tx < %d; tx += %d) {
								bloom_tile[ty][tx] = vec3(0.0);
							}
						}
						memoryBarrierShared();
						barrier();
					} else {
						%s
					}

					vec3 sum = vec3(0.0);
					ivec2 tile_pos = ivec2(gl_LocalInvocationID.xy) + ivec2(%d);

					sum += bloom_tile[tile_pos.y - 2][tile_pos.x - 2];
					sum += bloom_tile[tile_pos.y - 2][tile_pos.x] * 2.0;
					sum += bloom_tile[tile_pos.y - 2][tile_pos.x + 2];
					sum += bloom_tile[tile_pos.y][tile_pos.x - 2] * 2.0;
					sum += bloom_tile[tile_pos.y][tile_pos.x] * 4.0;
					sum += bloom_tile[tile_pos.y][tile_pos.x + 2] * 2.0;
					sum += bloom_tile[tile_pos.y + 2][tile_pos.x - 2];
					sum += bloom_tile[tile_pos.y + 2][tile_pos.x] * 2.0;
					sum += bloom_tile[tile_pos.y + 2][tile_pos.x + 2];

					if (in_bounds) {
						imageStore(out_bloom, pos, vec4(sum / 16.0, 1.0));
					}
				}
			]],
				BLOOM_TILE_HEIGHT,
				BLOOM_TILE_WIDTH,
				BLOOM_THRESHOLD,
				BLOOM_KNEE,
				BLOOM_KNEE,
				BLOOM_KNEE,
				BLOOM_THRESHOLD,
				BLOOM_TILE_HEIGHT,
				COMPUTE_LOCAL_SIZE.y,
				BLOOM_TILE_WIDTH,
				COMPUTE_LOCAL_SIZE.x,
				build_tile_loader_glsl("extract_bloom(texture(source_tex, sample_uv).rgb)"),
				BLOOM_KERNEL_HALO
			)
	else
		shader = string.format(
			[[
			layout(set = 0, binding = 0, rgba16f) uniform writeonly image2D out_bloom;
			layout(set = 0, binding = 1) uniform sampler2D source_tex;
			shared vec3 bloom_tile[%d][%d];
		]] .. compute_helpers.GetScreenHelpersGLSL() .. [[

			void main() {
				ivec2 pos = get_screen_pos();
				ivec2 size = imageSize(out_bloom);

				bool in_bounds = is_screen_pos_in_bounds(pos, size);

				if (compute.has_source_tex == 0) {
					for (int ty = int(gl_LocalInvocationID.y); ty < %d; ty += %d) {
						for (int tx = int(gl_LocalInvocationID.x); tx < %d; tx += %d) {
							bloom_tile[ty][tx] = vec3(0.0);
						}
					}
					memoryBarrierShared();
					barrier();
				} else {
					%s
				}

				vec3 sum = vec3(0.0);
				ivec2 tile_pos = ivec2(gl_LocalInvocationID.xy) + ivec2(%d);

				sum += bloom_tile[tile_pos.y - 2][tile_pos.x - 2];
				sum += bloom_tile[tile_pos.y - 2][tile_pos.x] * 2.0;
				sum += bloom_tile[tile_pos.y - 2][tile_pos.x + 2];
				sum += bloom_tile[tile_pos.y][tile_pos.x - 2] * 2.0;
				sum += bloom_tile[tile_pos.y][tile_pos.x] * 4.0;
				sum += bloom_tile[tile_pos.y][tile_pos.x + 2] * 2.0;
				sum += bloom_tile[tile_pos.y + 2][tile_pos.x - 2];
				sum += bloom_tile[tile_pos.y + 2][tile_pos.x] * 2.0;
				sum += bloom_tile[tile_pos.y + 2][tile_pos.x + 2];

				if (in_bounds) {
					imageStore(out_bloom, pos, vec4(sum / 16.0, 1.0));
				}
			}
		]],
			BLOOM_TILE_HEIGHT,
			BLOOM_TILE_WIDTH,
			BLOOM_TILE_HEIGHT,
			COMPUTE_LOCAL_SIZE.y,
			BLOOM_TILE_WIDTH,
			COMPUTE_LOCAL_SIZE.x,
			build_tile_loader_glsl("texture(source_tex, sample_uv).rgb"),
			BLOOM_KERNEL_HALO
		)
	end

	return {
		name = "bloom_down" .. i,
		ComputePass = true,
		ColorFormat = {{"r16g16b16a16_sfloat", {"bloom", "rgba"}}},
		scale = 0.5 / (2 ^ i),
		LocalSize = COMPUTE_LOCAL_SIZE,
		storage_images = {
			{
				binding_index = 0,
				attachment = 1,
				dst_stage = "compute",
			},
		},
		sampled_images = {
			{
				binding_index = 1,
				get_texture = get_source_texture,
			},
		},
		block = {
			{"has_source_tex", "int"},
		},
		write = function(self, block)
			block.has_source_tex = get_source_texture() and 1 or 0
			return block
		end,
		shader = shader,
	}
end

local r = {}

for i = 1, 3 do
	local prev_name = i == 1 and nil or ("bloom_down" .. (i - 1))
	r[#r + 1] = build_downsample_pass(i, prev_name)
end

local upsample_merge_strength = 0.65

local function build_upsample_pass(i, source_name, merge_name, idx)
	local dst_stage = idx == 0 and "fragment" or "compute"
	local get_source_texture = function()
		return render3d.pipelines[source_name]:GetFramebuffer():GetAttachment(1)
	end
	local get_merge_texture = function()
		return render3d.pipelines[merge_name]:GetFramebuffer():GetAttachment(1)
	end
	return {
		name = "bloom_up" .. idx,
		ComputePass = true,
		ColorFormat = {{"r16g16b16a16_sfloat", {"bloom", "rgba"}}},
		scale = 0.5 / (2 ^ i),
		LocalSize = COMPUTE_LOCAL_SIZE,
		storage_images = {
			{
				binding_index = 0,
				attachment = 1,
				dst_stage = dst_stage,
			},
		},
		sampled_images = {
			{
				binding_index = 1,
				get_texture = get_source_texture,
			},
			{
				binding_index = 2,
				get_texture = get_merge_texture,
			},
		},
		block = {
			{"has_source_tex", "int"},
			{"has_merge_tex", "int"},
		},
		write = function(self, block)
			block.has_source_tex = get_source_texture() and 1 or 0
			block.has_merge_tex = get_merge_texture() and 1 or 0
			return block
		end,
		shader = compute_helpers.GetScreenHelpersGLSL() .. string.format(
				[[
				layout(set = 0, binding = 0, rgba16f) uniform writeonly image2D out_bloom;
				layout(set = 0, binding = 1) uniform sampler2D source_tex;
				layout(set = 0, binding = 2) uniform sampler2D merge_tex;
					shared vec3 bloom_tile[%d][%d];

				void main() {
					ivec2 pos = get_screen_pos();
					ivec2 size = imageSize(out_bloom);

					bool in_bounds = is_screen_pos_in_bounds(pos, size);

					if (compute.has_source_tex == 0) {
						for (int ty = int(gl_LocalInvocationID.y); ty < %d; ty += %d) {
							for (int tx = int(gl_LocalInvocationID.x); tx < %d; tx += %d) {
								bloom_tile[ty][tx] = vec3(0.0);
							}
						}
						memoryBarrierShared();
						barrier();
					} else {
						%s
					}

					vec2 uv = get_screen_uv(pos, size);
					vec3 sum = vec3(0.0);
					ivec2 tile_pos = ivec2(gl_LocalInvocationID.xy) + ivec2(%d);

					sum += bloom_tile[tile_pos.y - 1][tile_pos.x - 1];
					sum += bloom_tile[tile_pos.y - 1][tile_pos.x] * 2.0;
					sum += bloom_tile[tile_pos.y - 1][tile_pos.x + 1];
					sum += bloom_tile[tile_pos.y][tile_pos.x - 1] * 2.0;
					sum += bloom_tile[tile_pos.y][tile_pos.x] * 4.0;
					sum += bloom_tile[tile_pos.y][tile_pos.x + 1] * 2.0;
					sum += bloom_tile[tile_pos.y + 1][tile_pos.x - 1];
					sum += bloom_tile[tile_pos.y + 1][tile_pos.x] * 2.0;
					sum += bloom_tile[tile_pos.y + 1][tile_pos.x + 1];

					vec3 result = sum / 16.0;

					if (compute.has_merge_tex != 0) {
						result += texture(merge_tex, uv).rgb * %.3f;
					}

					if (in_bounds) {
						imageStore(out_bloom, pos, vec4(result, 1.0));
					}
				}
			]],
				BLOOM_TILE_HEIGHT,
				BLOOM_TILE_WIDTH,
				BLOOM_TILE_HEIGHT,
				COMPUTE_LOCAL_SIZE.y,
				BLOOM_TILE_WIDTH,
				COMPUTE_LOCAL_SIZE.x,
				build_tile_loader_glsl("texture(source_tex, sample_uv).rgb"),
				BLOOM_KERNEL_HALO,
				upsample_merge_strength
			),
	}
end

for i = 3, 1, -1 do
	local source_name = i == 3 and "bloom_down3" or ("bloom_up" .. (i + 1))
	local merge_name = "bloom_down" .. i
	local idx = i == 1 and 0 or i

	if idx ~= 0 then
		r[#r + 1] = build_upsample_pass(i, source_name, merge_name, idx)
	end
end

return r
