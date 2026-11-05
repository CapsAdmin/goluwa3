local Vec3 = import("goluwa/structs/vec3.lua")
local Color = import("goluwa/structs/color.lua")
local Entity = import("goluwa/entities/entity.lua")
local steam = import("goluwa/steam/steam.lua")
local event = import("goluwa/event.lua")
local shapes = import("goluwa/render3d/shapes.lua")
local View = import("goluwa/render3d/view.lua")
steam.MountSourceGame("gmod")
local npcs = import("lua/npcs.lua")
local players = import("lua/players.lua")
local AIController = import("lua/components/ai_controller.lua")
local simulation_lod = import("lua/simulation_lod.lua")
local SIZE = tonumber(os.getenv("ARENA_SIZE")) or 36
local TARGET = tonumber(os.getenv("ARENA_TARGET")) or 24
local REFILL_AT = tonumber(os.getenv("ARENA_REFILL_AT")) or 4
local HEIGHT = 8
local WALL = 1
local MARGIN = 3
local SPAWN_PER_FRAME = 2
local CREATURE_SHARE = 0.4
local HALF = SIZE / 2
local MELEE = {
	"weapon_sword",
	"weapon_greatsword",
	"weapon_rapier",
	"weapon_reaper",
	"weapon_shovel",
}
local bipeds, creatures = {}, {}

for _, name in ipairs(npcs.GetNames()) do
	local info = npcs.Definitions[name]

	if info.Biped and info.Player and not info.Dummy then
		bipeds[#bipeds + 1] = name
	elseif not info.Biped and info.Attacks then
		creatures[#creatures + 1] = name
	end
end

local root = Entity.New{Name = "npc_arena"}
local floor = shapes.Material{Color = Color(0.35, 0.33, 0.3, 1), Roughness = 0.8, Metallic = 0}
local walls = shapes.Material{Color = Color(0.6, 0.6, 0.62, 1), Roughness = 0.9, Metallic = 0}

local function plane(name, position, normal, size_x, size_y, material)
	shapes.Polygon{
		Name = name,
		Parent = root,
		Material = material,
		RigidBody = {MotionType = "static", WorldGeometry = true, Friction = 0.85},
		Polygon = function(poly)
			shapes.BuildPlane(poly, position, normal, size_x, size_y, 1, 12, 12)
		end,
	}
end

-- zero thickness planes let ragdolls fall out, so every wall is a closed shell of inner and outer faces
do
	local outer, outer_height = HALF + WALL, HEIGHT / 2 + WALL
	plane("floor", Vec3(0, 0, 0), Vec3(0, 1, 0), HALF, HALF, floor)
	plane("ceiling", Vec3(0, HEIGHT, 0), Vec3(0, -1, 0), HALF, HALF, walls)
	plane("wall_n", Vec3(0, HEIGHT / 2, -HALF), Vec3(0, 0, 1), HALF, HEIGHT / 2, walls)
	plane("wall_s", Vec3(0, HEIGHT / 2, HALF), Vec3(0, 0, -1), HALF, HEIGHT / 2, walls)
	plane("wall_w", Vec3(-HALF, HEIGHT / 2, 0), Vec3(1, 0, 0), HALF, HEIGHT / 2, walls)
	plane("wall_e", Vec3(HALF, HEIGHT / 2, 0), Vec3(-1, 0, 0), HALF, HEIGHT / 2, walls)
	plane("shell_floor", Vec3(0, -WALL, 0), Vec3(0, -1, 0), outer, outer, walls)
	plane("shell_ceiling", Vec3(0, HEIGHT + WALL, 0), Vec3(0, 1, 0), outer, outer, walls)
	plane(
		"shell_n",
		Vec3(0, HEIGHT / 2, -outer),
		Vec3(0, 0, -1),
		outer,
		outer_height,
		walls
	)
	plane("shell_s", Vec3(0, HEIGHT / 2, outer), Vec3(0, 0, 1), outer, outer_height, walls)
	plane(
		"shell_w",
		Vec3(-outer, HEIGHT / 2, 0),
		Vec3(-1, 0, 0),
		outer,
		outer_height,
		walls
	)
	plane("shell_e", Vec3(outer, HEIGHT / 2, 0), Vec3(1, 0, 0), outer, outer_height, walls)
end

for _, x in ipairs{-0.25, 0.25} do
	for _, z in ipairs{-0.25, 0.25} do
		local light = Entity.New{Name = "npc_arena_light", Parent = root}
		light:AddComponent("transform"):SetPosition(Vec3(x * SIZE, HEIGHT - 1, z * SIZE))
		local point = light:AddComponent("light_point")
		point:SetColor(Color(1, 0.95, 0.85, 1))
		point:SetLumen(30000)
	end
end

-- far npcs are not simulated and never fight
simulation_lod.MaxSimulated = 1000
View.New{
	Priority = 100,
	Position = Vec3(-HALF + 2, HEIGHT - 1.5, -HALF + 2),
	Rotation = QuatDeg3(-30, -135, 0),
}:Activate()
local fighters = {}
local queue = {}
local parked

local function enqueue(count)
	for _ = 1, count do
		local creature = math.random() < CREATURE_SHARE
		local list = creature and creatures or bipeds
		queue[#queue + 1] = {
			name = list[math.random(#list)],
			weapon = not creature and MELEE[math.random(#MELEE)] or nil,
		}
	end
end

local function spawn(request)
	local entity = npcs.Spawn(
		request.name,
		Vec3(
			math.randomf(-HALF + MARGIN, HALF - MARGIN),
			0.05,
			math.randomf(-HALF + MARGIN, HALF - MARGIN)
		),
		math.randomf(-math.pi, math.pi),
		{Faction = AIController.FreeForAll, Weapon = request.weapon}
	)
	entity.ai_controller:SetAttackRange(SIZE * 2)
	entity.ai_controller:SetPhysicsDistance(SIZE * 4)
	fighters[entity] = true
end

event.AddListener("Update", "npc_arena", function()
	local player = players.GetLocal()

	if not parked and player:IsValid() and player.character_movement then
		parked = true
		player.health:SetUnkillable(true)
		player.character_movement:TeleportTo(Vec3(0, HEIGHT + WALL + 0.2, 0))
	end

	local alive = 0

	for entity in pairs(fighters) do
		if not entity:IsValid() or entity.health:IsDead() then
			fighters[entity] = nil
		else
			alive = alive + 1
		end
	end

	if alive <= REFILL_AT and #queue == 0 then enqueue(TARGET - alive) end

	for _ = 1, SPAWN_PER_FRAME do
		local request = table.remove(queue)

		if request then spawn(request) end
	end
end)
