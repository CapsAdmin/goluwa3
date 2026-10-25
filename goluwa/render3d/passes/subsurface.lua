local render3d = import("goluwa/render3d/render3d.lua")
local gbuffer_layout = import("goluwa/render3d/gbuffer_layout.lua")
local compute_helpers = import("goluwa/render3d/compute_helpers.lua")
local pvars = import("goluwa/cli/pvars.lua")
local COMPUTE_LOCAL_SIZE = {x = 8, y = 8, z = 1}
local TAPS = 10
local EXTENT_MM = 24
local MIN_EXTENT_PIXELS = 0.5
pvars.StartGroup("Post", "Subsurface scattering", {store = false, prefix = "subsurface_"})
local width = pvars.Setup2{
	key = "r_subsurface_width",
	friendly = "width",
	default = 1,
	help = "scales how far light travels under the skin, 1 is human skin (the profile is in millimeters)",
}
pvars.EndGroup()
local DIRECTIONS = {horizontal = "ivec2(1, 0)", vertical = "ivec2(0, 1)"}

local function is_lighting_enabled()
	return render3d.IsPassEnabled("lighting")
end

local function get_shader(direction, combine)
	return compute_helpers.GetScreenHelpersGLSL() .. gbuffer_layout.GetDecodeGLSL("sss_data") .. [[

		const int TAPS = ]] .. TAPS .. [[;
		const float EXTENT_MM = ]] .. EXTENT_MM .. [[.0;
		const float MIN_ALBEDO = ]] .. string.format("%.3f", render3d.SUBSURFACE_MIN_ALBEDO) .. [[;
		vec3 profile(float distance_mm, vec3 scatter_mm) {
			vec3 x = abs(distance_mm) / max(scatter_mm, vec3(0.02));
			return exp(-x) + exp(-x / 3.0);
		}

		float get_view_depth(float depth) {
			mat4 inv_projection = sss_data.inv_projection;
			return -(inv_projection[2][2] * depth + inv_projection[3][2]) / (inv_projection[2][3] * depth + inv_projection[3][3]);
		}

		void main() {
			ivec2 pos = get_screen_pos();
			ivec2 size = textureSize(TEXTURE(sss_data.source_tex), 0);

			if (!is_screen_pos_in_bounds(pos, size)) return;

			vec4 center = texelFetch(TEXTURE(sss_data.source_tex), pos, 0);
			]] .. (
			combine and
			[[
			vec4 original = texelFetch(TEXTURE(sss_data.diffuse_tex), pos, 0);
			if (original.a <= 0.0) return;
			]] or
			[[
			if (center.a <= 0.0) {
				imageStore(out_color, pos, vec4(0.0));
				return;
			}
			]]
		) .. [[

			float center_depth = gbuffer_depth(pos);
			float view_depth = get_view_depth(center_depth);
			float pixels_per_meter = sss_data.projection[0][0] * 0.5 * float(size.x) / view_depth;
			vec3 tint = gbuffer_subsurface_tint(pos);
			float width = sss_data.width * gbuffer_subsurface_radius(pos);
			float extent_pixels = EXTENT_MM * 0.001 * width * pixels_per_meter;
			vec3 result = center.rgb;

			if (extent_pixels >= ]] .. MIN_EXTENT_PIXELS .. [[) {
				vec3 sum = vec3(0.0);
				vec3 total = vec3(0.0);

				float jitter = fract(52.9829189 * fract(dot(vec2(pos), vec2(0.06711056, 0.00583715))) + sss_data.noise_phase * 0.618034 + ]] .. (
			combine and
			"0.37" or
			"0.0"
		) .. [[) - 0.5;

				for (int k = -TAPS; k <= TAPS; k++) {
					float steps = k == 0 ? 0.0 : max(float(abs(k)) + jitter, 0.0);
					float t = sign(float(k)) * steps * steps / float(TAPS * TAPS);
					float spacing = max(2.0 * steps, 0.5) / float(TAPS * TAPS);
					ivec2 p = pos + ]] .. DIRECTIONS[direction] .. [[ * int(round(t * extent_pixels));

					if (any(lessThan(p, ivec2(0))) || any(greaterThanEqual(p, size))) continue;

					vec4 tap = texelFetch(TEXTURE(sss_data.source_tex), p, 0);

					if (tap.a <= 0.0) continue;

					float tap_depth = gbuffer_depth(p);
					float depth_difference = abs(get_view_depth(tap_depth) - view_depth);
					float allowed = 0.004 + 1.5 * abs(t) * EXTENT_MM * 0.001 * width;
					vec3 weight = profile(t * EXTENT_MM, tint) * spacing * (depth_difference < allowed ? 1.0 : 0.0);
					sum += tap.rgb * weight;
					total += weight;
				}

				result = total.r > 0.0 ? sum / max(total, vec3(1e-6)) : center.rgb;
			}

			]] .. (
			combine and
			[[
			vec3 albedo = max(gbuffer_albedo(pos), vec3(MIN_ALBEDO));
			vec4 color = imageLoad(scene_color, pos);
			color.rgb = max(color.rgb + original.a * (result - original.rgb) * albedo, vec3(0.0));
			imageStore(scene_color, pos, color);
			]] or
			[[
			imageStore(out_color, pos, vec4(result, center.a));
			]]
		) .. [[
		}
	]]
end

local function get_block(source_texture_getter, combine)
	return {
		name = "sss_data",
		binding_index = 3,
		block = {
			render3d.camera_block,
			gbuffer_layout.block,
			{"source_tex", "int"},
			{"diffuse_tex", "int"},
			{"width", "float"},
		},
		write = function(self, block)
			render3d.WriteCameraBlock(self, block)
			gbuffer_layout.WriteBlock(self, block)
			block.source_tex = self:GetTextureIndex(source_texture_getter())
			block.diffuse_tex = self:GetTextureIndex(render3d.pipelines.lighting:GetFramebuffer(1):GetAttachment(2))
			block.width = width:Get()
			return block
		end,
	}
end

return {
	{
		name = "subsurface_blur",
		ComputePass = true,
		is_enabled = is_lighting_enabled,
		ColorFormat = {{"r16g16b16a16_sfloat", {"color", "rgba"}}},
		framebuffer_count = 1,
		LocalSize = COMPUTE_LOCAL_SIZE,
		storage_images = {{binding_index = 0, attachment = 1, dst_stage = "compute"}},
		uniform_buffers = {
			get_block(function()
				return render3d.pipelines.lighting:GetFramebuffer(1):GetAttachment(2)
			end),
		},
		custom_declarations = [[
			layout(set = 0, binding = 0, rgba16f) uniform writeonly image2D out_color;
		]],
		shader = get_shader("horizontal", false),
	},
	{
		name = "subsurface",
		ComputePass = true,
		is_enabled = is_lighting_enabled,
		ColorFormat = {{"r8_unorm", {"unused", "r"}}},
		framebuffer_count = 1,
		LocalSize = COMPUTE_LOCAL_SIZE,
		storage_images = {
			{
				binding_index = 0,
				dst_stage = "fragment",
				get_texture = function()
					return render3d.pipelines.lighting:GetFramebuffer(1):GetAttachment(1)
				end,
			},
		},
		uniform_buffers = {
			get_block(function()
				return render3d.pipelines.subsurface_blur:GetFramebuffer(1):GetAttachment(1)
			end),
		},
		custom_declarations = [[
			layout(set = 0, binding = 0, rgba16f) uniform image2D scene_color;
		]],
		shader = get_shader("vertical", true),
	},
}
