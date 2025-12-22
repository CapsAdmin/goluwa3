do
	return
end

local ecs = require("ecs")
local Vec3 = require("structs.vec3")
local Ang3 = require("structs.ang3")
local Material = require("render3d.material")
local render3d = require("render3d.render3d")
local build_cube = runfile("lua/build_cube.lua")
local Light = require("components.light")
local cube_mesh = build_cube(1.0)
local materials = {
	Material.New({base_color_factor = {1, 0.2, 0.2, 1}}),
	Material.New({base_color_factor = {0.2, 1, 0.2, 1}}),
	Material.New({base_color_factor = {0.2, 0.2, 1, 1}}),
	Material.New({base_color_factor = {1, 1, 0.2, 1}}),
	Material.New({base_color_factor = {0.2, 1, 1, 1}}),
	Material.New({base_color_factor = {1, 0.2, 1, 1}}),
	Material.New({base_color_factor = {0.9, 0.9, 0.9, 1}}),
	Material.New({base_color_factor = {0.5, 0.5, 0.5, 1}}),
}
local SIZE = 4
SIZE = SIZE / 2

for x = -SIZE, SIZE do
	for y = -SIZE, SIZE do
		for z = -SIZE, SIZE do
			local entity = ecs.CreateEntity(("cube%i.%i.%i"):format(x, y, z), ecs.GetWorld())
			entity:AddComponent("transform", {
				position = Vec3(x, y, z),
				scale = Vec3(1, 1, 1),
			})
			entity:AddComponent("model", {
				mesh = cube_mesh,
				material = table.random(materials),
			})
		end
	end
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
sun:SetIsSun(true)
render3d.SetLights({sun})
render3d.GetCamera():SetFOV(1.2)
