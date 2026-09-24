local Vec2 = import("goluwa/structs/vec2.lua")
local system = import("goluwa/system.lua")
local commands = import("goluwa/cli/commands.lua")
local render = import("goluwa/render/render.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local post_source = import("goluwa/render3d/post_source.lua")
-- Temporal anti aliasing. The camera is shifted by a different sub pixel
-- offset every frame (Halton 2,3), and each frame is blended into a history
-- that follows the surfaces through the gbuffer velocity. Over the 8 offsets
-- every pixel ends up covered by many samples, which smooths edges and thin
-- geometry like grass that a single sample per pixel can't resolve.
--
-- The history is kept in linear HDR with the view depth it saw in alpha. It
-- is sampled with a Catmull-Rom filter to stay sharp under motion, dropped
-- where the depth says a surface was hidden last frame, and clipped to the
-- colour range of the current pixel's neighbourhood so it can't ghost. The
-- blend happens on exposed, Reinhard compressed colour so a few very bright
-- samples don't dominate it.
render3d.taa_enabled = render3d.taa_enabled ~= false

commands.Add("r_taa=boolean[true]", function(enabled)
	render3d.taa_enabled = enabled
end)

local SAMPLES = {}

do
	local function halton(i, base)
		local f, r = 1, 0

		while i > 0 do
			f = f / base
			r = r + f * (i % base)
			i = math.floor(i / base)
		end

		return r
	end

	for i = 1, 8 do
		SAMPLES[i] = Vec2(halton(i, 2) - 0.5, halton(i, 3) - 0.5)
	end
end

local ZERO = Vec2(0, 0)
local last_frame = -1
local last_width, last_height = 0, 0
return {
	{
		name = "taa",
		ColorFormat = {{"r16g16b16a16_sfloat", {"color", "rgba"}}},
		framebuffer_count = 2,
		pre_render = function()
			render3d.GetMainCamera():SetJitter(render3d.taa_enabled and SAMPLES[system.GetFrameNumber() % #SAMPLES + 1] or ZERO)
		end,
		fragment = {
			uniform_buffers = {
				{
					name = "taa_data",
					binding_index = 2,
					block = {
						render3d.camera_block,
						render3d.prev_camera_block,
						{"jitter", "vec2"},
						{"source_tex", "int"},
						{"history_tex", "int"},
						{"depth_tex", "int"},
						{"velocity_tex", "int"},
						{"exposure_tex", "int"},
						{"history_valid", "int"},
					},
					write = function(self, block)
						render3d.WriteCameraBlock(self, block)
						render3d.WritePreviousCameraBlock(self, block)
						local jitter = render3d.GetCamera():GetJitter()
						block.jitter[0] = jitter.x
						block.jitter[1] = jitter.y
						local frame = system.GetFrameNumber()
						block.source_tex = self:GetTextureIndex(post_source.GetSceneSourceTexture({name = "taa"}))
						block.history_tex = self:GetTextureIndex(render3d.pipelines.taa:GetFramebuffer((frame + 1) % 2 + 1):GetAttachment(1))
						local gbuffer = render3d.pipelines.gbuffer:GetFramebuffer()
						block.depth_tex = self:GetTextureIndex(gbuffer:GetDepthTexture())
						block.velocity_tex = render3d.velocity_enabled and
							self:GetTextureIndex(gbuffer:GetAttachment(6)) or
							-1
						local exposure = post_source.GetExposureTexture(true)
						block.exposure_tex = exposure and self:GetTextureIndex(exposure) or -1
						-- the history is only usable if it was written last frame at
						-- this size
						local size = render.GetRenderImageSize()
						block.history_valid = (
								render3d.taa_enabled and
								last_frame == frame - 1 and
								last_width == size.x and
								last_height == size.y
							)
							and
							1 or
							0
						last_frame = frame
						last_width, last_height = size.x, size.y
						return block
					end,
				},
			},
			shader = [[
			vec3 rgb_to_ycocg(vec3 c) {
				return vec3(
					0.25 * c.r + 0.5 * c.g + 0.25 * c.b,
					0.5 * c.r - 0.5 * c.b,
					-0.25 * c.r + 0.5 * c.g - 0.25 * c.b
				);
			}

			vec3 ycocg_to_rgb(vec3 c) {
				return vec3(c.x + c.y - c.z, c.x + c.z, c.x - c.y - c.z);
			}

			float get_luma(vec3 c) {
				return dot(c, vec3(0.2126, 0.7152, 0.0722));
			}

			// exposed and Reinhard compressed by luminance, so the inverse is exact
			vec3 compress(vec3 c, float exposure) {
				c *= exposure;
				return rgb_to_ycocg(c / (1.0 + get_luma(c)));
			}

			vec3 decompress(vec3 c, float exposure) {
				vec3 rgb = max(ycocg_to_rgb(c), vec3(0.0));
				return rgb / max(1.0 - get_luma(rgb), 1e-4) / exposure;
			}

			float get_view_depth(vec2 uv, float depth) {
				vec4 view_pos = taa_data.inv_projection * vec4(uv * 2.0 - 1.0, depth, 1.0);
				return -view_pos.z / view_pos.w;
			}

			// 5 bilinear taps covering the 4x4 Catmull-Rom footprint, with the
			// corners dropped (Jimenez, "Filmic SMAA")
			vec3 sample_history(vec2 uv, vec2 size) {
				vec2 position = uv * size;
				vec2 center = floor(position - 0.5) + 0.5;
				vec2 f = position - center;
				vec2 w0 = f * (-0.5 + f * (1.0 - 0.5 * f));
				vec2 w1 = 1.0 + f * f * (-2.5 + 1.5 * f);
				vec2 w2 = f * (0.5 + f * (2.0 - 1.5 * f));
				vec2 w3 = f * f * (-0.5 + 0.5 * f);
				vec2 w12 = w1 + w2;
				vec2 tc0 = (center - 1.0) / size;
				vec2 tc3 = (center + 2.0) / size;
				vec2 tc12 = (center + w2 / w12) / size;
				vec4 result =
					vec4(textureLod(TEXTURE(taa_data.history_tex), vec2(tc12.x, tc0.y), 0.0).rgb, 1.0) * (w12.x * w0.y) +
					vec4(textureLod(TEXTURE(taa_data.history_tex), vec2(tc0.x, tc12.y), 0.0).rgb, 1.0) * (w0.x * w12.y) +
					vec4(textureLod(TEXTURE(taa_data.history_tex), vec2(tc12.x, tc12.y), 0.0).rgb, 1.0) * (w12.x * w12.y) +
					vec4(textureLod(TEXTURE(taa_data.history_tex), vec2(tc3.x, tc12.y), 0.0).rgb, 1.0) * (w3.x * w12.y) +
					vec4(textureLod(TEXTURE(taa_data.history_tex), vec2(tc12.x, tc3.y), 0.0).rgb, 1.0) * (w12.x * w3.y);
				return max(result.rgb / result.a, vec3(0.0));
			}

			// pulls q toward the box's center until it is inside
			vec3 clip_to_box(vec3 box_min, vec3 box_max, vec3 q) {
				vec3 center = 0.5 * (box_max + box_min);
				vec3 extent = 0.5 * (box_max - box_min) + 1e-5;
				vec3 v = q - center;
				vec3 a = abs(v / extent);
				float m = max(a.x, max(a.y, a.z));
				return m > 1.0 ? center + v / m : q;
			}

			void main() {
				ivec2 size = textureSize(TEXTURE(taa_data.source_tex), 0);
				ivec2 pixel = ivec2(gl_FragCoord.xy);
				vec2 uv = (vec2(pixel) + 0.5) / vec2(size);
				float depth = texelFetch(TEXTURE(taa_data.depth_tex), pixel, 0).r;
				float view_depth = get_view_depth(uv, depth);

				if (taa_data.history_valid == 0) {
					set_color(vec4(texelFetch(TEXTURE(taa_data.source_tex), pixel, 0).rgb, view_depth));
					return;
				}

				float exposure = taa_data.exposure_tex != -1 ? texture(TEXTURE(taa_data.exposure_tex), vec2(0.5)).r : 1.0;

				// the neighbourhood's colour spread, the closest depth (so edges
				// move with the object in front), and this pixel's colour at its
				// unjittered center: sample p shows the scene at p - jitter, so its
				// distance from this pixel's center is offset - jitter
				vec3 m1 = vec3(0.0);
				vec3 m2 = vec3(0.0);
				vec3 current = vec3(0.0);
				float current_weight = 0.0;
				float closest_depth = 1.0;
				ivec2 closest_pixel = pixel;

				for (int y = -1; y <= 1; y++) {
					for (int x = -1; x <= 1; x++) {
						ivec2 p = clamp(pixel + ivec2(x, y), ivec2(0), size - 1);
						vec3 c = compress(texelFetch(TEXTURE(taa_data.source_tex), p, 0).rgb, exposure);
						m1 += c;
						m2 += c * c;
						vec2 d = vec2(x, y) - taa_data.jitter;
						float w = exp(-2.29 * dot(d, d));
						current += c * w;
						current_weight += w;
						float depth = texelFetch(TEXTURE(taa_data.depth_tex), p, 0).r;

						if (depth < closest_depth) {
							closest_depth = depth;
							closest_pixel = p;
						}
					}
				}

				current /= current_weight;

				// where the surface was last frame. the sky and a disabled
				// velocity buffer go through the cameras instead
				vec2 prev_uv;
				float expected_depth = -1.0;

				if (closest_depth < 1.0 && taa_data.velocity_tex != -1) {
					vec3 motion = texelFetch(TEXTURE(taa_data.velocity_tex), closest_pixel, 0).rgb;
					prev_uv = uv - motion.xy;
					expected_depth = motion.z;
				} else {
					vec4 view_pos = taa_data.inv_projection * vec4(uv * 2.0 - 1.0, closest_depth, 1.0);
					vec4 world_pos = taa_data.inv_view * (view_pos / view_pos.w);
					vec4 prev_clip = taa_data.prev_projection * taa_data.prev_view * vec4(world_pos.xyz, 1.0);
					prev_uv = prev_clip.xy / prev_clip.w * 0.5 + 0.5;
				}

				if (any(lessThan(prev_uv, vec2(0.0))) || any(greaterThan(prev_uv, vec2(1.0)))) {
					set_color(vec4(decompress(current, exposure), view_depth));
					return;
				}

				// a surface that was hidden last frame has a history of whatever
				// was in front of it, which sits at a different depth
				float history_weight = 1.0;

				if (expected_depth > 0.0) {
					vec4 history_depths = textureGather(TEXTURE(taa_data.history_tex), prev_uv, 3);
					vec4 difference = abs(history_depths - expected_depth) / expected_depth;
					float closest = min(min(difference.x, difference.y), min(difference.z, difference.w));
					history_weight = 1.0 - smoothstep(0.02, 0.1, closest);
				}

				vec3 mean = m1 / 9.0;
				vec3 sigma = sqrt(max(m2 / 9.0 - mean * mean, vec3(0.0)));
				vec3 history = compress(sample_history(prev_uv, vec2(size)), exposure);
				history = clip_to_box(mean - sigma, mean + sigma, history);
				vec3 result = mix(current, history, 0.9 * history_weight);
				set_color(vec4(decompress(result, exposure), view_depth));
			}
		]],
		},
		CullMode = "none",
		DepthTest = false,
		DepthWrite = false,
	},
}
