local Vec3 = import("goluwa/structs/vec3.lua")
local Color = import("goluwa/structs/color.lua")
local Entity = import("goluwa/entities/entity.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local shapes = import("goluwa/render3d/shapes.lua")
local weather = import("goluwa/render3d/weather.lua")
local HALF = 4
local HEIGHT = 5
local grey = shapes.Material{Color = Color(0.7, 0.7, 0.7, 1), Roughness = 0.9, Metallic = 0}
local outside = shapes.Material{Color = Color(0.45, 0.4, 0.35, 1), Roughness = 0.9, Metallic = 0}

-- every plane is one quad facing into the room, so only its inside face is drawn and nothing but the plane itself stands between the sun and the floor
local function plane(name, position, normal, size_x, size_y, material)
	shapes.Polygon{
		Name = name,
		Material = material,
		Collision = false,
		RigidBody = false,
		Polygon = function(poly)
			shapes.BuildPlane(poly, position, normal, size_x, size_y)
		end,
	}
end

plane("room_floor", Vec3(0, 0, 0), Vec3(0, 1, 0), HALF, HALF, grey)
plane("room_ceiling", Vec3(0, HEIGHT, 0), Vec3(0, -1, 0), HALF, HALF, grey)
plane("room_back", Vec3(0, HEIGHT / 2, -HALF), Vec3(0, 0, 1), HALF, HEIGHT / 2, grey)
plane("room_front", Vec3(0, HEIGHT / 2, HALF), Vec3(0, 0, -1), HALF, HEIGHT / 2, grey)
plane("room_left", Vec3(-HALF, HEIGHT / 2, 0), Vec3(1, 0, 0), HALF, HEIGHT / 2, grey)
plane("room_right", Vec3(HALF, HEIGHT / 2, 0), Vec3(-1, 0, 0), HALF, HEIGHT / 2, grey)
plane("ground", Vec3(0, -0.02, 0), Vec3(0, 1, 0), 200, 200, outside)

weather.SetSolarHours(16)

do
	local cam = render3d.GetCamera()
	cam:SetPosition(Vec3(2.5, 1.6, 3))
	cam:SetAngles(Deg3(-10, 30, 0))
	local rig = Entity.World:GetKeyed("player_camera_rig")

	if rig and rig:IsValid() then
		rig.player_movement:SetEyePosition(cam:GetPosition())

		if rig.player_input and rig.player_input.SyncFromCamera then
			rig.player_input:SyncFromCamera(cam)
		end
	end
end
