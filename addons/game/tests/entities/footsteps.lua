local T = import("test/environment.lua")
local Entity = import("goluwa/entities/entity.lua")
local event = import("goluwa/event.lua")
local physics = import("goluwa/physics.lua")
local steam = import("goluwa/steam/steam.lua")
local vfs = import("goluwa/vfs.lua")
local Matrix44 = import("goluwa/structs/matrix44.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local BoxShape = import("goluwa/physics/shapes/box.lua")
local biped = import("lua/biped.lua")
local eye_pose = import("lua/eye_pose.lua")
Entity.RegisterComponent("character_movement", import("lua/components/character_movement.lua"))
Entity.RegisterComponent("ai_controller", import("lua/components/ai_controller.lua"))
Entity.RegisterComponent("usable", import("lua/components/usable.lua"))
Entity.RegisterComponent("weapon_holder", import("lua/components/weapon_holder.lua"))
Entity.RegisterComponent("weapon", import("lua/components/weapon.lua"))
import("addons/game/lua/autorun/characters.lua")
import("lua/weapons.lua")
local npcs = import("lua/npcs.lua")

local function create_floor()
	return Entity.New{
		transform = {Position = Vec3(0, -0.5, 0), Scale = Vec3(60, 1, 60)},
		rigid_body = {
			MotionType = "static",
			WorldGeometry = true,
			Shape = BoxShape.New(Vec3(1, 1, 1)),
		},
	}
end

local function record_impacts(entity)
	local impacts = {}

	event.AddListener("Impact", "footsteps_test", function(info)
		if info.Entity == entity then impacts[#impacts + 1] = info end
	end)

	return impacts
end

local function check_steps(impacts, floor, min_speed, max_speed)
	for i, info in ipairs(impacts) do
		T(info.Kind)["=="]("footstep")
		T(info.Surface)["=="]("default")
		T(info.Other)["=="](floor)
		T(math.abs(info.Position.y) < 0.01)["=="](true)
		T(info.Speed > min_speed and info.Speed < max_speed)["=="](true)

		if i > 1 then T(info.Part ~= impacts[i - 1].Part)["=="](true) end
	end
end

T.TestPhysics("the eye body fires a footstep impact each time a foot plants, alternating feet", function()
	local floor = create_floor()
	local owner = Entity.New{transform = {Position = Vec3(0, 0, 0)}, character_pose = {}}
	local bones = {}

	for _, entry in ipairs(biped.Bones) do
		bones[entry[1]] = Matrix44():Identity()
	end

	local state = eye_pose.New()
	local impacts = record_impacts(owner)

	for frame = 1, 180 do
		owner.transform:SetPosition(Vec3(0, 0, -frame / 60 * 1.5))
		owner.character_pose:OnUpdate(1 / 60)
		eye_pose.Compute(state, bones, owner, 1 / 60)
	end

	event.RemoveListener("Impact", "footsteps_test")
	T(#impacts >= 8)["=="](true)
	check_steps(impacts, floor, 0.5, 3)
end)

T.Test3D("a walking source npc fires alternating footstep impacts from its foot ik", function()
	steam.MountSourceGame("gmod")

	if not vfs.IsFile("models/humans/group01/male_01.mdl") then
		return T.Unavailable("gmod content not mounted")
	end

	if not physics.instance then physics.Initialize() end

	local floor = create_floor()
	local entity = npcs.Spawn("citizen", Vec3(0, 0.05, 0), 0)
	entity.ai_controller:SetWander(false)
	local impacts = record_impacts(entity)

	T.WaitUntil(function()
		return entity.animator and entity.animator:GetRig() ~= nil
	end, 30)

	entity.ai_controller:MoveTo(Vec3(0, 0, -20), false)

	T.WaitUntil(function()
		return #impacts >= 6
	end, 20)

	event.RemoveListener("Impact", "footsteps_test")
	check_steps(impacts, floor, 0.3, 4)
	entity:Remove()
	floor:Remove()
end)
