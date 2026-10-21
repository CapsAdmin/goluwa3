local Vec3 = import("goluwa/structs/vec3.lua")
local Color = import("goluwa/structs/color.lua")
local Entity = import("goluwa/entities/entity.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local shapes = import("goluwa/render3d/shapes.lua")
local W, D, H, T = 16, 12, 6, 0.2
local WALL_ALBEDO = 0.5
local EMISSION = 1
local wall = shapes.Material{
	Roughness = 1,
	Metallic = 0,
	SpecularMultiplier = 0,
	ColorMultiplier = Color(WALL_ALBEDO, WALL_ALBEDO, WALL_ALBEDO, 1),
	AlbedoAlphaIsEmissive = true,
	EmissiveMultiplier = Color(1, 1, 1, EMISSION),
}

local function box(name, position, size)
	return shapes.Box{
		Name = name,
		Position = position,
		Size = size,
		Material = wall,
		Collision = false,
		RigidBody = false,
	}
end

box("furnace_floor", Vec3(0, -T / 2, 0), Vec3(W + 2 * T, T, D + 2 * T))
box("furnace_ceiling", Vec3(0, H + T / 2, 0), Vec3(W + 2 * T, T, D + 2 * T))
box("furnace_wall_left", Vec3(-W / 2 - T / 2, H / 2, 0), Vec3(T, H, D))
box("furnace_wall_right", Vec3(W / 2 + T / 2, H / 2, 0), Vec3(T, H, D))
box("furnace_wall_front", Vec3(0, H / 2, D / 2 + T / 2), Vec3(W, H, T))
box("furnace_wall_back", Vec3(0, H / 2, -D / 2 - T / 2), Vec3(W, H, T))
local COLUMNS = 5

for column = 0, COLUMNS - 1 do
	local roughness = column / (COLUMNS - 1)
	local x = ((COLUMNS - 1) / 2 - column) * 2.6

	for row = 0, 1 do
		shapes.Sphere{
			Name = "furnace_sphere_" .. column .. "_" .. row,
			Position = Vec3(x, 3.6 - row * 2.2, 3),
			Radius = 0.9,
			Material = shapes.Material{
				Roughness = roughness,
				Metallic = row == 0 and 1 or 0,
				ColorMultiplier = Color(1, 1, 1, 1),
			},
			Collision = false,
			RigidBody = false,
		}
	end
end

do
	local cam = render3d.GetCamera()
	cam:SetPosition(Vec3(0, 2.6, -4.5))
	cam:SetAngles(Deg3(0, 180, 0))
	local rig = Entity.World:GetKeyed("player_camera_rig")

	if rig and rig:IsValid() then
		rig.character_movement:SetEyePosition(cam:GetPosition())

		if rig.player_input and rig.player_input.SyncFromCamera then
			rig.player_input:SyncFromCamera(cam)
		end
	end
end
