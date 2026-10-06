local mesh_surface_contact = import("goluwa/physics/mesh_surface_contact.lua")
local RigidBodyComponent = import("goluwa/physics/rigid_body.lua")
local stats = import("goluwa/physics/stats.lua")
local trace = {}

local function normalize_query_options(options)
	options = options or {}

	if options.IncludeRigidBodies ~= nil and options.IgnoreRigidBodies == nil then
		options.IgnoreRigidBodies = not options.IncludeRigidBodies
	end

	if options.IncludeKinematicBodies ~= nil and options.IgnoreKinematicBodies == nil then
		options.IgnoreKinematicBodies = not options.IncludeKinematicBodies
	end

	if options.IncludeWorld ~= nil and options.IgnoreWorld == nil then
		options.IgnoreWorld = not options.IncludeWorld
	end

	return options
end

local ray_cast

function trace.RayCast(origin, direction, max_distance, ignore_entity, filter_fn, options)
	stats:PushTime("trace")
	stats:Count("traces")
	local hit = ray_cast(origin, direction, max_distance, ignore_entity, filter_fn, options)
	stats:PopTime()
	return hit
end

function ray_cast(origin, direction, max_distance, ignore_entity, filter_fn, options)
	options = normalize_query_options(options)
	local allow_rigid = options.IgnoreRigidBodies == false
	local best_hit = nil

	if not (allow_rigid or options.IgnoreWorld ~= true) then return nil end

	local trace_radius = options.TraceRadius or 0
	local bodies = allow_rigid and
		RigidBodyComponent.Instances or
		RigidBodyComponent.WorldGeometryBodies

	for _, body in ipairs(bodies) do
		if body.Owner == ignore_entity then goto continue end

		if body.WorldGeometry == true and options.IgnoreWorld == true then
			goto continue
		end

		if not body.CollisionEnabled then goto continue end

		if
			options.IgnoreKinematicBodies ~= false and
			body.WorldGeometry ~= true and
			body:IsKinematic()
		then
			goto continue
		end

		if filter_fn and not filter_fn(body.Owner) then goto continue end

		for _, collider in ipairs(body:GetColliders() or {}) do
			local hit = collider:GetPhysicsShape():TraceAgainstBody(collider, origin, direction, max_distance, trace_radius)

			if hit and (not best_hit or hit.distance < best_hit.distance) then
				best_hit = hit
			end
		end

		::continue::
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
