local vk = require("bindings.vk")

if not pcall(vk.find_library) then
	print("Vulkan library not available, skipping polygon_3d comprehensive tests.")
	return
end

local T = require("test.environment")
local ffi = require("ffi")
local png_encode = require("file_formats.png.encode")
local render = require("graphics.render")
local render3d = require("graphics.render3d")
local skybox = require("graphics.skybox")
local Polygon3D = require("graphics.polygon_3d")
local Material = require("graphics.material")
local Vec3 = require("structs.vec3")
local Color = require("structs.color")
local Vec2 = require("structs.vec2")
local Rect = require("structs.rect")
local Matrix44 = require("structs.matrix").Matrix44
local Texture = require("graphics.texture")
local fs = require("fs")
local width = 512
local height = 512
local Quat = require("structs.quat")

local function draw3d(cb)
	render.Initialize({headless = true, width = width, height = height})
	render3d.Initialize()
	local env_tex = Texture.New(
		{
			width = 1024,
			height = 512,
			format = "r8g8b8a8_unorm",
			mip_map_levels = "auto",
		}
	)
	env_tex:Shade([[
		float theta = uv.y * 3.14159265359;
		float phi = uv.x * 6.28318530718;
		vec3 dir = vec3(
			sin(theta) * sin(phi),
			cos(theta),
			sin(theta) * cos(phi)
		);
		vec3 a = abs(dir);
		if (a.x >= a.y && a.x >= a.z) {
			return dir.x > 0.0 ? vec4(1, 1, 0, 1) : vec4(0, 0, 1, 1); // +X: Yellow (Right), -X: Blue (Left)
		} else if (a.y >= a.z) {
			return dir.y > 0.0 ? vec4(0, 1, 0, 1) : vec4(1, 0, 1, 1); // +Y: Green (Up), -Y: Pink (Down)
		} else {
			return dir.z > 0.0 ? vec4(1, 0, 0, 1) : vec4(0, 1, 1, 1); // +Z: Red (Back), -Z: Teal (Front)
		}
	]])
	env_tex:GenerateMipMap("shader_read_only_optimal")
	skybox.SetTexture(env_tex)
	local cam = render3d.GetCamera()
	cam:SetPosition(Vec3(0, 0, -10))
	cam:SetRotation(Quat(0, 0, 0, 1))
	cam:SetViewport(Rect(0, 0, width, height))
	cam:SetFOV(math.rad(45))
	cam:SetOrthoMode(false)
	local Light = require("components.light")
	local sun = Light.CreateDirectional({color = {1, 1, 1}, intensity = 0})
	sun:SetIsSun(true)
	render3d.SetLights({sun})
	render.BeginFrame()
	skybox.Draw()
	render3d.BindPipeline()
	cb(render.GetCommandBuffer())
	render3d.SetWorldMatrix(Matrix44())
	render.EndFrame()
	render.GetDevice():WaitIdle()
end

local function setup_view()
	local r = 10
	render3d.GetCamera():SetFOV(0.001 * r)
	render3d.GetCamera():SetPosition(Vec3(0, 0, 2000 / r))
end

local function sphere(lp, ly, config)
	local M = config.metallic or 1
	local R = config.roughness or 1
	local color = config.color or Color(1, 1, 1, 1)

	draw3d(function(cmd)
		local mat = Material.New(
			{
				base_color_factor = {color:Unpack()},
				metallic_roughness_texture = Texture.New(
					{
						width = 1,
						height = 1,
						format = "r8g8b8a8_unorm",
						buffer = ffi.new("uint8_t[4]", {
							255,
							255 * R,
							255 * M,
							255,
						}),
					}
				),
			}
		)
		setup_view()
		local poly = Polygon3D.New()
		poly:CreateSphere()
		poly:BuildNormals()
		poly:AddSubMesh(#poly.Vertices)
		poly:Upload()
		local sun = render3d.GetLights()[1]
		sun:SetRotation(Quat():SetAngles(Deg3(lp, ly, 0)))
		render3d.SetMaterial(mat)
		render3d.UploadConstants(cmd)
		poly:Draw(cmd)
	end)

	render.Screenshot("test")
end

T.Test("Graphics Polygon3D environment map reflection colors", function()
	sphere(90, 0, {metallic = 0.5, roughness = 0.1, color = Color(1, 1, 1, 1)})
	local tolerance = 0.6
	-- Center: Blue (Left -X)
	T.ScreenPixel(256, 256, 0, 0, 1, 1, tolerance)
	-- Top: Green (Up +Y)
	T.ScreenPixel(256, 128, 0, 1, 0, 1, tolerance)
	-- Bottom: Pink (Down -Y)
	T.ScreenPixel(256, 384, 1, 0, 1, 1, tolerance)
	-- Left: Red (Back +Z)
	T.ScreenPixel(128, 256, 1, 0, 0, 1, tolerance)
	-- Right: Teal (Front -Z)
	T.ScreenPixel(384, 256, 0, 1, 1, 1, tolerance)
	-- Rim: Yellow (Right +X)
	T.ScreenPixel(256, 10, 1, 1, 0, 1, tolerance)
end)
