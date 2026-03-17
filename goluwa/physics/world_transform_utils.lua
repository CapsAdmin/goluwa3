local AABB = import("goluwa/structs/aabb.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local world_transform_utils = {}

function world_transform_utils.GetModelTransforms(model)
	if model.WorldSpaceVertices then return nil, nil end

	local transform = model.Owner and model.Owner.transform or nil

	if not transform then return nil, nil end

	return transform:GetWorldMatrixInverse(), transform:GetWorldMatrix()
end

function world_transform_utils.BuildLocalAABBFromWorldAABB(world_aabb, world_to_local)
	if not world_to_local then return world_aabb end

	local local_min = Vec3(math.huge, math.huge, math.huge)
	local local_max = Vec3(-math.huge, -math.huge, -math.huge)
	local corners = {
		Vec3(world_aabb.min_x, world_aabb.min_y, world_aabb.min_z),
		Vec3(world_aabb.min_x, world_aabb.min_y, world_aabb.max_z),
		Vec3(world_aabb.min_x, world_aabb.max_y, world_aabb.min_z),
		Vec3(world_aabb.min_x, world_aabb.max_y, world_aabb.max_z),
		Vec3(world_aabb.max_x, world_aabb.min_y, world_aabb.min_z),
		Vec3(world_aabb.max_x, world_aabb.min_y, world_aabb.max_z),
		Vec3(world_aabb.max_x, world_aabb.max_y, world_aabb.min_z),
		Vec3(world_aabb.max_x, world_aabb.max_y, world_aabb.max_z),
	}

	for i = 1, #corners do
		local point = world_to_local:TransformVector(corners[i])
		local_min.x = math.min(local_min.x, point.x)
		local_min.y = math.min(local_min.y, point.y)
		local_min.z = math.min(local_min.z, point.z)
		local_max.x = math.max(local_max.x, point.x)
		local_max.y = math.max(local_max.y, point.y)
		local_max.z = math.max(local_max.z, point.z)
	end

	return AABB(
		local_min.x,
		local_min.y,
		local_min.z,
		local_max.x,
		local_max.y,
		local_max.z
	)
end

function world_transform_utils.AABBIntersects(a, b)
	if not (a and b) then return false end

	return not (
		a.min_x > b.max_x or
		b.min_x > a.max_x or
		a.min_y > b.max_y or
		b.min_y > a.max_y or
		a.min_z > b.max_z or
		b.min_z > a.max_z
	)
end

return world_transform_utils