local ffi = require("ffi")
local event = require("event")
local render = require("render.render")
local render3d = require("render3d.render3d")
local Camera3D = require("render3d.camera3d")
local Texture = require("render.texture")
local Framebuffer = require("render.framebuffer")
local Fence = require("render.vulkan.internal.fence")
local Matrix44 = require("structs.matrix44")
local Vec3 = require("structs.vec3")
local Rect = require("structs.rect")
local skybox = require("render3d.skybox")
local reflection_probe = {}
-- Configuration
reflection_probe.SIZE = 128 -- Cubemap resolution per face
reflection_probe.UPDATE_FACES_PER_FRAME = 1 -- How many faces to update each frame
reflection_probe.GRID_COUNTS = Vec3(4, 4, 4)
reflection_probe.GRID_SPACING = Vec3(10, 10, 10)
reflection_probe.GRID_ORIGIN = Vec3(35, -1.5, 50)
reflection_probe.PROBE_COUNT = reflection_probe.GRID_COUNTS.x * reflection_probe.GRID_COUNTS.y * reflection_probe.GRID_COUNTS.z
reflection_probe.enabled = true
-- State
reflection_probe.probes = {}
reflection_probe.current_probe_index = 0
reflection_probe.current_face = 0
reflection_probe.temp_camera = nil
reflection_probe.pipeline = nil
reflection_probe.prefilter_pipeline = nil
reflection_probe.inv_projection_view = Matrix44()
-- Face rotation angles (same as skybox.lua)
local face_angles = {
	Deg3(0, -90 + 180, 0), -- +X
	Deg3(0, 90 + 180, 0), -- -X
	Deg3(90, 0 + 180, 0), -- +Y
	Deg3(-90, 0 + 180, 0), -- -Y
	Deg3(0, 0 + 180, 0), -- +Z
	Deg3(0, 180 + 180, 0), -- -Z
}

function reflection_probe.Initialize()
	if next(reflection_probe.probes) then return end

	local SIZE = reflection_probe.SIZE

	for i = 0, reflection_probe.PROBE_COUNT - 1 do
		local probe = {}
		reflection_probe.probes[i] = probe
		-- Create the output cubemap (prefiltered, used for rendering)
		probe.cubemap = Texture.New(
			{
				width = SIZE,
				height = SIZE,
				format = "b10g11r11_ufloat_pack32",
				mip_map_levels = "auto",
				image = {
					array_layers = 6,
					flags = {"cube_compatible"},
					usage = {"color_attachment", "sampled", "transfer_src", "transfer_dst"},
				},
				view = {
					view_type = "cube",
					layer_count = 6,
				},
			}
		)
		-- Create source cubemap (raw scene render, before prefiltering)
		probe.source_cubemap = Texture.New(
			{
				width = SIZE,
				height = SIZE,
				format = "b10g11r11_ufloat_pack32",
				mip_map_levels = "auto",
				image = {
					array_layers = 6,
					flags = {"cube_compatible"},
					usage = {"color_attachment", "sampled", "transfer_src", "transfer_dst"},
				},
				view = {
					view_type = "cube",
					layer_count = 6,
				},
			}
		)
		-- Create depth cubemap (linear depth for parallax correction)
		probe.depth_cubemap = Texture.New(
			{
				width = SIZE,
				height = SIZE,
				format = "r32_sfloat", -- Store linear depth as single float
				mip_map_levels = 1,
				image = {
					array_layers = 6,
					flags = {"cube_compatible"},
					usage = {"color_attachment", "sampled", "transfer_src", "transfer_dst"},
				},
				view = {
					view_type = "cube",
					layer_count = 6,
				},
			}
		)
		-- Create per-face views for source cubemap
		probe.source_face_views = {}

		for j = 0, 5 do
			probe.source_face_views[j] = probe.source_cubemap:GetImage():CreateView(
				{
					view_type = "2d",
					base_array_layer = j,
					layer_count = 1,
					base_mip_level = 0,
					level_count = 1,
				}
			)
		end

		-- Create per-face views for depth cubemap
		probe.depth_face_views = {}

		for j = 0, 5 do
			probe.depth_face_views[j] = probe.depth_cubemap:GetImage():CreateView(
				{
					view_type = "2d",
					base_array_layer = j,
					layer_count = 1,
					base_mip_level = 0,
					level_count = 1,
				}
			)
		end

		-- Create per-mip per-face views for output cubemap
		local num_mips = probe.cubemap.mip_map_levels
		probe.mip_face_views = {}

		for m = 0, num_mips - 1 do
			probe.mip_face_views[m] = {}

			for j = 0, 5 do
				probe.mip_face_views[m][j] = probe.cubemap:GetImage():CreateView(
					{
						view_type = "2d",
						base_array_layer = j,
						layer_count = 1,
						base_mip_level = m,
						level_count = 1,
					}
				)
			end
		end

		-- Set probe position in a grid
		local gx = i % reflection_probe.GRID_COUNTS.x
		local gy = math.floor(i / reflection_probe.GRID_COUNTS.x) % reflection_probe.GRID_COUNTS.y
		local gz = math.floor(i / (reflection_probe.GRID_COUNTS.x * reflection_probe.GRID_COUNTS.y))
		probe.position = reflection_probe.GRID_ORIGIN + Vec3(
				gx * reflection_probe.GRID_SPACING.x,
				gy * reflection_probe.GRID_SPACING.y,
				gz * reflection_probe.GRID_SPACING.z
			)
	end

	-- Create camera for probe rendering
	reflection_probe.temp_camera = Camera3D.New()
	reflection_probe.temp_camera:SetFOV(math.rad(90))
	reflection_probe.temp_camera:SetViewport(Rect(0, 0, SIZE, SIZE))
	reflection_probe.temp_camera:SetNearZ(0.1)
	reflection_probe.temp_camera:SetFarZ(1000)
	-- Create pipeline for rendering scene to probe
	reflection_probe.CreatePipelines()
	-- Create fence for synchronization
	reflection_probe.fence = Fence.New(render.GetDevice())
	-- Initialize cubemap layouts
	reflection_probe.InitializeCubemapLayouts()
end

-- Initialize all cubemap faces to shader_read_only_optimal layout
function reflection_probe.InitializeCubemapLayouts()
	local cmd = render.GetCommandPool():AllocateCommandBuffer()
	cmd:Begin()

	for i = 0, reflection_probe.PROBE_COUNT - 1 do
		local probe = reflection_probe.probes[i]
		-- Transition source cubemap to shader_read_only_optimal
		cmd:PipelineBarrier(
			{
				srcStage = "top_of_pipe",
				dstStage = "fragment_shader",
				imageBarriers = {
					{
						image = probe.source_cubemap:GetImage(),
						oldLayout = "undefined",
						newLayout = "shader_read_only_optimal",
						srcAccessMask = "none",
						dstAccessMask = "shader_read",
						base_array_layer = 0,
						layer_count = 6,
						base_mip_level = 0,
						level_count = probe.source_cubemap.mip_map_levels,
					},
				},
			}
		)
		-- Transition output cubemap to shader_read_only_optimal
		cmd:PipelineBarrier(
			{
				srcStage = "top_of_pipe",
				dstStage = "fragment_shader",
				imageBarriers = {
					{
						image = probe.cubemap:GetImage(),
						oldLayout = "undefined",
						newLayout = "shader_read_only_optimal",
						srcAccessMask = "none",
						dstAccessMask = "shader_read",
						base_array_layer = 0,
						layer_count = 6,
						base_mip_level = 0,
						level_count = probe.cubemap.mip_map_levels,
					},
				},
			}
		)
		-- Transition depth cubemap to shader_read_only_optimal
		cmd:PipelineBarrier(
			{
				srcStage = "top_of_pipe",
				dstStage = "fragment_shader",
				imageBarriers = {
					{
						image = probe.depth_cubemap:GetImage(),
						oldLayout = "undefined",
						newLayout = "shader_read_only_optimal",
						srcAccessMask = "none",
						dstAccessMask = "shader_read",
						base_array_layer = 0,
						layer_count = 6,
						base_mip_level = 0,
						level_count = 1,
					},
				},
			}
		)
	end

	cmd:End()
	render.GetQueue():SubmitAndWait(render.GetDevice(), cmd, reflection_probe.fence)
	render.GetCommandPool():FreeCommandBuffer(cmd)
end

function reflection_probe.CreatePipelines()
	local EasyPipeline = require("render.easy_pipeline")
	local orientation = require("render3d.orientation")
	local skybox = require("render3d.skybox")
	local Material = require("render3d.material")
	local Light = require("components.light")
	-- Pipeline to render the scene into a cubemap face
	-- This is similar to the fill pipeline but outputs to a single color attachment
	-- and includes basic lighting so reflections look correct
	reflection_probe.scene_pipeline = EasyPipeline.New(
		{
			color_format = {
				{"b10g11r11_ufloat_pack32", {"color", "rgba"}},
				{"r32_sfloat", {"linear_depth", "r"}},
			}, -- Color + linear depth
			depth_format = "d32_sfloat",
			samples = "1",
			color_blend = {
				attachments = {
					{blend = false, color_write_mask = {"r", "g", "b", "a"}},
					{blend = false, color_write_mask = {"r", "g", "b", "a"}},
				},
			},
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
									return reflection_probe.GetProjectionViewWorldMatrix():CopyToFloatPointer(constants.projection_view_world)
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
                struct Light {
                    vec4 position;
                    vec4 color;
                    vec4 params;
                };
                
                layout(std140, binding = 2) uniform LightData {
                    float _shadow_padding[84];
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
						name = "probe_data",
						binding_index = 3,
						block = {
							{
								"camera_position",
								"vec4",
								function(constants)
									local p = reflection_probe.temp_camera:GetPosition()
									constants.camera_position[0] = p.x
									constants.camera_position[1] = p.y
									constants.camera_position[2] = p.z
									constants.camera_position[3] = 0
								end,
							},
							{
								"stars_texture_index",
								"int",
								function(constants)
									return reflection_probe.scene_pipeline:GetTextureIndex(skybox.stars_texture)
								end,
							},
							{
								"sun_direction",
								"vec4",
								function(constants)
									local lights = render3d.GetLights()

									if lights[1] then
										lights[1]:GetRotation():GetBackward():CopyToFloatPointer(constants.sun_direction)
									end
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
									return reflection_probe.scene_pipeline:GetTextureIndex(render3d.GetMaterial():GetAlbedoTexture())
								end,
							},
							{
								"NormalTexture",
								"int",
								function(constants)
									return reflection_probe.scene_pipeline:GetTextureIndex(render3d.GetMaterial():GetNormalTexture())
								end,
							},
							{
								"MetallicRoughnessTexture",
								"int",
								function(constants)
									return reflection_probe.scene_pipeline:GetTextureIndex(render3d.GetMaterial():GetMetallicRoughnessTexture())
								end,
							},
							{
								"EmissiveTexture",
								"int",
								function(constants)
									return reflection_probe.scene_pipeline:GetTextureIndex(render3d.GetMaterial():GetEmissiveTexture())
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
								"EmissiveMultiplier",
								"vec4",
								function(constants)
									return render3d.GetMaterial():GetEmissiveMultiplier():CopyToFloatPointer(constants.EmissiveMultiplier)
								end,
							},
						},
					},
				},
				shader = [[
                ]] .. Material.BuildGlslFlags("pc.model.Flags") .. [[
                ]] .. skybox.GetGLSLCode() .. [[
                
                #define PI 3.14159265359
                #define saturate(x) clamp(x, 0.0, 1.0)
                
                vec3 get_albedo() {
                    if (pc.model.AlbedoTexture == -1) {
                        return pc.model.ColorMultiplier.rgb;
                    }
                    return texture(TEXTURE(pc.model.AlbedoTexture), in_uv).rgb * pc.model.ColorMultiplier.rgb;
                }
                
                float get_alpha() {
                    if (pc.model.AlbedoTexture == -1) {
                        return pc.model.ColorMultiplier.a;
                    }
                    return texture(TEXTURE(pc.model.AlbedoTexture), in_uv).a * pc.model.ColorMultiplier.a;
                }
                
                vec3 get_normal() {
                    vec3 N = in_normal;
                    if (pc.model.NormalTexture != -1) {
                        vec3 tangent_normal = texture(TEXTURE(pc.model.NormalTexture), in_uv).xyz * 2.0 - 1.0;
                        vec3 Q1 = dFdx(in_position);
                        vec3 Q2 = dFdy(in_position);
                        vec2 st1 = dFdx(in_uv);
                        vec2 st2 = dFdy(in_uv);
                        vec3 N_orig = normalize(in_normal);
                        vec3 T = normalize(Q1 * st2.t - Q2 * st1.t);
                        vec3 B = -normalize(cross(N_orig, T));
                        mat3 TBN = mat3(T, B, N_orig);
                        N = TBN * tangent_normal;
                    }
                    if (DoubleSided && gl_FrontFacing) {
                        N = -N;
                    }
                    return normalize(N);
                }
                
                float get_metallic() {
                    if (pc.model.MetallicRoughnessTexture != -1) {
                        return texture(TEXTURE(pc.model.MetallicRoughnessTexture), in_uv).b * pc.model.MetallicMultiplier;
                    }
                    return pc.model.MetallicMultiplier;
                }
                
                float get_roughness() {
                    if (pc.model.MetallicRoughnessTexture != -1) {
                        return texture(TEXTURE(pc.model.MetallicRoughnessTexture), in_uv).g * pc.model.RoughnessMultiplier;
                    }
                    return pc.model.RoughnessMultiplier;
                }
                
                vec3 get_emissive() {
                    if (pc.model.EmissiveTexture != -1) {
                        return texture(TEXTURE(pc.model.EmissiveTexture), in_uv).rgb * pc.model.EmissiveMultiplier.rgb;
                    }
                    return pc.model.EmissiveMultiplier.rgb * pc.model.EmissiveMultiplier.a;
                }
                
                void main() {
                    vec3 N = get_normal();
                    vec3 V = normalize(probe_data.camera_position.xyz - in_position);
                    vec3 albedo = get_albedo();
                    float metallic = get_metallic();
                    float roughness = get_roughness();
                    vec3 emissive = get_emissive();
                    
                    // Simple directional light calculation
                    vec3 L = normalize(-light_data.lights[0].position.xyz);
                    float NoL = max(dot(N, L), 0.0);
                    vec3 light_color = light_data.lights[0].color.rgb * light_data.lights[0].color.a;
                    
                    // Basic diffuse + ambient
                    vec3 diffuse = albedo * NoL * light_color;
                    vec3 ambient = albedo * 0.1;
                    
                    vec3 color = diffuse + ambient + emissive;
                    
                    // Check if this is sky (depth == 1.0 equivalent - we use a flag or check normal)
                    if (get_alpha() < 0.01) {
                        // Render sky
                        vec3 sky_color_output;
                        vec3 dir = normalize(in_position - probe_data.camera_position.xyz);
                        vec3 sunDir = normalize(probe_data.sun_direction.xyz);
                        ]] .. skybox.GetGLSLMainCode(
						"dir",
						"sunDir",
						"probe_data.camera_position.xyz",
						"probe_data.stars_texture_index"
					) .. [[
                        color = sky_color_output;
                    }
                    
                    // Clamp to prevent infinities in HDR
                    color = clamp(color, vec3(0.0), vec3(65504.0));
                    set_color(vec4(color, 1.0));
                    
                    // Output linear depth (distance from probe camera)
                    set_linear_depth(length(in_position - probe_data.camera_position.xyz));
                }
            ]],
			},
			rasterizer = {
				depth_clamp = false,
				discard = false,
				polygon_mode = "fill",
				line_width = 1.0,
				-- Inverted culling for cubemap rendering (faces are viewed from inside)
				cull_mode = "front",
				front_face = orientation.FRONT_FACE,
				depth_bias = 0,
			},
			dynamic_state = {
				"cull_mode",
			},
			depth_stencil = {
				depth_test = true,
				depth_write = true,
				depth_compare_op = "less",
			},
		}
	)
	-- Sky-only pipeline (for background where no geometry exists)
	reflection_probe.sky_pipeline = EasyPipeline.New(
		{
			color_format = {
				{"b10g11r11_ufloat_pack32", {"color", "rgba"}},
				{"r32_sfloat", {"linear_depth", "r"}},
			}, -- Color + depth
			samples = "1",
			color_blend = {
				attachments = {
					{blend = false, color_write_mask = {"r", "g", "b", "a"}},
					{blend = false, color_write_mask = {"r", "g", "b", "a"}},
				},
			},
			vertex = {
				push_constants = {
					{
						name = "vertex",
						block = {
							{
								"inv_projection_view",
								"mat4",
								function(constants)
									reflection_probe.inv_projection_view:CopyToFloatPointer(constants.inv_projection_view)
								end,
							},
						},
					},
				},
				custom_declarations = [[
                layout(location = 0) out vec3 out_direction;
            ]],
				shader = [[
                vec2 positions[3] = vec2[](
                    vec2(-1.0, -1.0),
                    vec2( 3.0, -1.0),
                    vec2(-1.0,  3.0)
                );
                void main() {
                    vec2 pos = positions[gl_VertexIndex];
                    gl_Position = vec4(pos, 1.0, 1.0);
                    vec4 world_pos = pc.vertex.inv_projection_view * vec4(pos, 1.0, 1.0);
                    out_direction = world_pos.xyz / world_pos.w;
                }
            ]],
			},
			fragment = {
				push_constants = {
					{
						name = "fragment",
						block = {
							{
								"stars_texture_index",
								"int",
								function(constants, pipeline)
									return pipeline:GetTextureIndex(skybox.stars_texture)
								end,
							},
							{
								"sun_direction",
								"vec4",
								function(constants)
									local lights = render3d.GetLights()

									if lights[1] then
										lights[1]:GetRotation():GetBackward():CopyToFloatPointer(constants.sun_direction)
									end
								end,
							},
							{
								"camera_position",
								"vec4",
								function(constants)
									reflection_probe.temp_camera:GetPosition():CopyToFloatPointer(constants.camera_position)
								end,
							},
						},
					},
				},
				custom_declarations = [[
                layout(location = 0) in vec3 in_direction;
                ]] .. skybox.GetGLSLCode() .. [[
            ]],
				shader = [[
                void main() {
                    vec3 sky_color_output;
                    ]] .. skybox.GetGLSLMainCode(
						"in_direction",
						"pc.fragment.sun_direction.xyz",
						"pc.fragment.camera_position.xyz",
						"pc.fragment.stars_texture_index"
					) .. [[
                    // Clamp sky to prevent infinities
                    sky_color_output = clamp(sky_color_output, vec3(0.0), vec3(65504.0));
                    set_color(vec4(sky_color_output, 1.0));
                    // Sky is at infinite distance, use a large value (camera far plane)
                    set_linear_depth(1000.0);
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
	)
	-- Prefilter pipeline (same as skybox prefilter)
	reflection_probe.prefilter_pipeline = EasyPipeline.New(
		{
			color_format = {{"b10g11r11_ufloat_pack32", {"color", "rgba"}}},
			samples = "1",
			vertex = {
				push_constants = {
					{
						name = "vertex",
						block = {
							{
								"inv_projection_view",
								"mat4",
								function(constants)
									reflection_probe.inv_projection_view:CopyToFloatPointer(constants.inv_projection_view)
								end,
							},
						},
					},
				},
				custom_declarations = [[
                layout(location = 0) out vec3 out_direction;
            ]],
				shader = [[
                vec2 positions[3] = vec2[](
                    vec2(-1.0, -1.0),
                    vec2( 3.0, -1.0),
                    vec2(-1.0,  3.0)
                );
                void main() {
                    vec2 pos = positions[gl_VertexIndex];
                    gl_Position = vec4(pos, 1.0, 1.0);
                    vec4 world_pos = pc.vertex.inv_projection_view * vec4(pos, 1.0, 1.0);
                    out_direction = world_pos.xyz / world_pos.w;
                }
            ]],
			},
			fragment = {
				push_constants = {
					{
						name = "fragment",
						block = {
							{
								"roughness",
								"float",
								function(constants)
									return reflection_probe.current_roughness or 0
								end,
							},
							{
								"input_texture_index",
								"int",
								function(constants, pipeline)
									local probe = reflection_probe.probes[reflection_probe.current_probe_index]
									return pipeline:GetTextureIndex(probe.source_cubemap)
								end,
							},
						},
					},
				},
				custom_declarations = [[
                layout(location = 0) in vec3 in_direction;

                const float PI = 3.14159265359;

                float D_GGX(float NoH, float roughness) {
                    float a = roughness * roughness;
                    float a2 = a * a;
                    float NoH2 = NoH * NoH;
                    float denom = (NoH2 * (a2 - 1.0) + 1.0);
                    return a2 / (PI * denom * denom);
                }

                float RadicalInverse_Vdc(uint bits) {
                    bits = (bits << 16u) | (bits >> 16u);
                    bits = ((bits & 0x55555555u) << 1u) | ((bits & 0xAAAAAAAAu) >> 1u);
                    bits = ((bits & 0x33333333u) << 2u) | ((bits & 0xCCCCCCCCu) >> 2u);
                    bits = ((bits & 0x0F0F0F0Fu) << 4u) | ((bits & 0xF0F0F0F0u) >> 4u);
                    bits = ((bits & 0x00FF00FFu) << 8u) | ((bits & 0xFF00FF00u) >> 8u);
                    return float(bits) * 2.3283064365386963e-10;
                }

                vec2 Hammersley(uint i, uint N) {
                    return vec2(float(i)/float(N), RadicalInverse_Vdc(i));
                }

                vec3 ImportanceSampleGGX(vec2 Xi, vec3 N, float roughness) {
                    float a = roughness*roughness;
                    float phi = 2.0 * PI * Xi.x;
                    float cosTheta = sqrt((1.0 - Xi.y) / (1.0 + (a*a - 1.0) * Xi.y));
                    float sinTheta = sqrt(1.0 - cosTheta*cosTheta);
                    
                    vec3 H;
                    H.x = cos(phi) * sinTheta;
                    H.y = sin(phi) * sinTheta;
                    H.z = cosTheta;
                    
                    vec3 up = abs(N.z) < 0.999 ? vec3(0.0, 0.0, 1.0) : vec3(1.0, 0.0, 0.0);
                    vec3 tangent = normalize(cross(up, N));
                    vec3 bitangent = cross(N, tangent);
                    
                    vec3 sampleVec = tangent * H.x + bitangent * H.y + N * H.z;
                    return normalize(sampleVec);
                }
            ]],
				shader = [[
                void main() {
                    vec3 N = normalize(in_direction);
                    vec3 R = N;
                    vec3 V = R;

                    const uint SAMPLE_COUNT = 512u;
                    float totalWeight = 0.0;
                    vec3 prefilteredColor = vec3(0.0);
                    float roughness = clamp(pc.fragment.roughness, 0.0, 1.0);

                    // For very low roughness (mirror-like), just sample the cubemap directly
                    if (roughness < 0.001) {
                        prefilteredColor = textureLod(CUBEMAP(pc.fragment.input_texture_index), N, 0.0).rgb;
                        set_color(vec4(prefilteredColor, 1.0));
                        return;
                    }

                    for(uint i = 0u; i < SAMPLE_COUNT; ++i) {
                        vec2 Xi = Hammersley(i, SAMPLE_COUNT);
                        vec3 H  = ImportanceSampleGGX(Xi, N, roughness);
                        vec3 L  = normalize(2.0 * dot(V, H) * H - V);

                        float NoL = max(dot(N, L), 0.0);
                        if(NoL > 0.0) {
                            float NoH = max(dot(N, H), 0.0);
                            float VoH = max(dot(V, H), 0.0001);
                            float D = D_GGX(NoH, roughness);
                            float pdf = max((D * NoH / (4.0 * VoH)), 0.0001);

                            float resolution = ]] .. tostring(reflection_probe.SIZE) .. [[.0;
                            float saSample = 1.0 / (float(SAMPLE_COUNT) * pdf);
                            float saTexel  = 4.0 * PI / (6.0 * resolution * resolution);

                            float mipBias = max(saSample / saTexel, 1.0);
                            float lod = clamp(0.5 * log2(mipBias), 0.0, 8.0);

                            vec3 sampledColor = textureLod(CUBEMAP(pc.fragment.input_texture_index), L, lod).rgb;
                            // Clamp to prevent infinities
                            sampledColor = min(sampledColor, vec3(65504.0));
                            
                            prefilteredColor += sampledColor * NoL;
                            totalWeight      += NoL;
                        }
                    }
                    
                    // Prevent division by zero
                    if (totalWeight > 0.0001) {
                        prefilteredColor /= totalWeight;
                    } else {
                        // Fallback: just sample the cubemap directly
                        prefilteredColor = textureLod(CUBEMAP(pc.fragment.input_texture_index), N, 0.0).rgb;
                    }
                    
                    // Final clamp to prevent NaN/Inf
                    prefilteredColor = clamp(prefilteredColor, vec3(0.0), vec3(65504.0));
                    set_color(vec4(prefilteredColor, 1.0));
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
	)
end

-- Projection-view-world matrix for probe rendering
local pvm_cached = Matrix44()

function reflection_probe.GetProjectionViewWorldMatrix()
	render3d.GetWorldMatrix():GetMultiplied(reflection_probe.temp_camera:BuildViewMatrix(), pvm_cached)
	pvm_cached:GetMultiplied(reflection_probe.temp_camera:BuildProjectionMatrix(), pvm_cached)
	return pvm_cached
end

function reflection_probe.UploadConstants(cmd)
	if reflection_probe.scene_pipeline then
		-- Inverted culling for cubemap rendering
		cmd:SetCullMode(render3d.GetMaterial():GetDoubleSided() and "none" or "front")
		reflection_probe.scene_pipeline:UploadConstants(cmd)
	end
end

-- Create depth buffer for probe rendering
function reflection_probe.GetOrCreateDepthBuffer()
	if not reflection_probe.depth_buffer then
		reflection_probe.depth_buffer = Texture.New(
			{
				width = reflection_probe.SIZE,
				height = reflection_probe.SIZE,
				format = "d32_sfloat",
				image = {
					usage = {"depth_stencil_attachment"},
					properties = "device_local",
				},
				view = {
					aspect = "depth",
				},
			}
		)
	end

	return reflection_probe.depth_buffer
end

-- Render one or more faces of the probe cubemap
function reflection_probe.RenderFaces(cmd, num_faces)
	if not reflection_probe.enabled then return end

	if not reflection_probe.scene_pipeline then return end

	num_faces = num_faces or reflection_probe.UPDATE_FACES_PER_FRAME
	local SIZE = reflection_probe.SIZE
	local probe = reflection_probe.probes[reflection_probe.current_probe_index]
	reflection_probe.temp_camera:SetPosition(probe.position)
	local depth_tex = reflection_probe.GetOrCreateDepthBuffer()

	for _ = 1, num_faces do
		local face_idx = reflection_probe.current_face
		-- Set camera rotation for this face
		reflection_probe.temp_camera:SetAngles(face_angles[face_idx + 1])
		-- Calculate inverse projection-view for sky rendering
		local proj = reflection_probe.temp_camera:BuildProjectionMatrix()
		local view = reflection_probe.temp_camera:BuildViewMatrix():Copy()
		view.m30, view.m31, view.m32 = 0, 0, 0
		local proj_view = view * proj
		proj_view:GetInverse(reflection_probe.inv_projection_view)
		-- Transition source face to color attachment
		cmd:PipelineBarrier(
			{
				srcStage = "fragment_shader",
				dstStage = "color_attachment_output",
				imageBarriers = {
					{
						image = probe.source_cubemap:GetImage(),
						oldLayout = "shader_read_only_optimal",
						newLayout = "color_attachment_optimal",
						srcAccessMask = "shader_read",
						dstAccessMask = "color_attachment_write",
						base_array_layer = face_idx,
						layer_count = 1,
						base_mip_level = 0,
						level_count = 1,
					},
				},
			}
		)
		-- Transition depth face to color attachment (stores linear depth as r32_sfloat)
		cmd:PipelineBarrier(
			{
				srcStage = "fragment_shader",
				dstStage = "color_attachment_output",
				imageBarriers = {
					{
						image = probe.depth_cubemap:GetImage(),
						oldLayout = "shader_read_only_optimal",
						newLayout = "color_attachment_optimal",
						srcAccessMask = "shader_read",
						dstAccessMask = "color_attachment_write",
						base_array_layer = face_idx,
						layer_count = 1,
						base_mip_level = 0,
						level_count = 1,
					},
				},
			}
		)
		-- Transition depth to depth attachment
		cmd:PipelineBarrier(
			{
				srcStage = "top_of_pipe",
				dstStage = {"early_fragment_tests", "late_fragment_tests"},
				imageBarriers = {
					{
						image = depth_tex:GetImage(),
						oldLayout = "undefined",
						newLayout = "depth_attachment_optimal",
						srcAccessMask = "none",
						dstAccessMask = "depth_stencil_attachment_write",
						aspect = "depth",
					},
				},
			}
		)
		-- First render sky background
		cmd:BeginRendering(
			{
				color_attachments = {
					{
						color_image_view = probe.source_face_views[face_idx],
						clear_color = {0, 0, 0, 1},
						load_op = "clear",
						store_op = "store",
					},
					{
						color_image_view = probe.depth_face_views[face_idx],
						clear_color = {1000, 0, 0, 0}, -- Clear to far distance
						load_op = "clear",
						store_op = "store",
					},
				},
				w = SIZE,
				h = SIZE,
			}
		)
		cmd:SetViewport(0, 0, SIZE, SIZE)
		cmd:SetScissor(0, 0, SIZE, SIZE)
		cmd:SetCullMode("none")
		reflection_probe.sky_pipeline:Bind(cmd, 1)
		reflection_probe.sky_pipeline:UploadConstants(cmd)
		cmd:Draw(3, 1, 0, 0)
		cmd:EndRendering()
		-- Now render scene geometry on top
		cmd:BeginRendering(
			{
				color_attachments = {
					{
						color_image_view = probe.source_face_views[face_idx],
						load_op = "load", -- Keep the sky
						store_op = "store",
					},
					{
						color_image_view = probe.depth_face_views[face_idx],
						load_op = "load", -- Keep sky depth
						store_op = "store",
					},
				},
				depth_image_view = depth_tex:GetView(),
				clear_depth = 1.0,
				depth_store = false,
				w = SIZE,
				h = SIZE,
			}
		)
		cmd:SetViewport(0, 0, SIZE, SIZE)
		cmd:SetScissor(0, 0, SIZE, SIZE)
		-- Bind scene pipeline and draw geometry
		reflection_probe.scene_pipeline:Bind(cmd, 1)
		event.Call("DrawProbeGeometry", cmd, reflection_probe)
		cmd:EndRendering()
		-- Transition source face to shader read
		cmd:PipelineBarrier(
			{
				srcStage = "color_attachment_output",
				dstStage = "fragment_shader",
				imageBarriers = {
					{
						image = probe.source_cubemap:GetImage(),
						oldLayout = "color_attachment_optimal",
						newLayout = "shader_read_only_optimal",
						srcAccessMask = "color_attachment_write",
						dstAccessMask = "shader_read",
						base_array_layer = face_idx,
						layer_count = 1,
						base_mip_level = 0,
						level_count = 1,
					},
				},
			}
		)
		-- Transition depth face to shader read
		cmd:PipelineBarrier(
			{
				srcStage = "color_attachment_output",
				dstStage = "fragment_shader",
				imageBarriers = {
					{
						image = probe.depth_cubemap:GetImage(),
						oldLayout = "color_attachment_optimal",
						newLayout = "shader_read_only_optimal",
						srcAccessMask = "color_attachment_write",
						dstAccessMask = "shader_read",
						base_array_layer = face_idx,
						layer_count = 1,
						base_mip_level = 0,
						level_count = 1,
					},
				},
			}
		)
		-- Advance to next face
		reflection_probe.current_face = (reflection_probe.current_face + 1) % 6
	end
end

-- Prefilter the source cubemap into the output cubemap with roughness mips
function reflection_probe.PrefilterCubemap(cmd)
	if not reflection_probe.prefilter_pipeline then return end

	local SIZE = reflection_probe.SIZE
	local probe = reflection_probe.probes[reflection_probe.current_probe_index]
	local num_mips = probe.cubemap.mip_map_levels
	-- First generate mipmaps for source cubemap
	probe.source_cubemap:GenerateMipmaps("shader_read_only_optimal", cmd)

	-- For each mip level, render prefiltered version
	for m = 0, num_mips - 1 do
		local perceptual_roughness = m / math.max(num_mips - 1, 1)
		reflection_probe.current_roughness = perceptual_roughness
		local mip_size = math.max(1, math.floor(SIZE / (2 ^ m)))

		for face = 0, 5 do
			-- Set camera for this face
			reflection_probe.temp_camera:SetAngles(face_angles[face + 1])
			local proj = reflection_probe.temp_camera:BuildProjectionMatrix()
			local view = reflection_probe.temp_camera:BuildViewMatrix():Copy()
			view.m30, view.m31, view.m32 = 0, 0, 0
			local proj_view = view * proj
			proj_view:GetInverse(reflection_probe.inv_projection_view)
			-- Transition output face/mip to color attachment
			cmd:PipelineBarrier(
				{
					srcStage = "fragment_shader",
					dstStage = "color_attachment_output",
					imageBarriers = {
						{
							image = probe.cubemap:GetImage(),
							oldLayout = "shader_read_only_optimal",
							newLayout = "color_attachment_optimal",
							srcAccessMask = "shader_read",
							dstAccessMask = "color_attachment_write",
							base_array_layer = face,
							layer_count = 1,
							base_mip_level = m,
							level_count = 1,
						},
					},
				}
			)
			cmd:BeginRendering(
				{
					color_image_view = probe.mip_face_views[m][face],
					w = mip_size,
					h = mip_size,
					clear_color = {0, 0, 0, 1},
				}
			)
			cmd:SetViewport(0, 0, mip_size, mip_size)
			cmd:SetScissor(0, 0, mip_size, mip_size)
			cmd:SetCullMode("none")
			reflection_probe.prefilter_pipeline:Bind(cmd, 1)
			reflection_probe.prefilter_pipeline:UploadConstants(cmd)
			cmd:Draw(3, 1, 0, 0)
			cmd:EndRendering()
			-- Transition to shader read
			cmd:PipelineBarrier(
				{
					srcStage = "color_attachment_output",
					dstStage = "fragment_shader",
					imageBarriers = {
						{
							image = probe.cubemap:GetImage(),
							oldLayout = "color_attachment_optimal",
							newLayout = "shader_read_only_optimal",
							srcAccessMask = "color_attachment_write",
							dstAccessMask = "shader_read",
							base_array_layer = face,
							layer_count = 1,
							base_mip_level = m,
							level_count = 1,
						},
					},
				}
			)
		end
	end
end

-- Full update: render all 6 faces then prefilter
function reflection_probe.FullUpdate(cmd)
	reflection_probe.RenderFaces(cmd, 6)
	reflection_probe.PrefilterCubemap(cmd)
end

-- Get the output cubemap texture (prefiltered, ready for use in lighting)
function reflection_probe.GetCubemap(index)
	local probe = reflection_probe.probes[index or 0]
	return probe and probe.cubemap
end

-- Get the raw source cubemap (before prefiltering)
function reflection_probe.GetSourceCubemap(index)
	local probe = reflection_probe.probes[index or 0]
	return probe and probe.source_cubemap
end

-- Get the depth cubemap
function reflection_probe.GetDepthCubemap(index)
	local probe = reflection_probe.probes[index or 0]
	return probe and probe.depth_cubemap
end

function reflection_probe.GetProbePosition(index)
	local probe = reflection_probe.probes[index or 0]
	return probe and probe.position
end

function reflection_probe.GetProbes()
	return reflection_probe.probes
end

function reflection_probe.SetEnabled(enabled)
	reflection_probe.enabled = enabled
end

function reflection_probe.IsEnabled()
	return reflection_probe.enabled
end

-- Event listeners for integration
event.AddListener("Render3DInitialized", "reflection_probe", function()
	reflection_probe.Initialize()
end)

-- Incremental update each frame
event.AddListener("PreRenderPass", "reflection_probe_update", function(cmd)
	if not reflection_probe.enabled then return end

	if not reflection_probe.scene_pipeline then return end

	-- Render one face per frame
	reflection_probe.RenderFaces(cmd, reflection_probe.UPDATE_FACES_PER_FRAME)

	-- When we complete a full cycle (back to face 0), prefilter
	if reflection_probe.current_face == 0 then
		reflection_probe.PrefilterCubemap(cmd)
		-- Move to next probe
		reflection_probe.current_probe_index = (reflection_probe.current_probe_index + 1) % reflection_probe.PROBE_COUNT
	end
end)

-- Initialize immediately if render3d is already initialized
if HOTRELOAD or (render3d and render3d.fill_pipeline) then
	reflection_probe.Initialize()
end

return reflection_probe
