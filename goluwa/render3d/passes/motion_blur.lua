local system = import("goluwa/system.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local gbuffer_layout = import("goluwa/render3d/gbuffer_layout.lua")
local post_source = import("goluwa/render3d/post_source.lua")
local pvars = import("goluwa/cli/pvars.lua")
local screen_reconstruct = import("goluwa/render3d/screen_reconstruct.lua")
local SAMPLES = 16
local PROBES = 8
pvars.StartGroup("Post", "Motion blur", {store = false, prefix = "motion_blur_"})
render3d.motion_blur_enabled = pvars.Setup2{
	key = "r_motion_blur",
	default = true,
	help = "blur along each pixel's screen motion, from the velocity buffer",
}
local shutter = pvars.Setup2{
	key = "r_motion_blur_shutter",
	default = 1 / 60,
	min = 0.002,
	max = 0.1,
	help = "how long the virtual shutter stays open in seconds. the blur is the motion over the frame times shutter / frame time, so a low framerate smears each step instead of showing it",
}
local max_length = pvars.Setup2{
	key = "r_motion_blur_max",
	default = 40,
	min = 4,
	max = 160,
	help = "the longest blur in pixels",
}
pvars.EndGroup()
return {
	{
		name = "motion_blur",
		is_enabled = function()
			return render3d.motion_blur_enabled:Get()
		end,
		ColorFormat = {{"r16g16b16a16_sfloat", {"color", "rgba"}}},
		fragment = {
			uniform_buffers = {
				{
					name = "mb_data",
					binding_index = 2,
					block = {
						render3d.camera_block,
						render3d.prev_camera_block,
						{"source_tex", "int"},
						{"depth_tex", "int"},
						{"velocity_tex", "int"},
						post_source.pre_exposure_block,
						{"blur_scale", "float"},
						{"max_length", "float"},
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
						post_source.WritePreExposureBlock(self, block)
						block.blur_scale = shutter:Get() / math.max(system.GetFrameTime(), 0.0001)
						block.max_length = max_length:Get()
						block.frame = system.GetFrameNumber()
						return block
					end,
				},
			},
			shader = [[
]] .. post_source.GetCompressGLSL() .. post_source.GetPreExposureGLSL("mb_data") .. [[

]] .. screen_reconstruct.GetViewRayFromUVGLSL("mb_data") .. [[

]] .. screen_reconstruct.GetViewDepthGLSL("mb_data") .. screen_reconstruct.GetViewPosGLSL("mb_data") .. [[

			const int SAMPLES = ]] .. SAMPLES .. [[;
			const int PROBES = ]] .. PROBES .. [[;

			ivec2 size;
			float exposure;

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

					if (prev_clip.w <= 0.0001) return vec2(0.0);

					motion = uv - (prev_clip.xy / prev_clip.w * 0.5 + 0.5);
				}

				vec2 blur = motion * vec2(size) * mb_data.blur_scale;
				float len = length(blur);
				float keep = smoothstep(1.0, 2.5, len) * min(mb_data.max_length / max(len, 1e-4), 1.0);
				return blur * keep;
			}

			float cone(float dist, float len) {
				return clamp(1.0 - dist / max(len, 1e-4), 0.0, 1.0);
			}

			float cylinder(float dist, float len) {
				return 1.0 - smoothstep(0.95 * len, 1.05 * len, dist);
			}

			void main() {
				size = textureSize(TEXTURE(mb_data.source_tex), 0);
				ivec2 pixel = ivec2(gl_FragCoord.xy);
				vec2 uv = (vec2(pixel) + 0.5) / vec2(size);
				exposure = mb_data.pre_exposure_tex != -1 ? ]] .. string.format("%.1f", post_source.PRE_EXPOSURE_HEADROOM) .. [[ : 1.0;
				vec4 center = texelFetch(TEXTURE(mb_data.source_tex), pixel, 0);
				float center_depth = texelFetch(TEXTURE(mb_data.depth_tex), pixel, 0).r;
				vec2 center_blur = get_blur(pixel, center_depth);
				float center_z = get_view_depth(uv, center_depth);

				vec2 direction = center_blur;
				float probe_radius = 0.5 * mb_data.max_length;

				for (int i = 0; i < PROBES; i++) {
					float angle = 6.2831853 * (float(i) + 0.5) / float(PROBES);
					vec2 offset = vec2(cos(angle), sin(angle)) * probe_radius;
					ivec2 p = clamp(pixel + ivec2(offset), ivec2(0), size - 1);
					vec2 blur = get_blur(p, texelFetch(TEXTURE(mb_data.depth_tex), p, 0).r);

					if (length(blur) > length(direction) && length(blur) > probe_radius) direction = blur;
				}

				float len = length(direction);

				if (len < 1.0) {
					set_color(center);
					return;
				}

				float noise = fract(52.9829189 * fract(dot(gl_FragCoord.xy, vec2(0.06711056, 0.00583715)) + float(mb_data.frame % 8) * 0.618034)) - 0.5;
				vec3 sum = vec3(0.0);
				float total = 0.0;
				float center_weight = float(SAMPLES) / max(len, 1.0);
				sum += compress(center.rgb, exposure) * center_weight;
				total += center_weight;

				for (int i = 0; i < SAMPLES; i++) {
					float t = (float(i) + 0.5 + noise) / float(SAMPLES) - 0.5;
					ivec2 p = clamp(pixel + ivec2(round(direction * t)), ivec2(0), size - 1);
					float dist = abs(t) * len;
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
