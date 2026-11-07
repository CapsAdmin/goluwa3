local system = import("goluwa/system.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local gbuffer_layout = import("goluwa/render3d/gbuffer_layout.lua")
local post_source = import("goluwa/render3d/post_source.lua")
local pvars = import("goluwa/cli/pvars.lua")
local screen_reconstruct = import("goluwa/render3d/screen_reconstruct.lua")
local exposure_model = import("goluwa/render3d/exposure.lua")
local MIN_SAMPLES = 8
local MAX_SAMPLES = 48
local TILE = 16
pvars.StartGroup("Post", "Motion blur", {store = false, prefix = "motion_blur_"})
render3d.motion_blur_enabled = pvars.Setup2{
	key = "r_motion_blur",
	default = true,
	help = "blur along each pixel's screen motion, from the velocity buffer",
}
local max_length = pvars.Setup2{
	key = "r_motion_blur_max",
	default = 40,
	min = 4,
	max = 160,
	help = "the longest blur in pixels",
}
local trailing = pvars.Setup2{
	key = "r_motion_blur_trailing",
	default = true,
	help = "blur only behind what moves, like a shutter that closes on the frame, so the leading edge stays at its true position. Off blurs both ways around the frame, which stretches things ahead of where they are",
}
pvars.EndGroup()

local function is_enabled()
	return render3d.motion_blur_enabled:Get()
end

local function get_tile_texture(name)
	return render3d.pipelines[name]:GetFramebuffer():GetAttachment(1)
end

local function uniform_buffer(binding_index, tile_textures)
	return {
		name = "mb_data",
		binding_index = binding_index,
		block = {
			render3d.camera_block,
			render3d.prev_camera_block,
			{"source_tex", "int"},
			{"depth_tex", "int"},
			{"velocity_tex", "int"},
			{"translucent_motion_tex", "int"},
			{"tiles_tex", "int"},
			{"neighbors_tex", "int"},
			post_source.pre_exposure_block,
			exposure_model.camera_block,
			{"frame_time", "float"},
			{"max_length", "float"},
			{"trailing", "int"},
			{"frame", "int"},
		},
		write = function(self, block)
			render3d.WriteCameraBlock(self, block)
			render3d.WritePreviousCameraBlock(self, block)
			block.source_tex = self:GetTextureIndex(post_source.GetSceneSourceTexture({name = "motion_blur"}))
			block.depth_tex = self:GetTextureIndex(gbuffer_layout.GetDepthTexture())
			block.velocity_tex = render3d.velocity_enabled:Get() and
				self:GetTextureIndex(gbuffer_layout.GetTexture("velocity")) or
				-1
			block.translucent_motion_tex = render3d.IsPassEnabled("translucent") and
				self:GetTextureIndex(render3d.pipelines.translucent_accumulate:GetFramebuffer():GetAttachment(2)) or
				-1
			block.tiles_tex = tile_textures and
				self:GetTextureIndex(get_tile_texture("motion_blur_tiles")) or
				-1
			block.neighbors_tex = tile_textures and
				self:GetTextureIndex(get_tile_texture("motion_blur_neighbors")) or
				-1
			post_source.WritePreExposureBlock(self, block)
			exposure_model.WriteCameraBlock(block)
			block.frame_time = math.max(system.GetFrameTime(), 0.0001)
			block.max_length = max_length:Get()
			block.trailing = trailing:Get() and 1 or 0
			block.frame = system.GetFrameNumber()
			return block
		end,
	}
end

local BLUR_GLSL = post_source.GetPreExposureGLSL("mb_data") .. exposure_model.GetCameraSettingsGLSL("mb_data") .. screen_reconstruct.GetViewRayFromUVGLSL("mb_data") .. screen_reconstruct.GetViewDepthGLSL("mb_data") .. screen_reconstruct.GetViewPosGLSL("mb_data") .. [[
			const int TILE = ]] .. TILE .. [[;

			ivec2 size;
			float exposure;
			float blur_scale;

			vec2 get_blur(ivec2 pixel, float depth) {
				pixel = clamp(pixel, ivec2(0), size - 1);
				vec2 motion;

				if (depth > 0.0 && mb_data.velocity_tex != -1) {
					motion = texelFetch(TEXTURE(mb_data.velocity_tex), pixel, 0).xy;
				} else {
					vec2 uv = (vec2(pixel) + 0.5) / vec2(size);
					vec4 prev_clip;

					if (depth > 0.0) {
						vec4 world_pos = mb_data.inv_view * vec4(get_view_pos(uv, depth), 1.0);
						prev_clip = mb_data.prev_projection * mb_data.prev_view * vec4(world_pos.xyz, 1.0);
					} else {
						prev_clip = mb_data.prev_projection * mat4(mat3(mb_data.prev_view)) * vec4(get_view_ray(uv), 1.0);
					}

					motion = prev_clip.w <= 0.0001 ? vec2(0.0) : uv - (prev_clip.xy / prev_clip.w * 0.5 + 0.5);
				}

				if (mb_data.translucent_motion_tex != -1) {
					vec4 translucent = texelFetch(TEXTURE(mb_data.translucent_motion_tex), pixel, 0);
					float coverage = min(translucent.b, 1.0);

					if (coverage > 0.0) motion = mix(motion, translucent.rg / translucent.b, coverage);
				}

				vec2 blur = motion * vec2(size) * blur_scale;
				float len = length(blur);
				float keep = smoothstep(1.0, 2.5, len) * min(mb_data.max_length / max(len, 1e-4), 1.0);
				return blur * keep;
			}


			void init_blur() {
				size = textureSize(TEXTURE(mb_data.source_tex), 0);
				blur_scale = mb_data.pre_exposure_tex != -1 ? camera_settings(get_exposure()).z / mb_data.frame_time : 1.0;
			}
]]
return {
	{
		-- the longest blur of each tile, so the blur pass finds what reaches a pixel in a few cached reads instead of probing the full res buffers
		name = "motion_blur_tiles",
		is_enabled = is_enabled,
		ComputePass = true,
		ColorFormat = {{"r16g16_sfloat", {"blur", "rg"}}},
		framebuffer_count = 1,
		scale = 1 / TILE,
		LocalSize = {x = TILE, y = TILE, z = 1},
		storage_images = {{binding_index = 0, attachment = 1, dst_stage = {"compute", "fragment"}}},
		uniform_buffers = {uniform_buffer(3, false)},
		on_draw = function(self, cmd, fb, frame, desc)
			self:UploadConstants()
			self.pipeline:DispatchForSize(cmd, fb.width * TILE, fb.height * TILE, 1, desc, self.dynamic_offsets)
		end,
		custom_declarations = [[
			layout(set = 0, binding = 0, rg16f) uniform writeonly image2D out_tiles;
		]],
		shader = BLUR_GLSL .. [[
			shared vec2 s_blur[TILE * TILE];

			void main() {
				init_blur();
				ivec2 tile = ivec2(gl_WorkGroupID.xy);
				ivec2 tiles = imageSize(out_tiles);
				ivec2 local_id = ivec2(gl_LocalInvocationID.xy);
				ivec2 first = tile * TILE;
				// the scaled image rounds its size, so the last row and column of tiles take the remaining pixels
				ivec2 last = mix(min(first + TILE, size), size, equal(tile, tiles - 1));
				vec2 best = vec2(0.0);

				for (int y = first.y + local_id.y; y < last.y; y += TILE) {
					for (int x = first.x + local_id.x; x < last.x; x += TILE) {
						ivec2 pixel = ivec2(x, y);
						vec2 blur = get_blur(pixel, texelFetch(TEXTURE(mb_data.depth_tex), pixel, 0).r);

						if (dot(blur, blur) > dot(best, best)) best = blur;
					}
				}

				uint index = gl_LocalInvocationIndex;
				s_blur[index] = best;
				barrier();

				for (uint stride = TILE * TILE / 2; stride > 0u; stride >>= 1u) {
					if (index < stride) {
						vec2 other = s_blur[index + stride];

						if (dot(other, other) > dot(s_blur[index], s_blur[index])) s_blur[index] = other;
					}

					barrier();
				}

				if (index == 0u) imageStore(out_tiles, tile, vec4(s_blur[0], 0.0, 0.0));
			}
		]],
	},
	{
		name = "motion_blur_neighbors",
		is_enabled = is_enabled,
		ComputePass = true,
		ColorFormat = {{"r16g16_sfloat", {"blur", "rg"}}},
		framebuffer_count = 1,
		scale = 1 / TILE,
		LocalSize = {x = 8, y = 8, z = 1},
		storage_images = {{binding_index = 0, attachment = 1, dst_stage = "fragment"}},
		uniform_buffers = {
			{
				name = "neighbor_data",
				binding_index = 3,
				block = {
					{"tiles_tex", "int"},
					{"max_length", "float"},
					{"trailing", "int"},
				},
				write = function(self, block)
					block.tiles_tex = self:GetTextureIndex(get_tile_texture("motion_blur_tiles"))
					block.max_length = max_length:Get()
					block.trailing = trailing:Get() and 1 or 0
					return block
				end,
			},
		},
		custom_declarations = [[
			layout(set = 0, binding = 0, rg16f) uniform writeonly image2D out_neighbors;
		]],
		shader = [[
			const int TILE = ]] .. TILE .. [[;

			void main() {
				ivec2 tile = ivec2(gl_GlobalInvocationID.xy);
				ivec2 tiles = imageSize(out_neighbors);

				if (any(greaterThanEqual(tile, tiles))) return;

				int radius = int(ceil(neighbor_data.max_length / float(TILE)));
				float reach_scale = neighbor_data.trailing != 0 ? 1.0 : 2.0;
				vec2 best = vec2(0.0);

				for (int y = max(tile.y - radius, 0); y <= min(tile.y + radius, tiles.y - 1); y++) {
					for (int x = max(tile.x - radius, 0); x <= min(tile.x + radius, tiles.x - 1); x++) {
						vec2 blur = texelFetch(TEXTURE(neighbor_data.tiles_tex), ivec2(x, y), 0).xy;
						float gap = length(vec2(max(abs(ivec2(x, y) - tile) - 1, ivec2(0)))) * float(TILE);

						if (dot(blur, blur) > dot(best, best) && gap * reach_scale <= length(blur)) best = blur;
					}
				}

				imageStore(out_neighbors, tile, vec4(best, 0.0, 0.0));
			}
		]],
	},
	{
		name = "motion_blur",
		is_enabled = is_enabled,
		ColorFormat = {{"r16g16b16a16_sfloat", {"color", "rgba"}}},
		fragment = {
			uniform_buffers = {uniform_buffer(2, true)},
			shader = post_source.GetCompressGLSL() .. BLUR_GLSL .. [[
			const int MIN_SAMPLES = ]] .. MIN_SAMPLES .. [[;
			const int MAX_SAMPLES = ]] .. MAX_SAMPLES .. [[;

			float cone(float dist, float len) {
				return clamp(1.0 - dist / max(len, 1e-4), 0.0, 1.0);
			}

			float cylinder(float dist, float len) {
				return 1.0 - smoothstep(0.95 * len, 1.05 * len, dist);
			}

			void main() {
				init_blur();
				ivec2 pixel = ivec2(gl_FragCoord.xy);
				vec2 uv = (vec2(pixel) + 0.5) / vec2(size);
				exposure = mb_data.pre_exposure_tex != -1 ? ]] .. string.format("%.1f", post_source.PRE_EXPOSURE_HEADROOM) .. [[ : 1.0;
				vec4 center = texelFetch(TEXTURE(mb_data.source_tex), pixel, 0);
				float center_depth = texelFetch(TEXTURE(mb_data.depth_tex), pixel, 0).r;
				vec2 center_blur = get_blur(pixel, center_depth);
				float center_z = get_view_depth(uv, center_depth);

				float jitter = fract(52.9829189 * fract(dot(gl_FragCoord.xy, vec2(0.06711056, 0.00583715)) + float(mb_data.frame % 8) * 0.618034));
				float reach_scale = mb_data.trailing != 0 ? 1.0 : 2.0;
				vec2 direction = center_blur;
				ivec2 tiles = textureSize(TEXTURE(mb_data.tiles_tex), 0);
				ivec2 tile = min(pixel / TILE, tiles - 1);

				if (length(texelFetch(TEXTURE(mb_data.neighbors_tex), tile, 0).xy) >= 1.0) {
					int radius = int(ceil(mb_data.max_length / float(TILE)));
					vec2 pixel_center = vec2(pixel) + 0.5;

					for (int y = max(tile.y - radius, 0); y <= min(tile.y + radius, tiles.y - 1); y++) {
						for (int x = max(tile.x - radius, 0); x <= min(tile.x + radius, tiles.x - 1); x++) {
							vec2 blur = texelFetch(TEXTURE(mb_data.tiles_tex), ivec2(x, y), 0).xy;
							float blur_len = length(blur);
							float dist = length(max(abs(pixel_center - (vec2(x, y) + 0.5) * float(TILE)) - 0.5 * float(TILE), vec2(0.0)));

							if (blur_len > length(direction) && dist * reach_scale <= blur_len) direction = blur;
						}
					}
				}

				float len = length(direction);

				if (len < 1.0) {
					set_color(center);
					return;
				}

				int count = clamp(int(ceil(len * 0.5)), MIN_SAMPLES, MAX_SAMPLES);
				float shift = mb_data.trailing != 0 ? 0.0 : 0.5;
				float noise = jitter - 0.5;
				vec3 sum = vec3(0.0);
				float total = 0.0;
				float center_weight = float(count) / max(len, 1.0);
				sum += compress(center.rgb, exposure) * center_weight;
				total += center_weight;

				for (int i = 0; i < count; i++) {
					float t = (float(i) + 0.5 + noise) / float(count) - shift;
					ivec2 p = clamp(pixel + ivec2(round(direction * t)), ivec2(0), size - 1);
					float dist = abs(t) * len * reach_scale;
					float depth = texelFetch(TEXTURE(mb_data.depth_tex), p, 0).r;
					float z = get_view_depth((vec2(p) + 0.5) / vec2(size), depth);
					float extent = 0.1 * center_z + 0.1;
					float in_front = clamp(1.0 - (z - center_z) / extent, 0.0, 1.0);
					float behind = clamp(1.0 - (center_z - z) / extent, 0.0, 1.0);
					float sample_len = length(get_blur(p, depth));
					float weight = in_front * cone(dist, sample_len) +
						behind * cone(dist, length(center_blur)) +
						2.0 * cylinder(dist, sample_len) * cylinder(dist, length(center_blur));
					sum += compress(texelFetch(TEXTURE(mb_data.source_tex), p, 0).rgb, exposure) * weight;
					total += weight;
				}

				set_color(vec4(decompress(sum / total, exposure), center.a));
			}
		]],
		},
		CullMode = "none",
		DepthTest = false,
		DepthWrite = false,
	},
}
