local T = import("test/environment.lua")
local Entity = import("goluwa/entities/entity.lua")
local physics = import("goluwa/physics.lua")
local BoxShape = import("goluwa/physics/shapes/box.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
Entity.RegisterComponent("character_movement", import("lua/components/character_movement.lua"))
Entity.RegisterComponent("ai_controller", import("lua/components/ai_controller.lua"))
Entity.RegisterComponent("player_controller", import("lua/components/player_controller.lua"))
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

T.TestPhysics("a pinned character ignores lunges and pushes until the pin runs out", function()
	local entity = Entity.New{
		ComponentSet = {"transform", "ai_controller", "character_pose", "health"},
		transform = {Position = Vec3(0, 0.05, 0)},
		ai_controller = {Wander = false},
	}
	local movement = entity.character_movement
	movement:Pin(0.2)
	movement:Lunge(Vec3(0, 0, -1), 0.5, 0, 0.15)
	movement:Push(Vec3(0, 0, -3))
	T(movement.lunge)["=="](nil)
	T(movement.push)["=="](nil)
	run(0.5)
	movement:Lunge(Vec3(0, 0, -1), 0.5, 0, 0.15)
	T(movement.lunge ~= nil)["=="](true)
	entity:Remove()
end)

T.TestPhysics("a driven player in fly mode follows the drive target", function()
	local player = Entity.New{
		ComponentSet = {
			"transform",
			"player_controller",
			"character_movement",
			"character_pose",
			"health",
		},
		transform = {Position = Vec3(0, 5, 0)},
		player_controller = {Source = "queue"},
		health = {Health = 100, MaxHealth = 100},
	}
	player.player_controller.cmd.mode = "fly"
	player.character_movement:TeleportTo(Vec3(0, 5, 0))
	run(0.3)
	local start = player.transform:GetPosition():Copy()

	for _ = 1, 30 do
		player.character_movement:Drive(player.rigid_body:GetPosition() + Vec3(0.05, 0, 0))
		run(1 / 60)
	end

	T(player.transform:GetPosition().x - start.x)[">"](0.5)
	player:Remove()
end)
