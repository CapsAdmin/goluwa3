local system = import("goluwa/system.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local post_source = import("goluwa/render3d/post_source.lua")
local compute_helpers = import("goluwa/render3d/compute_helpers.lua")

local function get_scene_source_texture()
	return post_source.GetSceneSourceTexture({name = "luminance"})
end

local function get_previous_luma_texture()
	if not render3d.pipelines.luminance or not render3d.pipelines.luminance.framebuffers then
		return nil
	end

	local prev_idx = (system.GetFrameNumber() + 1) % 2 + 1
	local prev_fb = render3d.pipelines.luminance:GetFramebuffer(prev_idx)

	if not prev_fb.initialized then return nil end

	return prev_fb:GetAttachment(1)
end

return {
	name = "luminance",
	ComputePass = true,
	ColorFormat = {{"r16_sfloat", {"luma", "r"}}},
	scale = 0.0625,
	framebuffer_count = 2,
	LocalSize = {x = 8, y = 8, z = 1},
	storage_images = {
		{
			binding_index = 0,
			attachment = 1,
			dst_stage = "fragment",
		},
	},
	sampled_images = {
		{
			binding_index = 1,
			get_texture = get_scene_source_texture,
		},
		{
			binding_index = 2,
			get_texture = get_previous_luma_texture,
		},
	},
	block = {
		{"has_source_tex", "int"},
		{"has_prev_luma_tex", "int"},
	},
	write = function(self, block)
		block.has_source_tex = get_scene_source_texture() and 1 or 0
		block.has_prev_luma_tex = get_previous_luma_texture() and 1 or 0
		return block
	end,
	shader = [[
		layout(set = 0, binding = 0, r16f) uniform writeonly image2D out_luma;
		layout(set = 0, binding = 1) uniform sampler2D source_tex;
		layout(set = 0, binding = 2) uniform sampler2D prev_luma_tex;
	]] .. compute_helpers.GetScreenHelpersGLSL() .. [[

		void main() {
			ivec2 pos = get_screen_pos();
			ivec2 size = imageSize(out_luma);

			if (!is_screen_pos_in_bounds(pos, size)) return;

			float luma;

			if (compute.has_source_tex == 0) {
				luma = 0.5;
				imageStore(out_luma, pos, vec4(luma, 0.0, 0.0, 1.0));
				return;
			}

			vec2 uv = get_screen_uv(pos, size);
			vec3 col = texture(source_tex, uv).rgb;
			float current_luma = dot(col, vec3(0.2126, 0.7152, 0.0722));
			current_luma = log2(max(current_luma, 0.0001));

			if (compute.has_prev_luma_tex != 0) {
				float prev_luma = texture(prev_luma_tex, uv).r;
				float adapt_speed = 0.001;
				current_luma = mix(prev_luma, current_luma, adapt_speed);
			}

			imageStore(out_luma, pos, vec4(current_luma, 0.0, 0.0, 1.0));
		}
	]],
}
