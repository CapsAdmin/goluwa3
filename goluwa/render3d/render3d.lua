local ffi = require("ffi")
local render = require("render.render")
local EasyPipeline = require("render.easy_pipeline")
local event = require("event")
local ecs = require("ecs")
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
local lightprobes = require("render3d.lightprobes")
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
render3d.camera_block = camera_block
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
	local debug_modes = {"none", "normals", "irradiance", "ambient_occlusion", "ssr", "probe"}
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
			color = irradiance;
		} else if (debug_mode == 3) {
			color = vec3(ambient_occlusion);
		} else if (debug_mode == 4) {
			color = texture(TEXTURE(lighting_data.ssr_tex), in_uv).rgb;
		} else if (debug_mode == 5) {
			// Probe debug - show probe cubemap contribution
			color = get_reflection(N, 0, V, world_pos);
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
			block[key] = self:GetTextureIndex(render3d.pipelines.gbuffer:GetFramebuffer():GetAttachment(1))
		end,
	},
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
		"emissive_tex",
		"int",
		function(self, block, key)
			block[key] = self:GetTextureIndex(render3d.pipelines.gbuffer:GetFramebuffer():GetAttachment(4))
		end,
	},
	{
		"depth_tex",
		"int",
		function(self, block, key)
			block[key] = self:GetTextureIndex(render3d.pipelines.gbuffer:GetFramebuffer():GetDepthTexture())
		end,
	},
}
local last_frame_block = {
	{
		"last_frame_tex",
		"int",
		function(self, block, key)
			if not render3d.pipelines.lighting or not render3d.pipelines.lighting.framebuffers then
				block[key] = -1
				return
			end

			local prev_idx = (system.GetFrameNumber() + 1) % 2 + 1
			block[key] = self:GetTextureIndex(render3d.pipelines.lighting:GetFramebuffer(prev_idx):GetAttachment(1))
		end,
	},
}
local pipelines = {
	{
		name = "gbuffer",
		on_draw = function(self, cmd)
			event.Call("PreDraw3D", cmd, dt)
			event.Call("Draw3DGeometry", cmd, dt)
		end,
		color_format = {
			{"r8g8b8a8_srgb", {"albedo", "rgb"}, {"alpha", "a"}},
			{"r16g16b16a16_sfloat", {"normal", "rgb"}},
			{"r8g8b8a8_unorm", {"metallic", "r"}, {"roughness", "g"}, {"ao", "b"}},
			{"r16g16b16a16_sfloat", {"emissive", "rgb"}}, -- HDR emissive can exceed 1.0
		},
		depth_format = "d32_sfloat",
		vertex = {
			binding_index = 0,
			attributes = {
				{"position", "vec3", "r32g32b32_sfloat"},
				{"normal", "vec3", "r32g32b32_sfloat"},
				{"uv", "vec2", "r32g32_sfloat"},
				{"tangent", "vec4", "r32g32b32a32_sfloat"},
				{"texture_blend", "float", "r32_sfloat"},
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
				out_texture_blend = in_texture_blend;
			}
		]],
		},
		fragment = {
			uniform_buffers = {
				{
					name = "debug_data",
					binding_index = 3,
					block = {
						debug_block,
					},
				},
			},
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
								block[key] = render3d.pipelines.gbuffer:GetTextureIndex(render3d.GetMaterial():GetAlbedoTexture())
							end,
						},
						{
							"Albedo2Texture",
							"int",
							function(self, block, key)
								block[key] = render3d.pipelines.gbuffer:GetTextureIndex(render3d.GetMaterial():GetAlbedo2Texture())
							end,
						},
						{
							"NormalTexture",
							"int",
							function(self, block, key)
								block[key] = render3d.pipelines.gbuffer:GetTextureIndex(render3d.GetMaterial():GetNormalTexture())
							end,
						},
						{
							"Normal2Texture",
							"int",
							function(self, block, key)
								block[key] = render3d.pipelines.gbuffer:GetTextureIndex(render3d.GetMaterial():GetNormal2Texture())
							end,
						},
						{
							"BlendTexture",
							"int",
							function(self, block, key)
								block[key] = render3d.pipelines.gbuffer:GetTextureIndex(render3d.GetMaterial():GetBlendTexture())
							end,
						},
						{
							"MetallicRoughnessTexture",
							"int",
							function(self, block, key)
								block[key] = render3d.pipelines.gbuffer:GetTextureIndex(render3d.GetMaterial():GetMetallicRoughnessTexture())
							end,
						},
						{
							"AmbientOcclusionTexture",
							"int",
							function(self, block, key)
								block[key] = render3d.pipelines.gbuffer:GetTextureIndex(render3d.GetMaterial():GetAmbientOcclusionTexture())
							end,
						},
						{
							"EmissiveTexture",
							"int",
							function(self, block, key)
								block[key] = render3d.pipelines.gbuffer:GetTextureIndex(render3d.GetMaterial():GetEmissiveTexture())
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
								block[key] = render3d.pipelines.gbuffer:GetTextureIndex(render3d.GetMaterial():GetMetallicTexture())
							end,
						},
						{
							"RoughnessTexture",
							"int",
							function(self, block, key)
								block[key] = render3d.pipelines.gbuffer:GetTextureIndex(render3d.GetMaterial():GetRoughnessTexture())
							end,
						},
					},
				},
			},
			shader = [[
			]] .. Material.BuildGlslFlags("pc.model.Flags") .. [[

			float get_texture_blend() {
				if (pc.model.BlendTexture == -1) {
					return in_texture_blend;
				}

				float blend = in_texture_blend;
			
				vec2 blend_data = texture(TEXTURE(pc.model.BlendTexture), in_uv).rg;
				float minb = blend_data.r;
				float maxb = blend_data.g;
				
				// Remap vertex blend through the min/max range
				blend = clamp((blend - minb) / (maxb - minb + 0.001), 0.0, 1.0);

				return blend;
			}

			vec3 get_albedo() {
				if (pc.model.AlbedoTexture == -1) {
					return pc.model.ColorMultiplier.rgb;
				}
				
				vec3 rgb1 = texture(TEXTURE(pc.model.AlbedoTexture), in_uv).rgb;
				
				if (pc.model.Albedo2Texture != -1) {
					float blend = get_texture_blend();
					
					if (blend != 0) {
						vec3 rgb2 = texture(TEXTURE(pc.model.Albedo2Texture), in_uv).rgb;
						rgb1 = mix(rgb1, rgb2, blend);
					}
				}
			
				return rgb1 * pc.model.ColorMultiplier.rgb;
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

			void compute_translucency_and_discard(inout float alpha) {
				if (AlphaTest) {
					if (alpha < pc.model.AlphaCutoff) discard;
				} else if (Translucent) {
					if (fract(dot(vec2(171.0, 231.0) + alpha * 0.00001, gl_FragCoord.xy) / 103.0) > (alpha * alpha)) discard;
				}
			}

			vec3 get_vertex_normal() {
				vec3 N = in_normal;

				if (DoubleSided && gl_FrontFacing) {
					N = -N;
				}

				return normalize(N);
			}

			vec3 get_normal() {
				if ((debug_data.debug_mode - 1) == 5) {
					return get_vertex_normal();
				}

				vec3 N;
				if (pc.model.NormalTexture == -1) {
					N = in_normal;
				} else {
					vec3 rgb1 = texture(TEXTURE(pc.model.NormalTexture), in_uv).xyz * 2.0 - 1.0;


					if (pc.model.Normal2Texture != -1) {
						float blend = get_texture_blend();
						if (blend != 0) {
							vec3 rgb2 = texture(TEXTURE(pc.model.Normal2Texture), in_uv).xyz * 2.0 - 1.0;
							rgb1 = normalize(mix(rgb1, rgb2, blend));
						}
					}
					
					vec3 normal = normalize(in_normal);
					vec3 tangent = normalize(in_tangent.xyz);
					vec3 bitangent = cross(normal, tangent) * in_tangent.w;
					mat3 TBN = mat3(tangent, bitangent, normal);

					N = TBN * rgb1;
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

				val *= val; // roughness squared

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
				compute_translucency_and_discard(alpha);
				set_alpha(alpha); // debug
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
	},
	{
		name = "ssr",
		color_format = {{"r16g16b16a16_sfloat", {"ssr", "rgba"}}},
		fragment = {
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
						camera_block,
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
	{
		name = "lighting",
		color_format = {{"r16g16b16a16_sfloat", {"color", "rgba"}}},
		framebuffer_count = 2,
		fragment = {
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
									for i, v in ipairs(kernel) do
										v:CopyToFloatPointer(block[key][i - 1])
									end
								end
							end,
							64,
						},
						{
							"lights",
							{
								{"position", "vec4"},
								{"color", "vec4"},
								{"params", "vec4"},
							},
							function(self, block, key)
								local ents = render3d.GetLights()

								for i = 0, 128 - 1 do
									local data = block[key][i]
									local ent = ents[i + 1]

									if ent then
										if ent.light.LightType == "directional" or ent.light.LightType == "sun" then
											ent.transform:GetRotation():GetForward():CopyToFloatPointer(data.position)
										else
											ent.transform:GetPosition():CopyToFloatPointer(data.position)
										end

										if ent.light.LightType == "directional" or ent.light.LightType == "sun" then
											data.position[3] = 0
										elseif ent.light.LightType == "point" then
											data.position[3] = 1
										elseif ent.light.LightType == "spot" then
											data.position[3] = 2
										else
											error("Unknown light type: " .. tostring(ent.light.LightType), 2)
										end

										data.color[0] = ent.light.Color.r
										data.color[1] = ent.light.Color.g
										data.color[2] = ent.light.Color.b
										data.color[3] = ent.light.Intensity
										data.params[0] = ent.light.Range
										data.params[1] = ent.light.InnerCone
										data.params[2] = ent.light.OuterCone
										data.params[3] = 0
									else
										data.position[0] = 0
										data.position[1] = 0
										data.position[2] = 0
										data.position[3] = 0
										data.color[0] = 0
										data.color[1] = 0
										data.color[2] = 0
										data.color[3] = 0
										data.params[0] = 0
										data.params[1] = 0
										data.params[2] = 0
										data.params[3] = 0
									end
								end
							end,
							128,
						},
						{
							"light_count",
							"int",
							function(self, block, key)
								block[key] = math.min(#render3d.GetLights(), 128)
							end,
						},
						{
							"shadows",
							{
								{"light_space_matrices", "mat4", 4},
								{"cascade_splits", "int", 4},
								{"shadow_map_indices", "int", 4},
								{"cascade_count", "int"},
							},
							function(self, block, key)
								local sun = nil

								for i, ent in ipairs(render3d.GetLights()) do
									if i > 128 then break end

									if
										(
											ent.light.LightType == "sun" or
											ent.light.LightType == "directional"
										)
										and
										ent.light:GetCastShadows()
									then
										sun = ent

										break
									end
								end

								if sun then
									local shadow_map = sun.light:GetShadowMap()
									local cascade_count = shadow_map:GetCascadeCount()

									for i = 1, cascade_count do
										block[key].shadow_map_indices[i - 1] = self:GetTextureIndex(shadow_map:GetDepthTexture(i))
										shadow_map:GetLightSpaceMatrix(i):CopyToFloatPointer(block[key].light_space_matrices[i - 1])
										block[key].cascade_splits[i - 1] = shadow_map:GetCascadeSplits()[i]
									end

									block[key].cascade_count = cascade_count

									-- Fill remaining slots with -1
									for i = cascade_count + 1, 4 do
										block[key].shadow_map_indices[i - 1] = -1
									end
								else
									block[key].cascade_count = 0

									for i = 0, 3 do
										block[key].shadow_map_indices[i] = -1
									end
								end
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
								if
									not render3d.pipelines.ssr_resolve or
									not render3d.pipelines.ssr_resolve.framebuffers
								then
									block[key] = -1
									return
								end

								local current_idx = system.GetFrameNumber() % 2 + 1
								local current_ssr_fb = render3d.pipelines.ssr_resolve:GetFramebuffer(current_idx)
								block[key] = self:GetTextureIndex(current_ssr_fb:GetAttachment(1))
							end,
						},
						{
							"probe_color_textures",
							"int",
							function(self, block, key)
								for i = 0, 63 do
									block[key][i] = -1

									if lightprobes.IsEnabled() then
										local probe = lightprobes.GetProbes()[i + 1]

										if probe and probe.cubemap then
											block[key][i] = self:GetTextureIndex(probe.cubemap)
										end
									end
								end
							end,
							64,
						},
						{
							"probe_depth_textures",
							"int",
							function(self, block, key)
								for i = 0, 63 do
									block[key][i] = -1

									if lightprobes.IsEnabled() then
										local probe = lightprobes.GetProbes()[i + 1]

										if probe and probe.depth_cubemap then
											block[key][i] = self:GetTextureIndex(probe.depth_cubemap)
										end
									end
								end
							end,
							64,
						},
						{
							"probe_positions",
							"vec4",
							function(self, block, key)
								if not lightprobes.IsEnabled() then return end

								for i = 0, 63 do
									local probe = lightprobes.GetProbes()[i + 1]

									if probe then
										block[key][i][0] = probe.position.x
										block[key][i][1] = probe.position.y
										block[key][i][2] = probe.position.z
										block[key][i][3] = probe.radius or 20
									end
								end
							end,
							64,
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


			#define SSR 1
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

            vec3 F_SchlickRoughness(vec3 f0, float NdotV, float roughness) {
                float f = pow(1.0 - NdotV, 5.0);
                return f0 + (max(vec3(1.0 - roughness), f0) - f0) * f;
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
				
				for (int i = 0; i < lighting_data.shadows.cascade_count; i++) {
					if (dist < lighting_data.shadows.cascade_splits[i]) {
						return i;
					}
				}
				return lighting_data.shadows.cascade_count - 1;
			}

			// PCF Shadow calculation
			float calculateShadow(vec3 world_pos, vec3 normal, vec3 light_dir) {
				int cascade_idx = getCascadeIndex(world_pos);
				if (cascade_idx < 0) return 1.0;
				
				int shadow_map_idx = lighting_data.shadows.shadow_map_indices[cascade_idx];
				if (shadow_map_idx < 0) return 1.0;
				
				float bias_val = max(0.05 * (1.0 - dot(normal, light_dir)), 0.005);
				vec3 offset_pos = world_pos + normal * bias_val;
				vec4 light_space_pos = lighting_data.shadows.light_space_matrices[cascade_idx] * vec4(offset_pos, 1.0);
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

			vec3 parallax_sphere(vec3 R, vec3 ray_origin, float sphere_radius) {
				float b = dot(ray_origin, R);
				float c = dot(ray_origin, ray_origin) - sphere_radius * sphere_radius;
				float discriminant = b * b - c;
				if (discriminant >= 0.0) {
					float t = -b + sqrt(discriminant);
					return normalize(ray_origin + t * R);
				}
				return R;
			}



			vec3 parallax_depth(vec3 R, vec3 ray_origin, float sphere_radius, int depth_tex, float roughness) {
				const int MAX_STEPS = 8;
				float t_min = 0.0;
				float t_max = sphere_radius * 2.0;

				// Binary search for intersection with actual geometry
				for (int i = 0; i < MAX_STEPS; i++) {
					float t_mid = (t_min + t_max) * 0.5;
					vec3 ray_pos = ray_origin + t_mid * R;
					vec3 ray_dir = normalize(ray_pos);
					float ray_dist = length(ray_pos);

					// Sample linearized depth from cubemap (distance from probe center)
					float max_mip = float(textureQueryLevels(CUBEMAP(depth_tex)) - 1);

					float stored_depth = textureLod(CUBEMAP(depth_tex), ray_dir, 0).r;

					if (ray_dist < stored_depth) {
						t_min = t_mid;  // Ray is in front of geometry, move forward
					} else {
						t_max = t_mid;  // Ray is behind geometry, move backward
					}
				}

				return normalize(ray_origin + t_max * R);
			}

			vec3 get_reflection(vec3 normal, float roughness, vec3 V, vec3 world_pos) {
				vec3 R = reflect(-V, normal);
				R = mix(R, normal, roughness * roughness);

				vec3 global_env = vec3(0.0);
				int global_tex_idx = lighting_data.env_tex;
				if (global_tex_idx != -1) {
					float max_mip = float(textureQueryLevels(CUBEMAP(global_tex_idx)) - 1);
					global_env = textureLod(CUBEMAP(global_tex_idx), R, roughness * max_mip).rgb;
				}

				// Find the best probe based on depth accuracy
				int best_probe = -1;
				float best_score = -1.0;
				float best_depth_diff = 99999.0;
				vec3 best_probe_to_point;
				float best_sphere_radius;

				vec3 probes_env = vec3(0.0);
				float total_weight = 0.0;

				for (int i = 0; i < 64; i++) {
					int color_tex = lighting_data.probe_color_textures[i];
					int depth_tex = lighting_data.probe_depth_textures[i];
					if (color_tex == -1) continue;

					vec3 probe_pos = lighting_data.probe_positions[i].xyz;
					float sphere_radius = lighting_data.probe_positions[i].w;
					vec3 probe_to_point = world_pos - probe_pos;
					float dist_to_point = length(probe_to_point);

					if (dist_to_point < sphere_radius) {
						vec3 dir_to_point = normalize(probe_to_point);

						// Check visibility and how accurately this probe sees the surface
						float stored_depth = texture(CUBEMAP(depth_tex), dir_to_point).r;
						float depth_diff = abs(stored_depth - dist_to_point);
						float bias = 0.3;

						// Surface must be visible (not behind geometry)
						if (dist_to_point > stored_depth + bias) continue;

						// Weight based on depth match quality - closer match = higher weight
						// Using exponential falloff for smoother blending
						float depth_weight = exp(-depth_diff * 0.5); // Tune the 0.5 multiplier
						
						// Also weight by distance from probe center for smooth edge falloff
						float edge_weight = smoothstep(sphere_radius, sphere_radius * 0.3, dist_to_point);
						
						float weight = depth_weight * edge_weight;

						if (weight > 0.001) {
							vec3 corrected_R = parallax_depth(R, probe_to_point, sphere_radius, depth_tex, roughness);
							float max_mip = float(textureQueryLevels(CUBEMAP(color_tex)) - 1);
							probes_env += textureLod(CUBEMAP(color_tex), corrected_R, roughness * max_mip).rgb * weight;
							total_weight += weight;
						}
					}
				}

				vec3 env = mix(global_env, probes_env / max(total_weight, 0.0001), min(total_weight, 1.0));

				//vec4 ssr = texture(TEXTURE(lighting_data.ssr_tex), in_uv);
				//env = mix(env, ssr.rgb, ssr.a);

				return env;
			}

			vec3 get_irradiance(vec3 normal, vec3 V, vec3 world_pos) {
				return get_reflection(normal, 1, V, world_pos);
			}

			float get_ambient_occlusion(vec2 uv, vec3 world_pos, vec3 N) {
				float ao_tex = get_ao();

				if (lighting_data.blue_noise_tex == -1) return ao_tex;

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
				return pow(clamp(ao, 0.0, 1.0), 1) * ao_tex;
			}

			vec3 get_sky() {
				// Skybox or background
				vec4 clip_pos = vec4(in_uv * 2.0 - 1.0, 1.0, 1.0);
				vec4 view_pos = lighting_data.inv_projection * clip_pos;
				view_pos /= view_pos.w;
				vec3 world_pos = (lighting_data.inv_view * view_pos).xyz;
				vec3 sky_dir = normalize(world_pos - lighting_data.camera_position.xyz);

				vec3 sunDir = vec3(0, 1, 0);
				if (lighting_data.light_count > 0) {
					vec3 p = lighting_data.lights[0].position.xyz;
					if (length(p) > 0.0001) {
						sunDir = normalize(-p);
					}
				}
				vec3 sky_color_output = vec3(0.0);

				]] .. require("render3d.atmosphere").GetGLSLMainCode(
					"sky_dir",
					"sunDir",
					"lighting_data.camera_position.xyz",
					"lighting_data.stars_texture_index"
				) .. [[

				return clamp(sky_color_output, vec3(0.0), vec3(65504.0));
			}

			vec3 get_light(vec3 F0, float NdotV, vec3 albedo, float r2, float metallic, vec3 world_pos, vec3 V, vec3 N)
			{
				vec3 Lo = vec3(0.0);

                for (int i = 0; i < lighting_data.light_count; i++) {
                    lights_t light = lighting_data.lights[i];
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
                    if (i == 0 && lighting_data.shadows.shadow_map_indices[0] >= 0) {
                        shadow_factor = calculateShadow(world_pos, N, L);
                    }
                    vec3 radiance = light.color.rgb * light.color.a * attenuation;
                    Lo += (Fd + Fr) * radiance * NoL * shadow_factor;
                }

				return Lo;				
			}

			vec3 get_world_pos(float depth) {
				// Reconstruct world position from depth
				vec4 clip_pos = vec4(in_uv * 2.0 - 1.0, depth, 1.0);
				vec4 view_pos = lighting_data.inv_projection * clip_pos;
				view_pos /= view_pos.w;
				return (lighting_data.inv_view * view_pos).xyz;
			}

			vec3 get_view_normal(vec3 world_pos) {
				return normalize(lighting_data.camera_position.xyz - world_pos);
			}

			void main() {
				float alpha = get_alpha();
				if (alpha == 0.0) discard;
				
				float depth = get_depth();

				if (depth == 1.0) {
					
					set_color(vec4(get_sky(), 1.0));
					return;
				}


				vec3 N = get_normal();
				vec3 world_pos = get_world_pos(depth);
				vec3 V = get_view_normal(world_pos);


				vec3 albedo = get_albedo();
				float metallic = get_metallic();
				float roughness = get_roughness();
				vec3 emissive = get_emissive();
				vec3 reflection = get_reflection(N, roughness, V, world_pos);
				vec3 F0 = mix(vec3(0.04), albedo, metallic);
				float NdotV = max(dot(N, V), 0.001);

                vec3 Lo = get_light(F0, NdotV, albedo, roughness, metallic, world_pos, V, N);
				float ambient_occlusion = get_ambient_occlusion(in_uv, world_pos, N);

                // Diffuse IBL: use irradiance (max-mip env sample in normal direction)
                vec3 irradiance = get_irradiance(N, V, world_pos);
                vec3 F_ambient = F_SchlickRoughness(F0, NdotV, roughness);
                vec3 kD_ambient = (1.0 - F_ambient) * (1.0 - metallic);
                vec3 ambient_diffuse = kD_ambient * irradiance * albedo * ambient_occlusion;
                
                // Specular IBL with split-sum approximation
                vec2 envBRDF = envBRDFApprox(NdotV, roughness);
                vec3 ambient_specular = reflection * (F0 * envBRDF.x + envBRDF.y) * ambient_occlusion;

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
	},
	require("render3d.pipelines.smaa"),
	{
		name = "blit",
		fragment = {
			push_constants = {
				{
					name = "blit",
					block = {
						{
							"tex",
							"int",
							function(self, block, key)
								if render3d.pipelines.smaa_resolve and render3d.pipelines.smaa_resolve.framebuffers then
									local current_idx = system.GetFrameNumber() % 2 + 1
									block[key] = self:GetTextureIndex(render3d.pipelines.smaa_resolve:GetFramebuffer(current_idx):GetAttachment(1))
									return
								end

								if not render3d.pipelines.lighting or not render3d.pipelines.lighting.framebuffers then
									block[key] = -1
									return
								end

								local current_idx = system.GetFrameNumber() % 2 + 1
								block[key] = self:GetTextureIndex(render3d.pipelines.lighting:GetFramebuffer(current_idx):GetAttachment(1))
							end,
						},
						{
							"requires_manual_gamma",
							"int",
							function(self, block, key)
								block[key] = render.target:RequiresManualGamma() and 1 or 0
							end,
						},
						{
							"is_hdr",
							"int",
							function(self, block, key)
								block[key] = render.target:IsHDR() and 1 or 0
							end,
						},
					},
				},
			},
			shader = [[
				layout(location = 0) out vec4 frag_color;

				vec3 ACESFilm(vec3 x) {
					vec3 res = (x * (2.51 * x + 0.03)) / (x * (2.43 * x + 0.59) + 0.14);
					return clamp(res, 0.0, 1.0);
				}

				vec3 ACESFilmHDR(vec3 x) {
					return (x * (2.51 * x + 0.03)) / (x * (2.43 * x + 0.59) + 0.14);
				}


				vec3 jodieReinhardTonemap(vec3 c){
					float l = dot(c, vec3(0.7152, 0.7152, 0.7152));
					vec3 tc = c / (c + 1.0);
					vec3 c2 = mix(c / (l + 1.0), tc, tc);
					c2 = pow(c2*1.5, vec3(1.5));
					return c2;
				}

				vec3 LinearToSRGB(vec3 col) {
					vec3 low = col * 12.92;
					vec3 high = 1.055 * pow(col, vec3(1.0/2.4)) - 0.055;
					return mix(low, high, step(0.0031308, col));
				}

				

				vec3 tonemap(vec3 x) {
					const float a = 2.51;
					const float b = 0.03;
					const float c = 2.43;
					const float d = 0.59;
					const float e = 0.14;
					vec3 col = (x * (a * x + b)) / (x * (c * x + d) + e);

					col = pow(col*0.75, vec3(1.5))*1.25;

					return col;
				}

				void main() {
					if (pc.blit.tex == -1) {
						frag_color = vec4(1.0, 0.0, 1.0, 1.0);
						return;
					}
					
					vec3 col = texture(TEXTURE(pc.blit.tex), in_uv).rgb;

					if (pc.blit.is_hdr == 1) {
						col = tonemap(pow(col*1.5, vec3(0.8)))*1.2;

					} else {
						col = ACESFilm(col);
					}
					
					if (pc.blit.requires_manual_gamma == 1) {
						col = LinearToSRGB(col);
					}
					
					frag_color = vec4(col, 1.0);
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

function render3d.Initialize()
	render3d.pipelines = {}
	render3d.pipelines_i = {}
	local i = 1

	for _, config in ipairs(pipelines) do
		if config[1] then
			for _, config in ipairs(config) do
				render3d.pipelines_i[i] = EasyPipeline.New(config)
				render3d.pipelines[config.name] = render3d.pipelines_i[i]
				--
				render3d.pipelines_i[i].name = config.name
				render3d.pipelines_i[i].post_draw = config.post_draw
				i = i + 1
			end
		else
			render3d.pipelines_i[i] = EasyPipeline.New(config)
			render3d.pipelines[config.name] = render3d.pipelines_i[i]
			--
			render3d.pipelines_i[i].name = config.name
			render3d.pipelines_i[i].post_draw = config.post_draw
			i = i + 1
		end
	end

	event.AddListener("PreRenderPass", "render3d", function(cmd)
		if not render3d.pipelines.gbuffer then return end

		for _, pipeline in ipairs(render3d.pipelines_i) do
			if pipeline.name ~= "blit" then pipeline:Draw(cmd) end
		end
	end)

	event.AddListener("Draw", "render3d", function(cmd, dt)
		render3d.Draw(cmd, dt)
	end)

	event.Call("Render3DInitialized")
end

function render3d.Draw(cmd, dt)
	if not render3d.pipelines.blit then return end

	-- render to the screen
	render3d.pipelines.blit:Draw(cmd)

	for _, pipeline in ipairs(render3d.pipelines_i) do
		if pipeline.post_draw then pipeline:post_draw(cmd, dt) end
	end

	render3d.prev_view_matrix = render3d.camera:BuildViewMatrix():Copy()
	render3d.prev_projection_matrix = render3d.camera:BuildProjectionMatrix():Copy()
end

function render3d.UploadGBufferConstants(cmd)
	if not render3d.pipelines.gbuffer then return end

	cmd:SetCullMode(render3d.GetMaterial():GetDoubleSided() and "none" or orientation.CULL_MODE)
	render3d.pipelines.gbuffer:UploadConstants(cmd)
end

do
	render3d.camera = render3d.camera or Camera3D.New()
	render3d.world_matrix = render3d.world_matrix or Matrix44()
	render3d.prev_view_matrix = render3d.prev_view_matrix or Matrix44()
	render3d.prev_projection_matrix = render3d.prev_projection_matrix or Matrix44()

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

function render3d.GetLights()
	return ecs.GetEntitiesWithComponent("light") -- TODO, optimize
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
			render3d.pipelines.gbuffer:GetVertexAttributes(),
			vertices,
			indices,
			index_type,
			index_count
		)
	end
end

if HOTRELOAD then render3d.Initialize() end

return render3d
