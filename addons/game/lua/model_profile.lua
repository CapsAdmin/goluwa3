local Vec3 = import("goluwa/structs/vec3.lua")
local Quat = import("goluwa/structs/quat.lua")
local Matrix44 = import("goluwa/structs/matrix44.lua")
local model_loader = import("goluwa/render3d/model_loader.lua")
local aim_pose = import("lua/aim_pose.lua")
local model_profile = {}
local MIN_RADIUS = 0.02
local MIN_LENGTH = 0.02
local RADIUS_FIT = 0.8
local DEFAULT_TWIST = 0.4
local DEFAULT_SWING = 0.6
local MIN_LIMIT = 0.15
local MAX_LIMIT = 1.5
local HEAD_MULTIPLIER = 2.5
local LIMB_MULTIPLIER = 0.7
local BODY_HIT = {Amount = 0.6, Hold = 0.1, Recover = 0.3, Impulse = 0.5}
local LIMB_HIT = {Amount = 0.9, Hold = 1, Recover = 0.4, Impulse = 1}
local LIMB_WORDS = {
	"arm",
	"leg",
	"hand",
	"foot",
	"thigh",
	"calf",
	"claw",
	"wing",
	"tail",
	"knee",
	"shin",
}
local cache = {}
local loading = {}

local function get_multiplier(name)
	name = name:lower()

	if name:find("head", nil, true) then return HEAD_MULTIPLIER end

	for _, word in ipairs(LIMB_WORDS) do
		if name:find(word, nil, true) then return LIMB_MULTIPLIER end
	end

	return 1
end

local function get_limit(axis)
	local range = math.max(math.abs(axis.min), math.abs(axis.max))

	if range == 0 then return nil end

	return math.clamp(range, MIN_LIMIT, MAX_LIMIT)
end

-- a capsule along the longest direction of the solid, in the frame of its bone
local function fit_capsule(solid)
	local points = {}
	local centroid = Vec3()

	for _, child in ipairs(solid.children) do
		for _, vertex in ipairs(child.ConvexHull.vertices) do
			local point = child.Position + vertex
			points[#points + 1] = point
			centroid = centroid + point
		end
	end

	if #points == 0 then
		return solid.mass_center, Quat():Identity(), MIN_LENGTH, MIN_RADIUS
	end

	centroid = centroid / #points
	local axis, farthest = Vec3(0, 1, 0), 0

	for _, point in ipairs(points) do
		local distance = (point - centroid):GetLength()

		if distance > farthest then
			farthest = distance
			axis = (point - centroid) / math.max(distance, 1e-6)
		end
	end

	local low, high, radius = math.huge, -math.huge, 0

	for _, point in ipairs(points) do
		local along = (point - centroid):Dot(axis)
		low = math.min(low, along)
		high = math.max(high, along)
		radius = math.max(radius, ((point - centroid) - axis * along):GetLength())
	end

	radius = math.max(radius * RADIUS_FIT, MIN_RADIUS)
	local rotation = Quat()
	aim_pose.SetBetween(rotation, 0, 1, 0, axis.x, axis.y, axis.z)
	return centroid + axis * ((low + high) * 0.5),
	rotation,
	math.max(high - low - radius * 2, MIN_LENGTH),
	radius
end

function model_profile.Build(ragdoll)
	local profile = {Model = true, Parts = {}, Joints = {}, Hits = {}, Rest = {}}
	local names = {}
	local used = {}

	for i, solid in ipairs(ragdoll.solids) do
		local name = solid.name ~= "" and solid.name or solid.bone

		if used[name] then name = name .. "_" .. i end

		used[name] = true
		names[i] = name
		local center, rotation, length, radius = fit_capsule(solid)
		local multiplier = get_multiplier(name .. " " .. solid.bone)
		profile.Parts[i] = {
			Name = name,
			Bone = solid.bone,
			Frame = {rotation = rotation, center = center},
			Length = length,
			Radius = radius,
			Mass = solid.weight,
			Multiplier = multiplier,
		}
		profile.Hits[name] = multiplier < 1 and LIMB_HIT or BODY_HIT
		local rest = Matrix44():Identity()
		rest:SetRotation(solid.bone_rotation)
		rest:SetTranslation(solid.bone_position.x, solid.bone_position.y, solid.bone_position.z)
		profile.Rest[solid.bone] = rest
	end

	local adjacent = {}
	local joint_of = {}

	for _, constraint in ipairs(ragdoll.constraints) do
		adjacent[constraint.parent] = adjacent[constraint.parent] or {}
		table.insert(adjacent[constraint.parent], constraint)
		joint_of[constraint.child] = constraint
	end

	local order = {}
	local queue = {1}
	local seen = {[1] = true}

	while queue[1] do
		local index = table.remove(queue, 1)
		order[#order + 1] = index

		for _, constraint in ipairs(adjacent[index] or {}) do
			if not seen[constraint.child] then
				seen[constraint.child] = true
				queue[#queue + 1] = constraint.child
			end
		end
	end

	for i in ipairs(ragdoll.solids) do
		if not seen[i] then
			order[#order + 1] = i
			joint_of[i] = nil
		end
	end

	local parts = {}

	for position, index in ipairs(order) do
		parts[position] = profile.Parts[index]
		local constraint = joint_of[index]

		if index ~= 1 then
			local twist = constraint and get_limit(constraint.x) or DEFAULT_TWIST
			local swing = constraint and
				math.max(get_limit(constraint.y) or 0, get_limit(constraint.z) or 0) or
				DEFAULT_SWING

			if swing == 0 then swing = DEFAULT_SWING end

			profile.Joints[#profile.Joints + 1] = {
				Parent = names[constraint and constraint.parent or 1],
				Child = names[index],
				Anchor = ragdoll.solids[index].bone,
				Twist = twist,
				Swing = swing,
			}
		end
	end

	profile.Parts = parts
	return profile
end

function model_profile.Get(model_path)
	local profile = cache[model_path]

	if profile then return profile end

	if not loading[model_path] then
		loading[model_path] = true

		model_loader.LoadModel(
			model_path,
			function(data)
				assert(data.physics and data.physics.ragdoll, model_path .. " has no ragdoll data")
				cache[model_path] = model_profile.Build(data.physics.ragdoll)
			end,
			nil,
			function(err)
				wlog("model_profile: failed to load %s: %s", model_path, tostring(err))
			end
		)
	end
end

return model_profile
