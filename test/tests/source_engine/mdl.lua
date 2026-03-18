local T = import("test/environment.lua")
local ffi = require("ffi")
local render = import("goluwa/render/render.lua")
local steam = import("goluwa/steam.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local Polygon3D = import("goluwa/render3d/polygon_3d.lua")
local Material = import("goluwa/render3d/material.lua")
local transform = import("goluwa/ecs/components/3d/transform.lua")
local model = import("goluwa/ecs/components/3d/model.lua")
local light = import("goluwa/ecs/components/3d/light.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Quat = import("goluwa/structs/quat.lua")
local Vec2 = import("goluwa/structs/vec2.lua")
local Rect = import("goluwa/structs/rect.lua")
local Color = import("goluwa/structs/color.lua")
local Matrix44 = import("goluwa/structs/matrix44.lua")
local fs = import("goluwa/fs.lua")
local width = 512
local height = 512
local Entity = import("goluwa/ecs/entity.lua")
local tasks = import("goluwa/tasks.lua")
local system = import("goluwa/system.lua")
local vfs = import("goluwa/vfs.lua")

--T.Test3D
T.Pending("mdl rendering", function(draw)
	steam.MountSourceGame("gmod")
	tasks.WaitAll(15)
	local cam = render3d.GetCamera()
	cam:SetPosition(Vec3(0, 0.68, 3))
	cam:SetRotation(Quat(0, 0, 0, 1))
	cam:SetFOV(math.rad(30))
	local sun = Entity.New{
		transform = {
			Rotation = Quat(0.5, 0, 0, -1),
		},
		light = {
			LightType = "sun",
			Color = Color(1, 1, 1),
			Intensity = 10,
		},
	}
	local ent = Entity.New({Name = "mdl"})
	ent:AddComponent("transform")
	ent:AddComponent("model")
	ent.model:SetModelPath("models/player/combine_super_soldier.mdl")
	ent.transform:SetRotation(Quat(0, -1, 0, 1))
	tasks.WaitAll(15)
	draw()
	T.ScreenshotAlbedo("game/storage/logs/screenshots/combine.png")

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
	T.ScreenshotAlbedo("game/storage/logs/screenshots/alyx.png")

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
