local T = import("test/environment.lua")
local Entity = import("goluwa/entities/entity.lua")
local Armature = import("goluwa/entities/components/armature.lua")
local physics = import("goluwa/physics.lua")
local usercmd = import("goluwa/network/usercmd.lua")
local BoxShape = import("goluwa/physics/shapes/box.lua")
local Quat = import("goluwa/structs/quat.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local biped = import("lua/biped.lua")
local pose_variation = import("lua/pose_variation.lua")
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

pose_variation.SwayPitch = 0
pose_variation.SwayYaw = 0

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
	character.player_controller.cmd.view = Quat(0, 0, 0, 1):RotateYaw(math.rad(110)):RotatePitch(math.rad(30))

	for _ = 1, 30 do
		physics.UpdateFixed(1 / 60)
		character.character_pose:OnUpdate(1 / 60)
	end

	forward = character.character_pose.pitch:GetForward()
	T(forward.y)["~"](math.sin(math.rad(30)), 0.01)
	T(math.abs(forward.x) < 0.01)["=="](true)
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
	T(#owner.armature:GetSocketNames())["=="](8)
	T(owner.armature:GetBoneMatrix("grip_r") ~= nil)["=="](true)
	owner:Remove()
	local early = Entity.New{transform = {}}
	early:AddComponent("armature")
	early.armature:SetSkeleton(biped.SkeletonName)
	early:AddComponent("attachment_points")
	T(#early.armature:GetSocketNames())["=="](8)
	early:Remove()
end)

T.Test("a source pose can be removed after the pose it drives", function()
	local character = Entity.New{
		ComponentSet = {"transform", "character_pose", "source_pose"},
		transform = {},
	}
	character.source_pose.character = character
	character.character_pose.driver = character.source_pose
	character:RemoveComponent("character_pose")
	character:Remove()
	T(character:IsValid())["=="](false)
end)

T.TestPhysics("a character leans into its acceleration and stands up again at a steady speed", function()
	create_ground()
	local character = create_character()
	local pose = character.character_pose
	local controller = character.player_controller
	local number = 0

	local function run(frames, forward)
		for _ = 1, frames do
			number = number + 1
			local cmd = usercmd.New()
			cmd.number = number
			cmd.mode = "walk"
			cmd.buttons = usercmd.BUTTON.ACTIVE
			cmd.forward = forward
			controller:PushCommands({cmd})
			physics.UpdateFixed(1 / 60)
			pose:OnUpdate(1 / 60)
		end
	end

	run(30, 0)
	T(math.abs(pose.lean_forward))["<"](0.01)
	T(math.abs(pose.lean_side))["<"](0.01)
	local peak = 0

	for _ = 1, 30 do
		run(1, 1)
		peak = math.max(peak, pose.lean_forward)
	end

	T(peak)[">"](0.02)
	T(peak)["<="](pose_variation.MaxLean + 1e-6)
	run(240, 1)
	T(math.abs(pose.lean_forward))["<"](0.02)
	local lowest = 0

	for _ = 1, 30 do
		run(1, 0)
		lowest = math.min(lowest, pose.lean_forward)
	end

	T(lowest)["<"](-0.02)
	character:Remove()
end)

T.Test("a character without a movement follows the replicated lean and takes its seed from its network identity", function()
	local entity = Entity.New{ComponentSet = {"transform", "character_pose"}, transform = {}}
	local pose = entity.character_pose
	T(pose.Network.LeanSide ~= nil)["=="](true)
	T(pose.Network.LeanForward ~= nil)["=="](true)
	pose:SetLeanSide(0.15)
	pose:SetLeanForward(-0.1)

	for _ = 1, 120 do
		pose:OnUpdate(1 / 60)
	end

	T(pose.lean_side)["~"](0.15, 0.005)
	T(pose.lean_forward)["~"](-0.1, 0.005)
	local network = {owner = "uid-1", id = -1}
	entity.network = {
		GetNetworkOwner = function()
			return network.owner
		end,
		GetNetworkId = function()
			return network.id
		end,
	}
	pose:OnUpdate(1 / 60)
	local seed = pose.seed
	T(seed)["=="](pose_variation.HashSeed("uid-1"))
	T(pose.rate_scale)["=="](pose_variation.GetRateScale(seed))
	network.owner = ""
	pose:OnUpdate(1 / 60)
	T(pose.seed)["=="](seed)
	network.id = 7
	pose:OnUpdate(1 / 60)
	T(pose.seed)["=="](pose_variation.HashSeed(7))
	entity.network = nil
	entity:Remove()
end)

T.TestPhysics("the pose of a simulated character takes its distance from the movement and a remote one follows the replicated distance", function()
	create_ground()
	local character = create_character()
	local pose = character.character_pose
	character.character_movement.distance = 12.5
	pose:OnUpdate(1 / 60)
	T(pose.Distance)["=="](12.5)
	character:Remove()
	local remote = Entity.New{ComponentSet = {"transform", "character_pose"}, transform = {}}
	remote.character_pose:SetDistance(33)
	remote.character_pose:OnUpdate(1 / 60)
	T(remote.character_pose.Distance)["=="](33)
	T(remote.character_pose.Network.Distance ~= nil)["=="](true)
	remote:Remove()
end)
