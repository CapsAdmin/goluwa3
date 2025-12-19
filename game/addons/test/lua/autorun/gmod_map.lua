local vfs = require("vfs")
require("model_loader")
local steam = require("steam")
local Light = require("components.light")
local Vec3 = require("structs.vec3")
local Quat = require("structs.quat")
local ecs = require("ecs")
local Ang3 = require("structs.ang3")
local Material = require("graphics.material")
local Polygon3D = require("graphics.polygon_3d")
local render3d = require("graphics.render3d")
local sun, sun_entity = Light.CreateDirectional(
	{
		direction = Vec3(0.75, 0.25, -0.25):Normalize(),
		color = {1.0, 1.0, 1.0},
		intensity = 2.0,
		name = "Sun",
		cast_shadows = false,
	}
)
render3d.SetSunLight(sun)
render3d.GetCamera():SetFOV(1.2)
render3d.GetCamera():SetPosition(Vec3(-0.3, -242.9, -18.3))
render3d.GetCamera():SetRotation(Quat(-0.1, -0.3, -0.1, 0.9))
steam.SetMap("gm_flatgrass")
