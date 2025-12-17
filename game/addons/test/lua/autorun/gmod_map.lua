local vfs = require("vfs")
require("model_loader")
local steam = require("steam")
local Light = require("components.light")
local Vec3 = require("structs.vec3")
local ecs = require("ecs")
local Ang3 = require("structs.ang3")
local Material = require("graphics.material")
local Polygon3D = require("graphics.polygon_3d")
local render3d = require("graphics.render3d")
local sun, sun_entity = Light.CreateDirectional(
	{
		direction = Vec3(0.75, 0.25, -0.25):Normalize(),
		color = {1.0, 0.2, 1.0},
		intensity = 2.0,
		name = "Sun",
		cast_shadows = false,
	}
)
render3d.SetSunLight(sun)
render3d.SetCameraFOV(1.2)

do
	local Vec3 = require("structs.vec3")
	local ecs = require("ecs")
	local Ang3 = require("structs.ang3")
	local Polygon3D = require("graphics.polygon_3d")
	local Material = require("graphics.material")
	local poly = Polygon3D.New()
	poly:CreateCube(1.0, 1.0)
	poly:AddSubMesh(#poly.Vertices)
	poly:BuildNormals()
	poly:BuildBoundingBox()
	poly:Upload()
	local entity = ecs.CreateEntity("cube", ecs.GetWorld())
	entity:AddComponent("transform", {
		position = Vec3(0, 0, -5),
		scale = Vec3(1, 1, 1),
	})
	entity.transform:SetAngles(Deg3(45, 0, 0))
	entity:AddComponent(
		"model",
		{
			mesh = poly,
			material = Material.New({base_color_factor = {1, 0.2, 0.2, 1}}),
		}
	)
	return
end

steam.SetMap("gm_construct")
