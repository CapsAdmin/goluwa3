local system = import("goluwa/system.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local gbuffer_layout = import("goluwa/render3d/gbuffer_layout.lua")
local post_source = import("goluwa/render3d/post_source.lua")
local screen_fields = import("goluwa/render3d/screen_fields.lua")
local screen_reconstruct = import("goluwa/render3d/screen_reconstruct.lua")
local MAX = screen_fields.MAX
local TAPS = 24
local SKY_DISTANCE = 500
return {
	{
		name = "screen_fields",
		is_enabled = post_source.IsScreenFieldsActive,
		ColorFormat = {{"r16g16b16a16_sfloat", {"color", "rgba"}}},
		fragment = {
			uniform_buffers = {
				{
					name = "sf_data",
					binding_index = 2,
					block = {
						render3d.camera_block,
						{"source_tex", "int"},
						{"depth_tex", "int"},
						{"count", "int"},
						{"time", "float"},
						post_source.pre_exposure_block,
						{"shape", "vec4", MAX},
						{"look", "vec4", MAX},
						{"grade", "vec4", MAX},
					},
					write = function(self, block)
						render3d.WriteCameraBlock(self, block)
						block.source_tex = self:GetTextureIndex(post_source.GetSceneSourceTexture({name = "screen_fields"}))
						block.depth_tex = self:GetTextureIndex(gbuffer_layout.GetDepthTexture())
						block.time = system.GetElapsedTime() % 1000
						post_source.WritePreExposureBlock(self, block)
						local fields = screen_fields.fields
						block.count = #fields

						for i, field in ipairs(fields) do
							local slot = i - 1
							local intensity = screen_fields.GetIntensity(field)
							block.shape[slot][0] = field.position.x
							block.shape[slot][1] = field.position.y
							block.shape[slot][2] = field.position.z
							block.shape[slot][3] = screen_fields.GetRadius(field)
							block.look[slot][0] = field.Thickness
							block.look[slot][1] = field.Blur
							block.look[slot][2] = field.Ring
							block.look[slot][3] = field.Aberration
							block.grade[slot][0] = field.Darken
							block.grade[slot][1] = field.Haze
							block.grade[slot][2] = field.Zoom
							block.grade[slot][3] = intensity
						end

						return block
					end,
				},
			},
			shader = post_source.GetCompressGLSL() .. screen_reconstruct.GetWorldPosFromUVGLSL("sf_data") .. screen_reconstruct.GetWorldRayGLSL("sf_data") .. [[
			const int TAPS = ]] .. TAPS .. [[;

			float hash21(vec2 p) {
				return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
			}

			vec2 project(vec3 world, out bool visible) {
				vec4 clip = sf_data.projection * sf_data.view * vec4(world, 1.0);
				visible = clip.w > 0.0001;
				return clip.xy / max(clip.w, 0.0001) * 0.5 + 0.5;
			}

			void main() {
				ivec2 size = textureSize(TEXTURE(sf_data.source_tex), 0);
				vec2 uv = in_uv;
				float aspect = float(size.x) / float(size.y);
				float depth = texelFetch(TEXTURE(sf_data.depth_tex), ivec2(gl_FragCoord.xy), 0).r;
				vec3 world = depth > 0.0 ? get_world_pos(uv, depth) : sf_data.camera_position + get_world_ray() * ]] .. SKY_DISTANCE .. [[.0;
				vec2 offset = vec2(0.0);
				vec2 blur = vec2(0.0);
				vec2 chroma = vec2(0.0);
				float darken = 0.0;
				float jitter = hash21(gl_FragCoord.xy);

				for (int i = 0; i < sf_data.count; i++) {
					vec4 shape = sf_data.shape[i];
					vec4 look = sf_data.look[i];
					vec4 grade = sf_data.grade[i];
					float intensity = grade.w;
					float thickness = max(look.x * shape.w, 0.05);
					float dist = length(world - shape.xyz);
					float inside = 1.0 - smoothstep(shape.w - thickness, shape.w + thickness, dist);
					float shell_x = (dist - shape.w) / thickness;
					float shell = exp(-shell_x * shell_x);
					bool visible;
					vec2 center = project(shape.xyz, visible);
					vec2 delta = (uv - center) * vec2(aspect, 1.0);
					float length_delta = length(delta);
					vec2 outward = length_delta > 1e-5 ? delta / length_delta / vec2(aspect, 1.0) : vec2(0.0);

					if (!visible) outward = vec2(0.0);

					blur += outward * look.y * intensity * inside / float(size.y);
					offset += outward * look.z * intensity * shell;
					offset -= (uv - center) * grade.z * intensity * inside;
					offset += vec2(sin(uv.y * 70.0 + sf_data.time * 7.0) + sin(uv.y * 23.0 - sf_data.time * 4.0), cos(uv.x * 60.0 + sf_data.time * 6.0)) * grade.y * intensity * inside * 0.003;
					chroma += outward * look.w * intensity * (shell + inside * 0.3) / float(size.y);
					darken = max(darken, grade.x * intensity * (1.0 - inside));
				}

				vec2 base = uv + offset;
				float exposure = sf_data.pre_exposure_tex != -1 ? ]] .. string.format("%.1f", post_source.PRE_EXPOSURE_HEADROOM) .. [[ : 1.0;
				vec3 sum = vec3(0.0);

				for (int i = 0; i < TAPS; i++) {
					float t = (float(i) + jitter) / float(TAPS) - 0.5;
					vec2 sample_uv = base + blur * t;
					vec3 tap = vec3(
						texture(TEXTURE(sf_data.source_tex), sample_uv + chroma * 0.5).r,
						texture(TEXTURE(sf_data.source_tex), sample_uv).g,
						texture(TEXTURE(sf_data.source_tex), sample_uv - chroma * 0.5).b
					);
					sum += compress(tap, exposure);
				}

				vec3 color = decompress(sum / float(TAPS), exposure);
				float luminance = dot(color, vec3(0.2126, 0.7152, 0.0722));
				color = mix(color, vec3(luminance) * 0.25, darken);
				set_color(vec4(color, texelFetch(TEXTURE(sf_data.source_tex), ivec2(gl_FragCoord.xy), 0).a));
			}
		]],
		},
		CullMode = "none",
		DepthTest = false,
		DepthWrite = false,
	},
}
