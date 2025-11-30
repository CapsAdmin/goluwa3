local ffi = require("ffi")
local render = require("graphics.render")
local event = require("event")
local window = require("graphics.window")
local camera = require("graphics.camera")
local Material = require("graphics.material")
local cam = camera.CreateCamera()
-- Push constants for vertex shader
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
		float base_color_factor[4];
		float metallic_factor;
		float roughness_factor;
		float normal_scale;
		float occlusion_strength;
		float emissive_factor[4];
		float light_direction[4];
		float light_color[4];
		float camera_position[4];
	}
]])
local render3d = {}
render3d.cam = cam
render3d.current_material = nil
-- Default light settings
render3d.light_direction = {0.5, -1.0, 0.3}
render3d.light_color = {1.0, 1.0, 1.0, 2.0} -- RGB + intensity
function render3d.Initialize()
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
							format = "R32G32B32_SFLOAT", -- vec3
							offset = 0,
						},
						{
							binding = 0,
							location = 1, -- in_normal
							format = "R32G32B32_SFLOAT", -- vec3
							offset = ffi.sizeof("float") * 3,
						},
						{
							binding = 0,
							location = 2, -- in_uv
							format = "R32G32_SFLOAT", -- vec2
							offset = ffi.sizeof("float") * 6,
						},
						{
							binding = 0,
							location = 3, -- in_tangent
							format = "R32G32B32A32_SFLOAT", -- vec4
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
						vec4 base_color_factor;
						float metallic_factor;
						float roughness_factor;
						float normal_scale;
						float occlusion_strength;
						vec4 emissive_factor;
						vec4 light_direction;
						vec4 light_color;
						vec4 camera_position;
					} pc;

					const float PI = 3.14159265359;

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

					void main() {
						// Sample textures
						vec4 albedo = texture(textures[nonuniformEXT(pc.albedo_texture_index)], in_uv) * pc.base_color_factor;
						vec3 normal_map = texture(textures[nonuniformEXT(pc.normal_texture_index)], in_uv).rgb;
						vec4 metallic_roughness = texture(textures[nonuniformEXT(pc.metallic_roughness_texture_index)], in_uv);
						float ao = texture(textures[nonuniformEXT(pc.occlusion_texture_index)], in_uv).r;
						vec3 emissive = texture(textures[nonuniformEXT(pc.emissive_texture_index)], in_uv).rgb * pc.emissive_factor.rgb;

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
						vec3 L = normalize(-pc.light_direction.xyz);
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

						// Final lighting
						vec3 light_color = pc.light_color.rgb * pc.light_color.w;
						vec3 Lo = (kD * albedo.rgb / PI + specular) * light_color * NdotL;

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

						out_color = vec4(color, albedo.a);
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

	event.AddListener("Draw", "draw_3d", function(cmd, dt)
		local frame_index = render.GetCurrentFrame()
		render3d.pipeline:Bind(cmd, frame_index)
		event.Call("Draw3D", cmd, dt)
	end)
end

function render3d.SetWorldMatrix(world)
	cam:SetWorld(world)
end

function render3d.SetLightDirection(x, y, z)
	render3d.light_direction = {x, y, z}
end

function render3d.SetLightColor(r, g, b, intensity)
	render3d.light_color = {r, g, b, intensity or 1.0}
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
		-- Base color factor
		fragment_constants.base_color_factor[0] = mat.base_color_factor[1]
		fragment_constants.base_color_factor[1] = mat.base_color_factor[2]
		fragment_constants.base_color_factor[2] = mat.base_color_factor[3]
		fragment_constants.base_color_factor[3] = mat.base_color_factor[4]
		fragment_constants.metallic_factor = mat.metallic_factor
		fragment_constants.roughness_factor = mat.roughness_factor
		fragment_constants.normal_scale = mat.normal_scale
		fragment_constants.occlusion_strength = mat.occlusion_strength
		-- Emissive factor
		fragment_constants.emissive_factor[0] = mat.emissive_factor[1]
		fragment_constants.emissive_factor[1] = mat.emissive_factor[2]
		fragment_constants.emissive_factor[2] = mat.emissive_factor[3]
		fragment_constants.emissive_factor[3] = 1.0
		-- Light parameters
		fragment_constants.light_direction[0] = render3d.light_direction[1]
		fragment_constants.light_direction[1] = render3d.light_direction[2]
		fragment_constants.light_direction[2] = render3d.light_direction[3]
		fragment_constants.light_direction[3] = 1.0 -- Flag to use camera position
		fragment_constants.light_color[0] = render3d.light_color[1]
		fragment_constants.light_color[1] = render3d.light_color[2]
		fragment_constants.light_color[2] = render3d.light_color[3]
		fragment_constants.light_color[3] = render3d.light_color[4]
		-- Camera position for specular
		local cam_pos = cam:GetPosition()
		fragment_constants.camera_position[0] = cam_pos.x
		fragment_constants.camera_position[1] = cam_pos.y
		fragment_constants.camera_position[2] = cam_pos.z
		fragment_constants.camera_position[3] = 1.0
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
