local event = require("event")
local ffi = require("ffi")
local Color = require("structs.color")
local orientation = require("render3d.orientation")
local Matrix44 = require("structs.matrix44")
local Vec3 = require("structs.vec3")
local Ang3 = require("structs.ang3")
local Quat = require("structs.quat")
local Rect = require("structs.rect")
local render = require("render.render")
local render3d = require("render3d.render3d")
local Camera3D = require("render3d.camera3d")
local EasyPipeline = require("render.easy_pipeline")
local skybox = library()
local Texture = require("render.texture")
local Fence = require("render.vulkan.internal.fence")
skybox.inv_projection_view = Matrix44()
skybox.temp_fence = nil
skybox.temp_camera = nil
skybox.update_cmd = nil
local SIZE = 512

function skybox.CreatePipeline(color_format)
	return EasyPipeline.New(
		{
			color_format = color_format,
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
								"universe_texture_index",
								"int",
								function(constants, pipeline)
									return pipeline:GetTextureIndex(skybox.universe_texture)
								end,
							},
							{
								"sun_direction",
								"vec4",
								function(constants)
									local lights = render3d.GetLights()
									local sun = lights[1]

									if not sun then return end

									sun:GetRotation():GetBackward():CopyToFloatPointer(constants.sun_direction)
								end,
							},
							{
								"camera_position",
								"vec4",
								function(constants)
									(render3d.camera:GetPosition() * 100):CopyToFloatPointer(constants.camera_position)
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
						
						if (sunAngle < sunRadius+0-00000000001) {
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
end

function skybox.Initialize()
	if skybox.output_texture then return end

	-- Create environment cubemap
	skybox.output_texture = Texture.New(
		{
			width = SIZE,
			height = SIZE,
			format = "r8g8b8a8_unorm",
			image = {
				array_layers = 6,
				flags = {"cube_compatible"},
				usage = {"color_attachment", "sampled", "transfer_src"},
			},
			view = {
				view_type = "cube",
			},
		}
	)
	skybox.face_views = {}

	for i = 0, 5 do
		skybox.face_views[i] = skybox.output_texture:GetImage():CreateView({
			view_type = "2d",
			base_array_layer = i,
			layer_count = 1,
		})
	end

	skybox.pipeline = skybox.CreatePipeline(render.target.color_format)
	skybox.cubemap_pipeline = skybox.CreatePipeline("r8g8b8a8_unorm")
end

event.AddListener("Render3DInitialized", "skybox", function()
	skybox.Initialize()
end)

function skybox.UpdateEnvironmentTexture()
	if not skybox.pipeline or not skybox.output_texture then return end

	if not skybox.update_cmd then
		skybox.update_cmd = render.GetCommandPool():AllocateCommandBuffer()
	end

	local cmd = skybox.update_cmd
	cmd:Reset()
	cmd:Begin()
	-- Transition cubemap to color_attachment_optimal
	cmd:PipelineBarrier(
		{
			srcStage = "top_of_pipe",
			dstStage = "color_attachment_output",
			imageBarriers = {
				{
					image = skybox.output_texture:GetImage(),
					oldLayout = "undefined",
					newLayout = "color_attachment_optimal",
					srcAccessMask = "none",
					dstAccessMask = "color_attachment_write",
					layer_count = 6,
				},
			},
		}
	)

	if not skybox.temp_camera then
		skybox.temp_camera = Camera3D.New()
		skybox.temp_camera:SetFOV(math.rad(90))
		skybox.temp_camera:SetViewport(Rect(0, 0, SIZE, SIZE))
		skybox.temp_camera:SetNearZ(0.1)
		skybox.temp_camera:SetFarZ(100)
	end

	local temp_camera = skybox.temp_camera
	local old_camera = render3d.camera
	render3d.camera = temp_camera
	local face_angles = {
		Ang3(0, math.rad(-90), 0), -- +X
		Ang3(0, math.rad(90), 0), -- -X
		Ang3(math.rad(90), 0, 0), -- +Y
		Ang3(math.rad(-90), 0, 0), -- -Y
		Ang3(0, math.rad(180), 0), -- +Z
		Ang3(0, 0, 0), -- -Z
	}
	local face_colors = {
		Color(1, 0, 0), -- +X: Red
		Color(0, 1, 0), -- -X: Green
		Color(0, 0, 1), -- +Y: Blue
		Color(1, 1, 0), -- -Y: Yellow
		Color(1, 0, 1), -- +Z: Magenta
		Color(0, 1, 1), -- -Z: Cyan
	}

	for i = 0, 5 do
		temp_camera:SetAngles(face_angles[i + 1])
		-- Calculate inverse projection-view matrix
		local proj = temp_camera:BuildProjectionMatrix()
		local view = temp_camera:BuildViewMatrix():Copy()
		view.m30, view.m31, view.m32 = 0, 0, 0
		local proj_view = view * proj
		proj_view:GetInverse(skybox.inv_projection_view)
		cmd:BeginRendering(
			{
				color_image_view = skybox.face_views[i],
				w = SIZE,
				h = SIZE,
				clear_color = {0, 0, 0, 1},
			}
		)
		cmd:ClearColorImage(
			{
				image = skybox.output_texture:GetImage(),
				color = {face_colors[i + 1]:Unpack()},
				base_array_layer = i,
				layer_count = 1,
			}
		)
		cmd:SetViewport(0, 0, SIZE, SIZE)
		cmd:SetScissor(0, 0, SIZE, SIZE)
		skybox.cubemap_pipeline:Bind(cmd, render.GetCurrentFrame())
		skybox.cubemap_pipeline:UploadConstants(cmd)
		--cmd:Draw(3, 1, 0, 0)
		cmd:EndRendering()
	end

	-- Transition to shader_read_only_optimal
	cmd:PipelineBarrier(
		{
			srcStage = "color_attachment_output",
			dstStage = "fragment",
			imageBarriers = {
				{
					image = skybox.output_texture:GetImage(),
					oldLayout = "color_attachment_optimal",
					newLayout = "shader_read_only_optimal",
					srcAccessMask = "color_attachment_write",
					dstAccessMask = "shader_read",
					layer_count = 6,
				},
			},
		}
	)
	cmd:End()

	if not skybox.temp_fence then
		skybox.temp_fence = Fence.New(render.GetDevice())
	end

	render.GetQueue():SubmitAndWait(render.GetDevice(), cmd, skybox.temp_fence)
	render.GetDevice():WaitIdle()
	render3d.camera = old_camera
end

event.AddListener("PreFrame", "skybox_update", function()
	skybox.UpdateEnvironmentTexture()
end)

function skybox.Draw(cmd)
	if not skybox.pipeline then return end

	if skybox.output_texture then
		render3d.SetEnvironmentTexture(skybox.GetOutputCubemapTexture())
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
	skybox.pipeline:Bind(cmd, render.GetCurrentFrame())
	skybox.pipeline:UploadConstants(cmd)
	cmd:Draw(3, 1, 0, 0)
-- update here?
end

event.AddListener("DrawSkybox", "skybox", skybox.Draw)

function skybox.SetUniverseTexture(texture)
	skybox.universe_texture = texture
end

function skybox.GetOutputCubemapTexture()
	return skybox.output_texture
end

if render3d.pipeline then skybox.Initialize() end

return skybox
