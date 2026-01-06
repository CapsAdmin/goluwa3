local ffi = require("ffi")
local render = require("render.render")
local EasyPipeline = require("render.easy_pipeline")
local event = require("event")
local window = require("render.window")
local orientation = require("render3d.orientation")
local Material = require("render3d.material")
local Matrix44 = require("structs.matrix44")
local Vec3 = require("structs.vec3")
local Ang3 = require("structs.ang3")
local Quat = require("structs.quat")
local Rect = require("structs.rect")
local Camera3D = require("render3d.camera3d")
local GetBlueNoiseTexture = require("render.textures.blue_noise")
local Light = require("components.light")
local Framebuffer = require("render.framebuffer")
local system = require("system")
local render3d = library()
package.loaded["render3d.render3d"] = render3d
local atmosphere = require("render3d.atmosphere")
local reflection_probe = require("render3d.reflection_probe")
local camera_block = {
	{
		"inv_view",
		"mat4",
		function(self, block, key)
			render3d.camera:BuildViewMatrix():GetInverse():CopyToFloatPointer(block[key])
		end,
	},
	{
		"inv_projection",
		"mat4",
		function(self, block, key)
			render3d.camera:BuildProjectionMatrix():GetInverse():CopyToFloatPointer(block[key])
		end,
	},
	{
		"view",
		"mat4",
		function(self, block, key)
			render3d.camera:BuildViewMatrix():CopyToFloatPointer(block[key])
		end,
	},
	{
		"projection",
		"mat4",
		function(self, block, key)
			render3d.camera:BuildProjectionMatrix():CopyToFloatPointer(block[key])
		end,
	},
	{
		"camera_position",
		"vec3",
		function(self, block, key)
			render3d.camera:GetPosition():CopyToFloatPointer(block[key])
		end,
	},
}
local debug_block = {
	{
		"debug_cascade_colors",
		"int",
		function(self, block, key)
			block[key] = render3d.debug_cascade_colors and 1 or 0
		end,
	},
	{
		"debug_mode",
		"int",
		function(self, block, key)
			block[key] = render3d.debug_mode or 1
		end,
	},
	{
		"near_z",
		"float",
		function(self, block, key)
			block[key] = render3d.camera:GetNearZ()
		end,
	},
	{
		"far_z",
		"float",
		function(self, block, key)
			block[key] = render3d.camera:GetFarZ()
		end,
	},
}

do
	local debug_modes = {"none", "normals", "light", "ssao", "ssr", "probe"}
	render3d.debug_mode = render3d.debug_mode or 1

	function render3d.GetDebugModes()
		return debug_modes
	end

	function render3d.CycleDebugMode()
		render3d.debug_mode = render3d.debug_mode % #debug_modes + 1
		return debug_modes[render3d.debug_mode]
	end

	function render3d.GetDebugModeName()
		return debug_modes[render3d.debug_mode]
	end

	render3d.debug_mode_glsl = [[
		int debug_mode = lighting_data.debug_mode - 1;

		if (debug_mode == 1) {
			color = N * 0.5 + 0.5;
		} else if (debug_mode == 2) {
			color = ambient_specular + emissive;
		} else if (debug_mode == 3) {
			color = ssao;
		} else if (debug_mode == 4) {
			color = texture(TEXTURE(lighting_data.ssr_tex), in_uv).rgb;
		} else if (debug_mode == 5) {
			// Probe debug - show probe cubemap contribution
			color = reflection;
		}
	]]
end

local common_block = {
	{
		"time",
		"float",
		function(self, block, key)
			block[key] = system.GetElapsedTime()
		end,
	},
}
local gbuffer_block = {
	{
		"albedo_tex",
		"int",
		function(self, block, key)
			block[key] = self:GetTextureIndex(render3d.gbuffer:GetAttachment(1))
		end,
	},
	{
		"normal_tex",
		"int",
		function(self, block, key)
			block[key] = self:GetTextureIndex(render3d.gbuffer:GetAttachment(2))
		end,
	},
	{
		"mra_tex",
		"int",
		function(self, block, key)
			block[key] = self:GetTextureIndex(render3d.gbuffer:GetAttachment(3))
		end,
	},
	{
		"emissive_tex",
		"int",
		function(self, block, key)
			block[key] = self:GetTextureIndex(render3d.gbuffer:GetAttachment(4))
		end,
	},
	{
		"depth_tex",
		"int",
		function(self, block, key)
			block[key] = self:GetTextureIndex(render3d.gbuffer:GetDepthTexture())
		end,
	},
}
local last_frame_block = {
	{
		"last_frame_tex",
		"int",
		function(self, block, key)
			if not render3d.lighting_fbs then
				block[key] = -1
				return
			end

			local prev_idx = 3 - render3d.current_lighting_fb_index
			block[key] = self:GetTextureIndex(render3d.lighting_fbs[prev_idx]:GetAttachment(1))
		end,
	},
}
local quad_vertex_config = {
	shader = [[
		layout(location = 0) out vec2 out_uv;
		void main() {
			vec2 uv = vec2((gl_VertexIndex << 1) & 2, gl_VertexIndex & 2);
			gl_Position = vec4(uv * 2.0 - 1.0, 0.0, 1.0);
			out_uv = uv;
		}
	]],
	fragment_code = [[
		layout(location = 0) in vec2 in_uv;
	]],
}
render3d.gbuffer_config = {
	color_format = {
		{"r8g8b8a8_unorm", {"albedo", "rgb"}, {"alpha", "a"}},
		{"r16g16b16a16_sfloat", {"normal", "rgb"}},
		{"r8g8b8a8_unorm", {"metallic", "r"}, {"roughness", "g"}, {"ao", "b"}},
		{"r8g8b8a8_unorm", {"emissive", "rgb"}},
	},
	depth_format = "d32_sfloat",
	vertex = {
		binding_index = 0,
		attributes = {
			{"position", "vec3", "r32g32b32_sfloat"},
			{"normal", "vec3", "r32g32b32_sfloat"},
			{"uv", "vec2", "r32g32_sfloat"},
			{"tangent", "vec4", "r32g32b32a32_sfloat"},
		},
		push_constants = {
			{
				name = "vertex",
				block = {
					{
						"projection_view_world",
						"mat4",
						function(self, block, key)
							render3d.GetProjectionViewWorldMatrix():CopyToFloatPointer(block[key])
						end,
					},
					{
						"world",
						"mat4",
						function(self, block, key)
							render3d.GetWorldMatrix():CopyToFloatPointer(block[key])
						end,
					},
				},
			},
		},
		shader = [[
			void main() {
				gl_Position = pc.vertex.projection_view_world * vec4(in_position, 1.0);
				out_position = (pc.vertex.world * vec4(in_position, 1.0)).xyz;						
				out_normal = normalize(mat3(pc.vertex.world) * in_normal);
				out_tangent = vec4(normalize(mat3(pc.vertex.world) * in_tangent.xyz), in_tangent.w);
				out_uv = in_uv;
			}
		]],
	},
	fragment = {
		push_constants = {
			{
				name = "model",
				block = {
					{
						"Flags",
						"int",
						function(self, block, key)
							block[key] = render3d.GetMaterial():GetFillFlags()
						end,
					},
					{
						"AlbedoTexture",
						"int",
						function(self, block, key)
							block[key] = render3d.gbuffer_pipeline:GetTextureIndex(render3d.GetMaterial():GetAlbedoTexture())
						end,
					},
					{
						"NormalTexture",
						"int",
						function(self, block, key)
							block[key] = render3d.gbuffer_pipeline:GetTextureIndex(render3d.GetMaterial():GetNormalTexture())
						end,
					},
					{
						"MetallicRoughnessTexture",
						"int",
						function(self, block, key)
							block[key] = render3d.gbuffer_pipeline:GetTextureIndex(render3d.GetMaterial():GetMetallicRoughnessTexture())
						end,
					},
					{
						"AmbientOcclusionTexture",
						"int",
						function(self, block, key)
							block[key] = render3d.gbuffer_pipeline:GetTextureIndex(render3d.GetMaterial():GetAmbientOcclusionTexture())
						end,
					},
					{
						"EmissiveTexture",
						"int",
						function(self, block, key)
							block[key] = render3d.gbuffer_pipeline:GetTextureIndex(render3d.GetMaterial():GetEmissiveTexture())
						end,
					},
					{
						"ColorMultiplier",
						"vec4",
						function(self, block, key)
							render3d.GetMaterial():GetColorMultiplier():CopyToFloatPointer(block[key])
						end,
					},
					{
						"MetallicMultiplier",
						"float",
						function(self, block, key)
							block[key] = render3d.GetMaterial():GetMetallicMultiplier()
						end,
					},
					{
						"RoughnessMultiplier",
						"float",
						function(self, block, key)
							block[key] = render3d.GetMaterial():GetRoughnessMultiplier()
						end,
					},
					{
						"AmbientOcclusionMultiplier",
						"float",
						function(self, block, key)
							block[key] = render3d.GetMaterial():GetAmbientOcclusionMultiplier()
						end,
					},
					{
						"EmissiveMultiplier",
						"vec4",
						function(self, block, key)
							render3d.GetMaterial():GetEmissiveMultiplier():CopyToFloatPointer(block[key])
						end,
					},
					{
						"AlphaCutoff",
						"float",
						function(self, block, key)
							block[key] = render3d.GetMaterial():GetAlphaCutoff()
						end,
					},
					{
						"MetallicTexture",
						"int",
						function(self, block, key)
							block[key] = render3d.gbuffer_pipeline:GetTextureIndex(render3d.GetMaterial():GetMetallicTexture())
						end,
					},
					{
						"RoughnessTexture",
						"int",
						function(self, block, key)
							block[key] = render3d.gbuffer_pipeline:GetTextureIndex(render3d.GetMaterial():GetRoughnessTexture())
						end,
					},
				},
			},
		},
		shader = [[
			]] .. Material.BuildGlslFlags("pc.model.Flags") .. [[

			vec3 get_albedo() {
				if (pc.model.AlbedoTexture == -1) {
					return pc.model.ColorMultiplier.rgb;
				}
				vec3 rgb = texture(TEXTURE(pc.model.AlbedoTexture), in_uv).rgb * pc.model.ColorMultiplier.rgb;
				return rgb;
			}

			float get_alpha() {

				if (
					pc.model.AlbedoTexture == -1 ||
					AlbedoTextureAlphaIsRoughness ||
					AlbedoTextureAlphaIsRoughness ||
					AlbedoAlphaIsEmissive
				) {
					return pc.model.ColorMultiplier.a;	
				}

				return texture(TEXTURE(pc.model.AlbedoTexture), in_uv).a * pc.model.ColorMultiplier.a;
			}

			void compute_translucency(inout float alpha) {
				if (AlphaTest) {
					if (alpha < pc.model.AlphaCutoff) discard;
				} else if (Translucent) {
					if (fract(dot(vec2(171.0, 231.0) + alpha * 0.00001, gl_FragCoord.xy) / 103.0) > (alpha * alpha)) discard;
				}
			}

			vec3 get_normal() {
				vec3 N;
				if (pc.model.NormalTexture == -1) {
					N = in_normal;
				} else {
					vec3 tangent_normal = texture(TEXTURE(pc.model.NormalTexture), in_uv).xyz * 2.0 - 1.0;
					
					vec3 normal = normalize(in_normal);
					vec3 tangent = normalize(in_tangent.xyz);
					vec3 bitangent = cross(normal, tangent) * in_tangent.w;
					mat3 TBN = mat3(tangent, bitangent, normal);

					N = TBN * tangent_normal;
				}

				if (DoubleSided && gl_FrontFacing) {
					N = -N;
				}

				return normalize(N);
			}

			float get_metallic() {
				float val = 1.0;

				if (pc.model.MetallicTexture != -1) {
					val = texture(TEXTURE(pc.model.MetallicTexture), in_uv).r;
				} else if (pc.model.MetallicRoughnessTexture != -1) {
					val = texture(TEXTURE(pc.model.MetallicRoughnessTexture), in_uv).b;
				} else {
					val = pc.model.MetallicMultiplier;
					val = clamp(val, 0, 1);
					return val;
				}

				val *= pc.model.MetallicMultiplier;
				val = clamp(val, 0, 1);

				return val;
			}

			float get_roughness() {
				float val = 1.0;

				if (pc.model.AlbedoTexture != -1 && AlbedoTextureAlphaIsRoughness) {
					val = texture(TEXTURE(pc.model.AlbedoTexture), in_uv).a;
				} else if (pc.model.NormalTexture != -1 && NormalTextureAlphaIsRoughness) {
					val = -texture(TEXTURE(pc.model.NormalTexture), in_uv).a+1;
				} else if (AlbedoLuminanceIsRoughness) {
					val = dot(get_albedo(), vec3(0.2126, 0.7152, 0.0722));
				} else if (pc.model.RoughnessTexture != -1) {
					val = texture(TEXTURE(pc.model.RoughnessTexture), in_uv).r;
				} else if (pc.model.MetallicRoughnessTexture != -1) {
					val = texture(TEXTURE(pc.model.MetallicRoughnessTexture), in_uv).g;
				} else  {
					val = pc.model.RoughnessMultiplier;
					val = clamp(val, 0.05, 0.95);
					return val;
				}

				val *= pc.model.RoughnessMultiplier;

				if (InvertRoughnessTexture) val = -val + 1.0;

				val = clamp(val, 0.05, 0.95);
				
				return val;
			}

			vec3 get_emissive() {
				if (AlbedoAlphaIsEmissive) {
					float mask = 1.0;
					if (pc.model.AlbedoTexture != -1) {
						mask = texture(TEXTURE(pc.model.AlbedoTexture), in_uv).a;
					}
					return get_albedo() * mask * pc.model.EmissiveMultiplier.rgb * pc.model.EmissiveMultiplier.a;
				}
				else if (pc.model.EmissiveTexture != -1) {
					float mask = texture(TEXTURE(pc.model.EmissiveTexture), in_uv).r;
					return get_albedo() * mask * pc.model.EmissiveMultiplier.rgb * pc.model.EmissiveMultiplier.a;
				} else if (pc.model.MetallicTexture != -1 && MetallicTextureAlphaIsEmissive) {
					float mask = texture(TEXTURE(pc.model.MetallicTexture), in_uv).a;
					return get_albedo() * mask * pc.model.EmissiveMultiplier.rgb * pc.model.EmissiveMultiplier.a;
				} else if (pc.model.EmissiveTexture != -1) {
					vec3 emissive = texture(TEXTURE(pc.model.EmissiveTexture), in_uv).rgb;
					return emissive * pc.model.EmissiveMultiplier.rgb * pc.model.EmissiveMultiplier.a;
				}
									return vec3(0);

			//	return (pc.model.EmissiveMultiplier.rgb - vec3(1)) * pc.model.EmissiveMultiplier.a;
			}

			float get_ao() {
				if (pc.model.AmbientOcclusionTexture == -1) {
					return 1.0 * pc.model.AmbientOcclusionMultiplier;
				}
				return texture(TEXTURE(pc.model.AmbientOcclusionTexture), in_uv).r * pc.model.AmbientOcclusionMultiplier;
			}

			void main() {
				float alpha = get_alpha();
				compute_translucency(alpha);
				set_alpha(alpha);
				set_albedo(get_albedo());
				set_normal(get_normal());
				set_metallic(get_metallic());
				set_roughness(get_roughness());
				set_ao(get_ao());
				set_emissive(get_emissive());
			}
		]],
	},
	rasterizer = {
		depth_clamp = false,
		discard = false,
		polygon_mode = "fill",
		line_width = 1.0,
		cull_mode = orientation.CULL_MODE,
		front_face = orientation.FRONT_FACE,
		depth_bias = 0,
	},
	dynamic_state = {
		"cull_mode",
	},
	color_blend = {
		logic_op_enabled = false,
		logic_op = "copy",
		constants = {0.0, 0.0, 0.0, 0.0},
		attachments = {
			{blend = false, color_write_mask = {"r", "g", "b", "a"}},
			{blend = false, color_write_mask = {"r", "g", "b", "a"}},
			{blend = false, color_write_mask = {"r", "g", "b", "a"}},
			{blend = false, color_write_mask = {"r", "g", "b", "a"}},
		},
	},
	depth_stencil = {
		depth_test = true,
		depth_write = true,
		depth_compare_op = "less",
		depth_bounds_test_enabled = false,
		stencil_test_enabled = false,
	},
}
render3d.ssr_config = {
	color_format = {{"r16g16b16a16_sfloat", {"ssr", "rgba"}}},
	vertex = quad_vertex_config,
	fragment = {
		custom_declarations = quad_vertex_config.fragment_code,
		uniform_buffers = {
			{
				name = "ssr_data",
				binding_index = 3,
				block = {
					camera_block,
					{
						"normal_tex",
						"int",
						function(self, block, key)
							block[key] = self:GetTextureIndex(render3d.gbuffer:GetAttachment(2))
						end,
					},
					{
						"mra_tex",
						"int",
						function(self, block, key)
							block[key] = self:GetTextureIndex(render3d.gbuffer:GetAttachment(3))
						end,
					},
					{
						"depth_tex",
						"int",
						function(self, block, key)
							block[key] = self:GetTextureIndex(render3d.gbuffer:GetDepthTexture())
						end,
					},
					{
						"blue_noise_tex",
						"int",
						function(self, block, key)
							block[key] = self:GetTextureIndex(GetBlueNoiseTexture())
						end,
					},
					last_frame_block,
					common_block,
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
}
render3d.ssr_resolve_config = {
	vertex = quad_vertex_config,
	fragment = {
		custom_declarations = quad_vertex_config.fragment_code,
		uniform_buffers = {
			{
				name = "resolve_data",
				binding_index = 3,
				block = {
					camera_block,
					{
						"current_ssr_tex",
						"int",
						function(self, block, key)
							if not render3d.ssr_trace_fb then
								block[key] = -1
								return
							end

							block[key] = self:GetTextureIndex(render3d.ssr_trace_fb:GetAttachment(1))
						end,
					},
					{
						"history_ssr_tex",
						"int",
						function(self, block, key)
							if not render3d.ssr_fbs then
								block[key] = -1
								return
							end

							local prev_idx = 3 - render3d.current_ssr_fb_index
							block[key] = self:GetTextureIndex(render3d.ssr_fbs[prev_idx]:GetAttachment(1))
						end,
					},
					{
						"depth_tex",
						"int",
						function(self, block, key)
							block[key] = self:GetTextureIndex(render3d.gbuffer:GetDepthTexture())
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
}
render3d.lighting_config = {
	color_format = {{"r16g16b16a16_sfloat", {"color", "rgba"}}},
	vertex = quad_vertex_config,
	fragment = {
		custom_declarations = quad_vertex_config.fragment_code .. [[

			struct ShadowData {
				mat4 light_space_matrices[4];
				vec4 cascade_splits;
				ivec4 shadow_map_indices;
				int cascade_count;
			};

			struct Light {
				vec4 position; // w = type
				vec4 color;    // w = intensity
				vec4 params;   // x = range, y = inner, z = outer
			};

			layout(std140, binding = 2) uniform LightData {
				ShadowData shadow;
				Light lights[32];
			} light_data;
		]],
		descriptor_sets = {
			{
				type = "uniform_buffer",
				binding_index = 2,
				args = function()
					return {Light.GetUBO()}
				end,
			},
		},
		uniform_buffers = {
			{
				name = "lighting_data",
				binding_index = 3,
				block = {
					camera_block,
					{
						"ssao_kernel",
						"vec3",
						function(self, block, key)
							local kernel = {}

							for i = 1, 64 do
								math.randomseed(i)
								local sample = Vec3(math.random() * 2 - 1, math.random() * 2 - 1, math.random()):Normalize()
								sample = sample * math.random()
								local scale = (i - 1) / 64
								scale = math.lerp(0.1, 1.0, scale * scale)
								sample = sample * scale
								table.insert(kernel, sample)
							end

							return function(self, block, key)
								for i, v in ipairs(render3d.ssao_kernel) do
									v:CopyToFloatPointer(block[key][i - 1])
								end
							end
						end,
						64,
					},
					{
						"light_count",
						"int",
						function(self, block, key)
							block[key] = math.min(#Light.GetLights(), 32)
						end,
					},
					debug_block,
					gbuffer_block,
					{
						"env_tex",
						"int",
						function(self, block, key)
							block[key] = self:GetTextureIndex(render3d.GetEnvironmentTexture())
						end,
					},
					{
						"blue_noise_tex",
						"int",
						function(self, block, key)
							block[key] = self:GetTextureIndex(GetBlueNoiseTexture())
						end,
					},
					last_frame_block,
					common_block,
					{
						"stars_texture_index",
						"int",
						function(self, block, key)
							block[key] = self:GetTextureIndex(atmosphere.GetStarsTexture())
						end,
					},
					{
						"ssr_tex",
						"int",
						function(self, block, key)
							if not render3d.ssr_fb then
								block[key] = -1
								return
							end

							block[key] = self:GetTextureIndex(render3d.ssr_fb:GetAttachment(1))
						end,
					},
					{
						"probe_indices",
						"int",
						function(self, block, key)
							if not reflection_probe.IsEnabled() then
								for i = 0, 63 do
									block[key][i] = -1
								end

								return
							end

							for i = 0, 63 do
								local cubemap = reflection_probe.GetCubemap(i)
								block[key][i] = cubemap and self:GetTextureIndex(cubemap) or -1
							end
						end,
						64,
					},
					{
						"probe_depth_indices",
						"int",
						function(self, block, key)
							if not reflection_probe.IsEnabled() then
								for i = 0, 63 do
									block[key][i] = -1
								end

								return
							end

							for i = 0, 63 do
								local depth_cubemap = reflection_probe.GetDepthCubemap(i)
								block[key][i] = depth_cubemap and self:GetTextureIndex(depth_cubemap) or -1
							end
						end,
						64,
					},
					{
						"probe_positions",
						"vec4",
						function(self, block, key)
							if not reflection_probe.IsEnabled() then return end

							for i = 0, 63 do
								local pos = reflection_probe.GetProbePosition(i)

								if pos then
									block[key][i][0] = pos.x
									block[key][i][1] = pos.y
									block[key][i][2] = pos.z
									block[key][i][3] = 0
								else
									block[key][i][0] = 0
									block[key][i][1] = 0
									block[key][i][2] = 0
									block[key][i][3] = -1 -- Mark as invalid
								end
							end
						end,
						64,
					},
					{
						"probe_grid_origin",
						"vec4",
						function(self, block, key)
							local origin = reflection_probe.GRID_ORIGIN
							block[key][0] = origin.x
							block[key][1] = origin.y
							block[key][2] = origin.z
							block[key][3] = 0
						end,
					},
					{
						"probe_grid_spacing",
						"vec4",
						function(self, block, key)
							local spacing = reflection_probe.GRID_SPACING
							block[key][0] = spacing.x
							block[key][1] = spacing.y
							block[key][2] = spacing.z
							block[key][3] = 0
						end,
					},
					{
						"probe_grid_counts",
						"ivec4",
						function(self, block, key)
							local counts = reflection_probe.GRID_COUNTS
							block[key][0] = counts.x
							block[key][1] = counts.y
							block[key][2] = counts.z
							block[key][3] = 0
						end,
					},
				},
			},
		},
		shader = [[
			vec3 get_albedo() {
				return texture(TEXTURE(lighting_data.albedo_tex), in_uv).rgb;
			}

			float get_alpha() {
				return texture(TEXTURE(lighting_data.albedo_tex), in_uv).a;
			}

			float get_depth() {
				return texture(TEXTURE(lighting_data.depth_tex), in_uv).r;
			}

			vec3 get_normal() {
				return texture(TEXTURE(lighting_data.normal_tex), in_uv).xyz;
			}

			float get_metallic() {
				vec3 mra = texture(TEXTURE(lighting_data.mra_tex), in_uv).rgb;
				return mra.r;
			}

			float get_roughness() {
				vec3 mra = texture(TEXTURE(lighting_data.mra_tex), in_uv).rgb;
				return mra.g;
			}

			float get_ao() {
				vec3 mra = texture(TEXTURE(lighting_data.mra_tex), in_uv).rgb;
				return mra.b;
			}

			vec3 get_emissive() {
				return texture(TEXTURE(lighting_data.emissive_tex), in_uv).rgb;
			}


			]] .. require("render3d.atmosphere").GetGLSLCode() .. [[


			#define SSR 0
			#define PARALLAX_CORRECTION 1
			#define uv in_uv
			float hash(vec2 p) {
				p = fract(p * vec2(123.34, 456.21));
				p += dot(p, p + 45.32);
				return fract(p.x * p.y);
			}

			vec3 random_vec3(vec2 p) {
				return vec3(hash(p), hash(p + 1.0), hash(p + 2.0)) * 2.0 - 1.0;
			}

			#define saturate(x) clamp(x, 0.0, 1.0)

            float pow5(float x) {
                float x2 = x * x;
                return x2 * x2 * x;
            }

            float D_GGX(float roughness, float NoH) {
                float oneMinusNoHSquared = 1.0 - NoH * NoH;
                float a = NoH * roughness;
                float k = roughness / (oneMinusNoHSquared + a * a);
                float d = k * (k * (1.0 / PI));
                return d;
            }

            float V_SmithGGXCorrelated(float roughness, float NoV, float NoL) {
                float a2 = roughness * roughness;
                float lambdaV = NoL * sqrt((NoV - a2 * NoV) * NoV + a2);
                float lambdaL = NoV * sqrt((NoL - a2 * NoL) * NoL + a2);
                float v = 0.5 / (lambdaV + lambdaL);
                return v;
            }

            vec3 F_Schlick(const vec3 f0, float VoH) {
                float f = pow(1.0 - VoH, 5.0);
                return f + f0 * (1.0 - f);
            }

            float Fd_Lambert() {
                return 1.0 / PI;
            }

            // Approximate BRDF integration (Karis/Epic Games approximation)
            vec2 envBRDFApprox(float NdotV, float roughness) {
                vec4 c0 = vec4(-1.0, -0.0275, -0.572, 0.022);
                vec4 c1 = vec4(1.0, 0.0425, 1.04, -0.04);
                vec4 r = roughness * c0 + c1;
                float a004 = min(r.x * r.x, exp2(-9.28 * NdotV)) * r.x + r.y;
                return vec2(-1.04, 1.04) * a004 + r.zw;
            }

			// Cascade debug colors
			const vec3 CASCADE_COLORS[4] = vec3[4](
				vec3(1.0, 0.2, 0.2),  // Red - cascade 1
				vec3(0.2, 1.0, 0.2),  // Green - cascade 2
				vec3(0.2, 0.2, 1.0),  // Blue - cascade 3
				vec3(1.0, 1.0, 0.2)   // Yellow - cascade 4
			);

			float random(vec2 co)
			{
				return fract(sin(dot(co.xy ,vec2(12.9898,78.233))) * 43758.5453);
			}
			vec3 get_noise3_world(vec3 world_pos)
			{
				float x = random(world_pos.xy);
				float y = random(world_pos.yz * x);
				float z = random(world_pos.xz * y);

				return vec3(x, y, z) * 2.0 - 1.0;
			}

			// Get cascade index based on view distance
			int getCascadeIndex(vec3 world_pos) {
				float dist = length(world_pos - lighting_data.camera_position.xyz);
				
				for (int i = 0; i < light_data.shadow.cascade_count; i++) {
					if (dist < light_data.shadow.cascade_splits[i]) {
						return i;
					}
				}
				return light_data.shadow.cascade_count - 1;
			}

			// PCF Shadow calculation
			float calculateShadow(vec3 world_pos, vec3 normal, vec3 light_dir) {
				int cascade_idx = getCascadeIndex(world_pos);
				if (cascade_idx < 0) return 1.0;
				
				int shadow_map_idx = light_data.shadow.shadow_map_indices[cascade_idx];
				if (shadow_map_idx < 0) return 1.0;
				
				float bias_val = max(0.05 * (1.0 - dot(normal, light_dir)), 0.005);
				vec3 offset_pos = world_pos + normal * bias_val;
				vec4 light_space_pos = light_data.shadow.light_space_matrices[cascade_idx] * vec4(offset_pos, 1.0);
				vec3 proj_coords = light_space_pos.xyz / light_space_pos.w;
				proj_coords.xy = proj_coords.xy * 0.5 + 0.5;
				
				if (proj_coords.z > 1.0 || proj_coords.z < 0.0 || proj_coords.x < 0.0 || proj_coords.x > 1.0 || proj_coords.y < 0.0 || proj_coords.y > 1.0) {
					return 1.0;
				}
				vec2 texel_size = 1.0 / textureSize(TEXTURE(shadow_map_idx), 0);
				float current_depth = proj_coords.z;
				float shadow_val = 0.0;
				for (int x = -1; x <= 1; ++x) {
					for (int y = -1; y <= 1; ++y) {
						float pcf_depth = texture(TEXTURE(shadow_map_idx), proj_coords.xy + vec2(x, y) * texel_size).r;
						shadow_val += current_depth - 0.001 > pcf_depth ? 0.0 : 1.0;
					}
				}
				return shadow_val / 9.0;
			}

			vec3 env_color(vec3 normal, float roughness, vec3 V, vec3 world_pos) {
				vec3 R = reflect(-V, normal);
				R = mix(R, normal, roughness * roughness);
				R = normalize(R);

				float max_mip = float(textureQueryLevels(CUBEMAP(lighting_data.env_tex)) - 1);
				float mip_level = roughness * max_mip;

				vec3 env = textureLod(CUBEMAP(lighting_data.env_tex), R, mip_level).rgb;

				#if SSR
				vec4 ssr = texture(TEXTURE(lighting_data.ssr_tex), in_uv);
				env = mix(env, ssr.rgb, ssr.a);
				#endif

				{return env;}
				// TODO

				vec3 total_env = vec3(0.0);
				float total_weight = 0.0;

				// DDGI-style grid lookup
				vec3 grid_pos = (world_pos - lighting_data.probe_grid_origin.xyz) / lighting_data.probe_grid_spacing.xyz;
				ivec3 base_coord = ivec3(floor(grid_pos));
				vec3 alpha = fract(grid_pos);

				for (int i = 0; i < 8; i++) {
					ivec3 offset = ivec3(i & 1, (i >> 1) & 1, (i >> 2) & 1);
					ivec3 coord = base_coord + offset;

					if (any(lessThan(coord, ivec3(0))) || any(greaterThanEqual(coord, lighting_data.probe_grid_counts.xyz))) {
						continue;
					}

					int probe_idx = coord.x + coord.y * lighting_data.probe_grid_counts.x + coord.z * lighting_data.probe_grid_counts.x * lighting_data.probe_grid_counts.y;
					int tex_idx = lighting_data.probe_indices[probe_idx];
					if (tex_idx == -1) continue;

					vec3 probe_pos = lighting_data.probe_positions[probe_idx].xyz;
					vec3 probe_to_point = world_pos - probe_pos;
					vec3 dir_to_point = normalize(probe_to_point);
					float dist_to_point = length(probe_to_point);

					// Trilinear weight
					vec3 trilinear = mix(1.0 - alpha, alpha, vec3(offset));
					float weight = trilinear.x * trilinear.y * trilinear.z;

					// Smooth backface test
					float weight_normal = max(0.05, dot(dir_to_point, normal));
					weight *= weight_normal * weight_normal;

					// Visibility test (using depth cubemap)
					int depth_tex_idx = lighting_data.probe_depth_indices[probe_idx];
					if (depth_tex_idx != -1) {
						float captured_depth = texture(CUBEMAP(depth_tex_idx), dir_to_point).r;
						// Smooth visibility test to prevent light leaking and hard edges
						float visibility = smoothstep(captured_depth + 1.0, captured_depth + 0.2, dist_to_point);
						weight *= visibility;
					}

					if (weight > 0.0) {
						float max_mip = float(textureQueryLevels(CUBEMAP(tex_idx)) - 1);
						float mip_level = roughness * max_mip;
						
						// Parallax correction (simple sphere-based)
						vec3 corrected_R = R;
						float sphere_radius = 20.0;
						vec3 ray_origin = world_pos - probe_pos;
						float b = dot(ray_origin, R);
						float c = dot(ray_origin, ray_origin) - sphere_radius * sphere_radius;
						float discriminant = b * b - c;
						if (discriminant >= 0.0) {
							float t = -b + sqrt(discriminant);
							corrected_R = normalize(ray_origin + t * R);
						}

						vec3 env = textureLod(CUBEMAP(tex_idx), corrected_R, mip_level).rgb;
						total_env += env * weight;
						total_weight += weight;
					}
				}

				env = vec3(0.0);
				if (total_weight > 0.001) {
					env = total_env / total_weight;
				}
				
				// Blend with global environment if weights are low
				if (total_weight < 1.0 && lighting_data.env_tex != -1) {
					float max_mip = float(textureQueryLevels(CUBEMAP(lighting_data.env_tex)) - 1);
					float mip_level = roughness * max_mip;
					vec3 global_env = textureLod(CUBEMAP(lighting_data.env_tex), R, mip_level).rgb;
					env = mix(global_env, env, clamp(total_weight, 0.0, 1.0));
				} else if (total_weight <= 0.001) {
					if (lighting_data.env_tex != -1) {
						float max_mip = float(textureQueryLevels(CUBEMAP(lighting_data.env_tex)) - 1);
						float mip_level = roughness * max_mip;
						env = textureLod(CUBEMAP(lighting_data.env_tex), R, mip_level).rgb;
					} else {
						env = vec3(0.2);
					}
				}

				#if SSR
				ssr = texture(TEXTURE(lighting_data.ssr_tex), in_uv);
				return mix(env, ssr.rgb, ssr.a);
				#else
				return env;
				#endif
			}

			vec3 get_ssao(vec2 uv, vec3 world_pos, vec3 N) {
				if (lighting_data.blue_noise_tex == -1) return vec3(1.0);

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
				float thickness = 0.1; 
				float bias = 0.1;

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
				return vec3(pow(clamp(ao, 0.0, 1.0), 2.5));
			}

			void main() {
				vec3 alpha = get_albedo();
				//if (alpha.a == 0.0) discard;
				float depth = get_depth();
				vec3 albedo = get_albedo();

				if (depth == 1.0) {
					// Skybox or background
					vec3 sky_color_output;
					vec3 sunDir = normalize(-light_data.lights[0].position.xyz);
					vec4 clip_pos = vec4(in_uv * 2.0 - 1.0, 1.0, 1.0);
					vec4 view_pos = lighting_data.inv_projection * clip_pos;
					view_pos /= view_pos.w;
					vec3 world_pos = (lighting_data.inv_view * view_pos).xyz;
					vec3 dir = normalize(world_pos - lighting_data.camera_position.xyz);
					
					]] .. require("render3d.atmosphere").GetGLSLMainCode(
				"dir",
				"sunDir",
				"lighting_data.camera_position.xyz",
				"lighting_data.stars_texture_index"
			) .. [[
					
					set_color(vec4(sky_color_output, 1.0));
					return;
				}

				vec3 N = get_normal();
				float metallic = get_metallic();
				float roughness = get_roughness();
				float ao = get_ao();
				vec3 emissive = get_emissive();

				// Reconstruct world position from depth
				vec4 clip_pos = vec4(in_uv * 2.0 - 1.0, depth, 1.0);
				vec4 view_pos = lighting_data.inv_projection * clip_pos;
				view_pos /= view_pos.w;
				vec3 world_pos = (lighting_data.inv_view * view_pos).xyz;
			
				vec3 V = normalize(lighting_data.camera_position.xyz - world_pos);
				vec3 reflection = env_color(N, roughness, V, world_pos);
				vec3 F0 = mix(vec3(0.04), albedo, metallic);
				float NdotV = max(dot(N, V), 0.001);

				float r2 = roughness * roughness;
                vec3 Lo = vec3(0.0);
                for (int i = 0; i < lighting_data.light_count; i++) {
                    Light light = light_data.lights[i];
                    int type = int(light.position.w);
                    vec3 L;
                    float attenuation = 1.0;
                    if (type == 0) {
                        L = normalize(-light.position.xyz);
                    } else {
                        vec3 light_to_pos = light.position.xyz - world_pos;
                        float dist = length(light_to_pos);
                        L = normalize(light_to_pos);
                        float range = light.params.x;
                        attenuation = saturate(1.0 - dist / range);
                        attenuation *= attenuation;
                    }
                    vec3 H = normalize(V + L);
                    float NoL = saturate(dot(N, L));
                    float NoH = saturate(dot(N, H));
                    float LoH = saturate(dot(L, H));

                    float D = D_GGX(r2, NoH);
                    float V_func = V_SmithGGXCorrelated(r2, NdotV, NoL);
                    vec3 F = F_Schlick(F0, LoH);

                    vec3 Fr = (D * V_func) * F;
                    vec3 kD = vec3(1.0 - metallic);
                    vec3 Fd = kD * albedo * Fd_Lambert();

                    float shadow_factor = 1.0;
                    if (i == 0 && light_data.shadow.shadow_map_indices[0] >= 0) {
                        shadow_factor = calculateShadow(world_pos, N, L);
                    }
                    vec3 radiance = light.color.rgb * light.color.a * attenuation;
                    Lo += (Fd + Fr) * radiance * NoL * shadow_factor;
                }

				vec3 ssao = get_ssao(in_uv, world_pos, N);
                vec3 ambient_diffuse = reflection * albedo * (1.0 - metallic) * ao * ssao;
                
                // Split-sum IBL with BRDF approximation
                //vec2 envBRDF = envBRDFApprox(NdotV, roughness);
                //vec3 ambient_specular = reflection * (F0 * envBRDF.x + envBRDF.y) * ao * ssao;
                
        		vec3 F_ambient = F_Schlick(F0, NdotV);
                vec3 ambient_specular = F_ambient * reflection * ao * ssao;

                vec3 ambient = ambient_diffuse + ambient_specular;
                vec3 color = ambient + Lo + emissive;

				if (lighting_data.debug_cascade_colors != 0) {
					int cascade_idx = getCascadeIndex(world_pos);
					color = mix(color, CASCADE_COLORS[cascade_idx], 0.4);
				}

				]] .. render3d.debug_mode_glsl .. [[

				set_color(vec4(color, alpha));
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
}
render3d.blit_config = {
	color_format = {
		{
			function()
				return render.target.color_format
			end,
			{"color", "rgba"},
		},
	},
	depth_format = function()
		return render.target.depth_format
	end,
	vertex = quad_vertex_config,
	fragment = {
		custom_declarations = quad_vertex_config.fragment_code,
		push_constants = {
			{
				name = "blit",
				block = {
					{
						"tex",
						"int",
						function(self, block, key)
							if not render3d.lighting_fbs then
								block[key] = -1
								return
							end

							block[key] = self:GetTextureIndex(render3d.lighting_fbs[render3d.current_lighting_fb_index]:GetAttachment(1))
						end,
					},
				},
			},
		},
		shader = [[
			// https://knarkowicz.wordpress.com/2016/01/06/aces-filmic-tone-mapping-curve/
			vec3 ACESFilm(vec3 x){
				return clamp((x * (2.51 * x + 0.03)) / (x * (2.43 * x + 0.59) + 0.14), 0.0, 1.0);
			}

			#define GAMMA 2.2
			#define INV_GAMMA (1.0/GAMMA)
			vec3 gamma(vec3 col){
				return pow(col, vec3(INV_GAMMA));
			}

			void main() {
				if (pc.blit.tex == -1) {
					set_color(vec4(1.0, 0.0, 1.0, 1.0));
					return;
				}
				vec3 col = texture(TEXTURE(pc.blit.tex), in_uv).rgb;

				// Tone mapping
				col = ACESFilm(col);

				col = gamma(col);
				
				set_color(vec4(col, 1.0));
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
}

function render3d.Initialize()
	local function create_gbuffer()
		local size = window:GetSize()
		render3d.gbuffer = Framebuffer.New(
			{
				width = size.x,
				height = size.y,
				formats = EasyPipeline.GetColorFormats(render3d.gbuffer_config),
				depth = true,
				depth_format = "d32_sfloat",
			}
		)
	end

	local function create_lighting_fbs()
		local size = window:GetSize()
		render3d.lighting_fbs = {}

		for i = 1, 2 do
			render3d.lighting_fbs[i] = Framebuffer.New(
				{
					width = size.x,
					height = size.y,
					formats = EasyPipeline.GetColorFormats(render3d.lighting_config),
					depth = false,
				}
			)
		end

		render3d.current_lighting_fb_index = 1
	end

	local function create_ssr_fb()
		local size = window:GetSize()
		-- Full resolution SSR with ping-pong for temporal accumulation
		render3d.ssr_fbs = {}

		for i = 1, 2 do
			render3d.ssr_fbs[i] = Framebuffer.New(
				{
					width = size.x,
					height = size.y,
					formats = EasyPipeline.GetColorFormats(render3d.ssr_config),
					depth = false,
				}
			)
		end

		render3d.ssr_trace_fb = Framebuffer.New(
			{
				width = size.x,
				height = size.y,
				formats = EasyPipeline.GetColorFormats(render3d.ssr_config),
				depth = false,
			}
		)
		render3d.current_ssr_fb_index = 1
		-- Keep ssr_fb as alias for current for compatibility
		render3d.ssr_fb = render3d.ssr_fbs[1]
	end

	local function create_blue_noise_texture()
		render3d.ssao_kernel = {}
	end

	create_gbuffer()
	create_lighting_fbs()
	create_ssr_fb()
	create_blue_noise_texture()
	render3d.gbuffer_pipeline = EasyPipeline.New(render3d.gbuffer_config)
	render3d.ssr_pipeline = EasyPipeline.New(render3d.ssr_config)
	render3d.ssr_resolve_config.color_format = render3d.ssr_config.color_format
	render3d.ssr_resolve_pipeline = EasyPipeline.New(render3d.ssr_resolve_config)
	render3d.lighting_pipeline = EasyPipeline.New(render3d.lighting_config)
	render3d.blit_pipeline = EasyPipeline.New(render3d.blit_config)

	event.AddListener("WindowFramebufferResized", "render3d_gbuffer", function(wnd, size)
		create_gbuffer()
		create_lighting_fbs()
		create_ssr_fb()
		-- Update lighting pipeline descriptor sets with new G-buffer textures
		local textures = {}

		for _, tex in ipairs(render3d.gbuffer.color_textures) do
			table.insert(textures, {view = tex.view, sampler = tex.sampler})
		end

		table.insert(
			textures,
			{
				view = render3d.gbuffer.depth_texture.view,
				sampler = render3d.gbuffer.depth_texture.sampler,
			}
		)

		for i = 1, #render3d.lighting_pipeline.pipeline.descriptor_sets do
			render3d.lighting_pipeline.pipeline:UpdateDescriptorSetArray(i, 0, textures)
		end

		for i = 1, #render3d.ssr_pipeline.pipeline.descriptor_sets do
			render3d.ssr_pipeline.pipeline:UpdateDescriptorSetArray(i, 0, textures)
		end

		for i = 1, #render3d.ssr_resolve_pipeline.pipeline.descriptor_sets do
			render3d.ssr_resolve_pipeline.pipeline:UpdateDescriptorSetArray(i, 0, textures)
		end

		for i = 1, #render3d.blit_pipeline.pipeline.descriptor_sets do
			render3d.blit_pipeline.pipeline:UpdateDescriptorSetArray(i, 0, textures)
		end
	end)

	event.AddListener("PreRenderPass", "draw_3d_geometry", function(cmd)
		if not render3d.gbuffer_pipeline then return end

		local dt = 0 -- dt is not easily available here, but usually not needed for draw calls
		Light.UpdateUBOs(render3d.lighting_pipeline.pipeline)
		-- 1. Geometry Pass
		render3d.gbuffer:Begin(cmd)

		do
			render3d.gbuffer_pipeline:Bind(cmd)
			event.Call("PreDraw3D", cmd, dt)
			event.Call("Draw3DGeometry", cmd, dt)
		end

		render3d.gbuffer:End(cmd)

		-- 1.5 SSR Pass
		if render3d.ssr_fbs and render3d.ssr_pipeline and render3d.ssr_resolve_pipeline then
			-- 1.5.1 Trace
			render3d.ssr_trace_fb:Begin(cmd)
			cmd:SetCullMode("none")
			render3d.ssr_pipeline:Bind(cmd)
			render3d.ssr_pipeline:UploadConstants(cmd)
			cmd:Draw(3, 1, 0, 0)
			render3d.ssr_trace_fb:End(cmd)
			-- 1.5.2 Resolve
			local current_ssr_fb = render3d.ssr_fbs[render3d.current_ssr_fb_index]
			current_ssr_fb:Begin(cmd)
			render3d.ssr_resolve_pipeline:Bind(cmd)
			render3d.ssr_resolve_pipeline:UploadConstants(cmd)
			cmd:Draw(3, 1, 0, 0)
			current_ssr_fb:End(cmd)
			-- Use resolved result for lighting
			render3d.ssr_fb = current_ssr_fb
		end

		-- 2. Lighting Pass (Offscreen)
		local current_fb = render3d.lighting_fbs[render3d.current_lighting_fb_index]
		current_fb:Begin(cmd)
		cmd:SetCullMode("none")
		render3d.lighting_pipeline:Bind(cmd)
		render3d.lighting_pipeline:UploadConstants(cmd)
		cmd:Draw(3, 1, 0, 0)
		current_fb:End(cmd)
	end)

	event.AddListener("Draw", "draw_3d_lighting", function(cmd, dt)
		if not render3d.gbuffer_pipeline then return end

		-- 3. Blit Lighting to Screen
		cmd:SetCullMode("none")
		render3d.blit_pipeline:Bind(cmd)
		render3d.blit_pipeline:UploadConstants(cmd)
		cmd:Draw(3, 1, 0, 0)
		-- Store current matrices for next frame reprojection
		render3d.prev_view_matrix = render3d.camera:BuildViewMatrix():Copy()
		render3d.prev_projection_matrix = render3d.camera:BuildProjectionMatrix():Copy()
		-- Swap framebuffers for next frame
		render3d.current_lighting_fb_index = 3 - render3d.current_lighting_fb_index
		render3d.current_ssr_fb_index = 3 - render3d.current_ssr_fb_index
	end)

	event.Call("Render3DInitialized")
end

function render3d.BindPipeline()
	render3d.gbuffer_pipeline:Bind(render.GetCommandBuffer())
end

function render3d.UploadConstants(cmd)
	if render3d.gbuffer_pipeline then
		do
			cmd:SetCullMode(render3d.GetMaterial():GetDoubleSided() and "none" or orientation.CULL_MODE)
		end

		render3d.gbuffer_pipeline:UploadConstants(cmd)
	end
end

do
	render3d.camera = render3d.camera or Camera3D.New()
	render3d.world_matrix = render3d.world_matrix or Matrix44()

	function render3d.GetCamera()
		return render3d.camera
	end

	function render3d.SetWorldMatrix(world)
		render3d.world_matrix = world
	end

	function render3d.GetWorldMatrix()
		return render3d.world_matrix
	end

	local pvm_cached = Matrix44()

	function render3d.GetProjectionViewWorldMatrix()
		-- ORIENTATION / TRANSFORMATION: Coordinate system defined in orientation.lua
		-- Row-major: v * W * V * P
		render3d.world_matrix:GetMultiplied(render3d.camera:BuildViewMatrix(), pvm_cached)
		pvm_cached:GetMultiplied(render3d.camera:BuildProjectionMatrix(), pvm_cached)
		return pvm_cached
	end
end

function render3d.SetLights(lights)
	Light.SetLights(lights)
end

function render3d.GetLights()
	return Light.GetLights()
end

-- Debug state for cascade visualization
render3d.debug_cascade_colors = false

function render3d.SetDebugCascadeColors(enabled)
	render3d.debug_cascade_colors = enabled
end

function render3d.GetDebugCascadeColors()
	return render3d.debug_cascade_colors
end

event.AddListener("WindowFramebufferResized", "render3d", function(wnd, size)
	render3d.camera:SetViewport(Rect(0, 0, size.x, size.y))
end)

function render3d.SetMaterial(mat)
	render3d.current_material = mat
end

function render3d.GetMaterial()
	return render3d.current_material or render3d.GetDefaultMaterial()
end

do
	local default = Material.New()

	function render3d.GetDefaultMaterial()
		return default
	end
end

function render3d.SetEnvironmentTexture(texture)
	render3d.environment_texture = texture
end

function render3d.GetEnvironmentTexture()
	return render3d.environment_texture
end

do -- mesh
	local Mesh = require("render.mesh")

	function render3d.CreateMesh(vertices, indices, index_type, index_count)
		return Mesh.New(
			render3d.gbuffer_pipeline:GetVertexAttributes(),
			vertices,
			indices,
			index_type,
			index_count
		)
	end
end

if HOTRELOAD then render3d.Initialize() end

return render3d
