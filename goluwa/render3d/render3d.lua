local ffi = require("ffi")
local render = require("render.render")
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
local VertexConstants = ffi.typeof([[
	struct {
		float projection_view_world[16];
		float world[16];
	}
]])
local FragmentConstants = ffi.typeof([[
	struct {
		int albedo_texture_index;
		int normal_texture_index;
		int metallic_roughness_texture_index;
		int occlusion_texture_index;
		int emissive_texture_index;
		int environment_texture_index;
		float base_color_factor[4];
		float metallic_factor;
		float roughness_factor;
		float normal_scale;
		float occlusion_strength;
		float emissive_factor[3];
		float camera_position[3];
		int debug_cascade_colors;
		int light_count;
	}
]])
local render3d = {}
render3d.current_material = nil
render3d.current_color = {1, 1, 1, 1}
render3d.current_metallic_multiplier = 1
render3d.current_roughness_multiplier = 1
render3d.environment_texture = nil

function render3d.Initialize()
	if render3d.pipeline then return end

	render3d.pipeline = render.CreateGraphicsPipeline(
		{
			dynamic_states = {"viewport", "scissor"},
			shader_stages = {
				{
					type = "vertex",
					code = [[
					#version 450
					#extension GL_EXT_scalar_block_layout : require

					layout(location = 0) in vec3 in_position;
					layout(location = 1) in vec3 in_normal;
					layout(location = 2) in vec2 in_uv;
					layout(location = 3) in vec4 in_tangent;

					layout(push_constant, scalar) uniform Constants {
						mat4 projection_view_world;
						mat4 world;
					} pc;

					layout(location = 0) out vec3 out_world_pos;
					layout(location = 1) out vec3 out_normal;
					layout(location = 2) out vec2 out_uv;
					layout(location = 3) out vec3 out_tangent;
					layout(location = 4) out vec3 out_bitangent;

					void main() {
						vec4 world_pos = pc.world * vec4(in_position, 1.0);

						// ORIENTATION / TRANSFORMATION: Coordinate system defined in orientation.lua
						gl_Position = pc.projection_view_world * vec4(in_position, 1.0);
						out_world_pos = world_pos.xyz;
						
						// ORIENTATION / TRANSFORMATION: Transform normal to world space
						// Transform normal to world space
						mat3 normal_matrix = mat3(pc.world);
						out_normal = normalize(normal_matrix * in_normal);
						out_uv = in_uv;
						
						// Calculate tangent and bitangent for normal mapping
						vec3 T = normalize(normal_matrix * in_tangent.xyz);
						vec3 N = out_normal;
						T = normalize(T - dot(T, N) * N);
						vec3 B = cross(N, T) * in_tangent.w;
						out_tangent = T;
						out_bitangent = B;
					}
				]],
					bindings = {
						{
							binding = 0,
							stride = ffi.sizeof("float") * 12, -- vec3 + vec3 + vec2 + vec4
							input_rate = "vertex",
						},
					},
					attributes = {
						{
							binding = 0,
							location = 0, -- in_position
							format = "r32g32b32_sfloat", -- vec3
							offset = 0,
						},
						{
							binding = 0,
							location = 1, -- in_normal
							format = "r32g32b32_sfloat", -- vec3
							offset = ffi.sizeof("float") * 3,
						},
						{
							binding = 0,
							location = 2, -- in_uv
							format = "r32g32_sfloat", -- vec2
							offset = ffi.sizeof("float") * 6,
						},
						{
							binding = 0,
							location = 3, -- in_tangent
							format = "r32g32b32a32_sfloat", -- vec4
							offset = ffi.sizeof("float") * 8,
						},
					},
					input_assembly = {
						topology = "triangle_list",
						primitive_restart = false,
					},
					push_constants = {
						size = ffi.sizeof(VertexConstants),
						offset = 0,
					},
				},
				{
					type = "fragment",
					code = [[
					#version 450
					#extension GL_EXT_nonuniform_qualifier : require
					#extension GL_EXT_scalar_block_layout : require

					layout(binding = 0) uniform sampler2D textures[1024]; // Bindless texture array
					
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

					// from vertex shader
					layout(location = 0) in vec3 in_world_pos;
					layout(location = 1) in vec3 in_normal;
					layout(location = 2) in vec2 in_uv;
					layout(location = 3) in vec3 in_tangent;
					layout(location = 4) in vec3 in_bitangent;

					// output color
					layout(location = 0) out vec4 out_color;

					layout(push_constant, scalar) uniform Constants {
						layout(offset = ]] .. ffi.sizeof(VertexConstants) .. [[)
						int albedo_texture_index;
						int normal_texture_index;
						int metallic_roughness_texture_index;
						int occlusion_texture_index;
						int emissive_texture_index;
						int environment_texture_index;
						vec4 base_color_factor;
						float metallic_factor;
						float roughness_factor;
						float normal_scale;
						float occlusion_strength;
						vec3 emissive_factor;
						vec3 camera_position;
						int debug_cascade_colors;
						int light_count;
					} pc;

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
						float dist = length(world_pos - pc.camera_position);
						
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
						vec2 texel_size = 1.0 / textureSize(textures[nonuniformEXT(shadow_map_idx)], 0);

						float current_depth = proj_coords.z;
						float additional_bias = 0.001;
						
						// PCF - sample 3x3 area
						float shadow_val = 0.0;
						for (int x = -1; x <= 1; ++x) {
							for (int y = -1; y <= 1; ++y) {
								float pcf_depth = texture(textures[nonuniformEXT(shadow_map_idx)], proj_coords.xy + vec2(x, y) * texel_size).r;
								shadow_val += current_depth - additional_bias > pcf_depth ? 0.0 : 1.0;
							}
						}
						shadow_val /= 9.0;
						
						return shadow_val;
					}

					// https://www.shadertoy.com/view/MslGR8
					bool alpha_discard(vec2 uv, float alpha)
					{
						if (false)
						{
							if (alpha*alpha > gl_FragCoord.z/10)
								return false;

							return true;
						}

						if (true)
						{
							return fract(dot(vec2(171.0, 231.0)+alpha*0.00001, gl_FragCoord.xy) / 103.0) > ((alpha * alpha) - 0.001);
						}

						return false;
					}

					vec3 sample_env_map(vec3 V, vec3 N, float roughness) 
					{
						ivec2 size = textureSize(textures[nonuniformEXT(pc.environment_texture_index)], 0);
						float max_mip = log2(max(size.x, size.y));
						
						vec3 R = reflect(-V, N);
						
						// Based on: mip_level = 0.5 * log2(solid_angle / pixel_solid_angle)
						// For GGX distribution: solid_angle ≈ π * α²
						float alpha = roughness * roughness;
						float mip_level = 0.5 * log2(alpha * alpha * size.x * size.y / PI);
						mip_level = clamp(mip_level, 0.0, max_mip);
						
						float u = atan(R.z, R.x) / (2.0 * PI) + 0.5;
						float v = asin(R.y) / PI + 0.5;
						
						return textureLod(textures[nonuniformEXT(pc.environment_texture_index)], vec2(u, -v), mip_level).rgb;
					}

					void main() {
						// Sample textures
						vec4 albedo = texture(textures[nonuniformEXT(pc.albedo_texture_index)], in_uv) * pc.base_color_factor;
						vec3 normal_map = texture(textures[nonuniformEXT(pc.normal_texture_index)], in_uv).rgb;
						vec4 metallic_roughness = texture(textures[nonuniformEXT(pc.metallic_roughness_texture_index)], in_uv);
						float ao = texture(textures[nonuniformEXT(pc.occlusion_texture_index)], in_uv).r;
						vec3 emissive = texture(textures[nonuniformEXT(pc.emissive_texture_index)], in_uv).rgb * pc.emissive_factor;

						// Alpha test
						if (alpha_discard(in_uv, albedo.a)) {
							discard;
						}

						// glTF: metallic in B, roughness in G
						float metallic = metallic_roughness.b * pc.metallic_factor;
						float roughness = clamp(metallic_roughness.g * pc.roughness_factor, 0.04, 1.0);

						// Calculate normal from normal map
						vec3 N;
						if (pc.normal_texture_index > 0) {
							vec3 tangent_normal = normal_map * 2.0 - 1.0;
							tangent_normal.xy *= pc.normal_scale;
							mat3 TBN = mat3(normalize(in_tangent), normalize(in_bitangent), normalize(in_normal));
							N = normalize(TBN * tangent_normal);
						} else {
							N = normalize(in_normal);
						}

						// View direction - camera position needs to be negated (view matrix uses negative position)
						vec3 V = normalize(pc.camera_position - in_world_pos);
						
						// F0 for dielectrics is 0.04, for metals use albedo
						vec3 F0 = mix(vec3(0.04), albedo.rgb, metallic);
						float NdotV = max(dot(N, V), 0.001);

						vec3 Lo = vec3(0.0);
						for (int i = 0; i < pc.light_count; i++) {
							Light light = light_data.lights[i];
							int type = int(light.position.w);
							
							vec3 L;
							float attenuation = 1.0;
							
							if (type == 0) { // DIRECTIONAL
								L = normalize(-light.position.xyz);
							} else { // POINT or SPOT
								vec3 light_to_pos = light.position.xyz - in_world_pos;
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
								shadow_factor = calculateShadow(in_world_pos, N, L);
							}

							vec3 radiance = light.color.rgb * light.color.a * attenuation;
							Lo += (kD * albedo.rgb / PI + specular) * radiance * NdotL * shadow_factor;
						}

						// Ambient - use environment map if available
						vec3 ambient_diffuse;
						vec3 ambient_specular;
						
						if (pc.environment_texture_index >= 0) {
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
						if (pc.debug_cascade_colors != 0) {
							int cascade_idx = getCascadeIndex(in_world_pos);
							vec3 cascade_color = CASCADE_COLORS[cascade_idx];
							color = mix(color, cascade_color, 0.4);
						}

						out_color = vec4(color, albedo.a);
					}
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
					},
					push_constants = {
						size = ffi.sizeof(FragmentConstants),
						offset = ffi.sizeof(VertexConstants),
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

	function events.Draw.draw_3d(cmd, dt)
		if not render3d.pipeline then return end

		Light.UpdateUBOs(render3d.pipeline)
		event.Call("DrawSkybox", cmd, dt)
		render3d.BindPipeline()
		event.Call("PreDraw3D", cmd, dt)
		event.Call("Draw3D", cmd, dt)
	end

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

do
	local vertex_constants = VertexConstants()
	local fragment_constants = FragmentConstants()

	function render3d.UploadConstants(cmd)
		do
			vertex_constants.projection_view_world = render3d.GetProjectionViewWorldMatrix():GetFloatCopy()
			vertex_constants.world = render3d.GetWorldMatrix():GetFloatCopy()
			render3d.pipeline:PushConstants(cmd, "vertex", 0, vertex_constants)
		end

		do
			local mat = render3d.current_material or Material.GetDefault()
			fragment_constants.albedo_texture_index = render3d.pipeline:GetTextureIndex(mat:GetAlbedoTexture())
			fragment_constants.normal_texture_index = render3d.pipeline:GetTextureIndex(mat:GetNormalTexture())
			fragment_constants.metallic_roughness_texture_index = render3d.pipeline:GetTextureIndex(mat:GetMetallicRoughnessTexture())
			fragment_constants.occlusion_texture_index = render3d.pipeline:GetTextureIndex(mat:GetOcclusionTexture())
			fragment_constants.emissive_texture_index = render3d.pipeline:GetTextureIndex(mat:GetEmissiveTexture())

			-- Environment texture
			if render3d.environment_texture then
				fragment_constants.environment_texture_index = render3d.pipeline:RegisterTexture(render3d.environment_texture)
			else
				fragment_constants.environment_texture_index = -1
			end

			-- Base color factor
			local c = render3d.current_color
			fragment_constants.base_color_factor[0] = mat.base_color_factor[1] * (c.r or c[1] or 1)
			fragment_constants.base_color_factor[1] = mat.base_color_factor[2] * (c.g or c[2] or 1)
			fragment_constants.base_color_factor[2] = mat.base_color_factor[3] * (c.b or c[3] or 1)
			fragment_constants.base_color_factor[3] = mat.base_color_factor[4] * (c.a or c[4] or 1)
			fragment_constants.metallic_factor = mat.metallic_factor * render3d.current_metallic_multiplier
			fragment_constants.roughness_factor = mat.roughness_factor * render3d.current_roughness_multiplier
			fragment_constants.normal_scale = mat.normal_scale
			fragment_constants.occlusion_strength = mat.occlusion_strength
			-- Emissive factor (vec3)
			fragment_constants.emissive_factor[0] = mat.emissive_factor[1]
			fragment_constants.emissive_factor[1] = mat.emissive_factor[2]
			fragment_constants.emissive_factor[2] = mat.emissive_factor[3]
			-- Camera position for specular (vec3)
			-- ORIENTATION / TRANSFORMATION: Using camera_position as-is
			local camera_position = render3d.camera:GetPosition()
			fragment_constants.camera_position[0] = camera_position.x
			fragment_constants.camera_position[1] = camera_position.y
			fragment_constants.camera_position[2] = camera_position.z
			-- Debug cascade visualization
			fragment_constants.debug_cascade_colors = render3d.debug_cascade_colors and 1 or 0
			fragment_constants.light_count = math.min(#Light.GetLights(), 32)
			render3d.pipeline:PushConstants(cmd, "fragment", ffi.sizeof(VertexConstants), fragment_constants)
		end
	end
end

function events.WindowFramebufferResized.render3d(wnd, size)
	render3d.camera:SetViewport(Rect(0, 0, size.x, size.y))
end

function render3d.SetMaterial(mat)
	render3d.current_material = mat

	if mat then mat:RegisterTextures(render3d.pipeline) end
end

function render3d.SetColor(c)
	render3d.current_color = c
end

function render3d.SetMetallicMultiplier(m)
	render3d.current_metallic_multiplier = m
end

function render3d.SetRoughnessMultiplier(r)
	render3d.current_roughness_multiplier = r
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
