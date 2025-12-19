local ffi = require("ffi")
local render = require("graphics.render")
local event = require("event")
local window = require("graphics.window")
local orientation = require("orientation")
local Material = require("graphics.material")
local Light = require("graphics.light")
local Matrix44 = require("structs.matrix").Matrix44
local Vec3 = require("structs.vec3")
local Ang3 = require("structs.ang3")
local Quat = require("structs.quat")
local Rect = require("structs.rect")
local Camera3D = require("graphics.camera3d")
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
		int shadow_map_indices[4];
		int environment_texture_index;
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
local ShadowUBO = ffi.typeof([[
	struct {
		float light_space_matrices[4][16];
		float cascade_splits[4];
		int cascade_count;
		float _pad[3];
	}
]])
local render3d = {}
render3d.current_material = nil
render3d.current_color = {1, 1, 1, 1}
render3d.current_metallic_multiplier = 1
render3d.current_roughness_multiplier = 1
-- Default light settings
render3d.light_direction = {0.5, -1.0, 0.3}
render3d.light_color = {1.0, 1.0, 1.0, 2.0} -- RGB + intensity
render3d.environment_texture = nil

function render3d.Initialize()
	if render3d.pipeline then return end

	-- Create shadow UBO buffer
	local shadow_ubo_data = ShadowUBO()

	-- Initialize with identity matrices for all cascades
	for cascade = 0, 3 do
		for i = 0, 15 do
			shadow_ubo_data.light_space_matrices[cascade][i] = (i % 5 == 0) and 1.0 or 0.0
		end
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
					
					// UBO for shadow data
					layout(std140, binding = 1) uniform ShadowData {
						mat4 light_space_matrices[4];
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
						int shadow_map_indices[4];
						int environment_texture_index;
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
						float dist = length(world_pos - pc.camera_position);
						
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
						// Get cascade index for this fragment
						int cascade_idx = getCascadeIndex(world_pos);
						
						// Get shadow map index for this cascade
						int shadow_map_idx = pc.shadow_map_indices[cascade_idx];
						if (shadow_map_idx <= 0) {
							return 1.0; // No shadow map for this cascade
						}
						
						// Transform to light space using the cascade's matrix
						vec4 light_space_pos = shadow.light_space_matrices[cascade_idx] * vec4(world_pos, 1.0);
						
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
						vec2 texel_size = 1.0 / textureSize(textures[nonuniformEXT(shadow_map_idx)], 0);
						for (int x = -1; x <= 1; ++x) {
							for (int y = -1; y <= 1; ++y) {
								float pcf_depth = texture(textures[nonuniformEXT(shadow_map_idx)], proj_coords.xy + vec2(x, y) * texel_size).r;
								shadow_val += current_depth - bias > pcf_depth ? 0.0 : 1.0;
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
					if (pc.shadow_map_indices[0] > 0) {
						shadow_factor = calculateShadow(in_world_pos);
					}

					// Final lighting
					vec3 radiance = pc.light_color * pc.light_intensity;
					vec3 Lo = (kD * albedo.rgb / PI + specular) * radiance * NdotL * shadow_factor;

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

	-- Create skybox pipeline
	render3d.skybox_pipeline = render.CreateGraphicsPipeline(
		{
			dynamic_states = {"viewport", "scissor"},
			shader_stages = {
				{
					type = "vertex",
					code = [[
					#version 450
					
					layout(location = 0) out vec3 out_direction;
					
					layout(push_constant) uniform Constants {
						mat4 inv_projection_view;
					} pc;
					
					vec2 positions[3] = vec2[](
						vec2(-1.0, -1.0),
						vec2( 3.0, -1.0),
						vec2(-1.0,  3.0)
					);
					
					void main() {
						vec2 pos = positions[gl_VertexIndex];
						gl_Position = vec4(pos, 1.0, 1.0);
						
						// Convert NDC to world direction
						vec4 world_pos = pc.inv_projection_view * vec4(pos, 1.0, 1.0);
						out_direction = world_pos.xyz / world_pos.w;
					}
				]],
					push_constants = {
						size = ffi.sizeof("float") * 16,
						offset = 0,
					},
				},
				{
					type = "fragment",
					code = [[
					#version 450
					#extension GL_EXT_nonuniform_qualifier : require
					
					layout(binding = 0) uniform sampler2D textures[1024];
					
					layout(location = 0) in vec3 in_direction;
					layout(location = 0) out vec4 out_color;
					
					layout(push_constant) uniform Constants {
						layout(offset = 64)
						int environment_texture_index;
					} pc;
					
					const float PI = 3.14159265359;
					
					void main() {
						if (pc.environment_texture_index < 0) {
							out_color = vec4(0.2, 0.2, 0.2, 1.0);
							return;
						}
						
						vec3 dir = normalize(in_direction);
						float u = atan(dir.z, dir.x) / (2.0 * PI) + 0.5;
						float v = asin(dir.y) / PI + 0.5;
						vec3 color = texture(textures[nonuniformEXT(pc.environment_texture_index)], vec2(u, -v)).rgb;
						
						// Tonemapping + gamma
						color = color / (color + vec3(1.0));
						color = pow(color, vec3(1.0/2.2));
						
						out_color = vec4(color, 1.0);
					}
				]],
					descriptor_sets = {
						{
							type = "combined_image_sampler",
							binding_index = 0,
							count = 1024,
						},
					},
					push_constants = {
						size = ffi.sizeof("int"),
						offset = ffi.sizeof("float") * 16,
					},
				},
			},
			rasterizer = {
				depth_clamp = false,
				discard = false,
				polygon_mode = "fill",
				line_width = 1.0,
				cull_mode = {"front"},
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
						src_color_blend_factor = "one",
						dst_color_blend_factor = "zero",
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
				depth_write = false,
				depth_compare_op = "less_or_equal",
				depth_bounds_test = false,
				stencil_test = false,
			},
		}
	)

	function events.Draw.draw_3d(cmd, dt)
		if not render3d.pipeline then return end

		-- Draw skybox first
		if render3d.environment_texture then render3d.DrawSkybox(cmd) end

		render3d.BindPipeline()
		event.Call("PreDraw3D", cmd, dt)
		event.Call("Draw3D", cmd, dt)
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

function render3d.SetLightDirection(x, y, z)
	render3d.light_direction = {x, y, z}

	-- Update sun light direction too if exists
	if render3d.sun_light then render3d.sun_light:SetDirection(Vec3(x, y, z)) end
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
		local cascade_count = shadow_map:GetCascadeCount()

		-- Copy all cascade light space matrices
		for i = 1, cascade_count do
			local matrix_data = shadow_map:GetLightSpaceMatrix(i):GetFloatCopy()
			ffi.copy(render3d.shadow_ubo_data.light_space_matrices[i - 1], matrix_data, ffi.sizeof("float") * 16)
		end

		-- Copy cascade splits
		local cascade_splits = shadow_map:GetCascadeSplits()

		for i = 1, 4 do
			render3d.shadow_ubo_data.cascade_splits[i - 1] = cascade_splits[i] or 0
		end

		render3d.shadow_ubo_data.cascade_count = cascade_count
		render3d.shadow_ubo:CopyData(render3d.shadow_ubo_data, ffi.sizeof(ShadowUBO))
	end
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

			-- Shadow map indices (one per cascade)
			if render3d.sun_light and render3d.sun_light:HasShadows() then
				local shadow_map = render3d.sun_light:GetShadowMap()
				local cascade_count = shadow_map:GetCascadeCount()

				for i = 1, cascade_count do
					fragment_constants.shadow_map_indices[i - 1] = render3d.pipeline:RegisterTexture(shadow_map:GetDepthTexture(i))
				end

				-- Fill remaining slots with 0
				for i = cascade_count + 1, 4 do
					fragment_constants.shadow_map_indices[i - 1] = 0
				end
			else
				for i = 0, 3 do
					fragment_constants.shadow_map_indices[i] = 0
				end
			end

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
			-- Light parameters (vec3)
			fragment_constants.light_direction[0] = render3d.light_direction[1]
			fragment_constants.light_direction[1] = render3d.light_direction[2]
			fragment_constants.light_direction[2] = render3d.light_direction[3]
			fragment_constants.light_color[0] = render3d.light_color[1]
			fragment_constants.light_color[1] = render3d.light_color[2]
			fragment_constants.light_color[2] = render3d.light_color[3]
			fragment_constants.light_intensity = render3d.light_color[4]
			-- Camera position for specular (vec3)
			-- ORIENTATION / TRANSFORMATION: Using camera_position as-is
			local camera_position = render3d.camera:GetPosition()
			fragment_constants.camera_position[0] = camera_position.x
			fragment_constants.camera_position[1] = camera_position.y
			fragment_constants.camera_position[2] = camera_position.z
			-- Debug cascade visualization
			fragment_constants.debug_cascade_colors = render3d.debug_cascade_colors and 1 or 0
			render3d.pipeline:PushConstants(cmd, "fragment", ffi.sizeof(VertexConstants), fragment_constants)
		end
	end
end

do
	local inv_proj_view = Matrix44()
	local SkyboxConstants = ffi.typeof([[
		struct {
			float inv_projection_view[16];
			int environment_texture_index;
		}
	]])
	local skybox_constants = SkyboxConstants()

	function render3d.DrawSkybox(cmd)
		if not render3d.environment_texture or not render3d.skybox_pipeline then
			return
		end

		local frame_index = render.GetCurrentFrame()
		render3d.skybox_pipeline:Bind(cmd, frame_index)
		-- Calculate inverse projection-view matrix (without camera translation for skybox)
		local proj = render3d.camera:BuildProjectionMatrix()
		local view = render3d.camera:BuildViewMatrix():Copy()
		-- Remove translation from view matrix for skybox
		view.m30 = 0
		view.m31 = 0
		view.m32 = 0
		local proj_view = view * proj
		proj_view:GetInverse(inv_proj_view)
		-- Upload constants
		local matrix_copy = inv_proj_view:GetFloatCopy()
		ffi.copy(skybox_constants.inv_projection_view, matrix_copy, ffi.sizeof("float") * 16)
		skybox_constants.environment_texture_index = render3d.skybox_pipeline:RegisterTexture(render3d.environment_texture)
		render3d.skybox_pipeline:PushConstants(cmd, "vertex", 0, skybox_constants)
		-- Draw fullscreen triangle
		cmd:Draw(3, 1, 0, 0)
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
	local Mesh = require("graphics.mesh")

	function render3d.CreateMesh(vertices, indices, index_type, index_count)
		return Mesh.New(render3d.pipeline:GetVertexAttributes(), vertices, indices, index_type, index_count)
	end
end

do
	local system = require("system")
	render3d.noculling = true -- Debug flag to disable culling
	render3d.freeze_culling = false -- Debug flag to freeze frustum for culling tests
	local function extract_frustum_planes(proj_view_matrix, out_planes)
		local m = proj_view_matrix
		-- Left plane: row3 + row0
		out_planes[0] = m.m03 + m.m00
		out_planes[1] = m.m13 + m.m10
		out_planes[2] = m.m23 + m.m20
		out_planes[3] = m.m33 + m.m30
		-- Right plane: row3 - row0
		out_planes[4] = m.m03 - m.m00
		out_planes[5] = m.m13 - m.m10
		out_planes[6] = m.m23 - m.m20
		out_planes[7] = m.m33 - m.m30
		-- Bottom plane: row3 + row1
		out_planes[8] = m.m03 + m.m01
		out_planes[9] = m.m13 + m.m11
		out_planes[10] = m.m23 + m.m21
		out_planes[11] = m.m33 + m.m31
		-- Top plane: row3 - row1
		out_planes[12] = m.m03 - m.m01
		out_planes[13] = m.m13 - m.m11
		out_planes[14] = m.m23 - m.m21
		out_planes[15] = m.m33 - m.m31
		-- Near plane: row3 + row2
		out_planes[16] = m.m03 + m.m02
		out_planes[17] = m.m13 + m.m12
		out_planes[18] = m.m23 + m.m22
		out_planes[19] = m.m33 + m.m32
		-- Far plane: row3 - row2
		out_planes[20] = m.m03 - m.m02
		out_planes[21] = m.m13 - m.m12
		out_planes[22] = m.m23 - m.m22
		out_planes[23] = m.m33 - m.m32

		for i = 0, 20, 4 do
			local a, b, c = out_planes[i], out_planes[i + 1], out_planes[i + 2]
			local len = math.sqrt(a * a + b * b + c * c)

			if len > 0 then
				local inv_len = 1.0 / len
				out_planes[i] = a * inv_len
				out_planes[i + 1] = b * inv_len
				out_planes[i + 2] = c * inv_len
				out_planes[i + 3] = out_planes[i + 3] * inv_len
			end
		end
	end

	local function is_aabb_visible_frustum(aabb, frustum_planes)
		for i = 0, 20, 4 do
			local a, b, c, d = frustum_planes[i], frustum_planes[i + 1], frustum_planes[i + 2], frustum_planes[i + 3]
			local px = a > 0 and aabb.max_x or aabb.min_x
			local py = b > 0 and aabb.max_y or aabb.min_y
			local pz = c > 0 and aabb.max_z or aabb.min_z

			if a * px + b * py + c * pz + d < 0 then return false end
		end

		return true
	end

	local function transform_plane(plane_offset, frustum_array, inv_matrix, out_offset, out_array)
		local a = frustum_array[plane_offset]
		local b = frustum_array[plane_offset + 1]
		local c = frustum_array[plane_offset + 2]
		local d = frustum_array[plane_offset + 3]
		local m = inv_matrix
		out_array[out_offset] = a * m.m00 + b * m.m01 + c * m.m02
		out_array[out_offset + 1] = a * m.m10 + b * m.m11 + c * m.m12
		out_array[out_offset + 2] = a * m.m20 + b * m.m21 + c * m.m22
		out_array[out_offset + 3] = a * m.m30 + b * m.m31 + c * m.m32 + d
	end

	do
		local local_frustum_planes = ffi.new("float[24]")

		function render3d.IsAABBVisibleLocal(local_aabb, inv_world)
			if render3d.noculling then return true end

			local world_frustum = render3d.GetFrustumPlanes()

			for i = 0, 20, 4 do
				transform_plane(i, world_frustum, inv_world, i, local_frustum_planes)
			end

			return is_aabb_visible_frustum(local_aabb, local_frustum_planes)
		end
	end

	do
		local cached_frustum_planes = ffi.new("float[24]")
		local cached_frustum_frame = -1

		function render3d.GetFrustumPlanes()
			if render3d.freeze_culling and cached_frustum_frame >= 0 then
				return cached_frustum_planes
			end

			local current_frame = system.GetFrameNumber()

			if cached_frustum_frame ~= current_frame then
				-- ORIENTATION / TRANSFORMATION: Extract frustum from projection-view matrix
				local proj = render3d.camera:BuildProjectionMatrix()
				local view = render3d.camera:BuildViewMatrix()
				extract_frustum_planes(proj * view, cached_frustum_planes)
				cached_frustum_frame = current_frame
			end

			return cached_frustum_planes
		end
	end
end

return render3d
