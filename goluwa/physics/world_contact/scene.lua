local physics = import("goluwa/physics.lua")
local raycast = import("goluwa/physics/raycast.lua")
local world_transform_utils = import("goluwa/physics/world_transform_utils.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local ModelComponent = import("goluwa/ecs/components/3d/model.lua")
local world_contact_scene = {}

function world_contact_scene.GetWorldModels()
	local source = physics.GetWorldTraceSource and physics.GetWorldTraceSource() or nil

	if source and source.models then return source.models end

	return ModelComponent.Instances or {}
end

function world_contact_scene.BuildBodyWorldContactAABB(body)
	if body.GetBroadphaseAABB then return body:GetBroadphaseAABB() end

	local points = {}

	for _, point in ipairs(body.GetCollisionLocalPoints and body:GetCollisionLocalPoints() or {}) do
		points[#points + 1] = body:GeometryLocalToWorld(point)
	end

	for _, point in ipairs(body.GetSupportLocalPoints and body:GetSupportLocalPoints() or {}) do
		points[#points + 1] = body:GeometryLocalToWorld(point)
	end

	if not points[1] then
		local position = body.GetPosition and body:GetPosition() or Vec3()
		local margin = body.GetCollisionMargin and
			math.max(body:GetCollisionMargin() or 0.01, 0.01) or
			0.01
		return {
			min_x = position.x - margin,
			min_y = position.y - margin,
			min_z = position.z - margin,
			max_x = position.x + margin,
			max_y = position.y + margin,
			max_z = position.z + margin,
		}
	end

	local bounds = {
		min_x = math.huge,
		min_y = math.huge,
		min_z = math.huge,
		max_x = -math.huge,
		max_y = -math.huge,
		max_z = -math.huge,
	}

	for i = 1, #points do
		local point = points[i]
		bounds.min_x = math.min(bounds.min_x, point.x)
		bounds.min_y = math.min(bounds.min_y, point.y)
		bounds.min_z = math.min(bounds.min_z, point.z)
		bounds.max_x = math.max(bounds.max_x, point.x)
		bounds.max_y = math.max(bounds.max_y, point.y)
		bounds.max_z = math.max(bounds.max_z, point.z)
	end

	return bounds
end

function world_contact_scene.ForEachWorldPrimitiveCandidate(body, callback, arg1, arg2, arg3, arg4)
	local body_aabb = world_contact_scene.BuildBodyWorldContactAABB(body)
	local primitive_candidates = {}

	for _, model in ipairs(world_contact_scene.GetWorldModels()) do
		local entity = model and model.Owner or nil

		if not (model and entity and entity ~= body:GetOwner()) then
			goto continue_model
		end

		if entity.PhysicsNoCollision or entity.NoPhysicsCollision or entity.rigid_body then
			goto continue_model
		end

		local filter_fn = body:GetFilterFunction()

		if filter_fn and not filter_fn(entity) then goto continue_model end

		local model_aabb = model.GetWorldAABB and model:GetWorldAABB() or model.AABB

		if
			model_aabb and
			not (
				(
					body_aabb.IsBoxIntersecting and
					body_aabb:IsBoxIntersecting(model_aabb)
				) or
				world_transform_utils.AABBIntersects(body_aabb, model_aabb)
			)
		then
			goto continue_model
		end

		local world_to_local, local_to_world = world_transform_utils.GetModelTransforms(model)
		local local_body_aabb = world_transform_utils.BuildLocalAABBFromWorldAABB(body_aabb, world_to_local)

		for i = #primitive_candidates, 1, -1 do
			primitive_candidates[i] = nil
		end

		raycast.CollectModelPrimitiveCandidatesByLocalAABB(model, local_body_aabb, primitive_candidates)

		for i = 1, #primitive_candidates do
			local candidate = primitive_candidates[i]
			local primitive = candidate and candidate.primitive or nil
			local primitive_index = candidate and candidate.primitive_idx or nil

			if primitive and primitive_index then
				callback(
					model,
					entity,
					primitive,
					primitive_index,
					local_body_aabb,
					world_to_local,
					local_to_world,
					arg1,
					arg2,
					arg3,
					arg4
				)
			end
		end

		::continue_model::
	end
end

return world_contact_scene