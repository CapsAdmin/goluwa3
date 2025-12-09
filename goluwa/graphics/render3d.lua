local ffi = require("ffi")
local render = require("graphics.render")
local event = require("event")
local window = require("graphics.window")
local camera = require("graphics.camera")
local Material = require("graphics.material")
local Light = require("graphics.light")
local cam = camera.CreateCamera()
-- Push constants for vertex shader (128 bytes)
local VertexConstants = ffi.typeof([[
	struct {
		float projection_view_world[16];
		float world[16];
	}
]])
-- Push constants for fragment shader - PBR material data
local FragmentConstants = ffi.typeof([[
	struct {
		int albedo_texture_index;
		int normal_texture_index;
		int metallic_roughness_texture_index;
		int occlusion_texture_index;
		int emissive_texture_index;
		int shadow_map_index;
		float base_color_factor[4];
		float metallic_factor;
		float roughness_factor;
		float normal_scale;
		float occlusion_strength;
		float emissive_factor[3];
		float light_direction[3];
		float light_color[3];
		float light_intensity;
		float camera_position[3];
		int debug_cascade_colors;
	}
]])
-- UBO for shadow data (light space matrix + cascade info)
local ShadowUBO = ffi.typeof([[
	struct {
		float light_space_matrix[16];
		float cascade_splits[4];
		int cascade_count;
		float _pad[3];
	}
]])
local render3d = {}
render3d.cam = cam
render3d.current_material = nil
-- Default light settings
render3d.light_direction = {0.5, -1.0, 0.3}
render3d.light_color = {1.0, 1.0, 1.0, 2.0} -- RGB + intensity
function render3d.Initialize()
	-- Create shadow UBO buffer
	local shadow_ubo_data = ShadowUBO()

	-- Initialize with identity matrix
	for i = 0, 15 do
		shadow_ubo_data.light_space_matrix[i] = (i % 5 == 0) and 1.0 or 0.0
	end

	render3d.shadow_ubo = render.CreateBuffer(
		{
			data = shadow_ubo_data,
			byte_size = ffi.sizeof(ShadowUBO),
			buffer_usage = {"uniform_buffer"},
			memory_property = {"host_visible", "host_coherent"},
		}
	)
	render3d.shadow_ubo_data = shadow_ubo_data
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
						gl_Position = pc.projection_view_world * vec4(in_position, 1.0);
						out_world_pos = world_pos.xyz;
						
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
					
					// UBO for shadow data
					layout(std140, binding = 1) uniform ShadowData {
						mat4 light_space_matrix;
						vec4 cascade_splits;
						int cascade_count;
					} shadow;

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
						int shadow_map_index;
						vec4 base_color_factor;
						float metallic_factor;
						float roughness_factor;
						float normal_scale;
						float occlusion_strength;
						vec3 emissive_factor;
						vec3 light_direction;
						vec3 light_color;
						float light_intensity;
						vec3 camera_position;
						int debug_cascade_colors;
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
						vec3 cam_pos = -vec3(pc.camera_position.y, pc.camera_position.x, pc.camera_position.z);
						float dist = length(world_pos - cam_pos);
						
						for (int i = 0; i < shadow.cascade_count; i++) {
							if (dist < shadow.cascade_splits[i]) {
								return i;
							}
						}
						return shadow.cascade_count - 1;
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
					float calculateShadow(vec3 world_pos) {
						// Transform to light space
						vec4 light_space_pos = shadow.light_space_matrix * vec4(world_pos, 1.0);
						
						// Perspective divide
						vec3 proj_coords = light_space_pos.xyz / light_space_pos.w;
						
						// Transform X,Y from NDC [-1,1] to UV [0,1]
						// Z (depth) is already in [0,1] for Vulkan projection
						proj_coords.xy = proj_coords.xy * 0.5 + 0.5;
						
						// Outside shadow map
						if (proj_coords.z > 1.0 || proj_coords.z < 0.0 || proj_coords.x < 0.0 || proj_coords.x > 1.0 || proj_coords.y < 0.0 || proj_coords.y > 1.0) {
							return 1.0;
						}
						
						float current_depth = proj_coords.z;
						
						// Bias to reduce shadow acne
						float bias = 0.005;
						
						// PCF - sample 3x3 area
						float shadow_val = 0.0;
						vec2 texel_size = 1.0 / textureSize(textures[nonuniformEXT(pc.shadow_map_index)], 0);
						for (int x = -1; x <= 1; ++x) {
							for (int y = -1; y <= 1; ++y) {
								float pcf_depth = texture(textures[nonuniformEXT(pc.shadow_map_index)], proj_coords.xy + vec2(x, y) * texel_size).r;
								shadow_val += current_depth - bias > pcf_depth ? 0.0 : 1.0;
							}
						}
						shadow_val /= 9.0;
						
						return shadow_val;
					}

					void main() {
						// Sample textures
						vec4 albedo = texture(textures[nonuniformEXT(pc.albedo_texture_index)], in_uv) * pc.base_color_factor;
						vec3 normal_map = texture(textures[nonuniformEXT(pc.normal_texture_index)], in_uv).rgb;
						vec4 metallic_roughness = texture(textures[nonuniformEXT(pc.metallic_roughness_texture_index)], in_uv);
						float ao = texture(textures[nonuniformEXT(pc.occlusion_texture_index)], in_uv).r;
						vec3 emissive = texture(textures[nonuniformEXT(pc.emissive_texture_index)], in_uv).rgb * pc.emissive_factor;

						// Alpha test
						if (albedo.a < 0.5) {
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
						vec3 cam_pos = -vec3(pc.camera_position.y, pc.camera_position.x, pc.camera_position.z);
						vec3 V = normalize(cam_pos - in_world_pos);
						vec3 L = normalize(-pc.light_direction);
						vec3 H = normalize(V + L);

						// F0 for dielectrics is 0.04, for metals use albedo
						vec3 F0 = mix(vec3(0.04), albedo.rgb, metallic);

						// Pre-calculate dot products
						float NdotV = max(dot(N, V), 0.001);
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

						// Shadow
						float shadow_factor = 1.0;
						if (pc.shadow_map_index > 0) {
							shadow_factor = calculateShadow(in_world_pos);
						}

						// Final lighting
						vec3 radiance = pc.light_color * pc.light_intensity;
						vec3 Lo = (kD * albedo.rgb / PI + specular) * radiance * NdotL * shadow_factor;

						// Ambient - add simple environment approximation for metals
						vec3 ambient_diffuse = vec3(0.03) * albedo.rgb * ao;
						// Fake environment reflection for metals (fresnel at grazing angles)
						vec3 F_ambient = fresnelSchlick(NdotV, F0);
						vec3 ambient_specular = F_ambient * albedo.rgb * 0.2 * ao; // Approximate IBL
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
							args = {render3d.shadow_ubo},
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
				cull_mode = "none", -- Disable culling for double-sided materials
				front_face = "counter_clockwise",
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

	function events.Draw.draw_3d(cmd, dt)
		local frame_index = render.GetCurrentFrame()
		render3d.pipeline:Bind(cmd, frame_index)
		event.Call("Draw3D", cmd, dt)
	end
end

function render3d.SetWorldMatrix(world)
	cam:SetWorld(world)
end

function render3d.SetLightDirection(x, y, z)
	render3d.light_direction = {x, y, z}

	-- Update sun light direction too if exists
	if render3d.sun_light then render3d.sun_light:SetDirection(x, y, z) end
end

function render3d.SetLightColor(r, g, b, intensity)
	render3d.light_color = {r, g, b, intensity or 1.0}

	-- Update sun light color too if exists
	if render3d.sun_light then
		render3d.sun_light:SetColor(r, g, b)
		render3d.sun_light:SetIntensity(intensity or 1.0)
	end
end

function render3d.SetSunLight(light)
	render3d.sun_light = light

	if light then
		local dir = light:GetDirection()
		render3d.light_direction = {dir.x, dir.y, dir.z}
		local color = light:GetColor()
		local intensity = light:GetIntensity()
		render3d.light_color = {color.r, color.g, color.b, intensity}
	end
end

function render3d.GetSunLight()
	return render3d.sun_light
end

-- Debug state for cascade visualization
render3d.debug_cascade_colors = false

function render3d.SetDebugCascadeColors(enabled)
	render3d.debug_cascade_colors = enabled
end

function render3d.GetDebugCascadeColors()
	return render3d.debug_cascade_colors
end

-- Update the shadow UBO with the light space matrix and cascade info
function render3d.UpdateShadowUBO()
	if render3d.sun_light and render3d.sun_light:HasShadows() then
		local shadow_map = render3d.sun_light:GetShadowMap()
		local matrix_data = shadow_map.light_space_matrix:GetFloatCopy()
		ffi.copy(render3d.shadow_ubo_data.light_space_matrix, matrix_data, ffi.sizeof("float") * 16)
		-- Copy cascade splits
		local cascade_splits = shadow_map:GetCascadeSplits()
		local cascade_count = shadow_map:GetCascadeCount()

		for i = 1, 4 do
			render3d.shadow_ubo_data.cascade_splits[i - 1] = cascade_splits[i] or 0
		end

		render3d.shadow_ubo_data.cascade_count = cascade_count
		render3d.shadow_ubo:CopyData(render3d.shadow_ubo_data, ffi.sizeof(ShadowUBO))
	end
end

function render3d.UploadConstants(cmd)
	local matrices = cam:GetMatrices()

	do
		local vertex_constants = VertexConstants()
		vertex_constants.projection_view_world = matrices.projection_view_world:GetFloatCopy()
		vertex_constants.world = matrices.world:GetFloatCopy()
		render3d.pipeline:PushConstants(cmd, "vertex", 0, vertex_constants)
	end

	do
		local fragment_constants = FragmentConstants()
		local mat = render3d.current_material or Material.GetDefault()
		local indices = mat:GetTextureIndices(render3d.pipeline)
		fragment_constants.albedo_texture_index = indices.albedo
		fragment_constants.normal_texture_index = indices.normal
		fragment_constants.metallic_roughness_texture_index = indices.metallic_roughness
		fragment_constants.occlusion_texture_index = indices.occlusion
		fragment_constants.emissive_texture_index = indices.emissive

		-- Shadow map index
		if render3d.sun_light and render3d.sun_light:HasShadows() then
			local shadow_map = render3d.sun_light:GetShadowMap()
			fragment_constants.shadow_map_index = render3d.pipeline:RegisterTexture(shadow_map.depth_texture)
		else
			fragment_constants.shadow_map_index = 0
		end

		-- Base color factor
		fragment_constants.base_color_factor[0] = mat.base_color_factor[1]
		fragment_constants.base_color_factor[1] = mat.base_color_factor[2]
		fragment_constants.base_color_factor[2] = mat.base_color_factor[3]
		fragment_constants.base_color_factor[3] = mat.base_color_factor[4]
		fragment_constants.metallic_factor = mat.metallic_factor
		fragment_constants.roughness_factor = mat.roughness_factor
		fragment_constants.normal_scale = mat.normal_scale
		fragment_constants.occlusion_strength = mat.occlusion_strength
		-- Emissive factor (vec3)
		fragment_constants.emissive_factor[0] = mat.emissive_factor[1]
		fragment_constants.emissive_factor[1] = mat.emissive_factor[2]
		fragment_constants.emissive_factor[2] = mat.emissive_factor[3]
		-- Light parameters (vec3)
		fragment_constants.light_direction[0] = render3d.light_direction[1]
		fragment_constants.light_direction[1] = render3d.light_direction[2]
		fragment_constants.light_direction[2] = render3d.light_direction[3]
		fragment_constants.light_color[0] = render3d.light_color[1]
		fragment_constants.light_color[1] = render3d.light_color[2]
		fragment_constants.light_color[2] = render3d.light_color[3]
		fragment_constants.light_intensity = render3d.light_color[4]
		-- Camera position for specular (vec3)
		local cam_pos = cam:GetPosition()
		fragment_constants.camera_position[0] = cam_pos.x
		fragment_constants.camera_position[1] = cam_pos.y
		fragment_constants.camera_position[2] = cam_pos.z
		-- Debug cascade visualization
		fragment_constants.debug_cascade_colors = render3d.debug_cascade_colors and 1 or 0
		render3d.pipeline:PushConstants(cmd, "fragment", ffi.sizeof(VertexConstants), fragment_constants)
	end
end

function render3d.SetMaterial(mat)
	render3d.current_material = mat

	if mat then mat:RegisterTextures(render3d.pipeline) end
end

-- Legacy API for backwards compatibility
function render3d.SetTexture(tex)
	-- Create a simple material with just the albedo texture
	local mat = Material.New({
		albedo_texture = tex,
	})
	render3d.SetMaterial(mat)
end

return render3d
