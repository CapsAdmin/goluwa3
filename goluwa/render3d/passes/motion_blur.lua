local system = import("goluwa/system.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local gbuffer_layout = import("goluwa/render3d/gbuffer_layout.lua")
local post_source = import("goluwa/render3d/post_source.lua")
local pvars = import("goluwa/cli/pvars.lua")
local screen_reconstruct = import("goluwa/render3d/screen_reconstruct.lua")
local exposure_model = import("goluwa/render3d/exposure.lua")
local MIN_SAMPLES = 8
local MAX_SAMPLES = 48
local PROBES = 16
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
						{"translucent_motion_tex", "int"},
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
						post_source.WritePreExposureBlock(self, block)
						exposure_model.WriteCameraBlock(block)
						block.frame_time = math.max(system.GetFrameTime(), 0.0001)
						block.max_length = max_length:Get()
						block.trailing = trailing:Get() and 1 or 0
						block.frame = system.GetFrameNumber()
						return block
					end,
				},
			},
			shader = [[
]] .. post_source.GetCompressGLSL() .. post_source.GetPreExposureGLSL("mb_data") .. exposure_model.GetCameraSettingsGLSL("mb_data") .. [[

]] .. screen_reconstruct.GetViewRayFromUVGLSL("mb_data") .. [[

]] .. screen_reconstruct.GetViewDepthGLSL("mb_data") .. screen_reconstruct.GetViewPosGLSL("mb_data") .. [[

			const int MIN_SAMPLES = ]] .. MIN_SAMPLES .. [[;
			const int MAX_SAMPLES = ]] .. MAX_SAMPLES .. [[;
			const int PROBES = ]] .. PROBES .. [[;

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

			float cone(float dist, float len) {
				return clamp(1.0 - dist / max(len, 1e-4), 0.0, 1.0);
			}

			float cylinder(float dist, float len) {
				return 1.0 - smoothstep(0.95 * len, 1.05 * len, dist);
			}

			void main() {
				size = textureSize(TEXTURE(mb_data.source_tex), 0);
				blur_scale = mb_data.pre_exposure_tex != -1 ? camera_settings(get_exposure()).z / mb_data.frame_time : 1.0;
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

				for (int i = 0; i < PROBES; i++) {
					float f = (float(i) + 0.5) / float(PROBES);
					float angle = 2.39996323 * float(i) + 6.2831853 * jitter;
					float dist = mb_data.max_length * f * f;
					ivec2 p = clamp(pixel + ivec2(vec2(cos(angle), sin(angle)) * dist), ivec2(0), size - 1);
					vec2 blur = get_blur(p, texelFetch(TEXTURE(mb_data.depth_tex), p, 0).r);
					float blur_len = length(blur);

					if (blur_len > length(direction) && dist * reach_scale <= blur_len) direction = blur;
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
