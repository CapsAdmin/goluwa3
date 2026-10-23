local T = import("test/environment.lua")
local Entity = import("goluwa/entities/entity.lua")
local physics = import("goluwa/physics.lua")
local BoxShape = import("goluwa/physics/shapes/box.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local usercmd = import("goluwa/network/usercmd.lua")
Entity.RegisterComponent("character_movement", import("lua/components/character_movement.lua"))
Entity.RegisterComponent("ai_controller", import("lua/components/ai_controller.lua"))
Entity.RegisterComponent("player_controller", import("lua/components/player_controller.lua"))
Entity.RegisterComponent("weapon", import("lua/components/weapon.lua"))
Entity.RegisterComponent("weapon_holder", import("lua/components/weapon_holder.lua"))
import("lua/weapons.lua")
import("lua/damage.lua")
import("addons/game/lua/autorun/characters.lua")

local function create_ground()
	return Entity.New{
		transform = {Position = Vec3(0, -0.5, 0), Scale = Vec3(300, 1, 300)},
		rigid_body = {MotionType = "static", WorldGeometry = true, Shape = BoxShape.New(Vec3(1, 1, 1))},
	}
end

local function run(seconds)
	for _ = 1, seconds * 60 do
		physics.UpdateFixed(1 / 60)
	end
end

local function create_gunman(position)
	local entity = Entity.New{
		ComponentSet = {"transform", "ai_controller", "character_pose", "weapon_holder", "health"},
		transform = {Position = position:Copy()},
		ai_controller = {Wander = false, WalkSpeed = 3},
	}
	entity.ai_controller:Teleport(position, 0)
	entity.weapon_holder:Give("weapon_pistol")
	return entity
end

local function create_target(position)
	local player = Entity.New{
		ComponentSet = {"transform", "player_controller", "character_movement", "character_pose", "health"},
		transform = {Position = position:Copy()},
		player_controller = {Source = "queue"},
		health = {Health = 1000, MaxHealth = 1000},
	}
	player.player_controller.cmd.mode = "walk"
	player.character_movement:TeleportTo(position)
	return player
end

T.TestPhysics("npc with a weapon turns to and shoots a player in range", function()
	create_ground()
	local gunman = create_gunman(Vec3(0, 0.05, 0))
	local player = create_target(Vec3(6, 0.05, 0))
	run(2)
	T(player.health.Health < player.health.MaxHealth)["=="](true)
	local forward = gunman.transform:GetRotation():GetForward()
	T(forward.x > 0.9)["=="](true)
	gunman.character_pose:OnUpdate(1 / 60)
	T(gunman.character_pose.pitch:GetForward().y < 0)["=="](true)
	T(gunman.character_pose.Shots > 0)["=="](true)
	T(player.character_pose.Hits > 0)["=="](true)
	player.character_pose:OnUpdate(1 / 60)
	T(player.character_pose.flinch > 0)["=="](true)
	gunman.character_pose:OnUpdate(1 / 60)
	T(gunman.character_pose.recoil > 0.5)["=="](true)
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

T.TestPhysics("an armed npc with nothing to shoot at wanders", function()
	create_ground()
	local gunman = create_gunman(Vec3(0, 0.05, 0))
	gunman.ai_controller:SetWander(true)
	gunman.ai_controller:SetWanderMinDelay(0)
	gunman.ai_controller:SetWanderMaxDelay(0.1)
	local moved = false

	for _ = 1, 30 * 60 do
		physics.UpdateFixed(1 / 60)

		if gunman.transform:GetPosition():Distance(Vec3(0, 0, 0)) > 3 then
			moved = true

			break
		end
	end

	T(moved)["=="](true)
end)

T.TestPhysics("a physgun is held by an npc as it is by a player", function()
	create_ground()
	local gunman = create_gunman(Vec3(0, 0.05, 0))
	local physgun = gunman.weapon_holder:Give("weapon_physgun")
	gunman.weapon_holder:Select(physgun)
	local crate = Entity.New{
		transform = {Position = Vec3(0, 1.2, -4)},
		rigid_body = {Shape = BoxShape.New(Vec3(1, 1, 1))},
	}
	local cmd = usercmd.New()
	cmd.buttons = usercmd.BUTTON.ACTIVE + usercmd.BUTTON.ATTACK1

	for _ = 1, 10 do
		physics.UpdateFixed(1 / 60)
		physgun.weapon_physgun:OnWeaponThink(1 / 60, cmd)
	end

	T(physgun.weapon_physgun.held_body == crate.rigid_body)["=="](true)
	T(gunman.character_pose:IsHolding())["=="](true)
	cmd.buttons = usercmd.BUTTON.ACTIVE
	physgun.weapon_physgun:OnWeaponThink(1 / 60, cmd)
	T(gunman.character_pose:IsHolding())["=="](false)
end)
