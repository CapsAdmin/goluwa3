import("goluwa/physics.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local Entity = import("goluwa/ecs/entity.lua")
Entity.RegisterComponent("camera", import("lua/components/camera.lua"))
Entity.RegisterComponent("player_input", import("lua/components/player_input.lua"))
Entity.RegisterComponent("player_movement", import("lua/components/player_movement.lua"))

local current = Entity.World:GetKeyed("player_camera_rig")

if current and current:IsValid() then current:Remove() end

local cam = render3d.GetCamera()
local rig = Entity.New({
	Key = "player_camera_rig",
	Name = "player_camera_rig",
	ComponentSet = {
		"transform",
		"camera",
		"player_input",
		"player_movement",
	},
	camera = {
		Active = true,
	},
	player_input = {
		Mode = "fly",
	},
})

rig.transform:SetPosition(cam:GetPosition():Copy())
rig.player_input:SyncFromCamera(cam)