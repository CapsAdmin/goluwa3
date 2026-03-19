local physics = import("goluwa/physics.lua")
local mesh_surface_contact = import("goluwa/physics/mesh_surface_contact.lua")
local raycast = import("goluwa/physics/raycast.lua")
local world_static_query = import("goluwa/physics/world_static_query.lua")
local RigidBodyComponent = import("goluwa/physics/rigid_body.lua")

local function normalize_query_options(options)
	options = options or {}

	if options.IncludeRigidBodies ~= nil and options.IgnoreRigidBodies == nil then
		options.IgnoreRigidBodies = not options.IncludeRigidBodies
	end

	if options.IncludeKinematicBodies ~= nil and options.IgnoreKinematicBodies == nil then
		options.IgnoreKinematicBodies = not options.IncludeKinematicBodies
	end

	if
		options.IncludeWorld ~= nil and
		options.UseRenderMeshes == nil and
		options.WorldSource == nil
	then
		options.UseRenderMeshes = options.IncludeWorld
	end

	return options
end

local function filter(entity, ignore_entity, filter_fn, ignore_kinematic, ignore_rigid)
	if entity == ignore_entity then return false end

	if entity.PhysicsNoCollision or entity.NoPhysicsCollision then return false end

	if
		ignore_kinematic and
		entity.rigid_body and
		entity.rigid_body.IsKinematic and
		entity.rigid_body:IsKinematic()
	then
		return false
	end

	if ignore_rigid and entity.rigid_body then return false end

	if filter_fn and not filter_fn(entity) then return false end

	return true
end

local function cast_with_filter(
	origin,
	direction,
	max_distance,
	ignore_entity,
	filter_fn,
	options,
	ignore_rigid_override
)
	local cast_options = options or {}
	local ignore_kinematic = cast_options.IgnoreKinematicBodies ~= false
	local ignore_rigid = cast_options.IgnoreRigidBodies ~= false
	local world_source = cast_options.WorldSource

	if ignore_rigid_override ~= nil then ignore_rigid = ignore_rigid_override end

	local use_render_meshes = cast_options.UseRenderMeshes
	world_source, use_render_meshes = world_static_query.ResolveWorldSource(world_source, use_render_meshes, ignore_rigid)

	if cast_options.ClosestOnly ~= false then
		if world_source then
			local hit = raycast.CastClosestFromSource(
				world_source,
				origin,
				direction,
				max_distance or math.huge,
				filter,
				ignore_entity,
				filter_fn,
				ignore_kinematic,
				ignore_rigid
			)
			return hit and {hit} or {}
		end

		if not use_render_meshes then return {} end

		local hit = raycast.CastClosest(
			origin,
			direction,
			max_distance or math.huge,
			filter,
			ignore_entity,
			filter_fn,
			ignore_kinematic,
			ignore_rigid
		)
		return hit and {hit} or {}
	end

	if world_source then
		return raycast.CastFromSource(
			world_source,
			origin,
			direction,
			max_distance or math.huge,
			filter,
			ignore_entity,
			filter_fn,
			ignore_kinematic,
			ignore_rigid
		)
	end

	if not use_render_meshes then return {} end

	local hits = raycast.Cast(
		origin,
		direction,
		max_distance or math.huge,
		filter,
		ignore_entity,
		filter_fn,
		ignore_kinematic,
		ignore_rigid
	)
	return hits
end

local function is_straight_down(direction)
	return direction and
		math.abs(direction.x) <= 0.00001 and
		direction.y < -0.00001 and
		math.abs(direction.z) <= 0.00001
end

local function pick_best_world_hit(hits, direction)
	if not (hits and hits[1]) then return nil end

	if is_straight_down(direction) then
		for _, hit in ipairs(hits) do
			if hit.normal and hit.normal.y >= 0 then return hit end
		end
	end

	return hits[1]
end

function physics.Trace(origin, direction, max_distance, ignore_entity, filter_fn, options)
	options = normalize_query_options(options)
	local allow_rigid = options.IgnoreRigidBodies == false
	local downward_trace = is_straight_down(direction)
	local hits = cast_with_filter(
		origin,
		direction,
		max_distance,
		ignore_entity,
		filter_fn,
		options,
		allow_rigid and true or nil
	)
	local best_hit = pick_best_world_hit(hits, direction)

	if allow_rigid then
		local trace_radius = options.TraceRadius or 0

		for _, body in ipairs(RigidBodyComponent.Instances or {}) do
			if not (physics.IsActiveRigidBody(body) and body.Owner ~= ignore_entity) then
				goto continue
			end

			if body.Owner and (body.Owner.PhysicsNoCollision or body.Owner.NoPhysicsCollision) then
				goto continue
			end

			if
				options.IgnoreKinematicBodies ~= false and
				body.IsKinematic and
				body:IsKinematic()
			then
				goto continue
			end

			if filter_fn and not filter_fn(body.Owner) then goto continue end

			for _, collider in ipairs(body.GetColliders and body:GetColliders() or {}) do
				local hit = collider:GetPhysicsShape():TraceAgainstBody(collider, origin, direction, max_distance, trace_radius)

				if hit and (not best_hit or hit.distance < best_hit.distance) then
					best_hit = hit
				end
			end

			::continue::
		end
	end

	return best_hit
end

physics.RayCast = physics.Trace

function physics.GetHitNormal(hit, reference_point)
	local contact = physics.GetHitSurfaceContact(hit, reference_point)
	local normal = contact and contact.normal or nil

	if not normal then return nil end

	if hit and hit.normal then
		if normal:Dot(hit.normal) < 0 then normal = normal * -1 end
	elseif reference_point and hit and hit.position then
		if (reference_point - hit.position):Dot(normal) < 0 then normal = normal * -1 end
	end

	return normal
end

function physics.GetHitSurfaceContact(hit, reference_point)
	return mesh_surface_contact.GetHitSurfaceContact(hit, reference_point)
end

return physics
