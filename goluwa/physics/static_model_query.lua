local physics = import("goluwa/physics.lua")
local raycast = import("goluwa/physics/raycast.lua")
local model_transform_utils = import("goluwa/physics/model_transform_utils.lua")
local AABB = import("goluwa/structs/aabb.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local ModelComponent = import("goluwa/ecs/components/3d/model.lua")
local static_model_query = {}

function static_model_query.BuildExpandedWorldContactAABB(bounds, body, extra_body)
	local margin = body and body.GetCollisionMargin and body:GetCollisionMargin() or 0
	local probe_distance = body and body.GetCollisionProbeDistance and body:GetCollisionProbeDistance() or 0
	local extra_margin = extra_body and
		extra_body.GetCollisionMargin and
		extra_body:GetCollisionMargin() or
		0
	local extra_probe_distance = extra_body and
		extra_body.GetCollisionProbeDistance and
		extra_body:GetCollisionProbeDistance() or
		0
	local pad = math.max(
		margin + probe_distance + extra_margin + extra_probe_distance,
		physics.DefaultSkin or 0,
		physics.EPSILON
	)
	return {
		min_x = bounds.min_x - pad,
		min_y = bounds.min_y - pad,
		min_z = bounds.min_z - pad,
		max_x = bounds.max_x + pad,
		max_y = bounds.max_y + pad,
		max_z = bounds.max_z + pad,
	}
end

local function get_world_models()
	return ModelComponent.Instances or {}
end

function static_model_query.BuildBodyWorldContactAABB(body)
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

function static_model_query.BuildExpandedBodyWorldContactAABB(body)
	return static_model_query.BuildExpandedWorldContactAABB(static_model_query.BuildBodyWorldContactAABB(body), body)
end

local function append_model_candidate(out, model, world_aabb, include_unbounded)
	local bounds = model and (model.GetWorldAABB and model:GetWorldAABB() or model.AABB) or nil

	if bounds then
		if AABB.IsBoxIntersecting(world_aabb, bounds) then
			out[#out + 1] = {model = model}
		end

		return out
	end

	if include_unbounded and model then out[#out + 1] = {model = model} end

	return out
end

function static_model_query.CollectWorldModelCandidates(world_aabb, out, include_unbounded)
	out = out or {}

	if not world_aabb then return out end

	for _, model in ipairs(get_world_models()) do
		append_model_candidate(out, model, world_aabb, include_unbounded)
	end

	return out
end

function static_model_query.ForEachWorldPrimitiveCandidate(body, callback, world_aabb)
	local body_aabb = world_aabb or static_model_query.BuildBodyWorldContactAABB(body)
	local primitive_candidates = {}

	for _, model in ipairs(ModelComponent.Instances or {}) do
		local entity = model and model.Owner or nil

		if not (model and entity and entity ~= body:GetOwner()) then
			goto continue_model
		end

		if
			entity.PhysicsNoCollision or
			entity.NoPhysicsCollision or
			entity.rigid_body
		then
			goto continue_model
		end

		local filter_fn = body:GetFilterFunction()

		if filter_fn and not filter_fn(entity) then goto continue_model end

		local model_aabb = model.GetWorldAABB and model:GetWorldAABB() or model.AABB

		if model_aabb and not AABB.IsBoxIntersecting(body_aabb, model_aabb) then
			goto continue_model
		end

		local world_to_local, local_to_world = model_transform_utils.GetModelTransforms(model)
		local local_body_aabb = AABB.BuildLocalAABBFromWorldAABB(body_aabb, world_to_local)

		for i = #primitive_candidates, 1, -1 do
			primitive_candidates[i] = nil
		end

		raycast.CollectModelPrimitiveCandidatesByLocalAABB(model, local_body_aabb, primitive_candidates)

		for i = 1, #primitive_candidates do
			local candidate = primitive_candidates[i]
			local primitive = candidate and candidate.primitive or nil

			if primitive then
				callback(entity, primitive)
			end
		end

		::continue_model::
	end
end

return static_model_query
