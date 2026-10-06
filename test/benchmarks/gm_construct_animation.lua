local commands = import("goluwa/cli/commands.lua")
local frame_benchmark = import("goluwa/render3d/frame_benchmark.lua")
local raycast = import("goluwa/render3d/raycast.lua")
local vfs = import("goluwa/vfs.lua")
local Entity = import("goluwa/entities/entity.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Animator = import("goluwa/entities/components/animator.lua")
local scene_bvh = import("goluwa/render3d/scene_bvh.lua")
local SIDES = {}

for side in (os.getenv("ANIM_SIDES") or "0,5,10,15,20"):gmatch("%d+") do
	SIDES[#SIDES + 1] = tonumber(side)
end

if os.getenv("ANIM_NO_LOD") then
	Animator.LOD_NEAR = 1e9
	Animator.LOD_FAR = 2e9
end

if os.getenv("ANIM_NO_BVH_ANIM") then scene_bvh.ANIMATION_DISTANCE = 0 end

local SPACING = 1.2
local SEQUENCES = {"walk_all", "run_all_01", "run_all_02", "idle_all_01", "cwalk_all"}
local floor_y = 0
local models = {}
local characters = {}

local function find_floor()
	local hit = raycast.CastClosest(Vec3(0, 60, 0), Vec3(0, -1, 0), 200)
	floor_y = hit and hit.position.y or 0
end

local function spawn_grid(side)
	for _, entity in ipairs(characters) do
		if entity:IsValid() then entity:Remove() end
	end

	characters = {}
	local half = (side - 1) / 2

	for index = 0, side * side - 1 do
		local entity = Entity.New{Name = "animated_" .. index}
		local transform = entity:AddComponent("transform")
		transform:SetPosition(
			Vec3((math.floor(index / side) - half) * SPACING, floor_y, (index % side - half) * SPACING)
		)
		transform:SetRotation(QuatDeg3(0, (index * 47) % 360, 0))
		entity:AddComponent("visual")
		entity.visual:SetModelPath(models[index % #models + 1])

		if not os.getenv("ANIM_STATIC") then
			local animator = entity:AddComponent("animator")
			entity.sequence = SEQUENCES[index % #SEQUENCES + 1]
			animator:SetSpeed(0.7 + ((index * 13) % 7) / 10)
			animator:SetPoseParameterByName("move_x", 1)
		end

		characters[#characters + 1] = entity
	end
end

local function characters_ready()
	for _, entity in ipairs(characters) do
		if
			entity.visual:IsLoading() or
			entity.animator and
			entity.animator.skeleton ~= entity.visual.Skeleton
		then
			return false
		end

		if entity.animator and not entity.sequence_set and entity.animator.skeleton then
			entity.sequence_set = true
			local clips = entity.animator.skeleton.ClipsByName

			if clips[entity.sequence] then entity.animator:SetSequence(entity.sequence) end
		end
	end

	return true
end

local phases = {}

for _, side in ipairs(SIDES) do
	phases[#phases + 1] = {
		name = side == 0 and
			"no models" or
			string.format("%dx%d = %d models", side, side, side * side),
		enter = function()
			spawn_grid(side)
		end,
		ready = characters_ready,
	}
end

frame_benchmark.Run{
	name = "gm_construct animation",
	fov = 60,
	measure = tonumber(os.getenv("ANIM_SECONDS")),
	load = function()
		commands.RunString("map gm_construct")
	end,
	view = function()
		find_floor()

		for _, path in ipairs(vfs.Find("models/player/")) do
			if path:ends_with(".mdl") then models[#models + 1] = "models/player/" .. path end
		end

		table.sort(models)
		return Vec3(0, floor_y + SIDES[#SIDES] * SPACING * 1.05 + 4, 0), -89, 0
	end,
	phases = phases,
}
