-- glw: --2d --physics
-- a stand-in for a big BSP world body: ~1370 heightmap colliders (displacements)
-- plus one brush model collider with thousands of primitives. an awake capsule
-- stands, then walks, with the collider index on and then off
local system = import("goluwa/system.lua")
local event = import("goluwa/event.lua")
local physics = import("goluwa/physics.lua")
local Entity = import("goluwa/entities/entity.lua")
local Vec2 = import("goluwa/structs/vec2.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Quat = import("goluwa/structs/quat.lua")
local AABB = import("goluwa/structs/aabb.lua")
local HeightmapShape = import("goluwa/physics/shapes/heightmap.lua")
local CapsuleShape = import("goluwa/physics/shapes/capsule.lua")
local stats = import("goluwa/physics/stats.lua")
local collider_index = import("goluwa/physics/collider_index.lua")
local STEPS = 240
local PATCH_GRID = 37
local PATCH_SIZE = 4
local PATCH_SAMPLES = 9
local BRUSH_COUNT = 8000
local WALK_SPEED = 5
local seed = 1234
local function rand()
	seed = (seed * 1103515245 + 12345) % 2147483648
	return seed / 2147483648
end
local function ground_height(x, z)
	return math.sin(x * 0.35) * 0.15 + math.cos(z * 0.27) * 0.15
end

local ent = Entity.New({Name = "synthetic_map"})
ent:AddComponent("transform")
local collider_shapes = {}
local half = PATCH_GRID * PATCH_SIZE * 0.5

for gz = 0, PATCH_GRID - 1 do
	for gx = 0, PATCH_GRID - 1 do
		local cx = (gx + 0.5) * PATCH_SIZE - half
		local cz = (gz + 0.5) * PATCH_SIZE - half
		local samples = HeightmapShape.SamplesFromFunction(PATCH_SAMPLES, PATCH_SAMPLES, function(x, z)
			local wx = cx + (x / (PATCH_SAMPLES - 1) - 0.5) * PATCH_SIZE
			local wz = cz + (z / (PATCH_SAMPLES - 1) - 0.5) * PATCH_SIZE
			return ground_height(wx, wz)
		end)
		collider_shapes[#collider_shapes + 1] = {
			Heightmap = {Samples = samples, SamplesX = PATCH_SAMPLES, SamplesZ = PATCH_SAMPLES, Size = Vec2(PATCH_SIZE, PATCH_SIZE)},
			Position = Vec3(cx, 0, cz),
			Rotation = Quat(0, 0, 0, 1),
		}
	end
end

local primitives = {}
local model_aabb = AABB(math.huge, math.huge, math.huge, -math.huge, -math.huge, -math.huge)

for _ = 1, BRUSH_COUNT do
	local sx, sy, sz = 1 + rand() * 5, 1 + rand() * 7, 1 + rand() * 5
	local x, z = (rand() - 0.5) * 2 * (half - 5), (rand() - 0.5) * 2 * (half - 5)

	-- keep the walking lane (z within 3 of 0) mostly open
	if math.abs(z) < 3 and rand() < 0.9 then z = z + (z < 0 and -4 or 4) end

	local min_x, max_x, min_y, max_y, min_z, max_z = x - sx * 0.5, x + sx * 0.5, 0.2, 0.2 + sy, z - sz * 0.5, z + sz * 0.5
	local aabb = AABB(min_x, min_y, min_z, max_x, max_y, max_z)
	primitives[#primitives + 1] = {
		brush_planes = {
			{normal = Vec3(1, 0, 0), dist = max_x},
			{normal = Vec3(-1, 0, 0), dist = -min_x},
			{normal = Vec3(0, 1, 0), dist = max_y},
			{normal = Vec3(0, -1, 0), dist = -min_y},
			{normal = Vec3(0, 0, 1), dist = max_z},
			{normal = Vec3(0, 0, -1), dist = -min_z},
		},
		aabb = aabb,
	}
	model_aabb:Expand(aabb)
end

table.insert(collider_shapes, 1, {Model = {Owner = ent, Visible = true, WorldSpaceVertices = true, AABB = model_aabb, Primitives = primitives}})
local world = ent:AddComponent("rigid_body", {Shapes = collider_shapes, MotionType = "static", GravityScale = 0, Friction = 0.85, Restitution = 0, WorldGeometry = true})
print("[RESULT] synthetic map colliders", #world:GetColliders(), "brush primitives", #primitives)

local player = Entity.New({Name = "synthetic_player"})
player:AddComponent("transform")
player.transform:SetPosition(Vec3(-half + 12, 1.5, 0))
local body = player:AddComponent("rigid_body", {Shape = CapsuleShape.New(0.3, 1.2), Radius = 0.3, Height = 1.2, Mass = 80, AutomaticMass = false, CanSleep = false, CCD = true, Friction = 0.5, Restitution = 0, LinearDamping = 0})

event.RemoveListener("Update", "physics")

local function run_phase(name, walk)
	stats:Enable()
	local start_x = player.transform:GetPosition().x

	for _ = 1, STEPS do
		if walk then
			local v = body:GetVelocity()
			body:SetVelocity(Vec3(WALK_SPEED, v.y, 0))
		end

		physics.instance.Step(1 / 60)
	end

	local summary = stats:Summary()
	stats:Disable()
	local pos = player.transform:GetPosition()
	local avg = summary:match("([%d%.]+) ms/step avg")
	print(string.format("[RESULT] %-24s avg step %s ms, moved %.2f m, y=%.2f", name, tostring(avg), pos.x - start_x, pos.y))

end

local phase = 0
event.AddListener("Update", "synthetic_bench", function()
	phase = phase + 1

	if phase == 1 then
		for _ = 1, 120 do physics.instance.Step(1 / 60) end
	elseif phase == 2 then
		run_phase("standing, index on", false)
	elseif phase == 3 then
		run_phase("walking, index on", true)
	elseif phase == 4 then
		local original = collider_index.Query
		collider_index.Query = function(b, aabb, out)
			local c = b:GetColliders()
			return c, #c
		end
		run_phase("standing, index OFF", false)
		run_phase("walking, index OFF", true)
		collider_index.Query = original
	else
		system.ShutDown(0)
	end
end)
