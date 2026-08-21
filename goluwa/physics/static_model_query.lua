local raycast = import("goluwa/physics/raycast.lua")
local physics_constants = import("goluwa/physics/constants.lua")
local model_transform_utils = import("goluwa/physics/model_transform_utils.lua")
local AABB = import("goluwa/structs/aabb.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local VisualComponent = _G.GRAPHICS_3D and import("goluwa/entities/components/visual.lua")
local static_model_query = {}

local function for_each_spatial_component(callback)
	if not VisualComponent then return end

	for _, visual in ipairs(VisualComponent.Instances) do
		callback(visual)
	end
end

function static_model_query.BuildExpandedWorldContactAABB(bounds, body, extra_body)
	local margin = body and (body:GetCollisionMargin() or 0) or 0
	local probe_distance = body and (body:GetCollisionProbeDistance() or 0) or 0
	local extra_margin = extra_body and (extra_body:GetCollisionMargin() or 0) or 0
	local extra_probe_distance = extra_body and (extra_body:GetCollisionProbeDistance() or 0) or 0
	local pad = math.max(
		margin + probe_distance + extra_margin + extra_probe_distance,
		physics_constants.DEFAULT_COLLISION_MARGIN,
		physics_constants.EPSILON
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

function static_model_query.BuildBodyWorldContactAABB(body)
	return body:GetBroadphaseAABB()
end

function static_model_query.BuildExpandedBodyWorldContactAABB(body)
	return static_model_query.BuildExpandedWorldContactAABB(static_model_query.BuildBodyWorldContactAABB(body), body)
end

function static_model_query.CollectWorldModelCandidates(world_aabb, out, include_unbounded)
	out = out or {}

	if not world_aabb or not VisualComponent then return out end

	-- inlined spatial component scan: no per-call closure, no per-model callback
	for _, model in ipairs(VisualComponent.Instances) do
		local bounds = model and (model.GetWorldAABB and model:GetWorldAABB() or model.AABB) or nil

		if bounds then
			if AABB.IsBoxIntersecting(world_aabb, bounds) then
				out[#out + 1] = model
			end
		elseif include_unbounded and model then
			out[#out + 1] = model
		end
	end

	return out
end

function static_model_query.ForEachWorldPrimitiveCandidate(body, callback, world_aabb)
	local body_aabb = world_aabb or static_model_query.BuildBodyWorldContactAABB(body)
	local primitive_candidates = {}

	for_each_spatial_component(function(model)
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

			if primitive then callback(entity, primitive) end
		end

		::continue_model::
	end)
end

return static_model_query
