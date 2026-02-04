local T = require("test.environment")
local ffi = require("ffi")
local render = require("render.render")
local steam = require("steam")
local render3d = require("render3d.render3d")
local Polygon3D = require("render3d.polygon_3d")
local Material = require("render3d.material")
local transform = require("ecs.components.3d.transform")
local model = require("ecs.components.3d.model")
local light = require("ecs.components.3d.light")
local Vec3 = require("structs.vec3")
local Quat = require("structs.quat")
local Vec2 = require("structs.vec2")
local Rect = require("structs.rect")
local Color = require("structs.color")
local Matrix44 = require("structs.matrix44")
local fs = require("fs")
local width = 512
local height = 512
local Entity = require("ecs.entity")
local tasks = require("tasks")
local system = require("system")
local vfs = require("vfs")

--T.Test3D
T.Pending("mdl rendering", function(draw)
	steam.MountSourceGame("gmod")
	tasks.WaitAll(15)
	local cam = render3d.GetCamera()
	cam:SetPosition(Vec3(0, 0.68, 3))
	cam:SetRotation(Quat(0, 0, 0, 1))
	cam:SetFOV(math.rad(30))
	local sun = Entity.New(
		{
			transform = {
				Rotation = Quat(0.5, 0, 0, -1),
			},
			light = {
				LightType = "sun",
				Color = Color(1, 1, 1),
				Intensity = 10,
			},
		}
	)
	local ent = Entity.New({Name = "mdl"})
	ent:AddComponent("transform")
	ent:AddComponent("model")
	ent.model:SetModelPath("models/player/combine_super_soldier.mdl")
	ent.transform:SetRotation(Quat(0, -1, 0, 1))
	tasks.WaitAll(15)
	draw()
	T.ScreenshotAlbedo("logs/screenshots/combine.png")

	T.ScreenAlbedoPixel(256, 256, function(r, g, b, a)
		return r > 0 and g > 0 and b > 0
	end)

	-- check the pixel between left arm and leg and make sure it hits the skybox as to not be corrupt
	T.ScreenAlbedoPixel(170, 300, function(r, g, b, a)
		T(r)["<"](0.01)
		T(g)["<"](0.01)
		T(b)["<"](0.01)
		return true
	end)

	ent.model:SetModelPath("models/player/alyx.mdl")
	ent.transform:SetRotation(Quat(0, -1, 0, 1))
	tasks.WaitAll(15)
	draw()
	T.ScreenshotAlbedo("logs/screenshots/alyx.png")

	T.ScreenAlbedoPixel(256, 256, function(r, g, b, a)
		return r > 0 and g > 0 and b > 0
	end)

	-- check the pixel between left arm and leg and make sure it hits the skybox
	T.ScreenAlbedoPixel(170, 300, function(r, g, b, a)
		T(r)["<"](0.01)
		T(g)["<"](0.01)
		T(b)["<"](0.01)
		return true
	end)

	ent:Remove()
	sun:Remove()
end)
