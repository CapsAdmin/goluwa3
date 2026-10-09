local assets = import("goluwa/assets.lua")
local system = import("goluwa/system.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local ambient_occlusion = import("goluwa/render3d/ambient_occlusion.lua")
local post_source = import("goluwa/render3d/post_source.lua")
local gbuffer_layout = import("goluwa/render3d/gbuffer_layout.lua")
local compute_helpers = import("goluwa/render3d/compute_helpers.lua")
local screen_reconstruct = import("goluwa/render3d/screen_reconstruct.lua")
local COMPUTE_LOCAL_SIZE = {x = 8, y = 8, z = 1}
local BIT_COUNT = 32
local SCALE = 0.5
local RATIO = math.floor(1 / SCALE + 0.5)
local BLUR_DISTANCE_SIGMA = 2
local BLUR_DEPTH_SIGMA = 0.02
local BLUR_NORMAL_POWER = 8
local BENT_COS_SQUARED = {}
local BENT_COS_SIN = {}

for k = 0, BIT_COUNT - 1 do
	local angle = (k + 0.5) / BIT_COUNT * math.pi - math.pi / 2
	BENT_COS_SQUARED[k + 1] = string.format("%.7f", math.cos(angle) ^ 2)
	BENT_COS_SIN[k + 1] = string.format("%.7f", math.cos(angle) * math.sin(angle))
end

return {
	{
		name = "ambient_occlusion",
		ComputePass = true,
		ColorFormat = {
			{"r16g16b16a16_sfloat", {"bounce_ao", "rgba"}},
			{"r16g16b16a16_sfloat", {"bent_normal", "rgba"}},
		},
		framebuffer_count = 1,
		scale = SCALE,
		LocalSize = COMPUTE_LOCAL_SIZE,
		storage_images = {
			{
				binding_index = 0,
				attachment = 1,
				dst_stage = "compute",
			},
			{
				binding_index = 1,
				attachment = 2,
				dst_stage = "compute",
			},
		},
		uniform_buffers = {
			{
				name = "lighting_data",
				binding_index = 3,
				block = {
					render3d.camera_block,
					render3d.last_frame_block,
					post_source.pre_exposure_block,
					{"blue_noise_tex", "int"},
					{"frame", "int"},
					{"gi_enabled", "int"},
					{"gi_strength", "float"},
					gbuffer_layout.block,
				},
				write = function(self, block)
					render3d.WriteCameraBlock(self, block)
					render3d.WriteLastFrameBlock(self, block)
					post_source.WritePreExposureBlock(self, block)
					block.blue_noise_tex = self:GetTextureIndex(assets.GetTexture("textures/render/blue_noise.lua"))
					block.frame = system.GetFrameNumber() % 4096
					block.gi_enabled = ambient_occlusion.IsGIEnabled() and block.last_frame_tex ~= -1 and 1 or 0
					block.gi_strength = ambient_occlusion.GetGIStrength()
					gbuffer_layout.WriteBlock(self, block)
					return block
				end,
			},
		},
		custom_declarations = [[
			layout(set = 0, binding = 0, rgba16f) uniform writeonly image2D out_color;
			layout(set = 0, binding = 1, rgba16f) uniform writeonly image2D out_bent_normal;
			]],
		shader = [[
			vec2 in_uv;

			const float BENT_COS_SQUARED[32] = float[32](]] .. table.concat(BENT_COS_SQUARED, ", ") .. [[);
			const float BENT_COS_SIN[32] = float[32](]] .. table.concat(BENT_COS_SIN, ", ") .. [[);
			// a diffuse surface in full sun is about this bright in cd/m2. anything above is a glint, an
			// emitter or earlier bounce piling up, and one such pixel should not become a firefly
			const float BOUNCE_MAX_LUMINANCE = 30000.0;

			]] .. compute_helpers.GetScreenHelpersGLSL() .. gbuffer_layout.GetDecodeGLSL("lighting_data") .. post_source.GetPreExposureGLSL("lighting_data") .. [[
			]] .. screen_reconstruct.GetWorldPosGLSL("lighting_data") .. [[
			]] .. screen_reconstruct.GetWorldPosFromUVGLSL("lighting_data", {function_name = "get_world_pos_uv"}) .. [[

			void set_color(vec3 bounce, float ao, vec3 bent, float view_depth) {
				imageStore(out_color, get_screen_pos(), vec4(bounce, ao));
				imageStore(out_bent_normal, get_screen_pos(), vec4(bent, view_depth));
			}

			vec3 get_geometric_normal(vec2 uv, vec3 world_pos, float depth, vec3 shading_normal) {
				vec2 texel = 1.0 / vec2(textureSize(TEXTURE(lighting_data.depth_tex), 0));
				float depth_left = gbuffer_depth(uv - vec2(texel.x, 0.0));
				float depth_right = gbuffer_depth(uv + vec2(texel.x, 0.0));
				float depth_down = gbuffer_depth(uv - vec2(0.0, texel.y));
				float depth_up = gbuffer_depth(uv + vec2(0.0, texel.y));
				vec3 dx = abs(depth_left - depth) < abs(depth_right - depth) ?
					world_pos - get_world_pos_uv(uv - vec2(texel.x, 0.0), depth_left) :
					get_world_pos_uv(uv + vec2(texel.x, 0.0), depth_right) - world_pos;
				vec3 dy = abs(depth_down - depth) < abs(depth_up - depth) ?
					world_pos - get_world_pos_uv(uv - vec2(0.0, texel.y), depth_down) :
					get_world_pos_uv(uv + vec2(0.0, texel.y), depth_up) - world_pos;
				vec3 n = cross(dx, dy);
				float len = length(n);

				if (len < 1e-12) {
					return shading_normal;
				}

				n /= len;

				if (dot(n, shading_normal) < 0.0) {
					n = -n;
				}

				return n;
			}

			// ao is the share of the hemisphere left open, bounce the light that came in through
			// the part that was not, in the same units as the gi irradiance, and bent the
			// cosine weighted direction of what is open
			void get_ambient_occlusion(vec2 uv, vec3 world_pos, vec3 N, out float ao, out vec3 bounce, out vec3 bent) {
				vec3 p = (lighting_data.view * vec4(world_pos, 1.0)).xyz;
				vec3 V = normalize(-p);
				vec3 view_normal = normalize(mat3(lighting_data.view) * N);

				ivec2 screen_size = textureSize(TEXTURE(lighting_data.depth_tex), 0);
				ivec2 pixel = ivec2(uv * vec2(screen_size));
				ivec2 noise_size = textureSize(TEXTURE(lighting_data.blue_noise_tex), 0);
				// a different pattern every frame (R2 sequence), for taa to average
				vec2 noise = fract(texelFetch(TEXTURE(lighting_data.blue_noise_tex), pixel % noise_size, 0).rg + float(lighting_data.frame) * vec2(0.7548776662, 0.5698402910));
				
				float random_offset = noise.x;
				float random_rotation = noise.y * 6.28318;

				float world_radius = 2.0;
				float screen_radius = (world_radius * lighting_data.projection[0][0]) / (-p.z * 2.0);

				const int Nd = 3; 
				const int Ns = 6; 
				const uint Nb = 32;
				// how far behind its visible front an occluder is assumed to
				// extend, in view space units. thin translucent surfaces
				// (transmissive, like leaves and grass blades) barely extend at
				// all, or a field of blades would black out the ground between
				// them
				float thickness = 0.5;
				float thin_thickness = 0.03;

				// the light of the last frame was exposed for that frame
				float history_scale = get_pre_exposure() / get_previous_pre_exposure();
				float bounce_max = BOUNCE_MAX_LUMINANCE * get_pre_exposure();
				vec2 history_texel = 1.0 / vec2(screen_size);
				float total_ao = 0.0;
				vec3 total_bounce = vec3(0.0);
				vec3 total_bent = vec3(0.0);
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
					vec3 slice_bounce = vec3(0.0);

					for (int j = 0; j < Ns; j++) {
						float o = (float(j) + random_offset) / float(Ns);
						float step_dist = o * o * screen_radius;
						
						for (float side = -1.0; side <= 1.0; side += 2.0) {
							if (side == 0.0) continue;
							vec2 sample_uv = uv + dir * step_dist * side;
							
							if (sample_uv.x < 0.0 || sample_uv.x > 1.0 || sample_uv.y < 0.0 || sample_uv.y > 1.0) continue;

							float sample_depth = gbuffer_depth(sample_uv);
							vec4 sample_clip_pos = vec4(sample_uv * 2.0 - 1.0, sample_depth, 1.0);
							vec4 sample_view_pos = lighting_data.inv_projection * sample_clip_pos;
							vec3 sf = sample_view_pos.xyz / sample_view_pos.w;
							
							vec3 v_f = sf - p;
							float dist2 = dot(v_f, v_f);

							if (dist2 > world_radius * world_radius || dist2 < 0.0001) continue;

							// at or below the tangent plane nothing can occlude, and on flat
							// or convex faceted surfaces that is where every sample lands, a
							// hair above or below. without a margin those set a bit each
							if (dot(v_f, view_normal) < 0.1 * sqrt(dist2)) continue;

							float sample_transmission = gbuffer_transmission(sample_uv);
							float sample_thickness = sample_transmission > 0.0 ? thin_thickness : thickness;

							// Angles from the view vector, signed by the side of
							// the slice the sample is on (Therrien 2023). The
							// back of the occluder is its front pushed away from
							// the viewer by thickness; on a flat surface that
							// lands below the horizon and occludes nothing.
							// Taking the angles from atan of the in-slice
							// components instead lets the back one, which points
							// almost straight away from the viewer, flip sign
							// on noise and cover the whole hemisphere.
							float theta_f = side * acos(clamp(dot(v_f * inversesqrt(dist2), V), -1.0, 1.0));
							float theta_b = side * acos(clamp(dot(normalize(v_f - V * sample_thickness), V), -1.0, 1.0));
							float diff_f = theta_f - theta_n;
							float diff_b = theta_b - theta_n;

							float theta_min = clamp(min(diff_f, diff_b), -1.5708, 1.5708);
							float theta_max = clamp(max(diff_f, diff_b), -1.5708, 1.5708);
							
							uint a = uint(round((theta_min + 1.5708) / 3.14159 * float(Nb)));
							uint b = uint(round((theta_max + 1.5708) / 3.14159 * float(Nb)));
							
							a = clamp(a, 0u, Nb);
							b = clamp(b, 0u, Nb);

							if (b > a) {
								uint count = b - a;
								uint mask = (count >= 32u) ? 0xFFFFFFFFu : ((1u << count) - 1u) << a;

								// only the part of the arc nothing nearer covered already sends light
								uint fresh = mask & ~bi;

								if (lighting_data.gi_enabled != 0 && fresh != 0u) {
									vec2 history_uv = lighting_data.velocity_tex == -1 ? sample_uv : sample_uv - texture(TEXTURE(lighting_data.velocity_tex), sample_uv).xy;

									if (history_uv.x > 0.0 && history_uv.x < 1.0 && history_uv.y > 0.0 && history_uv.y < 1.0) {
										vec3 sample_normal = normalize(mat3(lighting_data.view) * gbuffer_normal(sample_uv));
										float facing = sample_transmission > 0.0 ? 1.0 : clamp(dot(sample_normal, -v_f * inversesqrt(dist2)), 0.0, 1.0);
										// the share of the cosine weighted hemisphere this arc covers
										float cosine_share = 0.5 * (sin(theta_max) - sin(theta_min));
										// a few taps around it, so a single bright pixel is only a part of what the sample sees
										vec3 hit = (
											texture(TEXTURE(lighting_data.last_frame_tex), history_uv + history_texel * vec2(-1.5, -0.5)).rgb +
											texture(TEXTURE(lighting_data.last_frame_tex), history_uv + history_texel * vec2(0.5, -1.5)).rgb +
											texture(TEXTURE(lighting_data.last_frame_tex), history_uv + history_texel * vec2(1.5, 0.5)).rgb +
											texture(TEXTURE(lighting_data.last_frame_tex), history_uv + history_texel * vec2(-0.5, 1.5)).rgb
										) * (0.25 * history_scale);
										hit *= min(1.0, bounce_max / max(dot(hit, vec3(0.2126, 0.7152, 0.0722)), 1e-6));
										slice_bounce += hit * (cosine_share * float(bitCount(fresh)) / float(count) * facing);
									}
								}

								bi |= mask;
							}
						}
					}

					total_ao += (1.0 - float(bitCount(bi)) / float(Nb)) * weight;
					total_bounce += slice_bounce * weight;

					float open_cos_squared = 0.0;
					float open_cos_sin = 0.0;

					for (int k = 0; k < 32; k++) {
						if (((bi >> uint(k)) & 1u) == 0u) {
							open_cos_squared += BENT_COS_SQUARED[k];
							open_cos_sin += BENT_COS_SIN[k];
						}
					}

					// the open direction in the slice, measured from the projected normal, back in view space
					float cn = cos(theta_n);
					float sn = sin(theta_n);
					total_bent += (V * (open_cos_squared * cn - open_cos_sin * sn) + T_v * (open_cos_squared * sn + open_cos_sin * cn)) * weight;
					total_weight += weight;
				}

				if (total_weight <= 0.001) {
					ao = 1.0;
					bounce = vec3(0.0);
					bent = N;
					return;
				}

				ao = clamp(total_ao / total_weight, 0.0, 1.0);
				bounce = total_bounce / total_weight * lighting_data.gi_strength;
				float bent_length = length(total_bent);
				bent = bent_length > 1e-4 ? normalize(mat3(lighting_data.inv_view) * (total_bent / bent_length)) : N;
			}

			void main() {
				ivec2 pos = get_screen_pos();
				ivec2 size = imageSize(out_color);

				if (!is_screen_pos_in_bounds(pos, size)) return;

				ivec2 pixel = pos * ]] .. RATIO .. [[;
				in_uv = (vec2(pixel) + 0.5) / vec2(textureSize(TEXTURE(lighting_data.depth_tex), 0));
				float depth = gbuffer_depth(pixel);
				float alpha = gbuffer_alpha(pixel);

				if (depth == 1.0 || alpha == 0.0) {
					set_color(vec3(0.0), 1.0, vec3(0.0), 0.0);
					return;
				}

				vec3 world_pos = get_world_pos(depth);
				vec3 N = gbuffer_normal(pixel);
				bool thin = gbuffer_transmission(pixel) > 0.0;

				// on a thin card the depth derivatives belong to whatever the card and its neighbours are,
				// and flip from pixel to pixel
				if (!thin) N = get_geometric_normal(in_uv, world_pos, depth, N);

				float ao;
				vec3 bounce;
				vec3 bent;
				get_ambient_occlusion(in_uv, world_pos, N, ao, bounce, bent);

				// the normals of foliage are not a surface, bending the lookup by them only adds noise
				if (thin) bent = N;

				set_color(bounce, ao, bent, -(lighting_data.view * vec4(world_pos, 1.0)).z);
			}
		]],
	},
	{
		name = "ambient_occlusion_temporal",
		ComputePass = true,
		ColorFormat = {
			{"r16g16b16a16_sfloat", {"bounce_ao", "rgba"}},
			{"r16g16b16a16_sfloat", {"bent_normal", "rgba"}},
		},
		framebuffer_count = 2,
		scale = SCALE,
		LocalSize = COMPUTE_LOCAL_SIZE,
		storage_images = {
			{
				binding_index = 0,
				attachment = 1,
				dst_stage = "compute",
			},
			{
				binding_index = 1,
				attachment = 2,
				dst_stage = "compute",
			},
		},
		uniform_buffers = {
			{
				name = "temporal_data",
				binding_index = 3,
				block = {
					gbuffer_layout.block,
					post_source.pre_exposure_block,
					{"raw_ao_tex", "int"},
					{"raw_bent_tex", "int"},
					{"history_ao_tex", "int"},
					{"history_bent_tex", "int"},
				},
				write = function(self, block)
					gbuffer_layout.WriteBlock(self, block)
					post_source.WritePreExposureBlock(self, block)
					local raw = render3d.pipelines.ambient_occlusion:GetFramebuffer(1)
					block.raw_ao_tex = self:GetTextureIndex(raw:GetAttachment(1))
					block.raw_bent_tex = self:GetTextureIndex(raw:GetAttachment(2))
					local frame = system.GetFrameNumber()

					if self.history_framebuffers ~= self.framebuffers then
						self.history_framebuffers = self.framebuffers
						self.history_reset_frame = frame
					end

					if frame > self.history_reset_frame and render3d.ShouldUseLastFrameHistory() then
						local history = self:GetFramebuffer((frame + 1) % 2 + 1)
						block.history_ao_tex = self:GetTextureIndex(history:GetAttachment(1))
						block.history_bent_tex = self:GetTextureIndex(history:GetAttachment(2))
					else
						block.history_ao_tex = -1
						block.history_bent_tex = -1
					end

					return block
				end,
			},
		},
		custom_declarations = [[
			layout(set = 0, binding = 0, rgba16f) uniform writeonly image2D out_color;
			layout(set = 0, binding = 1, rgba16f) uniform writeonly image2D out_bent_normal;
			]],
		shader = [[
			]] .. compute_helpers.GetScreenHelpersGLSL() .. gbuffer_layout.GetDecodeGLSL("temporal_data") .. post_source.GetPreExposureGLSL("temporal_data") .. [[

			void main() {
				ivec2 pos = get_screen_pos();
				ivec2 size = imageSize(out_color);

				if (!is_screen_pos_in_bounds(pos, size)) return;

				vec4 current = texelFetch(TEXTURE(temporal_data.raw_ao_tex), pos, 0);
				vec4 current_bent = texelFetch(TEXTURE(temporal_data.raw_bent_tex), pos, 0);

				if (temporal_data.history_ao_tex == -1 || temporal_data.velocity_tex == -1 || current_bent.w == 0.0) {
					imageStore(out_color, pos, current);
					imageStore(out_bent_normal, pos, current_bent);
					return;
				}

				vec2 uv = get_screen_uv(pos, size);
				vec4 motion = texture(TEXTURE(temporal_data.velocity_tex), uv);
				vec2 history_uv = uv - motion.xy;

				// what the history held where this surface was: a different depth there means something else was in view
				float history_depth = texelFetch(TEXTURE(temporal_data.history_bent_tex), clamp(ivec2(history_uv * vec2(size)), ivec2(0), size - 1), 0).w;
				bool valid = history_uv.x > 0.0 && history_uv.x < 1.0 && history_uv.y > 0.0 && history_uv.y < 1.0 && history_depth > 0.0;
				// thin geometry changes what a pixel sees constantly, so how far off the history is decides how much of it is kept
				float depth_error = abs(history_depth - motion.z) / max(motion.z, 0.1);
				float history_weight = 0.92 * (1.0 - smoothstep(0.05, 0.3, depth_error));

				if (!valid || history_weight <= 0.0) {
					imageStore(out_color, pos, current);
					imageStore(out_bent_normal, pos, current_bent);
					return;
				}

				vec4 mean = vec4(0.0);
				vec4 mean_squared = vec4(0.0);

				for (int y = -1; y <= 1; y++) {
					for (int x = -1; x <= 1; x++) {
						vec4 neighbor = texelFetch(TEXTURE(temporal_data.raw_ao_tex), clamp(pos + ivec2(x, y), ivec2(0), size - 1), 0);
						mean += neighbor;
						mean_squared += neighbor * neighbor;
					}
				}

				// a pixel far brighter than what is around it is a firefly, not the light
				vec4 around = (mean - current) / 8.0;
				current.rgb = min(current.rgb, around.rgb * 2.0 + vec3(50.0 * get_pre_exposure()));
				mean /= 9.0;
				vec4 sigma = sqrt(max(mean_squared / 9.0 - mean * mean, vec4(0.0)));
				vec4 history = texture(TEXTURE(temporal_data.history_ao_tex), history_uv);
				// the history was exposed for the frame before
				history.rgb *= get_pre_exposure() / get_previous_pre_exposure();
				history = clamp(history, mean - 2.0 * sigma, mean + 2.0 * sigma);
				vec4 history_bent = texture(TEXTURE(temporal_data.history_bent_tex), history_uv);
				imageStore(out_color, pos, mix(current, history, history_weight));
				imageStore(out_bent_normal, pos, vec4(mix(current_bent.xyz, history_bent.xyz, history_weight), current_bent.w));
			}
		]],
	},
	{
		name = "ambient_occlusion_blur",
		ComputePass = true,
		ColorFormat = {
			{"r16g16b16a16_sfloat", {"bounce_ao", "rgba"}},
			{"r16g16b16a16_sfloat", {"bent_normal", "rgba"}},
		},
		framebuffer_count = 1,
		LocalSize = COMPUTE_LOCAL_SIZE,
		storage_images = {
			{
				binding_index = 0,
				attachment = 1,
				dst_stage = "compute",
			},
			{
				binding_index = 1,
				attachment = 2,
				dst_stage = "compute",
			},
		},
		uniform_buffers = {
			{
				name = "ao_blur_data",
				binding_index = 3,
				block = {
					render3d.camera_block,
					gbuffer_layout.block,
					{"ao_tex", "int"},
					{"bent_tex", "int"},
				},
				write = function(self, block)
					render3d.WriteCameraBlock(self, block)
					gbuffer_layout.WriteBlock(self, block)
					local framebuffer = render3d.pipelines.ambient_occlusion_temporal:GetFramebuffer(system.GetFrameNumber() % 2 + 1)
					block.ao_tex = self:GetTextureIndex(framebuffer:GetAttachment(1))
					block.bent_tex = self:GetTextureIndex(framebuffer:GetAttachment(2))
					return block
				end,
			},
		},
		custom_declarations = [[
			layout(set = 0, binding = 0, rgba16f) uniform writeonly image2D out_color;
			layout(set = 0, binding = 1, rgba16f) uniform writeonly image2D out_bent_normal;
			]],
		shader = [[
			]] .. compute_helpers.GetScreenHelpersGLSL() .. gbuffer_layout.GetDecodeGLSL("ao_blur_data") .. [[

			void set_color(vec4 bounce_ao, vec3 bent) {
				imageStore(out_color, get_screen_pos(), bounce_ao);
				imageStore(out_bent_normal, get_screen_pos(), vec4(bent, 1.0));
			}

			// the pixel makes up its ao from the texels around it, each weighted by how near it is, how
			// close the depth it stands for is to the pixel's and, unless the pixel is foliage whose
			// normals disagree with their neighbours' however close they are, which way it faces. blurring
			// the ao across leaves at different depths would smear the shade of one over the others
			void main() {
				ivec2 pos = get_screen_pos();
				ivec2 size = imageSize(out_color);

				if (!is_screen_pos_in_bounds(pos, size)) return;

				float depth = gbuffer_depth(pos);

				if (depth == 1.0) {
					set_color(vec4(0.0, 0.0, 0.0, 1.0), vec3(0.0));
					return;
				}

				mat4 inv_projection = ao_blur_data.inv_projection;
				float view_depth = -(inv_projection[2][2] * depth + inv_projection[3][2]) / (inv_projection[2][3] * depth + inv_projection[3][3]);
				float depth_sigma = max(]] .. BLUR_DEPTH_SIGMA .. [[ * view_depth, 0.005);
				ivec2 ao_size = textureSize(TEXTURE(ao_blur_data.ao_tex), 0);
				ivec2 base = pos / ]] .. RATIO .. [[;
				vec3 center_normal = gbuffer_normal(pos);
				bool center_thin = gbuffer_transmission(pos) > 0.0;
				vec4 total = vec4(0.0);
				vec3 total_bent = vec3(0.0);
				float weight_sum = 0.0;

				for (int y = -1; y <= 2; y++) {
					for (int x = -1; x <= 2; x++) {
						ivec2 texel = clamp(base + ivec2(x, y), ivec2(0), ao_size - 1);
						vec4 bent = texelFetch(TEXTURE(ao_blur_data.bent_tex), texel, 0);
						// the depth the texel stands for, 0 where there is none
						float texel_depth = bent.w;

						if (texel_depth <= 0.0) continue;

						vec2 offset = vec2(pos - texel * ]] .. RATIO .. [[);
						float depth_diff = texel_depth - view_depth;
						float depth_weight = exp(-(depth_diff * depth_diff) / (2.0 * depth_sigma * depth_sigma));
						float spatial_weight = exp(-dot(offset, offset) / (2.0 * ]] .. BLUR_DISTANCE_SIGMA .. [[.0 * ]] .. BLUR_DISTANCE_SIGMA .. [[.0));
						float normal_weight = center_thin ? 1.0 : pow(max(dot(center_normal, gbuffer_normal(texel * ]] .. RATIO .. [[)), 0.0), ]] .. BLUR_NORMAL_POWER .. [[.0);
						float weight = depth_weight * spatial_weight * normal_weight;
						total += texelFetch(TEXTURE(ao_blur_data.ao_tex), texel, 0) * weight;
						total_bent += bent.xyz * weight;
						weight_sum += weight;
					}
				}

				if (weight_sum > 0.0001) {
					set_color(total / weight_sum, total_bent / weight_sum);
				} else {
					// nothing that looks like this pixel is near: the closest texel's
					ivec2 texel = clamp(base + (pos & 1), ivec2(0), ao_size - 1);
					set_color(texelFetch(TEXTURE(ao_blur_data.ao_tex), texel, 0), texelFetch(TEXTURE(ao_blur_data.bent_tex), texel, 0).xyz);
				}
			}
		]],
	},
}
