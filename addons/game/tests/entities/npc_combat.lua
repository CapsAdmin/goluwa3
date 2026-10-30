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
local damage = import("lua/damage.lua")
local movesets = import("lua/movesets.lua")
import("addons/game/lua/autorun/characters.lua")

local function create_ground()
	return Entity.New{
		transform = {Position = Vec3(0, -0.5, 0), Scale = Vec3(300, 1, 300)},
		rigid_body = {
			MotionType = "static",
			WorldGeometry = true,
			Shape = BoxShape.New(Vec3(1, 1, 1)),
		},
	}
end

local function run(seconds)
	for _ = 1, seconds * 60 do
		physics.UpdateFixed(1 / 60)
	end
end

local function create_gunman(position, faction)
	local entity = Entity.New{
		ComponentSet = {"transform", "ai_controller", "character_pose", "weapon_holder", "health"},
		transform = {Position = position:Copy()},
		ai_controller = {Wander = false, WalkSpeed = 3, Faction = faction},
		health = {Health = 1000, MaxHealth = 1000},
	}
	entity.ai_controller:Teleport(position, 0)
	entity.weapon_holder:Give("weapon_pistol")
	return entity
end

local function create_target(position)
	local player = Entity.New{
		ComponentSet = {
			"transform",
			"player_controller",
			"character_movement",
			"character_pose",
			"health",
		},
		transform = {Position = position:Copy()},
		player_controller = {Source = "queue"},
		health = {Health = 1000, MaxHealth = 1000},
	}
	player.player_controller.cmd.mode = "walk"
	player.character_movement:TeleportTo(position)
	return player
end

movesets.Register("test_bite", {Moves = {bite = {Duration = 0.5, Keys = {}, Events = {{At = 0.4, Type = "strike", Damage = 10, Range = 2}}}}})

T.TestPhysics("an unarmed npc chases a player and hurts it with its moves", function()
	create_ground()
	local biter = Entity.New{
		ComponentSet = {"transform", "ai_controller", "character_pose", "health"},
		transform = {Position = Vec3(0, 0.05, 0)},
		ai_controller = {
			Wander = false,
			WalkSpeed = 3,
			Moveset = "test_bite",
			Attacks = {{Move = "bite", Range = 1.5, Interval = 1}},
		},
		health = {Health = 1000, MaxHealth = 1000},
	}
	biter.ai_controller:Teleport(Vec3(0, 0.05, 0), 0)
	local player = create_target(Vec3(6, 0.05, 0))
	run(1)
	T(player.health.Health)["=="](player.health.MaxHealth)
	run(5)
	T(player.health.Health < player.health.MaxHealth)["=="](true)
	T((player.health.MaxHealth - player.health.Health) % 10)["=="](0)
	T(biter.move_runner ~= nil)["=="](true)
end)

movesets.Register(
	"test_charge",
	{
		Moves = {
			windup = {Duration = 0.3, Keys = {}, Next = "run"},
			run = {
				Duration = 2,
				Keys = {},
				Speed = 8,
				Crash = "crash",
				Next = "stop",
				Events = {{At = 0.03, Until = 1, Type = "strike", Damage = 50, Range = 2, Force = 10}},
			},
			stop = {Duration = 0.3, Keys = {}},
			crash = {Duration = 0.3, Keys = {}},
		},
	}
)

local function create_charger()
	local charger = Entity.New{
		ComponentSet = {"transform", "ai_controller", "character_pose", "health"},
		transform = {Position = Vec3(0, 0.05, 0)},
		ai_controller = {
			Wander = false,
			WalkSpeed = 3,
			Moveset = "test_charge",
			AttackRange = 25,
			Attacks = {{Move = "windup", Range = 20, MinRange = 6, Interval = 30}},
		},
		health = {Health = 1000, MaxHealth = 1000},
	}
	charger.ai_controller:Teleport(Vec3(0, 0.05, 0), 0)
	return charger
end

local function run_until_move(charger, name, seconds)
	for _ = 1, seconds * 60 do
		physics.UpdateFixed(1 / 60)
		local move = charger.move_runner and charger.move_runner.move

		if move and move.Action == "test_charge_" .. name then return true end
	end

	return false
end

T.TestPhysics("a charging npc runs at a player, hurts it once and stops", function()
	create_ground()
	local charger = create_charger()
	local player = create_target(Vec3(14, 0.05, 0))
	T(run_until_move(charger, "run", 3))["=="](true)
	T(run_until_move(charger, "stop", 4))["=="](true)
	T(player.health.MaxHealth - player.health.Health)["=="](50)
end)

T.TestPhysics("a charging npc that runs into a wall crashes instead", function()
	create_ground()
	Entity.New{
		transform = {Position = Vec3(6, 0.5, 0), Scale = Vec3(0.5, 1, 20)},
		rigid_body = {MotionType = "static", WorldGeometry = true, Shape = BoxShape.New(Vec3(1, 1, 1))},
	}
	local charger = create_charger()
	local player = create_target(Vec3(14, 0.05, 0))
	T(run_until_move(charger, "run", 3))["=="](true)
	T(run_until_move(charger, "crash", 4))["=="](true)
	T(player.health.Health)["=="](player.health.MaxHealth)
end)

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
	T(player.character_pose:GetWeight("flinch") > 0)["=="](true)
	gunman.character_pose:OnUpdate(1 / 60)
	T(gunman.character_pose:GetWeight("recoil") > 0.5)["=="](true)
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
	gunman.weapon_holder:GetWeapon("right"):Remove()
	local player = create_target(Vec3(6, 0.05, 0))
	run(4)
	T(player.health.Health)["=="](player.health.MaxHealth)
end)

T.TestPhysics("a friendly npc does not shoot a player", function()
	create_ground()
	create_gunman(Vec3(0, 0.05, 0), "friend")
	local player = create_target(Vec3(6, 0.05, 0))
	run(4)
	T(player.health.Health)["=="](player.health.MaxHealth)
end)

T.TestPhysics("friendly and enemy npcs shoot each other", function()
	create_ground()
	local friend = create_gunman(Vec3(0, 0.05, 0), "friend")
	local enemy = create_gunman(Vec3(6, 0.05, 0), "enemy")
	run(4)
	T(friend.health.Health < friend.health.MaxHealth)["=="](true)
	T(enemy.health.Health < enemy.health.MaxHealth)["=="](true)
end)

T.TestPhysics("npcs of the same faction leave each other alone", function()
	create_ground()
	local first = create_gunman(Vec3(0, 0.05, 0), "enemy")
	local second = create_gunman(Vec3(6, 0.05, 0), "enemy")
	run(4)
	T(first.health.Health)["=="](first.health.MaxHealth)
	T(second.health.Health)["=="](second.health.MaxHealth)
end)

T.TestPhysics("an armed npc with nothing to shoot at wanders", function()
	create_ground()
	local gunman = create_gunman(Vec3(0, 0.05, 0), "friend")
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
	gunman.weapon_holder:Equip(physgun, "right")
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

T.TestPhysics("an unarmed npc that retaliates follows whoever hit it, stops two meters away and keeps aiming at it", function()
	create_ground()
	local npc = Entity.New{
		ComponentSet = {"transform", "ai_controller", "character_pose", "health"},
		transform = {Position = Vec3(0, 0.05, 0)},
		ai_controller = {
			Wander = false,
			Retaliate = true,
			WalkSpeed = 3,
			RunSpeed = 5,
			Faction = "friend",
		},
		health = {Health = 1000, MaxHealth = 1000},
	}
	npc.ai_controller:Teleport(Vec3(0, 0.05, 0), 0)
	local player = create_target(Vec3(8, 0.05, 0))
	run(1)
	T(npc.transform:GetPosition().x)["<"](0.5)
	damage.Deal(npc, {Attacker = player, Damage = 1})
	run(6)
	local distance = (npc.transform:GetPosition() - player.transform:GetPosition()):GetLength()
	T(distance > 1.5 and distance < 2.6)["=="](true)
	T(npc.transform:GetRotation():GetForward().x > 0.9)["=="](true)
	npc.character_pose:OnUpdate(1 / 60)
	T(math.abs(npc.character_pose.pitch:GetForward().y) < 0.05)["=="](true)
	player.character_movement:TeleportTo(Vec3(8, 0.05, 6))
	run(6)
	T(npc.transform:GetPosition().z > 3)["=="](true)
	T(npc.transform:GetRotation():GetForward().z > 0.5)["=="](true)
end)
