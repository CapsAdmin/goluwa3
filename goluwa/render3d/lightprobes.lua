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
local system = require("system")
local atmosphere = require("render3d.atmosphere")
local lightprobes = {}
-- Probe types
lightprobes.TYPE_ENVIRONMENT = "environment" -- Sky-only, dynamic, updated based on sun
lightprobes.TYPE_SCENE = "scene" -- Renders geometry, typically static
-- Update modes
lightprobes.UPDATE_DYNAMIC = "dynamic" -- Update every frame (or on sun change for environment)
lightprobes.UPDATE_STATIC = "static" -- Update once on creation
lightprobes.UPDATE_MANUAL = "manual" -- Update only when requested
-- Configuration
lightprobes.ENVIRONMENT_SIZE = 512 -- Larger size for environment probe
lightprobes.SCENE_SIZE = 128 -- Smaller size for scene probes
lightprobes.UPDATE_FACES_PER_FRAME = 1 -- How many faces to update each frame
lightprobes.enabled = true
-- State
lightprobes.probes = lightprobes.probes or {}
lightprobes.current_scene_probe_index = 1 -- Current scene probe being updated (1-based, skips environment)
lightprobes.current_face = 0
lightprobes.camera = nil
lightprobes.pipeline = nil
lightprobes.prefilter_pipeline = nil
lightprobes.inv_projection_view = Matrix44()
lightprobes.last_sun_direction = nil -- For detecting sun changes
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
function lightprobes.CreateEnvironmentProbe(position)
	local probe = CreateProbeTextures(lightprobes.ENVIRONMENT_SIZE)
	probe.type = lightprobes.TYPE_ENVIRONMENT
	probe.update_mode = lightprobes.UPDATE_DYNAMIC
	probe.position = position or Vec3(0, 0, 0)
	probe.size = lightprobes.ENVIRONMENT_SIZE
	probe.needs_update = true
	probe.last_rendered = 0
	lightprobes.environment_probe = probe
	return probe
end

-- Create a scene probe
function lightprobes.CreateSceneProbe(position, update_mode, radius)
	local probe = CreateProbeTextures(lightprobes.SCENE_SIZE)
	probe.type = lightprobes.TYPE_SCENE
	probe.update_mode = update_mode or lightprobes.UPDATE_DYNAMIC
	probe.position = position
	probe.radius = radius or 40
	probe.size = lightprobes.SCENE_SIZE
	probe.needs_update = true
	probe.last_rendered = 0
	table.insert(lightprobes.probes, probe)
	return probe
end

function lightprobes.Initialize()
	lightprobes.CreatePipelines()
	lightprobes.fence = Fence.New(render.GetDevice())
	lightprobes.InitializeCubemapLayouts()

	do
		lightprobes.CreateEnvironmentProbe(Vec3(0, 0, 0))
		lightprobes.camera = Camera3D.New()
		lightprobes.camera:SetFOV(math.rad(90))
		lightprobes.camera:SetViewport(Rect(0, 0, lightprobes.ENVIRONMENT_SIZE, lightprobes.ENVIRONMENT_SIZE))
		lightprobes.camera:SetNearZ(0.1)
		lightprobes.camera:SetFarZ(1000)
		render3d.SetEnvironmentTexture(lightprobes.environment_probe.cubemap)
	end
end

event.AddListener("SpawnProbe", "lightprobes", function(position) --lightprobes.CreateSceneProbe(position)
end)

-- Initialize all cubemap faces to shader_read_only_optimal layout
function lightprobes.InitializeCubemapLayouts()
	local cmd = render.GetCommandPool():AllocateCommandBuffer()
	cmd:Begin()

	for index, probe in pairs(lightprobes.probes) do
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
	render.GetQueue():SubmitAndWait(render.GetDevice(), cmd, lightprobes.fence)
	cmd:Remove()
end

function lightprobes.CreatePipelines()
	local EasyPipeline = require("render.easy_pipeline")
	local orientation = require("render3d.orientation")
	local Material = require("render3d.material")
	local Light = require("ecs.components.3d.light")
	-- Pipeline to render the scene into a cubemap face
	lightprobes.scene_pipeline = EasyPipeline.New(
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
									lightprobes.GetProjectionViewWorldMatrix():CopyToFloatPointer(block[key])
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
									local p = lightprobes.camera:GetPosition()
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
										lights[1].Owner.transform:GetRotation():GetBackward():CopyToFloatPointer(block[key])
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
              
                void main() {
					vec3 albedo = vec3(1,0,0);
					if (pc.model.AlbedoTexture != -1) {
                        albedo = texture(TEXTURE(pc.model.AlbedoTexture), in_uv).rgb;
                    }
                    
                    set_color(vec4(albedo, 1.0));
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
	lightprobes.sky_pipeline = EasyPipeline.New(
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
									lightprobes.inv_projection_view:CopyToFloatPointer(block[key])
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
										lights[1].Owner.transform:GetRotation():GetBackward():CopyToFloatPointer(block[key])
									end
								end,
							},
							{
								"camera_position",
								"vec4",
								function(self, block, key)
									lightprobes.camera:GetPosition():CopyToFloatPointer(block[key])
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
	lightprobes.prefilter_pipeline = EasyPipeline.New(
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
									lightprobes.inv_projection_view:CopyToFloatPointer(block[key])
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
									block[key] = lightprobes.current_roughness or 0
								end,
							},
							{
								"input_texture_index",
								"int",
								function(self, block, key)
									local probe = lightprobes.current_prefilter_probe
									block[key] = self:GetTextureIndex(probe.source_cubemap)
								end,
							},
							{
								"resolution",
								"float",
								function(self, block, key)
									local probe = lightprobes.current_prefilter_probe
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

function lightprobes.GetProjectionViewWorldMatrix()
	render3d.GetWorldMatrix():GetMultiplied(lightprobes.camera:BuildViewMatrix(), pvm_cached)
	pvm_cached:GetMultiplied(lightprobes.camera:BuildProjectionMatrix(), pvm_cached)
	return pvm_cached
end

function lightprobes.UploadConstants(cmd)
	if lightprobes.scene_pipeline then
		cmd:SetCullMode(render3d.GetMaterial():GetDoubleSided() and "none" or "front")
		lightprobes.scene_pipeline:UploadConstants(cmd)
	end
end

-- Create depth buffer for probe rendering
function lightprobes.GetOrCreateDepthBuffer(size)
	if not lightprobes.depth_buffers then lightprobes.depth_buffers = {} end

	if not lightprobes.depth_buffers[size] then
		lightprobes.depth_buffers[size] = Texture.New(
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

	return lightprobes.depth_buffers[size]
end

-- Check if sun direction has changed significantly
function lightprobes.HasSunDirectionChanged()
	local lights = render3d.GetLights()

	if not lights[1] then return false end

	local current_sun_dir = lights[1].Owner.transform:GetRotation():GetBackward()

	if not lightprobes.last_sun_direction then
		lightprobes.last_sun_direction = current_sun_dir:Copy()
		return true
	end

	local diff = (current_sun_dir - lightprobes.last_sun_direction):GetLength()

	if diff > 0.001 then
		lightprobes.last_sun_direction = current_sun_dir:Copy()
		return true
	end

	return false
end

-- Render faces for a specific probe
function lightprobes.RenderProbeFaces(cmd, probe, num_faces, render_geometry)
	if not lightprobes.enabled then return end

	if not lightprobes.sky_pipeline then return end

	num_faces = num_faces or 1
	local SIZE = probe.size
	lightprobes.camera:SetPosition(probe.position)
	lightprobes.camera:SetViewport(Rect(0, 0, SIZE, SIZE))
	local depth_tex = lightprobes.GetOrCreateDepthBuffer(SIZE)

	for _ = 1, num_faces do
		local face_idx = lightprobes.current_face
		-- Set camera rotation for this face
		lightprobes.camera:SetAngles(face_angles[face_idx + 1])
		-- Calculate inverse projection-view for sky rendering
		local proj = lightprobes.camera:BuildProjectionMatrix()
		local view = lightprobes.camera:BuildViewMatrix():Copy()
		view.m30, view.m31, view.m32 = 0, 0, 0
		local proj_view = view * proj
		proj_view:GetInverse(lightprobes.inv_projection_view)
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
		lightprobes.sky_pipeline:Bind(cmd, 1)
		lightprobes.sky_pipeline:UploadConstants(cmd)
		cmd:Draw(3, 1, 0, 0)
		cmd:EndRendering()

		-- Render scene geometry if requested (for scene probes)
		if render_geometry and lightprobes.scene_pipeline then
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
						-- aspect is automatically determined from image format by PipelineBarrier
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
			lightprobes.scene_pipeline:Bind(cmd, 1)
			event.Call("DrawProbeGeometry", cmd, lightprobes)
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
		lightprobes.current_face = (lightprobes.current_face + 1) % 6
	end
end

-- Prefilter the source cubemap into the output cubemap with roughness mips
function lightprobes.PrefilterProbe(cmd, probe)
	if not lightprobes.prefilter_pipeline then return end

	local SIZE = probe.size
	local num_mips = probe.cubemap.mip_map_levels
	-- Set current probe for prefiltering
	lightprobes.current_prefilter_probe = probe
	-- Generate mipmaps for source cubemap
	probe.source_cubemap:GenerateMipmaps("shader_read_only_optimal", cmd)

	-- For each mip level, render prefiltered version
	for m = 0, num_mips - 1 do
		local perceptual_roughness = m / math.max(num_mips - 1, 1)
		lightprobes.current_roughness = perceptual_roughness
		local mip_size = math.max(1, math.floor(SIZE / (2 ^ m)))

		for face = 0, 5 do
			lightprobes.camera:SetAngles(face_angles[face + 1])
			local proj = lightprobes.camera:BuildProjectionMatrix()
			local view = lightprobes.camera:BuildViewMatrix():Copy()
			view.m30, view.m31, view.m32 = 0, 0, 0
			local proj_view = view * proj
			proj_view:GetInverse(lightprobes.inv_projection_view)
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
			lightprobes.prefilter_pipeline:Bind(cmd, 1)
			lightprobes.prefilter_pipeline:UploadConstants(cmd)
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
function lightprobes.UpdateEnvironmentProbe(cmd)
	if not lightprobes.environment_probe then return end

	local env_probe = lightprobes.environment_probe

	if not lightprobes.HasSunDirectionChanged() and not env_probe.needs_update then
		return
	end

	-- Save current face and render all 6 faces for environment
	local saved_face = lightprobes.current_face
	lightprobes.current_face = 0
	-- Environment probe only renders sky (no geometry)
	lightprobes.RenderProbeFaces(cmd, env_probe, 6, false)
	-- Prefilter the environment probe
	lightprobes.PrefilterProbe(cmd, env_probe)
	lightprobes.current_face = saved_face
	env_probe.needs_update = false
end

function lightprobes.GetProbes()
	return lightprobes.probes
end

function lightprobes.SetEnabled(enabled)
	lightprobes.enabled = enabled
end

function lightprobes.IsEnabled()
	return lightprobes.enabled
end

-- Compatibility with old skybox API
function lightprobes.SetStarsTexture(texture)
	atmosphere.SetStarsTexture(texture)
end

function lightprobes.GetStarsTexture()
	return atmosphere.GetStarsTexture()
end

event.AddListener("Render3DInitialized", "lightprobes", function()
	lightprobes.Initialize()
end)

event.AddListener("PreRenderPass", "lightprobes_update", function(cmd)
	if not lightprobes.enabled then return end

	if not lightprobes.sky_pipeline then return end

	lightprobes.UpdateEnvironmentProbe(cmd)
	local scene_probe_index = lightprobes.current_scene_probe_index
	local scene_probe = lightprobes.probes[scene_probe_index]

	if scene_probe and scene_probe.type == lightprobes.TYPE_SCENE then
		-- Only update if the probe needs it (static probes only update once)
		if
			scene_probe.needs_update or
			scene_probe.update_mode == lightprobes.UPDATE_DYNAMIC
		then
			local t = system.GetTime()

			if (t - scene_probe.last_rendered) > 1 / 10 then
				lightprobes.RenderProbeFaces(cmd, scene_probe, lightprobes.UPDATE_FACES_PER_FRAME, true)

				-- When we complete a full cycle (back to face 0), prefilter and move to next probe
				if lightprobes.current_face == 0 then
					lightprobes.PrefilterProbe(cmd, scene_probe)
					scene_probe.needs_update = false

					-- Move to next scene probe
					repeat
						scene_probe_index = scene_probe_index + 1

						if scene_probe_index > #lightprobes.probes then
							scene_probe_index = 1
						end					
					until lightprobes.probes[scene_probe_index] or scene_probe_index == lightprobes.current_scene_probe_index

					lightprobes.current_scene_probe_index = scene_probe_index
				end

				scene_probe.last_rendered = t
			end
		end
	end
end)

-- Initialize immediately if render3d is already initialized
if HOTRELOAD or (render3d and render3d.pipelines and render3d.pipelines.gbuffer) then
	lightprobes.Initialize()
end

return lightprobes
