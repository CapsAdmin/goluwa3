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
local Light = require("components.light")
local Framebuffer = require("render.framebuffer")
local render3d = library()
render3d.current_material = nil
render3d.environment_texture = nil
render3d.gbuffer = nil
render3d.config = {
	color_format = {
		"r8g8b8a8_unorm", -- albedo
		"r16g16b16a16_sfloat", -- normal
		"r8g8b8a8_unorm", -- metallic, roughness, ao
		"r8g8b8a8_unorm", -- emissive
	},
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
							return render3d.pipeline:GetTextureIndex(render3d.GetMaterial():GetAlbedoTexture())
						end,
					},
					{
						"NormalTexture",
						"int",
						function(constants)
							return render3d.pipeline:GetTextureIndex(render3d.GetMaterial():GetNormalTexture())
						end,
					},
					{
						"MetallicRoughnessTexture",
						"int",
						function(constants)
							return render3d.pipeline:GetTextureIndex(render3d.GetMaterial():GetMetallicRoughnessTexture())
						end,
					},
					{
						"AmbientOcclusionTexture",
						"int",
						function(constants)
							return render3d.pipeline:GetTextureIndex(render3d.GetMaterial():GetAmbientOcclusionTexture())
						end,
					},
					{
						"EmissiveTexture",
						"int",
						function(constants)
							return render3d.pipeline:GetTextureIndex(render3d.GetMaterial():GetEmissiveTexture())
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
							return render3d.pipeline:GetTextureIndex(render3d.GetMaterial():GetMetallicTexture())
						end,
					},
					{
						"RoughnessTexture",
						"int",
						function(constants)
							return render3d.pipeline:GetTextureIndex(render3d.GetMaterial():GetRoughnessTexture())
						end,
					},
					{
						"SelfIlluminationTexture",
						"int",
						function(constants)
							return render3d.pipeline:GetTextureIndex(render3d.GetMaterial():GetSelfIlluminationTexture())
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
				if (pc.model.NormalTexture == -1) {
					return normalize(in_normal);
				}
				
				vec3 tangent_normal = texture(TEXTURE(pc.model.NormalTexture), in_uv).xyz * 2.0 - 1.0;
				
				// Calculate TBN matrix on the fly
				vec3 Q1 = dFdx(in_position);
				vec3 Q2 = dFdy(in_position);
				vec2 st1 = dFdx(in_uv);
				vec2 st2 = dFdy(in_uv);

				vec3 N = normalize(in_normal);
				vec3 T = normalize(Q1 * st2.t - Q2 * st1.t);
				vec3 B = -normalize(cross(N, T));
				mat3 TBN = mat3(T, B, N);

				return normalize(TBN * tangent_normal);
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
					return pc.model.MetallicMultiplier;
				}
				return val * pc.model.MetallicMultiplier;
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
					return pc.model.RoughnessMultiplier;
				}
				return val * pc.model.RoughnessMultiplier;
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
						"camera_position",
						"vec3",
						function(constants)
							return render3d.camera:GetPosition():CopyToFloatPointer(constants.camera_position)
						end,
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
				},
			},
		},
		shader = [[
			const float PI = 3.14159265359;

			// Cascade debug colors
			const vec3 CASCADE_COLORS[4] = vec3[4](
				vec3(1.0, 0.2, 0.2),  // Red - cascade 1
				vec3(0.2, 1.0, 0.2),  // Green - cascade 2
				vec3(0.2, 0.2, 1.0),  // Blue - cascade 3
				vec3(1.0, 1.0, 0.2)   // Yellow - cascade 4
			);

			// Get cascade index based on view distance
			int getCascadeIndex(vec3 world_pos) {
				float dist = length(world_pos - lighting_data.camera_position);
				
				for (int i = 0; i < light_data.shadow.cascade_count; i++) {
					if (dist < light_data.shadow.cascade_splits[i]) {
						return i;
					}
				}
				return light_data.shadow.cascade_count - 1;
			}

			// GGX/Trowbridge-Reitz NDF
			float DistributionGGX(vec3 N, vec3 H, float roughness) {
				float a = roughness * roughness;
				float a2 = a * a;
				float NdotH = max(dot(N, H), 0.0);
				float NdotH2 = NdotH * NdotH;
				float denom = (NdotH2 * (a2 - 1.0) + 1.0);
				denom = PI * denom * denom;
				return a2 / max(denom, 0.0001);
			}

			// Schlick-GGX geometry function
			float GeometrySchlickGGX(float NdotV, float roughness) {
				float r = (roughness + 1.0);
				float k = (r * r) / 8.0;
				return NdotV / (NdotV * (1.0 - k) + k);
			}

			float GeometrySmith(vec3 N, vec3 V, vec3 L, float roughness) {
				float NdotV = max(dot(N, V), 0.0);
				float NdotL = max(dot(N, L), 0.0);
				return GeometrySchlickGGX(NdotV, roughness) * GeometrySchlickGGX(NdotL, roughness);
			}

			// Fresnel-Schlick
			vec3 fresnelSchlick(float cosTheta, vec3 F0) {
				return F0 + (1.0 - F0) * pow(clamp(1.0 - cosTheta, 0.0, 1.0), 5.0);
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
				if (lighting_data.env_tex == -1) return vec3(0.2);
				float NdotV = dot(normal, V);
				if (NdotV <= 0.0) return vec3(0.0);
				vec3 R = reflect(-V, normal);
				R = mix(R, normal, roughness * roughness);
				R = normalize(R);
				float max_mip = float(textureQueryLevels(CUBEMAP(lighting_data.env_tex)) - 1);
				float mip_level = sqrt(roughness) * (max_mip - 1.0) + 1.0;
				return textureLod(CUBEMAP(lighting_data.env_tex), R, mip_level).rgb;
			}

			void main() {
				vec4 albedo_alpha = texture(TEXTURE(lighting_data.albedo_tex), in_uv);
				//if (albedo_alpha.a == 0.0) discard;
				float depth = texture(TEXTURE(lighting_data.depth_tex), in_uv).r;
				vec3 albedo = albedo_alpha.rgb;

				if (depth == 1.0) {
					// Skybox or background
					vec3 color = albedo;
					color = color / (color + vec3(1.0));
					color = pow(color, vec3(1.0/2.2));
					out_color = vec4(color, albedo_alpha.a);
					return;
				}

				vec3 N = texture(TEXTURE(lighting_data.normal_tex), in_uv).xyz;
				vec3 mra = texture(TEXTURE(lighting_data.mra_tex), in_uv).rgb;
				float metallic = mra.r;
				float roughness = mra.g;
				float ao = mra.b;
				vec3 emissive = texture(TEXTURE(lighting_data.emissive_tex), in_uv).rgb;

				// Reconstruct world position from depth
				vec4 clip_pos = vec4(in_uv * 2.0 - 1.0, depth, 1.0);
				vec4 view_pos = lighting_data.inv_projection * clip_pos;
				view_pos /= view_pos.w;
				vec3 world_pos = (lighting_data.inv_view * view_pos).xyz;

				vec3 V = normalize(lighting_data.camera_position - world_pos);
				vec3 reflection = env_color(N, roughness, V, world_pos);
				vec3 F0 = mix(vec3(0.04), albedo, metallic);
				float NdotV = max(dot(N, V), 0.001);

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
						attenuation = clamp(1.0 - dist / range, 0.0, 1.0);
						attenuation *= attenuation;
					}
					vec3 H = normalize(V + L);
					float NdotL = max(dot(N, L), 0.0);
					float HdotV = max(dot(H, V), 0.0);
					float NDF = DistributionGGX(N, H, roughness);
					float G = GeometrySmith(N, V, L, roughness);
					vec3 F = fresnelSchlick(HdotV, F0);
					vec3 kS = F;
					vec3 kD = (1.0 - kS) * (1.0 - metallic);
					vec3 numerator = NDF * G * F;
					float denominator = 4.0 * NdotV * NdotL + 0.0001;
					vec3 specular = numerator / denominator;
					float shadow_factor = 1.0;
					if (i == 0 && light_data.shadow.shadow_map_indices[0] >= 0) {
						shadow_factor = calculateShadow(world_pos, N, L);
					}
					vec3 radiance = light.color.rgb * light.color.a * attenuation;
					Lo += (kD * albedo / PI + specular) * radiance * NdotL * shadow_factor;
				}

				vec3 ambient_diffuse = reflection * albedo * ao;
				vec3 F_ambient = fresnelSchlick(NdotV, F0);
				vec3 ambient_specular = F_ambient * reflection * ao;
				vec3 ambient = ambient_diffuse * (1.0 - metallic) + ambient_specular * metallic;
				vec3 color = ambient + Lo + emissive;

				color = color / (color + vec3(1.0));
				color = pow(color, vec3(1.0/2.2));

				if (lighting_data.debug_cascade_colors != 0) {
					int cascade_idx = getCascadeIndex(world_pos);
					color = mix(color, CASCADE_COLORS[cascade_idx], 0.4);
				}

				int mode = lighting_data.debug_mode - 1;
				
				if (mode == 1) {
					color = N * 0.5 + 0.5;
				} else if (mode == 2) {
					color = reflection;
				} else if (mode == 3) {
					color = ambient_specular + emissive;
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

--
function render3d.Initialize()
	if render3d.pipeline then return end

	local function create_gbuffer()
		local size = window:GetSize()
		render3d.gbuffer = Framebuffer.New(
			{
				width = size.x,
				height = size.y,
				formats = render3d.config.color_format,
				depth = true,
				depth_format = "d32_sfloat",
			}
		)
	end

	create_gbuffer()

	-- Resolve descriptor set args functions
	for _, desc in ipairs(render3d.config.fragment.descriptor_sets) do
		if type(desc.args) == "function" then desc.args = desc.args() end
	end

	for _, desc in ipairs(render3d.lighting_config.fragment.descriptor_sets) do
		if type(desc.args) == "function" then desc.args = desc.args() end
	end

	render3d.pipeline = EasyPipeline.New(render3d.config)
	render3d.lighting_pipeline = EasyPipeline.New(render3d.lighting_config)

	-- Store uniform buffers in render3d for external access
	for name, ubo in pairs(render3d.pipeline.uniform_buffers) do
		render3d[name .. "_ubo"] = ubo
	end

	event.AddListener("WindowFramebufferResized", "render3d_gbuffer", function(wnd, size)
		create_gbuffer()
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
	end)

	event.AddListener("PreRenderPass", "draw_3d_geometry", function(cmd)
		if not render3d.pipeline then return end

		local dt = 0 -- dt is not easily available here, but usually not needed for draw calls
		Light.UpdateUBOs(render3d.lighting_pipeline.pipeline)
		-- 1. Geometry Pass
		render3d.gbuffer:Begin(cmd)

		do
			event.Call("DrawSkybox", cmd, dt)
			render3d.pipeline:Bind(cmd)
			event.Call("PreDraw3D", cmd, dt)
			event.Call("Draw3DGeometry", cmd, dt)
		end

		render3d.gbuffer:End(cmd)
	end)

	event.AddListener("Draw", "draw_3d_lighting", function(cmd, dt)
		if not render3d.pipeline then return end

		-- 2. Lighting Pass
		cmd:SetCullMode("none")
		render3d.lighting_pipeline:Bind(cmd)
		render3d.lighting_pipeline:UploadConstants(cmd)
		cmd:Draw(3, 1, 0, 0)
	end)

	event.Call("Render3DInitialized")
end

function render3d.BindPipeline()
	render3d.pipeline:Bind(render.GetCommandBuffer())
end

function render3d.UploadConstants(cmd)
	if render3d.pipeline then
		do
			cmd:SetCullMode(render3d.GetMaterial():GetDoubleSided() and "none" or orientation.CULL_MODE)
		end

		render3d.pipeline:UploadConstants(cmd)
	end
end

do
	render3d.camera = Camera3D.New()
	render3d.world_matrix = Matrix44()

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
	local debug_modes = {"none", "normals", "reflection", "light"}
	render3d.debug_mode = 1

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
		return Mesh.New(render3d.pipeline:GetVertexAttributes(), vertices, indices, index_type, index_count)
	end
end

return render3d
