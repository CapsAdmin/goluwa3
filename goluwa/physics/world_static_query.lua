local physics = import("goluwa/physics.lua")
local BVH = import("goluwa/physics/bvh.lua")
local raycast = import("goluwa/physics/raycast.lua")
local world_transform_utils = import("goluwa/physics/world_transform_utils.lua")
local AABB = import("goluwa/structs/aabb.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local ModelComponent = import("goluwa/ecs/components/3d/model.lua")
local world_static_query = {}

function world_static_query.BuildExpandedWorldContactAABB(bounds, body, extra_body)
	local margin = body and body.GetCollisionMargin and body:GetCollisionMargin() or 0
	local probe_distance = body and body.GetCollisionProbeDistance and body:GetCollisionProbeDistance() or 0
	local extra_margin = extra_body and extra_body.GetCollisionMargin and extra_body:GetCollisionMargin() or 0
	local extra_probe_distance = extra_body and extra_body.GetCollisionProbeDistance and extra_body:GetCollisionProbeDistance() or 0
	local pad = math.max(margin + probe_distance + extra_margin + extra_probe_distance, physics.DefaultSkin or 0, physics.EPSILON)
	return {
		min_x = bounds.min_x - pad,
		min_y = bounds.min_y - pad,
		min_z = bounds.min_z - pad,
		max_x = bounds.max_x + pad,
		max_y = bounds.max_y + pad,
		max_z = bounds.max_z + pad,
	}
end

function world_static_query.GetWorldModels(source)
	source = source == nil and (physics.GetWorldTraceSource and physics.GetWorldTraceSource() or nil) or source

	if source and source.models then return source.models end

	return ModelComponent.Instances or {}
end

function world_static_query.ResolveWorldSource(source, use_render_meshes, ignore_rigid_bodies)
	if source == nil and physics.GetWorldTraceSource then
		source = physics.GetWorldTraceSource()
	end

	if use_render_meshes == nil then use_render_meshes = source == nil end

	if not source then
		if not use_render_meshes then
			if ignore_rigid_bodies then return nil, use_render_meshes end

			return false, use_render_meshes
		end

		source = {
			models = ModelComponent.Instances or {},
		}
	end

	return source, use_render_meshes
end

function world_static_query.BuildBodyWorldContactAABB(body)
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
		local margin = body.GetCollisionMargin and math.max(body:GetCollisionMargin() or 0.01, 0.01) or 0.01
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

function world_static_query.BuildExpandedBodyWorldContactAABB(body)
	return world_static_query.BuildExpandedWorldContactAABB(world_static_query.BuildBodyWorldContactAABB(body), body)
end

local function visit_model_bvh_leaf_aabb(node, context, out)
	for i = node.first, node.last do
		out[#out + 1] = context.acceleration.models[i]
	end

	return out
end

local function append_model_candidate(out, model, world_aabb, include_unbounded)
	local bounds = model and (model.GetWorldAABB and model:GetWorldAABB() or model.AABB) or nil

	if bounds then
		if AABB.IsBoxIntersecting(world_aabb, bounds) then out[#out + 1] = {model = model} end
		return out
	end

	if include_unbounded and model then out[#out + 1] = {model = model} end
	return out
end

function world_static_query.CollectWorldModelCandidates(source, world_aabb, out, include_unbounded)
	out = out or {}

	if not world_aabb or source == false then return out end

	if source and source.tree then
		local traversal_context = source.tree.traversal_context or {}
		traversal_context.acceleration = source.tree
		traversal_context.node_stack = traversal_context.node_stack or {}
		BVH.TraverseAABB(world_aabb, source.tree.root, visit_model_bvh_leaf_aabb, traversal_context, out)

		for _, model in ipairs(source.dynamic_models or {}) do
			append_model_candidate(out, model, world_aabb, include_unbounded)
		end

		return out
	end

	for _, model in ipairs(world_static_query.GetWorldModels(source)) do
		append_model_candidate(out, model, world_aabb, include_unbounded)
	end

	return out
end

function world_static_query.ForEachWorldPrimitiveCandidate(body, callback, arg1, arg2, arg3, arg4, world_aabb, source)
	local body_aabb = world_aabb or world_static_query.BuildBodyWorldContactAABB(body)
	local model_candidates = world_static_query.CollectWorldModelCandidates(source, body_aabb, {}, true)
	local primitive_candidates = {}

	for _, item in ipairs(model_candidates) do
		local model = item and item.model or nil
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

		local world_to_local, local_to_world = world_transform_utils.GetModelTransforms(model)
		local local_body_aabb = AABB.BuildLocalAABBFromWorldAABB(body_aabb, world_to_local)

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

return world_static_query
