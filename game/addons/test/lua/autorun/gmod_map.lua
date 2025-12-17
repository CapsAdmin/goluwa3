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
local poly = Polygon3D.New()

do
	steam.SetMap("gm_flatgrass")
	poly:CreateCube(1.0, 1.0)
	poly:AddSubMesh(#poly.Vertices)
	poly:BuildNormals()
	poly:Upload()
	local entity = ecs.CreateEntity("cube", ecs.GetWorld())
	local o = Vec3(-984, 0, -12768) * steam.source2meters
	local n = -Vec3(-o.y, -o.z, -o.x)
	entity:AddComponent("transform", {
		position = n,
		scale = Vec3(1, 1, 1),
	})
	entity:AddComponent(
		"model",
		{
			mesh = poly,
			material = Material.New({base_color_factor = {1, 0.2, 0.2, 1}}),
		}
	)
end

local sun, sun_entity = Light.CreateDirectional(
	{
		direction = Vec3(1, 0.5, -0.5):Normalize(),
		color = {1.0, 1.0, 1.0},
		intensity = 2.0,
		name = "Sun",
		cast_shadows = false,
	}
)
render3d.SetSunLight(sun)
--render3d.SetCameraPosition(Vec3(0, 0, 0))
render3d.SetCameraFOV(1.2)
