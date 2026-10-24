local mesh_surface_contact = import("goluwa/physics/mesh_surface_contact.lua")
local sweep_candidates = import("goluwa/physics/sweep_candidates.lua")
local collider_index = import("goluwa/physics/collider_index.lua")
local stats = import("goluwa/physics/stats.lua")
local AABB = import("goluwa/structs/aabb.lua")
local trace = {}
local EMPTY_OPTIONS = {}

local function normalize_query_options(options)
	if options == nil then return EMPTY_OPTIONS end

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

local MAX_RAY_EXTENT = 1e6
local MIN_DIRECTION_LENGTH = 0.00001
local ray_aabb = AABB(0, 0, 0, 0, 0, 0)
local ray_bodies = {}
local ray_colliders = {}

function trace.RayCast(physics, origin, direction, max_distance, ignore_entity, filter_fn, options)
	stats:PushTime("trace")
	stats:Count("traces")
	options = normalize_query_options(options)
	local dx, dy, dz = direction.x, direction.y, direction.z
	local length = math.sqrt(dx * dx + dy * dy + dz * dz)
	local best_hit = nil

	if length > MIN_DIRECTION_LENGTH then
		local trace_radius = options.TraceRadius or 0
		local scale = math.min(max_distance or math.huge, MAX_RAY_EXTENT) / length
		local end_x = origin.x + dx * scale
		local end_y = origin.y + dy * scale
		local end_z = origin.z + dz * scale
		ray_aabb.min_x = math.min(origin.x, end_x) - trace_radius
		ray_aabb.min_y = math.min(origin.y, end_y) - trace_radius
		ray_aabb.min_z = math.min(origin.z, end_z) - trace_radius
		ray_aabb.max_x = math.max(origin.x, end_x) + trace_radius
		ray_aabb.max_y = math.max(origin.y, end_y) + trace_radius
		ray_aabb.max_z = math.max(origin.z, end_z) + trace_radius
		table.clear(ray_bodies)
		sweep_candidates.CollectRigidBodyCandidates(physics, ray_aabb, ignore_entity, filter_fn, options, ray_bodies)
		local ignore_world = options.IgnoreWorld == true

		for i = 1, #ray_bodies do
			local body = ray_bodies[i]

			if not (ignore_world and body.WorldGeometry == true) then
				local colliders, count = collider_index.Query(body, ray_aabb, ray_colliders)

				for j = 1, count do
					local collider = colliders[j]
					local hit = collider:GetPhysicsShape():TraceAgainstBody(collider, origin, direction, max_distance, trace_radius)

					if hit and (not best_hit or hit.distance < best_hit.distance) then
						best_hit = hit
					end
				end
			end
		end
	end

	stats:PopTime()
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
