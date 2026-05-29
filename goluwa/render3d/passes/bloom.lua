local render3d = import("goluwa/render3d/render3d.lua")
local post_source = import("goluwa/render3d/post_source.lua")
local compute_helpers = import("goluwa/render3d/compute_helpers.lua")
local COMPUTE_LOCAL_SIZE = {x = 8, y = 8, z = 1}

local function get_scene_source_texture(name)
	return function()
		return post_source.GetSceneSourceTexture({name = name})
	end
end

local function build_extract_pass()
	return {
		name = "bloom_extract",
		ComputePass = true,
		ColorFormat = {{"r16g16b16a16_sfloat", {"bloom", "rgba"}}},
		scale = 0.5,
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
				get_texture = get_scene_source_texture("bloom_extract"),
			},
		},
		block = {
			{"has_source_tex", "int"},
		},
		write = function(self, block)
			block.has_source_tex = get_scene_source_texture("bloom_extract")() and 1 or 0
			return block
		end,
		shader = [[
			layout(set = 0, binding = 0, rgba16f) uniform writeonly image2D out_bloom;
			layout(set = 0, binding = 1) uniform sampler2D source_tex;
		]] .. compute_helpers.GetScreenHelpersGLSL() .. [[

			void main() {
				ivec2 pos = get_screen_pos();
				ivec2 size = imageSize(out_bloom);

				if (!is_screen_pos_in_bounds(pos, size)) return;

				if (compute.has_source_tex == 0) {
					imageStore(out_bloom, pos, vec4(0.0));
					return;
				}

				vec2 uv = get_screen_uv(pos, size);
				vec3 col = texture(source_tex, uv).rgb;

				float threshold = 1.25;
				float knee = 0.75;
				float brightness = dot(col, vec3(0.2126, 0.7152, 0.0722));
				float soft = brightness - threshold + knee;
				soft = clamp(soft, 0.0, 2.0 * knee);
				soft = soft * soft / (4.0 * knee + 0.00001);
				float contribution = max(soft, brightness - threshold);
				contribution /= max(brightness, 0.00001);

				imageStore(out_bloom, pos, vec4(col * contribution, 1.0));
			}
		]],
	}
end

local function build_downsample_pass(i, prev_name)
	local get_source_texture = function()
		return render3d.pipelines[prev_name]:GetFramebuffer():GetAttachment(1)
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
		shader = [[
			layout(set = 0, binding = 0, rgba16f) uniform writeonly image2D out_bloom;
			layout(set = 0, binding = 1) uniform sampler2D source_tex;
		]] .. compute_helpers.GetScreenHelpersGLSL() .. [[

			void main() {
				ivec2 pos = get_screen_pos();
				ivec2 size = imageSize(out_bloom);

				if (!is_screen_pos_in_bounds(pos, size)) return;

				if (compute.has_source_tex == 0) {
					imageStore(out_bloom, pos, vec4(0.0));
					return;
				}

				vec2 uv = get_screen_uv(pos, size);
				vec2 texel_size = 1.0 / vec2(textureSize(source_tex, 0));
				vec3 sum = vec3(0.0);

				sum += texture(source_tex, uv + vec2(-2, -2) * texel_size).rgb;
				sum += texture(source_tex, uv + vec2(0, -2) * texel_size).rgb * 2.0;
				sum += texture(source_tex, uv + vec2(2, -2) * texel_size).rgb;
				sum += texture(source_tex, uv + vec2(-2, 0) * texel_size).rgb * 2.0;
				sum += texture(source_tex, uv).rgb * 4.0;
				sum += texture(source_tex, uv + vec2(2, 0) * texel_size).rgb * 2.0;
				sum += texture(source_tex, uv + vec2(-2, 2) * texel_size).rgb;
				sum += texture(source_tex, uv + vec2(0, 2) * texel_size).rgb * 2.0;
				sum += texture(source_tex, uv + vec2(2, 2) * texel_size).rgb;

				imageStore(out_bloom, pos, vec4(sum / 16.0, 1.0));
			}
		]],
	}
end

local r = {build_extract_pass()}

for i = 1, 3 do
	local prev_name = i == 1 and "bloom_extract" or ("bloom_down" .. (i - 1))
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

				void main() {
					ivec2 pos = get_screen_pos();
					ivec2 size = imageSize(out_bloom);

					if (!is_screen_pos_in_bounds(pos, size)) return;

					if (compute.has_source_tex == 0) {
						imageStore(out_bloom, pos, vec4(0.0));
						return;
					}

					vec2 uv = get_screen_uv(pos, size);
					vec2 texel_size = 1.0 / vec2(textureSize(source_tex, 0));
					vec3 sum = vec3(0.0);

					sum += texture(source_tex, uv + vec2(-1, -1) * texel_size).rgb;
					sum += texture(source_tex, uv + vec2(0, -1) * texel_size).rgb * 2.0;
					sum += texture(source_tex, uv + vec2(1, -1) * texel_size).rgb;
					sum += texture(source_tex, uv + vec2(-1, 0) * texel_size).rgb * 2.0;
					sum += texture(source_tex, uv).rgb * 4.0;
					sum += texture(source_tex, uv + vec2(1, 0) * texel_size).rgb * 2.0;
					sum += texture(source_tex, uv + vec2(-1, 1) * texel_size).rgb;
					sum += texture(source_tex, uv + vec2(0, 1) * texel_size).rgb * 2.0;
					sum += texture(source_tex, uv + vec2(1, 1) * texel_size).rgb;

					vec3 result = sum / 16.0;

					if (compute.has_merge_tex != 0) {
						result += texture(merge_tex, uv).rgb * %.3f;
					}

					imageStore(out_bloom, pos, vec4(result, 1.0));
				}
			]],
				upsample_merge_strength
			),
	}
end

for i = 3, 1, -1 do
	local source_name = i == 3 and "bloom_down3" or ("bloom_up" .. (i + 1))
	local merge_name = i == 1 and "bloom_extract" or ("bloom_down" .. i)
	local idx = i == 1 and 0 or i
	r[#r + 1] = build_upsample_pass(i, source_name, merge_name, idx)
end

return r
