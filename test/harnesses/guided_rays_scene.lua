local Vec3 = import("goluwa/structs/vec3.lua")
local Color = import("goluwa/structs/color.lua")
local Entity = import("goluwa/entities/entity.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local shapes = import("goluwa/render3d/shapes.lua")
local window = tonumber(os.getenv("GR_WINDOW") or "") or 0.4

local function mat(color, roughness)
	return shapes.Material{Color = color, Roughness = roughness, Metallic = 0}
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
local grey = mat(Color(0.5, 0.5, 0.5, 1), 0.9)
local sun_dir = Vec3(0, 1, 0)

for _, light in ipairs(render3d.GetLights()) do
	if light.Type == "light_sun" then
		light.Owner.transform:SetRotation(QuatDeg3(-50, 30, 0))
		sun_dir = -light.Owner.transform:GetRotation():GetForward()
	end
end

local side = sun_dir.z > 0 and -1 or 1
box("ground", Vec3(0, -0.5, 0), Vec3(200, 1, 200), white)

do
	local t, w, h = 0.4, 8.8, 3
	box("room_roof", Vec3(0, h + t / 2, 0), Vec3(w, t, w), grey)
	box("room_left", Vec3(-4.2, h / 2, 0), Vec3(t, h, w), grey)
	box("room_right", Vec3(4.2, h / 2, 0), Vec3(t, h, w), grey)
	box("room_far", Vec3(0, h / 2, -side * 4.2), Vec3(w, h, t), grey)
	local zc = side * 4.2
	local lo, hi = 1.6 - window / 2, 1.6 + window / 2
	box("wall_below", Vec3(0, lo / 2, zc), Vec3(w, lo, t), grey)
	box("wall_above", Vec3(0, (hi + h) / 2, zc), Vec3(w, h - hi, t), grey)
	local half = (w - window) / 2
	box("wall_left", Vec3(-(window / 2 + half / 2), 1.6, zc), Vec3(half, window, t), grey)
	box("wall_right", Vec3(window / 2 + half / 2, 1.6, zc), Vec3(half, window, t), grey)
	box("pillar", Vec3(-1.5, 1, 0), Vec3(0.6, 2, 0.6), white)
	box("crate", Vec3(1.5, 0.4, -side * 1.5), Vec3(0.8, 0.8, 0.8), white)
end

do
	local cam = render3d.GetCamera()
	cam:SetPosition(Vec3(0, 1.6, side * 2.5))
	cam:SetAngles(Deg3(-5, side > 0 and 0 or 180, 0))
	local rig = Entity.World:GetKeyed("player_camera_rig")

	if rig and rig:IsValid() then
		rig.transform:SetPosition(cam:GetPosition():Copy())

		if rig.player_input and rig.player_input.SyncFromCamera then
			rig.player_input:SyncFromCamera(cam)
		end
	end
end
