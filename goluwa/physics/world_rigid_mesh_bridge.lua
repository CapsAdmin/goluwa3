local physics = import("goluwa/physics.lua")
local pair_solver_helpers = import("goluwa/physics/pair_solver_helpers.lua")
local world_static_query = import("goluwa/physics/world_static_query.lua")
local world_mesh_body = import("goluwa/physics/world_mesh_body.lua")
local world_rigid_mesh_bridge = {}

local function supports_shape_type(shape_type)
	return shape_type == "sphere" or shape_type == "capsule" or shape_type == "box" or shape_type == "convex"
end

local function body_supports_world_bridge(dynamic_body)
	if not dynamic_body then return false end

	if dynamic_body:GetShapeType() ~= "compound" then
		return supports_shape_type(dynamic_body:GetShapeType())
	end

	local colliders = dynamic_body:GetColliders() or {}

	if not colliders[1] then return false end

	for _, collider in ipairs(colliders) do
		if not supports_shape_type(collider:GetShapeType()) then return false end
	end

	return true
end

local function get_collider_sweep_hit(dynamic_body, collider)
	if not (physics.SweepCollider and collider and dynamic_body) then return nil end

	local previous_position = collider:GetPreviousPosition()
	local current_position = collider:GetPosition()
	local movement = current_position - previous_position

	if movement:GetLength() <= physics.EPSILON then return nil end

	local hit = physics.SweepCollider(
		collider,
		previous_position,
		movement,
		dynamic_body:GetOwner(),
		dynamic_body:GetFilterFunction(),
		{
			Rotation = collider:GetRotation(),
		}
	)

	if not (hit and world_mesh_body.IsSupportedPrimitive(hit.primitive)) then return nil end

	return {
		collider = collider,
		hit = hit,
		movement = movement,
		previous_position = previous_position,
		current_position = current_position,
	}
end

local function rewind_body_to_triangle_hit(dynamic_body, sweep_result)
	if not (dynamic_body and sweep_result and sweep_result.hit and sweep_result.collider) then return nil end

	local hit = sweep_result.hit
	local collider = sweep_result.collider
	local movement = sweep_result.movement
	local movement_length = movement:GetLength()

	if movement_length <= physics.EPSILON then return nil end

	local fraction = math.max(0, math.min(hit.fraction or 0, 1))
	local skin = math.max(collider:GetCollisionMargin() or 0, physics.DefaultSkin or 0)
	local post_fraction = math.min(1, fraction + skin / movement_length)
	local target_position = sweep_result.previous_position + movement * post_fraction
	local delta = target_position - sweep_result.current_position

	if delta:GetLength() <= physics.EPSILON then return nil end

	dynamic_body:SetPosition(dynamic_body:GetPosition() + delta)
	return delta
end

function world_rigid_mesh_bridge.ResolveBodyAgainstPrimitive(dynamic_body, model, entity, primitive, dt, primitive_index)
	if not (dynamic_body and world_mesh_body.IsSupportedPrimitive(primitive)) then return false end

	local proxy_body = world_mesh_body.GetPrimitiveBody(model, entity, primitive, primitive_index)

	if not (proxy_body and physics.ShouldBodiesCollide(dynamic_body, proxy_body)) then return false end

	return pair_solver_helpers.DispatchColliderPairs(
		physics.solver,
		dynamic_body:GetShapeType() == "compound" and dynamic_body:GetColliders() or {dynamic_body},
		proxy_body:GetColliders(),
		nil,
		nil,
		dt
	)
end

function world_rigid_mesh_bridge.ResolveBodyAgainstWorldPrimitives(dynamic_body, dt)
	if not body_supports_world_bridge(dynamic_body) then return false end

	local solved = false
	local query_aabb = world_static_query.BuildExpandedBodyWorldContactAABB(dynamic_body)

	world_static_query.ForEachWorldPrimitiveCandidate(
		dynamic_body,
		function(model, entity, primitive, primitive_index)
			if world_mesh_body.IsSupportedPrimitive(primitive) then
				if world_rigid_mesh_bridge.ResolveBodyAgainstPrimitive(dynamic_body, model, entity, primitive, dt, primitive_index) then
					solved = true
				end
			end
		end,
		nil,
		nil,
		nil,
		nil,
		query_aabb
	)

	return solved
end

function world_rigid_mesh_bridge.CanResolveBodyAgainstWorldPrimitives(dynamic_body)
	return body_supports_world_bridge(dynamic_body)
end

function world_rigid_mesh_bridge.ResolveSweptBodyAgainstWorldPrimitives(dynamic_body, dt)
	if not body_supports_world_bridge(dynamic_body) then return false end

	local best = nil

	for _, collider in ipairs(dynamic_body:GetColliders() or {}) do
		local sweep_hit = get_collider_sweep_hit(dynamic_body, collider)

		if sweep_hit and (not best or (sweep_hit.hit.fraction or 1) < (best.hit.fraction or 1)) then
			best = sweep_hit
		end
	end

	if not best then return false end

	local original_position = dynamic_body:GetPosition():Copy()
	local delta = rewind_body_to_triangle_hit(dynamic_body, best)

	if not delta then return false end

	local solved = world_rigid_mesh_bridge.ResolveBodyAgainstPrimitive(
		dynamic_body,
		best.hit.model,
		best.hit.entity,
		best.hit.primitive,
		dt,
		best.hit.primitive_index
	)

	if not solved then dynamic_body:SetPosition(original_position) end

	return solved
end

world_rigid_mesh_bridge.ResolveBodyAgainstWorldTriangles = world_rigid_mesh_bridge.ResolveBodyAgainstWorldPrimitives
world_rigid_mesh_bridge.CanResolveBodyAgainstWorldTriangles = world_rigid_mesh_bridge.CanResolveBodyAgainstWorldPrimitives
world_rigid_mesh_bridge.ResolveSweptBodyAgainstWorldTriangles = world_rigid_mesh_bridge.ResolveSweptBodyAgainstWorldPrimitives

return world_rigid_mesh_bridge