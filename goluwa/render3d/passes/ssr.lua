local GetBlueNoiseTexture = require("render.textures.blue_noise")
local render3d = require("render3d.render3d")
local system = require("system")
return {
	{
		name = "ssr",
		color_format = {{"r16g16b16a16_sfloat", {"ssr", "rgba"}}},
		fragment = {
			uniform_buffers = {
				{
					name = "ssr_data",
					binding_index = 3,
					block = {
						render3d.camera_block,
						{
							"normal_tex",
							"int",
							function(self, block, key)
								block[key] = self:GetTextureIndex(render3d.pipelines.gbuffer:GetFramebuffer():GetAttachment(2))
							end,
						},
						{
							"mra_tex",
							"int",
							function(self, block, key)
								block[key] = self:GetTextureIndex(render3d.pipelines.gbuffer:GetFramebuffer():GetAttachment(3))
							end,
						},
						{
							"depth_tex",
							"int",
							function(self, block, key)
								block[key] = self:GetTextureIndex(render3d.pipelines.gbuffer:GetFramebuffer():GetDepthTexture())
							end,
						},
						{
							"blue_noise_tex",
							"int",
							function(self, block, key)
								block[key] = self:GetTextureIndex(GetBlueNoiseTexture())
							end,
						},
						render3d.last_frame_block,
						render3d.common_block,
						-- NEW: Frame index for temporal noise
						{
							"frame_index",
							"int",
							function(self, block, key)
								render3d.ssr_frame_count = (render3d.ssr_frame_count or 0) + 1
								block[key] = render3d.ssr_frame_count % 256
							end,
						},
					},
				},
			},
			shader = [[            
			vec3 get_normal() {
				return texture(TEXTURE(ssr_data.normal_tex), in_uv).xyz;
			}

			float get_roughness() {
				return texture(TEXTURE(ssr_data.mra_tex), in_uv).g;
			}

			float get_depth() {
				return texture(TEXTURE(ssr_data.depth_tex), in_uv).r;
			}
		

            #define SSR_MAX_STEPS 64
            #define SSR_BINARY_STEPS 8
            #define SSR_ROUGHNESS_CUTOFF 1
            #define PI 3.14159265359
            
            #define saturate(x) clamp(x, 0.0, 1.0)
            
            // Spatiotemporal blue noise using a precomputed texture
            vec2 blue_noise(vec2 uv, int frame) {
                ivec2 pixel = ivec2(uv * vec2(textureSize(TEXTURE(ssr_data.depth_tex), 0)));
                ivec2 noise_size = textureSize(TEXTURE(ssr_data.blue_noise_tex), 0);
                
                // Use golden ratio to offset the noise texture per frame for temporal stability
                ivec2 offset = ivec2(
                    int(fract(float(frame) * 0.7548776662466927) * float(noise_size.x)),
                    int(fract(float(frame) * 0.5698402909980532) * float(noise_size.y))
                );
                
                return texelFetch(TEXTURE(ssr_data.blue_noise_tex), (pixel + offset) % noise_size, 0).rg;
            }
            
            // VNDF sampling for GGX (Heitz 2018 + spherical cap)
            vec3 sampleGGXVNDF(vec3 Ve, float alpha, vec2 xi) {
                vec3 Vh = normalize(vec3(alpha * Ve.x, alpha * Ve.y, Ve.z));
                float lensq = Vh.x * Vh.x + Vh.y * Vh.y;
                vec3 T1 = lensq > 0.0 ? vec3(-Vh.y, Vh.x, 0.0) / sqrt(lensq) : vec3(1.0, 0.0, 0.0);
                vec3 T2 = cross(Vh, T1);
                
                float r = sqrt(xi.x);
                float phi = 2.0 * PI * xi.y;
                float t1 = r * cos(phi);
                float t2 = r * sin(phi);
                float s = 0.5 * (1.0 + Vh.z);
                t2 = (1.0 - s) * sqrt(1.0 - t1 * t1) + s * t2;
                
                vec3 Nh = t1 * T1 + t2 * T2 + sqrt(max(0.0, 1.0 - t1*t1 - t2*t2)) * Vh;
                return normalize(vec3(alpha * Nh.x, alpha * Nh.y, max(0.0, Nh.z)));
            }
            
            // Robust tangent frame construction (Frisvad / revised Pixar method)
            void buildOrthonormalBasis(vec3 n, out vec3 t, out vec3 b) {
				float a = 1.0 / (1.0 + n.z);
				float d = -n.x * n.y * a;
				t = vec3(1.0 - n.x * n.x * a, d, -n.x);
				b = vec3(d, 1.0 - n.y * n.y * a, -n.y);
            }
            
            vec4 cast_ssr_ray(vec3 world_pos, vec3 N, vec3 V, float roughness, vec2 xi) {
                if (ssr_data.last_frame_tex == -1) return vec4(0.0);
                if (roughness > SSR_ROUGHNESS_CUTOFF) return vec4(0.0);
                
                // Transform to view space
                vec3 N_vs = normalize(mat3(ssr_data.view) * N);
                vec3 V_vs = normalize(mat3(ssr_data.view) * V);
                vec4 pos_vs = ssr_data.view * vec4(world_pos, 1.0);
                
                // VNDF importance sampling with robust tangent frame
                vec3 T, B;
                buildOrthonormalBasis(N_vs, T, B);
                
                vec3 V_local = vec3(dot(V_vs, T), dot(V_vs, B), dot(V_vs, N_vs));
                float alpha = max(0.001, roughness * roughness);
                vec3 H_local = sampleGGXVNDF(V_local, alpha, xi);
                vec3 H_vs = normalize(T * H_local.x + B * H_local.y + N_vs * H_local.z);
                
                vec3 R_vs = reflect(-V_vs, H_vs);
                if (dot(N_vs, R_vs) < 0.0) return vec4(0.0);
                
                // Adaptive ray marching with jittered start
                float jitter = fract(xi.x * 12.9898 + xi.y * 78.233);
                float step_size = 0.05 + 0.05 * jitter; // Jittered initial step
                vec3 current_pos = pos_vs.xyz + R_vs * step_size * jitter; // Jittered start position
                int steps = int(mix(float(SSR_MAX_STEPS), float(SSR_MAX_STEPS/2), roughness));
                
                for (int i = 0; i < steps; i++) {
                    current_pos += R_vs * step_size;
                    
                    vec4 proj = ssr_data.projection * vec4(current_pos, 1.0);
                    proj.xyz /= proj.w;
                    vec2 uv = proj.xy * 0.5 + 0.5;
                    
                    if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0) break;
                    
                    float sampled_depth = texture(TEXTURE(ssr_data.depth_tex), uv).r;
                    vec4 sampled_clip = vec4(uv * 2.0 - 1.0, sampled_depth, 1.0);
                    vec4 sampled_view = ssr_data.inv_projection * sampled_clip;
                    sampled_view /= sampled_view.w;
                    
                    if (current_pos.z < sampled_view.z) {
                        float depth_diff = abs(current_pos.z - sampled_view.z);
                        float thickness = 0.5 + step_size * 2.0;
                        thickness *= 1.0 + length(current_pos) * 0.005;
                        
                        if (depth_diff < thickness) {
                            // Binary search refinement
                            vec3 start = current_pos - R_vs * step_size;
                            vec3 end = current_pos;
                            
                            for (int j = 0; j < SSR_BINARY_STEPS; j++) {
                                vec3 mid = mix(start, end, 0.5);
                                vec4 mid_proj = ssr_data.projection * vec4(mid, 1.0);
                                mid_proj.xyz /= mid_proj.w;
                                vec2 mid_uv = mid_proj.xy * 0.5 + 0.5;
                                
                                float mid_depth = texture(TEXTURE(ssr_data.depth_tex), mid_uv).r;
                                vec4 mid_clip = vec4(mid_uv * 2.0 - 1.0, mid_depth, 1.0);
                                vec4 mid_view = ssr_data.inv_projection * mid_clip;
                                mid_view /= mid_view.w;
                                
                                if (mid.z < mid_view.z) {
                                    end = mid; uv = mid_uv;
                                } else {
                                    start = mid;
                                }
                            }
                            
                            // Backface rejection - transform to same space
                            vec3 hit_normal_ws = texture(TEXTURE(ssr_data.normal_tex), uv).xyz;
                            vec3 hit_normal_vs = normalize(mat3(ssr_data.view) * hit_normal_ws);
                            if (dot(hit_normal_vs, -R_vs) < 0.0) {
                                step_size *= 1.5;
                                continue;
                            }
                            
                            // Sample with roughness-based blur
                            vec3 hit_color;
                            float dist = length(current_pos - pos_vs.xyz);
                            
                            if (roughness > 0.1) {
                                vec2 tex_size = vec2(textureSize(TEXTURE(ssr_data.last_frame_tex), 0));
                                float cone = roughness * dist * 0.05;
                                float mip = log2(max(1.0, cone * max(tex_size.x, tex_size.y)));
                                hit_color = textureLod(TEXTURE(ssr_data.last_frame_tex), uv, min(mip, 4.0)).rgb;
                            } else {
                                hit_color = texture(TEXTURE(ssr_data.last_frame_tex), uv).rgb;
                            }
                            
                            // Confidence calculation
                            float edge_fade = 1.0 - pow(max(abs(uv.x-0.5), abs(uv.y-0.5)) * 2.0, 3.0);
                            float dist_fade = 1.0 - saturate(dist / 100.0);
                            float thick_conf = 1.0 - saturate(depth_diff / thickness);
                            float confidence = edge_fade * dist_fade * thick_conf;
                            
                            return vec4(hit_color, confidence);
                        }
                    }
                    
                    step_size *= 1.05; // Slower growth than before
                }
                
                return vec4(0.0);
            }
            
            void main() {
                vec3 N = get_normal();
                float roughness = get_roughness();
                float depth = get_depth();
                
                if (depth == 1.0) {
                    set_ssr(vec4(0.0));
                    return;
                }
					
                vec4 clip_pos = vec4(in_uv * 2.0 - 1.0, depth, 1.0);
                vec4 view_pos = ssr_data.inv_projection * clip_pos;
                view_pos /= view_pos.w;
                vec3 world_pos = (ssr_data.inv_view * view_pos).xyz;
                vec3 V = normalize(ssr_data.camera_position.xyz - world_pos);
                
                // SINGLE RAY with spatiotemporal blue noise
                vec2 xi = blue_noise(in_uv, ssr_data.frame_index);
                vec4 current = cast_ssr_ray(world_pos, N, V, roughness, xi);
                
                set_ssr(current);
            }
        ]],
		},
		rasterizer = {
			cull_mode = "none",
		},
		depth_stencil = {
			depth_test = false,
			depth_write = false,
		},
	},
	{
		name = "ssr_resolve",
		color_format = {{"r16g16b16a16_sfloat", {"ssr", "rgba"}}},
		framebuffer_count = 2,
		fragment = {
			uniform_buffers = {
				{
					name = "resolve_data",
					binding_index = 3,
					block = {
						render3d.camera_block,
						{
							"current_ssr_tex",
							"int",
							function(self, block, key)
								if not render3d.pipelines.ssr then
									block[key] = -1
									return
								end

								block[key] = self:GetTextureIndex(render3d.pipelines.ssr:GetFramebuffer():GetAttachment(1))
							end,
						},
						{
							"history_ssr_tex",
							"int",
							function(self, block, key)
								if
									not render3d.pipelines.ssr_resolve or
									not render3d.pipelines.ssr_resolve.framebuffers
								then
									block[key] = -1
									return
								end

								local prev_idx = (system.GetFrameNumber() + 1) % 2 + 1
								block[key] = self:GetTextureIndex(render3d.pipelines.ssr_resolve:GetFramebuffer(prev_idx):GetAttachment(1))
							end,
						},
						{
							"depth_tex",
							"int",
							function(self, block, key)
								block[key] = self:GetTextureIndex(render3d.pipelines.gbuffer:GetFramebuffer():GetDepthTexture())
							end,
						},
						{
							"prev_inv_view",
							"mat4",
							function(self, block, key)
								local mat = render3d.prev_view_matrix

								if mat then
									mat:GetInverse():CopyToFloatPointer(block[key])
								else
									render3d.camera:BuildViewMatrix():GetInverse():CopyToFloatPointer(block[key])
								end
							end,
						},
						{
							"prev_projection",
							"mat4",
							function(self, block, key)
								local mat = render3d.prev_projection_matrix

								if mat then
									mat:CopyToFloatPointer(block[key])
								else
									render3d.camera:BuildProjectionMatrix():CopyToFloatPointer(block[key])
								end
							end,
						},
					},
				},
			},
			shader = [[
			float get_depth() {
				return texture(TEXTURE(resolve_data.depth_tex), in_uv).r;
			}

			vec4 get_ssr() {
				return texture(TEXTURE(resolve_data.current_ssr_tex), in_uv);
			}

			vec4 get_ssr(vec2 uv) {
				return texture(TEXTURE(resolve_data.current_ssr_tex), uv);
			}

			vec4 get_history_ssr(vec2 uv) {
				return texture(TEXTURE(resolve_data.history_ssr_tex), uv);
			}

			#define saturate(x) clamp(x, 0.0, 1.0)
			
			void main() {
				if (resolve_data.current_ssr_tex == -1) {
					set_ssr(vec4(0.0));
					return;
				}
				
				vec4 current = get_ssr();
				
				// Get world position for reprojection
				float depth = get_depth();
				
				if (depth == 1.0) {
					set_ssr(current);
					return;
				}
				
				// Reconstruct world position
				vec4 clip_pos = vec4(in_uv * 2.0 - 1.0, depth, 1.0);
				vec4 view_pos = resolve_data.inv_projection * clip_pos;
				view_pos /= view_pos.w;
				vec3 world_pos = (resolve_data.inv_view * view_pos).xyz;
				
				// Reproject to previous frame
				vec4 prev_view_pos = inverse(resolve_data.prev_inv_view) * vec4(world_pos, 1.0);
				vec4 prev_clip = resolve_data.prev_projection * prev_view_pos;
				vec2 prev_uv = (prev_clip.xy / prev_clip.w) * 0.5 + 0.5;
				
				// Check if reprojected UV is valid
				if (prev_uv.x < 0.0 || prev_uv.x > 1.0 || prev_uv.y < 0.0 || prev_uv.y > 1.0) {
					set_ssr(current);
					return;
				}
				
				vec4 history = get_history_ssr(prev_uv);
				
				// Neighborhood clamping (AABB) to reject invalid history
				vec3 m1 = vec3(0.0);
				vec3 m2 = vec3(0.0);
				float a1 = 0.0, a2 = 0.0;
				
				vec2 texel_size = 1.0 / vec2(textureSize(TEXTURE(resolve_data.current_ssr_tex), 0));
				
				// Use a slightly larger neighborhood for better stability with sparse noise
				for (int y = -1; y <= 1; y++) {
					for (int x = -1; x <= 1; x++) {
						vec4 s = get_ssr(in_uv + vec2(x, y) * texel_size);
						m1 += s.rgb;
						m2 += s.rgb * s.rgb;
						a1 += s.a;
						a2 += s.a * s.a;
					}
				}
				
				m1 /= 9.0;
				m2 /= 9.0;
				a1 /= 9.0;
				a2 /= 9.0;
				
				vec3 sigma = sqrt(max(vec3(0.0), m2 - m1 * m1));
				float sigma_a = sqrt(max(0.0, a2 - a1 * a1));
				
				// Clamp history to neighborhood bounds (with some slack)
				float gamma = 1.5;
				vec3 clamped_rgb = clamp(history.rgb, m1 - sigma * gamma, m1 + sigma * gamma);
				float clamped_a = clamp(history.a, a1 - sigma_a * gamma, a1 + sigma_a * gamma);
				vec4 clamped_history = vec4(clamped_rgb, clamped_a);
				
				// Blend factor - higher = more temporal stability, lower = more responsive
				float blend = 0.5;
				
				// Reduce blend if history was clamped significantly (indicates disocclusion)
				float clamp_diff = length(history.rgb - clamped_rgb);
				blend *= 1.0 - saturate(clamp_diff * 2.0);
				
				vec4 result = mix(current, clamped_history, blend);
				set_ssr(result);
			}
		]],
		},
		rasterizer = {
			cull_mode = "none",
		},
		depth_stencil = {
			depth_test = false,
			depth_write = false,
		},
	},
}
