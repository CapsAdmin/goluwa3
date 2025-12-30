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
local render3d = library()
render3d.current_material = nil
render3d.environment_texture = nil
render3d.config = {
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
				// ORIENTATION / TRANSFORMATION
				gl_Position = pc.vertex.projection_view_world * vec4(in_position, 1.0);

				out_position = (pc.vertex.world * vec4(in_position, 1.0)).xyz;						
				out_normal = normalize(mat3(pc.vertex.world) * in_normal);
				out_uv = in_uv;
			}
		]],
	},
	fragment = {
		custom_declarations = [[
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

			// UBO for light and shadow data
			layout(std140, binding = 1) uniform LightData {
				ShadowData shadow;
				Light lights[32];
			} light_data;

			// output color
			layout(location = 0) out vec4 out_color;
		]],
		descriptor_sets = {
			{
				type = "uniform_buffer",
				binding_index = 1,
				args = function()
					return {Light.GetUBO()}
				end,
			},
		},
		uniform_buffers = {
			{
				name = "debug_data",
				binding_index = 2,
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
							return render3d.debug_mode or 0
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
							return render3d.GetMaterial():GetFlags()
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
						"EnvironmentTexture",
						"int",
						function(constants)
							return render3d.pipeline:GetTextureIndex(render3d.GetEnvironmentTexture())
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
						"NormalMapMultiplier",
						"float",
						function(constants)
							return render3d.GetMaterial():GetNormalMapMultiplier()
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
						"Albedo2Texture",
						"int",
						function(constants)
							return render3d.pipeline:GetTextureIndex(render3d.GetMaterial():GetAlbedo2Texture())
						end,
					},
					{
						"Normal2Texture",
						"int",
						function(constants)
							return render3d.pipeline:GetTextureIndex(render3d.GetMaterial():GetNormal2Texture())
						end,
					},
					{
						"AlbedoBlendTexture",
						"int",
						function(constants)
							return render3d.pipeline:GetTextureIndex(render3d.GetMaterial():GetAlbedoBlendTexture())
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
			{
				name = "fragment",
				block = {
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
				},
			},
		},
		shader = [[
			#define FLAGS pc.model.Flags
			]] .. Material.BuildGlslFlags() .. [[
			const float PI = 3.14159265359;

			float get_alpha() {
				if (
					AlbedoTextureAlphaIsMetallic ||
					AlbedoTextureAlphaIsRoughness 
				) {
					return pc.model.ColorMultiplier.a;	
				}

				float alpha = texture(TEXTURE(pc.model.AlbedoTexture), in_uv).a * pc.model.ColorMultiplier.a;
				return alpha;
			}

			vec3 get_albedo() {
				if (pc.model.AlbedoTexture == -1) {
					return pc.model.ColorMultiplier.rgb;
				}
				return texture(TEXTURE(pc.model.AlbedoTexture), in_uv).rgb * pc.model.ColorMultiplier.rgb;
			}

			vec3 get_normal() {
				if (pc.model.NormalTexture == -1) {
					return normalize(in_normal);
				}

				vec3 tangent_normal = texture(TEXTURE(pc.model.NormalTexture), in_uv).rgb * 2.0 - 1.0;
				
				if (ReverseXZNormalMap) {
					tangent_normal.x = -tangent_normal.x;
					tangent_normal.y = -tangent_normal.y;
				}						
				
				tangent_normal = normalize(tangent_normal);
				tangent_normal *= pc.model.NormalMapMultiplier;
				
				// Calculate tangents on-the-fly using screen-space derivatives
				vec3 dp1 = dFdx(in_position);
				vec3 dp2 = dFdy(in_position);
				vec2 duv1 = dFdx(in_uv);
				vec2 duv2 = dFdy(in_uv);
				
				// Solve for tangent and bitangent
				vec3 dp2perp = cross(dp2, in_normal);
				vec3 dp1perp = cross(in_normal, dp1);
				vec3 T = dp2perp * duv1.x + dp1perp * duv2.x;
				vec3 B = dp2perp * duv1.y + dp1perp * duv2.y;
				
				// Construct TBN matrix
				float invmax = inversesqrt(max(dot(T, T), dot(B, B)));
				mat3 TBN = mat3(T * invmax, B * invmax, in_normal);
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
				}

				return val * pc.model.MetallicMultiplier;
			}

			float get_roughness() {
				float val = 1.0;

				if (pc.model.AlbedoTexture != -1 && AlbedoTextureAlphaIsRoughness) {
					val = 1.0 - texture(TEXTURE(pc.model.AlbedoTexture), in_uv).a;
					if (InvertRoughnessTexture) {
						val = 1.0 - val;
					}
				} else if (AlbedoLuminanceIsRoughness) {
					val = dot(get_albedo(), vec3(0.2126, 0.7152, 0.0722));
					if (InvertRoughnessTexture) {
						val = 1.0 - val;
					}
				} else if (pc.model.RoughnessTexture != -1) {
					val = texture(TEXTURE(pc.model.RoughnessTexture), in_uv).r;
					if (InvertRoughnessTexture) {
						val = 1.0 - val;
					}
				} else if (pc.model.MetallicRoughnessTexture != -1) {
					val = texture(TEXTURE(pc.model.MetallicRoughnessTexture), in_uv).g;
				}

				return clamp(val * pc.model.RoughnessMultiplier, 0.04, 1.0);
			}

			vec3 env_color(vec3 normal, float roughness) {
				if (pc.model.EnvironmentTexture == -1) {
					return vec3(0.2);
				}

				vec3 V = normalize(pc.fragment.camera_position - in_position);
				
				// For cubemaps, we don't need to calculate UVs manually
				// We can just use the reflection vector
				vec3 R = reflect(-V, normal);
				
				// Calculate mip level based on roughness
				// Cubemaps usually have 5-10 mip levels
				float max_mip = 7.0; // Default for 128x128 cubemap
				float mip_level = roughness * max_mip;
				
				return textureLod(CUBEMAP(pc.model.EnvironmentTexture), R, mip_level).rgb;
			}

			vec3 get_emissive() {
				vec3 emissive = vec3(0.0);
				
				if (pc.model.SelfIlluminationTexture != -1) {
					// Self-illum mask: multiply albedo by mask value
					float mask = texture(TEXTURE(pc.model.SelfIlluminationTexture), in_uv).r;
					emissive = get_albedo() * mask;
				} else if (pc.model.MetallicTexture != -1 && MetallicTextureAlphaIsEmissive) {
					// Emissive stored in metallic texture alpha (selfillum_envmapmask_alpha)
					float mask = texture(TEXTURE(pc.model.MetallicTexture), in_uv).a;
					emissive = get_albedo() * mask;
				} else if (pc.model.EmissiveTexture != -1) {
					// Standard glTF emissive texture
					emissive = texture(TEXTURE(pc.model.EmissiveTexture), in_uv).rgb;
				}

				return emissive * pc.model.EmissiveMultiplier.rgb * pc.model.EmissiveMultiplier.a;
			}

			float get_ao() {
				if (pc.model.AmbientOcclusionTexture == -1) {
					return 1.0 * pc.model.AmbientOcclusionMultiplier;
				}
			
				return texture(TEXTURE(pc.model.AmbientOcclusionTexture), in_uv).r * pc.model.AmbientOcclusionMultiplier;
			}




			// Cascade debug colors
			const vec3 CASCADE_COLORS[4] = vec3[4](
				vec3(1.0, 0.2, 0.2),  // Red - cascade 1
				vec3(0.2, 1.0, 0.2),  // Green - cascade 2
				vec3(0.2, 0.2, 1.0),  // Blue - cascade 3
				vec3(1.0, 1.0, 0.2)   // Yellow - cascade 4
			);

			// Get cascade index based on view distance
			int getCascadeIndex(vec3 world_pos) {
				float dist = length(world_pos - pc.fragment.camera_position);
				
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
				// Get cascade index for this fragment
				int cascade_idx = getCascadeIndex(world_pos);
				if (cascade_idx < 0) {
					return 1.0;
				}
				
				// Get shadow map index for this cascade
				int shadow_map_idx = light_data.shadow.shadow_map_indices[cascade_idx];
				if (shadow_map_idx < 0) {
					return 1.0; // No shadow map for this cascade
				}
				
				// Normal offset bias to prevent shadow acne
				// The amount of offset depends on the angle of the surface to the light
				float bias_val = max(0.05 * (1.0 - dot(normal, light_dir)), 0.005);
				vec3 offset_pos = world_pos + normal * (bias_val );

				// Transform to light space using the cascade's matrix
				vec4 light_space_pos = light_data.shadow.light_space_matrices[cascade_idx] * vec4(offset_pos, 1.0);
				
				// Perspective divide
				vec3 proj_coords = light_space_pos.xyz / light_space_pos.w;
				
				// Transform X,Y from NDC [-1,1] to UV [0,1]
				// Z (depth) is already in [0,1] for Vulkan projection
				proj_coords.xy = proj_coords.xy * 0.5 + 0.5;
				
				// Outside shadow map
				if (proj_coords.z > 1.0 || proj_coords.z < 0.0 || proj_coords.x < 0.0 || proj_coords.x > 1.0 || proj_coords.y < 0.0 || proj_coords.y > 1.0) {
					return 1.0;
				}
				vec2 texel_size = 1.0 / textureSize(TEXTURE(shadow_map_idx), 0);

				float current_depth = proj_coords.z;
				float additional_bias = 0.001;
				
				// PCF - sample 3x3 area
				float shadow_val = 0.0;
				for (int x = -1; x <= 1; ++x) {
					for (int y = -1; y <= 1; ++y) {
						float pcf_depth = texture(TEXTURE(shadow_map_idx), proj_coords.xy + vec2(x, y) * texel_size).r;
						shadow_val += current_depth - additional_bias > pcf_depth ? 0.0 : 1.0;
					}
				}
				shadow_val /= 9.0;
				
				return shadow_val;
			}

			void main() {
				float alpha = get_alpha();

				if (AlphaTest) {
					if (alpha < pc.model.AlphaCutoff) {
						discard;
					}
				} else if (Translucent) {
					if (fract(dot(vec2(171.0, 231.0) + alpha * 0.00001, gl_FragCoord.xy) / 103.0) > (alpha * alpha)) {
						discard;
					}
				}

				vec3 albedo = get_albedo();
				vec3 N = get_normal();
				float metallic = get_metallic();
				float roughness = get_roughness();
				float ao = get_ao();
				vec3 emissive = get_emissive();
				vec3 reflection = env_color(N, roughness);

				// TODO: texture blending for world textures
				// TODO: tint albedo based on mask
				// TODO: emissive textures

				// View direction - camera position needs to be negated (view matrix uses negative position)
				vec3 V = normalize(pc.fragment.camera_position - in_position);
				
				// F0 for dielectrics is 0.04, for metals use albedo
				vec3 F0 = mix(vec3(0.04), albedo.rgb, metallic);
				float NdotV = max(dot(N, V), 0.001);

				vec3 Lo = vec3(0.0);
				for (int i = 0; i < pc.fragment.light_count; i++) {
					Light light = light_data.lights[i];
					int type = int(light.position.w);
					
					vec3 L;
					float attenuation = 1.0;
					
					if (type == 0) { // DIRECTIONAL
						L = normalize(-light.position.xyz);
					} else { // POINT or SPOT
						vec3 light_to_pos = light.position.xyz - in_position;
						float dist = length(light_to_pos);
						L = normalize(light_to_pos);
						
						float range = light.params.x;
						attenuation = clamp(1.0 - dist / range, 0.0, 1.0);
						attenuation *= attenuation;
						
						if (type == 2) { // SPOT
							// For spot lights, light.position.xyz is position, but we also need direction.
							// Wait, the current LightData doesn't have direction for spot lights?
							// Actually, for spot lights, we might need another field.
							// But let's look at how it was before.
						}
					}
					
					vec3 H = normalize(V + L);
					float NdotL = max(dot(N, L), 0.0);
					float HdotV = max(dot(H, V), 0.0);

					// Cook-Torrance BRDF
					float NDF = DistributionGGX(N, H, roughness);
					float G = GeometrySmith(N, V, L, roughness);
					vec3 F = fresnelSchlick(HdotV, F0);

					vec3 kS = F;
					vec3 kD = (1.0 - kS) * (1.0 - metallic);

					vec3 numerator = NDF * G * F;
					float denominator = 4.0 * NdotV * NdotL + 0.0001;
					vec3 specular = numerator / denominator;

					// Shadow - only for the first light (assumed sun) for now
					float shadow_factor = 1.0;
					if (i == 0 && light_data.shadow.shadow_map_indices[0] >= 0) {
						shadow_factor = calculateShadow(in_position, N, L);
					}

					vec3 radiance = light.color.rgb * light.color.a * attenuation;
					Lo += (kD * albedo.rgb / PI + specular) * radiance * NdotL * shadow_factor;
				}

				// Ambient - use environment map if available
				vec3 ambient_diffuse = reflection * albedo.rgb * ao;
				vec3 F_ambient = fresnelSchlick(NdotV, F0);
				vec3 ambient_specular = F_ambient * reflection * ao;
				vec3 ambient = ambient_diffuse * (1.0 - metallic) + ambient_specular * metallic;
				vec3 color = ambient + Lo + emissive;

				// Tonemapping + gamma
				color = color / (color + vec3(1.0));
				color = pow(color, vec3(1.0/2.2));

				// Debug: overlay cascade colors
				if (debug_data.debug_cascade_colors != 0) {
					int cascade_idx = getCascadeIndex(in_position);
					vec3 cascade_color = CASCADE_COLORS[cascade_idx];
					color = mix(color, cascade_color, 0.4);
				}

				if (debug_data.debug_mode == 1) { // normals
					color = N * 0.5 + 0.5;
				} else if (debug_data.debug_mode == 2) { // albedo
					color = albedo;
				} else if (debug_data.debug_mode == 3) { // roughness_metallic
					color = vec3(roughness, metallic, 0.0);
				} else if (debug_data.debug_mode == 4) { // depth
					float z = gl_FragCoord.z;
					float linear_depth = (debug_data.near_z * debug_data.far_z) / (debug_data.far_z + z * (debug_data.near_z - debug_data.far_z));
					color = vec3(linear_depth / 100.0); // Scale it so we can actually see something (e.g. 100 units)
				} else if (debug_data.debug_mode == 5) { // reflection
					color = reflection;
				} else if (debug_data.debug_mode == 6) { // geometry_normals
					color = normalize(in_normal) * 0.5 + 0.5;
				}

				out_color = vec4(color, alpha);
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
			{
				-- TODO: Respect Translucent flag from material for blend mode
				blend = false,
				src_color_blend_factor = "src_alpha",
				dst_color_blend_factor = "one_minus_src_alpha",
				color_blend_op = "add",
				src_alpha_blend_factor = "one",
				dst_alpha_blend_factor = "zero",
				alpha_blend_op = "add",
				color_write_mask = {"r", "g", "b", "a"},
			},
		},
	},
	multisampling = {
		sample_shading = false,
		rasterization_samples = "1",
	},
	depth_stencil = {
		depth_test = true,
		depth_write = true,
		depth_compare_op = "less",
		depth_bounds_test = false,
		stencil_test = false,
	},
}

--
function render3d.Initialize()
	if render3d.pipeline then return end

	-- Resolve descriptor set args functions
	for _, desc in ipairs(render3d.config.fragment.descriptor_sets) do
		if type(desc.args) == "function" then desc.args = desc.args() end
	end

	render3d.pipeline = EasyPipeline.New(render3d.config)

	-- Store uniform buffers in render3d for external access
	for name, ubo in pairs(render3d.pipeline.uniform_buffers) do
		render3d[name .. "_ubo"] = ubo
	end

	event.AddListener("Draw", "draw_3d", function(cmd, dt)
		if not render3d.pipeline then return end

		Light.UpdateUBOs(render3d.pipeline.pipeline)
		event.Call("DrawSkybox", cmd, dt)
		render3d.pipeline:Bind(cmd)
		event.Call("PreDraw3D", cmd, dt)
		event.Call("Draw3D", cmd, dt)
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

local debug_modes = {
	none = 0,
	normals = 1,
	albedo = 2,
	roughness_metallic = 3,
	depth = 4,
	reflection = 5,
	geometry_normals = 6,
}
render3d.debug_mode = 0

function render3d.SetDebugMode(mode)
	render3d.debug_mode = debug_modes[mode] or 0
end

function render3d.GetDebugMode()
	for k, v in pairs(debug_modes) do
		if v == render3d.debug_mode then return k end
	end

	return "none"
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
