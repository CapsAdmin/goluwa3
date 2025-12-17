local vfs = require("vfs")
require("model_loader")
local steam = require("steam")
local Vec3 = require("structs.vec3")
local ecs = require("ecs")
local Light = require("components.light")
local render3d = require("graphics.render3d")
local entity = ecs.CreateEntity("flatgrass", ecs.GetWorld())
entity:AddComponent("transform", {
	position = Vec3(0, 0, 0),
	scale = Vec3(1, 1, 1),
})
entity:AddComponent("model")
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

do
	local games = steam.GetSourceGames()
	steam.MountSourceGame("gmod")
	entity.model:SetModelPath("maps/gm_construct.bsp")
end
