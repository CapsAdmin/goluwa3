local mesh_surface_contact = import("goluwa/physics/mesh_surface_contact.lua")
local raycast = import("goluwa/physics/raycast.lua")
local RigidBodyComponent = import("goluwa/physics/rigid_body.lua")
local trace = {}

local function should_query_body_as_world(body, options)
	return options.IgnoreWorld ~= true and body and body.WorldGeometry == true
end

local function has_world_geometry_bodies()
	for _, body in ipairs(RigidBodyComponent.Instances) do
		if body.WorldGeometry == true then return true end
	end

	return false
end

local function normalize_query_options(options)
	options = options or {}

	if options.IncludeRigidBodies ~= nil and options.IgnoreRigidBodies == nil then
		options.IgnoreRigidBodies = not options.IncludeRigidBodies
	end

	if options.IncludeKinematicBodies ~= nil and options.IgnoreKinematicBodies == nil then
		options.IgnoreKinematicBodies = not options.IncludeKinematicBodies
	end

	if options.IncludeWorld ~= nil and options.UseRenderMeshes == nil then
		options.UseRenderMeshes = options.IncludeWorld
	end

	if
		options.UseRenderMeshes == nil and
		options.IgnoreWorld ~= true and
		has_world_geometry_bodies()
	then
		options.UseRenderMeshes = false
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

	if ignore_rigid_override ~= nil then ignore_rigid = ignore_rigid_override end

	local use_render_meshes = cast_options.UseRenderMeshes

	if use_render_meshes == nil then use_render_meshes = true end

	if cast_options.ClosestOnly ~= false then
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

function trace.RayCast(origin, direction, max_distance, ignore_entity, filter_fn, options)
	options = normalize_query_options(options)
	local allow_rigid = options.IgnoreRigidBodies == false
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

	if allow_rigid or options.IgnoreWorld ~= true then
		local trace_radius = options.TraceRadius or 0

		for _, body in ipairs(RigidBodyComponent.Instances) do
			local query_as_world = should_query_body_as_world(body, options)

			if not (allow_rigid or query_as_world) then goto continue end

			if body.Owner == ignore_entity then goto continue end

			if not body.CollisionEnabled then goto continue end

			if
				not query_as_world and
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

function trace.GetHitNormal(hit, reference_point)
	local contact = trace.GetHitSurfaceContact(hit, reference_point)
	local normal = contact and contact.normal or nil

	if not normal then return nil end

	if hit and hit.normal then
		if normal:Dot(hit.normal) < 0 then normal = normal * -1 end
	elseif reference_point and hit and hit.position then
		if (reference_point - hit.position):Dot(normal) < 0 then normal = normal * -1 end
	end

	return normal
end

function trace.GetHitSurfaceContact(hit, reference_point)
	return mesh_surface_contact.GetHitSurfaceContact(hit, reference_point)
end

return trace
