local vk = require("bindings.vk")

if not pcall(vk.find_library) then
	print("Vulkan library not available, skipping polygon_3d comprehensive tests.")
	return
end

local T = require("test.environment")
local ffi = require("ffi")
local render = require("render.render")
local steam = require("steam")
local render3d = require("render3d.render3d")
local Polygon3D = require("render3d.polygon_3d")
local Material = require("render3d.material")
require("components.transform")
require("components.model")
local Vec3 = require("structs.vec3")
local Quat = require("structs.quat")
local Vec2 = require("structs.vec2")
local Rect = require("structs.rect")
local Matrix44 = require("structs.matrix44")
local fs = require("fs")
local width = 512
local height = 512
local ecs = require("ecs")
local tasks = require("tasks")

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
	local Light = require("components.light")
	local sun = Light.CreateDirectional({color = {1, 1, 1}, intensity = 1})
	sun:SetIsSun(true)
	sun:SetRotation(Quat():SetAngles(Vec3(0.5, -1.0, 0.3):GetAngles()))
	render3d.SetLights({sun})
	render.BeginFrame()
	render3d.BindPipeline()
	cb()
	render.EndFrame()
	render.GetDevice():WaitIdle()
end

T.Pending("MDL Model", function()
	init_render3d()
	steam.MountSourceGame("gmod")
	tasks.WaitAll(3)
	local path = "/home/caps/.steam/steam/steamapps/common/GarrysMod/garrysmod/garrysmod_dir.vpk/models/maxofs2d/companion_doll.mdl"
	local ent = ecs.CreateEntity("mdl", ecs.GetWorld())
	ent:AddComponent("transform")
	ent:AddComponent("model")
	ent.model:SetModelPath(path)
	tasks.WaitAll(3)

	draw3d(function()
		local cam = render3d.GetCamera()
		cam:SetPosition(Vec3(0, 0.25, 1))
		ent.model:OnDraw3DGeometry(render.GetCommandBuffer())
	end)

	render.Screenshot("test")

	-- body (currently present)
	T.ScreenPixel(256, 256, function(r, g, b, a)
		return r > 0 and g > 0 and b > 0
	end)

	-- head (currently missing)
	T.ScreenPixel(256, 137, function(r, g, b, a)
		T(r)["~"](0.1490)
		T(g)["~"](0.1215)
		T(b)["~"](0.1058)
		return true
	end)
end)
