local T = import("test/environment.lua")
local Entity = import("goluwa/entities/entity.lua")
local physics = import("goluwa/physics.lua")
local BoxShape = import("goluwa/physics/shapes/box.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
Entity.RegisterComponent("character_movement", import("lua/components/character_movement.lua"))
Entity.RegisterComponent("ai_controller", import("lua/components/ai_controller.lua"))
import("addons/game/lua/autorun/characters.lua")

local function run(seconds)
	for _ = 1, seconds * 60 do
		physics.UpdateFixed(1 / 60)
	end
end

T.TestPhysics("a lunge waits for its delay, then covers its distance over its duration", function()
	Entity.New{
		transform = {Position = Vec3(0, -0.5, 0), Scale = Vec3(100, 1, 100)},
		rigid_body = {
			MotionType = "static",
			WorldGeometry = true,
			Shape = BoxShape.New(Vec3(1, 1, 1)),
		},
	}
	local entity = Entity.New{
		ComponentSet = {"transform", "ai_controller", "character_pose", "health"},
		transform = {Position = Vec3(0, 0.05, 0)},
		ai_controller = {Wander = false},
	}
	entity.ai_controller:Teleport(Vec3(0, 0.05, 0), 0)
	run(1)
	local start = entity.transform:GetPosition():Copy()
	entity.character_movement:Lunge(Vec3(0, 0, -1), 0.5, 0.3, 0.15)
	run(0.25)
	T((entity.transform:GetPosition() - start):GetLength())["<"](0.01)
	run(1)
	local moved = (entity.transform:GetPosition() - start):GetLength()
	T(moved)[">"](0.45)
	T(moved)["<"](0.7)
	T(entity.character_movement.lunge)["=="](nil)
	entity:Remove()
end)

T.TestPhysics("a lunge or a drive into a wall deals no impact damage", function()
	Entity.New{
		transform = {Position = Vec3(0, -0.5, 0), Scale = Vec3(100, 1, 100)},
		rigid_body = {
			MotionType = "static",
			WorldGeometry = true,
			Shape = BoxShape.New(Vec3(1, 1, 1)),
		},
	}
	Entity.New{
		transform = {Position = Vec3(0, 1, -2.5), Scale = Vec3(10, 3, 0.5)},
		rigid_body = {
			MotionType = "static",
			WorldGeometry = true,
			Shape = BoxShape.New(Vec3(1, 1, 1)),
		},
	}
	local entity = Entity.New{
		ComponentSet = {"transform", "ai_controller", "character_pose", "health"},
		transform = {Position = Vec3(0, 0.05, 0)},
		ai_controller = {Wander = false},
		health = {Health = 100, MaxHealth = 100},
	}
	entity.ai_controller:Teleport(Vec3(0, 0.05, 0), 0)
	run(1)
	entity.character_movement:Lunge(Vec3(0, 0, -1), 8, 0, 0.4)
	run(1.5)
	T(entity.health:GetHealth())["=="](100)
	entity:Remove()
end)
