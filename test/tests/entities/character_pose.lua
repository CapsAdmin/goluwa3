local T = import("test/environment.lua")
local Entity = import("goluwa/entities/entity.lua")
local Armature = import("goluwa/entities/components/armature.lua")
local physics = import("goluwa/physics.lua")
local usercmd = import("goluwa/network/usercmd.lua")
local BoxShape = import("goluwa/physics/shapes/box.lua")
local Quat = import("goluwa/structs/quat.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local biped = import("lua/biped.lua")
import("addons/game/lua/autorun/characters.lua")
Entity.RegisterComponent("player_controller", import("lua/components/player_controller.lua"))
Entity.RegisterComponent("character_movement", import("lua/components/character_movement.lua"))

local function create_ground()
	return Entity.New{
		transform = {Position = Vec3(0, -0.5, 0), Scale = Vec3(100, 1, 100)},
		rigid_body = {MotionType = "static", Shape = BoxShape.New(Vec3(1, 1, 1))},
	}
end

local function create_character()
	local entity = Entity.New{
		ComponentSet = {"transform", "player_controller", "character_movement", "character_pose"},
		transform = {Position = Vec3(0, 0.05, 0)},
		player_controller = {Source = "queue"},
	}
	entity.player_controller.cmd.mode = "walk"
	entity.player_controller.cmd.buttons = usercmd.BUTTON.ACTIVE
	return entity
end

T.TestPhysics("character pose follows the pitch of the command view and not its yaw", function()
	create_ground()
	local character = create_character()
	local cmd = character.player_controller.cmd
	cmd.view = Quat(0, 0, 0, 1):RotatePitch(math.rad(30))

	for _ = 1, 30 do
		physics.UpdateFixed(1 / 60)
		character.character_pose:OnUpdate(1 / 60)
	end

	local forward = character.character_pose.pitch:GetForward()
	T(forward.y)["~"](math.sin(math.rad(30)), 0.01)
	T(math.abs(forward.x) < 0.01)["=="](true)
	T(character.character_pose.crouch_alpha)["=="](0)
	character.player_controller.cmd.buttons = usercmd.BUTTON.ACTIVE + usercmd.BUTTON.CROUCH

	for _ = 1, 30 do
		physics.UpdateFixed(1 / 60)
		character.character_pose:OnUpdate(1 / 60)
	end

	T(character.character_pose:IsCrouching())["=="](true)
	T(character.character_pose.crouch_alpha > 0.9)["=="](true)
	character:Remove()
end)

T.Test("an attachment_points component puts its profile sockets on the armature when it is built", function()
	local owner = Entity.New{transform = {}, attachment_points = {}}
	T(owner.armature == nil)["=="](true)
	owner:AddComponent("armature")
	owner.armature:SetSkeleton(biped.SkeletonName)
	T(#owner.armature:GetSocketNames())["=="](6)
	T(owner.armature:GetBoneMatrix("grip_r") ~= nil)["=="](true)
	owner:Remove()
	local early = Entity.New{transform = {}}
	early:AddComponent("armature")
	early.armature:SetSkeleton(biped.SkeletonName)
	early:AddComponent("attachment_points")
	T(#early.armature:GetSocketNames())["=="](6)
	early:Remove()
end)
