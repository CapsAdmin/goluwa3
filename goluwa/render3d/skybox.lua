local event = require("event")
local ffi = require("ffi")
local orientation = require("render3d.orientation")
local Matrix44 = require("structs.matrix44")
local render = require("render.render")
local render3d = require("render3d.render3d")
local EasyPipeline = require("render.easy_pipeline")
local skybox = library()
local Texture = require("render.texture")
local Fence = require("render.vulkan.internal.fence")
skybox.inv_projection_view = Matrix44()

function skybox.Initialize()
	if skybox.pipeline then return end

	-- Create environment cubemap
	skybox.output_texture = Texture.New(
		{
			width = 256,
			height = 256,
			format = "r16g16b16a16_sfloat",
			mip_map_levels = "auto",
			image = {
				image_type = "2d",
				array_layers = 6,
				flags = {"cube_compatible"},
				usage = {"sampled", "transfer_dst", "transfer_src", "color_attachment"},
			},
			view = {
				view_type = "cube",
			},
			sampler = {
				min_filter = "linear",
				mag_filter = "linear",
				mipmap_mode = "linear",
				wrap_s = "clamp_to_edge",
				wrap_t = "clamp_to_edge",
				wrap_r = "clamp_to_edge",
			},
		}
	)
	-- Create views for each face of the cubemap for rendering
	skybox.face_views = {}

	for i = 0, 5 do
		table.insert(
			skybox.face_views,
			skybox.output_texture.image:CreateView(
				{
					format = skybox.output_texture.format,
					base_mip_level = 0,
					level_count = 1,
					base_array_layer = i,
					layer_count = 1,
					view_type = "2d",
				}
			)
		)
	end

	skybox.pipeline = EasyPipeline.New(
		{
			vertex = {
				push_constants = {
					{
						name = "vertex",
						block = {
							{
								"inv_projection_view",
								"mat4",
								function(constants)
									skybox.inv_projection_view:CopyToFloatPointer(constants.inv_projection_view)
								end,
							},
							{
								"face",
								"int",
								function()
									return skybox.current_face or -1
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
					
					vec3 get_cube_dir(vec2 uv, int face) {
						vec3 dir;
						if (face == 0) dir = vec3(1.0, -uv.y, -uv.x); // +X
						else if (face == 1) dir = vec3(-1.0, -uv.y, uv.x); // -X
						else if (face == 2) dir = vec3(uv.x, 1.0, uv.y); // +Y
						else if (face == 3) dir = vec3(uv.x, -1.0, -uv.y); // -Y
						else if (face == 4) dir = vec3(uv.x, -uv.y, 1.0); // +Z
						else if (face == 5) dir = vec3(-uv.x, -uv.y, -1.0); // -Z
						return normalize(dir);
					}

					void main() {
						vec2 pos = positions[gl_VertexIndex];
						gl_Position = vec4(pos, 1.0, 1.0);
						
						if (pc.vertex.face == -1) {
							// Convert NDC to world direction
							vec4 world_pos = pc.vertex.inv_projection_view * vec4(pos, 1.0, 1.0);
							out_direction = world_pos.xyz / world_pos.w;
						} else {
							out_direction = get_cube_dir(pos, pc.vertex.face);
						}
					}
				]],
			},
			fragment = {
				push_constants = {
					{
						name = "fragment",
						block = {
							{
								"universe_texture_index",
								"int",
								function()
									return skybox.pipeline:GetTextureIndex(skybox.universe_texture)
								end,
							},
							{
								"sun_direction",
								"vec4",
								function(constants)
									local lights = render3d.GetLights()
									local sun = lights and lights[1]
									local sun_dir = sun and sun:GetDirection() or {x = 0, y = 1, z = 0}

									if true then sun_dir = {x = 0, y = 1, z = 0} end

									constants.sun_direction[0] = sun_dir.x
									constants.sun_direction[1] = sun_dir.y
									constants.sun_direction[2] = sun_dir.z
									constants.sun_direction[3] = 0
								end,
							},
							{
								"camera_position",
								"vec4",
								function(constants)
									local cam_pos = render3d.camera:GetPosition()

									if true then cam_pos = {x = 0, y = 10, z = 0} end

									constants.camera_position[0] = cam_pos.x
									constants.camera_position[1] = cam_pos.y
									constants.camera_position[2] = cam_pos.z
									constants.camera_position[3] = 0
								end,
							},
						},
					},
				},
				custom_declarations = [[
					layout(location = 0) in vec3 in_direction;
					layout(location = 0) out vec4 out_color;
					
					const float PI = 3.14159265359;
					
					// Nishita Sky Model Constants
					const float EARTH_RADIUS = 6371000.0;      // meters
					const float ATMOSPHERE_RADIUS = 6471000.0; // meters (100km atmosphere)
					const float HR = 7994.0;                   // Rayleigh scale height
					const float HM = 1200.0;                   // Mie scale height
					
					// Rayleigh scattering coefficients at sea level
					const vec3 BETA_R = vec3(5.5e-6, 13.0e-6, 22.4e-6);
					// Mie scattering coefficient at sea level
					const float BETA_M = 21e-6;
					
					// Mie scattering phase function asymmetry factor
					const float G = 0.76;
					
					const int NUM_SAMPLES = 16;
					const int NUM_SAMPLES_LIGHT = 8;
					
					// Ray-sphere intersection
					// Returns distance to first intersection, or -1 if no intersection
					vec2 raySphereIntersect(vec3 rayOrigin, vec3 rayDir, float radius) {
						float a = dot(rayDir, rayDir);
						float b = 2.0 * dot(rayDir, rayOrigin);
						float c = dot(rayOrigin, rayOrigin) - radius * radius;
						float d = b * b - 4.0 * a * c;
						if (d < 0.0) return vec2(-1.0);
						d = sqrt(d);
						return vec2(-b - d, -b + d) / (2.0 * a);
					}
					
					// Rayleigh phase function
					float phaseRayleigh(float cosTheta) {
						return 3.0 / (16.0 * PI) * (1.0 + cosTheta * cosTheta);
					}
					
					// Mie phase function (Henyey-Greenstein)
					float phaseMie(float cosTheta) {
						float g2 = G * G;
						float num = (1.0 - g2);
						float denom = pow(1.0 + g2 - 2.0 * G * cosTheta, 1.5);
						return 3.0 / (8.0 * PI) * num / denom;
					}
					
					// Compute atmospheric scattering using Nishita model
					vec3 nishitaSky(vec3 rayDir, vec3 sunDir, vec3 camPos) {
						// Camera position - add world position to earth surface
						// Scale factor: game units to meters (adjust as needed)
						float scale = 1.0;
						vec3 rayOrigin = vec3(0.0, EARTH_RADIUS + 1.0 + camPos.y * scale, 0.0);
						
						// Intersect with atmosphere
						vec2 t = raySphereIntersect(rayOrigin, rayDir, ATMOSPHERE_RADIUS);
						if (t.x > t.y || t.y < 0.0) return vec3(0.0);
						
						float tMax = t.y;
						float tMin = max(t.x, 0.0);
						
						float segmentLength = (tMax - tMin) / float(NUM_SAMPLES);
						float tCurrent = tMin;
						
						vec3 sumR = vec3(0.0);
						vec3 sumM = vec3(0.0);
						float opticalDepthR = 0.0;
						float opticalDepthM = 0.0;
						
						float cosTheta = dot(rayDir, sunDir);
						float phaseR = phaseRayleigh(cosTheta);
						float phaseM = phaseMie(cosTheta);
						
						for (int i = 0; i < NUM_SAMPLES; i++) {
							vec3 samplePos = rayOrigin + rayDir * (tCurrent + segmentLength * 0.5);
							float height = length(samplePos) - EARTH_RADIUS;
							
							// Density at this height
							float densityR = exp(-height / HR) * segmentLength;
							float densityM = exp(-height / HM) * segmentLength;
							
							opticalDepthR += densityR;
							opticalDepthM += densityM;
							
							// Light ray to sun
							vec2 tLight = raySphereIntersect(samplePos, sunDir, ATMOSPHERE_RADIUS);
							float segmentLengthLight = tLight.y / float(NUM_SAMPLES_LIGHT);
							float tCurrentLight = 0.0;
							float opticalDepthLightR = 0.0;
							float opticalDepthLightM = 0.0;
							
							bool hitGround = false;
							for (int j = 0; j < NUM_SAMPLES_LIGHT; j++) {
								vec3 samplePosLight = samplePos + sunDir * (tCurrentLight + segmentLengthLight * 0.5);
								float heightLight = length(samplePosLight) - EARTH_RADIUS;
								
								if (heightLight < 0.0) {
									hitGround = true;
									break;
								}
								
								opticalDepthLightR += exp(-heightLight / HR) * segmentLengthLight;
								opticalDepthLightM += exp(-heightLight / HM) * segmentLengthLight;
								tCurrentLight += segmentLengthLight;
							}
							
							if (!hitGround) {
								vec3 tau = BETA_R * (opticalDepthR + opticalDepthLightR) + 
										   BETA_M * 1.1 * (opticalDepthM + opticalDepthLightM);
								vec3 attenuation = exp(-tau);
								sumR += densityR * attenuation;
								sumM += densityM * attenuation;
							}
							
							tCurrent += segmentLength;
						}
						
						// Sun intensity (22 is a good value for Earth)
						float sunIntensity = 22.0;
						
						return sunIntensity * (sumR * BETA_R * phaseR + sumM * BETA_M * phaseM);
					}
					
					// Render sun disk
					vec3 renderSun(vec3 rayDir, vec3 sunDir, vec3 skyColor) {
						float sunAngle = acos(clamp(dot(rayDir, sunDir), 0.0, 1.0));
						float sunRadius = 0.00935; // Angular radius of sun in radians (~0.53 degrees)
						
						if (sunAngle < sunRadius) {
							// Inside sun disk
							float limb = 1.0 - pow(sunAngle / sunRadius, 0.5);
							return vec3(1.0, 0.98, 0.95) * 100.0 * limb;
						} else if (sunAngle < sunRadius * 1.5) {
							// Sun glow/corona
							float glow = 1.0 - (sunAngle - sunRadius) / (sunRadius * 0.5);
							return skyColor + vec3(1.0, 0.9, 0.7) * glow * glow * 10.0;
						}
						
						return skyColor;
					}
				]],
				shader = [[
					void main() {
						vec3 dir = normalize(in_direction);
						vec3 sunDir = normalize(pc.fragment.sun_direction.xyz);
						
						// Compute Nishita sky
						vec3 skyColor = nishitaSky(dir, sunDir, pc.fragment.camera_position.xyz);
						
						// Add sun disk
						skyColor = renderSun(dir, sunDir, skyColor);
						
						// Compute sky brightness for blending with space texture
						// Use sun elevation to determine day/night
						float sunElevation = sunDir.y;
						
						// Sky brightness based on sun elevation
						// At sunset (elevation ~0), start transitioning
						// Below horizon, night time
						float dayFactor = smoothstep(-0.2, 0.1, sunElevation);
						
						// Also consider the actual sky luminance for the blend
						float skyLuminance = dot(skyColor, vec3(0.2126, 0.7152, 0.0722));
						float skyBrightness = clamp(skyLuminance * 0.5, 0.0, 1.0);
						
						// Combine day factor and sky brightness
						float blendFactor = max(dayFactor, skyBrightness);
						
						// Sample space/stars texture
						vec3 spaceColor = vec3(0.0);
						if (pc.fragment.universe_texture_index != -1) {
							float u = atan(dir.z, dir.x) / (2.0 * PI) + 0.5;
							float v = asin(dir.y) / PI + 0.5;
							spaceColor = texture(TEXTURE(pc.fragment.universe_texture_index), vec2(u, -v)).rgb;
						}
						
						// Blend: show stars when sky is dark, hide them during day
						vec3 finalColor = mix(spaceColor, skyColor, blendFactor);
						
						// Tonemapping (ACES-like)
						finalColor = finalColor / (finalColor + vec3(1.0));
						
						// Gamma correction
						finalColor = pow(finalColor, vec3(1.0/2.2));
						
						out_color = vec4(finalColor, 1.0);
					}
				]],
			},
			rasterizer = {
				cull_mode = "none",
				front_face = orientation.FRONT_FACE,
			},
			depth_stencil = {
				depth_test = false,
				depth_write = false,
			},
		}
	)
	skybox.UpdateEnvironmentTexture()
end

event.AddListener("Render3DInitialized", "skybox", function()
	skybox.Initialize()
end)

function skybox.UpdateEnvironmentTexture()
	if not skybox.output_texture then return end

	local device = render.GetDevice()
	local queue = render.GetQueue()
	local command_pool = render.GetCommandPool()
	local cmd = command_pool:AllocateCommandBuffer()
	cmd:Begin()
	-- Determine old layout based on whether this is first render
	local oldLayout = skybox.environment_texture_initialized and
		"shader_read_only_optimal" or
		"undefined"
	local srcAccessMask = skybox.environment_texture_initialized and "shader_read" or "none"
	-- Transition image to color_attachment_optimal
	cmd:PipelineBarrier(
		{
			srcStage = "top_of_pipe",
			dstStage = "color_attachment_output",
			imageBarriers = {
				{
					image = skybox.output_texture.image,
					srcAccessMask = srcAccessMask,
					dstAccessMask = "color_attachment_write",
					oldLayout = oldLayout,
					newLayout = "color_attachment_optimal",
					level_count = 1,
					layer_count = 6,
				},
			},
		}
	)
	skybox.pipeline:Bind(cmd)

	for i = 0, 5 do
		skybox.current_face = i
		skybox.pipeline:UploadConstants(cmd)
		cmd:BeginRendering(
			{
				color_image_view = skybox.face_views[i + 1],
				w = 256,
				h = 256,
				clear_color = {0, 0, 0, 1},
			}
		)
		cmd:SetViewport(0, 0, 256, 256, 0, 1)
		cmd:SetScissor(0, 0, 256, 256)
		cmd:Draw(3, 1, 0, 0)
		cmd:EndRendering()
	end

	-- Transition back to shader_read_only_optimal
	cmd:PipelineBarrier(
		{
			srcStage = "color_attachment_output",
			dstStage = "fragment",
			imageBarriers = {
				{
					image = skybox.output_texture.image,
					srcAccessMask = "color_attachment_write",
					dstAccessMask = "shader_read",
					oldLayout = "color_attachment_optimal",
					newLayout = "shader_read_only_optimal",
					level_count = 1,
					layer_count = 6,
				},
			},
		}
	)
	cmd:End()
	local fence = Fence.New(device)
	queue:SubmitAndWait(device, cmd, fence)
	device:WaitIdle()
	skybox.output_texture:GenerateMipMap("shader_read_only_optimal")
	-- Mark as initialized for subsequent calls
	skybox.environment_texture_initialized = true
end

function skybox.Draw(cmd)
	if not skybox.pipeline then return end

	if skybox.output_texture then
		render3d.SetEnvironmentTexture(skybox.GetEnvironmentTexture())
	end

	-- Calculate inverse projection-view matrix (without camera translation for skybox)
	local proj = render3d.camera:BuildProjectionMatrix()
	local view = render3d.camera:BuildViewMatrix():Copy()
	-- Remove translation from view matrix for skybox
	view.m30 = 0
	view.m31 = 0
	view.m32 = 0
	local proj_view = view * proj
	proj_view:GetInverse(skybox.inv_projection_view)
	skybox.current_face = -1
	skybox.pipeline:Bind(cmd, render.GetCurrentFrame())
	skybox.pipeline:UploadConstants(cmd)
	cmd:Draw(3, 1, 0, 0)
end

event.AddListener("DrawSkybox", "skybox", skybox.Draw)

function skybox.SetUniverseTexture(texture)
	skybox.universe_texture = texture
end

function skybox.GetEnvironmentTexture()
	return skybox.output_texture
end

if render3d.pipeline then skybox.Initialize() end

return skybox
