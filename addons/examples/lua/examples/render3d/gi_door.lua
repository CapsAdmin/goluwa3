local Vec3 = import("goluwa/structs/vec3.lua")
local Color = import("goluwa/structs/color.lua")
local Entity = import("goluwa/entities/entity.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local shapes = import("goluwa/render3d/shapes.lua")

local function mat(color, roughness)
	return shapes.Material{Color = color, Roughness = roughness, Metallic = 0}
end

local function emissive_mat(color, strength)
	return shapes.Material{
		Color = color,
		Roughness = 0.9,
		Metallic = 0,
		AlbedoAlphaIsEmissive = true,
		EmissiveMultiplier = Color(1, 1, 1, strength),
	}
end

local function box(name, position, size, material)
	shapes.Box{
		Name = name,
		Position = position,
		Size = size,
		Material = material,
		Collision = false,
		RigidBody = false,
	}
end

local white = mat(Color(0.8, 0.8, 0.8, 1), 0.9)
local grey = mat(Color(0.35, 0.35, 0.35, 1), 0.9)
local lamp = emissive_mat(Color(1, 0.72, 0.42, 1), 6)
box("ground", Vec3(0, -0.5, 0), Vec3(200, 1, 200), white)

do
	local t = 0.4
	box("room_back", Vec3(0, 2.5, -4.2), Vec3(8.8, 5, t), grey)
	box("room_left", Vec3(-4.2, 2.5, 0), Vec3(t, 5, 8.8), grey)
	box("room_right", Vec3(4.2, 2.5, 0), Vec3(t, 5, 8.8), grey)
	box("room_ceiling", Vec3(0, 5.2, 0), Vec3(8.8, t, 8.8), grey)
	box("room_front_left", Vec3(-2.6, 2.5, 4.2), Vec3(3.6, 5, t), grey)
	box("room_front_right", Vec3(2.6, 2.5, 4.2), Vec3(3.6, 5, t), grey)
	box("room_front_top", Vec3(0, 4.1, 4.2), Vec3(1.6, 2.2, t), grey)
	box("room_lamp_back", Vec3(0, 2.5, -3.9), Vec3(7, 4, 0.1), lamp)
	box("room_lamp_left", Vec3(-3.9, 2.5, 0), Vec3(0.1, 4, 7), lamp)
	box("room_lamp_right", Vec3(3.9, 2.5, 0), Vec3(0.1, 4, 7), lamp)
	box("room_lamp_ceiling", Vec3(0, 4.9, 0), Vec3(7, 0.1, 7), lamp)
	box("room_occluder", Vec3(1.3, 1.1, 1.6), Vec3(1.2, 2.2, 1.2), grey)
end

shapes.Sphere{
	Name = "spill_sphere",
	Position = Vec3(-2.5, 1, 9),
	Radius = 1,
	Material = white,
	Collision = false,
	RigidBody = false,
}

for _, light in ipairs(render3d.GetLights()) do
	if light.Type == "light_sun" then
		light.Owner.transform:SetRotation(QuatDeg3(75, 40, 0))
	end
end

do
	local cam = render3d.GetCamera()
	cam:SetPosition(Vec3(0, 4, 18))
	cam:SetAngles(Deg3(-10, 0, 0))
	local rig = Entity.World:GetKeyed("player_camera_rig")

	if rig and rig:IsValid() then
		rig.transform:SetPosition(cam:GetPosition():Copy())

		if rig.player_input and rig.player_input.SyncFromCamera then
			rig.player_input:SyncFromCamera(cam)
		end
	end
end
