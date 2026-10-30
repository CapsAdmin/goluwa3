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
