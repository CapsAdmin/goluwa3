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
local Polygon3D = require("graphics.polygon_3d")
local Material = require("graphics.material")
local Vec3 = require("structs.vec3")
local Vec2 = require("structs.vec2")
local Rect = require("structs.rect")
local Matrix44 = require("structs.matrix").Matrix44
local fs = require("fs")
local width = 512
local height = 512
local Quat = require("structs.quat")

-- Helper function to initialize render3d
local function init_render3d()
	render.Initialize({headless = true, width = width, height = height})
	render3d.Initialize()
end

local function draw3d(cb)
	init_render3d()
	local cam = render3d.GetCamera()
	cam:SetPosition(Vec3(0, 0, -10))
	cam:SetViewport(Rect(0, 0, width, height))
	cam:SetFOV(math.rad(45))
	render3d.SetLightColor(1.0, 1.0, 1.0, 1.0)
	render.BeginFrame()
	render3d.BindPipeline()
	cb(render.GetCommandBuffer())
	render3d.SetWorldMatrix(Matrix44())
	render.EndFrame()
	render.GetDevice():WaitIdle()
end

local function setup_view()
	render3d.GetCamera():SetFOV(0.001)
	render3d.GetCamera():SetPosition(Vec3(0, 0, 2000))
end

local function sphere(lp, ly, mat)
	draw3d(function(cmd)
		setup_view()
		local poly = Polygon3D.New()
		poly:CreateSphere()
		poly:AddSubMesh(#poly.Vertices)
		poly:Upload()
		render3d.SetLightRotation(Quat():SetAngles(Deg3(lp, ly, 0)))
		render3d.SetMaterial(mat)
		render3d.UploadConstants(cmd)
		poly:Draw(cmd)
	end)
end

T.Test("Graphics Polygon3D render sphere", function()
	sphere(90, 0, Material.New({base_color_factor = {1.0, 1.0, 1.0, 1.0}}))
	render.Screenshot("test")
end)
