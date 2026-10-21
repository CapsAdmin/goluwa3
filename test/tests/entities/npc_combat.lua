local T = import("test/environment.lua")
local Entity = import("goluwa/entities/entity.lua")
local physics = import("goluwa/physics.lua")
local BoxShape = import("goluwa/physics/shapes/box.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
Entity.RegisterComponent("character_movement", import("lua/components/character_movement.lua"))
Entity.RegisterComponent("ai_controller", import("lua/components/ai_controller.lua"))
Entity.RegisterComponent("player_controller", import("lua/components/player_controller.lua"))
Entity.RegisterComponent("weapon", import("lua/components/weapon.lua"))
Entity.RegisterComponent("weapon_holder", import("lua/components/weapon_holder.lua"))
import("lua/weapons.lua")
import("lua/damage.lua")

local function create_ground()
	return Entity.New{
		transform = {Position = Vec3(0, -0.5, 0), Scale = Vec3(300, 1, 300)},
		rigid_body = {MotionType = "static", Shape = BoxShape.New(Vec3(1, 1, 1))},
	}
end

local function run(seconds)
	for _ = 1, seconds * 60 do
		physics.UpdateFixed(1 / 60)
	end
end

local function create_gunman(position)
	local entity = Entity.New{
		ComponentSet = {"transform", "ai_controller", "weapon_holder", "health"},
		transform = {Position = position:Copy()},
		ai_controller = {Wander = false, WalkSpeed = 3},
	}
	entity.ai_controller:Teleport(position, 0)
	entity.weapon_holder:Give("weapon_pistol")
	return entity
end

local function create_target(position)
	local player = Entity.New{
		ComponentSet = {"transform", "player_controller", "character_movement", "health"},
		transform = {Position = position:Copy()},
		player_controller = {Source = "queue"},
	}
	player.player_controller.cmd.mode = "walk"
	player.character_movement:TeleportTo(position)
	return player
end

T.TestPhysics("npc with a weapon turns to and shoots a player in range", function()
	create_ground()
	local gunman = create_gunman(Vec3(0, 0.05, 0))
	local player = create_target(Vec3(6, 0.05, 0))
	run(4)
	T(player.health.Health < player.health.MaxHealth)["=="](true)
	local forward = gunman.transform:GetRotation():GetForward()
	T(forward.x > 0.9)["=="](true)
end)

T.TestPhysics("npc with a weapon leaves a player out of range alone", function()
	create_ground()
	create_gunman(Vec3(0, 0.05, 0))
	local player = create_target(Vec3(40, 0.05, 0))
	run(4)
	T(player.health.Health)["=="](player.health.MaxHealth)
end)

T.TestPhysics("npc without a weapon does not shoot", function()
	create_ground()
	local gunman = create_gunman(Vec3(0, 0.05, 0))
	gunman.weapon_holder:GetActiveWeapon():Remove()
	local player = create_target(Vec3(6, 0.05, 0))
	run(4)
	T(player.health.Health)["=="](player.health.MaxHealth)
end)
