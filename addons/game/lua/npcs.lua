local prefab = import("goluwa/entities/prefab.lua")
local Entity = import("goluwa/entities/entity.lua")
local nav_mesh = import("goluwa/entities/components/nav_mesh.lua")
local commands = import("goluwa/cli/commands.lua")
local render3d = RENDER_3D and import("goluwa/render3d/render3d.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local UNIT = import("goluwa/source_engine/units.lua").meters
import("lua/damage.lua")
local npcs = {}
npcs.Definitions = {
	citizen = {
		Model = "models/humans/group01/male_01.mdl",
		Idle = "idle_subtle",
		Walk = "walk_all",
		Run = "run_all",
		WalkSpeed = 80,
		RunSpeed = 210,
	},
	barney = {
		Model = "models/barney.mdl",
		Idle = "idle_subtle",
		Walk = "walk_all",
		Run = "run_all",
		WalkSpeed = 80,
		RunSpeed = 210,
	},
	combine_soldier = {
		Model = "models/combine_soldier.mdl",
		Idle = "Idle_Unarmed",
		Walk = "WalkEasy_all",
		Run = "RunALL",
		WalkSpeed = 78,
		RunSpeed = 215,
	},
	zombie = {
		Model = "models/zombie/classic.mdl",
		Idle = "Idle01",
		Walk = "walk",
		Run = "walk",
		WalkSpeed = 45,
		RunSpeed = 45,
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
	},
	antlion = {
		Model = "models/antlion.mdl",
		Idle = "Idle",
		Walk = "walk_all",
		Run = "run_all",
		WalkSpeed = 195,
		RunSpeed = 355,
		Radius = 28,
		Height = 56,
		TurnSpeed = 12,
	},
	headcrab = {
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
	local npc = {
		WalkSpeed = info.WalkSpeed * UNIT,
		RunSpeed = info.RunSpeed * UNIT,
		TurnSpeed = info.TurnSpeed,
		Radius = info.Radius and info.Radius * UNIT,
		Height = info.Height and info.Height * UNIT,
		StepHeight = info.StepHeight and info.StepHeight * UNIT,
	}
	return prefab.Register(
		npcs.GetPrefabName(name),
		{
			inputs = {
				input("Wander", "boolean", true),
				input("WanderRadius", "number", 30),
				input("Running", "boolean", false),
				input("WalkSpeed", "number", npc.WalkSpeed),
				input("RunSpeed", "number", npc.RunSpeed),
			},
			entities = {
				{
					guid = "root",
					components = {
						model = {ModelPath = info.Model},
						animator = {},
						locomotion = {IdleSequence = info.Idle, WalkSequence = info.Walk, RunSequence = info.Run},
						ai_controller = npc,
						health = {Health = info.Health or 50, MaxHealth = info.Health or 50, RemoveOnDeath = true},
					},
				},
			},
		}
	)
end

function npcs.Spawn(name, position, yaw)
	local entity = Entity.New{
		Name = name,
		transform = {Position = position:Copy()},
		prefab = {Path = npcs.GetPrefabName(name)},
		network = SERVER and {} or nil,
	}

	if entity.ai_controller:HasAuthority() then entity.ai_controller:Teleport(position, yaw) end

	return entity
end

function npcs.SpawnOnMesh(name, around, radius)
	local mesh = nav_mesh.GetMesh()
	assert(mesh, "there is no navigation mesh, load a map that has a nav file")
	local position = assert(
		mesh:GetRandomPoint(around, radius),
		"no place on the navigation mesh to spawn on"
	)
	return npcs.Spawn(name, position + Vec3(0, 0.05, 0), math.randomf(-math.pi, math.pi))
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
		npcs.SpawnOnMesh(name, render3d and render3d.GetCamera():GetPosition(), 30)
	end
end)

for name, info in pairs(npcs.Definitions) do
	npcs.Register(name, info).builtin = true
end

return npcs
