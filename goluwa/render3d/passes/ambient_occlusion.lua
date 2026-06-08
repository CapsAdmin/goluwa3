local Vec3 = import("goluwa/structs/vec3.lua")
local assets = import("goluwa/assets.lua")
local system = import("goluwa/system.lua")
local render = import("goluwa/render/render.lua")
local Texture = import("goluwa/render/texture.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local compute_helpers = import("goluwa/render3d/compute_helpers.lua")
local screen_reconstruct = import("goluwa/render3d/screen_reconstruct.lua")
local COMPUTE_LOCAL_SIZE = {x = 8, y = 8, z = 1}
local SSAO_KERNEL = {}

for i = 1, 64 do
	math.randomseed(i)
	local sample = Vec3(math.random() * 2 - 1, math.random() * 2 - 1, math.random()):Normalize()
	sample = sample * math.random()
	local scale = (i - 1) / 64
	scale = math.lerp(0.1, 1.0, scale * scale)
	SSAO_KERNEL[i] = sample * scale
end

return {
	{
		name = "ambient_occlusion",
		ComputePass = true,
		ColorFormat = {
			{"r32_sfloat", {"color", "r"}},
		},
		framebuffer_count = 1,
		LocalSize = COMPUTE_LOCAL_SIZE,
		storage_images = {
			{
				binding_index = 0,
				attachment = 1,
				dst_stage = "fragment",
			},
		},
		uniform_buffers = {
			{
				name = "lighting_data",
				binding_index = 3,
				block = {
					render3d.camera_block,
					{"ssao_kernel", "vec3", 64},
					{"blue_noise_tex", "int"},
					render3d.gbuffer_block,
				},
				write = function(self, block)
					render3d.WriteCameraBlock(self, block)

					for i, sample in ipairs(SSAO_KERNEL) do
						sample:CopyToFloatPointer(block.ssao_kernel[i - 1])
					end

					block.blue_noise_tex = self:GetTextureIndex(assets.GetTexture("textures/render/blue_noise.lua"))
					render3d.WriteGBufferBlock(self, block)
					return block
				end,
			},
		},
		custom_declarations = [[
			layout(set = 0, binding = 0, r32f) uniform writeonly image2D out_color;
			]],
		shader = [[
            vec2 in_uv;

			]] .. compute_helpers.GetScreenHelpersGLSL() .. [[
            ]] .. screen_reconstruct.GetWorldPosGLSL("lighting_data") .. [[

			vec2 get_compute_uv() {
				return get_screen_uv(get_screen_pos(), imageSize(out_color));
			}


			void set_color(float value) {
				imageStore(out_color, get_screen_pos(), vec4(value,0,0,1));
			}

			float get_depth() {
				return texture(TEXTURE(lighting_data.depth_tex), in_uv).r;
			}

			vec3 get_normal() {
				return texture(TEXTURE(lighting_data.normal_tex), in_uv).xyz;
			}

            float get_alpha() {
				return texture(TEXTURE(lighting_data.albedo_tex), in_uv).a;
			}

			float get_ambient_occlusion(vec2 uv, vec3 world_pos, vec3 N) {
				vec3 p = (lighting_data.view * vec4(world_pos, 1.0)).xyz;
				vec3 V = normalize(-p);
				vec3 view_normal = normalize(mat3(lighting_data.view) * N);

				ivec2 screen_size = textureSize(TEXTURE(lighting_data.depth_tex), 0);
				ivec2 pixel = ivec2(uv * vec2(screen_size));
				ivec2 noise_size = textureSize(TEXTURE(lighting_data.blue_noise_tex), 0);
				vec2 noise = texelFetch(TEXTURE(lighting_data.blue_noise_tex), pixel % noise_size, 0).rg;
				
				float random_offset = noise.x;
				float random_rotation = noise.y * 6.28318;

				float world_radius = 2.0;
				// radius_uv = (world_radius * focal_length / -p.z) * 0.5
				float screen_radius = (world_radius * lighting_data.projection[0][0]) / (-p.z * 2.0);

				const int Nd = 4; // Slices
				const int Ns = 12; // Steps per side
				const uint Nb = 32;
				float thickness = 0.025; 
				float bias = 0.2;

				float total_ao = 0.0;
				float total_weight = 0.0;

				for (int i = 0; i < Nd; i++) {
					float angle = (float(i) / float(Nd)) * 3.14159 + random_rotation;
					vec2 dir = vec2(cos(angle), sin(angle));
					
					vec4 dir_v = lighting_data.inv_projection * vec4(dir, 0.0, 0.0);
					vec3 T_v = normalize(dir_v.xyz);
					T_v = normalize(T_v - V * dot(T_v, V));

					vec3 M = cross(V, T_v);
					vec3 n_proj = view_normal - M * dot(view_normal, M);
					float n_proj_len = length(n_proj);
					
					float weight = max(0.0, n_proj_len);
					if (weight < 0.001) continue;
					
					float theta_n = atan(dot(n_proj, T_v), dot(n_proj, V));

					uint bi = 0u;
					for (int j = 0; j < Ns; j++) {
						// Exponential stepping for better local detail
						float o = (float(j) + random_offset) / float(Ns);
						float step_dist = o * o * screen_radius;
						
						for (float side = -1.0; side <= 1.0; side += 2.0) {
							if (side == 0.0) continue;
							vec2 sample_uv = uv + dir * step_dist * side;
							
							if (sample_uv.x < 0.0 || sample_uv.x > 1.0 || sample_uv.y < 0.0 || sample_uv.y > 1.0) continue;

							float sample_depth = texture(TEXTURE(lighting_data.depth_tex), sample_uv).r;
							vec4 sample_clip_pos = vec4(sample_uv * 2.0 - 1.0, sample_depth, 1.0);
							vec4 sample_view_pos = lighting_data.inv_projection * sample_clip_pos;
							vec3 sf = sample_view_pos.xyz / sample_view_pos.w;
							
							vec3 v_f = sf - p;
							float dist2 = dot(v_f, v_f);
							
							if (dist2 > world_radius * world_radius || dist2 < 0.0001) continue;
							
							float proj_T = dot(v_f, T_v);
							float proj_V = dot(v_f, V);
							
							// Skip samples that are too close to the surface or behind it to avoid self-occlusion
							if (proj_V < bias) continue;

							float theta_f = atan(proj_T, proj_V);
							// Thickness model: assume sample has a fixed thickness along the view vector
							float theta_b = atan(proj_T, proj_V - thickness);
							
							float diff_f = theta_f - theta_n;
							if (diff_f > 3.14159) diff_f -= 6.28318;
							if (diff_f < -3.14159) diff_f += 6.28318;
							
							float diff_b = theta_b - theta_n;
							if (diff_b > 3.14159) diff_b -= 6.28318;
							if (diff_b < -3.14159) diff_b += 6.28318;

							float theta_min = clamp(min(diff_f, diff_b), -1.5708, 1.5708);
							float theta_max = clamp(max(diff_f, diff_b), -1.5708, 1.5708);
							
							uint a = uint(floor((theta_min + 1.5708) / 3.14159 * float(Nb)));
							uint b = uint(ceil((theta_max + 1.5708) / 3.14159 * float(Nb)));
							
							a = clamp(a, 0u, Nb);
							b = clamp(b, 0u, Nb);

							if (b > a) {
								uint count = b - a;
								uint mask = (count >= 32u) ? 0xFFFFFFFFu : ((1u << count) - 1u) << a;
								bi |= mask;
							}
						}
					}
					total_ao += (1.0 - float(bitCount(bi)) / float(Nb)) * weight;
					total_weight += weight;
				}

				float ao = (total_weight > 0.001) ? (total_ao / total_weight) : 1.0;
				return pow(clamp(ao, 0.0, 1.0), 1);
			}

			void main() {
				ivec2 pos = get_screen_pos();
				ivec2 size = imageSize(out_color);

				if (!is_screen_pos_in_bounds(pos, size)) return;
				in_uv = get_compute_uv();

				float depth = get_depth();

				if (depth == 1.0) {
					set_color(1);
					return;
				}

				float alpha = get_alpha();

				if (alpha == 0.0) {
					set_color(1);
					return;
				}

				vec3 N = get_normal();
				vec3 world_pos = get_world_pos(depth);
                float ao = get_ambient_occlusion(in_uv, world_pos, N); 
                set_color(ao);
			}
		]],
	},
}
