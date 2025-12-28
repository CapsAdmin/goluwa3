local ffi = require("ffi")
local render = require("render.render")
local UniformBuffer = require("render.uniform_buffer")
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
		push_constants = {
			{
				name = "model",
				block = {
					{"AlbedoTexture", "int", function(constants) return render3d.pipeline:GetTextureIndex(render3d.GetMaterial():GetAlbedoTexture()) end},
					{"NormalTexture", "int", function(constants) return render3d.pipeline:GetTextureIndex(render3d.GetMaterial():GetNormalTexture()) end},
					{"MetallicRoughnessTexture", "int", function(constants) return render3d.pipeline:GetTextureIndex(render3d.GetMaterial():GetMetallicRoughnessTexture()) end},
					{"OcclusionTexture", "int", function(constants) return render3d.pipeline:GetTextureIndex(render3d.GetMaterial():GetOcclusionTexture()) end},
					{"EmissiveTexture", "int", function(constants) return render3d.pipeline:GetTextureIndex(render3d.GetMaterial():GetEmissiveTexture()) end},
					{"EnvironmentTexture", "int", function(constants) return render3d.pipeline:GetTextureIndex(render3d.GetEnvironmentTexture()) end},
					{"ColorMultiplier", "vec4", function(constants) return render3d.GetMaterial().ColorMultiplier:CopyToFloatPointer(constants.ColorMultiplier) end},
					{"MetallicMultiplier", "float", function(constants) return render3d.GetMaterial().MetallicMultiplier end},
					{"RoughnessMultiplier", "float", function(constants) return render3d.GetMaterial().RoughnessMultiplier end},
					{"NormalMapMultiplier", "float", function(constants) return render3d.GetMaterial().NormalMapMultiplier end},
					{"AmbientOcclusionMultiplier", "float", function(constants) return render3d.GetMaterial().AmbientOcclusionMultiplier end},
					{"EmissiveMultiplier", "vec4", function(constants) return render3d.GetMaterial().EmissiveMultiplier:CopyToFloatPointer(constants.EmissiveMultiplier) end},
					{"ReverseXZNormalMap", "int", function(constants) return render3d.GetMaterial().ReverseXZNormalMap and 1 or 0 end},
					{"AlphaMode", "float", function(constants) return render3d.GetMaterial():GetAlphaModeInt() end},
					{"AlphaCutoff", "float", function(constants) return render3d.GetMaterial().AlphaCutoff end},
				},
			},
			{
				name = "fragment",
				block = {
					{"camera_position", "vec3", function(constants) return render3d.camera:GetPosition():CopyToFloatPointer(constants.camera_position) end},
					{"light_count", "int", function(constants) return math.min(#Light.GetLights(), 32) end},
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

			// Alpha test/discard function
			// AlphaMode: 0=OPAQUE (no discard), 1=MASK (alpha cutoff), 2=BLEND (dithered translucency)
			// https://www.shadertoy.com/view/MslGR8 (dither pattern)
			bool alpha_discard(vec2 uv, float alpha, int AlphaMode, float AlphaCutoff)
			{
				if (AlphaMode == 0) {
					// OPAQUE - never discard
					return false;
				}
				else if (AlphaMode == 1) {
					// MASK - alpha test with cutoff
					if (alpha < AlphaCutoff) {
						return true;
					}
					return false;
				}
				else if (AlphaMode == 2) {
					// BLEND - dithered translucency
					// Use screen-space dither pattern based on alpha value
					return fract(dot(vec2(171.0, 231.0) + alpha * 0.00001, gl_FragCoord.xy) / 103.0) > (alpha * alpha);
				}
				
				return false;
			}

			vec3 sample_env_map(vec3 V, vec3 N, float roughness) 
			{
				ivec2 size = textureSize(TEXTURE(pc.model.EnvironmentTexture), 0);
				float max_mip = log2(max(size.x, size.y));
				
				vec3 R = reflect(-V, N);
				
				// Based on: mip_level = 0.5 * log2(solid_angle / pixel_solid_angle)
				// For GGX distribution: solid_angle ≈ π * α²
				float alpha = roughness * roughness;
				float mip_level = 0.5 * log2(alpha * alpha * size.x * size.y / PI);
				mip_level = clamp(mip_level, 0.0, max_mip);
				
				float u = atan(R.z, R.x) / (2.0 * PI) + 0.5;
				float v = asin(R.y) / PI + 0.5;
				
				return textureLod(TEXTURE(pc.model.EnvironmentTexture), vec2(u, -v), mip_level).rgb;
			}

			void main() {
				// Sample textures
				vec4 albedo = texture(TEXTURE(pc.model.AlbedoTexture), in_uv) * pc.model.ColorMultiplier;
				vec3 normal_map = texture(TEXTURE(pc.model.NormalTexture), in_uv).rgb;					
				// Source engine normals have X and Z swapped
				if (pc.model.ReverseXZNormalMap != 0) {
					normal_map.x = 1 - normal_map.x;
					normal_map.z = 1 - normal_map.z;
				}						
				
				vec4 metallic_roughness = texture(TEXTURE(pc.model.MetallicRoughnessTexture), in_uv);
				float ao = texture(TEXTURE(pc.model.OcclusionTexture), in_uv).r;
				vec3 emissive = texture(TEXTURE(pc.model.EmissiveTexture), in_uv).rgb * pc.model.EmissiveMultiplier.rgb * pc.model.EmissiveMultiplier.a;

				// Alpha test/blend
				if (alpha_discard(in_uv, albedo.a, int(pc.model.AlphaMode), pc.model.AlphaCutoff)) {
					discard;
				}

				// glTF: metallic in B, roughness in G
				float metallic = metallic_roughness.b * pc.model.MetallicMultiplier;
				float roughness = clamp(metallic_roughness.g * pc.model.RoughnessMultiplier, 0.04, 1.0);

				// Calculate normal from normal map
				vec3 N;
				if (pc.model.NormalTexture > 0) {
					vec3 tangent_normal = normal_map * 2.0 - 1.0;
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
					N = normalize(TBN * tangent_normal);
				} else {
					N = normalize(in_normal);
				}
				
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
				vec3 ambient_diffuse;
				vec3 ambient_specular;
				
				if (pc.model.EnvironmentTexture >= 0) {
					ambient_diffuse = sample_env_map(V, N, roughness) * albedo.rgb * ao;
					
					vec3 F_ambient = fresnelSchlick(NdotV, F0);
					ambient_specular = F_ambient * sample_env_map(V, N, roughness) * ao;
				} else {
					// Fallback to simple ambient
					ambient_diffuse = vec3(0.02) * albedo.rgb * ao;
					vec3 F_ambient = fresnelSchlick(NdotV, F0);
					ambient_specular = F_ambient * albedo.rgb * 0.2 * ao;
				}
				
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
					color = albedo.rgb;
				} else if (debug_data.debug_mode == 3) { // roughness_metallic
					color = vec3(roughness, metallic, 0.0);
				} else if (debug_data.debug_mode == 4) { // depth
					float z = gl_FragCoord.z;
					float linear_depth = (debug_data.near_z * debug_data.far_z) / (debug_data.far_z + z * (debug_data.near_z - debug_data.far_z));
					color = vec3(linear_depth / 100.0); // Scale it so we can actually see something (e.g. 100 units)
				} else if (debug_data.debug_mode == 5) { // reflection
					if (pc.model.EnvironmentTexture >= 0) {
						color = sample_env_map(V, N, roughness);
					} else {
						color = vec3(0.0);
					}
				}

				out_color = vec4(color, albedo.a);
			}
		]],
	},
}

--
function render3d.Initialize()
	if render3d.pipeline then return end

	local glsl_to_ffi = {
		mat4 = "float",
		vec4 = "float",
		vec3 = "float",
		vec2 = "float",
		float = "float",
		int = "int",
	}
	local glsl_to_array_size = {
		mat4 = 16,
		vec4 = 4,
		vec3 = 3,
		vec2 = 2,
	}
	local push_constant_types = {}
	local stage_sizes = {vertex = 0, fragment = 0}

	local function get_field_info(field)
		local name = field[1]
		local glsl_type = field[2]
		local callback = field[3]
		local array_size = type(field[4]) == "number" and field[4] or nil

		return {
			name = name,
			glsl_type = glsl_type,
			callback = type(callback) == "function" and callback or nil,
			array_size = array_size,
		}
	end

	for stage, stage_config in pairs(render3d.config) do
		for _, block in ipairs(stage_config.push_constants) do
			local struct_name = block.name:sub(1, 1):upper() .. block.name:sub(2) .. "Constants"
			local ffi_code = "struct {\n"

			for _, field in ipairs(block.block) do
				local info = get_field_info(field)
				local ffi_type = glsl_to_ffi[info.glsl_type] or info.glsl_type
				local array_size = info.array_size or glsl_to_array_size[info.glsl_type]

				if array_size then
					ffi_code = ffi_code .. string.format("    %s %s[%d];\n", ffi_type, info.name, array_size)
				else
					ffi_code = ffi_code .. string.format("    %s %s;\n", ffi_type, info.name)
				end
			end

			ffi_code = ffi_code .. "}"
			local ctype = ffi.typeof(ffi_code)
			push_constant_types[struct_name] = ctype
			stage_sizes[stage] = stage_sizes[stage] + ffi.sizeof(ctype)
		end
	end

	local function get_glsl_push_constants(stage)
		local blocks = render3d.config[stage].push_constants
		local str = ""

		for _, block in ipairs(blocks) do
			local struct_name = block.name:sub(1, 1):upper() .. block.name:sub(2) .. "Constants"
			str = str .. "struct " .. struct_name .. " {\n"

			for _, field in ipairs(block.block) do
				local info = get_field_info(field)

				if info.array_size then
					str = str .. string.format("    %s %s[%d];\n", info.glsl_type, info.name, info.array_size)
				else
					str = str .. string.format("    %s %s;\n", info.glsl_type, info.name)
				end
			end

			str = str .. "};\n\n"
		end

		str = str .. "layout(push_constant, scalar) uniform Constants {\n"

		if stage == "fragment" then
			str = str .. "    layout(offset = " .. stage_sizes.vertex .. ")\n"
		end

		for _, block in ipairs(blocks) do
			local struct_name = block.name:sub(1, 1):upper() .. block.name:sub(2) .. "Constants"
			str = str .. "    " .. struct_name .. " " .. block.name .. ";\n"
		end

		str = str .. "} pc;\n\n"
		return str
	end

	local function build_constants()
		-- Create constant structs for each block
		local constant_structs = {}
		for struct_name, ctype in pairs(push_constant_types) do
			constant_structs[struct_name] = ctype()
		end

		function render3d.UploadConstants(cmd)
			-- Vertex stage
			do
				local offset = 0
				for _, block in ipairs(render3d.config.vertex.push_constants) do
					local struct_name = block.name:sub(1, 1):upper() .. block.name:sub(2) .. "Constants"
					local constants = constant_structs[struct_name]

					for _, field in ipairs(block.block) do
						local info = get_field_info(field)
						if info.callback then
							local value = info.callback(constants)
							if value ~= nil and not info.array_size and not glsl_to_array_size[info.glsl_type] then
								constants[info.name] = value
							end
							-- For arrays (vec4, mat4, etc.), the callback handles CopyToFloatPointer
						end
					end

					render3d.pipeline:PushConstants(cmd, 'vertex', offset, constants)
					offset = offset + ffi.sizeof(push_constant_types[struct_name])
				end
			end

			-- Fragment stage
			do
				local offset = stage_sizes.vertex
				for _, block in ipairs(render3d.config.fragment.push_constants) do
					local struct_name = block.name:sub(1, 1):upper() .. block.name:sub(2) .. "Constants"
					local constants = constant_structs[struct_name]

					for _, field in ipairs(block.block) do
						local info = get_field_info(field)
						if info.callback then
							local value = info.callback(constants)
							if value ~= nil and not info.array_size and not glsl_to_array_size[info.glsl_type] then
								constants[info.name] = value
							end
							-- For arrays (vec4, mat4, etc.), the callback handles CopyToFloatPointer
						end
					end

					render3d.pipeline:PushConstants(cmd, 'fragment', offset, constants)
					offset = offset + ffi.sizeof(push_constant_types[struct_name])
				end
			end

			-- Debug UBO
			local debug_constants = render3d.debug_ubo:GetData()
			debug_constants.debug_cascade_colors = render3d.debug_cascade_colors and 1 or 0
			debug_constants.debug_mode = render3d.debug_mode or 0
			debug_constants.near_z = render3d.camera:GetNearZ()
			debug_constants.far_z = render3d.camera:GetFarZ()
			render3d.debug_ubo:Upload()
		end
	end

	local attributes = {}
	local vertex_attributes_size = 0

	for _, attribute in ipairs(render3d.config.vertex.attributes) do
		local offset = 0

		do
			local prev = attributes[#attributes]

			if prev then
				local size = render.GetVulkanFormatSize(prev.format)
				offset = prev.offset + size
			end
		end

		table.insert(
			attributes,
			{
				binding = render3d.config.vertex.binding_index,
				location = #attributes,
				format = attribute[3],
				offset = offset,
			}
		)
		vertex_attributes_size = vertex_attributes_size + render.GetVulkanFormatSize(attribute[3])
	end

	local bindings = {
		{
			binding = render3d.config.vertex.binding_index,
			stride = vertex_attributes_size,
			input_rate = "vertex",
		},
	}
	local shader_header = [[
	#version 450
	#extension GL_EXT_nonuniform_qualifier : require
	#extension GL_EXT_scalar_block_layout : require
]]
	local vertex_input = ""

	for i, attr in ipairs(render3d.config.vertex.attributes) do
		vertex_input = vertex_input .. string.format("layout(location = %d) in %s in_%s;\n", i - 1, attr[2], attr[1])
	end

	local vertex_output = ""

	for i, attr in ipairs(render3d.config.vertex.attributes) do
		vertex_output = vertex_output .. string.format("layout(location = %d) out %s out_%s;\n", i - 1, attr[2], attr[1])
	end

	render3d.debug_ubo = UniformBuffer.New([[
		struct {
			int debug_cascade_colors;
			int debug_mode;
			float near_z;
			float far_z;
		}
	]])
	render3d.pipeline = render.CreateGraphicsPipeline(
		{
			dynamic_states = {"viewport", "scissor"},
			shader_stages = {
				{
					type = "vertex",
					code = shader_header .. [[
					]] .. vertex_input .. [[	
					]] .. vertex_output .. [[
					]] .. get_glsl_push_constants("vertex") .. [[	
					]] .. render3d.config.vertex.shader .. [[
				]],
					bindings = bindings,
					attributes = attributes,
					input_assembly = {
						topology = "triangle_list",
						primitive_restart = false,
					},
					push_constants = {
						size = stage_sizes.vertex,
						offset = 0,
					},
				},
				{
					type = "fragment",
					code = shader_header .. [[
					]] .. vertex_input .. [[

					layout(binding = 0) uniform sampler2D textures[1024];
					#define TEXTURE(idx) textures[nonuniformEXT(idx)]

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

					]] .. get_glsl_push_constants("fragment") .. [[


					]] .. render3d.debug_ubo:GetGLSLDeclaration(2, "debug_data") .. [[
				
					]] .. render3d.config.fragment.shader .. [[
				]],
					descriptor_sets = {
						{
							type = "combined_image_sampler",
							binding_index = 0,
							count = 1024,
						},
						{
							type = "uniform_buffer",
							binding_index = 1,
							args = {Light.GetUBO()},
						},
						{
							type = "uniform_buffer",
							binding_index = 2,
							args = {render3d.debug_ubo.buffer},
						},
					},
					push_constants = {
						size = stage_sizes.fragment,
						offset = stage_sizes.vertex,
					},
				},
			},
			rasterizer = {
				depth_clamp = false,
				discard = false,
				polygon_mode = "fill",
				line_width = 1.0,
				cull_mode = orientation.CULL_MODE, -- ORIENTATION / TRANSFORMATION
				front_face = orientation.FRONT_FACE,
				depth_bias = 0,
			},
			color_blend = {
				logic_op_enabled = false,
				logic_op = "copy",
				constants = {0.0, 0.0, 0.0, 0.0},
				attachments = {
					{
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
	)

	function render3d.BindPipeline()
		local cmd = render.GetCommandBuffer()
		local frame_index = render.GetCurrentFrame()
		render3d.pipeline:Bind(cmd, frame_index)
	end

	event.AddListener("Draw", "draw_3d", function(cmd, dt)
		if not render3d.pipeline then return end

		Light.UpdateUBOs(render3d.pipeline)
		event.Call("DrawSkybox", cmd, dt)
		render3d.BindPipeline()
		event.Call("PreDraw3D", cmd, dt)
		event.Call("Draw3D", cmd, dt)
	end)

	build_constants()
	event.Call("Render3DInitialized")
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

function render3d.GetMaterial(mat)
	return render3d.current_material or Material.GetDefault()
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
