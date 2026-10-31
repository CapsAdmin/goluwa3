local T = import("test/environment.lua")
local Entity = import("goluwa/entities/entity.lua")
local physics = import("goluwa/physics.lua")
local BoxShape = import("goluwa/physics/shapes/box.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Quat = import("goluwa/structs/quat.lua")
Entity.RegisterComponent("character_movement", import("lua/components/character_movement.lua"))
Entity.RegisterComponent("ai_controller", import("lua/components/ai_controller.lua"))
import("addons/game/lua/autorun/characters.lua")
local grab = import("lua/grab.lua")
local actors = import("lua/actors.lua")

local function run(seconds)
	for _ = 1, seconds * 60 do
		physics.UpdateFixed(1 / 60)
	end
end

local function create_character(position)
	local entity = Entity.New{
		ComponentSet = {"transform", "ai_controller", "character_pose", "health"},
		transform = {Position = position:Copy()},
		ai_controller = {Wander = false},
	}
	entity.ai_controller:Teleport(position, 0)
	return entity
end

local function create_ground()
	Entity.New{
		transform = {Position = Vec3(0, -0.5, 0), Scale = Vec3(100, 1, 100)},
		rigid_body = {
			MotionType = "static",
			WorldGeometry = true,
			Shape = BoxShape.New(Vec3(1, 1, 1)),
		},
	}
end

T.TestPhysics("a latched character follows the grabber's frame and is thrown on release", function()
	create_ground()
	local grabber = create_character(Vec3(0, 0.05, 0))
	local victim = create_character(Vec3(0, 0.05, -2))
	run(0.5)
	local latch = grab.Latch(grabber, victim, {Offset = Vec3(0, 1, -1), Rotation = Quat(0, 0, 0, 1)})
	T(grab.IsHeld(victim))["=="](true)
	T(grabber.character_pose.grab_latch)["=="](latch)
	T(grab.Latch(grabber, victim, {}))["=="](nil)
	run(0.3)
	local position = victim.transform:GetPosition()
	T(position.y - grabber.transform:GetPosition().y)["~"](1, 1e-3)
	T(position.z - grabber.transform:GetPosition().z)["~"](-1, 1e-3)
	grabber.transform:SetPosition(Vec3(2, 0.05, 0))
	grabber.rigid_body:SynchronizeFromTransform()
	run(0.2)
	T(victim.transform:GetPosition().x)["~"](2, 1e-2)
	grab.Release(victim, Vec3(0, 0, -6))
	T(grab.IsHeld(victim))["=="](false)
	T(grabber.character_pose.grab_latch)["=="](nil)
	run(0.2)
	T(victim.rigid_body:GetVelocity().z < -1)["=="](true)
end)

T.TestPhysics("a latch lets go when the grabber dies", function()
	create_ground()
	local grabber = create_character(Vec3(0, 0.05, 0))
	local victim = create_character(Vec3(0, 0.05, -2))
	run(0.5)
	grab.Latch(grabber, victim, {Offset = Vec3(0, 1, -1), Rotation = Quat(0, 0, 0, 1)})
	run(0.1)
	T(grab.IsHeld(victim))["=="](true)
	grabber.health:SetHealth(0)
	run(0.1)
	T(grab.IsHeld(victim))["=="](false)
end)

T.TestPhysics("a latched character is kept above the floor and out of walls and reports being blocked", function()
	create_ground()
	Entity.New{
		transform = {Position = Vec3(0, 1, -3), Scale = Vec3(4, 2, 0.4)},
		rigid_body = {
			MotionType = "static",
			WorldGeometry = true,
			Shape = BoxShape.New(Vec3(1, 1, 1)),
		},
	}
	local grabber = create_character(Vec3(0, 0.05, 0))
	local victim = create_character(Vec3(0, 0.05, -1.5))
	run(0.5)
	local blocked = 0

	grabber:AddLocalListener("OnLatchBlocked", function()
		blocked = blocked + 1
	end)

	local latch = grab.Latch(grabber, victim, {Offset = Vec3(0, 0, -1.5), Rotation = Quat(0, 0, 0, 1)})
	run(0.2)
	latch.Offset:Set(0, -3, -1.5)
	run(0.3)
	T(victim.transform:GetPosition().y > -0.05)["=="](true)
	T(blocked > 0)["=="](true)
	latch.Offset:Set(0, 0.5, -4)
	run(0.3)
	local wall_face = -3 + 0.2
	T(actors.GetCenter(victim).z > wall_face)["=="](true)
	local radius = victim.character_movement:GetRadius()
	T(actors.GetCenter(victim).z - wall_face > radius * 0.9)["=="](true)
	latch.Offset:Set(0, 0.5, -1.5)
	run(0.3)
	T(victim.transform:GetPosition().z)["~"](-1.5, 0.05)
	grab.Release(victim, Vec3())
	run(0.5)
	T(victim.transform:GetPosition().y > -0.05)["=="](true)
end)
