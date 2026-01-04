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

local function setup_sun()
	if render3d.GetLights()[1] then return end

	local Light = require("components.light")
	local sun = Light.CreateDirectional({color = {1, 1, 1}, intensity = 1})
	sun:SetIsSun(true)
	sun:SetRotation(Quat(0.5, 0, 0, -1))
	render3d.SetLights({sun})
end

-- Helper function to initialize render3d
local function init_render3d()
	render.Initialize({headless = true, width = width, height = height})
	render3d.Initialize()
	local cam = render3d.GetCamera()
	cam:SetPosition(Vec3(0, 0.68, 3))
	cam:SetRotation(Quat(0, 0, 0, 1))
	cam:SetViewport(Rect(0, 0, width, height))
	cam:SetFOV(math.rad(30))
	setup_sun()
end

T.Test("combine", function()
	init_render3d()
	steam.MountSourceGame("gmod")
	tasks.WaitAll(3)
	local ent = ecs.CreateEntity("mdl", ecs.GetWorld())
	ent:AddComponent("transform")
	ent:AddComponent("model")
	ent.model:SetModelPath("models/player/combine_super_soldier.mdl")
	ent.transform:SetRotation(Quat(0, -1, 0, 1))
	tasks.WaitAll(3) -- waits for the model to load for max 3 seconds
	render.Draw(1)

	-- body 
	T.ScreenPixel(256, 256, function(r, g, b, a)
		return r > 0 and g > 0 and b > 0
	end)

	-- check the pixel between left arm and leg and make sure it hits the skybox as to not be corrupt
	T.ScreenPixel(170, 300, function(r, g, b, a)
		T(r)["<"](0.01)
		T(g)["<"](0.01)
		T(b)["<"](0.01)
		return true
	end)

	ent:Remove()
end)

T.Test("alyx", function()
	init_render3d()
	steam.MountSourceGame("gmod")
	tasks.WaitAll(3)
	local path = "models/player/alyx.mdl"
	local ent = ecs.CreateEntity("mdl", ecs.GetWorld())
	ent:AddComponent("transform")
	ent:AddComponent("model")
	ent.transform:SetRotation(Quat(0, -1, 0, 1))
	ent.model:SetModelPath(path)
	ent.transform:SetRotation(Quat(0, -1, 0, 1))
	tasks.WaitAll(3)
	render.Draw(1)

	-- body 
	T.ScreenPixel(256, 256, function(r, g, b, a)
		return r > 0 and g > 0 and b > 0
	end)

	-- check the pixel between left arm and leg and make sure it hits the skybox
	T.ScreenPixel(170, 300, function(r, g, b, a)
		T(r)["<"](0.01)
		T(g)["<"](0.01)
		T(b)["<"](0.01)
		return true
	end)
end)
