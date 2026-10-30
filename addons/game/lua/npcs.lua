local prefab = import("goluwa/entities/prefab.lua")
local Entity = import("goluwa/entities/entity.lua")
local GridNav = import("goluwa/navigation/grid_nav.lua")
local commands = import("goluwa/cli/commands.lua")
local render3d = RENDER_3D and import("goluwa/render3d/render3d.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local UNIT = import("goluwa/source_engine/units.lua").meters
import("lua/damage.lua")
local outfit = import("lua/outfit.lua")
local movesets = import("lua/movesets.lua")
local PlayerController = import("lua/components/player_controller.lua")
local AIController = import("lua/components/ai_controller.lua")
local eyes = RENDER_3D and import("goluwa/entities/components/eyes.lua")
local npcs = {}

local function claw(clip, duration, delay, damage, range)
	return {
		Clip = clip,
		Duration = duration,
		Face = false,
		PoseWeapon = false,
		Events = {{At = delay / duration, Type = "strike", Damage = damage, Range = range}},
	}
end

local function cast(clip, duration, delay, element, damage)
	return {
		Clip = clip,
		Duration = duration,
		Face = false,
		PoseWeapon = false,
		Events = {{At = delay / duration, Type = "cast", Element = element, Damage = damage}},
	}
end
npcs.Factions = {"friend", "enemy"}
npcs.Definitions = {
	citizen = {
		Faction = "friend",
		Weapon = "weapon_pistol",
		Biped = true,
		Model = "models/humans/group01/male_01.mdl",
		Idle = "idle_subtle",
		Walk = "walk_all",
		Run = "run_all",
		WalkSpeed = 80,
		RunSpeed = 210,
	},
	barney = {
		Faction = "friend",
		Weapon = "weapon_pistol",
		Biped = true,
		Model = "models/barney.mdl",
		Idle = "idle_subtle",
		Walk = "walk_all",
		Run = "run_all",
		WalkSpeed = 80,
		RunSpeed = 210,
		Health = 200,
	},
	combine_soldier = {
		Faction = "enemy",
		Weapon = "weapon_pistol",
		Biped = true,
		Model = "models/combine_soldier.mdl",
		Idle = "Idle_Unarmed",
		Walk = "WalkEasy_all",
		Run = "RunALL",
		WalkSpeed = 78,
		RunSpeed = 215,
	},
	eye = {
		Faction = "friend",
		Weapon = "weapon_pistol",
		Biped = true,
		Outfit = outfit.DefaultName,
		Ragdoll = "eye",
		WalkSpeed = 80,
		RunSpeed = 210,
	},
	zombie = {
		Faction = "enemy",
		Model = "models/zombie/classic.mdl",
		Idle = "Idle01",
		Walk = "walk",
		Run = "walk",
		WalkSpeed = 45,
		RunSpeed = 45,
		Moves = {claw = claw("attackA", 1.26, 0.6, 18, 1.96)},
		Attacks = {{Move = "claw", Range = 1.4, Interval = 1.8}},
	},
	vortigaunt = {
		Faction = "enemy",
		Model = "models/vortigaunt.mdl",
		Idle = "Idle01",
		Walk = "Walk_all",
		Run = "Run_all",
		WalkSpeed = 44,
		RunSpeed = 140,
		Radius = 20,
		Height = 84,
		Moves = {zap = cast("zapattack1", 0.9, 0.5, "lightning", 20)},
		Attacks = {{Move = "zap", Range = 12, Interval = 2.5}},
	},
	antlion = {
		Faction = "enemy",
		Model = "models/antlion.mdl",
		Idle = "Idle",
		Walk = "walk_all",
		Run = "run_all",
		WalkSpeed = 195,
		RunSpeed = 355,
		Radius = 28,
		Height = 56,
		TurnSpeed = 12,
		Moves = {claw = claw("attack1", 0.84, 0.3, 12, 2.52)},
		Attacks = {{Move = "claw", Range = 1.8, Interval = 1.2}},
	},
	headcrab = {
		Faction = "enemy",
		Model = "models/headcrab.mdl",
		Idle = "Idle01",
		Walk = "Run1",
		Run = "Run1",
		WalkSpeed = 188,
		RunSpeed = 188,
		Radius = 6,
		Height = 14,
		TurnSpeed = 14,
		StepHeight = 8,
		Moves = {claw = claw("attack", 0.84, 0.3, 6, 1.26)},
		Attacks = {{Move = "claw", Range = 0.9, Interval = 1.2}},
	},
	citizen_female = {
		Faction = "friend",
		Weapon = "weapon_pistol",
		Biped = true,
		Model = "models/humans/group01/female_01.mdl",
		Idle = "idle_subtle",
		Walk = "walk_all",
		Run = "run_all",
		WalkSpeed = 80,
		RunSpeed = 210,
	},
	rebel = {
		Faction = "friend",
		Weapon = "weapon_pistol",
		Biped = true,
		Model = "models/humans/group03/male_01.mdl",
		Idle = "idle_subtle",
		Walk = "walk_all",
		Run = "run_all",
		WalkSpeed = 80,
		RunSpeed = 210,
	},
	alyx = {
		Faction = "friend",
		Weapon = "weapon_pistol",
		Biped = true,
		Model = "models/alyx.mdl",
		Idle = "idle_subtle",
		Walk = "walk_all",
		Run = "run_all",
		WalkSpeed = 80,
		RunSpeed = 210,
		Health = 300,
	},
	combine_elite = {
		Faction = "enemy",
		Weapon = "weapon_pistol",
		Biped = true,
		Model = "models/combine_super_soldier.mdl",
		Idle = "Idle_Unarmed",
		Walk = "WalkEasy_all",
		Run = "RunALL",
		WalkSpeed = 78,
		RunSpeed = 215,
		Health = 80,
	},
	breen = {
		Faction = "friend",
		Dummy = true,
		Retaliate = true,
		Biped = true,
		Model = "models/breen.mdl",
		Idle = "idle_subtle",
		Walk = "walk_all",
		Run = "run_all",
		WalkSpeed = 80,
		RunSpeed = 210,
		Health = 300,
	},
	zombie_fast = {
		Faction = "enemy",
		Model = "models/zombie/fast.mdl",
		Idle = "idle",
		Walk = "walk_all",
		Run = "Run",
		WalkSpeed = 55,
		RunSpeed = 218,
		Moves = {claw = claw("BR2_Attack", 0.7, 0.3, 10, 1.82)},
		Attacks = {{Move = "claw", Range = 1.3, Interval = 1.0}},
	},
	zombie_poison = {
		Faction = "enemy",
		Model = "models/zombie/poison.mdl",
		Idle = "Idle01",
		Walk = "Walk",
		Run = "Run",
		WalkSpeed = 56,
		RunSpeed = 154,
		Health = 120,
		Moves = {claw = claw("melee_01", 1.4, 0.5, 25, 2.1)},
		Attacks = {{Move = "claw", Range = 1.5, Interval = 2.0}},
	},
	monk = {
		Faction = "friend",
		Weapon = "weapon_pistol",
		Biped = true,
		Model = "models/monk.mdl",
		Idle = "idle_subtle",
		Walk = "walk_all",
		Run = "run_all",
		WalkSpeed = 80,
		RunSpeed = 209,
	},
	kleiner = {
		Faction = "friend",
		Weapon = "weapon_pistol",
		Biped = true,
		Model = "models/kleiner.mdl",
		Idle = "idle_subtle",
		Walk = "walk_all",
		Run = "run_all",
		WalkSpeed = 80,
		RunSpeed = 209,
		Health = 80,
	},
	eli = {
		Faction = "friend",
		Weapon = "weapon_pistol",
		Biped = true,
		Model = "models/eli.mdl",
		Idle = "idle_subtle",
		Walk = "walk_all",
		Run = "run_all",
		WalkSpeed = 40,
		RunSpeed = 209,
		Health = 80,
	},
	odessa = {
		Faction = "friend",
		Weapon = "weapon_pistol",
		Biped = true,
		Model = "models/odessa.mdl",
		Idle = "idle_subtle",
		Walk = "walk_all",
		Run = "run_all",
		WalkSpeed = 80,
		RunSpeed = 209,
		Health = 150,
	},
	mossman = {
		Faction = "friend",
		Weapon = "weapon_pistol",
		Biped = true,
		Model = "models/mossman.mdl",
		Idle = "idle_subtle",
		Walk = "walk_all",
		Run = "run_all",
		WalkSpeed = 79,
		RunSpeed = 209,
	},
	gman = {
		Faction = "friend",
		Dummy = true,
		Biped = true,
		Model = "models/gman.mdl",
		Idle = "idle_subtle",
		Walk = "walk_all",
		Run = "walk_all",
		WalkSpeed = 52,
		RunSpeed = 52,
		Health = 1000,
	},
	metrocop = {
		Faction = "enemy",
		Weapon = "weapon_pistol",
		Biped = true,
		Model = "models/police.mdl",
		Idle = "Idle_Baton",
		Walk = "walk_all",
		Run = "run_all",
		WalkSpeed = 57,
		RunSpeed = 184,
		Health = 60,
	},
	combine_guard = {
		Faction = "enemy",
		Weapon = "weapon_pistol",
		Biped = true,
		Model = "models/combine_soldier_prisonguard.mdl",
		Idle = "Idle_Unarmed",
		Walk = "WalkEasy_all",
		Run = "RunALL",
		WalkSpeed = 77,
		RunSpeed = 214,
		Health = 70,
	},
	zombie_soldier = {
		Faction = "enemy",
		Model = "models/zombie/zombie_soldier.mdl",
		Idle = "Idle01",
		Walk = "walk_All",
		Run = "Run_All",
		WalkSpeed = 35,
		RunSpeed = 193,
		Health = 80,
		Moves = {claw = claw("attackA", 1.12, 0.6, 20, 1.96)},
		Attacks = {{Move = "claw", Range = 1.4, Interval = 1.6}},
	},
	zombie_torso = {
		Faction = "enemy",
		Model = "models/zombie/classic_torso.mdl",
		Idle = "Idle01",
		Walk = "crawl",
		Run = "crawl",
		WalkSpeed = 31,
		RunSpeed = 31,
		Radius = 14,
		Height = 28,
		StepHeight = 8,
		Health = 25,
		Moves = {claw = claw("attack", 1.26, 0.5, 10, 1.54)},
		Attacks = {{Move = "claw", Range = 1.1, Interval = 1.8}},
	},
	headcrab_black = {
		Faction = "enemy",
		Model = "models/headcrabblack.mdl",
		Idle = "Idle01",
		Walk = "walk_All",
		Run = "Scurry",
		WalkSpeed = 25,
		RunSpeed = 111,
		Radius = 6,
		Height = 14,
		TurnSpeed = 14,
		StepHeight = 8,
		Health = 40,
		Moves = {claw = claw("Spitattack", 0.84, 0.3, 14, 1.26)},
		Attacks = {{Move = "claw", Range = 0.9, Interval = 1.2}},
	},
	antlion_worker = {
		Faction = "enemy",
		Model = "models/antlion_worker.mdl",
		Idle = "Idle",
		Walk = "walk_all",
		Run = "run_all",
		WalkSpeed = 195,
		RunSpeed = 354,
		Radius = 28,
		Height = 56,
		TurnSpeed = 12,
		Health = 40,
		Moves = {claw = claw("attack1", 0.84, 0.3, 10, 2.52)},
		Attacks = {{Move = "claw", Range = 1.8, Interval = 1.2}},
	},
	antlion_guard = {
		Faction = "enemy",
		Model = "models/antlion_guard.mdl",
		Idle = "idle",
		Walk = "walk1",
		Run = "uprun1",
		WalkSpeed = 179,
		RunSpeed = 332,
		Radius = 40,
		Height = 80,
		TurnSpeed = 6,
		StepHeight = 24,
		Health = 400,
		Moves = {claw = claw("shove", 1.4, 0.5, 40, 3.64)},
		Attacks = {{Move = "claw", Range = 2.6, Interval = 2.0}},
	},
	hunter = {
		Faction = "enemy",
		Model = "models/hunter.mdl",
		Idle = "idle1",
		Walk = "walk_all",
		Run = "canter_all",
		WalkSpeed = 203,
		RunSpeed = 349,
		Radius = 28,
		Height = 100,
		TurnSpeed = 8,
		StepHeight = 24,
		Health = 200,
		Moves = {claw = claw("meleeleft", 1.05, 0.4, 30, 3.08)},
		Attacks = {{Move = "claw", Range = 2.2, Interval = 1.5}},
	},
	vortigaunt_slave = {
		Faction = "friend",
		Model = "models/vortigaunt_slave.mdl",
		Idle = "Idle01",
		Walk = "Walk_all",
		Run = "Run_all",
		WalkSpeed = 43,
		RunSpeed = 140,
		Radius = 20,
		Height = 84,
		Health = 80,
		Moves = {zap = cast("zapattack1", 0.9, 0.5, "lightning", 20)},
		Attacks = {{Move = "zap", Range = 12, Interval = 2.5}},
	},
	lamarr = {
		Faction = "friend",
		Model = "models/lamarr.mdl",
		Idle = "Idle01",
		Walk = "Run1",
		Run = "Run1",
		WalkSpeed = 50,
		RunSpeed = 50,
		Radius = 6,
		Height = 14,
		TurnSpeed = 14,
		StepHeight = 8,
		Health = 20,
	},
}

local function input(name, type, default, property)
	return {
		Name = name,
		Type = type,
		Default = default,
		Targets = {{Node = "root", Component = "ai_controller", Property = property or name}},
	}
end

function npcs.GetPrefabName(name)
	return "npc_" .. name
end

function npcs.Register(name, info)
	if info.Moves then
		movesets.Register(npcs.GetPrefabName(name), table.copy({Moves = info.Moves}))
	end

	local npc = {
		WalkSpeed = info.WalkSpeed * UNIT,
		RunSpeed = info.RunSpeed * UNIT,
		TurnSpeed = info.TurnSpeed,
		Radius = info.Radius and info.Radius * UNIT,
		Height = info.Height and info.Height * UNIT,
		StepHeight = info.StepHeight and info.StepHeight * UNIT,
		Moveset = info.Moves and npcs.GetPrefabName(name) or "",
		Attacks = info.Attacks,
		Faction = info.Faction,
		Retaliate = info.Retaliate,
	}
	return prefab.Register(
		npcs.GetPrefabName(name),
		{
			inputs = {
				input("Wander", "boolean", not info.Dummy),
				input("WanderRadius", "number", 30),
				input("Running", "boolean", false),
				input("WalkSpeed", "number", npc.WalkSpeed),
				input("RunSpeed", "number", npc.RunSpeed),
			},
			entities = {
				{
					guid = "root",
					components = {
						model = info.Model and {ModelPath = info.Model} or nil,
						animator = info.Model and {} or nil,
						eyes = info.Model and {AutoBlink = true, AutoLook = true} or nil,
						character_pose = {},
						source_pose = info.Model and
							{
								IdleSequence = info.Idle,
								WalkSequence = info.Walk,
								RunSequence = info.Run,
								Mirror = info.Biped,
								OwnsArmature = info.Biped,
							} or
							nil,
						procedural_pose = info.Outfit and {} or nil,
						player_avatar = info.Outfit and {Outfit = info.Outfit} or nil,
						attachment_points = info.Biped and {} or nil,
						ai_controller = npc,
						usable = info.Faction == "friend" and not info.Dummy and {Prompt = "follow"} or nil,
						weapon_holder = info.Weapon and {} or nil,
						ragdoll = info.Biped and {CorpseTime = 20, Profile = info.Ragdoll} or nil,
						health = {
							Health = info.Health or 50,
							MaxHealth = info.Health or 50,
							RemoveOnDeath = not info.Biped,
							RefillDelay = info.Dummy and 4 or 0,
						},
					},
				},
			},
		}
	)
end

if eyes then
	local fallback = eyes.GetTargetPosition

	function eyes.GetTargetPosition(entity)
		local movement = entity.character_movement

		if movement and not entity.eyes then
			return entity.transform:GetPosition() + movement:GetViewOffset()
		end

		return fallback(entity)
	end

	eyes.AddTargetSource(function(out, count)
		for _, list in ipairs{PlayerController.Instances or {}, AIController.Instances or {}} do
			for _, controller in ipairs(list) do
				local owner = controller.Owner

				if owner.health and not owner.health:IsDead() then
					count = count + 1
					out[count] = owner
				end
			end
		end

		return count
	end)
end

function npcs.Spawn(name, position, yaw)
	local entity = Entity.New{
		Name = name,
		transform = {Position = position:Copy()},
		prefab = {Path = npcs.GetPrefabName(name)},
		network = SERVER and {} or nil,
	}

	if entity.ai_controller:HasAuthority() then
		entity.ai_controller:Teleport(position, yaw)
		local weapon = npcs.Definitions[name].Weapon

		if weapon then entity.weapon_holder:Give(weapon) end
	end

	return entity
end

function npcs.SpawnNear(name, around, radius)
	local position = assert(
		GridNav.Get(0.3, 1.4, 0.35, 1.2):GetRandomPoint(around, radius, 30),
		"no ground to spawn on near that position"
	)
	return npcs.Spawn(name, position + Vec3(0, 0.05, 0), math.randomf(-math.pi, math.pi))
end

function npcs.GetByModel(model_path)
	model_path = model_path:lower()

	for name, info in pairs(npcs.Definitions) do
		if info.Model and info.Model:lower() == model_path then return name, info end
	end
end

function npcs.GetNamesByFaction(faction)
	local names = {}

	for name, info in pairs(npcs.Definitions) do
		if info.Faction == faction then names[#names + 1] = name end
	end

	table.sort(names)
	return names
end

function npcs.GetNames()
	local names = {}

	for name in pairs(npcs.Definitions) do
		names[#names + 1] = name
	end

	table.sort(names)
	return names
end

commands.Add("npc_spawn=string,number|nil", function(name, count)
	assert(
		npcs.Definitions[name],
		"unknown npc " .. name .. ", they are " .. table.concat(npcs.GetNames(), ", ")
	)

	for _ = 1, count or 1 do
		npcs.SpawnNear(name, render3d and render3d.GetCamera():GetPosition(), 30)
	end
end)

for name, info in pairs(npcs.Definitions) do
	npcs.Register(name, info).builtin = true
end

return npcs
