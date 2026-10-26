local T = import("test/environment.lua")
local Entity = import("goluwa/entities/entity.lua")
local physics = import("goluwa/physics.lua")
local BoxShape = import("goluwa/physics/shapes/box.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Quat = import("goluwa/structs/quat.lua")
import("addons/game/lua/autorun/characters.lua")
Entity.RegisterComponent("player_controller", import("lua/components/player_controller.lua"))
Entity.RegisterComponent("character_movement", import("lua/components/character_movement.lua"))

local function yaw_of(rotation)
	local forward = rotation:GetForward()
	return math.atan2(-forward.x, -forward.z)
end

T.TestPhysics("the body yaw reaches the render rotation at once without waiting for a physics step", function()
	local ground = Entity.New{
		transform = {Position = Vec3(0, -0.5, 0), Scale = Vec3(50, 1, 50)},
		rigid_body = {MotionType = "static", Shape = BoxShape.New(Vec3(1, 1, 1))},
	}
	local character = Entity.New{
		ComponentSet = {
			"transform",
			"player_controller",
			"character_movement",
			"character_pose",
			"health",
		},
		transform = {Position = Vec3(0, 0.05, 0)},
		player_controller = {Source = "queue"},
	}

	for _ = 1, 30 do
		physics.UpdateFixed(1 / 60)
	end

	local movement = character.character_movement

	for _, yaw in ipairs{0.3, 0.45, 0.46, -1.2} do
		movement:SetBodyYaw(Quat(0, 0, 0, 1):RotateYaw(yaw))
		local _, render = character.transform:GetRenderPositionRotation()
		T(yaw_of(render))["~"](yaw_of(character.transform:GetRotation()), 1e-6)
		T(yaw_of(character.rigid_body:GetRotation()))["~"](yaw_of(character.transform:GetRotation()), 1e-6)
	end

	character:Remove()
	ground:Remove()
end)
