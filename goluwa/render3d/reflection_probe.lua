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
local atmosphere = require("render3d.atmosphere")
local reflection_probe = {}
-- Probe types
reflection_probe.TYPE_ENVIRONMENT = "environment" -- Sky-only, dynamic, updated based on sun
reflection_probe.TYPE_SCENE = "scene" -- Renders geometry, typically static
-- Update modes
reflection_probe.UPDATE_DYNAMIC = "dynamic" -- Update every frame (or on sun change for environment)
reflection_probe.UPDATE_STATIC = "static" -- Update once on creation
reflection_probe.UPDATE_MANUAL = "manual" -- Update only when requested
-- Configuration
reflection_probe.ENVIRONMENT_SIZE = 512 -- Larger size for environment probe
reflection_probe.SCENE_SIZE = 128 -- Smaller size for scene probes
reflection_probe.UPDATE_FACES_PER_FRAME = 1 -- How many faces to update each frame
reflection_probe.GRID_COUNTS = Vec3(4, 4, 4)
reflection_probe.GRID_SPACING = Vec3(10, 10, 10)
reflection_probe.GRID_ORIGIN = Vec3(35, -1.5, 50)
reflection_probe.SCENE_PROBE_COUNT = reflection_probe.GRID_COUNTS.x * reflection_probe.GRID_COUNTS.y * reflection_probe.GRID_COUNTS.z
reflection_probe.enabled = true
-- State
reflection_probe.probes = {} -- All probes (environment at index 0, scene probes at 1+)
reflection_probe.environment_probe = nil -- Reference to the environment probe
reflection_probe.current_scene_probe_index = 1 -- Current scene probe being updated (1-based, skips environment)
reflection_probe.current_face = 0
reflection_probe.temp_camera = nil
reflection_probe.pipeline = nil
reflection_probe.prefilter_pipeline = nil
reflection_probe.inv_projection_view = Matrix44()
reflection_probe.last_sun_direction = nil -- For detecting sun changes
-- Face rotation angles for cubemap rendering
local face_angles = {
	Deg3(0, -90 + 180, 0), -- +X
	Deg3(0, 90 + 180, 0), -- -X
	Deg3(90, 0 + 180, 0), -- +Y
	Deg3(-90, 0 + 180, 0), -- -Y
	Deg3(0, 0 + 180, 0), -- +Z
	Deg3(0, 180 + 180, 0), -- -Z
}

-- Create a probe with given configuration
local function CreateProbeTextures(size)
	local probe = {}
	-- Create the output cubemap (prefiltered, used for rendering)
	probe.cubemap = Texture.New(
		{
			width = size,
			height = size,
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
			width = size,
			height = size,
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
	-- Create depth cubemap (linear depth for parallax correction) - only for scene probes
	probe.depth_cubemap = Texture.New(
		{
			width = size,
			height = size,
			format = "r32_sfloat",
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

	return probe
end

-- Create the environment probe (index 0)
function reflection_probe.CreateEnvironmentProbe(position)
	local probe = CreateProbeTextures(reflection_probe.ENVIRONMENT_SIZE)
	probe.type = reflection_probe.TYPE_ENVIRONMENT
	probe.update_mode = reflection_probe.UPDATE_DYNAMIC
	probe.position = position or Vec3(0, 0, 0)
	probe.size = reflection_probe.ENVIRONMENT_SIZE
	probe.needs_update = true
	reflection_probe.probes[0] = probe
	reflection_probe.environment_probe = probe
	return probe
end

-- Create a scene probe
function reflection_probe.CreateSceneProbe(position, update_mode)
	local probe = CreateProbeTextures(reflection_probe.SCENE_SIZE)
	probe.type = reflection_probe.TYPE_SCENE
	probe.update_mode = update_mode or reflection_probe.UPDATE_STATIC
	probe.position = position
	probe.size = reflection_probe.SCENE_SIZE
	probe.needs_update = true
	-- Find next available index (starting from 1)
	local index = 1

	while reflection_probe.probes[index] do
		index = index + 1
	end

	reflection_probe.probes[index] = probe
	return probe, index
end

function reflection_probe.Initialize()
	if reflection_probe.environment_probe then return end

	-- Create the environment probe first (index 0)
	reflection_probe.CreateEnvironmentProbe(Vec3(0, 0, 0))

	if false then
		-- Create scene probes in a grid
		for i = 0, reflection_probe.SCENE_PROBE_COUNT - 1 do
			local gx = i % reflection_probe.GRID_COUNTS.x
			local gy = math.floor(i / reflection_probe.GRID_COUNTS.x) % reflection_probe.GRID_COUNTS.y
			local gz = math.floor(i / (reflection_probe.GRID_COUNTS.x * reflection_probe.GRID_COUNTS.y))
			local position = reflection_probe.GRID_ORIGIN + Vec3(
					gx * reflection_probe.GRID_SPACING.x,
					gy * reflection_probe.GRID_SPACING.y,
					gz * reflection_probe.GRID_SPACING.z
				)
			reflection_probe.CreateSceneProbe(position, reflection_probe.UPDATE_STATIC)
		end
	end

	-- Create camera for probe rendering
	reflection_probe.temp_camera = Camera3D.New()
	reflection_probe.temp_camera:SetFOV(math.rad(90))
	reflection_probe.temp_camera:SetViewport(Rect(0, 0, reflection_probe.ENVIRONMENT_SIZE, reflection_probe.ENVIRONMENT_SIZE))
	reflection_probe.temp_camera:SetNearZ(0.1)
	reflection_probe.temp_camera:SetFarZ(1000)
	-- Create pipelines
	reflection_probe.CreatePipelines()
	-- Create fence for synchronization
	reflection_probe.fence = Fence.New(render.GetDevice())
	-- Initialize cubemap layouts
	reflection_probe.InitializeCubemapLayouts()
	-- Set the environment texture in render3d
	render3d.SetEnvironmentTexture(reflection_probe.environment_probe.cubemap)
end

-- Initialize all cubemap faces to shader_read_only_optimal layout
function reflection_probe.InitializeCubemapLayouts()
	local cmd = render.GetCommandPool():AllocateCommandBuffer()
	cmd:Begin()

	for index, probe in pairs(reflection_probe.probes) do
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
	local Material = require("render3d.material")
	local Light = require("components.light")
	-- Pipeline to render the scene into a cubemap face
	reflection_probe.scene_pipeline = EasyPipeline.New(
		{
			color_format = {
				{"b10g11r11_ufloat_pack32", {"color", "rgba"}},
				{"r32_sfloat", {"linear_depth", "r"}},
			},
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
									reflection_probe.GetProjectionViewWorldMatrix():CopyToFloatPointer(block[key])
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
                    out_uv = in_uv;
                    out_tangent = vec4(normalize(mat3(pc.vertex.world) * in_tangent.xyz), in_tangent.w);
                    out_texture_blend = in_texture_blend;
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
            ]],
				uniform_buffers = {
					{
						name = "probe_data",
						binding_index = 3,
						block = {
							{
								"camera_position",
								"vec4",
								function(self, block, key)
									local p = reflection_probe.temp_camera:GetPosition()
									block[key][0] = p.x
									block[key][1] = p.y
									block[key][2] = p.z
									block[key][3] = 0
								end,
							},
							{
								"stars_texture_index",
								"int",
								function(self, block, key)
									block[key] = self:GetTextureIndex(atmosphere.GetStarsTexture())
								end,
							},
							{
								"sun_direction",
								"vec4",
								function(self, block, key)
									local lights = render3d.GetLights()

									if lights[1] then
										lights[1].transform:GetRotation():GetBackward():CopyToFloatPointer(block[key])
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
								function(self, block, key)
									block[key] = render3d.GetMaterial():GetFillFlags()
								end,
							},
							{
								"AlbedoTexture",
								"int",
								function(self, block, key)
									block[key] = self:GetTextureIndex(render3d.GetMaterial():GetAlbedoTexture())
								end,
							},
							{
								"Albedo2Texture",
								"int",
								function(self, block, key)
									block[key] = self:GetTextureIndex(render3d.GetMaterial():GetAlbedo2Texture())
								end,
							},
							{
								"NormalTexture",
								"int",
								function(self, block, key)
									block[key] = self:GetTextureIndex(render3d.GetMaterial():GetNormalTexture())
								end,
							},
							{
								"Normal2Texture",
								"int",
								function(self, block, key)
									block[key] = self:GetTextureIndex(render3d.GetMaterial():GetNormal2Texture())
								end,
							},
							{
								"BlendTexture",
								"int",
								function(self, block, key)
									block[key] = self:GetTextureIndex(render3d.GetMaterial():GetBlendTexture())
								end,
							},
							{
								"MetallicRoughnessTexture",
								"int",
								function(self, block, key)
									block[key] = self:GetTextureIndex(render3d.GetMaterial():GetMetallicRoughnessTexture())
								end,
							},
							{
								"EmissiveTexture",
								"int",
								function(self, block, key)
									block[key] = self:GetTextureIndex(render3d.GetMaterial():GetEmissiveTexture())
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
								"EmissiveMultiplier",
								"vec4",
								function(self, block, key)
									render3d.GetMaterial():GetEmissiveMultiplier():CopyToFloatPointer(block[key])
								end,
							},
						},
					},
				},
				shader = [[
                ]] .. Material.BuildGlslFlags("pc.model.Flags") .. [[
                ]] .. atmosphere.GetGLSLCode() .. [[
                
                #define PI 3.14159265359
                #define saturate(x) clamp(x, 0.0, 1.0)
                
                float g_blend = -1.0;
                float get_blend() {
                    if (g_blend != -1.0) return g_blend;
                    
                    float blend = in_texture_blend;
                    if (pc.model.BlendTexture != -1) {
                        vec2 blend_data = texture(TEXTURE(pc.model.BlendTexture), in_uv).rg;
                        float b = blend_data.g;
                        float blend_power = blend_data.r;
                        
                        if (blend != 0) {
                            blend = mix(blend, b, 0.5);
                        } else {
                            blend = b;
                        }

                        if (blend != 0 && blend_power != 0) {
                            blend = pow(blend, blend_power);
                        }
                    }
                    g_blend = blend;
                    return g_blend;
                }

                vec4 get_albedo_vec4() {
                    vec4 albedo = vec4(1.0);
                    if (pc.model.AlbedoTexture != -1) {
                        albedo = texture(TEXTURE(pc.model.AlbedoTexture), in_uv);
                    }
                    
                    float blend = get_blend();
                    if (blend > 0.0 && pc.model.Albedo2Texture != -1) {
                        vec4 albedo2 = texture(TEXTURE(pc.model.Albedo2Texture), in_uv);
                        albedo = mix(albedo, albedo2, blend);
                    }

                    if (BlendTintByBaseAlpha) {
                        albedo.rgb = mix(albedo.rgb, albedo.rgb * pc.model.ColorMultiplier.rgb, albedo.a);
                        albedo.a *= pc.model.ColorMultiplier.a;
                    } else {
                        albedo *= pc.model.ColorMultiplier;
                    }

                    return albedo;
                }

                vec3 get_albedo() {
                    return get_albedo_vec4().rgb;
                }
                
                float get_alpha() {
                    if (
                        AlbedoTextureAlphaIsRoughness ||
                        NormalTextureAlphaIsRoughness ||
                        AlbedoAlphaIsEmissive
                    ) {
                        return pc.model.ColorMultiplier.a;	
                    }

                    return get_albedo_vec4().a;
                }
                
                vec3 get_normal() {
                    vec3 tangent_normal = vec3(0, 0, 1);
                    if (pc.model.NormalTexture != -1) {
                        tangent_normal = texture(TEXTURE(pc.model.NormalTexture), in_uv).xyz * 2.0 - 1.0;
                    }

                    float blend = get_blend();
                    if (blend > 0.0 && pc.model.Normal2Texture != -1) {
                        vec3 tangent_normal2 = texture(TEXTURE(pc.model.Normal2Texture), in_uv).xyz * 2.0 - 1.0;
                        tangent_normal = mix(tangent_normal, tangent_normal2, blend);
                    }
                    
                    vec3 normal = normalize(in_normal);
                    vec3 tangent = normalize(in_tangent.xyz);
                    vec3 bitangent = cross(normal, tangent) * in_tangent.w;
                    mat3 TBN = mat3(tangent, bitangent, normal);

                    vec3 N = TBN * tangent_normal;

                    if (DoubleSided && gl_FrontFacing) {
                        N = -N;
                    }

                    return normalize(N);
                }
                
                float get_metallic() {
                    float val = pc.model.MetallicMultiplier;
                    if (pc.model.MetallicRoughnessTexture != -1) {
                        val = texture(TEXTURE(pc.model.MetallicRoughnessTexture), in_uv).b * pc.model.MetallicMultiplier;
                    }
                    return clamp(val, 0, 1);
                }
                
                float get_roughness() {
                    float val = pc.model.RoughnessMultiplier;

                    if (AlbedoTextureAlphaIsRoughness) {
                        val = get_albedo_vec4().a;
                    } else if (NormalTextureAlphaIsRoughness) {
                        float a1 = 1.0;
                        if (pc.model.NormalTexture != -1) a1 = texture(TEXTURE(pc.model.NormalTexture), in_uv).a;
                        
                        val = a1;
                        float blend = get_blend();
                        if (blend > 0.0 && pc.model.Normal2Texture != -1) {
                            float a2 = texture(TEXTURE(pc.model.Normal2Texture), in_uv).a;
                            val = mix(a1, a2, blend);
                        }
                        val = -val + 1.0;
                    } else if (AlbedoLuminanceIsRoughness) {
                        val = dot(get_albedo(), vec3(0.2126, 0.7152, 0.0722));
                    } else if (pc.model.MetallicRoughnessTexture != -1) {
                        val = texture(TEXTURE(pc.model.MetallicRoughnessTexture), in_uv).g * pc.model.RoughnessMultiplier;
                    }

                    if (InvertRoughnessTexture) val = -val + 1.0;

                    return clamp(val, 0.05, 0.95);
                }
                
                vec3 get_emissive() {
                    if (AlbedoAlphaIsEmissive) {
                        float mask = get_albedo_vec4().a;
                        return get_albedo() * mask * pc.model.EmissiveMultiplier.rgb * pc.model.EmissiveMultiplier.a;
                    } else if (pc.model.EmissiveTexture != -1) {
                        vec3 emissive = texture(TEXTURE(pc.model.EmissiveTexture), in_uv).rgb;
                        return emissive * pc.model.EmissiveMultiplier.rgb * pc.model.EmissiveMultiplier.a;
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
                    
        
                    // Basic diffuse + ambient
                    vec3 diffuse = albedo  ;
                    vec3 ambient = albedo * 0.1;
                    
                    vec3 color = diffuse + ambient + emissive;
                    
                    // Check if this is sky (depth == 1.0 equivalent - we use a flag or check normal)
                    if (get_alpha() < 0.01) {
                        // Render sky
                        vec3 sky_color_output;
                        vec3 dir = normalize(in_position - probe_data.camera_position.xyz);
                        vec3 sunDir = normalize(probe_data.sun_direction.xyz);
                        ]] .. atmosphere.GetGLSLMainCode(
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
	-- Sky-only pipeline (for environment probe and scene probe backgrounds)
	reflection_probe.sky_pipeline = EasyPipeline.New(
		{
			color_format = {
				{"b10g11r11_ufloat_pack32", {"color", "rgba"}},
				{"r32_sfloat", {"linear_depth", "r"}},
			},
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
								function(self, block, key)
									reflection_probe.inv_projection_view:CopyToFloatPointer(block[key])
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
								function(self, block, key)
									block[key] = self:GetTextureIndex(atmosphere.GetStarsTexture())
								end,
							},
							{
								"sun_direction",
								"vec4",
								function(self, block, key)
									local lights = render3d.GetLights()

									if lights[1] then
										lights[1].transform:GetRotation():GetBackward():CopyToFloatPointer(block[key])
									end
								end,
							},
							{
								"camera_position",
								"vec4",
								function(self, block, key)
									reflection_probe.temp_camera:GetPosition():CopyToFloatPointer(block[key])
								end,
							},
						},
					},
				},
				custom_declarations = [[
                layout(location = 0) in vec3 in_direction;
                ]] .. atmosphere.GetGLSLCode() .. [[
            ]],
				shader = [[
                void main() {
                    vec3 sky_color_output;
                    ]] .. atmosphere.GetGLSLMainCode(
						"in_direction",
						"pc.fragment.sun_direction.xyz",
						"pc.fragment.camera_position.xyz",
						"pc.fragment.stars_texture_index"
					) .. [[
                    // Clamp sky to prevent infinities
                    sky_color_output = clamp(sky_color_output, vec3(0.0), vec3(65504.0));
                    set_color(vec4(sky_color_output, 1.0));
                    // Sky is at infinite distance
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
	-- Prefilter pipeline for IBL
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
								function(self, block, key)
									reflection_probe.inv_projection_view:CopyToFloatPointer(block[key])
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
								function(self, block, key)
									block[key] = reflection_probe.current_roughness or 0
								end,
							},
							{
								"input_texture_index",
								"int",
								function(self, block, key)
									local probe = reflection_probe.current_prefilter_probe
									block[key] = self:GetTextureIndex(probe.source_cubemap)
								end,
							},
							{
								"resolution",
								"float",
								function(self, block, key)
									local probe = reflection_probe.current_prefilter_probe
									block[key] = probe.size
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

                            float resolution = pc.fragment.resolution;
                            float saSample = 1.0 / (float(SAMPLE_COUNT) * pdf);
                            float saTexel  = 4.0 * PI / (6.0 * resolution * resolution);

                            float mipBias = max(saSample / saTexel, 1.0);
                            float lod = clamp(0.5 * log2(mipBias), 0.0, 8.0);

                            vec3 sampledColor = textureLod(CUBEMAP(pc.fragment.input_texture_index), L, lod).rgb;
                            sampledColor = min(sampledColor, vec3(65504.0));
                            
                            prefilteredColor += sampledColor * NoL;
                            totalWeight      += NoL;
                        }
                    }
                    
                    if (totalWeight > 0.0001) {
                        prefilteredColor /= totalWeight;
                    } else {
                        prefilteredColor = textureLod(CUBEMAP(pc.fragment.input_texture_index), N, 0.0).rgb;
                    }
                    
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
		cmd:SetCullMode(render3d.GetMaterial():GetDoubleSided() and "none" or "front")
		reflection_probe.scene_pipeline:UploadConstants(cmd)
	end
end

-- Create depth buffer for probe rendering
function reflection_probe.GetOrCreateDepthBuffer(size)
	if not reflection_probe.depth_buffers then
		reflection_probe.depth_buffers = {}
	end

	if not reflection_probe.depth_buffers[size] then
		reflection_probe.depth_buffers[size] = Texture.New(
			{
				width = size,
				height = size,
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

	return reflection_probe.depth_buffers[size]
end

-- Check if sun direction has changed significantly
function reflection_probe.HasSunDirectionChanged()
	local lights = render3d.GetLights()

	if not lights[1] then return false end

	local current_sun_dir = lights[1].transform:GetRotation():GetBackward()

	if not reflection_probe.last_sun_direction then
		reflection_probe.last_sun_direction = current_sun_dir:Copy()
		return true
	end

	local diff = (current_sun_dir - reflection_probe.last_sun_direction):GetLength()

	if diff > 0.001 then
		reflection_probe.last_sun_direction = current_sun_dir:Copy()
		return true
	end

	return false
end

-- Render faces for a specific probe
function reflection_probe.RenderProbeFaces(cmd, probe, num_faces, render_geometry)
	if not reflection_probe.enabled then return end

	if not reflection_probe.sky_pipeline then return end

	num_faces = num_faces or 1
	local SIZE = probe.size
	reflection_probe.temp_camera:SetPosition(probe.position)
	reflection_probe.temp_camera:SetViewport(Rect(0, 0, SIZE, SIZE))
	local depth_tex = reflection_probe.GetOrCreateDepthBuffer(SIZE)

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
		-- Transition depth face to color attachment
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
						clear_color = {1000, 0, 0, 0},
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

		-- Render scene geometry if requested (for scene probes)
		if render_geometry and reflection_probe.scene_pipeline then
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
			cmd:BeginRendering(
				{
					color_attachments = {
						{
							color_image_view = probe.source_face_views[face_idx],
							load_op = "load",
							store_op = "store",
						},
						{
							color_image_view = probe.depth_face_views[face_idx],
							load_op = "load",
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
			reflection_probe.scene_pipeline:Bind(cmd, 1)
			event.Call("DrawProbeGeometry", cmd, reflection_probe)
			cmd:EndRendering()
		end

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
		reflection_probe.current_face = (reflection_probe.current_face + 1) % 6
	end
end

-- Prefilter the source cubemap into the output cubemap with roughness mips
function reflection_probe.PrefilterProbe(cmd, probe)
	if not reflection_probe.prefilter_pipeline then return end

	local SIZE = probe.size
	local num_mips = probe.cubemap.mip_map_levels
	-- Set current probe for prefiltering
	reflection_probe.current_prefilter_probe = probe
	-- Generate mipmaps for source cubemap
	probe.source_cubemap:GenerateMipmaps("shader_read_only_optimal", cmd)

	-- For each mip level, render prefiltered version
	for m = 0, num_mips - 1 do
		local perceptual_roughness = m / math.max(num_mips - 1, 1)
		reflection_probe.current_roughness = perceptual_roughness
		local mip_size = math.max(1, math.floor(SIZE / (2 ^ m)))

		for face = 0, 5 do
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

-- Update the environment probe (called every frame if sun changed)
function reflection_probe.UpdateEnvironmentProbe(cmd)
	if not reflection_probe.environment_probe then return end

	local env_probe = reflection_probe.environment_probe

	-- Only update if sun direction changed
	if not reflection_probe.HasSunDirectionChanged() and not env_probe.needs_update then
		return
	end

	-- Save current face and render all 6 faces for environment
	local saved_face = reflection_probe.current_face
	reflection_probe.current_face = 0
	-- Environment probe only renders sky (no geometry)
	reflection_probe.RenderProbeFaces(cmd, env_probe, 6, false)
	-- Prefilter the environment probe
	reflection_probe.PrefilterProbe(cmd, env_probe)
	reflection_probe.current_face = saved_face
	env_probe.needs_update = false
end

-- Get the output cubemap texture (prefiltered)
function reflection_probe.GetCubemap(index)
	local probe = reflection_probe.probes[index or 0]
	return probe and probe.cubemap
end

-- Get the environment cubemap specifically
function reflection_probe.GetEnvironmentCubemap()
	return reflection_probe.environment_probe and reflection_probe.environment_probe.cubemap
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

-- Compatibility with old skybox API
function reflection_probe.SetStarsTexture(texture)
	atmosphere.SetStarsTexture(texture)
end

function reflection_probe.GetStarsTexture()
	return atmosphere.GetStarsTexture()
end

-- Event listeners for integration
event.AddListener("Render3DInitialized", "reflection_probe", function()
	reflection_probe.Initialize()
end)

-- Incremental update each frame
event.AddListener("PreRenderPass", "reflection_probe_update", function(cmd)
	if not reflection_probe.enabled then return end

	if not reflection_probe.sky_pipeline then return end

	-- Update environment probe first (if sun changed)
	reflection_probe.UpdateEnvironmentProbe(cmd)
	-- Then update scene probes incrementally
	local scene_probe_index = reflection_probe.current_scene_probe_index
	local scene_probe = reflection_probe.probes[scene_probe_index]

	if scene_probe and scene_probe.type == reflection_probe.TYPE_SCENE then
		-- Only update if the probe needs it (static probes only update once)
		if
			scene_probe.needs_update or
			scene_probe.update_mode == reflection_probe.UPDATE_DYNAMIC
		then
			reflection_probe.RenderProbeFaces(cmd, scene_probe, reflection_probe.UPDATE_FACES_PER_FRAME, true)

			-- When we complete a full cycle (back to face 0), prefilter and move to next probe
			if reflection_probe.current_face == 0 then
				reflection_probe.PrefilterProbe(cmd, scene_probe)
				scene_probe.needs_update = false

				-- Move to next scene probe
				repeat
					scene_probe_index = scene_probe_index + 1

					if scene_probe_index > reflection_probe.SCENE_PROBE_COUNT then
						scene_probe_index = 1
					end				
				until reflection_probe.probes[scene_probe_index] or scene_probe_index == reflection_probe.current_scene_probe_index

				reflection_probe.current_scene_probe_index = scene_probe_index
			end
		end
	end
end)

-- Initialize immediately if render3d is already initialized
if HOTRELOAD or (render3d and render3d.pipelines and render3d.pipelines.gbuffer) then
	reflection_probe.Initialize()
end

return reflection_probe
