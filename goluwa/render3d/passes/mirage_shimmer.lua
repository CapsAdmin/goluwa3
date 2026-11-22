local render3d = import("goluwa/render3d/render3d.lua")
local gbuffer_layout = import("goluwa/render3d/gbuffer_layout.lua")
local glsl_common = import("goluwa/render3d/glsl_common.lua")
local post_source = import("goluwa/render3d/post_source.lua")
local screen_reconstruct = import("goluwa/render3d/screen_reconstruct.lua")
local screen_refraction = import("goluwa/render3d/screen_refraction.lua")
local mirage = import("goluwa/render3d/mirage.lua")
local GROUND_TAPS = 8
local GROUND_SEARCH_START = 0.25
local SKY_DISTANCE = 5000
local CELL_PIXELS = 4
return {
	{
		name = "mirage_shimmer",
		is_enabled = post_source.IsMirageActive,
		ColorFormat = {{"r16g16b16a16_sfloat", {"color", "rgba"}}},
		fragment = {
			uniform_buffers = {
				{
					name = "shimmer_data",
					binding_index = 2,
					block = {
						render3d.camera_block,
						gbuffer_layout.block,
						mirage.block,
						{"source_tex", "int"},
						{"heat_tex", "int"},
					},
					write = function(self, block)
						render3d.WriteCameraBlock(self, block)
						gbuffer_layout.WriteBlock(self, block)
						mirage.WriteBlock(self, block)
						block.source_tex = self:GetTextureIndex(post_source.GetSceneSourceTexture({name = "mirage_shimmer"}))
						block.heat_tex = self:GetTextureIndex(post_source.GetMirageHeatTexture())
						return block
					end,
				},
			},
			shader = glsl_common.GetNoiseGLSL() .. gbuffer_layout.GetDecodeGLSL("shimmer_data") .. screen_reconstruct.GetWorldPosFromUVGLSL("shimmer_data") .. screen_reconstruct.GetViewRayFromUVGLSL("shimmer_data") .. screen_refraction.GetGLSL("shimmer_data") .. mirage.GetGLSL("shimmer_data") .. [[
				ivec2 render_pixel(vec2 uv) {
					ivec2 size = textureSize(TEXTURE(shimmer_data.depth_tex), 0);
					return clamp(ivec2(uv * vec2(size)), ivec2(0), size - 1);
				}

				void main() {
					vec2 uv = in_uv;
					vec4 scene = texture(TEXTURE(shimmer_data.source_tex), uv);
					ivec2 pixel = render_pixel(uv);
					float depth = gbuffer_depth(pixel);
					vec3 camera = shimmer_data.camera_position;
					vec3 target = depth > 0.0 ? get_world_pos(uv, depth) : camera + get_view_ray(uv) * (]] .. SKY_DISTANCE .. [[.0 * shimmer_data.view_scale);
					float heat = texelFetch(TEXTURE(shimmer_data.heat_tex), pixel, 0).r;
					vec3 ground = target;
					vec3 normal = heat > 0.0 ? gbuffer_geometric_normal(pixel) : vec3(0.0, 1.0, 0.0);

					if (heat <= 0.0) {
						for (int i = 0; i < ]] .. GROUND_TAPS .. [[; i++) {
							vec3 below = screen_refraction_project(target - vec3(0.0, ]] .. GROUND_SEARCH_START .. [[ * exp2(float(i)) * shimmer_data.view_scale, 0.0));

							if (!screen_refraction_on_screen(below.xy)) break;

							ivec2 tap = render_pixel(below.xy);
							float tap_heat = texelFetch(TEXTURE(shimmer_data.heat_tex), tap, 0).r;

							if (tap_heat <= 0.0) continue;

							heat = tap_heat;
							ground = get_world_pos(below.xy, gbuffer_depth(tap));
							normal = gbuffer_geometric_normal(tap);
							break;
						}
					}

					float camera_height = dot(camera - ground, normal);

					if (heat <= 0.0 || camera_height <= 0.0) {
						set_color(scene);
						return;
					}

					float range = distance(camera, target);
					float meters = 1.0 / shimmer_data.view_scale;
					float angle = mirage_arrival_angle(mirage_path_cn2(heat, camera_height * meters, max(dot(target - ground, normal), 0.0) * meters, range * meters));
					float footprint = range * 2.0 / (abs(shimmer_data.projection[1][1]) * float(textureSize(TEXTURE(shimmer_data.source_tex), 0).y));
					float eddy_size = ]] .. string.format("%.9g", mirage.EDDY_SIZE) .. [[ * shimmer_data.view_scale;
					vec3 eddy = (camera + (target - camera) * (distance(camera, ground) / range) - mirage_drift(mirage_convective_velocity(heat))) / max(eddy_size, ]] .. CELL_PIXELS .. [[.0 * footprint);
					vec2 wobble = vec2(mirage_noise(eddy), mirage_noise(eddy + vec3(17.3, 41.1, 7.7))) * angle * min(eddy_size / footprint, 1.0);
					set_color(texture(TEXTURE(shimmer_data.source_tex), uv + wobble * vec2(shimmer_data.projection[0][0], shimmer_data.projection[1][1]) * 0.5));
				}
			]],
		},
		CullMode = "none",
		DepthTest = false,
		DepthWrite = false,
	},
}
