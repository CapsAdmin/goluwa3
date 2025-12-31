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
local Texture = require("render.texture")
local Light = require("components.light")
local Framebuffer = require("render.framebuffer")
local system = require("system")
local render3d = library()
package.loaded["render3d.render3d"] = render3d
render3d.fill_config = {
	color_format = {
		"r8g8b8a8_unorm", -- albedo
		"r16g16b16a16_sfloat", -- normal
		"r8g8b8a8_unorm", -- metallic, roughness, ao
		"r8g8b8a8_unorm", -- emissive
	},
	depth_format = "d32_sfloat",
	samples = "1",
	vertex = {
		binding_index = 0,
		attributes = {
			{"position", "vec3", "r32g32b32_sfloat"},
			{"normal", "vec3", "r32g32b32_sfloat"},
			{"uv", "vec2", "r32g32_sfloat"},
		},
		push_constants = {
			{
				name = "vertex",
				block = {
					{
						"projection_view_world",
						"mat4",
						function(constants)
							return render3d.GetProjectionViewWorldMatrix():CopyToFloatPointer(constants.projection_view_world)
						end,
					},
					{
						"world",
						"mat4",
						function(constants)
							return render3d.GetWorldMatrix():CopyToFloatPointer(constants.world)
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
				out_uv = in_uv;
			}
		]],
	},
	fragment = {
		custom_declarations = [[
			layout(location = 0) out vec4 out_albedo;
			layout(location = 1) out vec4 out_normal;
			layout(location = 2) out vec4 out_metallic_roughness_ao;
			layout(location = 3) out vec4 out_emissive;
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
				name = "debug_data",
				binding_index = 3,
				block = {
					{
						"debug_cascade_colors",
						"int",
						function(constants)
							return render3d.debug_cascade_colors and 1 or 0
						end,
					},
					{
						"debug_mode",
						"int",
						function(constants)
							return render3d.debug_mode or 1
						end,
					},
					{
						"near_z",
						"float",
						function(constants)
							return render3d.camera:GetNearZ()
						end,
					},
					{
						"far_z",
						"float",
						function(constants)
							return render3d.camera:GetFarZ()
						end,
					},
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
						function(constants)
							return render3d.GetMaterial():GetFillFlags()
						end,
					},
					{
						"AlbedoTexture",
						"int",
						function(constants)
							return render3d.fill_pipeline:GetTextureIndex(render3d.GetMaterial():GetAlbedoTexture())
						end,
					},
					{
						"NormalTexture",
						"int",
						function(constants)
							return render3d.fill_pipeline:GetTextureIndex(render3d.GetMaterial():GetNormalTexture())
						end,
					},
					{
						"MetallicRoughnessTexture",
						"int",
						function(constants)
							return render3d.fill_pipeline:GetTextureIndex(render3d.GetMaterial():GetMetallicRoughnessTexture())
						end,
					},
					{
						"AmbientOcclusionTexture",
						"int",
						function(constants)
							return render3d.fill_pipeline:GetTextureIndex(render3d.GetMaterial():GetAmbientOcclusionTexture())
						end,
					},
					{
						"EmissiveTexture",
						"int",
						function(constants)
							return render3d.fill_pipeline:GetTextureIndex(render3d.GetMaterial():GetEmissiveTexture())
						end,
					},
					{
						"ColorMultiplier",
						"vec4",
						function(constants)
							return render3d.GetMaterial():GetColorMultiplier():CopyToFloatPointer(constants.ColorMultiplier)
						end,
					},
					{
						"MetallicMultiplier",
						"float",
						function(constants)
							return render3d.GetMaterial():GetMetallicMultiplier()
						end,
					},
					{
						"RoughnessMultiplier",
						"float",
						function(constants)
							return render3d.GetMaterial():GetRoughnessMultiplier()
						end,
					},
					{
						"AmbientOcclusionMultiplier",
						"float",
						function(constants)
							return render3d.GetMaterial():GetAmbientOcclusionMultiplier()
						end,
					},
					{
						"EmissiveMultiplier",
						"vec4",
						function(constants)
							return render3d.GetMaterial():GetEmissiveMultiplier():CopyToFloatPointer(constants.EmissiveMultiplier)
						end,
					},
					{
						"AlphaCutoff",
						"float",
						function(constants)
							return render3d.GetMaterial():GetAlphaCutoff()
						end,
					},
					{
						"MetallicTexture",
						"int",
						function(constants)
							return render3d.fill_pipeline:GetTextureIndex(render3d.GetMaterial():GetMetallicTexture())
						end,
					},
					{
						"RoughnessTexture",
						"int",
						function(constants)
							return render3d.fill_pipeline:GetTextureIndex(render3d.GetMaterial():GetRoughnessTexture())
						end,
					},
					{
						"SelfIlluminationTexture",
						"int",
						function(constants)
							return render3d.fill_pipeline:GetTextureIndex(render3d.GetMaterial():GetSelfIlluminationTexture())
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
				return texture(TEXTURE(pc.model.AlbedoTexture), in_uv).rgb * pc.model.ColorMultiplier.rgb;
			}

			float get_alpha() {

				if (
					pc.model.AlbedoTexture == -1 ||
					AlbedoTextureAlphaIsMetallic ||
					AlbedoTextureAlphaIsRoughness 
				) {
					return pc.model.ColorMultiplier.a;	
				}

				return texture(TEXTURE(pc.model.AlbedoTexture), in_uv).a * pc.model.ColorMultiplier.a;
			}

			vec3 get_normal() {
				vec3 N;
				if (pc.model.NormalTexture == -1) {
					N = normalize(in_normal);
				} else {
					vec3 tangent_normal = texture(TEXTURE(pc.model.NormalTexture), in_uv).xyz * 2.0 - 1.0;
					
					// Calculate TBN matrix on the fly
					vec3 Q1 = dFdx(in_position);
					vec3 Q2 = dFdy(in_position);
					vec2 st1 = dFdx(in_uv);
					vec2 st2 = dFdy(in_uv);

					vec3 N_orig = normalize(in_normal);
					vec3 T = normalize(Q1 * st2.t - Q2 * st1.t);
					vec3 B = -normalize(cross(N_orig, T));
					mat3 TBN = mat3(T, B, N_orig);

					N = normalize(TBN * tangent_normal);
				}

				if (DoubleSided && gl_FrontFacing) {
					N = -N;
				}

				return N;
			}

			float get_metallic() {
				float val = 0.0;

				if (pc.model.AlbedoTexture != -1 && AlbedoTextureAlphaIsMetallic) {
					val = 1.0 - texture(TEXTURE(pc.model.AlbedoTexture), in_uv).a;
				} else if (pc.model.NormalTexture != -1 && NormalTextureAlphaIsMetallic) {
					val = 1.0 - texture(TEXTURE(pc.model.NormalTexture), in_uv).a;
				} else if (pc.model.MetallicTexture != -1) {
					val = texture(TEXTURE(pc.model.MetallicTexture), in_uv).r;
				} else if (pc.model.MetallicRoughnessTexture != -1) {
					val = texture(TEXTURE(pc.model.MetallicRoughnessTexture), in_uv).b;
				} else {
					val = 1.0;
				}

				return clamp(val * pc.model.MetallicMultiplier, 0.01, 1.0);
			}

			float get_roughness() {
				float val = 1.0;

				if (pc.model.AlbedoTexture != -1 && AlbedoTextureAlphaIsRoughness) {
					val = 1.0 - texture(TEXTURE(pc.model.AlbedoTexture), in_uv).a;
					if (InvertRoughnessTexture) val = 1.0 - val;
				} else if (AlbedoLuminanceIsRoughness) {
					val = dot(get_albedo(), vec3(0.2126, 0.7152, 0.0722));
					if (InvertRoughnessTexture) val = 1.0 - val;
				} else if (pc.model.RoughnessTexture != -1) {
					val = texture(TEXTURE(pc.model.RoughnessTexture), in_uv).r;
					if (InvertRoughnessTexture) val = 1.0 - val;
				} else if (pc.model.MetallicRoughnessTexture != -1) {
					val = texture(TEXTURE(pc.model.MetallicRoughnessTexture), in_uv).g;
				} else  {
					val = 1.0;
				}
				return clamp(val * pc.model.RoughnessMultiplier, 0.01, 1.0);
			}

			vec3 get_emissive() {
				if (pc.model.SelfIlluminationTexture != -1) {
					float mask = texture(TEXTURE(pc.model.SelfIlluminationTexture), in_uv).r;
					return get_albedo() * mask * pc.model.EmissiveMultiplier.rgb * pc.model.EmissiveMultiplier.a;
				} else if (pc.model.MetallicTexture != -1 && MetallicTextureAlphaIsEmissive) {
					float mask = texture(TEXTURE(pc.model.MetallicTexture), in_uv).a;
					return get_albedo() * mask * pc.model.EmissiveMultiplier.rgb * pc.model.EmissiveMultiplier.a;
				} else if (pc.model.EmissiveTexture != -1) {
					vec3 emissive = texture(TEXTURE(pc.model.EmissiveTexture), in_uv).rgb;
					return emissive * pc.model.EmissiveMultiplier.rgb * pc.model.EmissiveMultiplier.a;
				}
				return pc.model.EmissiveMultiplier.rgb * pc.model.EmissiveMultiplier.a;
			}

			float get_ao() {
				if (pc.model.AmbientOcclusionTexture == -1) {
					return 1.0 * pc.model.AmbientOcclusionMultiplier;
				}
				return texture(TEXTURE(pc.model.AmbientOcclusionTexture), in_uv).r * pc.model.AmbientOcclusionMultiplier;
			}

			void main() {
				float alpha = get_alpha();

				if (AlphaTest) {
					if (alpha < pc.model.AlphaCutoff) discard;
				} else if (Translucent) {
					if (fract(dot(vec2(171.0, 231.0) + alpha * 0.00001, gl_FragCoord.xy) / 103.0) > (alpha * alpha)) discard;
				}

				out_albedo = vec4(get_albedo(), alpha);
				out_normal = vec4(get_normal(), 1.0);
				out_metallic_roughness_ao = vec4(get_metallic(), get_roughness(), get_ao(), 1.0);
				out_emissive = vec4(get_emissive(), 1.0);
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
render3d.lighting_config = {
	samples = "1",
	vertex = {
		custom_declarations = [[
			layout(location = 0) out vec2 out_uv;
		]],
		shader = [[
			void main() {
				vec2 uv = vec2((gl_VertexIndex << 1) & 2, gl_VertexIndex & 2);
				gl_Position = vec4(uv * 2.0 - 1.0, 0.0, 1.0);
				out_uv = uv;
			}
		]],
	},
	fragment = {
		custom_declarations = [[
			layout(location = 0) in vec2 in_uv;

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

			layout(location = 0) out vec4 out_color;
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
					{
						"inv_view",
						"mat4",
						function(constants)
							return render3d.camera:BuildViewMatrix():GetInverse():CopyToFloatPointer(constants.inv_view)
						end,
					},
					{
						"inv_projection",
						"mat4",
						function(constants)
							return render3d.camera:BuildProjectionMatrix():GetInverse():CopyToFloatPointer(constants.inv_projection)
						end,
					},
					{
						"view",
						"mat4",
						function(constants)
							return render3d.camera:BuildViewMatrix():CopyToFloatPointer(constants.view)
						end,
					},
					{
						"projection",
						"mat4",
						function(constants)
							return render3d.camera:BuildProjectionMatrix():CopyToFloatPointer(constants.projection)
						end,
					},
					{
						"camera_position",
						"vec4",
						function(constants)
							local p = render3d.camera:GetPosition()
							constants.camera_position[0] = p.x
							constants.camera_position[1] = p.y
							constants.camera_position[2] = p.z
							constants.camera_position[3] = 0
						end,
					},
					{
						"ssao_kernel",
						"vec4",
						function(constants)
							for i, v in ipairs(render3d.ssao_kernel) do
								constants.ssao_kernel[i - 1][0] = v.x
								constants.ssao_kernel[i - 1][1] = v.y
								constants.ssao_kernel[i - 1][2] = v.z
								constants.ssao_kernel[i - 1][3] = 0
							end
						end,
						64,
					},
					{
						"light_count",
						"int",
						function(constants)
							return math.min(#Light.GetLights(), 32)
						end,
					},
					{
						"debug_cascade_colors",
						"int",
						function(constants)
							return render3d.debug_cascade_colors and 1 or 0
						end,
					},
					{
						"debug_mode",
						"int",
						function(constants)
							return render3d.debug_mode or 1
						end,
					},
					{
						"near_z",
						"float",
						function(constants)
							return render3d.camera:GetNearZ()
						end,
					},
					{
						"far_z",
						"float",
						function(constants)
							return render3d.camera:GetFarZ()
						end,
					},
					{
						"albedo_tex",
						"int",
						function(constants)
							return render3d.lighting_pipeline:GetTextureIndex(render3d.gbuffer:GetAttachment(1))
						end,
					},
					{
						"normal_tex",
						"int",
						function(constants)
							return render3d.lighting_pipeline:GetTextureIndex(render3d.gbuffer:GetAttachment(2))
						end,
					},
					{
						"mra_tex",
						"int",
						function(constants)
							return render3d.lighting_pipeline:GetTextureIndex(render3d.gbuffer:GetAttachment(3))
						end,
					},
					{
						"emissive_tex",
						"int",
						function(constants)
							return render3d.lighting_pipeline:GetTextureIndex(render3d.gbuffer:GetAttachment(4))
						end,
					},
					{
						"depth_tex",
						"int",
						function(constants)
							return render3d.lighting_pipeline:GetTextureIndex(render3d.gbuffer:GetDepthTexture())
						end,
					},
					{
						"env_tex",
						"int",
						function(constants)
							return render3d.lighting_pipeline:GetTextureIndex(render3d.GetEnvironmentTexture())
						end,
					},
					{
						"ssao_noise_tex",
						"int",
						function(constants)
							return render3d.lighting_pipeline:GetTextureIndex(render3d.ssao_noise_tex)
						end,
					},
					{
						"last_frame_tex",
						"int",
						function(constants)
							if not render3d.lighting_fbs then return -1 end

							local prev_idx = 3 - render3d.current_lighting_fb_index
							return render3d.lighting_pipeline:GetTextureIndex(render3d.lighting_fbs[prev_idx]:GetAttachment(1))
						end,
					},
					{
						"time",
						"float",
						function(constants)
							return system.GetElapsedTime()
						end,
					},
					{
						"universe_texture_index",
						"int",
						function(constants)
							local skybox = require("render3d.skybox")
							return render3d.lighting_pipeline:GetTextureIndex(skybox.universe_texture)
						end,
					},
				},
			},
		},
		shader = [[
			]] .. require("render3d.skybox").GetGLSLCode() .. [[
			#define SSR 0
			#define uv in_uv
			float hash(vec2 p) {
				p = fract(p * vec2(123.34, 456.21));
				p += dot(p, p + 45.32);
				return fract(p.x * p.y);
			}

			vec3 random_vec3(vec2 p) {
				return vec3(hash(p), hash(p + 1.0), hash(p + 2.0)) * 2.0 - 1.0;
			}

			// Cascade debug colors
			const vec3 CASCADE_COLORS[4] = vec3[4](
				vec3(1.0, 0.2, 0.2),  // Red - cascade 1
				vec3(0.2, 1.0, 0.2),  // Green - cascade 2
				vec3(0.2, 0.2, 1.0),  // Blue - cascade 3
				vec3(1.0, 1.0, 0.2)   // Yellow - cascade 4
			);

			#if SSR

			vec2 _raycast_project(vec3 coord)
			{
				vec4 res = lighting_data.projection * vec4(coord, 1.0);
				return (res.xy / res.w) * 0.5 + 0.5;
			}
				
			float linearize_depth(float depth)
			{
				float n = lighting_data.near_z;
				float f = lighting_data.far_z;
				return (2.0 * n) / (f + n - depth * (f - n));
			}
			float random(vec2 co)
			{
				return fract(sin(dot(co.xy ,vec2(12.9898,78.233))) * 43758.5453);
			}
			vec3 get_noise3(vec2 uv)
			{
				float x = random(uv);
				float y = random(uv*x);
				float z = random(uv*y);

				return vec3(x,y,z) * 2 - 1;
			}

			vec3 get_noise3_world(vec3 world_pos)
{
    float x = random(world_pos.xy);
    float y = random(world_pos.yz * x);
    float z = random(world_pos.xz * y);

    return vec3(x, y, z) * 2.0 - 1.0;
}

vec3 get_noise3_world_stable(vec3 world_pos, float scale)
{
    vec3 p = floor(world_pos * scale) / scale;  // quantize to grid
    float x = random(p.xy);
    float y = random(p.yz * x);
    float z = random(p.xz * y);

    return vec3(x, y, z) * 2.0 - 1.0;
}

			vec3 get_view_pos(vec2 uv)
			{
				vec4 pos = vec4(uv * 2.0 - 1.0, texture(TEXTURE(lighting_data.depth_tex), uv).r * 2 - 1, 1.0)*lighting_data.inv_projection;
				return pos.xyz / pos.w;
			}

			vec2 g_raycast(vec3 viewPos, vec3 dir, const float step_size, const float max_steps, float roughness)
			{
				dir *= step_size + linearize_depth(texture(TEXTURE(lighting_data.depth_tex), uv).r);

				for(int i = 0; i < max_steps; i++)
				{
					viewPos += dir;
					//viewPos += get_noise3(viewPos.xy).xyz * pow(roughness, 3)*2;

					float depth = get_view_pos(_raycast_project(viewPos)).z - viewPos.z;

					if(depth > -5 && depth < 5)
					{
						return _raycast_project(viewPos).xy;
					}
				}

				return vec2(0.0, 0.0);
			}

			vec3 get_ssr_old2(vec3 world_pos, vec3 N, vec3 V, float roughness) {
				if (lighting_data.last_frame_tex == -1) return vec3(0.0);

				vec3 R = reflect(-V, N);
				vec4 view_pos = lighting_data.view * vec4(world_pos, 1.0);
				vec3 view_dir = normalize(mat3(lighting_data.view) * R);

				vec2 ray_uv = g_raycast(view_pos.xyz, view_dir, 0.5, 2, roughness);
				return texture(TEXTURE(lighting_data.last_frame_tex), ray_uv).rgb;
			}

			vec3 get_ssr_old23(vec3 world_pos, vec3 N, vec3 V, float roughness) {
				roughness = 0;
				if (lighting_data.last_frame_tex == -1) return vec3(0.0);

				vec3 R = reflect(-V, N);
				vec4 view_pos = lighting_data.view * vec4(world_pos, 1.0);
				vec3 dir = -normalize(mat3(lighting_data.view) * R);

				// Scale direction by step_size + linearized depth
				float depth_sample = texture(TEXTURE(lighting_data.depth_tex), uv).r;
				float lin_depth = (2.0 * lighting_data.near_z) / 
					(lighting_data.far_z + lighting_data.near_z - depth_sample * (lighting_data.far_z - lighting_data.near_z));
				dir *= 0.5 ;

				float roughness3 = roughness * roughness * roughness;

				vec3 pos = view_pos.xyz;
				for (int i = 0; i < 16; i++) {
					pos += dir;

					// Add noise based on roughness
					if (roughness > 0.0) {
						float rx = fract(sin(dot(pos.xy * float(i), vec2(12.9898, 78.233))) * 43758.5453);
						float ry = fract(sin(dot(pos.xy * float(i) * rx, vec2(12.9898, 78.233))) * 43758.5453);
						float rz = fract(sin(dot(pos.xy * float(i) * ry, vec2(12.9898, 78.233))) * 43758.5453);
						pos += ((vec3(rx, ry, rz) * 2.0 - 1.0) * roughness3 * 2.0)*0.0;
					}

					// Project to screen UV
					vec4 proj = lighting_data.projection * vec4(pos, 1.0);
					vec2 proj_uv = (proj.xy / proj.w) * 0.5 + 0.5;

					// Get view-space depth at that UV
					vec4 depth_pos = vec4(proj_uv * 2.0 - 1.0, 
						texture(TEXTURE(lighting_data.depth_tex), proj_uv).r * 2.0 - 1.0, 1.0) * lighting_data.inv_projection;
					float scene_z = depth_pos.z / depth_pos.w;

					if (abs(scene_z - pos.z) < 5.0) {
						return texture(TEXTURE(lighting_data.last_frame_tex), proj_uv).rgb;
					}
				}

				return vec3(0.0);
			}

			vec3 get_ssr(vec3 world_pos, vec3 N, vec3 V, float roughness) {
				if (lighting_data.last_frame_tex == -1) return vec3(0.0);
				if (roughness > 0.4) return vec3(0.0);


				N = N + get_noise3_world(world_pos) * roughness;

				vec3 R = reflect(-V, N);
				vec4 view_pos = lighting_data.view * vec4(world_pos, 1.0);
				vec3 view_dir = normalize(mat3(lighting_data.view) * R);

				float step_size = 0.1;
				int max_steps = 128;
				vec3 current_pos = view_pos.xyz;

				for (int i = 0; i < max_steps; i++) {

					current_pos += view_dir * step_size;


					vec4 projected_pos = lighting_data.projection * vec4(current_pos, 1.0);
					projected_pos.xyz /= projected_pos.w;
					vec2 uv = projected_pos.xy * 0.5 + 0.5;

					if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0) break;

					float sampled_depth = texture(TEXTURE(lighting_data.depth_tex), uv).r;
					vec4 sampled_clip_pos = vec4(uv * 2.0 - 1.0, sampled_depth, 1.0);
					vec4 sampled_view_pos = lighting_data.inv_projection * sampled_clip_pos;
					sampled_view_pos /= sampled_view_pos.w;

					if (current_pos.z < sampled_view_pos.z) {
						float depth_diff = abs(current_pos.z - sampled_view_pos.z);
						if (depth_diff < 0.5) {
							vec3 hit_color = texture(TEXTURE(lighting_data.last_frame_tex), uv).rgb;
							float edge_fade = min(1.0, 10.0 * min(min(uv.x, 1.0 - uv.x), min(uv.y, 1.0 - uv.y)));
							
							// Fade out based on roughness
							float roughness_fade = 1.0 - clamp(roughness * 1.2, 0.0, 1.0);
							return hit_color * edge_fade * roughness_fade;
						}
					}
					step_size *= 1.05;
				}
				return vec3(0.0);
			}
			#endif

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
				#if SSR
				vec3 ssr_color = get_ssr(world_pos, normal, V, roughness);
				if (length(ssr_color) > 0.0) {
					return ssr_color;
				}
				#endif

				if (lighting_data.env_tex == -1) return vec3(0.2);
				float NdotV = dot(normal, V);
				if (NdotV <= 0.0) return vec3(0.0);
				vec3 R = reflect(-V, normal);
				R = mix(R, normal, roughness * roughness);
				R = normalize(R);
				float max_mip = float(textureQueryLevels(CUBEMAP(lighting_data.env_tex)) - 1);
				float mip_level = roughness * max_mip;
				return textureLod(CUBEMAP(lighting_data.env_tex), R, mip_level).rgb;
			}

			vec3 get_ssao(vec2 uv, vec3 world_pos, vec3 N) {
				if (lighting_data.ssao_noise_tex == -1) return vec3(1.0);

				vec3 view_pos = (lighting_data.view * vec4(world_pos, 1.0)).xyz;
				vec3 view_normal = normalize(mat3(lighting_data.view) * N);

				vec2 noise_scale = vec2(textureSize(TEXTURE(lighting_data.albedo_tex), 0)) / 4.0;
				vec3 random_vec = texture(TEXTURE(lighting_data.ssao_noise_tex), uv * noise_scale).xyz;

				vec3 tangent = normalize(random_vec - view_normal * dot(random_vec, view_normal));
				vec3 bitangent = cross(view_normal, tangent);
				mat3 TBN = mat3(tangent, bitangent, view_normal);

				float occlusion = 0.0;
				float radius = 3.5;
				float bias = 0.025;

				for (int i = 0; i < 64; i++) {
					vec3 sample_pos = TBN * lighting_data.ssao_kernel[i].xyz;
					sample_pos = view_pos + sample_pos * radius;

					vec4 offset = vec4(sample_pos, 1.0);
					offset = lighting_data.projection * offset;
					offset.xyz /= offset.w;
					offset.xyz = offset.xyz * 0.5 + 0.5;

					float sample_depth = texture(TEXTURE(lighting_data.depth_tex), offset.xy).r;
					vec4 sample_clip_pos = vec4(offset.xy * 2.0 - 1.0, sample_depth, 1.0);
					vec4 sample_view_pos = lighting_data.inv_projection * sample_clip_pos;
					sample_view_pos /= sample_view_pos.w;

					float range_check = smoothstep(0.0, 1.0, radius / abs(view_pos.z - sample_view_pos.z));
					occlusion += (sample_view_pos.z >= sample_pos.z + bias ? 1.0 : 0.0) * range_check;
				}

				occlusion = 1.0 - (occlusion / 64.0);
				return vec3(occlusion);
			}

			void main() {
				vec4 albedo_alpha = texture(TEXTURE(lighting_data.albedo_tex), in_uv);
				//if (albedo_alpha.a == 0.0) discard;
				float depth = texture(TEXTURE(lighting_data.depth_tex), in_uv).r;
				vec3 albedo = albedo_alpha.rgb;

				if (depth == 1.0) {
					// Skybox or background
					vec3 sky_color_output;
					vec3 sunDir = normalize(-light_data.lights[0].position.xyz);
					vec4 clip_pos = vec4(in_uv * 2.0 - 1.0, 1.0, 1.0);
					vec4 view_pos = lighting_data.inv_projection * clip_pos;
					view_pos /= view_pos.w;
					vec3 world_pos = (lighting_data.inv_view * view_pos).xyz;
					vec3 dir = normalize(world_pos - lighting_data.camera_position.xyz);
					
					]] .. require("render3d.skybox").GetGLSLMainCode(
				"dir",
				"sunDir",
				"lighting_data.camera_position.xyz",
				"lighting_data.universe_texture_index"
			) .. [[
					
					out_color = vec4(sky_color_output, 1.0);
					return;
				}
				int debug_mode = lighting_data.debug_mode - 1;

				vec3 N = texture(TEXTURE(lighting_data.normal_tex), in_uv).xyz;

				vec3 mra = texture(TEXTURE(lighting_data.mra_tex), in_uv).rgb;
				float metallic = mra.r;
				float roughness = mra.g;
				if (debug_mode == 2) {
					metallic = 1.0;
					roughness = 0.4;
				}


				float ao = mra.b;
				vec3 emissive = texture(TEXTURE(lighting_data.emissive_tex), in_uv).rgb;

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
                vec3 F_ambient = F_Schlick(F0, NdotV);
                vec3 ambient_specular = F_ambient * reflection * ao * ssao;
                vec3 ambient = ambient_diffuse + ambient_specular;
                vec3 color = ambient + Lo + emissive;

				if (lighting_data.debug_cascade_colors != 0) {
					int cascade_idx = getCascadeIndex(world_pos);
					color = mix(color, CASCADE_COLORS[cascade_idx], 0.4);
				}

				
				if (debug_mode == 1) {
					color = N * 0.5 + 0.5;
				} else if (debug_mode == 2) {
					// do nothing, see up
				} else if (debug_mode == 3) {
					color = ambient_specular + emissive;
				} else if (debug_mode == 4) {
					color = ssao;
				}

				out_color = vec4(color, albedo_alpha.a);
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
	samples = "1",
	vertex = {
		custom_declarations = [[
			layout(location = 0) out vec2 out_uv;
		]],
		shader = [[
			void main() {
				vec2 uv = vec2((gl_VertexIndex << 1) & 2, gl_VertexIndex & 2);
				gl_Position = vec4(uv * 2.0 - 1.0, 0.0, 1.0);
				out_uv = uv;
			}
		]],
	},
	fragment = {
		custom_declarations = [[
			layout(location = 0) in vec2 in_uv;
			layout(location = 0) out vec4 out_color;
		]],
		push_constants = {
			{
				name = "blit",
				block = {
					{
						"tex",
						"int",
						function(constants)
							if not render3d.lighting_fbs then return -1 end

							return render3d.blit_pipeline:GetTextureIndex(render3d.lighting_fbs[render3d.current_lighting_fb_index]:GetAttachment(1))
						end,
					},
				},
			},
		},
		shader = [[
			void main() {
				if (pc.blit.tex == -1) {
					out_color = vec4(1.0, 0.0, 1.0, 1.0);
					return;
				}
				vec3 color = texture(TEXTURE(pc.blit.tex), in_uv).rgb;

				// Tonemapping (Filmic Narkowicz 2015)
				color = (color * (2.51 * color + 0.03)) / (color * (2.43 * color + 0.59) + 0.14);
				color = clamp(color, 0.0, 1.0);
				color = pow(color, vec3(1.0/2.2));

				out_color = vec4(color, 1.0);
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
	render3d.lighting_config.color_format = {"r16g16b16a16_sfloat"}
	render3d.blit_config.color_format = {render.target.color_format}
	render3d.blit_config.depth_format = render.target.depth_format
	render3d.blit_config.samples = render.target.samples

	local function create_gbuffer()
		local size = window:GetSize()
		render3d.gbuffer = Framebuffer.New(
			{
				width = size.x,
				height = size.y,
				formats = render3d.fill_config.color_format,
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
					formats = {"r16g16b16a16_sfloat"},
					depth = false,
				}
			)
		end

		render3d.current_lighting_fb_index = 1
	end

	local function create_ssao_noise()
		local function lerp(a, b, t)
			return a + (b - a) * t
		end

		render3d.ssao_kernel = {}

		for i = 1, 64 do
			local sample = Vec3(math.random() * 2 - 1, math.random() * 2 - 1, math.random()):Normalize()
			sample = sample * math.random()
			local scale = (i - 1) / 64
			scale = lerp(0.1, 1.0, scale * scale)
			sample = sample * scale
			table.insert(render3d.ssao_kernel, sample)
		end

		local ssao_noise = {}

		for i = 1, 16 do
			table.insert(ssao_noise, math.random() * 2 - 1)
			table.insert(ssao_noise, math.random() * 2 - 1)
			table.insert(ssao_noise, 0)
			table.insert(ssao_noise, 1)
		end

		local noise_buffer = ffi.new("float[?]", #ssao_noise, ssao_noise)
		render3d.ssao_noise_tex = Texture.New(
			{
				width = 4,
				height = 4,
				format = "r32g32b32a32_sfloat",
				buffer = noise_buffer,
				sampler = {
					min_filter = "nearest",
					mag_filter = "nearest",
					wrap_s = "repeat",
					wrap_t = "repeat",
				},
			}
		)
	end

	create_gbuffer()
	create_lighting_fbs()
	create_ssao_noise()
	render3d.fill_pipeline = EasyPipeline.New(render3d.fill_config)
	render3d.lighting_pipeline = EasyPipeline.New(render3d.lighting_config)
	render3d.blit_pipeline = EasyPipeline.New(render3d.blit_config)

	event.AddListener("WindowFramebufferResized", "render3d_gbuffer", function(wnd, size)
		create_gbuffer()
		create_lighting_fbs()
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

		for i = 1, #render3d.blit_pipeline.pipeline.descriptor_sets do
			render3d.blit_pipeline.pipeline:UpdateDescriptorSetArray(i, 0, textures)
		end
	end)

	event.AddListener("PreRenderPass", "draw_3d_geometry", function(cmd)
		if not render3d.fill_pipeline then return end

		local dt = 0 -- dt is not easily available here, but usually not needed for draw calls
		Light.UpdateUBOs(render3d.lighting_pipeline.pipeline)
		-- 1. Geometry Pass
		render3d.gbuffer:Begin(cmd)

		do
			render3d.fill_pipeline:Bind(cmd)
			event.Call("PreDraw3D", cmd, dt)
			event.Call("Draw3DGeometry", cmd, dt)
		end

		render3d.gbuffer:End(cmd)
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
		if not render3d.fill_pipeline then return end

		-- 3. Blit Lighting to Screen
		cmd:SetCullMode("none")
		render3d.blit_pipeline:Bind(cmd)
		render3d.blit_pipeline:UploadConstants(cmd)
		cmd:Draw(3, 1, 0, 0)
		-- Swap framebuffers for next frame
		render3d.current_lighting_fb_index = 3 - render3d.current_lighting_fb_index
	end)

	event.Call("Render3DInitialized")
end

function render3d.BindPipeline()
	render3d.fill_pipeline:Bind(render.GetCommandBuffer())
end

function render3d.UploadConstants(cmd)
	if render3d.fill_pipeline then
		do
			cmd:SetCullMode(render3d.GetMaterial():GetDoubleSided() and "none" or orientation.CULL_MODE)
		end

		render3d.fill_pipeline:UploadConstants(cmd)
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

do
	local debug_modes = {"none", "normals", "reflection", "light", "ssao"}
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
		return Mesh.New(render3d.fill_pipeline:GetVertexAttributes(), vertices, indices, index_type, index_count)
	end
end

if HOTRELOAD then render3d.Initialize() end

return render3d
