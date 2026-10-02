local raycast = import("goluwa/physics/raycast.lua")
local stats = import("goluwa/physics/stats.lua")
local physics_constants = import("goluwa/physics/constants.lua")
local model_transform_utils = import("goluwa/physics/model_transform_utils.lua")
local AABB = import("goluwa/structs/aabb.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local VisualComponent = RENDER_3D and import("goluwa/entities/components/visual.lua")
local static_model_query = {}

local function for_each_spatial_component(callback)
	if not VisualComponent then return end

	for _, visual in ipairs(VisualComponent.Instances) do
		callback(visual)
	end
end

function static_model_query.BuildExpandedWorldContactAABB(bounds, body, extra_body, extra_pad)
	local margin = body and (body:GetCollisionMargin() or 0) or 0
	local probe_distance = body and (body:GetCollisionProbeDistance() or 0) or 0
	local extra_margin = extra_body and (extra_body:GetCollisionMargin() or 0) or 0
	local extra_probe_distance = extra_body and (extra_body:GetCollisionProbeDistance() or 0) or 0
	local pad = math.max(
			margin + probe_distance + extra_margin + extra_probe_distance,
			physics_constants.DEFAULT_COLLISION_MARGIN,
			physics_constants.EPSILON
		) + (
			extra_pad or
			0
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

do
	-- The models that are not simulated as bodies, rebuilt when the physics
	-- step starts or the model count changes. A sweep only has to test these
	-- against its bounds; testing every model of a busy scene against every
	-- sweep was most of its step.
	local static_models = {}
	local static_model_count = 0
	local stale = true
	local known_instance_count = -1

	function static_model_query.InvalidateWorldModels()
		stale = true
	end

	-- ignore_rigid_bodies drops the models of entities that have a rigid body
	function static_model_query.CollectWorldModelCandidates(world_aabb, out, ignore_rigid_bodies, include_unbounded)
		out = out or {}

		if not world_aabb or not VisualComponent then return out end

		stats:PushTime("sweep_models")
		stats:Count("world_model_scans")
		local models = VisualComponent.Instances
		local count = #models

		if ignore_rigid_bodies then
			if stale or count ~= known_instance_count then
				stale = false
				known_instance_count = count
				static_model_count = 0

				for i = 1, count do
					local owner = models[i].Owner

					if not (owner and owner.rigid_body) then
						static_model_count = static_model_count + 1
						static_models[static_model_count] = models[i]
					end
				end

				for i = static_model_count + 1, #static_models do
					static_models[i] = nil
				end
			end

			models = static_models
			count = static_model_count
		end

		stats:Count("world_models_scanned", count)

		for i = 1, count do
			local model = models[i]
			local bounds = model.GetWorldAABB and model:GetWorldAABB() or model.AABB

			if bounds then
				if AABB.IsBoxIntersecting(world_aabb, bounds) then
					stats:Count("world_model_candidates")
					out[#out + 1] = model
				end
			elseif include_unbounded then
				out[#out + 1] = model
			end
		end

		stats:PopTime()
		return out
	end
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
