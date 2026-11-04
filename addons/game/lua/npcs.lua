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
local voices = import("lua/npc_voices.lua")
local rigs = import("lua/creature_rigs.lua")
local PlayerController = import("lua/components/player_controller.lua")
local AIController = import("lua/components/ai_controller.lua")
local eyes = RENDER_3D and import("goluwa/entities/components/eyes.lua")
local npcs = {}
npcs.Definitions = {
	citizen = {
		Biped = true,
		Player = true,
		Model = "models/player/group01/male_01.mdl",
		WalkSpeed = 80,
		RunSpeed = 210,
		Sounds = voices.citizen,
	},
	barney = {
		Biped = true,
		Player = true,
		Model = "models/player/barney.mdl",
		WalkSpeed = 80,
		RunSpeed = 210,
		Health = 200,
		Sounds = voices.barney,
	},
	combine_soldier = {
		Biped = true,
		Player = true,
		Model = "models/player/combine_soldier.mdl",
		WalkSpeed = 78,
		RunSpeed = 215,
		Sounds = voices.combine_soldier,
	},
	eye = {
		Biped = true,
		Outfit = outfit.DefaultName,
		Ragdoll = "eye",
		WalkSpeed = 80,
		RunSpeed = 210,
	},
	zombie = {
		Legs = true,
		Model = "models/zombie/classic.mdl",
		Idle = "Idle01",
		Walk = "walk",
		Run = "walk",
		WalkSpeed = 45,
		RunSpeed = 45,
		Moveset = true,
		Attacks = {
			{Move = "frenzy", Range = 1.4, Interval = 9},
			{Move = "claw", Range = 1.4, Interval = 2.4},
			{Move = "claw_b", Range = 1.4, Interval = 2.6},
			{Move = "claw_c", Range = 1.4, Interval = 3},
			{Move = "claw_d", Range = 1.4, Interval = 2.8},
			{Move = "swat_left", Range = 1.3, Interval = 2},
			{Move = "swat_right", Range = 1.3, Interval = 2.2},
			{Move = "kick", Range = 1.2, Interval = 3.5},
		},
		Sounds = voices.zombie,
	},
	vortigaunt = {
		Model = "models/vortigaunt.mdl",
		Idle = "Idle01",
		Walk = "Walk_all",
		Run = "Run_all",
		WalkSpeed = 44,
		RunSpeed = 140,
		Radius = 20,
		Height = 84,
		Moveset = true,
		Attacks = {{Move = "zap", Range = 12, Interval = 2.5}},
		Sounds = voices.vortigaunt,
	},
	antlion = {
		LegRig = rigs.antlion,
		Model = "models/antlion.mdl",
		Idle = "Idle",
		Walk = "walk_all",
		Run = "run_all",
		WalkSpeed = 195,
		RunSpeed = 355,
		Radius = 28,
		Height = 56,
		TurnSpeed = 12,
		Moveset = true,
		Attacks = {{Move = "claw", Range = 1.8, Interval = 1.2}},
		Sounds = voices.antlion,
	},
	headcrab = {
		LegRig = rigs.headcrab,
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
		Moveset = true,
		Attacks = {{Move = "claw", Range = 0.9, Interval = 1.2}},
		Sounds = voices.headcrab,
	},
	citizen_female = {
		Biped = true,
		Player = true,
		Model = "models/player/group01/female_01.mdl",
		WalkSpeed = 80,
		RunSpeed = 210,
		Sounds = voices.citizen_female,
	},
	rebel = {
		Biped = true,
		Player = true,
		Model = "models/player/group03/male_01.mdl",
		WalkSpeed = 80,
		RunSpeed = 210,
		Sounds = voices.rebel,
	},
	alyx = {
		Biped = true,
		Player = true,
		Model = "models/player/alyx.mdl",
		WalkSpeed = 80,
		RunSpeed = 210,
		Health = 300,
		Sounds = voices.alyx,
	},
	combine_elite = {
		Biped = true,
		Player = true,
		Model = "models/player/combine_super_soldier.mdl",
		WalkSpeed = 78,
		RunSpeed = 215,
		Health = 80,
		Sounds = voices.combine_elite,
	},
	breen = {
		Dummy = true,
		Retaliate = true,
		RefillDelay = 0.25,
		Biped = true,
		Player = true,
		Model = "models/player/breen.mdl",
		WalkSpeed = 80,
		RunSpeed = 210,
		Health = 300,
	},
	zombie_fast = {
		Legs = true,
		Model = "models/zombie/fast.mdl",
		Idle = "idle",
		Walk = "walk_all",
		Run = "Run",
		WalkSpeed = 55,
		RunSpeed = 218,
		Moveset = true,
		Attacks = {{Move = "claw", Range = 1.3, Interval = 1.0}},
		Sounds = voices.zombie_fast,
	},
	zombie_poison = {
		Legs = true,
		Model = "models/zombie/poison.mdl",
		Idle = "Idle01",
		Walk = "Walk",
		Run = "Run",
		WalkSpeed = 56,
		RunSpeed = 154,
		Health = 120,
		Moveset = true,
		Attacks = {{Move = "claw", Range = 1.5, Interval = 2.0}},
		Sounds = voices.zombie_poison,
	},
	monk = {
		Biped = true,
		Player = true,
		Model = "models/player/monk.mdl",
		WalkSpeed = 80,
		RunSpeed = 209,
		Sounds = voices.monk,
	},
	kleiner = {
		Biped = true,
		Player = true,
		Model = "models/player/kleiner.mdl",
		WalkSpeed = 80,
		RunSpeed = 209,
		Health = 80,
		Sounds = voices.kleiner,
	},
	eli = {
		Biped = true,
		Player = true,
		Model = "models/player/eli.mdl",
		WalkSpeed = 40,
		RunSpeed = 209,
		Health = 80,
		Sounds = voices.eli,
	},
	odessa = {
		Biped = true,
		Player = true,
		Model = "models/player/odessa.mdl",
		WalkSpeed = 80,
		RunSpeed = 209,
		Health = 150,
		Sounds = voices.odessa,
	},
	mossman = {
		Biped = true,
		Player = true,
		Model = "models/player/mossman.mdl",
		WalkSpeed = 79,
		RunSpeed = 209,
		Sounds = voices.mossman,
	},
	gman = {
		Dummy = true,
		Biped = true,
		Player = true,
		Model = "models/player/gman_high.mdl",
		WalkSpeed = 52,
		RunSpeed = 52,
		Health = 1000,
	},
	metrocop = {
		Biped = true,
		Player = true,
		Model = "models/player/police.mdl",
		WalkSpeed = 57,
		RunSpeed = 184,
		Health = 60,
		Sounds = voices.metrocop,
	},
	combine_guard = {
		Biped = true,
		Player = true,
		Model = "models/player/combine_soldier_prisonguard.mdl",
		WalkSpeed = 77,
		RunSpeed = 214,
		Health = 70,
		Sounds = voices.combine_guard,
	},
	zombie_soldier = {
		Legs = true,
		Model = "models/zombie/zombie_soldier.mdl",
		Idle = "Idle01",
		Walk = "walk_All",
		Run = "Run_All",
		WalkSpeed = 35,
		RunSpeed = 193,
		Health = 80,
		Moveset = true,
		Attacks = {{Move = "claw", Range = 1.4, Interval = 1.6}},
		Sounds = voices.zombie_soldier,
	},
	zombie_torso = {
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
		Moveset = true,
		Attacks = {{Move = "claw", Range = 1.1, Interval = 1.8}},
		Sounds = voices.zombie_torso,
	},
	headcrab_black = {
		LegRig = rigs.headcrab_black,
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
		Moveset = true,
		Attacks = {{Move = "claw", Range = 0.9, Interval = 1.2}},
		Sounds = voices.headcrab_black,
	},
	antlion_worker = {
		LegRig = rigs.antlion,
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
		Moveset = true,
		Attacks = {{Move = "claw", Range = 1.8, Interval = 1.2}},
		Sounds = voices.antlion_worker,
	},
	antlion_guard = {
		LegRig = rigs.antlion_guard,
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
		Alert = "roar",
		AttackRange = 25,
		Moveset = true,
		Attacks = {
			{Move = "shove", Range = 2.6, Interval = 2},
			{Move = "charge_windup", Range = 22, MinRange = 8, Interval = 12},
		},
		Sounds = voices.antlion_guard,
	},
	hunter = {
		LegRig = rigs.hunter,
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
		Moveset = true,
		Attacks = {{Move = "claw", Range = 2.2, Interval = 1.5}},
		Sounds = voices.hunter,
	},
	vortigaunt_slave = {
		Model = "models/vortigaunt_slave.mdl",
		Idle = "Idle01",
		Walk = "Walk_all",
		Run = "Run_all",
		WalkSpeed = 43,
		RunSpeed = 140,
		Radius = 20,
		Height = 84,
		Health = 80,
		Moveset = true,
		Attacks = {{Move = "zap", Range = 12, Interval = 2.5}},
		Sounds = voices.vortigaunt_slave,
	},
	lamarr = {
		LegRig = rigs.lamarr,
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
		Sounds = voices.lamarr,
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
	if info.Moveset then
		local path = "lua/npc_movesets/" .. name .. ".lua"
		movesets.Register(npcs.GetPrefabName(name), import(path), path)
	end

	local npc = {
		WalkSpeed = info.WalkSpeed * UNIT,
		RunSpeed = info.RunSpeed * UNIT,
		TurnSpeed = info.TurnSpeed,
		Radius = info.Radius and info.Radius * UNIT,
		Height = info.Height and info.Height * UNIT,
		StepHeight = info.StepHeight and info.StepHeight * UNIT,
		Moveset = info.Moveset and npcs.GetPrefabName(name) or "",
		Attacks = info.Attacks,
		Alert = info.Alert,
		AttackRange = info.AttackRange,
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
								Profile = info.Player and "gmod_player" or "creature",
								Mirror = info.Biped,
								OwnsArmature = info.Biped,
								LegIK = info.Legs,
								LegRig = info.LegRig,
							} or
							nil,
						procedural_pose = info.Outfit and {} or nil,
						player_avatar = info.Outfit and {Outfit = info.Outfit} or nil,
						attachment_points = info.Biped and {} or nil,
						ai_controller = npc,
						usable = not info.Dummy and {Prompt = "follow"} or nil,
						weapon_holder = info.Biped and {} or nil,
						ragdoll = (
								info.Biped or
								info.Model
							)
							and
							{
								CorpseTime = 20,
								CheapCorpse = true,
								BoxRagdoll = true,
								Profile = not info.Biped and "model" or info.Ragdoll,
							} or
							nil,
						npc_sounds = info.Sounds and {Sounds = info.Sounds} or nil,
						surface_exposure = RENDER_3D and {} or nil,
						health = {
							Health = info.Health or 50,
							MaxHealth = info.Health or 50,
							RefillDelay = info.RefillDelay or info.Dummy and 4 or 0,
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

function npcs.Spawn(name, position, yaw, options)
	local entity = Entity.New{
		Name = name,
		transform = {Position = position:Copy()},
		prefab = {Path = npcs.GetPrefabName(name)},
		network = SERVER and {} or nil,
	}

	if entity.ai_controller:HasAuthority() then
		entity.ai_controller:Teleport(position, yaw)

		if options then
			if options.Faction then entity.ai_controller:SetFaction(options.Faction) end

			if options.Weapon and entity.weapon_holder then
				entity.weapon_holder:Give(options.Weapon, options.Roll)
			end

			if options.Reaction then
				entity.character_pose:SetForcedReaction(options.Reaction)
			end

			if options.Health then
				entity.health:SetMaxHealth(options.Health)
				entity.health:SetHealth(options.Health)
			end

			if options.God then entity.health:SetUnkillable(true) end
		end
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
